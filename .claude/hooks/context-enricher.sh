#!/bin/bash
# =============================================================================
# UserPromptSubmit Hook - Context Enricher (Automated Lexical Retrieval Engine)
# =============================================================================
# Surfaces relevant context from the *actual repo* on every prompt, with zero
# setup. No hand-authored GLOSSARY.md required.
#
# Pipeline:
#   1. Read hook JSON from stdin; extract .prompt (CC) / .user_prompt (fallback)
#   2. Extract salient search terms (preserve identifiers & quoted phrases)
#   3. ripgrep (or grep fallback) those terms across the repo from PROJECT_ROOT
#      - respects .gitignore; excludes .git/node_modules/vendor/dist/archive/...
#   4. Rank candidate files by distinct-term hits + match density (+/- boosts)
#   5. For the top-N files, extract the densest matching window (section/anchor
#      for markdown, line-window for code), summing under a hard token budget
#   6. Emit JSON additionalContext wrapping <auto-context> excerpts + one scoped
#      nudge naming directories worth a deeper subagent search
#
# Design constraints (M2):
#   - NO blanket `set -e` (a non-zero in a substitution must not kill mid-output)
#   - bash 3.x safe: no associative arrays, no `head -n -1`, no mapfile/readarray
#   - jq required (graceful exit if absent); rg preferred, grep -rI fallback
#   - Read-only over the repo; never reads outside PROJECT_ROOT
#   - Deterministic output for a given repo+prompt (stable sort, no randomness)
#
# Modes:
#   - Plugin:    project root from $CLAUDE_PROJECT_DIR (set by Claude Code)
#   - Installer: same env var; falls back to current directory
# =============================================================================

# NOTE: intentionally NO `set -e`. We guard risky operations explicitly so that
# a non-zero exit inside a command substitution never aborts the hook before it
# has emitted its (possibly partial) output.

# -----------------------------------------------------------------------------
# Dependency Check
# -----------------------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
    echo "<!-- Memex: jq required but not found. Install with: brew install jq -->" >&2
    exit 0
fi

# Detect ripgrep once; fall back to grep -rI if absent.
HAVE_RG=0
if command -v rg >/dev/null 2>&1; then
    HAVE_RG=1
fi

PROJECT_ROOT="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# -----------------------------------------------------------------------------
# Telemetry Integration (optional - uses Claude Code's OTel config)
# -----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/telemetry.sh" ]; then
    # shellcheck source=/dev/null
    . "$SCRIPT_DIR/telemetry.sh"
    type telemetry_init >/dev/null 2>&1 && telemetry_init "user_prompt_submit"
fi

# -----------------------------------------------------------------------------
# Configuration (all overridable via env)
# -----------------------------------------------------------------------------
MAX_SECTION_LINES="${MAX_SECTION_LINES:-150}"   # Max lines per injected excerpt
MAX_TOTAL_TOKENS="${MAX_TOTAL_TOKENS:-10000}"   # Hard token budget
TOKENS_PER_LINE="${TOKENS_PER_LINE:-7}"         # Rough token-per-line estimate

MAX_FILES="${MAX_FILES:-4}"                      # Top-N files to inject (clamp 3-5)
[ "$MAX_FILES" -lt 3 ] 2>/dev/null && MAX_FILES=3
[ "$MAX_FILES" -gt 5 ] 2>/dev/null && MAX_FILES=5

MAX_TERMS=8                  # Cap on number of search terms (latency bound)
PER_TERM_MAX_COUNT=50        # rg/grep --max-count per term (latency bound)
MAX_CANDIDATE_FILES=200      # Ceiling on distinct files considered (latency bound)
MIN_SCORE_FLOOR=10           # Minimum score to inject (== matches >=1 term cleanly)

# -----------------------------------------------------------------------------
# Secure per-session temp dir (for cross-invocation dedup)
# -----------------------------------------------------------------------------
USER_MEMEX_TMP="${TMPDIR:-/tmp}/memex-$(id -u)"

if [ ! -d "$USER_MEMEX_TMP" ]; then
    mkdir -p "$USER_MEMEX_TMP" 2>/dev/null || {
        echo "<!-- Memex: failed to create temp directory -->" >&2
        exit 0
    }
fi
chmod 700 "$USER_MEMEX_TMP" 2>/dev/null || true

