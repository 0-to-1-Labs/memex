#!/bin/bash
# =============================================================================
# SessionEnd Hook - Memex Documentation System
# =============================================================================
# Triggered when a Claude Code session ends.
#
# Archiving is OPT-IN and default OFF. Enable it explicitly with:
#     export MEMEX_ARCHIVE_WORKING=TRUE
# When enabled, this tars docs/working/ into ~/.memex/archives and then deletes
# the working files (keeping the last 20 archives). When NOT enabled, this hook
# is non-destructive: it touches no files and simply records a telemetry signal.
# =============================================================================

# No blanket `set -e`: a failure mid-run must never abort archiving in a way
# that loses data. The destructive delete is gated on a confirmed-successful tar.

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
# Opt-in gate: do nothing destructive unless MEMEX_ARCHIVE_WORKING=TRUE
# -----------------------------------------------------------------------------
if [ "${MEMEX_ARCHIVE_WORKING:-}" != "TRUE" ]; then
    if type emit_session_end &>/dev/null; then
        emit_session_end "$PROJECT_NAME" 0
        telemetry_finish "archive_disabled"
    fi
    exit 0
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

# Archive the non-hidden working files, then delete ONLY if the archive is
# verified to contain them.
#
# Do NOT use `tar -czf "$ARCHIVE_FILE" --exclude='.*' .`: on bsdtar (macOS
# default) the `.*` pattern matches the `.` path argument itself, so tar
# archives NOTHING and still exits 0 — which, combined with the delete below,
# silently destroys every working doc. Instead we archive an explicit file
# list and refuse to delete unless the archive holds at least as many files
# as we are about to remove.
FILE_COUNT=$(find "$WORKING_DIR" -type f ! -path '*/.*' 2>/dev/null | wc -l | tr -d ' ')

if [ "${FILE_COUNT:-0}" -eq 0 ]; then
    echo "  No working documents to archive."
else
    TAR_EXIT_CODE=0
    ( cd "$WORKING_DIR" && find . -type f ! -path '*/.*' -print0 | tar -czf "$ARCHIVE_FILE" --null -T - ) 2>/dev/null || TAR_EXIT_CODE=$?

    # Verify the archive actually contains the files BEFORE deleting anything.
    ARCHIVED_COUNT=0
    if [ "$TAR_EXIT_CODE" -eq 0 ] && [ -s "$ARCHIVE_FILE" ]; then
        ARCHIVED_COUNT=$(tar -tzf "$ARCHIVE_FILE" 2>/dev/null | wc -l | tr -d ' ')
    fi

    if [ "$TAR_EXIT_CODE" -eq 0 ] && [ "${ARCHIVED_COUNT:-0}" -ge "$FILE_COUNT" ] && [ "${ARCHIVED_COUNT:-0}" -gt 0 ]; then
        echo "  Archive created successfully ($ARCHIVED_COUNT file(s))."
        echo "Cleaning up working directory..."
        find "$WORKING_DIR" -type f ! -path '*/.*' -delete 2>/dev/null
        echo "  Working directory cleaned."
    else
        echo "  Warning: archive verification failed (tar=$TAR_EXIT_CODE, archived=${ARCHIVED_COUNT:-0}, expected=$FILE_COUNT). Working docs preserved." >&2
        rm -f "$ARCHIVE_FILE" 2>/dev/null || true
    fi
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
