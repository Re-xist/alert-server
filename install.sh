#!/bin/bash
# ============================================================
#  Security Scripts - Setup Wizard
#
#  Setup script untuk pengguna baru:
#   - Cek dependencies (curl, jq)
#   - Prompt Bot Token + Chat ID
#   - Simpan ke config file
#   - Install systemd service
#   - Setup SSH login hook
#   - Set permissions
#   - Start service
#
#  Penggunaan: sudo bash install.sh
# ============================================================

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$HOME/.security-hardening.conf"

# ---- Warna ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

print_info()  { echo -e "${GREEN}[OK]${NC} $1"; }
print_warn()  { echo -e "${YELLOW}[!!]${NC} $1"; }
print_error() { echo -e "${RED}[XX]${NC} $1"; }
print_step()  { echo -e "${CYAN}[..]${NC} $1"; }

echo ""
echo -e "${CYAN}=========================================${NC}"
echo -e "${BOLD}  Security Scripts - Setup Wizard${NC}"
echo -e "${CYAN}=========================================${NC}"
echo ""

# ---- 1. Cek root ----
if [ "$EUID" -ne 0 ]; then
    print_error "Jalankan sebagai root: sudo bash install.sh"
    exit 1
fi

# ---- 2. Cek dependencies ----
print_step "Cek dependencies..."
missing=()
for cmd in curl jq; do
    if ! command -v "$cmd" &>/dev/null; then
        missing+=("$cmd")
    fi
done
if [ ${#missing[@]} -gt 0 ]; then
    print_warn "Installing: ${missing[*]}"
    apt-get update -qq && apt-get install -y -qq "${missing[@]}"
fi
print_info "Dependencies OK"

# ---- 3. Detect script location ----
print_step "Script directory: $SCRIPT_DIR"

# Resolve absolute paths
SCRIPT_DIR_ABS=$(realpath "$SCRIPT_DIR" 2>/dev/null || echo "$SCRIPT_DIR")

# ---- 4. Prompt Bot Token ----
echo ""
echo -e "${BOLD}Step 1: Telegram Bot Token${NC}"
echo "Cara mendapat Bot Token:"
echo "  1. Buka Telegram, cari @BotFather"
echo "  2. Kirim /newbot"
echo "  3. Ikuti instruksi, salin token yang diberikan"
echo ""

# Cek config yang sudah ada
existing_token=""
existing_chatid=""
if [ -f "$CONFIG_FILE" ]; then
    existing_token=$(grep '^TG_BOT_TOKEN=' "$CONFIG_FILE" | cut -d'"' -f2)
    existing_chatid=$(grep '^TG_CHAT_ID=' "$CONFIG_FILE" | cut -d'"' -f2)
fi

if [ -n "$existing_token" ]; then
    echo -e "  ${YELLOW}Token sudah ada: ${existing_token:0:10}...${NC}"
    echo -ne "  Gunakan token yang ada? (Y/n): "
    read -r use_existing
    if [[ "$use_existing" =~ ^[Nn]$ ]]; then
        existing_token=""
    fi
fi

if [ -z "$existing_token" ]; then
    echo -ne "  Masukkan Bot Token: "
    read -r TG_BOT_TOKEN
    if [ -z "$TG_BOT_TOKEN" ]; then
        print_error "Token kosong!"
        exit 1
    fi

    # Validasi
    print_step "Validasi token..."
    result=$(curl -s "https://api.telegram.org/bot${TG_BOT_TOKEN}/getMe" 2>/dev/null)
    if echo "$result" | jq -e '.ok == true' 2>/dev/null | grep -q true; then
        bot_name=$(echo "$result" | jq -r '.result.username' 2>/dev/null)
        print_info "Token valid! Bot: @$bot_name"
    else
        print_error "Token tidak valid!"
        exit 1
    fi
else
    TG_BOT_TOKEN="$existing_token"
fi

# ---- 5. Prompt Chat ID ----
echo ""
echo -e "${BOLD}Step 2: Telegram Chat ID${NC}"
echo ""

if [ -n "$existing_chatid" ]; then
    echo -e "  ${YELLOW}Chat ID sudah ada: $existing_chatid${NC}"
    echo -ne "  Gunakan Chat ID yang ada? (Y/n): "
    read -r use_existing
    if [[ "$use_existing" =~ ^[Nn]$ ]]; then
        existing_chatid=""
    fi
fi

if [ -z "$existing_chatid" ]; then
    echo "  1) Auto-detect dari pesan terakhir"
    echo "  2) Input manual"
    echo ""
    echo -ne "  Pilih (1/2): "
    read -r method

    case $method in
        1)
            print_step "Membaca pesan terakhir..."
            updates=$(curl -s "https://api.telegram.org/bot${TG_BOT_TOKEN}/getUpdates" 2>/dev/null)
            TG_CHAT_ID=$(echo "$updates" | jq -r '[.result[].message.chat.id] | last // empty' 2>/dev/null)

            if [ -z "$TG_CHAT_ID" ] || [ "$TG_CHAT_ID" = "null" ]; then
                print_error "Gagal mendeteksi Chat ID."
                echo "  Kirim pesan ke bot dulu, lalu jalankan ulang."
                echo -ne "  Atau masukkan manual: "
                read -r TG_CHAT_ID
                [ -z "$TG_CHAT_ID" ] && { print_error "Chat ID kosong!"; exit 1; }
            else
                chat_name=$(echo "$updates" | jq -r '[.result[].message.chat | "\(.first_name // "") \(.last_name // "") (\(.username // ""))"] | last // empty' 2>/dev/null)
                print_info "Terdeteksi: $chat_name (ID: $TG_CHAT_ID)"
            fi
            ;;
        2)
            echo -ne "  Masukkan Chat ID: "
            read -r TG_CHAT_ID
            [ -z "$TG_CHAT_ID" ] && { print_error "Chat ID kosong!"; exit 1; }
            ;;
        *)
            print_error "Pilihan tidak valid"
            exit 1
            ;;
    esac
