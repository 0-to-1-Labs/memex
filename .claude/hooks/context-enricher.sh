#!/bin/bash
# =============================================================================
# UserPromptSubmit Hook - Context Enricher
# =============================================================================
# Analyzes user prompts for documentation-related keywords and injects
# relevant documentation sections into the conversation context.
#
# This is the core of the Memex intelligent auto-loading system.
#
# Features:
# - Section-level loading (extracts specific sections via anchors)
# - Context budget awareness (stops at token threshold)
# - Session-level deduplication (tracks loaded docs)
# - Smart truncation (800 lines max for files, 150 for sections)
#
# To customize for your project:
# 1. Add entries to docs/GLOSSARY.md (keyword -> file.md#section mappings)
# 2. The hook reads those mappings at runtime - no need to edit this script
# 3. Matched docs are auto-injected wrapped in XML tags
#
# Compatible with bash 3.x (macOS default) - no associative arrays.
# Works in two modes:
#   - Plugin:    project root from $CLAUDE_PROJECT_DIR (set by Claude Code)
#   - Installer: same env var; falls back to current directory
# =============================================================================

set -e

# -----------------------------------------------------------------------------
# Dependency Check
# -----------------------------------------------------------------------------
if ! command -v jq &> /dev/null; then
    echo "<!-- Memex: jq required but not found. Install with: brew install jq -->" >&2
    exit 0
fi

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
DOCS_DIR="$PROJECT_ROOT/docs"

# -----------------------------------------------------------------------------
# Telemetry Integration (optional - uses Claude Code's OTel config)
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/telemetry.sh" ]]; then
    source "$SCRIPT_DIR/telemetry.sh"
    telemetry_init "user_prompt_submit"
fi

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
MAX_FILE_LINES=800           # Maximum lines to load from a single file
MAX_SECTION_LINES=150        # Maximum lines to load from a section
MAX_TOTAL_TOKENS=10000       # Approximate token budget (~7 tokens per line)
TOKENS_PER_LINE=7            # Rough estimate for markdown

# Session cache for deduplication (stable across hook invocations)
# Security approach: Use user-specific tmp dir with random session token
# The session token is stored so it persists across hook invocations
USER_MEMEX_TMP="${TMPDIR:-/tmp}/memex-$(id -u)"

# Create user-specific directory with secure permissions
if [ ! -d "$USER_MEMEX_TMP" ]; then
    mkdir -p "$USER_MEMEX_TMP" 2>/dev/null || {
        echo "Error: Failed to create memex temp directory" >&2
        exit 1
    }
fi
chmod 700 "$USER_MEMEX_TMP" 2>/dev/null || true

# Verify ownership before using (prevent symlink attacks)
if [ "$(stat -f %u "$USER_MEMEX_TMP" 2>/dev/null || stat -c %u "$USER_MEMEX_TMP" 2>/dev/null)" != "$(id -u)" ]; then
    echo "Error: Memex temp directory ownership mismatch - possible security issue" >&2
    exit 1
fi

