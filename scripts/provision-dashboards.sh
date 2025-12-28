#!/usr/bin/env bash
# Provision OpenObserve dashboards for Archon stack
# This script imports pre-built dashboards into OpenObserve
#
# Usage: ./provision-dashboards.sh [options]
# Options:
#   --list          List available dashboards
#   --import <name> Import a specific dashboard
#   --import-all    Import all dashboards
#   --delete <id>   Delete a dashboard by ID
#   --check         Check OpenObserve connectivity

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AEO_ARCHON_DIR="$(dirname "$SCRIPT_DIR")"
DASHBOARDS_DIR="${AEO_ARCHON_DIR}/dashboards"

# Default OpenObserve configuration
OPENOBSERVE_HOST="${OPENOBSERVE_HOST:-localhost}"
OPENOBSERVE_PORT="${OPENOBSERVE_PORT:-5080}"
OPENOBSERVE_ORG="${OPENOBSERVE_ORG:-default}"
OPENOBSERVE_USER="${OPENOBSERVE_USER:-admin@archon.local}"
OPENOBSERVE_PASSWORD="${OPENOBSERVE_PASSWORD:-archon123}"

# Source .env if exists
if [[ -f "${AEO_ARCHON_DIR}/.env" ]]; then
    # shellcheck disable=SC1091
    source "${AEO_ARCHON_DIR}/.env"
fi

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

get_base_url() {
    echo "http://${OPENOBSERVE_HOST}:${OPENOBSERVE_PORT}"
}

get_auth() {
    echo "-u ${OPENOBSERVE_USER}:${OPENOBSERVE_PASSWORD}"
}

check_connectivity() {
    log_info "Checking OpenObserve connectivity..."

    local base_url
    base_url=$(get_base_url)

    if curl -sf $(get_auth) "${base_url}/api/default/streams" -o /dev/null 2>/dev/null; then
        log_success "OpenObserve is reachable at ${base_url}"
        return 0
    else
        log_error "Cannot connect to OpenObserve at ${base_url}"
        log_warn "Make sure OpenObserve is running: docker ps | grep openobserve"
        return 1
    fi
}

