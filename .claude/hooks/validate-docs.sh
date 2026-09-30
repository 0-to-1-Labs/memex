#!/bin/bash
# =============================================================================
# PostToolUse Hook - Documentation Validation
# =============================================================================
# Triggered after Write or Edit operations on docs/*.md files.
#
# Features:
# - Enforces 800-line file limit (warning)
# - Warns about 150-line section limit (warning; headings inside fenced code
#   blocks are ignored)
# - Reminds about OPTIONAL glossary pins ONLY when docs/GLOSSARY.md already exists
#   (opt-in), and at most once per session. The lexical engine needs no glossary.
#
# Output contract: PostToolUse plain stdout goes to the debug log only, so the
# result is returned as JSON `hookSpecificOutput.additionalContext`, which
# Claude Code injects as a system reminder. Nothing to say -> empty output.
#
# Does NOT auto-edit and never blocks - only provides reminders and warnings.
# =============================================================================

LC_ALL=C
export LC_ALL

# Configuration
MAX_FILE_LINES=800
MAX_SECTION_LINES=150
PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
GLOSSARY_PATH="$PROJECT_ROOT/docs/GLOSSARY.md"

# -----------------------------------------------------------------------------
# Telemetry Integration (optional - uses Claude Code's OTel config)
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/telemetry.sh" ]]; then
    source "$SCRIPT_DIR/telemetry.sh"
    telemetry_init "post_tool_use"
fi

finish() {
    if type telemetry_finish &>/dev/null; then
        telemetry_finish "$1"
    fi
    exit 0
}

# jq is required both to read the input and to emit the JSON result.
if ! command -v jq >/dev/null 2>&1; then
    exit 0
fi

# Read the hook input from stdin (JSON format)
INPUT=$(cat)

# Extract file path and session id using jq
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)

# Exit early if not a file modification
if [ -z "$FILE_PATH" ]; then
    finish "no_file_path"
fi

