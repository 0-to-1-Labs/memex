#!/bin/bash
# =============================================================================
# Memex Telemetry - OpenTelemetry Export Helper
# =============================================================================
# Provides functions to emit metrics and events to an OpenTelemetry collector.
# Piggybacks on Claude Code's telemetry configuration for zero-config setup.
# Telemetry is opt-in: nothing is sent unless BOTH variables below are set.
#
# What is sent: counts and durations only (hook name, outcome, number of docs,
# tokens, terms, files archived, warning type). No prompt text, no search
# terms, no file paths, no project name, no hostname.
#
# Usage:
#   source "$(dirname "$0")/telemetry.sh"
#   telemetry_init "hook_name"
#   emit_counter "memex.docs.loaded" 5 '{"hook.name":"x"}'
#   telemetry_finish  # Emits hook duration and sends batch
#
# Environment Variables (shared with Claude Code):
#   CLAUDE_CODE_ENABLE_TELEMETRY=1  - Enable telemetry
#   OTEL_EXPORTER_OTLP_ENDPOINT     - Collector endpoint (e.g., http://localhost:4318)
#   OTEL_EXPORTER_OTLP_HEADERS      - Optional auth headers
#   OTEL_EXPORTER_OTLP_PROTOCOL     - Protocol: grpc, http/protobuf, http/json
# =============================================================================

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
MEMEX_SERVICE_NAME="memex"
MEMEX_SERVICE_VERSION="2.0.0"   # keep in sync with .claude-plugin/plugin.json
MEMEX_CURL_MAX_TIME=2           # seconds; the send is detached, never awaited

# Telemetry state
_TELEMETRY_ENABLED=0
_TELEMETRY_ENDPOINT=""
_TELEMETRY_HEADERS=""
_TELEMETRY_HOOK_NAME=""
_TELEMETRY_START_TIME=0
_TELEMETRY_METRICS_BATCH=""
_TELEMETRY_EVENTS_BATCH=""

# -----------------------------------------------------------------------------
# Initialization
# -----------------------------------------------------------------------------
telemetry_init() {
    local hook_name="${1:-unknown}"
    _TELEMETRY_HOOK_NAME="$hook_name"

    # Check if telemetry is enabled (same env var as Claude Code)
    if [[ "${CLAUDE_CODE_ENABLE_TELEMETRY:-0}" != "1" ]]; then
        _TELEMETRY_ENABLED=0
        return 0
    fi

    # Check for OTLP endpoint
    if [[ -z "${OTEL_EXPORTER_OTLP_ENDPOINT:-}" ]]; then
        _TELEMETRY_ENABLED=0
        return 0
    fi

    # jq and curl are required to build and send payloads safely.
    if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
        _TELEMETRY_ENABLED=0
        return 0
    fi

    _TELEMETRY_ENABLED=1
    _TELEMETRY_ENDPOINT="${OTEL_EXPORTER_OTLP_ENDPOINT}"
    _TELEMETRY_HEADERS="${OTEL_EXPORTER_OTLP_HEADERS:-}"

    # Record start time for duration tracking (milliseconds)
    _TELEMETRY_START_TIME=$(_get_time_ms)

    # Initialize batch arrays
    _TELEMETRY_METRICS_BATCH=""
    _TELEMETRY_EVENTS_BATCH=""

    # Emit hook invocation counter
    emit_counter "memex.hook.invocations" 1 "$(_attrs hook.name "$hook_name" hook.outcome started)"
}

# -----------------------------------------------------------------------------
# Check if telemetry is enabled
# -----------------------------------------------------------------------------
telemetry_enabled() {
    [[ "$_TELEMETRY_ENABLED" == "1" ]]
}

