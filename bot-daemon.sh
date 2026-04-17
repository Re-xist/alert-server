#!/bin/bash
# ============================================================
#  Security Bot Daemon
#
#  Polling daemon yang menangani:
#   - Callback queries (Logout, Block IP, Allow, Info)
#   - Bot commands (/status, /ports, /docker, /firewall, dll)
#   - Offset tracking via file
#   - Logging ke /var/log/telegram-polling.log
#
#  Penggunaan:
#    bash bot-daemon.sh            (foreground)
#    systemctl start security-bot  (via systemd)
# ============================================================

CONFIG_FILE="$HOME/.security-hardening.conf"

# Load config
if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"
fi

# Path defaults
TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"
ALERT_DB_DIR="${ALERT_DB_DIR:-/var/log/telegram-alerts}"
ALERT_DB_FILE="${ALERT_DB_FILE:-/var/log/telegram-alerts/alerts.db}"
POLLING_LOG="${POLLING_LOG:-/var/log/telegram-polling.log}"
ACTIONS_LOG="${ACTIONS_LOG:-/var/log/telegram-actions.log}"
BANNED_IPS_FILE="${BANNED_IPS_FILE:-/etc/banned_ips.txt}"
OFFSET_FILE="${ALERT_DB_DIR}/offset.txt"

# Buat direktori dan file yang diperlukan
mkdir -p "$ALERT_DB_DIR"
touch "$ALERT_DB_FILE" "$ACTIONS_LOG" "$POLLING_LOG"
[ -f "$OFFSET_FILE" ] || echo "0" > "$OFFSET_FILE"

export TZ="${TZ:-Asia/Jakarta}"

# ============================================================
# HELPER FUNCTIONS
# ============================================================

log_msg() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" >> "$POLLING_LOG"
}

log_action() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$ACTIONS_LOG"
}

escape_json() {
    echo "$1" | sed 's/"/\\"/g'
}

# ============================================================
# TELEGRAM API HELPERS
# ============================================================

answer_callback() {
    local callback_id="$1"
    local text="$2"
    local show_alert="${3:-false}"

    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/answerCallbackQuery" \
        -d callback_query_id="$callback_id" \
        -d text="$text" \
        -d show_alert="$show_alert" > /dev/null 2>&1
}

edit_message() {
    local chat_id="$1"
    local message_id="$2"
    local text="$3"
    local keyboard="$4"

    local args=(-s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/editMessageText"
        -d chat_id="$chat_id"
        -d message_id="$message_id"
        -d text="$(escape_json "$text")"
        -d parse_mode="Markdown")

    if [ -n "$keyboard" ]; then
        args+=(-d reply_markup="$keyboard")
    fi

    curl "${args[@]}" > /dev/null 2>&1
}

send_message() {
    local chat_id="$1"
    local text="$2"
    local parse_mode="${3:-HTML}"

    curl -s -X POST "https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage" \
        -d chat_id="$chat_id" \
        -d text="$text" \
        -d parse_mode="$parse_mode" > /dev/null 2>&1
}

# ============================================================
# CALLBACK HANDLERS
# ============================================================

callback_logout() {
    local alert_id="$1"

    local session_data
    session_data=$(grep "^${alert_id}|" "$ALERT_DB_FILE" | tail -1)

    if [ -z "$session_data" ]; then
        echo "ERROR|Session tidak ditemukan (mungkin sudah expired)"
        return 1
    fi

    local username ip pid tty
    username=$(echo "$session_data" | cut -d'|' -f3)
    ip=$(echo "$session_data" | cut -d'|' -f5)
    pid=$(echo "$session_data" | cut -d'|' -f6)
    tty=$(echo "$session_data" | cut -d'|' -f7)

    local killed=0
    if [ -n "$tty" ] && [ "$tty" != "N/A" ]; then
        pkill -9 -t "$tty" 2>/dev/null && killed=1
    fi
    if [ -n "$pid" ] && [ "$pid" != "0" ] && [ "$pid" != "N/A" ]; then
        kill -9 "$pid" 2>/dev/null && killed=1
    fi

    if [ "$killed" -eq 1 ]; then
        log_action "LOGOUT: User $username (session $alert_id) kicked"
        echo "SUCCESS|✅ User $username berhasil dikick!"
    else
        log_action "LOGOUT FAILED: User $username (session $alert_id)"
        echo "ERROR|Gagal mengkick user (session mungkin sudah tidak aktif)"
    fi
}