# Verify ownership before using (prevent symlink / shared-tmp attacks)
_owner="$(stat -f %u "$USER_MEMEX_TMP" 2>/dev/null || stat -c %u "$USER_MEMEX_TMP" 2>/dev/null)"
if [ "$_owner" != "$(id -u)" ]; then
    echo "<!-- Memex: temp directory ownership mismatch - skipping -->" >&2
    exit 0
fi

# -----------------------------------------------------------------------------
# Read & parse input
# -----------------------------------------------------------------------------
INPUT="$(cat)"

# CC sends .prompt; keep .user_prompt as a harmless fallback.
USER_PROMPT="$(printf '%s' "$INPUT" | jq -r '.prompt // .user_prompt // empty' 2>/dev/null)"
if [ -z "$USER_PROMPT" ]; then
    exit 0
fi

# Session id: prefer CC-provided session_id; otherwise PPID + parent start-time
# hash so a recycled PPID still yields a fresh dedup namespace (M2 fix).
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
if [ -z "$SESSION_ID" ]; then
    _pstart="$(ps -o lstart= -p "$PPID" 2>/dev/null)"
    _pstart_hash="$(printf '%s' "$_pstart" | cksum 2>/dev/null | awk '{print $1}')"
    SESSION_ID="ppid${PPID}-${_pstart_hash:-0}"
fi
# Sanitize session id into a safe filename token.
SESSION_TOKEN="$(printf '%s' "$SESSION_ID" | tr -c 'A-Za-z0-9_-' '_' | cut -c1-64)"

SESSION_CACHE_DIR="$USER_MEMEX_TMP/cache-$SESSION_TOKEN"
if [ ! -d "$SESSION_CACHE_DIR" ]; then
    mkdir -p "$SESSION_CACHE_DIR" 2>/dev/null || true
    chmod 700 "$SESSION_CACHE_DIR" 2>/dev/null || true
fi
# If the session cache dir could not be created, fall back to the user tmp dir
# directly so scratch files (matches/ranked) still have a writable home and the
# engine degrades gracefully instead of erroring out mid-pipeline.
if [ ! -d "$SESSION_CACHE_DIR" ]; then
    SESSION_CACHE_DIR="$USER_MEMEX_TMP"
fi
INJECTED_FILE="$SESSION_CACHE_DIR/injected"   # records "relpath:windowstart" entries

# =============================================================================
# TERM EXTRACTION  (.prompt -> ranked search terms)
# =============================================================================
# Strategy:
#   1. Pull out quoted "phrases" first (kept verbatim as multi-word terms).
#   2. From the remainder, keep identifier-shaped tokens whole: snake_case,
#      camelCase, kebab-case, dotted.paths -- these are the highest-signal terms.
#   3. Also split into plain words (lowercased), dropping stopwords / <3 chars.
#   4. De-dup, sort longest-first (most specific), cap at MAX_TERMS.
# -----------------------------------------------------------------------------

# Small, deliberately conservative stopword list.
STOPWORDS=" the and for are was were you your our their them they this that with \
from have has had not but can will would should could what when where which who \
why how does did doing done into out off over under about above below then than \
its it's i'm i've let lets get got use used using make made does dont don't \
the a an of to in on at by is be as or if it do we us me my so no yes all any \
some more most much many few how's here there now new old via per vs etc eg ie \
tell show find help need want know about explain describe give going want like \
just only also even still much such very too only one two also "

is_stopword() {
    case "$STOPWORDS" in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

# Collected terms, newline-separated in a temp accumulator (bash 3.x: no arrays
# of dynamic content needed; we use a string and dedup with grep -F).
TERMS_RAW=""

add_term() {
    local t="$1"
    # Trim surrounding whitespace.
    t="${t#"${t%%[![:space:]]*}"}"
    t="${t%"${t##*[![:space:]]}"}"
    [ -n "$t" ] || return 0
    # Length floor (3 chars) unless it is a multi-word quoted phrase.
    case "$t" in
        *" "*) : ;;                       # phrase: keep regardless of length
        *) [ "${#t}" -ge 3 ] || return 0 ;;
    esac
    TERMS_RAW="$TERMS_RAW
$t"
}

# --- 1. Extract quoted phrases (double-quoted) verbatim, lowercased. ---------
# We scan char-by-char-free using a sed that pulls out "...". Lowercase result.
_prompt_lc="$(printf '%s' "$USER_PROMPT" | tr '[:upper:]' '[:lower:]')"

