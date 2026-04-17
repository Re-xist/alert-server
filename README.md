# Alert Server

Server security monitoring & alert system berbasis Telegram Bot. Monitoring real-time, remote command, SSH login alert, dan hardening otomatis untuk server Linux.

**Developer:** [Martin (Re-xist)](https://github.com/Re-xist)

---

## Fitur

- **SSH Login Alert** - Notifikasi Telegram instan saat ada login SSH
- **Remote Command via Telegram** - Kontrol server dari Telegram (`/status`, `/ban`, `/unban`, dll)
- **UFW Firewall Management** - Kelola firewall langsung dari Telegram
- **Docker Monitoring** - Monitoring container Docker
- **Disk Usage Alert** - Peringatan otomatis jika disk hampir penuh
- **IP Banning** - Ban/unban IP dengan satu pesan
- **Auto Hardening** - Script hardening server (SSH, kernel, network, filesystem)
- **Systemd Service** - Berjalan sebagai service dengan auto-restart

---

## Persyaratan

- OS: Ubuntu / Debian-based Linux
- Akses root (`sudo`)
- Dependencies: `curl`, `jq` (otomatis diinstall oleh installer)
- Akun Telegram

---

## Instalasi

### 1. Clone Repository

```bash
git clone https://github.com/Re-xist/alert-server.git
cd alert-server
```

### 2. Siapkan Telegram Bot

1. Buka Telegram, cari **@BotFather**
2. Kirim `/newbot`
3. Ikuti instruksi - beri nama dan username untuk bot
4. Salin **Bot Token** yang diberikan (format: `123456789:ABCdefGHIjklMNOpqrsTUVwxyz`)
5. Kirim pesan apa saja ke bot baru Anda (untuk keperluan auto-detect Chat ID)

### 3. Jalankan Installer

```bash
sudo bash install.sh
```

Installer akan memandu Anda melalui:

| Step | Deskripsi |
|------|-----------|
| 1 | Validasi Bot Token (otomatis cek ke API Telegram) |
| 2 | Pilih Chat ID - auto-detect atau input manual |
| 3 | Tes koneksi - kirim pesan tes ke Telegram |

Installer secara otomatis akan:
- Install dependencies (`curl`, `jq`)
- Simpan konfigurasi ke `~/.security-hardening.conf`
- Setup SSH login alert hook
- Install dan start systemd service `security-bot`
- Kirim pesan tes ke Telegram

### 4. Verifikasi

```bash
# Cek status service
systemctl status security-bot

# Lihat log real-time
journalctl -u security-bot -f
```

Jika berhasil, Anda akan menerima pesan di Telegram: **"Security Bot berhasil diinstall!"**

---

## Konfigurasi Manual

Jika ingin setup tanpa installer interaktif:

```bash
# Copy template config
cp config.example ~/.security-hardening.conf

# Edit config
nano ~/.security-hardening.conf
```

Isi nilai yang diperlukan:

```bash
TG_BOT_TOKEN="123456789:ABCdefGHIjklMNOpqrsTUVwxyz"
TG_CHAT_ID="123456789"

# Toggle alert on/off
ALERT_SSH="on"
ALERT_DOCKER="on"
ALERT_UFW="on"
ALERT_DISK="on"
```

Lalu install service manual:

```bash
# Copy service file (edit path dulu)
sudo cp security-bot.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable security-bot
sudo systemctl start security-bot
```

---

## Penggunaan

### Perintah Telegram

Kirim perintah ini ke bot Anda di Telegram:

| Command | Fungsi |
|---------|--------|
| `/start` | Mulai bot / tampilkan info |
| `/help` | Daftar semua perintah |
| `/status` | Cek status server (CPU, RAM, Disk, Uptime) |
| `/ban <ip>` | Blokir IP address |
| `/unban <ip>` | Lepas blokir IP address |
| `/banned` | Lihat daftar IP yang diblokir |
| `/ufw status` | Status firewall UFW |
| `/ufw allow <port>` | Buka port di firewall |
| `/ufw deny <port>` | Tutup port di firewall |
| `/docker` | Status container Docker |
| `/restart docker` | Restart Docker service |
| `/reboot` | Reboot server (dengan konfirmasi) |
| `/logs <n>` | Tampilkan n log terakhir |

### Menu Interaktif

Jalankan script utama untuk menu hardening interaktif:

```bash
sudo bash security-hardening.sh
```

Menu yang tersedia:
1. SSH Hardening
2. Firewall Setup
3. System Update
4. Docker Monitoring
5. Disk Usage Check
6. Network Monitoring
7. dll.

---

## Struktur File

```
alert-server/
├── install.sh              # Setup wizard interaktif
├── security-hardening.sh   # Menu hardening utama
├── bot-daemon.sh           # Telegram polling daemon
├── login-alert.sh          # SSH login notifier
├── security-bot.service    # Systemd unit file
├── config.example          # Template konfigurasi
└── README.md               # Dokumentasi (file ini)
```

---

## Management Service

```bash
# Start service
sudo systemctl start security-bot

# Stop service
sudo systemctl stop security-bot

# Restart service
sudo systemctl restart security-bot

# Cek status
sudo systemctl status security-bot

# Lihat log
sudo journalctl -u security-bot -f

# Disable auto-start
sudo systemctl disable security-bot
```

---

## File Log

| File | Isi |
|------|-----|
| `/var/log/telegram-alerts/alerts.db` | Database alert |
| `/var/log/telegram-polling.log` | Log polling daemon |
| `/var/log/telegram-actions.log` | Log aksi (ban, UFW, dll) |
| `/var/log/login-alerts.log` | Log SSH login alert |
| `/etc/banned_ips.txt` | Daftar IP yang dibanned |

---

## Uninstall

```bash
# Stop dan remove service
sudo systemctl stop security-bot
sudo systemctl disable security-bot
sudo rm /etc/systemd/system/security-bot.service
sudo systemctl daemon-reload

# Remove SSH alert hook
sudo rm /etc/profile.d/security-alert-ssh.sh

# Remove config dan log
rm ~/.security-hardening.conf
sudo rm -rf /var/log/telegram-alerts
sudo rm /var/log/telegram-polling.log
sudo rm /var/log/telegram-actions.log
sudo rm /var/log/login-alerts.log
```

---

## Keamanan

- Config file disimpan dengan permission `600` (hanya root bisa baca)
- Token Telegram **tidak** disimpan di dalam script, hanya di config file
- Service berjalan sebagai root untuk akses penuh ke system tools
- Remote reboot membutuhkan konfirmasi

**Tips keamanan tambahan:**
- Jangan share Bot Token atau Chat ID
- Gunakan private repository jika fork project ini
- Aktifkan 2FA di akun GitHub dan server
- Review log secara berkala

---

## Kontribusi

Pull request dan issue welcome di [https://github.com/Re-xist/alert-server](https://github.com/Re-xist/alert-server)

---

## Lisensi

MIT License - Bebas digunakan dan dimodifikasi.

---

**Made by [Martin](https://github.com/Re-xist) from Jakarta, Indonesia**