callback_block() {
    local alert_id="$1"

    local session_data
    session_data=$(grep "^${alert_id}|" "$ALERT_DB_FILE" | tail -1)

    if [ -z "$session_data" ]; then
        echo "ERROR|Session tidak ditemukan"
        return 1
    fi

    local ip username
    ip=$(echo "$session_data" | cut -d'|' -f5)
    username=$(echo "$session_data" | cut -d'|' -f3)

    if [ "$ip" = "LOCAL" ] || [ "$ip" = "127.0.0.1" ] || [ "$ip" = "N/A" ]; then
        echo "ERROR|Tidak bisa block localhost"
        return 1
    fi

    # Block dengan iptables
    if command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -s "$ip" -j DROP 2>/dev/null || iptables -A INPUT -s "$ip" -j DROP 2>/dev/null
        iptables-save > /etc/iptables.rules 2>/dev/null
    fi

    # Block dengan ufw
    if command -v ufw >/dev/null 2>&1; then
        ufw deny from "$ip" 2>/dev/null
    fi

    # Save ke banned list
    if ! grep -q "^${ip}$" "$BANNED_IPS_FILE" 2>/dev/null; then
        echo "$ip" >> "$BANNED_IPS_FILE"
    fi

    log_action "BLOCK: IP $ip (user $username, session $alert_id) blocked"
    echo "SUCCESS|✅ IP $ip berhasil diblock!"
}

callback_allow() {
    local alert_id="$1"
    log_action "ALLOW: Session $alert_id allowed"
    echo "SUCCESS|✅ Login diizinkan"
}

callback_info() {
    local alert_id="$1"

    local session_data
    session_data=$(grep "^${alert_id}|" "$ALERT_DB_FILE" | tail -1)

    if [ -z "$session_data" ]; then
        echo "ERROR|Session tidak ditemukan"
        return 1
    fi

    local login_time username user_id ip pid tty
    login_time=$(echo "$session_data" | cut -d'|' -f2)
    username=$(echo "$session_data" | cut -d'|' -f3)
    user_id=$(echo "$session_data" | cut -d'|' -f4)
    ip=$(echo "$session_data" | cut -d'|' -f5)
    pid=$(echo "$session_data" | cut -d'|' -f6)
    tty=$(echo "$session_data" | cut -d'|' -f7)

    log_action "INFO: Session $alert_id queried"

    echo "SUCCESS|ℹ️ SESSION INFO:

👤 User: $username (ID: $user_id)
🌐 IP: $ip
⏰ Login: $login_time
📱 PID: $pid
🖥️  TTY: $tty
🔑 Alert ID: $alert_id"
}

# ============================================================
# HANDLE CALLBACK QUERY
# ============================================================

handle_callback() {
    local callback_id="$1"
    local callback_data="$2"
    local message_id="$3"
    local chat_id="$4"

    local action="${callback_data%%_*}"
    local alert_id="${callback_data#*_}"

    log_msg "CALLBACK: $action for alert $alert_id"

    case "$action" in
        logout)
            local result
            result=$(callback_logout "$alert_id")
            local status="${result%%|*}"
            local message="${result#*|}"

            answer_callback "$callback_id" "$message" "true"

            if [ "$status" = "SUCCESS" ]; then
                local new_keyboard='{"inline_keyboard": [[{"text": "🔴 USER DIKICK", "callback_data": "done"}]]}'
                edit_message "$chat_id" "$message_id" "$message

🚫 *Session terminated*" "$new_keyboard"
            fi
            ;;

        block)
            local result
            result=$(callback_block "$alert_id")
            local status="${result%%|*}"
            local message="${result#*|}"

            answer_callback "$callback_id" "$message" "true"

            if [ "$status" = "SUCCESS" ]; then
                local new_keyboard='{"inline_keyboard": [[{"text": "⛔ IP DIBLOCK", "callback_data": "done"}]]}'
                edit_message "$chat_id" "$message_id" "$message

🔒 *IP Address blocked*" "$new_keyboard"
            fi
            ;;

        allow)
            answer_callback "$callback_id" "✅ Login diizinkan" "false"
            local new_keyboard='{"inline_keyboard": [[{"text": "✅ LOGIN DIZINKAN", "callback_data": "done"}]]}'
            edit_message "$chat_id" "$message_id" "✅ *Login diizinkan*

Session tetap aktif." "$new_keyboard"
            log_action "ALLOW: Session $alert_id allowed"
            ;;

        info)
            local result
            result=$(callback_info "$alert_id")
            local status="${result%%|*}"
            local message="${result#*|}"

            answer_callback "$callback_id" "ℹ️ Info dikirim" "false"

            if [ "$status" = "SUCCESS" ]; then
                send_message "$chat_id" "$message" "Markdown"
            fi
            ;;

        done)
            answer_callback "$callback_id" "Aksi sudah dilakukan" "false"
            ;;

        *)
            answer_callback "$callback_id" "Aksi tidak dikenal" "true"
            ;;
    esac
}

# ============================================================
# HANDLE BOT COMMAND
# ============================================================

