#!/usr/bin/env bash
# Setup Claude Code OTEL telemetry to send to OpenObserve
# This script configures Claude Code CLI to export metrics and logs to OpenObserve
#
# Usage: ./setup-claude-otel.sh [options]
# Options:
#   --test        Test connection to OpenObserve
#   --show        Show current configuration without modifying
#   --uninstall   Remove OTEL configuration

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AEO_ARCHON_DIR="$(dirname "$SCRIPT_DIR")"
CLAUDE_SETTINGS_DIR="${HOME}/.claude"
CLAUDE_SETTINGS_FILE="${CLAUDE_SETTINGS_DIR}/settings.json"

# Default OpenObserve configuration (can be overridden by environment)
OPENOBSERVE_HOST="${OPENOBSERVE_HOST:-localhost}"
OPENOBSERVE_PORT="${OPENOBSERVE_PORT:-5080}"
OPENOBSERVE_ORG="${OPENOBSERVE_ORG:-default}"
OPENOBSERVE_USER="${OPENOBSERVE_USER:-admin@archon.local}"
OPENOBSERVE_PASSWORD="${OPENOBSERVE_PASSWORD:-archon123}"

# Source .env if it exists
if [[ -f "${AEO_ARCHON_DIR}/.env" ]]; then
    # shellcheck disable=SC1091
    source "${AEO_ARCHON_DIR}/.env"
fi

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

generate_auth_header() {
    local auth_b64
    auth_b64=$(echo -n "${OPENOBSERVE_USER}:${OPENOBSERVE_PASSWORD}" | base64 -w 0 2>/dev/null || echo -n "${OPENOBSERVE_USER}:${OPENOBSERVE_PASSWORD}" | base64)
    echo "Authorization=Basic ${auth_b64}"
}

test_openobserve_connection() {
    log_info "Testing connection to OpenObserve at ${OPENOBSERVE_HOST}:${OPENOBSERVE_PORT}..."

    local auth_header
    auth_header=$(generate_auth_header)

    # Test the /api/default endpoint
    if curl -sf -o /dev/null -w "%{http_code}" \
        -H "${auth_header/=/: }" \
        "http://${OPENOBSERVE_HOST}:${OPENOBSERVE_PORT}/api/default/streams" 2>/dev/null | grep -q "200"; then
        log_success "OpenObserve is reachable and accepting connections"
        return 0
    else
        log_error "Cannot connect to OpenObserve at http://${OPENOBSERVE_HOST}:${OPENOBSERVE_PORT}"
        log_warn "Make sure OpenObserve is running: docker ps | grep openobserve"
        return 1
    fi
}

show_current_config() {
    log_info "Current Claude Code settings:"

    if [[ -f "${CLAUDE_SETTINGS_FILE}" ]]; then
        if command -v jq &>/dev/null; then
            echo ""
            jq '.env // "No env section configured"' "${CLAUDE_SETTINGS_FILE}"
        else
            log_warn "Install jq for prettier output"
            cat "${CLAUDE_SETTINGS_FILE}"
        fi
    else
        log_warn "No settings file found at ${CLAUDE_SETTINGS_FILE}"
    fi

    echo ""
    log_info "OTEL-related environment variables:"
    env | grep -E "^(OTEL_|CLAUDE_CODE_)" || log_warn "No OTEL environment variables set"
}

create_settings_backup() {
    if [[ -f "${CLAUDE_SETTINGS_FILE}" ]]; then
        local backup_file="${CLAUDE_SETTINGS_FILE}.backup.$(date +%Y%m%d%H%M%S)"
        cp "${CLAUDE_SETTINGS_FILE}" "${backup_file}"
        log_info "Backup created: ${backup_file}"
    fi
}