list_dashboards() {
    log_info "Available dashboards in ${DASHBOARDS_DIR}:"
    echo ""

    if [[ ! -d "${DASHBOARDS_DIR}" ]]; then
        log_warn "Dashboards directory not found"
        return 1
    fi

    local count=0
    for file in "${DASHBOARDS_DIR}"/*.dashboard.json; do
        if [[ -f "$file" ]]; then
            local name
            name=$(basename "$file" .dashboard.json)
            local title
            title=$(jq -r '.title // "Untitled"' "$file" 2>/dev/null || echo "Unknown")
            local desc
            desc=$(jq -r '.description // "No description"' "$file" 2>/dev/null || echo "")

            echo "  ${GREEN}${name}${NC}"
            echo "    Title: ${title}"
            if [[ -n "$desc" && "$desc" != "No description" ]]; then
                echo "    Description: ${desc}"
            fi
            echo ""
            ((count++))
        fi
    done

    if [[ $count -eq 0 ]]; then
        log_warn "No dashboards found"
    else
        log_info "Found ${count} dashboard(s)"
    fi
}

list_remote_dashboards() {
    log_info "Dashboards in OpenObserve:"

    local base_url
    base_url=$(get_base_url)

    local response
    response=$(curl -sf $(get_auth) "${base_url}/api/${OPENOBSERVE_ORG}/dashboards" 2>/dev/null)

    if [[ -z "$response" ]]; then
        log_warn "No dashboards found or connection failed"
        return 1
    fi

    echo "$response" | jq -r '.dashboards[]? | "  ID: \(.dashboardId)\n    Title: \(.title)\n"' 2>/dev/null || \
        log_warn "Could not parse dashboard list"
}

import_dashboard() {
    local name="$1"
    local file="${DASHBOARDS_DIR}/${name}.dashboard.json"

    if [[ ! -f "$file" ]]; then
        log_error "Dashboard file not found: ${file}"
        return 1
    fi

    log_info "Importing dashboard: ${name}"

    local base_url
    base_url=$(get_base_url)

    # Read and modify the dashboard JSON (ensure unique ID)
    local dashboard_json
    dashboard_json=$(cat "$file")

    # Generate unique dashboard ID based on name and timestamp
    local new_id="${name}_$(date +%s)"
    dashboard_json=$(echo "$dashboard_json" | jq --arg id "$new_id" '.dashboardId = $id')

    local response
    local http_code

    # Create dashboard via API
    response=$(curl -sf -w "\n%{http_code}" \
        $(get_auth) \
        -H "Content-Type: application/json" \
        -X POST \
        -d "$dashboard_json" \
        "${base_url}/api/${OPENOBSERVE_ORG}/dashboards" 2>/dev/null) || true

    http_code=$(echo "$response" | tail -n1)
    response=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "200" || "$http_code" == "201" ]]; then
        log_success "Dashboard '${name}' imported successfully"
        log_info "Dashboard ID: ${new_id}"
        return 0
    else
        log_error "Failed to import dashboard (HTTP ${http_code})"
        if [[ -n "$response" ]]; then
            echo "$response" | jq . 2>/dev/null || echo "$response"
        fi
        return 1
    fi
}

import_all_dashboards() {
    log_info "Importing all dashboards..."

    if [[ ! -d "${DASHBOARDS_DIR}" ]]; then
        log_error "Dashboards directory not found: ${DASHBOARDS_DIR}"
        return 1
    fi

    local success=0
    local failed=0

    for file in "${DASHBOARDS_DIR}"/*.dashboard.json; do
        if [[ -f "$file" ]]; then
            local name
            name=$(basename "$file" .dashboard.json)

            if import_dashboard "$name"; then
                ((success++))
            else
                ((failed++))
            fi
        fi
    done

    echo ""
    log_info "Import complete: ${success} succeeded, ${failed} failed"
}

delete_dashboard() {
    local dashboard_id="$1"

    log_info "Deleting dashboard: ${dashboard_id}"

    local base_url
    base_url=$(get_base_url)

    # First get the dashboard to retrieve its hash
    local response
    response=$(curl -sf $(get_auth) "${base_url}/api/${OPENOBSERVE_ORG}/dashboards/${dashboard_id}" 2>/dev/null)

    if [[ -z "$response" ]]; then
        log_error "Dashboard not found: ${dashboard_id}"
        return 1
    fi

    local http_code
    response=$(curl -sf -w "\n%{http_code}" \
        $(get_auth) \
        -X DELETE \
        "${base_url}/api/${OPENOBSERVE_ORG}/dashboards/${dashboard_id}" 2>/dev/null) || true

    http_code=$(echo "$response" | tail -n1)

    if [[ "$http_code" == "200" || "$http_code" == "204" ]]; then
        log_success "Dashboard '${dashboard_id}' deleted"
        return 0
    else
        log_error "Failed to delete dashboard (HTTP ${http_code})"
        return 1
    fi
}

print_usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Options:"
    echo "  --check         Check OpenObserve connectivity"
    echo "  --list          List available local dashboards"
    echo "  --list-remote   List dashboards in OpenObserve"
    echo "  --import <name> Import a specific dashboard"
    echo "  --import-all    Import all dashboards"
    echo "  --delete <id>   Delete a dashboard by ID"
    echo "  --help          Show this help message"
    echo ""
    echo "Environment Variables:"
    echo "  OPENOBSERVE_HOST      OpenObserve hostname (default: localhost)"
    echo "  OPENOBSERVE_PORT      OpenObserve port (default: 5080)"
    echo "  OPENOBSERVE_ORG       OpenObserve organization (default: default)"
    echo "  OPENOBSERVE_USER      OpenObserve username"
    echo "  OPENOBSERVE_PASSWORD  OpenObserve password"
    echo ""
    echo "Examples:"
    echo "  $0 --list                  # List available dashboards"
    echo "  $0 --import archon-overview  # Import a specific dashboard"
    echo "  $0 --import-all            # Import all dashboards"
}

main() {
    case "${1:-}" in
        --check)
            check_connectivity
            ;;
        --list)
            list_dashboards
            ;;
        --list-remote)
            check_connectivity && list_remote_dashboards
            ;;
        --import)
            if [[ -z "${2:-}" ]]; then
                log_error "Dashboard name required"
                echo "Usage: $0 --import <dashboard-name>"
                exit 1
            fi
            check_connectivity && import_dashboard "$2"
            ;;
        --import-all)
            check_connectivity && import_all_dashboards
            ;;
        --delete)
            if [[ -z "${2:-}" ]]; then
                log_error "Dashboard ID required"
                echo "Usage: $0 --delete <dashboard-id>"
                exit 1
            fi
            check_connectivity && delete_dashboard "$2"
            ;;
        --help|-h)
            print_usage
            ;;
        "")
            print_usage
            ;;
        *)
            log_error "Unknown option: $1"
            print_usage
            exit 1
            ;;
    esac
}

main "$@"