handle_bot_command() {
    local chat_id="$1"
    local text="$2"
    local reply=""

    local hostname
    hostname=$(hostname -s 2>/dev/null || echo "server")

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
            local uptime_info cpu_usage ram_info disk_info load ip_info
            uptime_info=$(uptime -p 2>/dev/null || echo "N/A")
            cpu_usage=$(top -bn1 | grep "Cpu(s)" | awk '{print $2}' 2>/dev/null || echo "N/A")
            ram_info=$(free -h | awk '/Mem:/{print $3"/"$2}' 2>/dev/null || echo "N/A")
            disk_info=$(df -h / | awk 'NR==2{print $3"/"$2" ("$5" used)"}' 2>/dev/null || echo "N/A")
            load=$(cat /proc/loadavg | awk '{print $1,$2,$3}' 2>/dev/null || echo "N/A")
            ip_info=$(hostname -I | awk '{print $1}' 2>/dev/null || echo "N/A")

            reply="<b>=== Status Server ===</b>\n"
            reply+="Host: $hostname ($ip_info)\n"
            reply+="Uptime: $uptime_info\n"
            reply+="Load: $load\n"
            reply+="CPU: ${cpu_usage}%\n"
            reply+="RAM: $ram_info\n"
            reply+="Disk: $disk_info\n"
            reply+="Waktu: $(date '+%Y-%m-%d %H:%M:%S')"
            ;;
        /ports)
            local ports
            ports=$(ss -tlnp 2>/dev/null | grep LISTEN | head -20 || echo "N/A")
            reply="<b>=== Port Terbuka ===</b>\n<code>$ports</code>"
            ;;
        /docker)
            if command -v docker &>/dev/null; then
                local containers networks
                containers=$(docker ps --format "{{.Names}} | {{.Image}} | {{.Status}} | {{.Ports}}" 2>/dev/null || echo "No containers")
                networks=$(docker network ls --format "{{.Name}} | {{.Driver}}" 2>/dev/null || echo "No networks")
                reply="<b>=== Docker ===</b>\n\n<b>Containers:</b>\n<code>$containers</code>\n\n<b>Networks:</b>\n<code>$networks</code>"
            else
                reply="Docker tidak terinstall"
            fi
            ;;
        /firewall)
            local fw_status
            fw_status=$(ufw status verbose 2>/dev/null || echo "UFW tidak tersedia")
            reply="<b>=== Firewall ===</b>\n<code>$fw_status</code>"
            ;;
        /ssh)
            local ssh_config key_status
            ssh_config=$(sshd -T 2>/dev/null | grep -iE "passwordauthentication|pubkeyauthentication|permitrootlogin" || echo "N/A")
            key_status=$([ -f ~/.ssh/id_ed25519 ] && echo "Ed25519 key ADA" || echo "Belum ada key")
            reply="<b>=== SSH ===</b>\n<code>$ssh_config</code>\n\nKey: $key_status"
            ;;
        /security)
            reply="<b>=== Ringkasan Keamanan ===</b>\n\n"

            local pw_auth
            pw_auth=$(sshd -T 2>/dev/null | grep -i "passwordauthentication" | head -1 || echo "N/A")
            reply+="<b>SSH:</b> <code>$pw_auth</code>\n"

            local ufw_st
            ufw_st=$(ufw status 2>/dev/null | head -1 || echo "N/A")
            reply+="<b>Firewall:</b> $ufw_st\n"

            if command -v docker &>/dev/null; then
                local icc cnt
                icc=$(docker info 2>/dev/null | grep -i "icc" | head -1 || echo "N/A")
                reply+="<b>Docker ICC:</b> <code>$icc</code>\n"
                cnt=$(docker ps -q 2>/dev/null | wc -l)
                reply+="<b>Containers:</b> $cnt running\n"
            fi

            reply+="<b>SSH Key:</b> $([ -f ~/.ssh/id_ed25519 ] && echo 'Ada' || echo 'Belum ada')\n"

            local alert_ssh alert_docker alert_ufw alert_disk
            # Re-read config for current values
            if [ -f "$CONFIG_FILE" ]; then
                alert_ssh=$(grep '^ALERT_SSH=' "$CONFIG_FILE" | cut -d'"' -f2)
                alert_docker=$(grep '^ALERT_DOCKER=' "$CONFIG_FILE" | cut -d'"' -f2)
                alert_ufw=$(grep '^ALERT_UFW=' "$CONFIG_FILE" | cut -d'"' -f2)
                alert_disk=$(grep '^ALERT_DISK=' "$CONFIG_FILE" | cut -d'"' -f2)
            fi
            reply+="\nAlert: SSH=${alert_ssh:-on} Docker=${alert_docker:-on} UFW=${alert_ufw:-on} Disk=${alert_disk:-on}"
            ;;
        /alert_on)
            sed -i 's/ALERT_SSH="off"/ALERT_SSH="on"/' "$CONFIG_FILE"
            sed -i 's/ALERT_DOCKER="off"/ALERT_DOCKER="on"/' "$CONFIG_FILE"
            sed -i 's/ALERT_UFW="off"/ALERT_UFW="on"/' "$CONFIG_FILE"
            sed -i 's/ALERT_DISK="off"/ALERT_DISK="on"/' "$CONFIG_FILE"
            reply="Semua alert diaktifkan."
            ;;
        /alert_off)
            sed -i 's/ALERT_SSH="on"/ALERT_SSH="off"/' "$CONFIG_FILE"
            sed -i 's/ALERT_DOCKER="on"/ALERT_DOCKER="off"/' "$CONFIG_FILE"
            sed -i 's/ALERT_UFW="on"/ALERT_UFW="off"/' "$CONFIG_FILE"
            sed -i 's/ALERT_DISK="on"/ALERT_DISK="off"/' "$CONFIG_FILE"
            reply="Semua alert dinonaktifkan."
            ;;
        /reboot)
            reply="<b>Server akan di-reboot dalam 60 detik.</b>\nKirim /cancel untuk membatalkan."
            (sleep 60 && reboot) &
            local reboot_pid=$!
            echo "$reboot_pid" > /tmp/reboot-scheduled.pid
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

    if [ -n "$reply" ]; then
        send_message "$chat_id" "$reply" "HTML"
    fi
}

