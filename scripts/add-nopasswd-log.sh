#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo $0" >&2
  exit 1
fi

username="${SUDO_USER:-$(whoami)}"
sudoers_file="/etc/sudoers.d/aeo-archon-log"

tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT

# Build a clean, validated sudoers drop-in (rewrite to fix any prior corruption)
cat > "$tmp_file" <<EOF
# Allow $username to inspect Docker json logs (read-only)
Cmnd_Alias AEO_DOCKER_LOG_CMDS = /usr/bin/du -sh /var/lib/docker/containers, /usr/bin/find /var/lib/docker/containers -maxdepth 2 -type f -name \\*-json.log -ls, /bin/ls -lh /var/lib/docker/containers/*/*-json.log
$username ALL=(root) NOPASSWD: AEO_DOCKER_LOG_CMDS
EOF

chmod 0440 "$tmp_file"

if visudo -cf "$tmp_file"; then
  if [[ -f "$sudoers_file" ]]; then
    cp "$sudoers_file" "${sudoers_file}.bak.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
  fi
  install -m 0440 "$tmp_file" "$sudoers_file"
  echo "Updated $sudoers_file"
else
  echo "visudo validation failed; no changes applied" >&2
  exit 1
fi