# Pull double-quoted phrases. Guard: sed returns the whole line if no match, so
# we only accept lines that actually contained a quote.
_quoted="$(printf '%s\n' "$USER_PROMPT" \
    | grep -o '"[^"]*"' 2>/dev/null \
    | sed 's/^"//; s/"$//' \
    | tr '[:upper:]' '[:lower:]')"
if [ -n "$_quoted" ]; then
    while IFS= read -r _ph; do
        [ -n "$_ph" ] || continue
        add_term "$_ph"
    done <<EOF
$_quoted
EOF
fi

# Remainder of the prompt with quotes stripped, for token extraction.
_unquoted="$(printf '%s' "$_prompt_lc" | sed 's/"[^"]*"/ /g')"

# A UserPromptSubmit hook runs synchronously before the prompt is submitted, so
# term extraction must stay cheap even for a pathologically long prompt. We cap
# how many tokens we inspect; we only keep MAX_TERMS of them anyway.
SCAN_TOKEN_CAP="${MEMEX_SCAN_TOKEN_CAP:-200}"

# --- 2. Identifier-shaped tokens (kept whole). -------------------------------
# Tokens containing _, -, or . between word chars, or mixedCase. We grab any run
# of [A-Za-z0-9_.-] and decide per-token whether it is "identifier-shaped".
# Note: operate on the ORIGINAL-case unquoted text to detect camelCase, then
# lowercase the token we store (search is --ignore-case anyway).
_unquoted_origcase="$(printf '%s' "$USER_PROMPT" | sed 's/"[^"]*"/ /g')"

# Emit one candidate token per line: any maximal [A-Za-z0-9_.-]+ run (capped).
_tokens_idstyle="$(printf '%s' "$_unquoted_origcase" \
    | grep -oE '[A-Za-z0-9][A-Za-z0-9_.-]*[A-Za-z0-9]|[A-Za-z0-9]' 2>/dev/null \
    | head -n "$SCAN_TOKEN_CAP")"

if [ -n "$_tokens_idstyle" ]; then
    while IFS= read -r _tok; do
        [ -n "$_tok" ] || continue
        # Identifier-shaped if it contains _, -, or . (internal), OR is mixedCase.
        # Use builtin `case` tests, not `grep` subprocesses -- the old per-token
        # `grep -q '[a-z]'` / `grep -q '[A-Z]'` pair was the main latency source.
        _is_identifier=0
        case "$_tok" in
            *_*|*-*|*.*) _is_identifier=1 ;;
        esac
        if [ "$_is_identifier" -eq 0 ]; then
            # camelCase: has both a lowercase and an uppercase letter.
            _has_lower=0; _has_upper=0
            case "$_tok" in *[a-z]*) _has_lower=1 ;; esac
            case "$_tok" in *[A-Z]*) _has_upper=1 ;; esac
            [ "$_has_lower" -eq 1 ] && [ "$_has_upper" -eq 1 ] && _is_identifier=1
        fi
        if [ "$_is_identifier" -eq 1 ]; then
            _tok_lc="$(printf '%s' "$_tok" | tr '[:upper:]' '[:lower:]')"
            # Strip a stray leading/trailing . - _ that aren't part of the ident.
            _tok_lc="${_tok_lc#[._-]}"
            _tok_lc="${_tok_lc%[._-]}"
            [ "${#_tok_lc}" -ge 3 ] && add_term "$_tok_lc"
        fi
    done <<EOF
$_tokens_idstyle
EOF
fi

# --- 3. Plain words (lowercased, stopword/length filtered). ------------------
# Also bounded by SCAN_TOKEN_CAP so a huge prompt can't stall the loop.
_words="$(printf '%s' "$_unquoted" | tr -c 'a-z0-9' ' ' )"
_wscan=0
for _w in $_words; do
    _wscan=$((_wscan + 1)); [ "$_wscan" -gt "$SCAN_TOKEN_CAP" ] && break
    [ "${#_w}" -ge 3 ] || continue
    is_stopword "$_w" && continue
    add_term "$_w"
done

# --- 4. De-duplicate, sort longest-first, cap at MAX_TERMS. -------------------
# Build a stable, deduped, length-desc list.
TERMS="$(printf '%s\n' "$TERMS_RAW" \
    | grep -v '^[[:space:]]*$' \
    | awk '!seen[$0]++' \
    | awk '{ print length, $0 }' \
    | sort -k1,1nr -s \
    | sed 's/^[0-9][0-9]* //' \
    | head -n "$MAX_TERMS")"