# Use PPID combined with a random suffix for session identification
# PPID provides stability across hook invocations; random suffix adds unpredictability
SESSION_TOKEN_FILE="$USER_MEMEX_TMP/session-$PPID"
if [ ! -f "$SESSION_TOKEN_FILE" ]; then
    # Generate new session token with random suffix
    RANDOM_SUFFIX=$(head -c 16 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n' || echo "$$$(date +%s)")
    echo "$RANDOM_SUFFIX" > "$SESSION_TOKEN_FILE"
    chmod 600 "$SESSION_TOKEN_FILE"
fi
SESSION_TOKEN=$(cat "$SESSION_TOKEN_FILE" 2>/dev/null || echo "$PPID")

SESSION_CACHE_DIR="$USER_MEMEX_TMP/cache-$SESSION_TOKEN"
LOADED_DOCS_FILE="$SESSION_CACHE_DIR/loaded_docs"

# Initialize session cache directory with secure permissions
if [ ! -d "$SESSION_CACHE_DIR" ]; then
    mkdir -p "$SESSION_CACHE_DIR" 2>/dev/null || {
        echo "Error: Failed to create session cache directory" >&2
        exit 1
    }
    chmod 700 "$SESSION_CACHE_DIR"
fi

# Read the hook input from stdin (JSON format)
INPUT=$(cat)

# Extract the user prompt using jq
USER_PROMPT=$(echo "$INPUT" | jq -r '.user_prompt // empty' 2>/dev/null)

# Exit if no prompt or jq not available
if [ -z "$USER_PROMPT" ]; then
    exit 0
fi

# Convert prompt to lowercase for case-insensitive matching
PROMPT_LOWER=$(echo "$USER_PROMPT" | tr '[:upper:]' '[:lower:]')

# -----------------------------------------------------------------------------
# Token tracking
# -----------------------------------------------------------------------------
TOTAL_TOKENS_LOADED=0

# Check if we've exceeded our token budget
check_budget() {
    if [ "$TOTAL_TOKENS_LOADED" -ge "$MAX_TOTAL_TOKENS" ]; then
        return 1  # Budget exceeded
    fi
    return 0  # Budget available
}

# Add tokens to our running total
add_tokens() {
    local lines=$1
    local tokens=$((lines * TOKENS_PER_LINE))
    TOTAL_TOKENS_LOADED=$((TOTAL_TOKENS_LOADED + tokens))
}

# -----------------------------------------------------------------------------
# Session deduplication
# -----------------------------------------------------------------------------
# Check if a doc (with optional section) was already loaded this session
is_already_loaded() {
    local doc_ref="$1"
    if [ -f "$LOADED_DOCS_FILE" ]; then
        grep -q "^${doc_ref}$" "$LOADED_DOCS_FILE" 2>/dev/null && return 0
    fi
    return 1
}

# Mark a doc as loaded in this session
mark_as_loaded() {
    local doc_ref="$1"
    echo "$doc_ref" >> "$LOADED_DOCS_FILE"
}

# -----------------------------------------------------------------------------
# Matched docs tracking (space-separated list for bash 3.x compatibility)
# -----------------------------------------------------------------------------
MATCHED_DOCS=""

# Function to add a doc to matched list (deduplicates within this request)
add_doc() {
    local doc="$1"

    # Skip if already in this request's list
    case " $MATCHED_DOCS " in
        *" $doc "*)
            return
            ;;
    esac

    # Skip if already loaded in this session
    if is_already_loaded "$doc"; then
        # Telemetry: track cache hit (deduplication)
        if type emit_cache_hit &>/dev/null; then
            emit_cache_hit "$doc"
        fi
        return
    fi

    MATCHED_DOCS="$MATCHED_DOCS $doc"
}

# =============================================================================
# KEYWORD-TO-DOCUMENTATION MATCHING
# =============================================================================
# Keyword mappings are read from docs/GLOSSARY.md at runtime. Each glossary
# bullet of the form:
#
#     - **keyword** -> `docs/path/to/FILE.md#section` - description
#
# becomes a trigger: when the prompt contains <keyword> (case-insensitive),
# the mapped doc is injected. Paths may be written relative to the repo root
# (with a leading docs/) or relative to docs/ - both resolve correctly.
#
# This keeps customization in GLOSSARY.md (a single source of truth) so the
# hook itself never needs editing - which is what lets it ship as a plugin.
#
# If docs/GLOSSARY.md is absent, a small built-in default map is used so the
# hook still does something useful out of the box.
# =============================================================================

# Match keywords defined in docs/GLOSSARY.md
match_glossary_keywords() {
    local glossary="$DOCS_DIR/GLOSSARY.md"
    [ -f "$glossary" ] || return 1

    local line kw path kw_lower
    while IFS= read -r line; do
        # Only bullet lines that map a **keyword** to a `path` qualify.
        # (Table rows and prose lack the **...** / backtick pairing.)
        case "$line" in
            *'**'*'**'*'`'*'`'*) ;;
            *) continue ;;
        esac

        # Extract keyword between the first pair of **
        kw="${line#*\*\*}"
        kw="${kw%%\*\**}"
        # Extract path between the first pair of backticks
        path="${line#*\`}"
        path="${path%%\`*}"

        [ -n "$kw" ] && [ -n "$path" ] || continue

        # Glossary paths are written relative to repo root (docs/...); the
        # loader resolves relative to docs/, so strip a leading docs/.
        path="${path#docs/}"

        kw_lower=$(printf '%s' "$kw" | tr '[:upper:]' '[:lower:]')

        case "$PROMPT_LOWER" in
            *"$kw_lower"*) add_doc "$path" ;;
        esac
    done < "$glossary"

    return 0
}

