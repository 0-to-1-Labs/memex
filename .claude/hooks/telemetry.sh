#!/bin/bash
# =============================================================================
# Memex Telemetry - OpenTelemetry Export Helper
# =============================================================================
# Provides functions to emit metrics and events to an OpenTelemetry collector.
# Piggybacks on Claude Code's telemetry configuration for zero-config setup.
#
# Usage:
#   source "$(dirname "$0")/telemetry.sh"
#   telemetry_init "hook_name"
#   emit_counter "memex.docs.loaded" 5 '{"doc.name":"API.md"}'
#   telemetry_finish  # Emits hook duration and sends batch
#
# Environment Variables (shared with Claude Code):
#   CLAUDE_CODE_ENABLE_TELEMETRY=1  - Enable telemetry
#   OTEL_EXPORTER_OTLP_ENDPOINT     - Collector endpoint (e.g., http://localhost:4317)
#   OTEL_EXPORTER_OTLP_HEADERS      - Optional auth headers
#   OTEL_EXPORTER_OTLP_PROTOCOL     - Protocol: grpc, http/protobuf, http/json
# =============================================================================

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
MEMEX_SERVICE_NAME="memex"
MEMEX_SERVICE_VERSION="2.0.0"

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

    _TELEMETRY_ENABLED=1
    _TELEMETRY_ENDPOINT="${OTEL_EXPORTER_OTLP_ENDPOINT}"
    _TELEMETRY_HEADERS="${OTEL_EXPORTER_OTLP_HEADERS:-}"

    # Record start time for duration tracking (milliseconds)
    if command -v gdate &> /dev/null; then
        _TELEMETRY_START_TIME=$(gdate +%s%3N)
    elif date --version 2>/dev/null | grep -q GNU; then
        _TELEMETRY_START_TIME=$(date +%s%3N)
    else
        # macOS fallback: seconds only
        _TELEMETRY_START_TIME=$(($(date +%s) * 1000))
    fi

    # Initialize batch arrays
    _TELEMETRY_METRICS_BATCH=""
    _TELEMETRY_EVENTS_BATCH=""

    # Emit hook invocation counter
    emit_counter "memex.hook.invocations" 1 "{\"hook.name\":\"$hook_name\",\"hook.outcome\":\"started\"}"
}

# -----------------------------------------------------------------------------
# Check if telemetry is enabled
# -----------------------------------------------------------------------------
telemetry_enabled() {
    [[ "$_TELEMETRY_ENABLED" == "1" ]]
}

# -----------------------------------------------------------------------------
# Get current timestamp in nanoseconds (for OTLP)
# -----------------------------------------------------------------------------
_get_timestamp_nanos() {
    if command -v gdate &> /dev/null; then
        echo "$(gdate +%s%N)"
    elif date --version 2>/dev/null | grep -q GNU; then
        echo "$(date +%s%N)"
    else
        # macOS fallback
        echo "$(($(date +%s) * 1000000000))"
    fi
}

# -----------------------------------------------------------------------------
# Get current time in milliseconds
# -----------------------------------------------------------------------------
_get_time_ms() {
    if command -v gdate &> /dev/null; then
        gdate +%s%3N
    elif date --version 2>/dev/null | grep -q GNU; then
        date +%s%3N
    else
        echo "$(($(date +%s) * 1000))"
    fi
}

# -----------------------------------------------------------------------------
# Build resource attributes JSON
# -----------------------------------------------------------------------------
_build_resource_attributes() {
    cat <<EOF
{
  "attributes": [
    {"key": "service.name", "value": {"stringValue": "$MEMEX_SERVICE_NAME"}},
    {"key": "service.version", "value": {"stringValue": "$MEMEX_SERVICE_VERSION"}},
    {"key": "host.name", "value": {"stringValue": "$(hostname)"}},
    {"key": "os.type", "value": {"stringValue": "$(uname -s | tr '[:upper:]' '[:lower:]')"}},
    {"key": "process.pid", "value": {"intValue": "$$"}}
  ]
}
EOF
}