if [ -z "$TERMS" ]; then
    type emit_no_match >/dev/null 2>&1 && emit_no_match
    type telemetry_finish >/dev/null 2>&1 && telemetry_finish "no_match"
    exit 0
fi

# =============================================================================
# OPTIONAL GLOSSARY PINS  (demoted boost layer; engine works with no glossary)
# =============================================================================
# If docs/GLOSSARY.md exists, parse `- **keyword** -> `path`` bullets. When a
# keyword appears in the prompt, remember its path so we can BOOST/PIN that file
# into the candidate set. Purely additive.
GLOSSARY_PINS=""   # newline-separated relative paths to boost
GLOSSARY_FILE="$PROJECT_ROOT/docs/GLOSSARY.md"
if [ -f "$GLOSSARY_FILE" ]; then
    # Space-padded, punctuation-normalized prompt for WORD-boundary keyword
    # matching, so `api` pins on "the api" but not inside "rapid"/"capital".
    _prompt_words=" $(printf '%s' "$_prompt_lc" | tr -c 'a-z0-9' ' ' | tr -s ' ') "
    while IFS= read -r _gline; do
        case "$_gline" in
            *'**'*'**'*'`'*'`'*) ;;
            *) continue ;;
        esac
        _gkw="${_gline#*\*\*}"; _gkw="${_gkw%%\*\**}"
        # Take the LAST backtick pair as the path: the keyword itself may be
        # backticked (e.g. `- **`code kw`** -> `docs/CODE.md``), so grabbing the
        # FIRST pair would capture the keyword instead of the path.
        _gpath="${_gline%\`*}"; _gpath="${_gpath##*\`}"
        [ -n "$_gkw" ] && [ -n "$_gpath" ] || continue
        _gkw_norm="$(printf '%s' "$_gkw" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' ' ' | tr -s ' ')"
        _gkw_norm="${_gkw_norm# }"; _gkw_norm="${_gkw_norm% }"
        [ -n "$_gkw_norm" ] || continue
        case "$_prompt_words" in
            *" $_gkw_norm "*)
                GLOSSARY_PINS="$GLOSSARY_PINS
$_gpath"
                ;;
        esac
    done < "$GLOSSARY_FILE"
fi

# =============================================================================
# SEARCH  (one pass per term over the repo from PROJECT_ROOT)
# =============================================================================
# We accumulate match records into a temp file, one line per hit:
#     <relpath>\t<linenumber>\t<termindex>
# Then ranking/aggregation runs over that file.
# -----------------------------------------------------------------------------
MATCHES_FILE="$SESSION_CACHE_DIR/matches.$$"
: > "$MATCHES_FILE"

# Directories we never descend into. `.claude` is excluded so Memex never
# injects its own hooks/config (or the user's) as "context".
EXCLUDE_DIRS=".git node_modules vendor dist build target .next .claude"

# rg glob excludes (rg already honors .gitignore). We also exclude GLOSSARY.md
# itself -- it's the keyword-pin source, not content to inject.
RG_GLOBS=(
    --glob '!.git/**'
    --glob '!node_modules/**'
    --glob '!vendor/**'
    --glob '!dist/**'
    --glob '!build/**'
    --glob '!target/**'
    --glob '!.next/**'
    --glob '!.claude/**'
    --glob '!docs/archive/**'
    --glob '!**/GLOSSARY.md'
)

# grep --exclude-dir list, plus a filename exclude for GLOSSARY.md.
GREP_EXCLUDES=()
for _d in $EXCLUDE_DIRS; do
    GREP_EXCLUDES+=(--exclude-dir="$_d")
done
GREP_EXCLUDES+=(--exclude='GLOSSARY.md')

# Run one search for a literal term. Emits "relpath<TAB>lineno" lines, with
# relpath already relative to PROJECT_ROOT.
#
# We run inside a subshell cd'd to PROJECT_ROOT and search "." so that rg's
# exclude globs (which match paths relative to the search root) apply and so the
# emitted paths are already relative -- no fragile absolute-prefix stripping, and
# we never read outside PROJECT_ROOT. The subshell cd does not leak out.
#
# Wall-clock is bounded by per-term --max-count plus the candidate ceiling
# (macOS has no portable `timeout`, so we deliberately avoid depending on it).
search_term() {
    local term="$1"
    (
        cd "$PROJECT_ROOT" 2>/dev/null || exit 0
        if [ "$HAVE_RG" -eq 1 ]; then
            # --fixed-strings: treat the term literally (identifiers contain .).
            rg --line-number --no-heading --color never \
               --max-count "$PER_TERM_MAX_COUNT" --ignore-case --fixed-strings \
               "${RG_GLOBS[@]}" \
               -- "$term" . 2>/dev/null
        else
            grep -rIn --max-count="$PER_TERM_MAX_COUNT" --ignore-case -F \
                "${GREP_EXCLUDES[@]}" \
                -e "$term" . 2>/dev/null \
                | grep -v '/docs/archive/'
        fi
    ) | awk -F: 'NF>=2 { rel=$1; sub(/^\.\//,"",rel); print rel "\t" $2 }'
}

