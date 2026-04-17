#!/bin/bash
# ============================================================
#  Server Security Hardening & Monitoring Tool v3.0
#
#  Fitur:
#   - Security Hardening (SSH, Docker, Firewall)
#   - Telegram Bot (Notifikasi + Remote Monitoring)
#   - Interactive Login Alerts (Inline Keyboard)
#   - Alert Management (View, Block, Unblock, Stats)
#   - Systemd Service Management
#
#  Penggunaan: bash security-hardening.sh
# ============================================================

set -e

# ---- Konfigurasi ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$HOME/.security-hardening.conf"
BOT_PID_FILE="/tmp/security-bot-monitor.pid"
NOTIFY_PID_FILE="/tmp/security-bot-notify.pid"
LOG_FILE="$HOME/.security-bot.log"

# Alert & monitoring paths
ALERT_DB_DIR="${ALERT_DB_DIR:-/var/log/telegram-alerts}"
ALERT_DB_FILE="${ALERT_DB_FILE:-/var/log/telegram-alerts/alerts.db}"
POLLING_LOG="${POLLING_LOG:-/var/log/telegram-polling.log}"
ACTIONS_LOG="${ACTIONS_LOG:-/var/log/telegram-actions.log}"
LOGIN_ALERT_LOG="${LOGIN_ALERT_LOG:-/var/log/login-alerts.log}"
BANNED_IPS_FILE="${BANNED_IPS_FILE:-/etc/banned_ips.txt}"

# ---- Warna ----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

# ============================================================
# HELPER FUNCTIONS
# ============================================================

print_header() {
    echo ""
    echo -e "${CYAN}=========================================${NC}"
    echo -e "${BOLD}  $1${NC}"
    echo -e "${CYAN}=========================================${NC}"
}

print_info()    { echo -e "${GREEN}[OK]${NC} $1"; }
print_warn()    { echo -e "${YELLOW}[!!]${NC} $1"; }
print_error()   { echo -e "${RED}[XX]${NC} $1"; }
print_step()    { echo -e "${CYAN}[..]${NC} $1"; }

confirm() {
    local prompt="$1"
    echo -ne "${YELLOW}[??]${NC} $prompt (y/N): "
    read -r response
    [[ "$response" =~ ^[Yy]$ ]]
}

press_enter() {
    echo ""
    read -n 1 -s -r -p "Tekan ENTER untuk melanjutkan..."
    echo ""
}

check_root() {
    if [ "$EUID" -eq 0 ]; then
        print_error "JANGAN jalankan sebagai root! Gunakan user biasa dengan sudo."
        exit 1
    fi
}

check_sudo() {
    print_step "Cek akses sudo..."
    if ! sudo -v 2>/dev/null; then
        print_error "Dibutuhkan akses sudo!"
        exit 1
    fi
}

check_deps() {
    local missing=()
    for cmd in curl jq; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done
    if [ ${#missing[@]} -gt 0 ]; then
        print_warn "Menginstall dependency: ${missing[*]}"
        sudo apt-get update -qq && sudo apt-get install -y -qq "${missing[@]}"
    fi
}

# ---- Config Management ----

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck source=/dev/null
        source "$CONFIG_FILE"
    fi
    TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
    TG_CHAT_ID="${TG_CHAT_ID:-}"
    ALERT_SSH="${ALERT_SSH:-on}"
    ALERT_DOCKER="${ALERT_DOCKER:-on}"
    ALERT_UFW="${ALERT_UFW:-on}"
    ALERT_DISK="${ALERT_DISK:-on}"
    ALERT_DB_DIR="${ALERT_DB_DIR:-/var/log/telegram-alerts}"
    ALERT_DB_FILE="${ALERT_DB_FILE:-/var/log/telegram-alerts/alerts.db}"
    POLLING_LOG="${POLLING_LOG:-/var/log/telegram-polling.log}"
    ACTIONS_LOG="${ACTIONS_LOG:-/var/log/telegram-actions.log}"
    LOGIN_ALERT_LOG="${LOGIN_ALERT_LOG:-/var/log/login-alerts.log}"
    BANNED_IPS_FILE="${BANNED_IPS_FILE:-/etc/banned_ips.txt}"
}

save_config() {
    cat > "$CONFIG_FILE" << CONFEOF
# Security Hardening Tool - Config
# Auto-generated, jangan edit manual kecuali perlu
TG_BOT_TOKEN="$TG_BOT_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
ALERT_SSH="$ALERT_SSH"
ALERT_DOCKER="$ALERT_DOCKER"
ALERT_UFW="$ALERT_UFW"
ALERT_DISK="$ALERT_DISK"
ALERT_DB_DIR="$ALERT_DB_DIR"
ALERT_DB_FILE="$ALERT_DB_FILE"
POLLING_LOG="$POLLING_LOG"
ACTIONS_LOG="$ACTIONS_LOG"
LOGIN_ALERT_LOG="$LOGIN_ALERT_LOG"
BANNED_IPS_FILE="$BANNED_IPS_FILE"
CONFEOF
    chmod 600 "$CONFIG_FILE"
}

has_tg_config() {
    [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_CHAT_ID" ]
}

# ---- Telegram API ----

tg_send() {
    local text="$1"
    local parse_mode="${2:-HTML}"

    if ! has_tg_config; then
        return 1
    fi

    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d chat_id="$TG_CHAT_ID" \
        -d text="$text" \
        -d parse_mode="$parse_mode" \
        > /dev/null 2>&1
}

tg_send_message() {
    local msg="$1"
    local hostname
    hostname=$(hostname -s 2>/dev/null || echo "server")
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    tg_send "<b>[$hostname]</b> $msg" "HTML"
}

tg_get_updates() {
    local offset="${1:-0}"
    curl -s "https://api.telegram.org/bot${TG_BOT_TOKEN}/getUpdates?offset=${offset}&timeout=30" 2>/dev/null
}

# ============================================================
# SECURITY HARDENING FUNCTIONS
# ============================================================

step_ssh_key_setup() {
    print_header "Step 1: Setup SSH Key"

    if [ -f ~/.ssh/id_ed25519 ]; then
        print_warn "SSH key sudah ada di ~/.ssh/id_ed25519"
        if ! confirm "Timpa key lama?"; then
            print_info "Skip"
            return 0
        fi
        rm -f ~/.ssh/id_ed25519 ~/.ssh/id_ed25519.pub
    fi

    print_step "Membuat SSH key Ed25519..."
    ssh-keygen -t ed25519 -a 100 -f ~/.ssh/id_ed25519 -N "" -C "$USER@$(hostname)"
    print_info "SSH key berhasil dibuat"

    print_step "Setup authorized_keys..."
    mkdir -p ~/.ssh
    cat ~/.ssh/id_ed25519.pub >> ~/.ssh/authorized_keys
    chmod 700 ~/.ssh
    chmod 600 ~/.ssh/authorized_keys ~/.ssh/id_ed25519
    chmod 644 ~/.ssh/id_ed25519.pub
    print_info "Permission diatur"

    print_step "Tes SSH key..."
    if ssh -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=5 localhost echo "OK" 2>/dev/null | grep -q "OK"; then
        print_info "Tes SSH key BERHASIL"
    else
        print_warn "Tes SSH key GAGAL - key tetap dibuat, pastikan bekerja sebelum disable password"
    fi

    echo ""
    print_header "Public Key:"
    cat ~/.ssh/id_ed25519.pub
    echo ""
    local ip; ip=$(hostname -I | awk '{print $1}')
    echo "Salin ke komputer lokal:"
    echo "  scp $USER@${ip}:~/.ssh/id_ed25519 ~/.ssh/ctfd_key"
    echo "  ssh -i ~/.ssh/ctfd_key $USER@${ip}"
    echo ""
    print_info "SSH key setup selesai!"
}

step_disable_password_auth() {
    print_header "Step 2: Nonaktifkan Login Password SSH"

    print_warn "Pastikan SSH key sudah berfungsi! Jika tidak, Anda TERKUNCI."
    echo ""
    if ! confirm "Lanjutkan?"; then
        return 0
    fi

    if [ -f /etc/ssh/sshd_config.d/10-no-password.conf ]; then
        sudo cp /etc/ssh/sshd_config.d/10-no-password.conf \
            "/etc/ssh/sshd_config.d/10-no-password.conf.bak.$(date +%Y%m%d%H%M%S)"
        print_info "Backup config lama"
    fi

    print_step "Membuat konfigurasi..."
    sudo tee /etc/ssh/sshd_config.d/10-no-password.conf > /dev/null << 'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
EOF

    print_step "Restart SSH..."
    sudo systemctl restart sshd

    if sudo sshd -T 2>/dev/null | grep -qi "passwordauthentication no"; then
        print_info "Password auth BERHASIL dinonaktifkan"
    else
        print_error "Gagal! Cek manual."
        return 1
    fi
}

step_docker_hardening() {
    print_header "Step 3: Hardening Docker"

    if ! command -v docker &>/dev/null; then
        print_error "Docker tidak terinstall!"
        return 1
    fi

    if [ -f /etc/docker/daemon.json ]; then
        sudo cp /etc/docker/daemon.json "/etc/docker/daemon.json.bak.$(date +%Y%m%d%H%M%S)"
        print_info "Backup daemon.json"
    fi

    print_step "Konfigurasi Docker daemon..."
    sudo tee /etc/docker/daemon.json > /dev/null << 'EOF'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" },
  "live-restore": true,
  "icc": false,
  "userland-proxy": false,
  "no-new-privileges": true,
  "default-runtime": "runc",
  "runtimes": { "runc": { "path": "runc" } }
}
EOF

    print_step "Restart Docker..."
    sudo systemctl restart docker
    sleep 2

    print_info "Docker hardening selesai!"
    echo "  - ICC off (container terisolasi)"
    echo "  - no-new-privileges on"
    echo "  - Log rotation 10MB x 3"
    echo "  - Userland proxy off"
}

step_docker_networks() {
    print_header "Step 4: Isolasi Jaringan Docker"

    if ! command -v docker &>/dev/null; then
        print_error "Docker tidak terinstall!"
        return 1
    fi

    print_step "Membuat network terisolasi..."
    sudo docker network create ctfd-network --driver bridge 2>/dev/null && print_info "ctfd-network dibuat" || print_warn "ctfd-network sudah ada"
    sudo docker network create lab-network --driver bridge 2>/dev/null && print_info "lab-network dibuat" || print_warn "lab-network sudah ada"

    echo ""
    sudo docker network ls
    echo ""
    sudo docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Networks}}\t{{.Ports}}" 2>/dev/null || true
    echo ""
    echo "Pindahkan container manual:"
    echo "  sudo docker network connect ctfd-network <NAME>"
    echo "  sudo docker network disconnect bridge <NAME>"
}

