#!/usr/bin/env bash
#
# backup-fortigate.sh
#
# FortiGate Configuration Backup Script with verbose mode, error handling, and base64 token decoding.
#

set -euo pipefail
IFS=$'\n\t'

MAX_FILES_TO_KEEP=7

show_help() {
    cat <<'EOF'
FortiGate configuration backup script.

Usage:
  ./backup-fortigate.sh -u <firewallHost> -t <apiToken> -o <outputDir> [-v] [-b]
  ./backup-fortigate.sh -h

Required options:
  -u <firewallHost>   FortiGate API base URL (e.g. https://10.0.103.254:8443)
  -t <apiToken>       API bearer token used for Authorization header
  -o <outputDir>      Directory where backups will be saved

Optional:
  -v                  Verbose output with curl progress and detailed logs
  -b                  Treat API token as Base64 encoded and decode it before use

Other:
  -h                  Show this help message and exit

Notes:
  - The backup filename format is:
      config-backup-DD-MM-YYYY_HH-MM-SS.conf
  - The script keeps the most recent $MAX_FILES_TO_KEEP files and deletes older ones.
    To change that number, edit the MAX_FILES_TO_KEEP variable near the top of this script.
  - To see this help at any time:
      ./backup-fortigate.sh -h

Example:
  ./backup-fortigate.sh -u https://10.0.103.254:8443 -t myEncodedToken -o /home/user/backups -b -v
EOF
}

VERBOSE=0
BASE64_DECODE=0

error_exit() {
    local exit_code=$?
    local last_cmd=$BASH_COMMAND
    echo "❌ Error: Command '${last_cmd}' exited with code $exit_code."
    echo "Exiting."
    exit $exit_code
}

trap error_exit ERR

while getopts ":u:t:o:vbh" opt; do
    case "$opt" in
        u) FIREWALL_HOST="$OPTARG" ;;
        t) API_TOKEN="$OPTARG" ;;
        o) OUTPUT_DIR="$OPTARG" ;;
        v) VERBOSE=1 ;;
        b) BASE64_DECODE=1 ;;
        h) show_help; exit 0 ;;
        \?) echo "Error: Invalid option: -$OPTARG" >&2; show_help; exit 2 ;;
        :) echo "Error: Option -$OPTARG requires an argument." >&2; show_help; exit 2 ;;
    esac
done

if [[ -z "${FIREWALL_HOST-}" || -z "${API_TOKEN-}" || -z "${OUTPUT_DIR-}" ]]; then
    echo "Error: Missing required arguments."
    echo "Run: $0 -h"
    exit 2
fi

FIREWALL_HOST="${FIREWALL_HOST%/}"  # strip trailing slash

# Decode token if requested
if [[ $BASE64_DECODE -eq 1 ]]; then
    if [[ $VERBOSE -eq 1 ]]; then
        echo "Decoding API token from base64..."
    fi
    # Decode base64 token (handle potential errors)
    if ! API_TOKEN_DECODED=$(echo "$API_TOKEN" | base64 --decode 2>/dev/null); then
        echo "❌ Error: Failed to decode API token from base64."
        exit 3
    fi
else
    API_TOKEN_DECODED="$API_TOKEN"
fi

mkdir -p -- "$OUTPUT_DIR"

TIMESTAMP=$(date +%d-%m-%Y_%H-%M-%S)
OUTPUT_FILE="$OUTPUT_DIR/config-backup-$TIMESTAMP.conf"

BACKUP_URL="$FIREWALL_HOST/api/v2/monitor/system/config/backup"
BACKUP_BODY='{"destination":"file","file_format":"fos","scope":"global"}'

echo "Backing up FortiGate configuration..."
if [[ $VERBOSE -eq 1 ]]; then
    echo "Running curl with progress bar..."
    curl_opts=("-k" "-X" "POST" "-H" "Authorization: Bearer $API_TOKEN_DECODED" "-H" "Content-Type: application/json" "-d" "$BACKUP_BODY" "--fail" "--progress-bar" "$BACKUP_URL" "-o" "$OUTPUT_FILE")
else
    curl_opts=("-k" "-X" "POST" "-H" "Authorization: Bearer $API_TOKEN_DECODED" "-H" "Content-Type: application/json" "-d" "$BACKUP_BODY" "--fail" "-sS" "$BACKUP_URL" "-o" "$OUTPUT_FILE")
fi

echo "Running: curl -k -X POST -H 'Authorization: Bearer <REDACTED>' -H 'Content-Type: application/json' -d '$BACKUP_BODY' \"$BACKUP_URL\" -o \"$OUTPUT_FILE\""

curl "${curl_opts[@]}"
echo "✅ Backup saved to: $OUTPUT_FILE"

mapfile -t files_sorted < <(
    find "$OUTPUT_DIR" -maxdepth 1 -type f -name 'config-backup-*.conf' -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr \
    | awk '{$1=""; sub(/^ /,""); print}'
)

total_files=${#files_sorted[@]}

if (( total_files > MAX_FILES_TO_KEEP )); then
    files_to_delete=( "${files_sorted[@]:MAX_FILES_TO_KEEP}" )
    echo "🧹 Removing old backups (keeping latest $MAX_FILES_TO_KEEP):"
    for f in "${files_to_delete[@]}"; do
        echo "  Removing: $f"
        rm -f -- "$f" || echo "  Warning: failed to remove $f"
    done
else
    echo "No old backups to remove (found $total_files, keeping up to $MAX_FILES_TO_KEEP)."
fi

exit 0