# -----------------------------------------------------------------------------
# Convert simple JSON attributes to OTLP attribute array
# Example: {"doc.name":"API.md","count":5} -> OTLP attributes array
# -----------------------------------------------------------------------------
_parse_attributes() {
    local attrs_json="${1:-{\}}"

    # Handle empty or missing attributes
    if [[ -z "$attrs_json" || "$attrs_json" == "{}" ]]; then
        echo "[]"
        return
    fi

    # Use jq if available for proper parsing
    if command -v jq &> /dev/null; then
        echo "$attrs_json" | jq -c '[to_entries[] | {key: .key, value: (if .value | type == "number" then {intValue: (.value | tostring)} elif .value | type == "boolean" then {boolValue: .value} else {stringValue: (.value | tostring)} end)}]' 2>/dev/null || echo "[]"
    else
        # Fallback: simple string attributes only
        echo "[]"
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
    local timestamp=$(_get_timestamp_nanos)
    local attrs_array=$(_parse_attributes "$attributes")

    local metric_json=$(cat <<EOF
{
  "name": "$name",
  "sum": {
    "dataPoints": [{
      "asInt": "$value",
      "timeUnixNano": "$timestamp",
      "attributes": $attrs_array
    }],
    "aggregationTemporality": 2,
    "isMonotonic": true
  }
}
EOF
)

    if [[ -n "$_TELEMETRY_METRICS_BATCH" ]]; then
        _TELEMETRY_METRICS_BATCH="$_TELEMETRY_METRICS_BATCH,$metric_json"
    else
        _TELEMETRY_METRICS_BATCH="$metric_json"
    fi
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
    local timestamp=$(_get_timestamp_nanos)
    local attrs_array=$(_parse_attributes "$attributes")

    local metric_json=$(cat <<EOF
{
  "name": "$name",
  "gauge": {
    "dataPoints": [{
      "asInt": "$value",
      "timeUnixNano": "$timestamp",
      "attributes": $attrs_array
    }]
  }
}
EOF
)

    if [[ -n "$_TELEMETRY_METRICS_BATCH" ]]; then
        _TELEMETRY_METRICS_BATCH="$_TELEMETRY_METRICS_BATCH,$metric_json"
    else
        _TELEMETRY_METRICS_BATCH="$metric_json"
    fi
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
    local timestamp=$(_get_timestamp_nanos)
    local attrs_array=$(_parse_attributes "$attributes")

    # Add event name to attributes
    local name_attr="{\"key\":\"event.name\",\"value\":{\"stringValue\":\"$name\"}}"
    if [[ "$attrs_array" == "[]" ]]; then
        attrs_array="[$name_attr]"
    else
        attrs_array=$(echo "$attrs_array" | sed "s/^\[/[$name_attr,/")
    fi

    local event_json=$(cat <<EOF
{
  "timeUnixNano": "$timestamp",
  "severityNumber": 9,
  "severityText": "INFO",
  "body": {"stringValue": "$body"},
  "attributes": $attrs_array
}
EOF
)

    if [[ -n "$_TELEMETRY_EVENTS_BATCH" ]]; then
        _TELEMETRY_EVENTS_BATCH="$_TELEMETRY_EVENTS_BATCH,$event_json"
    else
        _TELEMETRY_EVENTS_BATCH="$event_json"
    fi
}

# -----------------------------------------------------------------------------
# Finalize and send telemetry
# Emits hook duration and flushes all batched metrics/events
# -----------------------------------------------------------------------------
telemetry_finish() {
    local outcome="${1:-success}"

    telemetry_enabled || return 0

    # Calculate hook duration
    local end_time=$(_get_time_ms)
    local duration_ms=$((end_time - _TELEMETRY_START_TIME))

    # Emit duration as gauge and final invocation counter
    emit_gauge "memex.hook.duration_ms" "$duration_ms" "{\"hook.name\":\"$_TELEMETRY_HOOK_NAME\",\"hook.outcome\":\"$outcome\"}"
    emit_counter "memex.hook.invocations" 1 "{\"hook.name\":\"$_TELEMETRY_HOOK_NAME\",\"hook.outcome\":\"$outcome\"}"

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
    local resource=$(_build_resource_attributes)

    local payload=$(cat <<EOF
{
  "resourceMetrics": [{
    "resource": $resource,
    "scopeMetrics": [{
      "scope": {
        "name": "com.memex.hooks",
        "version": "$MEMEX_SERVICE_VERSION"
      },
      "metrics": [$_TELEMETRY_METRICS_BATCH]
    }]
  }]
}
EOF
)

    _send_to_collector "/v1/metrics" "$payload"
}

# -----------------------------------------------------------------------------
# Send batched events to OTLP endpoint
# -----------------------------------------------------------------------------
_send_events() {
    local resource=$(_build_resource_attributes)

    local payload=$(cat <<EOF
{
  "resourceLogs": [{
    "resource": $resource,
    "scopeLogs": [{
      "scope": {
        "name": "com.memex.hooks",
        "version": "$MEMEX_SERVICE_VERSION"
      },
      "logRecords": [$_TELEMETRY_EVENTS_BATCH]
    }]
  }]
}
EOF
)

    _send_to_collector "/v1/logs" "$payload"
}