# Iterate terms (index gives each term a stable id for distinct-term counting).
TERM_INDEX=0
TERM_LIST=""   # newline list aligned with indices, for nudge reporting
while IFS= read -r _term; do
    [ -n "$_term" ] || continue
    TERM_INDEX=$((TERM_INDEX + 1))
    TERM_LIST="$TERM_LIST
$_term"
    # search_term already emits relpath<TAB>lineno; tag with this term's index.
    search_term "$_term" | while IFS="$(printf '\t')" read -r _rel _ln; do
        [ -n "$_rel" ] || continue
        printf '%s\t%s\t%s\n' "$_rel" "$_ln" "$TERM_INDEX" >> "$MATCHES_FILE"
    done
done <<EOF
$TERMS
EOF

# If no matches at all, bail (unless glossary pins exist -> still consider them).
if [ ! -s "$MATCHES_FILE" ] && [ -z "$GLOSSARY_PINS" ]; then
    rm -f "$MATCHES_FILE" 2>/dev/null
    type emit_no_match >/dev/null 2>&1 && emit_no_match
    type telemetry_finish >/dev/null 2>&1 && telemetry_finish "no_match"
    exit 0
fi

# =============================================================================
# RANK  (score each candidate file)
# =============================================================================
# score = (#distinct terms matched) * 10
#       + min(total match count, 30)
#       + 5 if path under docs/ or a common source extension
#       - 5 if path looks like test/spec/fixture/mock/__snapshots__
# A stable sort (score desc, then path asc) gives deterministic output.
#
# We compute per-file aggregates in awk for speed, then apply boosts/penalties
# and the candidate ceiling.
# -----------------------------------------------------------------------------

# Per-file: distinct-term-count and total-count, plus a sorted list of match
# line numbers (used later to find the densest window).
#
# RANKED format (one line per file):  <score>\t<relpath>\t<distinctterms>
RANKED_FILE="$SESSION_CACHE_DIR/ranked.$$"

