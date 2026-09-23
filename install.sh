#!/usr/bin/env bash
#
# install.sh
#
# Installer voor de Fortibackup tooling op een Debian probe.
# Zet scripts + config neer in /opt/fortibackup, vraagt interactief de
# klantgegevens (1 klant per probe) en zet een cronjob op die de backup +
# IT Glue upload periodiek uitvoert.
#
# Usage: sudo ./install.sh

set -euo pipefail

INSTALL_DIR="/opt/fortibackup"
LOG_DIR="/var/log/fortibackup"
CRON_FILE="/etc/cron.d/fortibackup"
LOGROTATE_FILE="/etc/logrotate.d/fortibackup"
SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# ---------------------------------------------------------------------------
# Voorwaarden
# ---------------------------------------------------------------------------

if [[ $EUID -ne 0 ]]; then
    echo "❌ Dit installatiescript moet als root draaien. Gebruik: sudo $0" >&2
    exit 1
fi

for f in FortinetConfigBackupv1.sh FortinetConfigUloadToITGlue.sh run_all_clients.sh clients.conf.example; do
    if [[ ! -f "$SOURCE_DIR/$f" ]]; then
        echo "❌ Verwacht bestand niet gevonden naast install.sh: $f" >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------

echo "▶️  Controleren van benodigde pakketten..."
missing_pkgs=()
command -v curl    >/dev/null 2>&1 || missing_pkgs+=("curl")
command -v python3 >/dev/null 2>&1 || missing_pkgs+=("python3")
command -v crontab  >/dev/null 2>&1 || missing_pkgs+=("cron")