# -----------------------------------------------------------------------------
# Send payload to OTLP collector via HTTP
# -----------------------------------------------------------------------------
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
        # Convert gRPC endpoint to HTTP
        url=$(echo "$url" | sed 's/:4317/:4318/')
    fi

    # Ensure URL has the path
    url="${url%/}${path}"

    # Build curl command
    local curl_opts=(-s -S --max-time 5)
    curl_opts+=(-X POST)
    curl_opts+=(-H "Content-Type: application/json")

    # Add auth headers if present
    if [[ -n "$_TELEMETRY_HEADERS" ]]; then
        # Parse headers (format: "Key1=Value1,Key2=Value2")
        IFS=',' read -ra HEADER_PAIRS <<< "$_TELEMETRY_HEADERS"
        for pair in "${HEADER_PAIRS[@]}"; do
            curl_opts+=(-H "${pair/=/:}")
        done
    fi

    # Send in background to not block the hook
    (curl "${curl_opts[@]}" -d "$payload" "$url" >/dev/null 2>&1 || true) &
}

# -----------------------------------------------------------------------------
# Convenience: Emit common memex metrics
# -----------------------------------------------------------------------------

# Emit docs loaded metric
emit_docs_loaded() {
    local count="$1"
    local attributes="${2:-{\}}"
    emit_counter "memex.docs.loaded" "$count" "$attributes"
}

# Emit tokens injected metric
emit_tokens_injected() {
    local tokens="$1"
    local attributes="${2:-{\}}"
    emit_counter "memex.tokens.injected" "$tokens" "$attributes"
}

# Emit cache hit (deduplication skip)
emit_cache_hit() {
    local doc_name="$1"
    emit_counter "memex.cache.hit" 1 "{\"doc.name\":\"$doc_name\"}"
}

# Emit cache miss (doc loaded)
emit_cache_miss() {
    local doc_name="$1"
    emit_counter "memex.cache.miss" 1 "{\"doc.name\":\"$doc_name\"}"
}

# Emit keyword match
# DEPRECATED: legacy glossary/keyword engine signal; use emit_term_match (lexical engine) instead.
emit_keyword_match() {
    local keyword="$1"
    local doc_name="$2"
    emit_counter "memex.keyword.matched" 1 "{\"keyword\":\"$keyword\",\"doc.name\":\"$doc_name\"}"
}

# Emit term-match (a search term that drove an injection in the lexical engine)
# The term may contain spaces (quoted phrases), quotes, or backslashes, so build the
# attributes JSON with jq when available to escape it safely; fall back to inline form.
emit_term_match() {
    local term="$1"
    local file_name="${2:-}"
    local attributes
    if command -v jq &> /dev/null; then
        attributes=$(jq -nc --arg term "$term" --arg file_name "$file_name" \
            '{"term": $term, "file.name": $file_name}' 2>/dev/null) \
            || attributes="{\"term\":\"$term\",\"file.name\":\"$file_name\"}"
    else
        attributes="{\"term\":\"$term\",\"file.name\":\"$file_name\"}"
    fi
    emit_counter "memex.term.matched" 1 "$attributes"
}

# Emit no-match prompt
emit_no_match() {
    emit_counter "memex.prompt.no_match" 1 "{}"
}

# Emit session start
emit_session_start() {
    local project_name="$1"
    emit_counter "memex.session.count" 1 "{\"project.name\":\"$project_name\"}"
    emit_event "memex.session.start" "Session started for $project_name" "{\"project.name\":\"$project_name\"}"
}

# Emit session end
emit_session_end() {
    local project_name="$1"
    local files_archived="${2:-0}"
    emit_event "memex.session.end" "Session ended" "{\"project.name\":\"$project_name\",\"files.archived\":$files_archived}"
}

# Emit validation warning
emit_validation_warning() {
    local warning_type="$1"
    local file_path="$2"
    local details="${3:-}"
    emit_counter "memex.validation.warning" 1 "{\"warning.type\":\"$warning_type\",\"file.path\":\"$file_path\"}"
    emit_event "memex.validation.warning" "$details" "{\"warning.type\":\"$warning_type\",\"file.path\":\"$file_path\"}"
}

# Emit budget status
emit_budget_status() {
    local tokens_used="$1"
    local budget_total="$2"
    local utilization=0
    # Avoid division by zero
    if [ "$budget_total" -gt 0 ]; then
        utilization=$((tokens_used * 100 / budget_total))
    fi
    emit_gauge "memex.tokens.budget.used" "$tokens_used" "{}"
    emit_gauge "memex.tokens.budget.utilization_percent" "$utilization" "{}"
}
