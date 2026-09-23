#!/usr/bin/env bash
#
# run_all_clients.sh
#
# Loopt over clients.conf en voert voor elke klant de FortiGate config-backup
# lokaal uit. Als voor een klant ook ITGLUE_API_KEY en ITGLUE_DOCUMENT_ID zijn
# ingevuld, wordt daarna ook geüpload naar IT Glue; zijn die velden leeg of
# "-", dan blijft de backup lokaal staan (upload volgt later). Hergebruikt de
# bestaande scripts FortinetConfigBackupv1.sh en FortinetConfigUloadToITGlue.sh
# zonder ze aan te passen. Eén klant die faalt stopt de run niet voor de
# andere klanten.
#
# Usage:
#   ./run_all_clients.sh [-c <configFile>]
#
# Default configFile: clients.conf naast dit script.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
BACKUP_SCRIPT="$SCRIPT_DIR/FortinetConfigBackupv1.sh"
UPLOAD_SCRIPT="$SCRIPT_DIR/FortinetConfigUloadToITGlue.sh"
CONFIG_FILE="$SCRIPT_DIR/clients.conf"

while getopts ":c:h" opt; do
    case "$opt" in
        c) CONFIG_FILE="$OPTARG" ;;
        h)
            cat <<EOF
Usage: $0 [-c <configFile>]
Default configFile: $SCRIPT_DIR/clients.conf
Zie clients.conf.example voor het formaat.
EOF
            exit 0
            ;;
        \?) echo "Error: Invalid option: -$OPTARG" >&2; exit 2 ;;
        :) echo "Error: Option -$OPTARG requires an argument." >&2; exit 2 ;;
    esac
done

if [[ ! -f "$BACKUP_SCRIPT" || ! -f "$UPLOAD_SCRIPT" ]]; then
    echo "❌ Error: verwacht $BACKUP_SCRIPT en $UPLOAD_SCRIPT naast dit script." >&2
    exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "❌ Error: configbestand niet gevonden: $CONFIG_FILE" >&2
    echo "   Kopieer clients.conf.example naar clients.conf en vul de klantgegevens in." >&2
    exit 1
fi

perms=$(stat -c '%a' "$CONFIG_FILE" 2>/dev/null || echo "")
if [[ -n "$perms" && "$perms" != "600" && "$perms" != "400" ]]; then
    echo "⚠️  Waarschuwing: $CONFIG_FILE heeft rechten $perms (bevat API keys/tokens)."
    echo "    Aanbevolen: chmod 600 $CONFIG_FILE"
fi

total=0
success=0
failed_clients=()

while IFS=',' read -r CLIENT_NAME FIREWALL_HOST API_TOKEN BASE64_FLAG ITGLUE_API_KEY ITGLUE_DOCUMENT_ID OUTPUT_DIR; do
    # sla lege regels en comments over
    [[ -z "${CLIENT_NAME// }" ]] && continue
    [[ "$CLIENT_NAME" =~ ^# ]] && continue

    total=$((total + 1))
    echo "=================================================="
    echo "▶️  Klant: $CLIENT_NAME"
    echo "=================================================="

    if [[ -z "$FIREWALL_HOST" || -z "$API_TOKEN" || -z "$OUTPUT_DIR" ]]; then
        echo "❌ Ongeldige/incomplete regel voor '$CLIENT_NAME', overgeslagen."
        failed_clients+=("$CLIENT_NAME (incomplete configregel)")
        continue
    fi

    backup_args=(-u "$FIREWALL_HOST" -t "$API_TOKEN" -o "$OUTPUT_DIR")
    if [[ "${BASE64_FLAG,,}" == "yes" ]]; then
        backup_args+=(-b)
    fi

    if ! "$BACKUP_SCRIPT" "${backup_args[@]}"; then
        echo "❌ Backup mislukt voor $CLIENT_NAME."
        failed_clients+=("$CLIENT_NAME (backup mislukt)")
        continue
    fi

    if [[ -z "${ITGLUE_API_KEY-}" || "$ITGLUE_API_KEY" == "-" || -z "${ITGLUE_DOCUMENT_ID-}" || "$ITGLUE_DOCUMENT_ID" == "-" ]]; then
        echo "ℹ️  IT Glue upload overgeslagen voor $CLIENT_NAME (nog niet geconfigureerd, backup blijft lokaal staan)."
    elif ! "$UPLOAD_SCRIPT" -t "$ITGLUE_API_KEY" -c "-" -d "$ITGLUE_DOCUMENT_ID" -f "$OUTPUT_DIR"; then
        echo "❌ Upload naar IT Glue mislukt voor $CLIENT_NAME."
        failed_clients+=("$CLIENT_NAME (upload mislukt)")
        continue
    fi

    echo "✅ $CLIENT_NAME voltooid."
    success=$((success + 1))
done < "$CONFIG_FILE"

echo "=================================================="
echo "Klaar: $success/$total klanten succesvol."
if (( ${#failed_clients[@]} > 0 )); then
    echo "Gefaald:"
    for f in "${failed_clients[@]}"; do
        echo "  - $f"
    done
    exit 1
fi

exit 0