step_ufw_firewall() {
    print_header "Step 5: Konfigurasi Firewall UFW"

    if ! command -v ufw &>/dev/null; then
        print_error "UFW tidak terinstall! sudo apt install ufw"
        return 1
    fi

    print_step "Set default policy..."
    sudo ufw default deny incoming
    sudo ufw default allow outgoing

    print_step "Allow SSH (22), HTTP (80), HTTPS (443)..."
    sudo ufw allow 22/tcp comment 'SSH'
    sudo ufw allow 80/tcp comment 'HTTP'
    sudo ufw allow 443/tcp comment 'HTTPS'

    print_step "Allow CTFd & Lab ports..."
    sudo ufw allow 8000/tcp comment 'CTFd'
    for port in 5001 5003 6002 6004 8001 8002 8003 8004 8005 8006 8007 8008 8009; do
        sudo ufw allow "$port/tcp" comment "Lab-$port"
    done

    echo ""
    sudo ufw show added
    echo ""

    if ! confirm "Aktifkan firewall?"; then
        print_info "Firewall belum aktif. Manual: sudo ufw enable"
        return 0
    fi

    sudo ufw --force enable
    echo ""
    print_info "Firewall aktif!"
    sudo ufw status numbered
}

run_all_hardening() {
    print_header "Jalankan Semua Step (1-5)"
    if ! confirm "Jalankan semua step?"; then return 0; fi

    step_ssh_key_setup; press_enter
    step_disable_password_auth; press_enter
    step_docker_hardening; press_enter
    step_docker_networks; press_enter
    step_ufw_firewall

    print_header "Semua Hardening Selesai!"
}

verify_security() {
    print_header "Verifikasi Keamanan"

    echo -e "\n${BOLD}=== SSH ===${NC}"
    sudo sshd -T 2>/dev/null | grep -iE "passwordauthentication|pubkeyauthentication" || true

    echo -e "\n${BOLD}=== UFW ===${NC}"
    sudo ufw status verbose 2>/dev/null || print_warn "UFW tidak ada"

    echo -e "\n${BOLD}=== Docker ===${NC}"
    command -v docker &>/dev/null && { sudo docker info 2>/dev/null | grep -iE "Live Restore|Userland|Insecure|icc" || true; } || print_warn "Docker tidak ada"

    echo -e "\n${BOLD}=== Docker Networks ===${NC}"
    command -v docker &>/dev/null && sudo docker network ls 2>/dev/null || true

    echo -e "\n${BOLD}=== Port Terbuka ===${NC}"
    ss -tlnp 2>/dev/null | grep LISTEN | head -20

    echo -e "\n${BOLD}=== SSH Keys ===${NC}"
    [ -f ~/.ssh/id_ed25519 ] && { print_info "Ed25519 key ada"; ls -la ~/.ssh/id_ed25519; } || print_warn "SSH key belum dibuat"

    echo ""
    print_info "Verifikasi selesai!"
}

# ============================================================
# TELEGRAM BOT FUNCTIONS
# ============================================================

