#!/bin/bash
# =============================================================================
# SessionStart Hook - Memex Documentation System
# =============================================================================
# Triggered when a Claude Code session begins (startup, resume, clear, compact,
# fork). Read-only: nothing here mutates the repo or the network.
#
# Behavior:
#   - Projects with no docs/ directory: silent (no context is added).
#   - startup / resume / fork with docs/: a short one- or two-line status.
#   - clear / compact: silent; clears this session's injection ledger so the
#     enricher can re-inject excerpts that compaction removed from context.
#   - Removes per-session cache directories older than 7 days.
#
# Updates to Memex itself are handled by `/plugin update` (plugin mode) or by
# re-running install.sh manually (installer mode). This hook intentionally does
# NOT fetch, pull, or execute any remote code on session start.
# =============================================================================

# No blanket `set -e`: this banner is purely informational and must never abort
# a session. Each command below tolerates its own failure (2>/dev/null || ...).

LC_ALL=C
export LC_ALL

# Resolve the script's own directory BEFORE changing directories, so telemetry
# sourcing works regardless of how the hook was invoked (relative or absolute).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"
cd "$PROJECT_ROOT" 2>/dev/null || true

PROJECT_NAME=$(basename "$PROJECT_ROOT")

# -----------------------------------------------------------------------------
# Telemetry Integration (optional - uses Claude Code's OTel config)
# -----------------------------------------------------------------------------
if [[ -f "$SCRIPT_DIR/telemetry.sh" ]]; then
    source "$SCRIPT_DIR/telemetry.sh"
    telemetry_init "session_start"
    emit_session_start
fi

finish() {
    if type telemetry_finish &>/dev/null; then
        telemetry_finish "$1"
    fi
    exit 0
}

# -----------------------------------------------------------------------------
# Read hook input (source, session id)
# -----------------------------------------------------------------------------
INPUT=$(cat 2>/dev/null)
SOURCE=""
SESSION_ID=""
if command -v jq >/dev/null 2>&1; then
    SOURCE=$(printf '%s' "$INPUT" | jq -r '.source // empty' 2>/dev/null)
    SESSION_ID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
fi

# -----------------------------------------------------------------------------
# Session cache housekeeping (same directory layout as context-enricher.sh)
# -----------------------------------------------------------------------------
USER_MEMEX_TMP="${TMPDIR:-/tmp}/memex-$(id -u)"
if [ -d "$USER_MEMEX_TMP" ] && [ ! -L "$USER_MEMEX_TMP" ]; then
    _owner="$(stat -f %u "$USER_MEMEX_TMP" 2>/dev/null || stat -c %u "$USER_MEMEX_TMP" 2>/dev/null)"
    if [ "$_owner" = "$(id -u)" ]; then
        # Drop stale per-session caches.
        find "$USER_MEMEX_TMP" -maxdepth 1 -name 'cache-*' -type d -mtime +7 -exec rm -rf {} + 2>/dev/null
        # After /clear or compaction the earlier injections are gone from the
        # conversation, so forget them and let the enricher inject again.
        case "$SOURCE" in
            clear|compact)
                if [ -n "$SESSION_ID" ]; then
                    _token="$(printf '%s' "$SESSION_ID" | tr -c 'A-Za-z0-9_-' '_' | cut -c1-64)"
                    rm -f "$USER_MEMEX_TMP/cache-$_token/injected" 2>/dev/null
                fi
                ;;
        esac
    fi
fi

# Only a fresh or resumed session gets a status line; clear/compact stay quiet.
case "$SOURCE" in
    ''|startup|resume|fork) ;;
    *) finish "silent_$SOURCE" ;;
esac

# Silent in projects that do not use Memex docs.
if [ ! -d "$PROJECT_ROOT/docs" ]; then
    finish "no_docs"
fi

# -----------------------------------------------------------------------------
# Short status (this is added to Claude's context, so keep it brief)
# -----------------------------------------------------------------------------
DOC_COUNT=$(find "$PROJECT_ROOT/docs" -name "*.md" -type f ! -path '*/docs/archive/*' ! -path '*/.*' 2>/dev/null | wc -l | tr -d ' ')
GLOSSARY_NOTE=""
[ -f "$PROJECT_ROOT/docs/GLOSSARY.md" ] && GLOSSARY_NOTE=", glossary pins on"

echo "Memex: lexical doc retrieval active for $PROJECT_NAME ($DOC_COUNT markdown files under docs/$GLOSSARY_NOTE). Relevant sections are injected per prompt; no manual loading needed."

WORKING_DIR="$PROJECT_ROOT/docs/working"
if [ -d "$WORKING_DIR" ]; then
    WORKING_COUNT=$(find "$WORKING_DIR" -type f ! -path '*/.*' 2>/dev/null | wc -l | tr -d ' ')
    if [ "${WORKING_COUNT:-0}" -gt 0 ]; then
        echo "Memex: $WORKING_COUNT working note(s) in docs/working/."
    fi
fi

finish "success"
