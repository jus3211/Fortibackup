#!/usr/bin/env bash
#
# bootstrap.sh
#
# One-command installer entry point for Fortibackup. Downloads the latest
# main branch from GitHub and hands off to install.sh (which does the real
# work: dependencies, /opt/fortibackup, clients.conf, cron).
#
# Usage (run as root, on the Debian probe):
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/jus3211/Fortibackup/main/bootstrap.sh)"

set -euo pipefail

REPO_TARBALL="https://github.com/jus3211/Fortibackup/archive/refs/heads/main.tar.gz"

if [[ $EUID -ne 0 ]]; then
    echo "❌ Must be run as root. Use:" >&2
    echo "   sudo bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/jus3211/Fortibackup/main/bootstrap.sh)\"" >&2
    exit 1
fi

command -v curl >/dev/null 2>&1 || { echo "❌ curl is required but not found." >&2; exit 1; }
command -v tar  >/dev/null 2>&1 || { echo "❌ tar is required but not found." >&2; exit 1; }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "▶️  Downloading Fortibackup (main branch)..."
curl -fsSL "$REPO_TARBALL" -o "$TMP_DIR/fortibackup.tar.gz"
tar -xzf "$TMP_DIR/fortibackup.tar.gz" -C "$TMP_DIR"

SRC_DIR="$(find "$TMP_DIR" -maxdepth 1 -type d -name 'Fortibackup-*')"
if [[ -z "$SRC_DIR" ]]; then
    echo "❌ Could not find extracted source directory." >&2
    exit 1
fi

chmod +x "$SRC_DIR/install.sh"
echo "▶️  Launching install.sh..."
echo ""
"$SRC_DIR/install.sh"