tg_setup_token() {
    print_header "Setup Telegram Bot Token"
    echo ""
    echo "Cara mendapat Bot Token:"
    echo "  1. Buka Telegram, cari @BotFather"
    echo "  2. Kirim /newbot"
    echo "  3. Ikuti instruksi, salin token yang diberikan"
    echo ""

    echo -ne "${YELLOW}[??]${NC} Masukkan Bot Token: "
    read -r token

    if [ -z "$token" ]; then
        print_error "Token kosong!"
        return 1
    fi

    # Validasi token
    print_step "Validasi token..."
    local result
    result=$(curl -s "https://api.telegram.org/bot${token}/getMe" 2>/dev/null)

    if echo "$result" | jq -e '.ok == true' 2>/dev/null | grep -q true; then
        local bot_name
        bot_name=$(echo "$result" | jq -r '.result.username' 2>/dev/null)
        print_info "Token valid! Bot: @$bot_name"
        TG_BOT_TOKEN="$token"
        save_config
    else
        print_error "Token tidak valid!"
        return 1
    fi
}

tg_setup_chatid() {
    print_header "Setup Telegram Chat ID"
    echo ""
    echo "Cara mendapat Chat ID:"
    echo "  1. Kirim pesan apa saja ke bot Anda di Telegram"
    echo "  2. Lalu pilih opsi 'Auto-detect' di bawah"
    echo ""
    echo -e "  ${BOLD}1.${NC} Auto-detect dari pesan terakhir"
    echo -e "  ${BOLD}2.${NC} Input manual"
    echo ""

    echo -ne "${YELLOW}[??]${NC} Pilih (1/2): "
    read -r method

    case $method in
        1)
            if [ -z "$TG_BOT_TOKEN" ]; then
                print_error "Set Bot Token dulu!"
                return 1
            fi
            print_step "Membaca pesan terakhir..."
            local updates
            updates=$(curl -s "https://api.telegram.org/bot${TG_BOT_TOKEN}/getUpdates" 2>/dev/null)

            local chat_id
            chat_id=$(echo "$updates" | jq -r '[.result[].message.chat.id] | last // empty' 2>/dev/null)

            if [ -z "$chat_id" ] || [ "$chat_id" = "null" ]; then
                print_error "Gagal mendeteksi Chat ID. Kirim pesan ke bot dulu, lalu coba lagi."
                return 1
            fi

            local chat_name
            chat_name=$(echo "$updates" | jq -r '[.result[].message.chat | "\(.first_name // "") \(.last_name // "") (\(.username // ""))"] | last // empty' 2>/dev/null)

            print_info "Terdeteksi: $chat_name (ID: $chat_id)"
            TG_CHAT_ID="$chat_id"
            save_config
            ;;
        2)
            echo -ne "${YELLOW}[??]${NC} Masukkan Chat ID: "
            read -r chat_id
            if [ -z "$chat_id" ]; then
                print_error "Chat ID kosong!"
                return 1
            fi
            TG_CHAT_ID="$chat_id"
            save_config
            ;;
        *)
            print_error "Pilihan tidak valid"
            return 1
            ;;
    esac
}

tg_test_connection() {
    print_header "Tes Koneksi Telegram Bot"

    if ! has_tg_config; then
        print_error "Set Bot Token dan Chat ID dulu!"
        return 1
    fi

    print_step "Mengirim pesan tes..."
    local hostname; hostname=$(hostname -s 2>/dev/null || echo "server")

    if tg_send "<b>[$hostname]</b> Tes koneksi berhasil!\nSecurity Hardening Tool aktif."; then
        print_info "Pesan tes terkirim! Cek Telegram Anda."
    else
        print_error "Gagal mengirim. Cek Token dan Chat ID."
    fi
}

tg_toggle_alerts() {
    print_header "Konfigurasi Alert"
    echo ""
    echo "Status alert saat ini:"
    echo "  SSH Login Alert    : $ALERT_SSH"
    echo "  Docker Event Alert : $ALERT_DOCKER"
    echo "  UFW Block Alert    : $ALERT_UFW"
    echo "  Disk Space Alert   : $ALERT_DISK"
    echo ""
    echo -e "  ${BOLD}1.${NC} Toggle SSH Login Alert"
    echo -e "  ${BOLD}2.${NC} Toggle Docker Event Alert"
    echo -e "  ${BOLD}3.${NC} Toggle UFW Block Alert"
    echo -e "  ${BOLD}4.${NC} Toggle Disk Space Alert"
    echo -e "  ${BOLD}5.${NC} Aktifkan Semua"
    echo -e "  ${BOLD}6.${NC} Nonaktifkan Semua"
    echo -e "  ${BOLD}0.${NC} Kembali"
    echo ""

    echo -ne "${YELLOW}[??]${NC} Pilih (0-6): "
    read -r choice

    case $choice in
        1) ALERT_SSH=$([ "$ALERT_SSH" = "on" ] && echo "off" || echo "on") ;;
        2) ALERT_DOCKER=$([ "$ALERT_DOCKER" = "on" ] && echo "off" || echo "on") ;;
        3) ALERT_UFW=$([ "$ALERT_UFW" = "on" ] && echo "off" || echo "on") ;;
        4) ALERT_DISK=$([ "$ALERT_DISK" = "on" ] && echo "off" || echo "on") ;;
        5) ALERT_SSH="on"; ALERT_DOCKER="on"; ALERT_UFW="on"; ALERT_DISK="on" ;;
        6) ALERT_SSH="off"; ALERT_DOCKER="off"; ALERT_UFW="off"; ALERT_DISK="off" ;;
        0) return 0 ;;
        *) print_error "Pilihan tidak valid"; return 1 ;;
    esac

    save_config
    print_info "Alert diupdate. SSH=$ALERT_SSH Docker=$ALERT_DOCKER UFW=$ALERT_UFW Disk=$ALERT_DISK"
}

# ---- Telegram Bot: SSH Alert Hook ----

# Install SSH login alert hook (calls login-alert.sh)
install_ssh_alert_hook() {
    print_step "Menginstall SSH login alert hook..."

    local hook_script="/etc/profile.d/security-alert-ssh.sh"
    local alert_script="$SCRIPT_DIR/login-alert.sh"

    if [ ! -f "$alert_script" ]; then
        print_error "login-alert.sh tidak ditemukan di $SCRIPT_DIR"
        return 1
    fi

    # Hapus hook lama dari /etc/profile jika ada
    if sudo grep -q "telegram-login-alert" /etc/profile 2>/dev/null; then
        sudo sed -i '/# Telegram Login Alert/d' /etc/profile
        sudo sed -i '/telegram-login-alert/d' /etc/profile
        print_info "Hook lama di /etc/profile dihapus"
    fi

    # Hapus hook lama di profile.d jika ada
    sudo rm -f /etc/profile.d/security-alert-ssh.sh

    # Buat hook baru yang memanggil login-alert.sh
    local alert_path
    alert_path=$(realpath "$alert_script" 2>/dev/null || echo "$alert_script")

    sudo tee "$hook_script" > /dev/null << SCRIPTEOF
#!/bin/bash
# Security alert - Interactive SSH login notification
# Installed by security-hardening.sh
if [ -n "\$SSH_CLIENT" ] || [ -n "\$SSH_TTY" ]; then
    "$alert_path" &
fi
SCRIPTEOF

    sudo chmod +x "$hook_script"
    print_info "SSH login alert hook diinstall di $hook_script"
    print_info "Script: $alert_path"
}

