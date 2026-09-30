#!/bin/bash
# =============================================================================
# SessionEnd Hook - Memex Documentation System
# =============================================================================
# Triggered when a Claude Code session ends.
#
# Archiving is OPT-IN and default OFF. Enable it explicitly with:
#     export MEMEX_ARCHIVE_WORKING=TRUE
# When enabled, this tars docs/working/ into ~/.memex/archives/<project>/ and
# then deletes the working files (keeping the last 20 archives per project).
# When NOT enabled, this hook is non-destructive: it touches no files and simply
# records a telemetry signal.
#
# Safety rules:
#   - Archive names are unique per run (session id + timestamp + pid + random),
#     so two sessions ending in the same second never overwrite each other.
#   - The archive is written to a temp name and renamed only after its listing
#     was verified against the files on disk. A partial archive is removed.
#   - Working files are deleted ONLY after that verification.
#   - `/clear` and `/resume` end the session but not the work: no archiving.
#
# The plugin sets a 10 s timeout for this hook in hooks/hooks.json (the
# SessionEnd budget is 1.5 s by default; Claude Code raises it to match the
# hook's timeout, up to 60 s).
# =============================================================================

# No blanket `set -e`: a failure mid-run must never abort archiving in a way
# that loses data. The destructive delete is gated on a verified tar.

LC_ALL=C
export LC_ALL

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
WORKING_DIR="$PROJECT_ROOT/docs/working"
PROJECT_NAME=$(basename "$PROJECT_ROOT")
PROJECT_TOKEN="$(printf '%s' "$PROJECT_NAME" | tr -c 'A-Za-z0-9_.-' '_' | cut -c1-64)"
[ -n "$PROJECT_TOKEN" ] || PROJECT_TOKEN="project"
ARCHIVE_DIR="$HOME/.memex/archives/$PROJECT_TOKEN"
KEEP_ARCHIVES=20

# -----------------------------------------------------------------------------
# Telemetry Integration (optional - uses Claude Code's OTel config)
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$SCRIPT_DIR/telemetry.sh" ]]; then
    source "$SCRIPT_DIR/telemetry.sh"
    telemetry_init "session_end"
fi

finish() {
    if type emit_session_end &>/dev/null; then
        emit_session_end "$PROJECT_NAME" "${2:-0}"
        telemetry_finish "$1"
    fi
    exit 0
}

# -----------------------------------------------------------------------------
# Read hook input (session id, end reason)
# -----------------------------------------------------------------------------
INPUT=$(cat 2>/dev/null)
REASON=""
SESSION_ID=""
if command -v jq >/dev/null 2>&1; then
    REASON=$(printf '%s' "$INPUT" | jq -r '.reason // empty' 2>/dev/null)
    SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
fi
SESSION_TOKEN="$(printf '%s' "${SESSION_ID:-nosession}" | tr -c 'A-Za-z0-9_-' '_' | cut -c1-32)"

# -----------------------------------------------------------------------------
# Opt-in gate: do nothing destructive unless MEMEX_ARCHIVE_WORKING=TRUE
# -----------------------------------------------------------------------------
if [ "${MEMEX_ARCHIVE_WORKING:-}" != "TRUE" ]; then
    finish "archive_disabled"
fi

# `/clear` and `/resume` end this session but the user keeps working in the
# same project, so the working notes must stay.
case "$REASON" in
    clear|resume) finish "skipped_$REASON" ;;
esac

# -----------------------------------------------------------------------------
# Check if working directory exists and has content
# -----------------------------------------------------------------------------
if [ ! -d "$WORKING_DIR" ] || [ -L "$WORKING_DIR" ]; then
    finish "no_working_dir"
fi

# Non-hidden regular files, sorted, one per line (used for the verification).
EXPECTED_LIST=$(cd "$WORKING_DIR" && find . -type f ! -path '*/.*' 2>/dev/null | sed 's#^\./##' | sort)
if [ -z "$EXPECTED_LIST" ]; then
    finish "empty_working_dir"
fi
FILE_COUNT=$(printf '%s\n' "$EXPECTED_LIST" | wc -l | tr -d ' ')

# -----------------------------------------------------------------------------
# Create archive directory if it doesn't exist (with secure permissions)
# -----------------------------------------------------------------------------
if ! mkdir -p "$ARCHIVE_DIR" 2>/dev/null; then
    echo "Error: Failed to create archive directory: $ARCHIVE_DIR" >&2
    exit 1