else
    TG_CHAT_ID="$existing_chatid"
fi

# ---- 6. Simpan config ----
echo ""
print_step "Menyimpan konfigurasi..."

ALERT_DB_DIR="/var/log/telegram-alerts"
ALERT_DB_FILE="/var/log/telegram-alerts/alerts.db"
POLLING_LOG="/var/log/telegram-polling.log"
ACTIONS_LOG="/var/log/telegram-actions.log"
LOGIN_ALERT_LOG="/var/log/login-alerts.log"
BANNED_IPS_FILE="/etc/banned_ips.txt"

cat > "$CONFIG_FILE" << CONFEOF
# Security Hardening Tool - Config
# Generated by install.sh
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
ALERT_SSH="on"
ALERT_DOCKER="on"
ALERT_UFW="on"
ALERT_DISK="on"
ALERT_DB_DIR="$ALERT_DB_DIR"
ALERT_DB_FILE="$ALERT_DB_FILE"
POLLING_LOG="$POLLING_LOG"
ACTIONS_LOG="$ACTIONS_LOG"
LOGIN_ALERT_LOG="$LOGIN_ALERT_LOG"
BANNED_IPS_FILE="$BANNED_IPS_FILE"
CONFEOF
chmod 600 "$CONFIG_FILE"
print_info "Config disimpan di $CONFIG_FILE"

# ---- 7. Buat direktori dan file log ----
print_step "Membuat direktori log..."
mkdir -p "$ALERT_DB_DIR"
touch "$ALERT_DB_FILE" "$ACTIONS_LOG" "$POLLING_LOG" "$LOGIN_ALERT_LOG"
touch "$BANNED_IPS_FILE"

# ---- 8. Set permissions ----
print_step "Set permissions..."
chmod +x "$SCRIPT_DIR/login-alert.sh"
chmod +x "$SCRIPT_DIR/bot-daemon.sh"
chmod +x "$SCRIPT_DIR/security-hardening.sh"
print_info "Permissions OK"