# ---- Telegram Bot: Alert Management ----

show_recent_alerts() {
    print_header "Alert Terakhir"
    echo ""

    if [ ! -f "$ALERT_DB_FILE" ] || [ ! -s "$ALERT_DB_FILE" ]; then
        print_warn "Belum ada alert"
        return 0
    fi

    echo "10 alert terakhir:"
    echo ""
    tail -10 "$ALERT_DB_FILE" | while IFS='|' read -r alert_id time user uid ip pid tty; do
        echo -e "  ${BOLD}Waktu:${NC} $time"
        echo -e "  ${BOLD}User:${NC} $user (ID: $uid)"
        echo -e "  ${BOLD}IP:${NC}  $ip"
        echo -e "  ${BOLD}TTY:${NC} $tty"
        echo -e "  ${DIM}ID: $alert_id${NC}"
        echo ""
    done
}

show_blocked_ips() {
    print_header "IP yang Diblock"
    echo ""

    local found=0

    # Dari banned_ips.txt
    if [ -f "$BANNED_IPS_FILE" ] && [ -s "$BANNED_IPS_FILE" ]; then
        found=1
        echo -e "${BOLD}Dari $BANNED_IPS_FILE:${NC}"
        while read -r ip; do
            [ -n "$ip" ] && echo "  - $ip"
        done < "$BANNED_IPS_FILE"
        echo ""
    fi

    # Dari iptables
    if command -v iptables >/dev/null 2>&1; then
        local iptables_drops
        iptables_drops=$(sudo iptables -L INPUT -n 2>/dev/null | grep DROP | awk '{print $4}' | grep -v "0.0.0.0/0" | sort -u)
        if [ -n "$iptables_drops" ]; then
            found=1
            echo -e "${BOLD}Dari iptables:${NC}"
            echo "$iptables_drops" | while read -r ip; do
                [ -n "$ip" ] && echo "  - $ip"
            done
            echo ""
        fi
    fi

    # Dari ufw
    if command -v ufw >/dev/null 2>&1; then
        local ufw_denies
        ufw_denies=$(sudo ufw status numbered 2>/dev/null | grep DENY | awk '{print $3}' | sort -u)
        if [ -n "$ufw_denies" ]; then
            found=1
            echo -e "${BOLD}Dari UFW:${NC}"
            echo "$ufw_denies" | while read -r ip; do
                [ -n "$ip" ] && echo "  - $ip"
            done
            echo ""
        fi
    fi

    if [ "$found" -eq 0 ]; then
        print_info "Tidak ada IP yang diblock"
    fi
}

unblock_ip() {
    print_header "Unblock IP"
    echo ""

    if [ ! -f "$BANNED_IPS_FILE" ] || [ ! -s "$BANNED_IPS_FILE" ]; then
        print_warn "Tidak ada IP yang diblock"
        return 0
    fi

    echo "IP yang diblock:"
    local idx=1
    declare -A ip_map
    while read -r ip; do
        if [ -n "$ip" ]; then
            echo "  $idx) $ip"
            ip_map[$idx]="$ip"
            ((idx++))
        fi
    done < "$BANNED_IPS_FILE"
    echo ""

    echo -ne "${YELLOW}[??]${NC} Masukkan nomor atau IP yang ingin di-unblock (0=batal): "
    read -r input

    [ "$input" = "0" ] && return 0

    local target_ip=""
    if [[ "$input" =~ ^[0-9]+$ ]] && [ -n "${ip_map[$input]}" ]; then
        target_ip="${ip_map[$input]}"
    else
        target_ip="$input"
    fi

    if [ -z "$target_ip" ]; then
        print_error "Input tidak valid"
        return 1
    fi

    print_step "Membuka block untuk $target_ip..."

    # Dari banned_ips.txt
    if [ -f "$BANNED_IPS_FILE" ]; then
        sudo sed -i "/^${target_ip}$/d" "$BANNED_IPS_FILE" 2>/dev/null
    fi

    # Dari iptables
    if command -v iptables >/dev/null 2>&1; then
        sudo iptables -D INPUT -s "$target_ip" -j DROP 2>/dev/null || true
        sudo iptables-save > /etc/iptables.rules 2>/dev/null || true
    fi

    # Dari ufw
    if command -v ufw >/dev/null 2>&1; then
        sudo ufw delete deny from "$target_ip" 2>/dev/null || true
    fi

    print_info "IP $target_ip berhasil di-unblock"
}

show_login_stats() {
    print_header "Statistik Login"
    echo ""

    if [ ! -f "$ALERT_DB_FILE" ]; then
        print_warn "Belum ada data login"
        return 0
    fi

    # Total login
    local total
    total=$(wc -l < "$ALERT_DB_FILE" 2>/dev/null || echo "0")
    echo "  Total Login   : $total"

    # User unik
    local users
    users=$(cut -d'|' -f3 "$ALERT_DB_FILE" 2>/dev/null | sort -u | wc -l)
    echo "  User Unik     : $users"

    # IP unik
    local ips
    ips=$(cut -d'|' -f5 "$ALERT_DB_FILE" 2>/dev/null | sort -u | wc -l)
    echo "  IP Unik       : $ips"

    # IP yang diblock
    local blocked=0
    if [ -f "$BANNED_IPS_FILE" ]; then
        blocked=$(grep -c '.' "$BANNED_IPS_FILE" 2>/dev/null || echo "0")
    fi
    echo "  IP Diblock    : $blocked"

    # Aksi
    local actions=0
    if [ -f "$ACTIONS_LOG" ]; then
        actions=$(wc -l < "$ACTIONS_LOG" 2>/dev/null || echo "0")
    fi
    echo "  Total Aksi    : $actions"

    # Breakdown aksi
    if [ -f "$ACTIONS_LOG" ] && [ -s "$ACTIONS_LOG" ]; then
        echo ""
        echo "  Breakdown Aksi:"
        local logout_count block_count allow_count
        logout_count=$(grep -c "LOGOUT:" "$ACTIONS_LOG" 2>/dev/null || echo "0")
        block_count=$(grep -c "BLOCK:" "$ACTIONS_LOG" 2>/dev/null || echo "0")
        allow_count=$(grep -c "ALLOW:" "$ACTIONS_LOG" 2>/dev/null || echo "0")
        echo "    Logout : $logout_count"
        echo "    Block  : $block_count"
        echo "    Allow  : $allow_count"
    fi

    echo ""
}