# ============================================================
# MAIN POLLING LOOP
# ============================================================

run_polling_loop() {
    if [ -z "$TG_BOT_TOKEN" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: TG_BOT_TOKEN not set" >> "$POLLING_LOG"
        exit 1
    fi

    # Baca offset terakhir
    OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null || echo "0")
    log_msg "Bot daemon started (offset: $OFFSET)"

    # Kirim pesan start
    local hostname
    hostname=$(hostname -s 2>/dev/null || echo "server")
    send_message "$TG_CHAT_ID" "<b>[$hostname]</b> Security Bot daemon dimulai!\nKirim /help untuk daftar command." "HTML"

    while true; do
        # Ambil updates
        local response
        response=$(curl -s "https://api.telegram.org/bot${TG_BOT_TOKEN}/getUpdates?offset=${OFFSET}&timeout=30" 2>/dev/null)

        if [ -z "$response" ]; then
            sleep 2
            continue
        fi

        # Cek response valid
        if ! echo "$response" | grep -q '"ok":true'; then
            log_msg "ERROR: Invalid response from Telegram"
            sleep 5
            continue
        fi

        # Hitung jumlah result
        local count
        count=$(echo "$response" | jq -r '.result | length' 2>/dev/null || echo "0")

        if [ "$count" -eq 0 ]; then
            sleep 1
            continue
        fi

        # Proses setiap update
        for ((i=0; i<count; i++)); do
            local update_id
            update_id=$(echo "$response" | jq -r ".result[$i].update_id")

            # Cek apakah ini callback query
            local has_callback
            has_callback=$(echo "$response" | jq -r ".result[$i].callback_query // empty" 2>/dev/null)

            if [ -n "$has_callback" ]; then
                # Handle callback
                local callback_id callback_data message_id chat_id
                callback_id=$(echo "$response" | jq -r ".result[$i].callback_query.id")
                callback_data=$(echo "$response" | jq -r ".result[$i].callback_query.data")
                message_id=$(echo "$response" | jq -r ".result[$i].callback_query.message.message_id")
                chat_id=$(echo "$response" | jq -r ".result[$i].callback_query.message.chat.id")

                log_msg "CALLBACK: $callback_data (cb: $callback_id, msg: $message_id)"

                handle_callback "$callback_id" "$callback_data" "$message_id" "$chat_id"
            else
                # Handle text message
                local chat_id text
                chat_id=$(echo "$response" | jq -r ".result[$i].message.chat.id")
                text=$(echo "$response" | jq -r ".result[$i].message.text")

                # Hanya respon ke chat ID yang sesuai
                if [ "$chat_id" != "$TG_CHAT_ID" ]; then
                    OFFSET=$((update_id + 1))
                    echo "$OFFSET" > "$OFFSET_FILE"
                    continue
                fi

                if [ -n "$text" ]; then
                    log_msg "COMMAND: $text"
                    handle_bot_command "$chat_id" "$text"
                fi
            fi

            # Update offset
            OFFSET=$((update_id + 1))
            echo "$OFFSET" > "$OFFSET_FILE"
        done

        sleep 1
    done
}

# ============================================================
# ENTRY POINT
# ============================================================

run_polling_loop