fi
chmod 700 "$HOME/.memex" "$HOME/.memex/archives" "$ARCHIVE_DIR" 2>/dev/null || {
    echo "Error: Failed to set permissions on archive directory" >&2
    exit 1
}

# -----------------------------------------------------------------------------
# Archive working documents
# -----------------------------------------------------------------------------
# Unique per run: timestamp + session id + pid + random suffix.
STAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE_NAME="session-${STAMP}-${SESSION_TOKEN}-$$-${RANDOM}${RANDOM}"
ARCHIVE_FILE="$ARCHIVE_DIR/${ARCHIVE_NAME}.tar.gz"
TMP_ARCHIVE="$ARCHIVE_DIR/.${ARCHIVE_NAME}.partial"

# Never reuse an existing name (noclobber create).
if ! ( set -C; : > "$TMP_ARCHIVE" ) 2>/dev/null || [ -e "$ARCHIVE_FILE" ]; then
    echo "Error: archive name collision for $ARCHIVE_FILE; working docs preserved." >&2
    rm -f "$TMP_ARCHIVE" 2>/dev/null
    finish "name_collision"
fi
# If we are cut off (timeout, signal) before the rename, drop the partial file.
trap 'rm -f "$TMP_ARCHIVE" 2>/dev/null' EXIT

echo "Archiving working documents..."
echo "  Source: $WORKING_DIR"
echo "  Archive: $ARCHIVE_FILE"

# Archive the explicit file list (NUL-separated, so spaces are safe). Do NOT use
# `tar --exclude='.*' .`: on bsdtar the `.*` pattern matches the `.` argument
# itself, so tar archives NOTHING and still exits 0.
TAR_EXIT_CODE=0
( cd "$WORKING_DIR" && find . -type f ! -path '*/.*' -print0 | tar -czf "$TMP_ARCHIVE" --null -T - ) 2>/dev/null || TAR_EXIT_CODE=$?

# Verify: the sorted archive listing must equal the sorted list on disk.
VERIFIED=0
if [ "$TAR_EXIT_CODE" -eq 0 ] && [ -s "$TMP_ARCHIVE" ]; then
    ARCHIVED_LIST=$(tar -tzf "$TMP_ARCHIVE" 2>/dev/null | sed 's#^\./##' | grep -v '/$' | sort)
    if [ "$ARCHIVED_LIST" = "$EXPECTED_LIST" ]; then
        VERIFIED=1
    fi
fi

if [ "$VERIFIED" -eq 1 ] && mv "$TMP_ARCHIVE" "$ARCHIVE_FILE" 2>/dev/null && [ -s "$ARCHIVE_FILE" ]; then
    trap - EXIT
    echo "  Archive created successfully ($FILE_COUNT file(s))."
    echo "Cleaning up working directory..."
    ( cd "$WORKING_DIR" && find . -type f ! -path '*/.*' -delete ) 2>/dev/null
    echo "  Working directory cleaned."
else
    echo "  Warning: archive verification failed (tar=$TAR_EXIT_CODE). Working docs preserved." >&2
    rm -f "$TMP_ARCHIVE" 2>/dev/null
    finish "verify_failed"
fi

# -----------------------------------------------------------------------------
# Manage archive retention (keep last N archives for this project)
# -----------------------------------------------------------------------------
ARCHIVE_COUNT=$(find "$ARCHIVE_DIR" -maxdepth 1 -name "*.tar.gz" -type f 2>/dev/null | wc -l | tr -d ' ')
if [ "$ARCHIVE_COUNT" -gt "$KEEP_ARCHIVES" ]; then
    echo "Managing archive retention..."
    # Names start with a sortable timestamp, so a plain sort orders by age.
    find "$ARCHIVE_DIR" -maxdepth 1 -name "*.tar.gz" -type f 2>/dev/null \
        | sort | head -n "$((ARCHIVE_COUNT - KEEP_ARCHIVES))" \
        | while IFS= read -r _old; do rm -f "$_old" 2>/dev/null; done
    echo "  Removed $((ARCHIVE_COUNT - KEEP_ARCHIVES)) old archive(s)."
fi

echo ""
echo "Session cleanup complete."

# Telemetry: emit session end metrics
if type emit_counter &>/dev/null; then
    emit_counter "memex.archive.created" 1 "{}"
fi
finish "success" "$FILE_COUNT"