clean_alert_logs() {
    print_header "Bersihkan Log"
    echo ""
    echo "Pilih log yang ingin dibersihkan:"
    echo -e "  ${BOLD}1.${NC} Semua log"
    echo -e "  ${BOLD}2.${NC} Hanya login alerts"
    echo -e "  ${BOLD}3.${NC} Hanya action logs"
    echo -e "  ${BOLD}4.${NC} Hanya polling log"
    echo -e "  ${BOLD}0.${NC} Batal"
    echo ""

    echo -ne "${YELLOW}[??]${NC} Pilih (0-4): "
    read -r choice

    case $choice in
        1)
            sudo truncate -s 0 "$LOGIN_ALERT_LOG" 2>/dev/null || true
            sudo truncate -s 0 "$ACTIONS_LOG" 2>/dev/null || true
            sudo truncate -s 0 "$POLLING_LOG" 2>/dev/null || true
            print_info "Semua log dibersihkan"
            ;;
        2)
            sudo truncate -s 0 "$LOGIN_ALERT_LOG" 2>/dev/null || true
            print_info "Login alerts dibersihkan"
            ;;
        3)
            sudo truncate -s 0 "$ACTIONS_LOG" 2>/dev/null || true
            print_info "Action logs dibersihkan"
            ;;
        4)
            sudo truncate -s 0 "$POLLING_LOG" 2>/dev/null || true
            print_info "Polling log dibersihkan"
            ;;
        0)
            return 0
            ;;
        *)
            print_error "Pilihan tidak valid"
            return 1
            ;;
    esac
}

# ---- Telegram Bot: Systemd Service Management ----

install_systemd_service() {
    print_header "Install Systemd Service"
    echo ""

    local service_file="$SCRIPT_DIR/security-bot.service"
    local daemon_script="$SCRIPT_DIR/bot-daemon.sh"

    if [ ! -f "$daemon_script" ]; then
        print_error "bot-daemon.sh tidak ditemukan di $SCRIPT_DIR"
        return 1
    fi

    # Dapatkan absolute path
    local daemon_path
    daemon_path=$(realpath "$daemon_script" 2>/dev/null || echo "$daemon_script")
    local script_dir_abs
    script_dir_abs=$(realpath "$SCRIPT_DIR" 2>/dev/null || echo "$SCRIPT_DIR")

    # Buat direktori log jika belum ada
    sudo mkdir -p "$(dirname "${ALERT_DB_FILE}")"
    sudo touch "$ALERT_DB_FILE" "$ACTIONS_LOG" "$POLLING_LOG" "$LOGIN_ALERT_LOG" 2>/dev/null

    # Hapus service lama jika ada
    if systemctl is-active --quiet telegram-alert-polling 2>/dev/null; then
        print_step "Menghentikan service lama (telegram-alert-polling)..."
        sudo systemctl stop telegram-alert-polling
        sudo systemctl disable telegram-alert-polling 2>/dev/null || true
    fi

    # Buat service file dengan path yang benar
    print_step "Membuat systemd service..."
    sudo tee /etc/systemd/system/security-bot.service > /dev/null << SERVEOF
[Unit]
Description=Security Bot - Telegram Monitoring & Alert
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$script_dir_abs
ExecStart=$daemon_path
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SERVEOF

    # Reload systemd
    sudo systemctl daemon-reload

    # Install SSH alert hook juga
    install_ssh_alert_hook

    # Enable dan start
    print_step "Mengaktifkan service..."
    sudo systemctl enable security-bot
    sudo systemctl start security-bot

    sleep 2

    if systemctl is-active --quiet security-bot; then
        print_info "Service security-bot BERJALAN"
        systemctl status security-bot --no-pager | head -10
    else
        print_error "Service gagal start! Cek: journalctl -u security-bot -n 20"
    fi
}

remove_systemd_service() {
    print_header "Remove Systemd Service"
    echo ""

    if ! confirm "Hapus security-bot service?"; then
        return 0
    fi

    # Stop service
    if systemctl is-active --quiet security-bot 2>/dev/null; then
        sudo systemctl stop security-bot
        print_info "Service dihentikan"
    fi

    # Disable
    sudo systemctl disable security-bot 2>/dev/null || true

    # Hapus service file
    sudo rm -f /etc/systemd/system/security-bot.service
    sudo systemctl daemon-reload

    # Hapus SSH alert hook
    sudo rm -f /etc/profile.d/security-alert-ssh.sh

    print_info "Service dan hook dihapus"
}

# ---- Telegram Bot: Monitoring Daemon (Manual/Fallback) ----

start_bot_monitor() {
    print_header "Start Telegram Bot Monitor (Manual)"

    if ! has_tg_config; then
        print_error "Set Bot Token dan Chat ID dulu!"
        return 1
    fi

    # Cek apakah sudah jalan
    if [ -f "$BOT_PID_FILE" ] && kill -0 "$(cat "$BOT_PID_FILE")" 2>/dev/null; then
        print_warn "Bot monitor sudah berjalan (PID: $(cat "$BOT_PID_FILE"))"
        return 0
    fi

    # Cek apakah systemd service sedang jalan
    if systemctl is-active --quiet security-bot 2>/dev/null; then
        print_warn "Systemd service security-bot sedang berjalan!"
        print_warn "Hentikan dulu: sudo systemctl stop security-bot"
        return 1
    fi

    print_step "Memulai bot monitor (manual mode)..."

    # Setup paths
    sudo mkdir -p "$ALERT_DB_DIR" 2>/dev/null
    sudo touch "$ALERT_DB_FILE" "$ACTIONS_LOG" "$POLLING_LOG" 2>/dev/null
    sudo chown "$USER" "$ALERT_DB_FILE" "$ACTIONS_LOG" "$POLLING_LOG" 2>/dev/null || true

    # Jalankan monitoring daemon di background
    (
        source "$CONFIG_FILE" 2>/dev/null
        LAST_UPDATE_ID=0

        # Load offset file jika ada
        local offset_file="$ALERT_DB_DIR/offset.txt"
        if [ -f "$offset_file" ]; then
            LAST_UPDATE_ID=$(cat "$offset_file")
        fi

        log_msg() { echo "[$(date '+%H:%M:%S')] $1" >> "$LOG_FILE"; }

        # Helper functions untuk callback
        escape_json() { echo "$1" | sed 's/"/\\"/g'; }

        answer_callback() {
            local cb_id="$1" text="$2" show_alert="${3:-false}"
            curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/answerCallbackQuery" \
                -d callback_query_id="$cb_id" -d text="$text" -d show_alert="$show_alert" > /dev/null 2>&1
        }

        edit_message() {
            local m_id="$1" text="$2" keyboard="$3"
            local args=(-s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/editMessageText"
                -d chat_id="${TG_CHAT_ID}" -d message_id="$m_id"
                -d text="$(escape_json "$text")" -d parse_mode="Markdown")
            [ -n "$keyboard" ] && args+=(-d reply_markup="$keyboard")
            curl "${args[@]}" > /dev/null 2>&1
        }

        handle_callback_action() {
            local cb_id="$1" cb_data="$2" msg_id="$3"
            local action="${cb_data%%_*}"
            local alert_id="${cb_data#*_}"

            local db_file="${ALERT_DB_FILE}"
            local banned="${BANNED_IPS_FILE}"
            local actions_log="${ACTIONS_LOG}"

            case "$action" in
                logout)
                    local session_data
                    session_data=$(grep "^${alert_id}|" "$db_file" | tail -1)
                    if [ -n "$session_data" ]; then
                        local username tty pid
                        username=$(echo "$session_data" | cut -d'|' -f3)
                        tty=$(echo "$session_data" | cut -d'|' -f7)
                        pid=$(echo "$session_data" | cut -d'|' -f6)
                        local killed=0
                        [ -n "$tty" ] && [ "$tty" != "N/A" ] && pkill -9 -t "$tty" 2>/dev/null && killed=1
                        [ -n "$pid" ] && [ "$pid" != "0" ] && [ "$pid" != "N/A" ] && kill -9 "$pid" 2>/dev/null && killed=1
                        if [ "$killed" -eq 1 ]; then
                            echo "[$(date '+%Y-%m-%d %H:%M:%S')] LOGOUT: User $username (session $alert_id) kicked" >> "$actions_log"
                            answer_callback "$cb_id" "✅ User $username berhasil dikick!" "true"
                            edit_message "$msg_id" "✅ User $username dikick

🚫 Session terminated" '{"inline_keyboard": [[{"text": "🔴 USER DIKICK", "callback_data": "done"}]]}'
                        else
                            answer_callback "$cb_id" "Gagal mengkick user" "true"
                        fi
                    else
                        answer_callback "$cb_id" "Session tidak ditemukan" "true"
                    fi
                    ;;
                block)
                    local session_data
                    session_data=$(grep "^${alert_id}|" "$db_file" | tail -1)
                    if [ -n "$session_data" ]; then
                        local ip username
                        ip=$(echo "$session_data" | cut -d'|' -f5)
                        username=$(echo "$session_data" | cut -d'|' -f3)
                        if [ "$ip" != "LOCAL" ] && [ "$ip" != "127.0.0.1" ] && [ "$ip" != "N/A" ]; then
                            command -v iptables >/dev/null 2>&1 && { iptables -C INPUT -s "$ip" -j DROP 2>/dev/null || iptables -A INPUT -s "$ip" -j DROP 2>/dev/null; }
                            command -v ufw >/dev/null 2>&1 && ufw deny from "$ip" 2>/dev/null
                            grep -q "^${ip}$" "$banned" 2>/dev/null || echo "$ip" >> "$banned"
                            echo "[$(date '+%Y-%m-%d %H:%M:%S')] BLOCK: IP $ip (user $username, session $alert_id)" >> "$actions_log"
                            answer_callback "$cb_id" "✅ IP $ip berhasil diblock!" "true"
                            edit_message "$msg_id" "✅ IP $ip diblock

🔒 IP Address blocked" '{"inline_keyboard": [[{"text": "⛔ IP DIBLOCK", "callback_data": "done"}]]}'
                        else
                            answer_callback "$cb_id" "Tidak bisa block localhost" "true"
                        fi
                    else
                        answer_callback "$cb_id" "Session tidak ditemukan" "true"
                    fi
                    ;;
                allow)
                    answer_callback "$cb_id" "✅ Login diizinkan" "false"
                    edit_message "$msg_id" "✅ *Login diizinkan*