# -----------------------------------------------------------------------------
# Build a small attributes object safely: _attrs key value [key value ...]
# Values are escaped by jq, so quotes and backslashes never break the payload.
# -----------------------------------------------------------------------------
_attrs() {
    local json="{}" k v
    while [ $# -ge 2 ]; do
        k="$1"; v="$2"; shift 2
        json=$(printf '%s' "$json" | jq -c --arg k "$k" --arg v "$v" '. + {($k): $v}' 2>/dev/null) || json="{}"
    done
    printf '%s' "$json"
}

# -----------------------------------------------------------------------------
# Get current timestamp in nanoseconds (for OTLP)
# -----------------------------------------------------------------------------
_get_timestamp_nanos() {
    if command -v gdate >/dev/null 2>&1; then
        gdate +%s%N
    elif date --version 2>/dev/null | grep -q GNU; then
        date +%s%N
    else
        # macOS fallback
        echo "$(($(date +%s) * 1000000000))"
    fi
}

# -----------------------------------------------------------------------------
# Get current time in milliseconds
# -----------------------------------------------------------------------------
_get_time_ms() {
    if command -v gdate >/dev/null 2>&1; then
        gdate +%s%3N
    elif date --version 2>/dev/null | grep -q GNU; then
        date +%s%3N
    else
        echo "$(($(date +%s) * 1000))"
    fi
}

# -----------------------------------------------------------------------------
# Build resource attributes JSON (no hostname: counts only)
# -----------------------------------------------------------------------------
_build_resource_attributes() {
    jq -nc --arg name "$MEMEX_SERVICE_NAME" --arg ver "$MEMEX_SERVICE_VERSION" \
        --arg os "$(uname -s | tr '[:upper:]' '[:lower:]')" --arg pid "$$" '
    {attributes: [
        {key: "service.name",    value: {stringValue: $name}},
        {key: "service.version", value: {stringValue: $ver}},
        {key: "os.type",         value: {stringValue: $os}},
        {key: "process.pid",     value: {intValue: $pid}}
    ]}' 2>/dev/null
}

# -----------------------------------------------------------------------------
# Convert simple JSON attributes to OTLP attribute array
# Example: {"hook.name":"x","count":5} -> OTLP attributes array
# -----------------------------------------------------------------------------
_parse_attributes() {
    local attrs_json="${1:-{\}}"

    # Handle empty or missing attributes
    if [[ -z "$attrs_json" || "$attrs_json" == "{}" ]]; then
        echo "[]"
        return
    fi

    printf '%s' "$attrs_json" | jq -c '[to_entries[] | {key: .key, value: (if .value | type == "number" then {intValue: (.value | tostring)} elif .value | type == "boolean" then {boolValue: .value} else {stringValue: (.value | tostring)} end)}]' 2>/dev/null || echo "[]"
}

# Append a JSON fragment to a comma-separated batch string.
_append_batch() {
    # $1 = batch variable name, $2 = fragment
    local cur
    eval "cur=\"\$$1\""
    if [[ -n "$cur" ]]; then
        eval "$1=\"\$cur,\$2\""
    else
        eval "$1=\"\$2\""
    fi
}

# -----------------------------------------------------------------------------
# Emit a counter metric (adds to batch)
# Usage: emit_counter "metric.name" value '{"attr":"value"}'
# -----------------------------------------------------------------------------
emit_counter() {
    telemetry_enabled || return 0

    local name="$1"
    local value="${2:-1}"
    local attributes="${3:-{\}}"
    local metric_json
    metric_json=$(jq -nc --arg name "$name" --arg value "$value" --arg ts "$(_get_timestamp_nanos)" \
        --argjson attrs "$(_parse_attributes "$attributes")" '
        {name: $name, sum: {dataPoints: [{asInt: $value, timeUnixNano: $ts, attributes: $attrs}],
                            aggregationTemporality: 2, isMonotonic: true}}' 2>/dev/null) || return 0
    _append_batch _TELEMETRY_METRICS_BATCH "$metric_json"
}

# -----------------------------------------------------------------------------
# Emit a gauge metric (adds to batch)
# Usage: emit_gauge "metric.name" value '{"attr":"value"}'
# -----------------------------------------------------------------------------
emit_gauge() {
    telemetry_enabled || return 0

    local name="$1"
    local value="${2:-0}"
    local attributes="${3:-{\}}"
    local metric_json
    metric_json=$(jq -nc --arg name "$name" --arg value "$value" --arg ts "$(_get_timestamp_nanos)" \
        --argjson attrs "$(_parse_attributes "$attributes")" '
        {name: $name, gauge: {dataPoints: [{asInt: $value, timeUnixNano: $ts, attributes: $attrs}]}}' 2>/dev/null) || return 0
    _append_batch _TELEMETRY_METRICS_BATCH "$metric_json"
}

# -----------------------------------------------------------------------------
# Emit an event/log (adds to batch)
# Usage: emit_event "event.name" "message" '{"attr":"value"}'
# -----------------------------------------------------------------------------
emit_event() {
    telemetry_enabled || return 0

    local name="$1"
    local body="${2:-}"
    local attributes="${3:-{\}}"
    local event_json
    event_json=$(jq -nc --arg name "$name" --arg body "$body" --arg ts "$(_get_timestamp_nanos)" \
        --argjson attrs "$(_parse_attributes "$attributes")" '
        {timeUnixNano: $ts, severityNumber: 9, severityText: "INFO",
         body: {stringValue: $body},
         attributes: ([{key: "event.name", value: {stringValue: $name}}] + $attrs)}' 2>/dev/null) || return 0
    _append_batch _TELEMETRY_EVENTS_BATCH "$event_json"
}

# -----------------------------------------------------------------------------
# Finalize and send telemetry
# Emits hook duration and flushes all batched metrics/events
# -----------------------------------------------------------------------------
telemetry_finish() {
    local outcome="${1:-success}"

    telemetry_enabled || return 0

    # Calculate hook duration
    local end_time duration_ms
    end_time=$(_get_time_ms)
    duration_ms=$((end_time - _TELEMETRY_START_TIME))

    # Emit duration as gauge and final invocation counter
    emit_gauge "memex.hook.duration_ms" "$duration_ms" "$(_attrs hook.name "$_TELEMETRY_HOOK_NAME" hook.outcome "$outcome")"
    emit_counter "memex.hook.invocations" 1 "$(_attrs hook.name "$_TELEMETRY_HOOK_NAME" hook.outcome "$outcome")"

    # Send metrics if we have any
    if [[ -n "$_TELEMETRY_METRICS_BATCH" ]]; then
        _send_metrics
    fi

    # Send events if we have any
    if [[ -n "$_TELEMETRY_EVENTS_BATCH" ]]; then
        _send_events
    fi
}

# -----------------------------------------------------------------------------
# Send batched metrics to OTLP endpoint
# -----------------------------------------------------------------------------
_send_metrics() {
    local resource payload
    resource=$(_build_resource_attributes)
    payload=$(cat <<EOF
{"resourceMetrics":[{"resource":$resource,"scopeMetrics":[{"scope":{"name":"com.memex.hooks","version":"$MEMEX_SERVICE_VERSION"},"metrics":[$_TELEMETRY_METRICS_BATCH]}]}]}
EOF
)
    _send_to_collector "/v1/metrics" "$payload"
}

# -----------------------------------------------------------------------------
# Send batched events to OTLP endpoint
# -----------------------------------------------------------------------------
_send_events() {
    local resource payload
    resource=$(_build_resource_attributes)
    payload=$(cat <<EOF
{"resourceLogs":[{"resource":$resource,"scopeLogs":[{"scope":{"name":"com.memex.hooks","version":"$MEMEX_SERVICE_VERSION"},"logRecords":[$_TELEMETRY_EVENTS_BATCH]}]}]}
EOF
)
    _send_to_collector "/v1/logs" "$payload"
}

# -----------------------------------------------------------------------------
# Send payload to OTLP collector via HTTP
# -----------------------------------------------------------------------------
# The send is fully detached: the subshell's stdin/stdout/stderr are redirected
# so it never holds the hook's stdout pipe open (Claude Code waits for EOF on
# that pipe). A collector that is down or slow therefore adds no latency to the
# hook; curl gives up after MEMEX_CURL_MAX_TIME seconds in the background.
_send_to_collector() {
    local path="$1"
    local payload="$2"

    # Determine endpoint URL
    local url="${_TELEMETRY_ENDPOINT}"

    # Handle protocol differences
    local protocol="${OTEL_EXPORTER_OTLP_PROTOCOL:-http/json}"

    # For gRPC endpoints, we need to use HTTP endpoint instead
    # Standard ports: gRPC=4317, HTTP=4318
    if [[ "$protocol" == "grpc" ]]; then
        url=$(printf '%s' "$url" | sed 's/:4317/:4318/')
    fi

    # Ensure URL has the path
    url="${url%/}${path}"

    # Build curl command
    local curl_opts=(-s -S --max-time "$MEMEX_CURL_MAX_TIME" -X POST -H "Content-Type: application/json")

    # Auth headers go through a private temp file (`-H @file`) so secrets never
    # appear on the process list. Format: "Key1=Value1,Key2=Value2".
    local header_file=""
    if [[ -n "$_TELEMETRY_HEADERS" ]]; then
        header_file=$(mktemp "${TMPDIR:-/tmp}/memex-hdr.XXXXXX" 2>/dev/null) || header_file=""
        if [[ -n "$header_file" ]]; then
            chmod 600 "$header_file" 2>/dev/null
            printf '%s' "$_TELEMETRY_HEADERS" | tr ',' '\n' | sed 's/=/: /' > "$header_file"
            curl_opts+=(-H "@$header_file")
        fi
    fi

    (
        curl "${curl_opts[@]}" -d "$payload" "$url" >/dev/null 2>&1 || true
        [[ -n "$header_file" ]] && rm -f "$header_file" 2>/dev/null
    ) >/dev/null 2>&1 </dev/null &
}

# -----------------------------------------------------------------------------
# Convenience: Emit common memex metrics (counts only)
# -----------------------------------------------------------------------------

# Emit docs loaded metric
emit_docs_loaded() {
    emit_counter "memex.docs.loaded" "${1:-0}" "{}"
}

# Emit tokens injected metric
emit_tokens_injected() {
    emit_counter "memex.tokens.injected" "${1:-0}" "{}"
}

# Emit the number of search terms that drove an injection (never the terms).
emit_terms_matched() {
    emit_counter "memex.terms.matched" "${1:-0}" "{}"
}

# Emit no-match prompt
emit_no_match() {
    emit_counter "memex.prompt.no_match" 1 "{}"
}

# Emit session start
emit_session_start() {
    emit_counter "memex.session.count" 1 "{}"
    emit_event "memex.session.start" "Session started" "{}"
}

# Emit session end
emit_session_end() {
    # $1 (project name) is accepted for call compatibility and not sent.
    local files_archived="${2:-0}"
    emit_event "memex.session.end" "Session ended" "$(_attrs files.archived "$files_archived")"
}

# Emit a doc edit (count only; the path is not sent)
emit_doc_edit() {
    emit_event "memex.doc.edited" "Documentation file modified" "{}"
    emit_counter "memex.doc.edits" 1 "{}"
}

# Emit validation warning (type only; the path is not sent)
emit_validation_warning() {
    local warning_type="$1"
    emit_counter "memex.validation.warning" 1 "$(_attrs warning.type "$warning_type")"
    emit_event "memex.validation.warning" "$warning_type" "$(_attrs warning.type "$warning_type")"
}

# Emit budget status
emit_budget_status() {
    local tokens_used="$1"
    local budget_total="$2"
    local utilization=0
    # Avoid division by zero
    if [ "$budget_total" -gt 0 ] 2>/dev/null; then
        utilization=$((tokens_used * 100 / budget_total))
    fi
    emit_gauge "memex.tokens.budget.used" "$tokens_used" "{}"
    emit_gauge "memex.tokens.budget.utilization_percent" "$utilization" "{}"
}