# Built-in fallback map (used only when docs/GLOSSARY.md does not exist)
match_builtin_defaults() {
    case "$PROMPT_LOWER" in
        *architecture*|*docker*|*container*|*network*|*infrastructure*|*topology*)
            add_doc "core/ARCHITECTURE.md" ;;
    esac
    case "$PROMPT_LOWER" in
        *database*|*postgres*|*schema*|*table*|*query*|*sql*|*migration*)
            add_doc "core/DATABASE.md" ;;
    esac
    case "$PROMPT_LOWER" in
        *" api"*|*"api "*|*endpoint*|*route*|*" rest"*|*request*|*response*)
            add_doc "core/API.md" ;;
    esac
    case "$PROMPT_LOWER" in
        *deploy*|*"ci/cd"*|*cicd*|*"github action"*|*workflow*|*production*)
            add_doc "DEPLOYMENT.md" ;;
    esac
    case "$PROMPT_LOWER" in
        *troubleshoot*|*" error"*|*"error "*|*debug*|*" fix "*|*issue*|*problem*)
            add_doc "TROUBLESHOOTING.md" ;;
    esac
    case "$PROMPT_LOWER" in
        *contributing*|*contribute*|*guidelines*|*"pull request"*)
            add_doc "CONTRIBUTING.md" ;;
    esac
}

if [ -f "$DOCS_DIR/GLOSSARY.md" ]; then
    match_glossary_keywords
else
    match_builtin_defaults
fi

# -----------------------------------------------------------------------------
# Exit if no matches
# -----------------------------------------------------------------------------
MATCHED_DOCS=$(echo "$MATCHED_DOCS" | xargs)  # Trim whitespace
if [ -z "$MATCHED_DOCS" ]; then
    # Telemetry: no keywords matched
    if type emit_no_match &>/dev/null; then
        emit_no_match
        telemetry_finish "no_match"
    fi
    exit 0
fi