Session tetap aktif." '{"inline_keyboard": [[{"text": "✅ LOGIN DIZINKAN", "callback_data": "done"}]]}'
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ALLOW: Session $alert_id allowed" >> "$actions_log"
                    ;;
                info)
                    local session_data
                    session_data=$(grep "^${alert_id}|" "$db_file" | tail -1)
                    if [ -n "$session_data" ]; then
                        local login_time username user_id ip pid tty
                        login_time=$(echo "$session_data" | cut -d'|' -f2)
                        username=$(echo "$session_data" | cut -d'|' -f3)
                        user_id=$(echo "$session_data" | cut -d'|' -f4)
                        ip=$(echo "$session_data" | cut -d'|' -f5)
                        pid=$(echo "$session_data" | cut -d'|' -f6)
                        tty=$(echo "$session_data" | cut -d'|' -f7)
                        answer_callback "$cb_id" "Info dikirim" "false"
                        curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
                            -d chat_id="${TG_CHAT_ID}" \
                            -d text="ℹ️ SESSION INFO:

👤 User: $username (ID: $user_id)
🌐 IP: $ip
⏰ Login: $login_time
📱 PID: $pid
🖥️ TTY: $tty
🔑 Alert ID: $alert_id" \
                            -d parse_mode="Markdown" > /dev/null 2>&1
                    else
                        answer_callback "$cb_id" "Session tidak ditemukan" "true"
                    fi
                    ;;
                done)
                    answer_callback "$cb_id" "Aksi sudah dilakukan" "false"
                    ;;
            esac
        }

        log_msg "Bot monitor started (manual mode, offset: $LAST_UPDATE_ID)"

        # Kirim pesan start
        curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TG_CHAT_ID}" \
            -d text="<b>[$(hostname -s)]</b> Bot monitor dimulai (manual mode)!\nKirim /help untuk daftar command." \
            -d parse_mode="HTML" > /dev/null 2>&1

        while true; do
            # Ambil updates
            updates=$(curl -s "https://api.telegram.org/bot${TG_BOT_TOKEN}/getUpdates?offset=${LAST_UPDATE_ID}&timeout=30" 2>/dev/null)

            if [ -z "$updates" ]; then
                sleep 2
                continue
            fi

            # Parse messages
            count=$(echo "$updates" | jq -r '.result | length' 2>/dev/null || echo "0")

            for ((i=0; i<count; i++)); do
                update_id=$(echo "$updates" | jq -r ".result[$i].update_id")

                # Cek apakah ini callback query
                has_callback=$(echo "$updates" | jq -r ".result[$i].callback_query // empty" 2>/dev/null)

                if [ -n "$has_callback" ]; then
                    local cb_id cb_data msg_id
                    cb_id=$(echo "$updates" | jq -r ".result[$i].callback_query.id")
                    cb_data=$(echo "$updates" | jq -r ".result[$i].callback_query.data")
                    msg_id=$(echo "$updates" | jq -r ".result[$i].callback_query.message.message_id")

                    log_msg "CALLBACK: $cb_data"
                    handle_callback_action "$cb_id" "$cb_data" "$msg_id"
                else
                    local chat_id text
                    chat_id=$(echo "$updates" | jq -r ".result[$i].message.chat.id")
                    text=$(echo "$updates" | jq -r ".result[$i].message.text")

                    # Hanya respon ke chat ID yang sesuai
                    if [ "$chat_id" != "$TG_CHAT_ID" ]; then
                        LAST_UPDATE_ID=$((update_id + 1))
                        echo "$LAST_UPDATE_ID" > "$offset_file"
                        continue
                    fi

                    log_msg "Command: $text"
                    reply=""

                    case "$text" in
                        /start|/help)
                            reply="<b>Security Monitor Bot</b>\n\n"
                            reply+="<b>Commands:</b>\n"
                            reply+="/status - Status server (uptime, CPU, RAM, disk)\n"
                            reply+="/ports - Port terbuka\n"
                            reply+="/docker - Status container Docker\n"
                            reply+="/firewall - Status UFW firewall\n"
                            reply+="/ssh - Status konfigurasi SSH\n"
                            reply+="/security - Ringkasan keamanan\n"
                            reply+="/alert_on - Aktifkan semua alert\n"
                            reply+="/alert_off - Nonaktifkan semua alert\n"
                            reply+="/reboot - Reboot server (dengan konfirmasi)"
                            ;;
                        /status)
                            uptime_info=$(uptime -p 2>/dev/null || echo "N/A")
                            cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' 2>/dev/null || echo "N/A")
                            ram_info=$(free -h | awk '/Mem:/{print $3"/"$2}' 2>/dev/null || echo "N/A")
                            disk_info=$(df -h / | awk 'NR==2{print $3"/"$2" ("$5" used)"}' 2>/dev/null || echo "N/A")
                            load=$(cat /proc/loadavg | awk '{print $1,$2,$3}' 2>/dev/null || echo "N/A")
                            hostname_info=$(hostname -s 2>/dev/null || echo "server")
                            ip_info=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "N/A")

                            reply="<b>=== Status Server ===</b>\n"
                            reply+="Host: $hostname_info ($ip_info)\n"
                            reply+="Uptime: $uptime_info\n"
                            reply+="Load: $load\n"
                            reply+="CPU: ${cpu_usage}%\n"
                            reply+="RAM: $ram_info\n"
                            reply+="Disk: $disk_info\n"
                            reply+="Waktu: $(date '+%Y-%m-%d %H:%M:%S')"
                            ;;
                        /ports)
                            ports=$(ss -tlnp 2>/dev/null | grep LISTEN | head -20 || echo "N/A")
                            reply="<b>=== Port Terbuka ===</b>\n<code>$ports</code>"
                            ;;
                        /docker)
                            if command -v docker &>/dev/null; then
                                containers=$(sudo docker ps --format "{{.Names}} | {{.Image}} | {{.Status}} | {{.Ports}}" 2>/dev/null || echo "No containers")
                                networks=$(sudo docker network ls --format "{{.Name}} | {{.Driver}}" 2>/dev/null || echo "No networks")
                                reply="<b>=== Docker ===</b>\n\n<b>Containers:</b>\n<code>$containers</code>\n\n<b>Networks:</b>\n<code>$networks</code>"
                            else
                                reply="Docker tidak terinstall"
                            fi
                            ;;
                        /firewall)
                            fw_status=$(sudo ufw status verbose 2>/dev/null || echo "UFW tidak tersedia")
                            reply="<b>=== Firewall ===</b>\n<code>$fw_status</code>"
                            ;;
                        /ssh)
                            ssh_config=$(sudo sshd -T 2>/dev/null | grep -iE "passwordauthentication|pubkeyauthentication|permitrootlogin" || echo "N/A")
                            key_status=$([ -f ~/.ssh/id_ed25519 ] && echo "Ed25519 key ADA" || echo "Belum ada key")
                            reply="<b>=== SSH ===</b>\n<code>$ssh_config</code>\n\nKey: $key_status"
                            ;;
                        /security)
                            reply="<b>=== Ringkasan Keamanan ===</b>\n\n"

                            # SSH
                            pw_auth=$(sudo sshd -T 2>/dev/null | grep -i "passwordauthentication" | head -1 || echo "N/A")
                            reply+="<b>SSH:</b> <code>$pw_auth</code>\n"

                            # UFW
                            ufw_st=$(sudo ufw status 2>/dev/null | head -1 || echo "N/A")
                            reply+="<b>Firewall:</b> $ufw_st\n"

                            # Docker
                            if command -v docker &>/dev/null; then
                                icc=$(sudo docker info 2>/dev/null | grep -i "icc" | head -1 || echo "N/A")
                                reply+="<b>Docker ICC:</b> <code>$icc</code>\n"
                                cnt=$(sudo docker ps -q 2>/dev/null | wc -l)
                                reply+="<b>Containers:</b> $cnt running\n"
                            fi

                            # Key
                            reply+="<b>SSH Key:</b> $([ -f ~/.ssh/id_ed25519 ] && echo 'Ada' || echo 'Belum ada')\n"

                            reply+="\nAlert: SSH=$ALERT_SSH Docker=$ALERT_DOCKER UFW=$ALERT_UFW Disk=$ALERT_DISK"
                            ;;
                        /alert_on)
                            sed -i 's/ALERT_SSH="off"/ALERT_SSH="on"/' "$CONFIG_FILE"
                            sed -i 's/ALERT_DOCKER="off"/ALERT_DOCKER="on"/' "$CONFIG_FILE"
                            sed -i 's/ALERT_UFW="off"/ALERT_UFW="on"/' "$CONFIG_FILE"
                            sed -i 's/ALERT_DISK="off"/ALERT_DISK="on"/' "$CONFIG_FILE"
                            source "$CONFIG_FILE"
                            reply="Semua alert diaktifkan."
                            ;;
                        /alert_off)
                            sed -i 's/ALERT_SSH="on"/ALERT_SSH="off"/' "$CONFIG_FILE"
                            sed -i 's/ALERT_DOCKER="on"/ALERT_DOCKER="off"/' "$CONFIG_FILE"
                            sed -i 's/ALERT_UFW="on"/ALERT_UFW="off"/' "$CONFIG_FILE"
                            sed -i 's/ALERT_DISK="on"/ALERT_DISK="off"/' "$CONFIG_FILE"
                            source "$CONFIG_FILE"
                            reply="Semua alert dinonaktifkan."
                            ;;
                        /reboot)
                            reply="<b>Server akan di-reboot dalam 60 detik.</b>\nKirim /cancel untuk membatalkan."
                            # schedule reboot
                            (sleep 60 && sudo reboot) &
                            REBOOT_PID=$!
                            echo "$REBOOT_PID" > /tmp/reboot-scheduled.pid
                            ;;
                        /cancel)
                            if [ -f /tmp/reboot-scheduled.pid ]; then
                                kill "$(cat /tmp/reboot-scheduled.pid)" 2>/dev/null
                                rm -f /tmp/reboot-scheduled.pid
                                reply="Reboot dibatalkan."
                            else
                                reply="Tidak ada reboot terjadwal."
                            fi
                            ;;
                        *)
                            reply="Command tidak dikenali. Ketik /help untuk daftar command."
                            ;;
                    esac

                    # Kirim balasan
                    if [ -n "$reply" ]; then
                        curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
                            -d chat_id="${TG_CHAT_ID}" \
                            -d text="$reply" \
                            -d parse_mode="HTML" > /dev/null 2>&1
                    fi
                fi

                LAST_UPDATE_ID=$((update_id + 1))
                echo "$LAST_UPDATE_ID" > "$offset_file"
            done

            sleep 1
        done
    ) &

    local pid=$!
    echo "$pid" > "$BOT_PID_FILE"
    print_info "Bot monitor berjalan di background (PID: $pid)"
    print_info "Log: $LOG_FILE"
    echo ""
    echo "Kirim /help ke bot Telegram Anda untuk melihat daftar command."
}

