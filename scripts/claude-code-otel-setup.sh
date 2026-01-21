#!/usr/bin/env bash
# Claude Code OpenTelemetry Integration for OpenObserve
#
# This script configures Claude Code to send telemetry (metrics, logs, events)
# to your local OpenObserve instance.
#
# Usage:
#   source scripts/claude-code-otel-setup.sh   # Add to current shell
#   # OR add to your shell profile (~/.bashrc, ~/.zshrc)
#
# Prerequisites:
#   - OpenObserve running (docker compose -f docker-compose.yml -f docker-compose.openobserve.yml up)
#   - Claude Code installed

set -euo pipefail

# OpenObserve Configuration (from .env)
OPENOBSERVE_HOST="${OPENOBSERVE_HOST:-localhost}"
OPENOBSERVE_PORT="${OPENOBSERVE_PORT:-5080}"
OPENOBSERVE_ORG="${OPENOBSERVE_ORG:-default}"
OPENOBSERVE_USER="${OPENOBSERVE_USER:-admin@archon.local}"
OPENOBSERVE_PASSWORD="${OPENOBSERVE_PASSWORD:-archon123}"

# Generate Basic Auth header
OPENOBSERVE_AUTH=$(echo -n "${OPENOBSERVE_USER}:${OPENOBSERVE_PASSWORD}" | base64)

# Claude Code OTEL Configuration
# ================================

# Enable Claude Code telemetry (required)
export CLAUDE_CODE_ENABLE_TELEMETRY=1

# OTLP Exporter Configuration
# OpenObserve uses http/protobuf on port 5080 with /api/{org} path
export OTEL_EXPORTER_OTLP_PROTOCOL=http/protobuf
export OTEL_EXPORTER_OTLP_ENDPOINT="http://${OPENOBSERVE_HOST}:${OPENOBSERVE_PORT}/api/${OPENOBSERVE_ORG}"
export OTEL_EXPORTER_OTLP_HEADERS="Authorization=Basic ${OPENOBSERVE_AUTH}"

# Enable metrics and logs export (Claude Code doesn't export traces by default)
export OTEL_METRICS_EXPORTER=otlp
export OTEL_LOGS_EXPORTER=otlp

# Export intervals (adjust for your needs)
# Default: 60s for metrics, 5s for logs
export OTEL_METRIC_EXPORT_INTERVAL=60000
export OTEL_LOGS_EXPORT_INTERVAL=5000

# Metrics cardinality control
export OTEL_METRICS_INCLUDE_SESSION_ID=true
export OTEL_METRICS_INCLUDE_VERSION=true
export OTEL_METRICS_INCLUDE_ACCOUNT_UUID=true

# Resource attributes for filtering in OpenObserve
export OTEL_RESOURCE_ATTRIBUTES="service.name=claude-code,deployment.environment=development,team.id=aeo"

# Optional: Enable user prompt logging (disabled by default for privacy)
# Uncomment to log full prompts (useful for debugging, not recommended for production)
# export OTEL_LOG_USER_PROMPTS=1

# Optional: Disable Anthropic's built-in telemetry while keeping OTEL
# Uncomment if you only want data going to OpenObserve
# export CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1

echo "Claude Code OTEL configured for OpenObserve"
echo "  Endpoint: ${OTEL_EXPORTER_OTLP_ENDPOINT}"
echo "  Protocol: ${OTEL_EXPORTER_OTLP_PROTOCOL}"
echo "  Exporters: metrics=${OTEL_METRICS_EXPORTER}, logs=${OTEL_LOGS_EXPORTER}"
echo ""
echo "Available metrics in OpenObserve:"
echo "  - claude_code.session.count"
echo "  - claude_code.lines_of_code.count"
echo "  - claude_code.pull_request.count"
echo "  - claude_code.commit.count"
echo "  - claude_code.cost.usage (USD)"
echo "  - claude_code.token.usage"
echo "  - claude_code.code_edit_tool.decision"
echo "  - claude_code.active_time.total (seconds)"
echo ""
echo "View in OpenObserve: http://${OPENOBSERVE_HOST}:${OPENOBSERVE_PORT}"
