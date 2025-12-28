# Setup Claude Code OTEL telemetry to send to OpenObserve (Windows PowerShell)
# This script configures Claude Code CLI to export metrics and logs to OpenObserve
#
# Usage: .\setup-claude-otel.ps1 [-Test] [-Show] [-Uninstall]
#
# Parameters:
#   -Test       Test connection to OpenObserve
#   -Show       Show current configuration without modifying
#   -Uninstall  Remove OTEL configuration

[CmdletBinding()]
param(
    [switch]$Test,
    [switch]$Show,
    [switch]$Uninstall,
    [switch]$Help
)

# Configuration (can be overridden by environment variables)
$OpenObserveHost = if ($env:OPENOBSERVE_HOST) { $env:OPENOBSERVE_HOST } else { "localhost" }
$OpenObservePort = if ($env:OPENOBSERVE_PORT) { $env:OPENOBSERVE_PORT } else { "5080" }
$OpenObserveOrg = if ($env:OPENOBSERVE_ORG) { $env:OPENOBSERVE_ORG } else { "default" }
$OpenObserveUser = if ($env:OPENOBSERVE_USER) { $env:OPENOBSERVE_USER } else { "admin@archon.local" }
$OpenObservePassword = if ($env:OPENOBSERVE_PASSWORD) { $env:OPENOBSERVE_PASSWORD } else { "archon123" }

$ClaudeSettingsDir = Join-Path $env:USERPROFILE ".claude"
$ClaudeSettingsFile = Join-Path $ClaudeSettingsDir "settings.json"