install_claude_otel_config() {
    log_info "Configuring Claude Code OTEL telemetry..."

    # Ensure directory exists
    mkdir -p "${CLAUDE_SETTINGS_DIR}"

    # Generate auth header
    local auth_header
    auth_header=$(generate_auth_header)

    # Build endpoint URLs
    local base_endpoint="http://${OPENOBSERVE_HOST}:${OPENOBSERVE_PORT}/api/${OPENOBSERVE_ORG}"
    local metrics_endpoint="${base_endpoint}/v1/metrics"
    local logs_endpoint="${base_endpoint}/v1/logs"

    # Create or update settings.json
    local temp_file
    temp_file=$(mktemp)

    if [[ -f "${CLAUDE_SETTINGS_FILE}" ]]; then
        create_settings_backup

        # Merge with existing settings
        if command -v jq &>/dev/null; then
            jq --arg metrics_endpoint "$metrics_endpoint" \
               --arg logs_endpoint "$logs_endpoint" \
               --arg auth_header "$auth_header" \
               '.env = (.env // {}) * {
                   "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
                   "OTEL_METRICS_EXPORTER": "otlp",
                   "OTEL_LOGS_EXPORTER": "otlp",
                   "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
                   "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT": $metrics_endpoint,
                   "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT": $logs_endpoint,
                   "OTEL_EXPORTER_OTLP_HEADERS": $auth_header,
                   "OTEL_METRIC_EXPORT_INTERVAL": "30000",
                   "OTEL_LOGS_EXPORT_INTERVAL": "5000",
                   "OTEL_RESOURCE_ATTRIBUTES": "service.name=claude-code,deployment.environment=development"
               }' "${CLAUDE_SETTINGS_FILE}" > "${temp_file}"
        else
            log_error "jq is required to modify existing settings.json"
            log_info "Install jq: sudo apt install jq"
            rm "${temp_file}"
            return 1
        fi
    else
        # Create new settings file
        cat > "${temp_file}" << EOF
{
  "env": {
    "CLAUDE_CODE_ENABLE_TELEMETRY": "1",
    "OTEL_METRICS_EXPORTER": "otlp",
    "OTEL_LOGS_EXPORTER": "otlp",
    "OTEL_EXPORTER_OTLP_PROTOCOL": "http/protobuf",
    "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT": "${metrics_endpoint}",
    "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT": "${logs_endpoint}",
    "OTEL_EXPORTER_OTLP_HEADERS": "${auth_header}",
    "OTEL_METRIC_EXPORT_INTERVAL": "30000",
    "OTEL_LOGS_EXPORT_INTERVAL": "5000",
    "OTEL_RESOURCE_ATTRIBUTES": "service.name=claude-code,deployment.environment=development"
  }
}
EOF
    fi

    mv "${temp_file}" "${CLAUDE_SETTINGS_FILE}"
    log_success "Claude Code OTEL configuration written to ${CLAUDE_SETTINGS_FILE}"

    echo ""
    log_info "Configuration summary:"
    echo "  Metrics endpoint: ${metrics_endpoint}"
    echo "  Logs endpoint:    ${logs_endpoint}"
    echo "  Export interval:  30 seconds (metrics), 5 seconds (logs)"
    echo ""
    log_info "Restart Claude Code for changes to take effect"
}

uninstall_claude_otel_config() {
    log_info "Removing Claude Code OTEL configuration..."

    if [[ ! -f "${CLAUDE_SETTINGS_FILE}" ]]; then
        log_warn "No settings file found"
        return 0
    fi

    create_settings_backup

    if command -v jq &>/dev/null; then
        local temp_file
        temp_file=$(mktemp)

        jq 'del(.env.CLAUDE_CODE_ENABLE_TELEMETRY,
                .env.OTEL_METRICS_EXPORTER,
                .env.OTEL_LOGS_EXPORTER,
                .env.OTEL_EXPORTER_OTLP_PROTOCOL,
                .env.OTEL_EXPORTER_OTLP_METRICS_ENDPOINT,
                .env.OTEL_EXPORTER_OTLP_LOGS_ENDPOINT,
                .env.OTEL_EXPORTER_OTLP_HEADERS,
                .env.OTEL_METRIC_EXPORT_INTERVAL,
                .env.OTEL_LOGS_EXPORT_INTERVAL,
                .env.OTEL_RESOURCE_ATTRIBUTES)' "${CLAUDE_SETTINGS_FILE}" > "${temp_file}"

        mv "${temp_file}" "${CLAUDE_SETTINGS_FILE}"
        log_success "OTEL configuration removed"
    else
        log_error "jq is required to safely remove settings"
        return 1
    fi
}

print_usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --test        Test connection to OpenObserve"
    echo "  --show        Show current configuration"
    echo "  --uninstall   Remove OTEL configuration"
    echo "  --help        Show this help message"
    echo ""
    echo "Environment Variables:"
    echo "  OPENOBSERVE_HOST      OpenObserve hostname (default: localhost)"
    echo "  OPENOBSERVE_PORT      OpenObserve port (default: 5080)"
    echo "  OPENOBSERVE_ORG       OpenObserve organization (default: default)"
    echo "  OPENOBSERVE_USER      OpenObserve username (default: admin@archon.local)"
    echo "  OPENOBSERVE_PASSWORD  OpenObserve password (default: archon123)"
    echo ""
    echo "Example:"
    echo "  $0                     # Install OTEL configuration"
    echo "  $0 --test              # Test OpenObserve connection"
    echo "  OPENOBSERVE_HOST=192.168.1.100 $0  # Use custom host"
}

main() {
    case "${1:-}" in
        --test)
            test_openobserve_connection
            ;;
        --show)
            show_current_config
            ;;
        --uninstall)
            uninstall_claude_otel_config
            ;;
        --help|-h)
            print_usage
            ;;
        "")
            # Default: install
            if test_openobserve_connection; then
                install_claude_otel_config
            else
                log_warn "OpenObserve not reachable, but configuring anyway..."
                install_claude_otel_config
            fi
            ;;
        *)
            log_error "Unknown option: $1"
            print_usage
            exit 1
            ;;
    esac
}

main "$@"
