#!/bin/bash
# =============================================================================
# SessionEnd Hook - Memex Documentation System
# =============================================================================
# Triggered when a Claude Code session ends.
# Archives working documents and cleans up the working directory.
# =============================================================================

set -e

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
WORKING_DIR="$PROJECT_ROOT/docs/working"
ARCHIVE_DIR="$HOME/.memex/archives"
PROJECT_NAME=$(basename "$PROJECT_ROOT")

# -----------------------------------------------------------------------------
# Telemetry Integration (optional - uses Claude Code's OTel config)
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/telemetry.sh" ]]; then
    source "$SCRIPT_DIR/telemetry.sh"
    telemetry_init "session_end"
fi

# -----------------------------------------------------------------------------
# Generate session ID (timestamp-based)
# -----------------------------------------------------------------------------
SESSION_ID="session-$(date +%Y%m%d-%H%M%S)"

# -----------------------------------------------------------------------------
# Check if working directory exists and has content
# -----------------------------------------------------------------------------
if [ ! -d "$WORKING_DIR" ]; then
    # Telemetry: session end with no working dir
    if type emit_session_end &>/dev/null; then
        emit_session_end "$PROJECT_NAME" 0
        telemetry_finish "no_working_dir"
    fi
    exit 0
fi

# Check if directory has any files (excluding .git* files)
FILES=$(ls -A "$WORKING_DIR" 2>/dev/null | grep -v "^\.git")
if [ -z "$FILES" ]; then
    # Telemetry: session end with empty working dir
    if type emit_session_end &>/dev/null; then
        emit_session_end "$PROJECT_NAME" 0
        telemetry_finish "empty_working_dir"
    fi
    exit 0
fi

# -----------------------------------------------------------------------------
# Create archive directory if it doesn't exist (with secure permissions)
# -----------------------------------------------------------------------------
if ! mkdir -p "$ARCHIVE_DIR" 2>/dev/null; then
    echo "Error: Failed to create archive directory: $ARCHIVE_DIR" >&2
    exit 1
fi
chmod 700 "$ARCHIVE_DIR" || {
    echo "Error: Failed to set permissions on archive directory" >&2
    exit 1
}

# -----------------------------------------------------------------------------
# Archive working documents
# -----------------------------------------------------------------------------
ARCHIVE_FILE="$ARCHIVE_DIR/${SESSION_ID}.tar.gz"

echo "Archiving working documents..."
echo "  Source: $WORKING_DIR"
echo "  Archive: $ARCHIVE_FILE"

# Create tar archive (excluding .git* files)
# Capture exit code immediately after tar command
cd "$WORKING_DIR"
TAR_EXIT_CODE=0
tar -czf "$ARCHIVE_FILE" --exclude='.*' . 2>/dev/null || TAR_EXIT_CODE=$?

if [ "$TAR_EXIT_CODE" -eq 0 ]; then
    echo "  Archive created successfully."

    # Count archived files
    FILE_COUNT=$(ls -1 "$WORKING_DIR" 2>/dev/null | grep -v "^\." | wc -l | tr -d ' ')
    echo "  Files archived: $FILE_COUNT"

    # -----------------------------------------------------------------------------
    # Clean up working directory (keep .git* files)
    # -----------------------------------------------------------------------------
    echo "Cleaning up working directory..."
    find "$WORKING_DIR" -type f ! -name ".*" -delete 2>/dev/null
    echo "  Working directory cleaned."
else
    echo "  Warning: Archive creation failed (exit code: $TAR_EXIT_CODE). Working docs preserved."
    # Remove potentially incomplete archive
    rm -f "$ARCHIVE_FILE" 2>/dev/null || true
fi

# -----------------------------------------------------------------------------
# Manage archive retention (keep last 20 archives)
# -----------------------------------------------------------------------------
# Use find instead of ls glob to avoid errors when no archives exist
ARCHIVE_COUNT=$(find "$ARCHIVE_DIR" -maxdepth 1 -name "*.tar.gz" -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$ARCHIVE_COUNT" -gt 20 ]; then
    echo "Managing archive retention..."
    # Use find with sort to get oldest files for removal
    find "$ARCHIVE_DIR" -maxdepth 1 -name "*.tar.gz" -type f -print0 2>/dev/null | \
        xargs -0 ls -1t 2>/dev/null | tail -n +21 | xargs rm -f 2>/dev/null || true
    REMOVED=$((ARCHIVE_COUNT - 20))
    echo "  Removed $REMOVED old archive(s)."
fi

echo ""
echo "Session cleanup complete."

# Telemetry: emit session end metrics
if type emit_session_end &>/dev/null; then
    emit_session_end "$PROJECT_NAME" "${FILE_COUNT:-0}"
    emit_counter "memex.archive.created" 1 "{\"session.id\":\"$SESSION_ID\"}"
    telemetry_finish "success"
fi

exit 0
