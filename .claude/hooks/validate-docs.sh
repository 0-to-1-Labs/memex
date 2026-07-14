#!/bin/bash
# =============================================================================
# PostToolUse Hook - Documentation Validation
# =============================================================================
# Triggered after Write or Edit operations on docs/*.md files.
#
# Features:
# - Enforces 800-line file limit (warning)
# - Warns about 150-line section limit (warning)
# - Reminds about OPTIONAL glossary pins ONLY when docs/GLOSSARY.md already exists
#   (opt-in), and at most once per session. The lexical engine needs no glossary.
#
# Does NOT auto-edit - only provides reminders and warnings.
# =============================================================================

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

# Read the hook input from stdin (JSON format)
INPUT=$(cat)

# Extract tool name and file path using jq
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null)

# Exit early if not a docs file modification
if [ -z "$FILE_PATH" ]; then
    # Telemetry: finalize for non-file operation
    if type telemetry_finish &>/dev/null; then
        telemetry_finish "no_file_path"
    fi
    exit 0
fi

# Check if the file is in the docs directory
case "$FILE_PATH" in
    */docs/*.md)
        # Continue with validation
        ;;
    *)
        # Not a docs file, exit silently
        # Telemetry: finalize for non-docs file
        if type telemetry_finish &>/dev/null; then
            telemetry_finish "non_docs_file"
        fi
        exit 0
        ;;
esac

# Skip line counting for GLOSSARY.md (it's an index, naturally larger)
SKIP_LINE_CHECK=0
if [[ "$FILE_PATH" == *"GLOSSARY.md" ]]; then
    SKIP_LINE_CHECK=1
fi

# Extract the relative path for cleaner display
REL_PATH="${FILE_PATH#$PROJECT_ROOT/}"

# =============================================================================
# Line Count Validation
# =============================================================================
if [ "$SKIP_LINE_CHECK" -eq 0 ] && [ -f "$FILE_PATH" ]; then
    LINE_COUNT=$(wc -l < "$FILE_PATH" | tr -d ' ')

    if [ "$LINE_COUNT" -gt "$MAX_FILE_LINES" ]; then
        echo ""
        echo "=============================================="
        echo "  WARNING: DOCUMENT EXCEEDS LINE LIMIT"
        echo "=============================================="
        echo ""
        echo "File: $REL_PATH"
        echo "Lines: $LINE_COUNT (maximum: $MAX_FILE_LINES)"
        echo ""
        echo "Consider splitting this document into sub-documents:"
        echo "  - Use naming convention: CATEGORY_SUBCATEGORY.md"
        echo "  - Example: DATABASE.md -> DATABASE_SCHEMA.md, DATABASE_QUERIES.md"
        echo "  - Update GLOSSARY.md with new file references"
        echo ""
        echo "See docs/CONTRIBUTING.md for document size guidelines."
        echo "=============================================="
        echo ""

        # Telemetry: file size warning
        if type emit_validation_warning &>/dev/null; then
            emit_validation_warning "file_exceeds_limit" "$REL_PATH" "File has $LINE_COUNT lines (max: $MAX_FILE_LINES)"
        fi
    fi

    # Check for oversized sections
    LARGE_SECTIONS=""
    current_section=""
    section_lines=0
    section_header=""

    while IFS= read -r line; do
        # Check if this is a header line (## or ###)
        if [[ "$line" =~ ^(##[#]?)[[:space:]]+(.*) ]]; then
            # If we were tracking a section, check its size
            if [ -n "$current_section" ] && [ "$section_lines" -gt "$MAX_SECTION_LINES" ]; then
                LARGE_SECTIONS="$LARGE_SECTIONS\n  - $section_header ($section_lines lines)"
            fi
            # Start tracking new section
            current_section="$line"
            section_header="${BASH_REMATCH[2]}"
            section_lines=1
        elif [ -n "$current_section" ]; then
            section_lines=$((section_lines + 1))
        fi
    done < "$FILE_PATH"

    # Check the last section
    if [ -n "$current_section" ] && [ "$section_lines" -gt "$MAX_SECTION_LINES" ]; then
        LARGE_SECTIONS="$LARGE_SECTIONS\n  - $section_header ($section_lines lines)"
    fi

    if [ -n "$LARGE_SECTIONS" ]; then
        echo ""
        echo "=============================================="
        echo "  NOTE: LARGE SECTIONS DETECTED"
        echo "=============================================="
        echo ""
        echo "File: $REL_PATH"
        echo "Sections exceeding $MAX_SECTION_LINES lines:"
        echo -e "$LARGE_SECTIONS"
        echo ""
        echo "Consider:"
        echo "  - Breaking up large sections into subsections"
        echo "  - Moving detailed content to separate files"
        echo "  - Using anchor links for section-level loading"
        echo "=============================================="
        echo ""

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
if type emit_event &>/dev/null; then
    emit_event "memex.doc.edited" "Documentation file modified" "{\"file.path\":\"$REL_PATH\"}"
    emit_counter "memex.doc.edits" 1 "{\"file.path\":\"$REL_PATH\"}"
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

# Rate-limit to at most once per session via a marker in the secure user tmp dir.
if [ "$SHOW_REMINDER" -eq 1 ]; then
    REMINDER_DIR="${TMPDIR:-/tmp}/memex-$(id -u)"
    REMINDER_MARKER="$REMINDER_DIR/validate-reminder-shown"
    if [ -f "$REMINDER_MARKER" ]; then
        SHOW_REMINDER=0
    else
        mkdir -p "$REMINDER_DIR" 2>/dev/null && chmod 700 "$REMINDER_DIR" 2>/dev/null
        : > "$REMINDER_MARKER" 2>/dev/null
    fi
fi

if [ "$SHOW_REMINDER" -eq 1 ]; then
    echo ""
    echo "=============================================="
    echo "  OPTIONAL: GLOSSARY PINS"
    echo "=============================================="
    echo ""
    echo "File modified: $REL_PATH"
    echo ""
    echo "This project has a docs/GLOSSARY.md, so you can OPTIONALLY"
    echo "pin/boost this file for specific terms. Pins are a boost on top"
    echo "of automatic retrieval -- they are never required."
    echo ""
    echo "Optional pin format:"
    echo "  - **keyword** -> \`path/FILE.md#section\` - Description"
    echo ""
    echo "(Shown once per session.)"
    echo "=============================================="
    echo ""
fi

# Telemetry: finalize
if type telemetry_finish &>/dev/null; then
    telemetry_finish "success"
fi

exit 0