if (( ${#missing_pkgs[@]} > 0 )); then
    echo "📦 Ontbrekende pakketten worden geïnstalleerd: ${missing_pkgs[*]}"
    apt-get update -qq
    apt-get install -y "${missing_pkgs[@]}"
else
    echo "✅ Alle benodigde pakketten zijn al aanwezig."
fi

# ---------------------------------------------------------------------------
# Scripts installeren
# ---------------------------------------------------------------------------

echo "▶️  Installeren naar $INSTALL_DIR..."
mkdir -p -- "$INSTALL_DIR"
install -m 0755 "$SOURCE_DIR/FortinetConfigBackupv1.sh"       "$INSTALL_DIR/FortinetConfigBackupv1.sh"
install -m 0755 "$SOURCE_DIR/FortinetConfigUloadToITGlue.sh"  "$INSTALL_DIR/FortinetConfigUloadToITGlue.sh"
install -m 0755 "$SOURCE_DIR/run_all_clients.sh"               "$INSTALL_DIR/run_all_clients.sh"
install -m 0644 "$SOURCE_DIR/clients.conf.example"             "$INSTALL_DIR/clients.conf.example"

mkdir -p -- "$LOG_DIR"
chmod 0750 "$LOG_DIR"

# ---------------------------------------------------------------------------
# Klantgegevens interactief opvragen
# ---------------------------------------------------------------------------

CONFIG_FILE="$INSTALL_DIR/clients.conf"

if [[ -f "$CONFIG_FILE" ]]; then
    echo "⚠️  Er bestaat al een clients.conf in $INSTALL_DIR."
    read -rp "Overschrijven met nieuwe klantgegevens? (bestaand bestand wordt gebackupt) [y/N]: " overwrite
    if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
        echo "ℹ️  clients.conf ongewijzigd gelaten."
        SKIP_CONFIG=1
    else
        cp -- "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    fi
fi

if [[ -z "${SKIP_CONFIG-}" ]]; then
    echo ""
    echo "==== Klantgegevens voor deze probe ===="

    default_name="$(hostname)"
    read -rp "Klantnaam [$default_name]: " CLIENT_NAME
    CLIENT_NAME="${CLIENT_NAME:-$default_name}"
    CLIENT_NAME="${CLIENT_NAME//,/}"   # komma's zijn het veldscheidingsteken

    read -rp "FortiGate API base URL (bv. https://10.0.103.254:8443): " FIREWALL_HOST
    while [[ -z "$FIREWALL_HOST" ]]; do
        read -rp "  → verplicht, opnieuw invoeren: " FIREWALL_HOST
    done

    read -rsp "FortiGate API token: " API_TOKEN
    echo ""
    while [[ -z "$API_TOKEN" ]]; do
        read -rsp "  → verplicht, opnieuw invoeren: " API_TOKEN
        echo ""
    done

    read -rp "Is dit token base64-encoded? [y/N]: " base64_answer
    if [[ "$base64_answer" =~ ^[Yy]$ ]]; then
        BASE64_FLAG="yes"
    else
        BASE64_FLAG="no"
    fi

    read -rp "IT Glue upload nu al instellen voor deze klant? [y/N]: " itglue_answer
    if [[ "$itglue_answer" =~ ^[Yy]$ ]]; then
        read -rsp "IT Glue API key: " ITGLUE_API_KEY
        echo ""
        while [[ -z "$ITGLUE_API_KEY" ]]; do
            read -rsp "  → verplicht, opnieuw invoeren: " ITGLUE_API_KEY
            echo ""
        done

        read -rp "IT Glue document ID: " ITGLUE_DOCUMENT_ID
        while [[ ! "$ITGLUE_DOCUMENT_ID" =~ ^[0-9]+$ ]]; do
            read -rp "  → moet numeriek zijn, opnieuw invoeren: " ITGLUE_DOCUMENT_ID
        done
    else
        ITGLUE_API_KEY="-"
        ITGLUE_DOCUMENT_ID="-"
        echo "ℹ️  IT Glue upload overgeslagen. Backups blijven voorlopig lokaal op $INSTALL_DIR/backups staan."
        echo "    Vul dit later in door $CONFIG_FILE handmatig aan te passen (velden 5 en 6) of install.sh opnieuw te draaien."
    fi

    safe_name="$(echo "$CLIENT_NAME" | tr -c 'A-Za-z0-9_-' '_')"
    default_output="$INSTALL_DIR/backups/$safe_name"
    read -rp "Lokale backupmap [$default_output]: " OUTPUT_DIR
    OUTPUT_DIR="${OUTPUT_DIR:-$default_output}"
    mkdir -p -- "$OUTPUT_DIR"

    printf '%s,%s,%s,%s,%s,%s,%s\n' \
        "$CLIENT_NAME" "$FIREWALL_HOST" "$API_TOKEN" "$BASE64_FLAG" \
        "$ITGLUE_API_KEY" "$ITGLUE_DOCUMENT_ID" "$OUTPUT_DIR" > "$CONFIG_FILE"

    chmod 0600 "$CONFIG_FILE"
    chown root:root "$CONFIG_FILE"
    echo "✅ clients.conf geschreven naar $CONFIG_FILE (chmod 600)."
fi

# ---------------------------------------------------------------------------
# Cronjob opzetten
# ---------------------------------------------------------------------------

echo ""
echo "==== Scheduling ===="
read -rp "Uur voor dagelijkse run (0-23) [2]: " CRON_HOUR
CRON_HOUR="${CRON_HOUR:-2}"
while [[ ! "$CRON_HOUR" =~ ^([0-9]|1[0-9]|2[0-3])$ ]]; do
    read -rp "  → moet 0-23 zijn, opnieuw invoeren: " CRON_HOUR
done

read -rp "Minuut (0-59) [0]: " CRON_MINUTE
CRON_MINUTE="${CRON_MINUTE:-0}"
while [[ ! "$CRON_MINUTE" =~ ^([0-9]|[1-5][0-9])$ ]]; do
    read -rp "  → moet 0-59 zijn, opnieuw invoeren: " CRON_MINUTE
done

cat > "$CRON_FILE" <<EOF
# Beheerd door Fortibackup install.sh - niet handmatig aanpassen,
# herinstalleer met install.sh om de planning te wijzigen.
MAILTO=""
$CRON_MINUTE $CRON_HOUR * * * root $INSTALL_DIR/run_all_clients.sh -c $INSTALL_DIR/clients.conf >> $LOG_DIR/run.log 2>&1
EOF
chmod 0644 "$CRON_FILE"
chown root:root "$CRON_FILE"
echo "✅ Cronjob geïnstalleerd: dagelijks om $(printf '%02d:%02d' "$CRON_HOUR" "$CRON_MINUTE") ($CRON_FILE)."

# ---------------------------------------------------------------------------
# Logrotate
# ---------------------------------------------------------------------------

cat > "$LOGROTATE_FILE" <<EOF
$LOG_DIR/run.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
}
EOF
echo "✅ Logrotate config geplaatst: $LOGROTATE_FILE"

# ---------------------------------------------------------------------------
# Klaar
# ---------------------------------------------------------------------------

echo ""
echo "=================================================="
echo "Installatie voltooid."
echo "  Scripts:    $INSTALL_DIR"
echo "  Config:     $CONFIG_FILE"
echo "  Logs:       $LOG_DIR/run.log"
echo "  Cron:       $CRON_FILE"
echo ""
echo "Handmatig testen:"
echo "  sudo $INSTALL_DIR/run_all_clients.sh -c $CONFIG_FILE"
echo "=================================================="