stop_bot_monitor() {
    print_header "Stop Telegram Bot Monitor"

    if [ -f "$BOT_PID_FILE" ]; then
        local pid
        pid=$(cat "$BOT_PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            rm -f "$BOT_PID_FILE"
            print_info "Bot monitor dihentikan (PID: $pid)"

            # Kirim pesan ke Telegram
            if has_tg_config; then
                tg_send_message "Bot monitor dihentikan."
            fi
        else
            rm -f "$BOT_PID_FILE"
            print_warn "Proses sudah tidak berjalan"
        fi
    else
        print_warn "Bot monitor tidak sedang berjalan"
    fi
}

bot_status() {
    print_header "Status Telegram Bot"
    echo ""
    echo "Bot Token  : $([ -n "$TG_BOT_TOKEN" ] && echo "Sudah diset" || echo "Belum diset")"
    echo "Chat ID    : $([ -n "$TG_CHAT_ID" ] && echo "$TG_CHAT_ID" || echo "Belum diset")"
    echo ""
    echo "Alert Settings:"
    echo "  SSH Login    : $ALERT_SSH"
    echo "  Docker Event : $ALERT_DOCKER"
    echo "  UFW Block    : $ALERT_UFW"
    echo "  Disk Space   : $ALERT_DISK"
    echo ""

    # Systemd service status
    if [ -f /etc/systemd/system/security-bot.service ]; then
        if systemctl is-active --quiet security-bot 2>/dev/null; then
            print_info "Systemd Service: BERJALAN"
        else
            print_warn "Systemd Service: BERHENTI"
        fi
    fi

    # Manual mode status
    if [ -f "$BOT_PID_FILE" ] && kill -0 "$(cat "$BOT_PID_FILE")" 2>/dev/null; then
        print_info "Manual Bot Monitor: BERJALAN (PID: $(cat "$BOT_PID_FILE"))"
    else
        [ -f "$BOT_PID_FILE" ] && rm -f "$BOT_PID_FILE"
        if [ ! -f /etc/systemd/system/security-bot.service ]; then
            print_warn "Manual Bot Monitor: BERHENTI"
        fi
    fi

    echo ""
    echo "Log files:"
    echo "  Monitor : $LOG_FILE"
    echo "  Polling : $POLLING_LOG"
    echo "  Actions : $ACTIONS_LOG"
    echo "  Login   : $LOGIN_ALERT_LOG"
    [ -f "$LOG_FILE" ] && echo "" && echo "5 log terakhir:" && tail -5 "$LOG_FILE"
}

# ============================================================
# MENU SYSTEM
# ============================================================

menu_telegram() {
    while true; do
        print_header "Menu Telegram Bot"
        echo ""
        echo -e "  ${BOLD}1.${NC} Set Bot Token"
        echo -e "  ${BOLD}2.${NC} Set Chat ID"
        echo -e "  ${BOLD}3.${NC} Tes Kirim Pesan"
        echo -e "  ${BOLD}4.${NC} Konfigurasi Alert"
        echo -e "  ${BOLD}5.${NC} Install SSH Login Alert Hook"
        echo -e "  ${BOLD}6.${NC} Start Bot Monitor (manual)"
        echo -e "  ${BOLD}7.${NC} Stop Bot Monitor (manual)"
        echo -e "  ${BOLD}8.${NC} Status Bot"
        echo ""
        echo -e "  ${DIM}--- Management ---${NC}"
        echo -e "  ${BOLD}9.${NC} Lihat Alert Terakhir"
        echo -e "  ${BOLD}10.${NC} Lihat / Unblock IP"
        echo -e "  ${BOLD}11.${NC} Statistik Login"
        echo -e "  ${BOLD}12.${NC} Bersihkan Log"
        echo ""
        echo -e "  ${DIM}--- Service ---${NC}"
        echo -e "  ${BOLD}13.${NC} Install Systemd Service"
        echo -e "  ${BOLD}14.${NC} Remove Systemd Service"
        echo ""
        echo -e "  ${BOLD}0.${NC} Kembali ke Menu Utama"
        echo ""

        echo -ne "${YELLOW}[??]${NC} Pilih (0-14): "
        read -r choice

        case $choice in
            1) tg_setup_token ;;
            2) tg_setup_chatid ;;
            3) tg_test_connection ;;
            4) tg_toggle_alerts ;;
            5) install_ssh_alert_hook ;;
            6) start_bot_monitor ;;
            7) stop_bot_monitor ;;
            8) bot_status ;;
            9) show_recent_alerts; press_enter ;;
            10)
                print_header "IP Management"
                echo ""
                echo -e "  ${BOLD}1.${NC} Lihat IP Diblock"
                echo -e "  ${BOLD}2.${NC} Unblock IP"
                echo ""
                echo -ne "${YELLOW}[??]${NC} Pilih (1/2): "
                read -r ip_choice
                case $ip_choice in
                    1) show_blocked_ips; press_enter ;;
                    2) unblock_ip ;;
                esac
                ;;
            11) show_login_stats; press_enter ;;
            12) clean_alert_logs ;;
            13) install_systemd_service ;;
            14) remove_systemd_service ;;
            0) return 0 ;;
            *) print_error "Pilihan tidak valid" ;;
        esac
    done
}

