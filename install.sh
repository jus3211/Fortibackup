#!/usr/bin/env bash
#
# install.sh
#
# Installer voor de Fortibackup tooling op een Debian probe.
# Zet scripts + config neer in /opt/fortibackup, vraagt via een tekst-UI
# (whiptail) de klantgegevens (1 klant per probe) op en zet een cronjob op
# die de backup + IT Glue upload periodiek uitvoert.
#
# Usage: sudo ./install.sh

set -euo pipefail

INSTALL_DIR="/opt/fortibackup"
LOG_DIR="/var/log/fortibackup"
CRON_FILE="/etc/cron.d/fortibackup"
LOGROTATE_FILE="/etc/logrotate.d/fortibackup"
SOURCE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

WT_BACKTITLE="Fortibackup Installer"
WT_H=10
WT_W=72

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
# Dependencies (plain terminal output - apt output hoort niet in een dialog)
# ---------------------------------------------------------------------------

echo "▶️  Controleren van benodigde pakketten..."
missing_pkgs=()
command -v curl     >/dev/null 2>&1 || missing_pkgs+=("curl")
command -v python3  >/dev/null 2>&1 || missing_pkgs+=("python3")
command -v crontab  >/dev/null 2>&1 || missing_pkgs+=("cron")
command -v whiptail >/dev/null 2>&1 || missing_pkgs+=("whiptail")