# Check if the file is in the docs directory
case "$FILE_PATH" in
    */docs/*.md) ;;
    *) finish "non_docs_file" ;;
esac

# Skip line counting for GLOSSARY.md (it's an index, naturally larger)
SKIP_LINE_CHECK=0
if [[ "$FILE_PATH" == *"GLOSSARY.md" ]]; then
    SKIP_LINE_CHECK=1
fi

# Extract the relative path for cleaner display
REL_PATH="${FILE_PATH#"$PROJECT_ROOT"/}"

# Accumulated message for Claude (empty means "say nothing").
MESSAGE=""
add_message() {
    if [ -n "$MESSAGE" ]; then
        MESSAGE="$MESSAGE
$1"
    else
        MESSAGE="$1"
    fi
}

# =============================================================================
# Line Count Validation
# =============================================================================
if [ "$SKIP_LINE_CHECK" -eq 0 ] && [ -f "$FILE_PATH" ]; then
    LINE_COUNT=$(wc -l < "$FILE_PATH" | tr -d ' ')

    if [ "$LINE_COUNT" -gt "$MAX_FILE_LINES" ]; then
        add_message "Memex: $REL_PATH has $LINE_COUNT lines (maximum $MAX_FILE_LINES). Split it into sub-documents named CATEGORY_SUBCATEGORY.md (for example DATABASE.md -> DATABASE_SCHEMA.md, DATABASE_QUERIES.md) and update docs/GLOSSARY.md. See docs/CONTRIBUTING.md for size guidelines."

        # Telemetry: file size warning
        if type emit_validation_warning &>/dev/null; then
            emit_validation_warning "file_exceeds_limit" "$REL_PATH" "File has $LINE_COUNT lines (max: $MAX_FILE_LINES)"
        fi
    fi

    # Oversized sections: `##`/`###` headings outside fenced code blocks. A
    # fence closes only on the same character with at least the opening length.
    LARGE_SECTIONS=$(awk -v maxlines="$MAX_SECTION_LINES" '
    function fence_run(t,   c, k) {
        c = substr(t, 1, 1)
        if (c != "`" && c != "~") return 0
        k = 0
        while (substr(t, k + 1, 1) == c) k++
        if (k < 3) return 0
        fc = c
        return k
    }
    function close_section() {
        if (cur != "" && count > maxlines) printf "  - %s (%d lines)\n", cur, count
    }
    {
        t = $0
        sub(/^[ \t]+/, "", t)
        k = fence_run(t)
        if (in_fence) {
            if (k > 0 && fc == fchar && k >= flen) {
                rest = substr(t, k + 1); sub(/[ \t]+$/, "", rest)
                if (rest == "") in_fence = 0
            }
            if (cur != "") count++
            next
        }
        if (k > 0) { in_fence = 1; fchar = fc; flen = k; if (cur != "") count++; next }
        if (match($0, /^##?#?[ \t]+/) && $0 ~ /^##/) {
            close_section()
            cur = substr($0, RLENGTH + 1)
            sub(/[ \t]+$/, "", cur)
            count = 1
            next
        }
        if (cur != "") count++
    }
    END { close_section() }
    ' "$FILE_PATH" 2>/dev/null)

    if [ -n "$LARGE_SECTIONS" ]; then
        add_message "Memex: sections in $REL_PATH exceed $MAX_SECTION_LINES lines:
$LARGE_SECTIONS
Break them into subsections or move detail into a separate file."

        # Telemetry: section size warning
        if type emit_validation_warning &>/dev/null; then
            emit_validation_warning "section_exceeds_limit" "$REL_PATH" "Large sections detected"
        fi
    fi
fi

# =============================================================================
# Optional Glossary Pins Reminder (conditional + rate-limited)
# =============================================================================
# The lexical retrieval engine works with zero glossary, so we never nag projects
# that don't use one. Only remind when the user has opted into pins by creating
# docs/GLOSSARY.md, and only once per session to avoid training the model to
# ignore the reminder. Skip the reminder when editing GLOSSARY.md itself.

# Telemetry: always record the doc edit regardless of whether we show a reminder
if type emit_doc_edit &>/dev/null; then
    emit_doc_edit "$REL_PATH"
fi

SHOW_REMINDER=1

# Don't remind on the glossary file itself.
if [[ "$FILE_PATH" == *"GLOSSARY.md" ]]; then
    SHOW_REMINDER=0
fi

# Only remind if the project opted into pins (a glossary already exists).
if [ "$SHOW_REMINDER" -eq 1 ] && [ ! -f "$GLOSSARY_PATH" ]; then
    SHOW_REMINDER=0
fi

# Rate-limit to at most once per session: the marker lives in the same
# per-session cache directory the context-enricher uses, under the owner-checked
# user temp dir (never a shared, unverified /tmp path).
if [ "$SHOW_REMINDER" -eq 1 ]; then
    USER_MEMEX_TMP="${TMPDIR:-/tmp}/memex-$(id -u)"
    mkdir -p "$USER_MEMEX_TMP" 2>/dev/null && chmod 700 "$USER_MEMEX_TMP" 2>/dev/null
    _owner="$(stat -f %u "$USER_MEMEX_TMP" 2>/dev/null || stat -c %u "$USER_MEMEX_TMP" 2>/dev/null)"
    if [ -L "$USER_MEMEX_TMP" ] || [ "$_owner" != "$(id -u)" ]; then
        SHOW_REMINDER=0
    else
        SESSION_TOKEN="$(printf '%s' "${SESSION_ID:-nosession}" | tr -c 'A-Za-z0-9_-' '_' | cut -c1-64)"
        REMINDER_DIR="$USER_MEMEX_TMP/cache-$SESSION_TOKEN"
        REMINDER_MARKER="$REMINDER_DIR/reminder-shown"
        if [ -e "$REMINDER_MARKER" ]; then
            SHOW_REMINDER=0
        else
            mkdir -p "$REMINDER_DIR" 2>/dev/null && chmod 700 "$REMINDER_DIR" 2>/dev/null
            if [ -L "$REMINDER_MARKER" ] || ! ( set -C; : > "$REMINDER_MARKER" ) 2>/dev/null; then
                SHOW_REMINDER=0
            fi
        fi
    fi
fi

if [ "$SHOW_REMINDER" -eq 1 ]; then
    add_message "Memex: this project has docs/GLOSSARY.md, so you can optionally pin $REL_PATH to specific terms with a bullet like: - **keyword** -> \`$REL_PATH#section\` - Description. Pins are a boost on top of automatic retrieval and are never required. (Shown once per session.)"
fi

# =============================================================================
# Emit result
# =============================================================================
if [ -n "$MESSAGE" ]; then
    jq -n --arg ctx "$MESSAGE" \
        '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$ctx}}' 2>/dev/null
fi

finish "success"