function Write-Info { param($Message) Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-Success { param($Message) Write-Host "[OK] $Message" -ForegroundColor Green }
function Write-Warn { param($Message) Write-Host "[WARN] $Message" -ForegroundColor Yellow }
function Write-Err { param($Message) Write-Host "[ERROR] $Message" -ForegroundColor Red }

function Get-AuthHeader {
    $credentials = "${OpenObserveUser}:${OpenObservePassword}"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($credentials)
    $base64 = [System.Convert]::ToBase64String($bytes)
    return "Authorization=Basic $base64"
}

function Test-OpenObserveConnection {
    Write-Info "Testing connection to OpenObserve at ${OpenObserveHost}:${OpenObservePort}..."

    try {
        $credentials = "${OpenObserveUser}:${OpenObservePassword}"
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($credentials)
        $base64 = [System.Convert]::ToBase64String($bytes)

        $headers = @{
            Authorization = "Basic $base64"
        }

        $response = Invoke-WebRequest -Uri "http://${OpenObserveHost}:${OpenObservePort}/api/default/streams" `
            -Headers $headers `
            -Method Get `
            -UseBasicParsing `
            -TimeoutSec 5 `
            -ErrorAction Stop

        if ($response.StatusCode -eq 200) {
            Write-Success "OpenObserve is reachable and accepting connections"
            return $true
        }
    }
    catch {
        Write-Err "Cannot connect to OpenObserve at http://${OpenObserveHost}:${OpenObservePort}"
        Write-Warn "Make sure OpenObserve is running: docker ps | Select-String openobserve"
        Write-Warn "Error: $_"
        return $false
    }

    return $false
}

function Show-CurrentConfig {
    Write-Info "Current Claude Code settings:"

    if (Test-Path $ClaudeSettingsFile) {
        Write-Host ""
        $settings = Get-Content $ClaudeSettingsFile -Raw | ConvertFrom-Json
        if ($settings.env) {
            $settings.env | ConvertTo-Json -Depth 5
        }
        else {
            Write-Warn "No env section configured"
        }
    }
    else {
        Write-Warn "No settings file found at $ClaudeSettingsFile"
    }

    Write-Host ""
    Write-Info "OTEL-related environment variables:"
    Get-ChildItem env: | Where-Object { $_.Name -match "^(OTEL_|CLAUDE_CODE_)" } | Format-Table Name, Value
}

function Backup-Settings {
    if (Test-Path $ClaudeSettingsFile) {
        $timestamp = Get-Date -Format "yyyyMMddHHmmss"
        $backupFile = "${ClaudeSettingsFile}.backup.${timestamp}"
        Copy-Item $ClaudeSettingsFile $backupFile
        Write-Info "Backup created: $backupFile"
    }
}

function Install-ClaudeOtelConfig {
    Write-Info "Configuring Claude Code OTEL telemetry..."

    # Ensure directory exists
    if (-not (Test-Path $ClaudeSettingsDir)) {
        New-Item -ItemType Directory -Path $ClaudeSettingsDir -Force | Out-Null
    }

    # Generate endpoints
    $baseEndpoint = "http://${OpenObserveHost}:${OpenObservePort}/api/${OpenObserveOrg}"
    $metricsEndpoint = "${baseEndpoint}/v1/metrics"
    $logsEndpoint = "${baseEndpoint}/v1/logs"
    $authHeader = Get-AuthHeader

    # Create new env configuration
    $otelEnv = @{
        CLAUDE_CODE_ENABLE_TELEMETRY     = "1"
        OTEL_METRICS_EXPORTER            = "otlp"
        OTEL_LOGS_EXPORTER               = "otlp"
        OTEL_EXPORTER_OTLP_PROTOCOL      = "http/protobuf"
        OTEL_EXPORTER_OTLP_METRICS_ENDPOINT = $metricsEndpoint
        OTEL_EXPORTER_OTLP_LOGS_ENDPOINT = $logsEndpoint
        OTEL_EXPORTER_OTLP_HEADERS       = $authHeader
        OTEL_METRIC_EXPORT_INTERVAL      = "30000"
        OTEL_LOGS_EXPORT_INTERVAL        = "5000"
        OTEL_RESOURCE_ATTRIBUTES         = "service.name=claude-code,deployment.environment=development"
    }

    # Load or create settings
    $settings = @{}
    if (Test-Path $ClaudeSettingsFile) {
        Backup-Settings
        $settings = Get-Content $ClaudeSettingsFile -Raw | ConvertFrom-Json -AsHashtable
    }

    # Merge env settings
    if (-not $settings.ContainsKey("env")) {
        $settings["env"] = @{}
    }

    foreach ($key in $otelEnv.Keys) {
        $settings["env"][$key] = $otelEnv[$key]
    }

    # Write settings
    $settings | ConvertTo-Json -Depth 10 | Set-Content $ClaudeSettingsFile -Encoding UTF8
    Write-Success "Claude Code OTEL configuration written to $ClaudeSettingsFile"

    Write-Host ""
    Write-Info "Configuration summary:"
    Write-Host "  Metrics endpoint: $metricsEndpoint"
    Write-Host "  Logs endpoint:    $logsEndpoint"
    Write-Host "  Export interval:  30 seconds (metrics), 5 seconds (logs)"
    Write-Host ""
    Write-Info "Restart Claude Code for changes to take effect"
}

function Uninstall-ClaudeOtelConfig {
    Write-Info "Removing Claude Code OTEL configuration..."

    if (-not (Test-Path $ClaudeSettingsFile)) {
        Write-Warn "No settings file found"
        return
    }

    Backup-Settings

    $settings = Get-Content $ClaudeSettingsFile -Raw | ConvertFrom-Json -AsHashtable

    if ($settings.ContainsKey("env")) {
        $keysToRemove = @(
            "CLAUDE_CODE_ENABLE_TELEMETRY",
            "OTEL_METRICS_EXPORTER",
            "OTEL_LOGS_EXPORTER",
            "OTEL_EXPORTER_OTLP_PROTOCOL",
            "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT",
            "OTEL_EXPORTER_OTLP_LOGS_ENDPOINT",
            "OTEL_EXPORTER_OTLP_HEADERS",
            "OTEL_METRIC_EXPORT_INTERVAL",
            "OTEL_LOGS_EXPORT_INTERVAL",
            "OTEL_RESOURCE_ATTRIBUTES"
        )

        foreach ($key in $keysToRemove) {
            if ($settings["env"].ContainsKey($key)) {
                $settings["env"].Remove($key)
            }
        }

        $settings | ConvertTo-Json -Depth 10 | Set-Content $ClaudeSettingsFile -Encoding UTF8
        Write-Success "OTEL configuration removed"
    }
}

function Show-Help {
    Write-Host @"
Setup Claude Code OTEL Telemetry (Windows PowerShell)

Usage: .\setup-claude-otel.ps1 [-Test] [-Show] [-Uninstall]

Parameters:
  -Test       Test connection to OpenObserve
  -Show       Show current configuration
  -Uninstall  Remove OTEL configuration
  -Help       Show this help message

Environment Variables:
  OPENOBSERVE_HOST      OpenObserve hostname (default: localhost)
  OPENOBSERVE_PORT      OpenObserve port (default: 5080)
  OPENOBSERVE_ORG       OpenObserve organization (default: default)
  OPENOBSERVE_USER      OpenObserve username (default: admin@archon.local)
  OPENOBSERVE_PASSWORD  OpenObserve password (default: archon123)

Examples:
  .\setup-claude-otel.ps1                     # Install OTEL configuration
  .\setup-claude-otel.ps1 -Test               # Test OpenObserve connection
  `$env:OPENOBSERVE_HOST="192.168.1.100"; .\setup-claude-otel.ps1  # Use custom host
"@
}

# Main execution
if ($Help) {
    Show-Help
}
elseif ($Test) {
    Test-OpenObserveConnection | Out-Null
}
elseif ($Show) {
    Show-CurrentConfig
}
elseif ($Uninstall) {
    Uninstall-ClaudeOtelConfig
}
else {
    # Default: install
    $connected = Test-OpenObserveConnection
    if (-not $connected) {
        Write-Warn "OpenObserve not reachable, but configuring anyway..."
    }
    Install-ClaudeOtelConfig
}