# -----------------------------------------------------------------------------
# Section Extraction Function
# -----------------------------------------------------------------------------
# Extracts a specific section from a markdown file based on anchor
# Usage: extract_section "file.md" "section-name"
extract_section() {
    local file="$1"
    local section="$2"
    local in_section=0
    local section_level=0
    local line_count=0
    local output=""

    # Convert anchor to header pattern (e.g., "quick-start" -> "Quick Start" or similar)
    local section_pattern=$(echo "$section" | tr '-' ' ')

    while IFS= read -r line; do
        # Check if this is a header line
        if [[ "$line" =~ ^(#+)[[:space:]]+(.*) ]]; then
            local hashes="${BASH_REMATCH[1]}"
            local header_text="${BASH_REMATCH[2]}"
            local current_level=${#hashes}

            # Slugify the header for comparison
            local header_slug=$(echo "$header_text" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd 'a-z0-9-')

            if [ "$in_section" -eq 0 ]; then
                # Check if this header matches our target section
                if [[ "$header_slug" == *"$section"* ]] || [[ "$(echo "$header_text" | tr '[:upper:]' '[:lower:]')" == *"$section_pattern"* ]]; then
                    in_section=1
                    section_level=$current_level
                    output="$line"$'\n'
                    line_count=1
                fi
            else
                # We're in the section - check if we've hit a same-level or higher header
                if [ "$current_level" -le "$section_level" ]; then
                    break  # End of our section
                fi
                output="$output$line"$'\n'
                line_count=$((line_count + 1))
            fi
        elif [ "$in_section" -eq 1 ]; then
            output="$output$line"$'\n'
            line_count=$((line_count + 1))
        fi

        # Enforce section line limit
        if [ "$line_count" -ge "$MAX_SECTION_LINES" ]; then
            output="$output"$'\n'"<!-- Section truncated at $MAX_SECTION_LINES lines -->"
            break
        fi
    done < "$file"

    if [ "$in_section" -eq 1 ]; then
        echo "$output"
        echo "$line_count"  # Return line count as last line
    else
        echo ""
        echo "0"
    fi
}

# -----------------------------------------------------------------------------
# Output Context Injection
# -----------------------------------------------------------------------------
echo ""
echo "<auto-loaded-documentation>"
echo "<!-- Documentation auto-loaded by Memex based on your query keywords. -->"
echo "<!-- Token budget: ~$MAX_TOTAL_TOKENS tokens | Session deduplication active -->"
echo ""

DOCS_LOADED=0

for doc_ref in $MATCHED_DOCS; do
    # Check token budget before loading more
    if ! check_budget; then
        echo "<!-- Token budget reached (~$TOTAL_TOKENS_LOADED tokens). Skipping remaining docs. -->"
        break
    fi

    # Parse file path and optional section
    if [[ "$doc_ref" == *"#"* ]]; then
        doc_file="${doc_ref%%#*}"
        section="${doc_ref##*#}"
    else
        doc_file="$doc_ref"
        section=""
    fi

    FULL_PATH="$DOCS_DIR/$doc_file"

    # Skip archived docs (they're preserved but not loaded)
    case "$doc_file" in
        archive/*|*/archive/*) continue ;;
    esac

    if [ -f "$FULL_PATH" ]; then
        DOCS_LOADED=$((DOCS_LOADED + 1))

        if [ -n "$section" ]; then
            # Section-level loading
            echo "<!-- Source: $doc_file#$section -->"
            echo "<doc path=\"docs/$doc_ref\">"

            # Extract the section
            section_output=$(extract_section "$FULL_PATH" "$section")
            section_lines=$(echo "$section_output" | tail -1)
            section_content=$(echo "$section_output" | head -n -1)

            if [ "$section_lines" -gt 0 ]; then
                echo "$section_content"
                add_tokens "$section_lines"
            else
                # Section not found, fall back to full file (truncated)
                echo "<!-- Section '$section' not found, loading file summary -->"
                head -n "$MAX_SECTION_LINES" "$FULL_PATH"
                add_tokens "$MAX_SECTION_LINES"
            fi

            echo "</doc>"
        else
            # Full file loading (with truncation)
            echo "<!-- Source: $doc_file -->"
            echo "<doc path=\"docs/$doc_file\">"

            LINE_COUNT=$(wc -l < "$FULL_PATH" | tr -d ' ')

            if [ "$LINE_COUNT" -le "$MAX_FILE_LINES" ]; then
                cat "$FULL_PATH"
                add_tokens "$LINE_COUNT"
            else
                head -n "$MAX_FILE_LINES" "$FULL_PATH"
                echo ""
                echo "<!-- Document truncated at $MAX_FILE_LINES lines. Full content: docs/$doc_file -->"
                add_tokens "$MAX_FILE_LINES"
            fi

            echo "</doc>"
        fi

        # Mark as loaded for session deduplication
        mark_as_loaded "$doc_ref"

        # Telemetry: track cache miss (doc loaded)
        if type emit_cache_miss &>/dev/null; then
            emit_cache_miss "$doc_ref"
        fi

        echo ""
    fi
done

echo "</auto-loaded-documentation>"
echo ""
echo "<!-- Loaded $DOCS_LOADED docs (~$TOTAL_TOKENS_LOADED tokens). For keyword lookups, see docs/GLOSSARY.md -->"
echo ""

# -----------------------------------------------------------------------------
# Telemetry: Emit final metrics
# -----------------------------------------------------------------------------
if type emit_docs_loaded &>/dev/null; then
    emit_docs_loaded "$DOCS_LOADED"
    emit_tokens_injected "$TOTAL_TOKENS_LOADED"
    emit_budget_status "$TOTAL_TOKENS_LOADED" "$MAX_TOTAL_TOKENS"
    telemetry_finish "success"
fi

exit 0