awk -F'\t' -v floor="$MIN_SCORE_FLOOR" '
function basescore(   s){ return s }
{
    rel = $1; term = $3
    total[rel]++
    key = rel SUBSEP term
    if (!(key in seen)) { seen[key]=1; distinct[rel]++ }
}
END {
    for (rel in total) {
        d = distinct[rel]; t = total[rel]
        cappedt = (t > 30 ? 30 : t)
        score = d * 10 + cappedt

        # boost: docs/ or common source extension
        boost = 0
        if (rel ~ /(^|\/)docs\//) boost += 5
        if (rel ~ /\.(py|js|ts|tsx|jsx|go|rs|java|rb|sh|md|c|cc|cpp|h|hpp|php|swift|kt|scala|sql|yaml|yml|toml)$/) boost += 5

        # penalty: tests / fixtures / mocks
        pen = 0
        if (rel ~ /(test|spec|fixture|mock|__snapshots__)/) pen += 5

        score = score + boost - pen
        if (score < 1) score = 1
        printf "%d\t%s\t%d\n", score, rel, d
    }
}
' "$MATCHES_FILE" > "$RANKED_FILE" 2>/dev/null

# Apply glossary pins: bump any pinned path's score above the floor so it gets
# considered even if lexical ranking placed it low (or it had no lexical hit).
if [ -n "$GLOSSARY_PINS" ]; then
    while IFS= read -r _pin; do
        [ -n "$_pin" ] || continue
        _pin="${_pin#./}"
        # Existing line for this path?
        if grep -q "	$_pin	" "$RANKED_FILE" 2>/dev/null; then
            # Add a pin boost (+15) by rewriting that row.
            awk -F'\t' -v p="$_pin" 'BEGIN{OFS="\t"} $2==p{ $1=$1+15 } {print}' \
                "$RANKED_FILE" > "$RANKED_FILE.tmp" 2>/dev/null \
                && mv "$RANKED_FILE.tmp" "$RANKED_FILE"
        elif [ -f "$PROJECT_ROOT/$_pin" ]; then
            # Pin a file that had no lexical match: inject a synthetic candidate
            # at floor+1 so it clears the floor.
            printf '%d\t%s\t%d\n' "$((MIN_SCORE_FLOOR + 1))" "$_pin" 1 >> "$RANKED_FILE"
        fi
    done <<EOF
$GLOSSARY_PINS
EOF
fi

# Stable sort: score desc, then path asc. Apply score floor. Cap candidates.
# (head on the candidate ceiling bounds downstream work on huge repos.)
RANKED_SORTED="$(sort -t"$(printf '\t')" -k1,1nr -k2,2 "$RANKED_FILE" 2>/dev/null \
    | awk -F'\t' -v floor="$MIN_SCORE_FLOOR" '$1 >= floor' \
    | head -n "$MAX_CANDIDATE_FILES")"

rm -f "$RANKED_FILE" 2>/dev/null

if [ -z "$RANKED_SORTED" ]; then
    rm -f "$MATCHES_FILE" 2>/dev/null
    type emit_no_match >/dev/null 2>&1 && emit_no_match
    type telemetry_finish >/dev/null 2>&1 && telemetry_finish "no_match"
    exit 0
fi

# =============================================================================
# EXCERPT EXTRACTION HELPERS
# =============================================================================

# Find the densest cluster of match lines for a file: the window-start line that
# maximizes the number of match lines within [start, start+WIN-1].
# Reads sorted match line numbers on stdin, echoes the chosen window start line.
densest_window_start() {
    local win="$1"
    awk -v win="$win" '
    { lines[NR]=$1 }
    END {
        n = NR
        if (n == 0) { print 1; exit }
        best_start = lines[1]; best_count = 0
        for (i = 1; i <= n; i++) {
            s = lines[i]
            # count matches within [s, s+win-1]
            c = 0
            for (j = i; j <= n; j++) {
                if (lines[j] <= s + win - 1) c++; else break
            }
            if (c > best_count) { best_count = c; best_start = s }
        }
        print best_start
    }'
}

# Extract the enclosing markdown section for a given line (snap to nearest
# preceding `#`/`##`... header, end at next header of same-or-higher level).
# Bounded to MAX_SECTION_LINES.
#
# Emits the chosen START line as the FIRST line of stdout, then the section
# body. The caller strips the first line. (We avoid setting a global inside a
# command substitution -- that runs in a subshell and would not propagate.)
extract_md_section() {
    local file="$1"
    local target_line="$2"
    awk -v target="$target_line" -v maxlines="$MAX_SECTION_LINES" '
    function header_level(s) {
        if (match(s, /^#+/)) return RLENGTH
        return 0
    }
    {
        line[NR] = $0
        # Ignore `#` lines inside fenced code blocks (``` or ~~~): those are code
        # comments, not markdown headings. Track fence state as we scan.
        t = $0
        sub(/^[ \t]+/, "", t)
        if (t ~ /^(```|~~~)/) {
            in_fence = !in_fence
        } else if (!in_fence) {
            lvl = header_level($0)
            if (lvl > 0) { hdr_line[NR] = 1; hdr_lvl[NR] = lvl }
        }
    }
    END {
        n = NR
        # Find nearest header at or before target.
        start = 1; start_lvl = 0
        for (i = target; i >= 1; i--) {
            if (i in hdr_line) { start = i; start_lvl = hdr_lvl[i]; break }
        }
        # End at next header with level <= start_lvl (or EOF).
        end = n
        for (i = start + 1; i <= n; i++) {
            if ((i in hdr_line) && hdr_lvl[i] <= start_lvl && start_lvl > 0) { end = i - 1; break }
        }
        if (end - start + 1 > maxlines) end = start + maxlines - 1
        # First stdout line: the chosen start line number.
        print start
        for (i = start; i <= end && i <= n; i++) print line[i]
    }' "$file"
}

# Extract a plain line-window of MAX_SECTION_LINES around a start line.
extract_line_window() {
    local file="$1"
    local start="$2"
    local end=$((start + MAX_SECTION_LINES - 1))
    [ "$start" -lt 1 ] && start=1
    awk -v s="$start" -v e="$end" 'NR>=s && NR<=e' "$file"
}

# Session dedup helpers (key = relpath:windowstart).
already_injected() {
    [ -f "$INJECTED_FILE" ] || return 1
    grep -qxF "$1" "$INJECTED_FILE" 2>/dev/null
}
mark_injected() {
    printf '%s\n' "$1" >> "$INJECTED_FILE" 2>/dev/null
}

# =============================================================================
# BUILD EXCERPTS UNDER BUDGET
# =============================================================================
CONTEXT_BODY=""
TOTAL_TOKENS=0
FILES_INJECTED=0
TRUNCATED=0
INJECTED_DIRS=""        # for the scoped nudge
MATCHED_TERMS_OUT=""    # terms that actually drove an injection

append_body() { CONTEXT_BODY="$CONTEXT_BODY$1"; }

FILES_DONE=0
while IFS="$(printf '\t')" read -r _score _rel _dterms; do
    [ -n "$_rel" ] || continue
    [ "$FILES_DONE" -ge "$MAX_FILES" ] && break

    _abspath="$PROJECT_ROOT/$_rel"
    [ -f "$_abspath" ] || continue

    # Budget check before doing work.
    if [ "$TOTAL_TOKENS" -ge "$MAX_TOTAL_TOKENS" ]; then
        TRUNCATED=1
        break
    fi

    # Gather this file's match line numbers (sorted, unique).
    _match_lines="$(awk -F'\t' -v f="$_rel" '$1==f {print $2}' "$MATCHES_FILE" \
        | sort -n | awk '!seen[$0]++')"

    # Determine the window. For markdown, snap to enclosing section; else a
    # line-window centered on the densest match cluster.
    _win_start="$(printf '%s\n' "$_match_lines" | densest_window_start "$MAX_SECTION_LINES")"
    [ -n "$_win_start" ] || _win_start=1

    case "$_rel" in
        *.md|*.markdown)
            # extract_md_section emits START on its first line, body after.
            _raw="$(extract_md_section "$_abspath" "$_win_start")"
            _used_start="$(printf '%s\n' "$_raw" | head -n 1)"
            _excerpt="$(printf '%s\n' "$_raw" | sed '1d')"
            case "$_used_start" in
                ''|*[!0-9]*) _used_start=1 ;;
            esac
            ;;
        *)
            # Center the window on the densest cluster (back up a quarter window).
            _ws=$(( _win_start - MAX_SECTION_LINES / 4 ))
            [ "$_ws" -lt 1 ] && _ws=1
            _excerpt="$(extract_line_window "$_abspath" "$_ws")"
            _used_start="$_ws"
            ;;
    esac

    [ -n "$_excerpt" ] || continue

    # Per-session dedup by path + window start.
    _dedup_key="$_rel:$_used_start"
    if already_injected "$_dedup_key"; then
        continue
    fi

    # Line count + token estimate for this excerpt.
    _lines="$(printf '%s\n' "$_excerpt" | wc -l | tr -d ' ')"
    [ -n "$_lines" ] || _lines=0
    _tok=$(( _lines * TOKENS_PER_LINE ))

    # If adding this excerpt would blow the budget and we already injected at
    # least one file, stop (note truncation). If it's the first file, allow it
    # but it will be the only one.
    if [ $((TOTAL_TOKENS + _tok)) -gt "$MAX_TOTAL_TOKENS" ] && [ "$FILES_INJECTED" -gt 0 ]; then
        TRUNCATED=1
        break
    fi

    _end_line=$(( _used_start + _lines - 1 ))

    append_body "<!-- $_rel : lines $_used_start-$_end_line -->
$_excerpt
"
    TOTAL_TOKENS=$((TOTAL_TOKENS + _tok))
    FILES_INJECTED=$((FILES_INJECTED + 1))
    FILES_DONE=$((FILES_DONE + 1))
    mark_injected "$_dedup_key"

    # Track parent dir for the nudge.
    _dir="$(dirname "$_rel")"
    case "$_dir" in
        .|"") _dir="(root)" ;;
    esac
    case "
$INJECTED_DIRS
" in
        *"
$_dir
"*) : ;;
        *) INJECTED_DIRS="$INJECTED_DIRS
$_dir" ;;
    esac
done <<EOF
$RANKED_SORTED
EOF

# Determine which terms actually matched the injected files (for nudge + telemetry).
if [ "$FILES_INJECTED" -gt 0 ]; then
    # Collect injected relpaths from the body markers.
    _injected_rels="$(printf '%s\n' "$CONTEXT_BODY" \
        | sed -n 's/^<!-- \(.*\) : lines .*$/\1/p')"
    # For each term, did it match any injected file?
    _ti=0
    while IFS= read -r _t; do
        [ -n "$_t" ] || continue
        _ti=$((_ti + 1))
        # term index _ti corresponds to position in TERMS list
        :
    done <<EOF
$TERMS
EOF
    # Simpler: a term "drove" an injection if it appears in MATCHES_FILE for any
    # injected relpath. Build the matched-term set by index.
    _ti=0
    while IFS= read -r _t; do
        [ -n "$_t" ] || continue
        _ti=$((_ti + 1))
        # Does this term's index appear for an injected file?
        if printf '%s\n' "$_injected_rels" | while IFS= read -r _ir; do
                [ -n "$_ir" ] || continue
                if awk -F'\t' -v f="$_ir" -v ti="$_ti" '$1==f && $3==ti{found=1} END{exit found?0:1}' "$MATCHES_FILE"; then
                    exit 0
                fi
            done; then
            MATCHED_TERMS_OUT="$MATCHED_TERMS_OUT $_t"
        fi
    done <<EOF
$TERMS
EOF
fi

rm -f "$MATCHES_FILE" 2>/dev/null

# -----------------------------------------------------------------------------
# No-match: nothing cleared the budget/floor -> inject nothing.
# -----------------------------------------------------------------------------
if [ "$FILES_INJECTED" -eq 0 ]; then
    type emit_no_match >/dev/null 2>&1 && emit_no_match
    type telemetry_finish >/dev/null 2>&1 && telemetry_finish "no_match"
    exit 0
fi

# =============================================================================
# ASSEMBLE OUTPUT
# =============================================================================

# Build the comma-separated lists for the nudge.
_term_csv="$(printf '%s' "$MATCHED_TERMS_OUT" | tr -s ' ' | sed 's/^ //; s/ /, /g')"
[ -n "$_term_csv" ] || _term_csv="$(printf '%s\n' "$TERMS" | head -3 | tr '\n' ',' | sed 's/,$//; s/,/, /g')"

_dir_csv="$(printf '%s\n' "$INJECTED_DIRS" \
    | grep -v '^[[:space:]]*$' \
    | awk '!seen[$0]++' \
    | head -3 \
    | tr '\n' ',' | sed 's/,$//; s/,/, /g')"

_trunc_note=""
if [ "$TRUNCATED" -eq 1 ]; then
    _trunc_note="<!-- Memex: token budget (~$MAX_TOTAL_TOKENS) reached; remaining matches omitted. -->
"
fi

CONTEXT="<auto-context>
<!-- Memex auto-retrieved the densest matching excerpts from this repo (read-only, lexical). -->
${CONTEXT_BODY}${_trunc_note}<!-- Memex: matched on [${_term_csv}]. For deeper detail, search ${_dir_csv} via a subagent. -->
</auto-context>"

# -----------------------------------------------------------------------------
# Telemetry (success path)
# -----------------------------------------------------------------------------
if type emit_term_match >/dev/null 2>&1; then
    for _mt in $MATCHED_TERMS_OUT; do
        emit_term_match "$_mt"
    done
fi
type emit_docs_loaded >/dev/null 2>&1 && emit_docs_loaded "$FILES_INJECTED"
type emit_tokens_injected >/dev/null 2>&1 && emit_tokens_injected "$TOTAL_TOKENS"
type emit_budget_status >/dev/null 2>&1 && emit_budget_status "$TOTAL_TOKENS" "$MAX_TOTAL_TOKENS"

# -----------------------------------------------------------------------------
# Emit JSON additionalContext (built with jq for correct escaping). Fall back to
# raw stdout if jq fails for any reason -- never regress to "nothing" on a match.
# -----------------------------------------------------------------------------
JSON_OUT="$(jq -n --arg ctx "$CONTEXT" \
    '{hookSpecificOutput:{hookEventName:"UserPromptSubmit",additionalContext:$ctx}}' \
    2>/dev/null)"

if [ -n "$JSON_OUT" ]; then
    printf '%s\n' "$JSON_OUT"
else
    # Fallback: emit the raw block so the match is not lost.
    printf '%s\n' "$CONTEXT"
fi

type telemetry_finish >/dev/null 2>&1 && telemetry_finish "success"
exit 0