show_main_menu() {
    while true; do
        clear
        print_header "Server Security Hardening & Monitor v3.0"
        echo ""
        echo -e "${BOLD} Security Hardening:${NC}"
        echo -e "  ${BOLD}1.${NC} Setup SSH Key"
        echo -e "  ${BOLD}2.${NC} Nonaktifkan Login Password SSH"
        echo -e "  ${BOLD}3.${NC} Hardening Docker"
        echo -e "  ${BOLD}4.${NC} Isolasi Jaringan Docker"
        echo -e "  ${BOLD}5.${NC} Konfigurasi Firewall UFW"
        echo -e "  ${BOLD}6.${NC} Jalankan Semua Hardening (1-5)"
        echo ""
        echo -e "${BOLD} Monitoring & Telegram:${NC}"
        echo -e "  ${BOLD}7.${NC} Telegram Bot Settings"
        echo ""
        echo -e "${BOLD} Lainnya:${NC}"
        echo -e "  ${BOLD}8.${NC} Verifikasi Keamanan"
        echo -e "  ${BOLD}0.${NC} Keluar"
        echo ""

        echo -ne "${YELLOW}[??]${NC} Pilih menu (0-8): "
        read -r choice

        case $choice in
            1) step_ssh_key_setup; press_enter ;;
            2) step_disable_password_auth; press_enter ;;
            3) step_docker_hardening; press_enter ;;
            4) step_docker_networks; press_enter ;;
            5) step_ufw_firewall; press_enter ;;
            6) run_all_hardening; press_enter ;;
            7) menu_telegram ;;
            8) verify_security; press_enter ;;
            0)
                echo ""
                print_info "Terima kasih!"
                echo ""
                exit 0
                ;;
            *)
                print_error "Pilihan tidak valid"
                press_enter
                ;;
        esac
    done
}

# ============================================================
# ENTRY POINT
# ============================================================

main() {
    check_root
    check_sudo
    check_deps
    load_config
    show_main_menu
}

main "$@"
