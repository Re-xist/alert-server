#!/bin/bash
# ============================================================
#  SSH Login Alert Script
#
#  Dipanggil oleh /etc/profile saat ada SSH login.
#  Mengirim pesan alert ke Telegram dengan inline keyboard.
#  Membaca config dari ~/.security-hardening.conf
#
#  Penggunaan: dipanggil otomatis oleh /etc/profile
# ============================================================

CONFIG_FILE="$HOME/.security-hardening.conf"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load config
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# Jangan kirim alert jika tidak ada config atau alert SSH dimatikan
if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
    exit 0
fi
if [ "${ALERT_SSH:-on}" != "on" ]; then
    exit 0
fi

# Path database
ALERT_DB_DIR="${ALERT_DB_DIR:-/var/log/telegram-alerts}"
ALERT_DB_FILE="${ALERT_DB_FILE:-/var/log/telegram-alerts/alerts.db}"
LOGIN_ALERT_LOG="${LOGIN_ALERT_LOG:-/var/log/login-alerts.log}"

mkdir -p "$ALERT_DB_DIR"
touch "$ALERT_DB_FILE"

# Zona waktu
export TZ="${TZ:-Asia/Jakarta}"
LOGIN_TIME=$(date "+%Y-%m-%d %H:%M:%S")

# Informasi user
USER_NAME=$(whoami)
USER_ID=$(id -u)

# Informasi koneksi
CLIENT_IP=$(echo "$SSH_CLIENT" | awk '{print $1}' || echo "LOCAL")
CLIENT_PORT=$(echo "$SSH_CLIENT" | awk '{print $2}' || echo "N/A")
SERVER_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
HOSTNAME=$(hostname -s 2>/dev/null || hostname)

# Generate unique ID untuk alert ini
ALERT_ID=$(echo "$LOGIN_TIME-$USER_NAME-$CLIENT_IP-$$" | md5sum | cut -d' ' -f1)
SESSION_PID=$PPID

# Simpan ke database
echo "$ALERT_ID|$LOGIN_TIME|$USER_NAME|$USER_ID|$CLIENT_IP|$SESSION_PID|${SSH_TTY:-N/A}" >> "$ALERT_DB_FILE"

# Escape untuk JSON
escape_json() {
    echo "$1" | sed 's/"/\\"/g' | sed "s/'/\\'/g"
}

# Membuat pesan alert
MSG_TEXT="🚨 *SERVER LOGIN ALERT* 🚨

━━━━━━━━━━━━━━━━━━━━━
⏰ *Waktu:* $LOGIN_TIME WIB
━━━━━━━━━━━━━━━━━━━━━

👤 *User:* $USER_NAME (ID: $USER_ID)
🌐 *Dari IP:* $CLIENT_IP:$CLIENT_PORT
🖥️  *Ke Server:* $HOSTNAME ($SERVER_IP)
📱 *TTY:* ${SSH_TTY:-N/A}

━━━━━━━━━━━━━━━━━━━━━
⚠️ *Pilih aksi di bawah:*
"

# Inline keyboard buttons
KEYBOARD='{
  "inline_keyboard": [
    [
      {"text": "🔴 LOGOUT User", "callback_data": "logout_'"$ALERT_ID"'"},
      {"text": "⛔ BLOCK IP", "callback_data": "block_'"$ALERT_ID"'"}
    ],
    [
      {"text": "✅ Izinkan Login", "callback_data": "allow_'"$ALERT_ID"'"},
      {"text": "ℹ️  Detail Session", "callback_data": "info_'"$ALERT_ID"'"}
    ]
  ]
}'

# Kirim pesan dengan inline keyboard
curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    -d chat_id="$TG_CHAT_ID" \
    -d text="$(escape_json "$MSG_TEXT")" \
    -d parse_mode="Markdown" \
    -d reply_markup="$KEYBOARD" \
    -d disable_web_page_preview="true" > /dev/null 2>&1

# Log lokal
echo "[$LOGIN_TIME] Alert sent - $USER_NAME from $CLIENT_IP (ID: $ALERT_ID)" >> "$LOGIN_ALERT_LOG" 2>/dev/null