if (( ${#missing_pkgs[@]} > 0 )); then
    echo "📦 Ontbrekende pakketten worden geïnstalleerd: ${missing_pkgs[*]}"
    apt-get update -qq
    apt-get install -y "${missing_pkgs[@]}"
else
    echo "✅ Alle benodigde pakketten zijn al aanwezig."
fi

if [[ ! -t 0 || ! -t 1 ]]; then
    echo "❌ Deze installer heeft een interactieve terminal nodig (voor de tekst-UI)." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# TUI helpers
# ---------------------------------------------------------------------------

wt_abort() {
    clear
    echo "❌ Installatie geannuleerd." >&2
    exit 1
}

wt_msg() {
    whiptail --backtitle "$WT_BACKTITLE" --title "$1" --msgbox "$2" "$WT_H" "$WT_W"
}

wt_yesno() {
    whiptail --backtitle "$WT_BACKTITLE" --title "$1" --yesno "$2" "$WT_H" "$WT_W"
}

# $1=title $2=prompt $3=default -> prints answer on stdout, aborts on Cancel/Esc
wt_input() {
    whiptail --backtitle "$WT_BACKTITLE" --title "$1" --inputbox "$2" "$WT_H" "$WT_W" "$3" 3>&1 1>&2 2>&3 || wt_abort
}

# $1=title $2=prompt -> prints answer on stdout, aborts on Cancel/Esc
wt_password() {
    whiptail --backtitle "$WT_BACKTITLE" --title "$1" --passwordbox "$2" "$WT_H" "$WT_W" 3>&1 1>&2 2>&3 || wt_abort
}

# $1=title $2=prompt $3=default -> loops until non-empty
wt_input_required() {
    local title="$1" prompt="$2" default="${3-}" val
    val="$(wt_input "$title" "$prompt" "$default")"
    while [[ -z "$val" ]]; do
        wt_msg "Verplicht" "Dit veld mag niet leeg zijn."
        val="$(wt_input "$title" "$prompt" "$default")"
    done
    printf '%s' "$val"
}

# $1=title $2=prompt -> loops until non-empty
wt_password_required() {
    local title="$1" prompt="$2" val
    val="$(wt_password "$title" "$prompt")"
    while [[ -z "$val" ]]; do
        wt_msg "Verplicht" "Dit veld mag niet leeg zijn."
        val="$(wt_password "$title" "$prompt")"
    done
    printf '%s' "$val"
}

wt_msg "Welkom" "Fortibackup installer\n\nDeze wizard installeert de backup-scripts naar $INSTALL_DIR, vraagt de klantgegevens op en zet een dagelijkse cronjob op.\n\nGebruik Tab om tussen velden/knoppen te wisselen, Enter om te bevestigen."

# ---------------------------------------------------------------------------
# Scripts installeren
# ---------------------------------------------------------------------------

mkdir -p -- "$INSTALL_DIR"
install -m 0755 "$SOURCE_DIR/FortinetConfigBackupv1.sh"       "$INSTALL_DIR/FortinetConfigBackupv1.sh"
install -m 0755 "$SOURCE_DIR/FortinetConfigUloadToITGlue.sh"  "$INSTALL_DIR/FortinetConfigUloadToITGlue.sh"
install -m 0755 "$SOURCE_DIR/run_all_clients.sh"               "$INSTALL_DIR/run_all_clients.sh"
install -m 0644 "$SOURCE_DIR/clients.conf.example"             "$INSTALL_DIR/clients.conf.example"

mkdir -p -- "$LOG_DIR"
chmod 0750 "$LOG_DIR"

# ---------------------------------------------------------------------------
# Klantgegevens
# ---------------------------------------------------------------------------

CONFIG_FILE="$INSTALL_DIR/clients.conf"
SKIP_CONFIG=""

if [[ -f "$CONFIG_FILE" ]]; then
    if wt_yesno "clients.conf bestaat al" "Er bestaat al een clients.conf in $INSTALL_DIR.\n\nOverschrijven met nieuwe klantgegevens? (het bestaande bestand wordt eerst gebackupt)"; then
        cp -- "$CONFIG_FILE" "${CONFIG_FILE}.bak.$(date +%Y%m%d%H%M%S)"
    else
        SKIP_CONFIG=1
    fi
fi

if [[ -z "$SKIP_CONFIG" ]]; then
    default_name="$(hostname)"
    CLIENT_NAME="$(wt_input "Klantgegevens (1/6)" "Klantnaam:" "$default_name")"
    CLIENT_NAME="${CLIENT_NAME:-$default_name}"
    CLIENT_NAME="${CLIENT_NAME//,/}"   # komma's zijn het veldscheidingsteken

    FIREWALL_HOST="$(wt_input_required "Klantgegevens (2/6)" "FortiGate API base URL:\n(bv. https://10.0.103.254:8443)" "")"

    API_TOKEN="$(wt_password_required "Klantgegevens (3/6)" "FortiGate API token:\n(invoer blijft verborgen)")"

    if wt_yesno "Klantgegevens (4/6)" "Is dit FortiGate API token base64-encoded?"; then
        BASE64_FLAG="yes"
    else
        BASE64_FLAG="no"
    fi

    if wt_yesno "Klantgegevens (5/6)" "IT Glue upload nu al instellen voor deze klant?\n\n(Kies Nee om voorlopig alleen lokaal te backuppen - dit kan later alsnog via clients.conf of door install.sh opnieuw te draaien.)"; then
        ITGLUE_API_KEY="$(wt_password_required "IT Glue" "IT Glue API key:\n(invoer blijft verborgen)")"

        ITGLUE_DOCUMENT_ID="$(wt_input_required "IT Glue" "IT Glue document ID:" "")"
        while [[ ! "$ITGLUE_DOCUMENT_ID" =~ ^[0-9]+$ ]]; do
            wt_msg "Ongeldig" "Document ID moet numeriek zijn."
            ITGLUE_DOCUMENT_ID="$(wt_input_required "IT Glue" "IT Glue document ID:" "")"
        done
    else
        ITGLUE_API_KEY="-"
        ITGLUE_DOCUMENT_ID="-"
    fi

    safe_name="$(echo "$CLIENT_NAME" | tr -c 'A-Za-z0-9_-' '_')"
    default_output="$INSTALL_DIR/backups/$safe_name"
    OUTPUT_DIR="$(wt_input "Klantgegevens (6/6)" "Lokale backupmap:" "$default_output")"
    OUTPUT_DIR="${OUTPUT_DIR:-$default_output}"
    mkdir -p -- "$OUTPUT_DIR"

    printf '%s,%s,%s,%s,%s,%s,%s\n' \
        "$CLIENT_NAME" "$FIREWALL_HOST" "$API_TOKEN" "$BASE64_FLAG" \
        "$ITGLUE_API_KEY" "$ITGLUE_DOCUMENT_ID" "$OUTPUT_DIR" > "$CONFIG_FILE"

    chmod 0600 "$CONFIG_FILE"
    chown root:root "$CONFIG_FILE"
fi

# ---------------------------------------------------------------------------
# Cronjob opzetten
# ---------------------------------------------------------------------------

CRON_HOUR="$(wt_input "Scheduling (1/2)" "Uur voor dagelijkse run (0-23):" "2")"
CRON_HOUR="${CRON_HOUR:-2}"
while [[ ! "$CRON_HOUR" =~ ^([0-9]|1[0-9]|2[0-3])$ ]]; do
    wt_msg "Ongeldig" "Moet een getal tussen 0 en 23 zijn."
    CRON_HOUR="$(wt_input "Scheduling (1/2)" "Uur voor dagelijkse run (0-23):" "2")"
    CRON_HOUR="${CRON_HOUR:-2}"
done

CRON_MINUTE="$(wt_input "Scheduling (2/2)" "Minuut (0-59):" "0")"
CRON_MINUTE="${CRON_MINUTE:-0}"
while [[ ! "$CRON_MINUTE" =~ ^([0-9]|[1-5][0-9])$ ]]; do
    wt_msg "Ongeldig" "Moet een getal tussen 0 en 59 zijn."
    CRON_MINUTE="$(wt_input "Scheduling (2/2)" "Minuut (0-59):" "0")"
    CRON_MINUTE="${CRON_MINUTE:-0}"
done

cat > "$CRON_FILE" <<EOF
# Beheerd door Fortibackup install.sh - niet handmatig aanpassen,
# herinstalleer met install.sh om de planning te wijzigen.
MAILTO=""
$CRON_MINUTE $CRON_HOUR * * * root $INSTALL_DIR/run_all_clients.sh -c $INSTALL_DIR/clients.conf >> $LOG_DIR/run.log 2>&1
EOF
chmod 0644 "$CRON_FILE"
chown root:root "$CRON_FILE"

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

# ---------------------------------------------------------------------------
# Klaar
# ---------------------------------------------------------------------------

itglue_summary="niet geconfigureerd (alleen lokale backup)"
if [[ -z "$SKIP_CONFIG" && "$ITGLUE_API_KEY" != "-" ]]; then
    itglue_summary="ingesteld, document ID $ITGLUE_DOCUMENT_ID"
fi

wt_msg "Installatie voltooid" "Scripts:    $INSTALL_DIR
Config:     $CONFIG_FILE
Logs:       $LOG_DIR/run.log
Cron:       dagelijks om $(printf '%02d:%02d' "$CRON_HOUR" "$CRON_MINUTE") ($CRON_FILE)
IT Glue:    $itglue_summary

Handmatig testen:
sudo $INSTALL_DIR/run_all_clients.sh -c $CONFIG_FILE"

clear
echo "=================================================="
echo "Installatie voltooid."
echo "  Scripts:    $INSTALL_DIR"
echo "  Config:     $CONFIG_FILE"
echo "  Logs:       $LOG_DIR/run.log"
echo "  Cron:       dagelijks om $(printf '%02d:%02d' "$CRON_HOUR" "$CRON_MINUTE") ($CRON_FILE)"
echo "  IT Glue:    $itglue_summary"
echo ""
echo "Handmatig testen:"
echo "  sudo $INSTALL_DIR/run_all_clients.sh -c $CONFIG_FILE"
echo "=================================================="