# ---- 9. Install SSH login hook ----
print_step "Install SSH login alert hook..."

# Hapus hook lama dari /etc/profile jika ada
if grep -q "telegram-login-alert" /etc/profile 2>/dev/null; then
    sed -i '/# Telegram Login Alert/d' /etc/profile
    sed -i '/telegram-login-alert/d' /etc/profile
    print_info "Hook lama di /etc/profile dihapus"
fi

# Hapus hook lama di profile.d
rm -f /etc/profile.d/security-alert-ssh.sh

alert_path="$SCRIPT_DIR_ABS/login-alert.sh"

tee /etc/profile.d/security-alert-ssh.sh > /dev/null << SCRIPTEOF
#!/bin/bash
# Security alert - Interactive SSH login notification
# Installed by install.sh
if [ -n "\$SSH_CLIENT" ] || [ -n "\$SSH_TTY" ]; then
    "$alert_path" &
fi
SCRIPTEOF

chmod +x /etc/profile.d/security-alert-ssh.sh
print_info "SSH alert hook diinstall"

# ---- 10. Stop service lama jika ada ----
if systemctl is-active --quiet telegram-alert-polling 2>/dev/null; then
    print_step "Menghentikan service lama (telegram-alert-polling)..."
    systemctl stop telegram-alert-polling
    systemctl disable telegram-alert-polling 2>/dev/null || true
    print_info "Service lama dihentikan"
fi

# ---- 11. Install systemd service ----
print_step "Install systemd service..."

daemon_path="$SCRIPT_DIR_ABS/bot-daemon.sh"

if [ ! -f "$daemon_path" ]; then
    print_error "bot-daemon.sh tidak ditemukan di $SCRIPT_DIR_ABS"
    print_warn "Lewati instalasi systemd service"
else
    tee /etc/systemd/system/security-bot.service > /dev/null << SERVEOF
[Unit]
Description=Security Bot - Telegram Monitoring & Alert
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$SCRIPT_DIR_ABS
ExecStart=$daemon_path
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVEOF

    systemctl daemon-reload
    systemctl enable security-bot
    systemctl start security-bot

    sleep 2

    if systemctl is-active --quiet security-bot; then
        print_info "Service security-bot BERJALAN"
    else
        print_error "Service gagal start! Cek: journalctl -u security-bot -n 20"
    fi
fi

# ---- 12. Tes koneksi ----
echo ""
echo -e "${BOLD}Step 3: Tes Koneksi${NC}"
print_step "Mengirim pesan tes ke Telegram..."

hostname=$(hostname -s 2>/dev/null || echo "server")
result=$(curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
    -d chat_id="$TG_CHAT_ID" \
    -d text="<b>[$hostname]</b> Security Bot berhasil diinstall!\nKirim /help untuk daftar command." \
    -d parse_mode="HTML" 2>/dev/null)

if echo "$result" | jq -e '.ok' 2>/dev/null | grep -q true; then
    print_info "Pesan tes terkirim! Cek Telegram Anda."
else
    print_warn "Gagal mengirim pesan tes. Cek token dan chat ID."
fi

# ---- Done ----
echo ""
echo -e "${CYAN}=========================================${NC}"
echo -e "${BOLD}  Setup Selesai!${NC}"
echo -e "${CYAN}=========================================${NC}"
echo ""
echo "  Config       : $CONFIG_FILE"
echo "  Alert hook   : /etc/profile.d/security-alert-ssh.sh"
echo "  Service      : security-bot (systemd)"
echo "  Alert DB     : $ALERT_DB_FILE"
echo "  Polling log  : $POLLING_LOG"
echo ""
echo "  Command berguna:"
echo "    systemctl status security-bot"
echo "    systemctl restart security-bot"
echo "    journalctl -u security-bot -f"
echo ""
echo "  Manual management:"
echo "    bash $SCRIPT_DIR/security-hardening.sh"
echo ""
print_info "Setup selesai!"
