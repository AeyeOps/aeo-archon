#!/usr/bin/env python3
"""
Archon System Diagnostics - Quick Triage Script

Automatically runs all diagnostic checks without parameters.
Add new diagnostic methods as needed.

Usage: python scripts/diagnose.py
"""

import json
import re
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime
from typing import Dict, List, Optional, Tuple


@dataclass
class DiagnosticResult:
    """Result of a diagnostic check"""
    check_name: str
    status: str  # "pass", "warn", "fail"
    message: str
    details: Optional[Dict] = None
    remedy: Optional[str] = None


class ArchonDiagnostics:
    """Diagnostic toolkit for Archon system"""

    def __init__(self):
        self.results: List[DiagnosticResult] = []

    def run_command(self, cmd: List[str]) -> Tuple[int, str, str]:
        """Run shell command and return exit code, stdout, stderr"""
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
            return result.returncode, result.stdout, result.stderr
        except subprocess.TimeoutExpired:
            return -1, "", "Command timed out"
        except Exception as e:
            return -1, "", str(e)

    def add_result(self, result: DiagnosticResult):
        """Add and immediately print diagnostic result"""
        self.results.append(result)
        icon = {"pass": "✓", "warn": "⚠", "fail": "✗"}[result.status]
        color = {"pass": "\033[32m", "warn": "\033[33m", "fail": "\033[31m"}[result.status]
        print(f"{color}{icon}\033[0m {result.check_name}: {result.message}")
        if result.remedy:
            print(f"   \033[33m→ {result.remedy}\033[0m")

    # ============================================================================
    # SECTION 1: Container Status
    # ============================================================================

    def check_container_status(self):
        """Check Docker container status"""
        code, stdout, stderr = self.run_command(
            ["docker", "ps", "-a", "--filter", "name=archon-", "--format", "{{json .}}"]
        )

        if code != 0:
            self.add_result(DiagnosticResult(
                check_name="Docker Status",
                status="fail",
                message="Docker not accessible",
                remedy="Ensure Docker daemon is running"
            ))
            return

        for line in stdout.strip().split('\n'):
            if not line:
                continue
            container = json.loads(line)
            name = container.get("Names", "unknown")
            status = container.get("Status", "unknown")

            if "unhealthy" in status.lower():
                self.add_result(DiagnosticResult(
                    check_name=f"Container: {name}",
                    status="fail",
                    message=f"Unhealthy: {status}",
                    remedy=f"docker logs {name} --tail 50"
                ))
            elif "up" in status.lower():
                self.add_result(DiagnosticResult(
                    check_name=f"Container: {name}",
                    status="pass",
                    message=f"Running: {status}"
                ))
            else:
                self.add_result(DiagnosticResult(
                    check_name=f"Container: {name}",
                    status="warn",
                    message=f"Status: {status}"
                ))

    # ============================================================================
    # SECTION 2: Environment Variables
    # ============================================================================

    def check_environment_variables(self):
        """Check critical environment variables"""
        checks = [
            ("archon-server", "SUPABASE_URL"),
            ("archon-server", "SUPABASE_SERVICE_KEY"),
            ("archon-server", "ARCHON_SERVER_PORT"),
        ]

        for service, var in checks:
            code, stdout, _ = self.run_command(
                ["docker", "exec", service, "printenv", var]
            )

            if code != 0 or not stdout.strip():
                self.add_result(DiagnosticResult(
                    check_name=f"EnvVar: {service}/{var}",
                    status="fail",
                    message="Not set or empty",
                    remedy="Check .env and docker-compose.yml"
                ))
            else:
                value = stdout.strip()
                if "KEY" in var or "SECRET" in var:
                    value = f"{value[:10]}...{value[-5:]}"
                self.add_result(DiagnosticResult(
                    check_name=f"EnvVar: {service}/{var}",
                    status="pass",
                    message=f"{value}"
                ))

    # ============================================================================
    # SECTION 3: Container Logs Analysis - THE KEY SECTION
    # ============================================================================

    def analyze_container_logs(self):
        """Analyze container logs for common errors - THIS IS WHERE WE FOUND THE ISSUE"""
        services = ["archon-server", "archon-mcp", "archon-ui"]

        for service in services:
            code, stdout, stderr = self.run_command(
                ["docker", "logs", service, "--tail", "100"]
            )

            if code != 0:
                continue

            logs = stdout + stderr

            # Error patterns that catch real issues
            error_patterns = {
                "ImportError": r"ImportError: cannot import name '(\w+)' from '([\w.]+)'",
                "ModuleNotFoundError": r"ModuleNotFoundError: No module named '([\w.]+)'",
                "Connection Refused": r"\[Errno 111\] Connection refused",
                "Traceback": r"Traceback \(most recent call last\):",
                "Startup Failed": r"(Application startup failed|ERROR:.*Application startup failed)",
                "Database Error": r"(postgres|supabase|database).*error",
            }

            for error_type, pattern in error_patterns.items():
                if re.search(pattern, logs, re.IGNORECASE | re.MULTILINE):
                    # Get context around error
                    lines = logs.split('\n')
                    for i, line in enumerate(lines):
                        if re.search(pattern, line, re.IGNORECASE):
                            context = '\n   '.join(lines[max(0, i-2):min(len(lines), i+5)])

                            self.add_result(DiagnosticResult(
                                check_name=f"Log Error: {service}/{error_type}",
                                status="fail",
                                message=f"Found in logs:\n   {context[:300]}...",
                                remedy=self._get_error_remedy(error_type)
                            ))
                            break

            # Check for successful startup
            if "started successfully" in logs.lower():
                self.add_result(DiagnosticResult(
                    check_name=f"Startup: {service}",
                    status="pass",
                    message="Started successfully"
                ))

    def _get_error_remedy(self, error_type: str) -> str:
        """Get remedy suggestion for error type"""
        remedies = {
            "ImportError": "Code change broke imports. Search codebase: grep -r 'from.*import.*OLDNAME' src/",
            "Connection Refused": "Check dependent services are running. Verify SUPABASE_URL points to correct host.",
            "ModuleNotFoundError": "Missing dependency. Rebuild: docker compose build",
            "Startup Failed": "Check main.py lifespan handler",
            "Database Error": "Verify Supabase is running: docker ps | grep supabase",
        }
        return remedies.get(error_type, "Check full logs for context")

    # ============================================================================
    # SECTION 4: Health Endpoints
    # ============================================================================

    def check_health_endpoints(self):
        """Check application health endpoints"""
        endpoints = [
            ("http://localhost:8181/health", "Archon Server"),
            ("http://localhost:3737", "Archon UI"),
        ]

        for url, name in endpoints:
            code, stdout, _ = self.run_command(
                ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}", url, "--max-time", "3"]
            )

            if code == 0 and stdout.strip() == "200":
                self.add_result(DiagnosticResult(
                    check_name=f"Health: {name}",
                    status="pass",
                    message=f"200 OK"
                ))
            else:
                self.add_result(DiagnosticResult(
                    check_name=f"Health: {name}",
                    status="fail",
                    message=f"Not responding ({stdout.strip()})",
                    remedy=f"curl -v {url} for details"
                ))

    # ============================================================================
    # SECTION 5: Resource Usage
    # ============================================================================

    def check_resource_usage(self):
        """Check container resource usage for anomalies"""
        code, stdout, _ = self.run_command(
            ["docker", "stats", "--no-stream", "--format", "{{json .}}", "archon-server"]
        )

        if code == 0:
            try:
                stats = json.loads(stdout)
                cpu = float(stats.get("CPUPerc", "0%").rstrip('%'))
                mem = stats.get("MemUsage", "unknown")

                if cpu > 80:
                    self.add_result(DiagnosticResult(
                        check_name="Resource: CPU",
                        status="warn",
                        message=f"High CPU: {cpu}%",
                        remedy="Check for deadlocks or infinite loops"
                    ))
                else:
                    self.add_result(DiagnosticResult(
                        check_name="Resource: CPU",
                        status="pass",
                        message=f"{cpu}%, Mem: {mem}"
                    ))
            except:
                pass

    # ============================================================================
    # SECTION 6: Network Connectivity
    # ============================================================================

    def check_network_connectivity(self):
        """Check if server can reach Supabase"""
        code, stdout, stderr = self.run_command([
            "docker", "exec", "archon-server", "python", "-c",
            "import os, httpx; "
            "url = os.getenv('SUPABASE_URL'); "
            "key = os.getenv('SUPABASE_SERVICE_KEY'); "
            "r = httpx.get(f'{url}/rest/v1/', headers={'apikey': key}, timeout=5.0); "
            "print(r.status_code)"
        ])

        if code == 0 and "200" in stdout:
            self.add_result(DiagnosticResult(
                check_name="Network: Supabase",
                status="pass",
                message="Connected"
            ))
        else:
            self.add_result(DiagnosticResult(
                check_name="Network: Supabase",
                status="fail",
                message="Cannot connect",
                remedy="Verify Supabase running and SUPABASE_URL is correct"
            ))

    # ============================================================================
    # Main Execution
    # ============================================================================

    def run_all_checks(self):
        """Run all diagnostic checks"""
        print(f"\n{'='*70}")
        print(f"  Archon System Diagnostics - {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
        print(f"{'='*70}\n")

        print("🔍 Checking containers...")
        self.check_container_status()

        print("\n🔍 Checking environment...")
        self.check_environment_variables()

        print("\n🔍 Analyzing logs (KEY: This finds hidden runtime errors)...")
        self.analyze_container_logs()

        print("\n🔍 Checking health endpoints...")
        self.check_health_endpoints()

        print("\n🔍 Checking resources...")
        self.check_resource_usage()

        print("\n🔍 Checking network...")
        self.check_network_connectivity()

        # Print summary
        self.print_summary()

    def print_summary(self):
        """Print diagnostic summary"""
        print(f"\n{'='*70}")
        print("  SUMMARY")
        print(f"{'='*70}\n")

        pass_count = sum(1 for r in self.results if r.status == "pass")
        warn_count = sum(1 for r in self.results if r.status == "warn")
        fail_count = sum(1 for r in self.results if r.status == "fail")

        print(f"  Total Checks: {len(self.results)}")
        print(f"  \033[32m✓ Pass: {pass_count}\033[0m")
        print(f"  \033[33m⚠ Warn: {warn_count}\033[0m")
        print(f"  \033[31m✗ Fail: {fail_count}\033[0m")

        if fail_count > 0:
            print(f"\n{'='*70}")
            print("  CRITICAL FAILURES (Fix these first!):")
            print(f"{'='*70}")
            for result in self.results:
                if result.status == "fail":
                    print(f"\n  \033[31m✗ {result.check_name}\033[0m")
                    if result.remedy:
                        print(f"    \033[33m→ {result.remedy}\033[0m")

        sys.exit(1 if fail_count > 0 else 0)


def main():
    diagnostics = ArchonDiagnostics()
    diagnostics.run_all_checks()


if __name__ == "__main__":
    main()
