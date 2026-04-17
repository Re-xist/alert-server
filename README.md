# Alert Server

Telegram Bot-based server security monitoring & alert system. Real-time monitoring, remote commands, SSH login alerts, and automatic hardening for Linux servers.

**Developer:** [Re-xist](https://github.com/Re-xist)

---

## Features

- **SSH Login Alert** - Instant Telegram notification on SSH login
- **Remote Command via Telegram** - Control server from Telegram (`/status`, `/ban`, `/unban`, etc.)
- **UFW Firewall Management** - Manage firewall directly from Telegram
- **Docker Monitoring** - Monitor Docker containers
- **Disk Usage Alert** - Automatic warning when disk is almost full
- **IP Banning** - Ban/unban IP with a single message
- **Auto Hardening** - Server hardening script (SSH, kernel, network, filesystem)
- **Systemd Service** - Runs as a service with auto-restart

---

## Requirements

- OS: Ubuntu / Debian-based Linux
- Root access (`sudo`)
- Dependencies: `curl`, `jq` (auto-installed by installer)
- Telegram account

---

## Installation

### 1. Clone Repository

```bash
git clone https://github.com/Re-xist/alert-server.git
cd alert-server
```

### 2. Setup Telegram Bot

1. Open Telegram, search for **@BotFather**
2. Send `/newbot`
3. Follow the instructions - provide a name and username for the bot
4. Copy the **Bot Token** provided (format: `123456789:ABCdefGHIjklMNOpqrsTUVwxyz`)
5. Send any message to your new bot (required for auto-detect Chat ID)

### 3. Run Installer

```bash
sudo bash install.sh
```

The installer will guide you through:

| Step | Description |
|------|-------------|
| 1 | Validate Bot Token (automatic check via Telegram API) |
| 2 | Select Chat ID - auto-detect or manual input |
| 3 | Test connection - send test message to Telegram |

The installer will automatically:
- Install dependencies (`curl`, `jq`)
- Save configuration to `~/.security-hardening.conf`
- Setup SSH login alert hook
- Install and start systemd service `security-bot`
- Send a test message to Telegram

### 4. Verify

```bash
# Check service status
systemctl status security-bot

# View real-time logs
journalctl -u security-bot -f
```

If successful, you will receive a message on Telegram: **"Security Bot berhasil diinstall!"**

---

## Manual Configuration

If you prefer to setup without the interactive installer:

```bash
# Copy config template
cp config.example ~/.security-hardening.conf

# Edit config
nano ~/.security-hardening.conf
```

Fill in the required values:

```bash
TG_BOT_TOKEN="123456789:ABCdefGHIjklMNOpqrsTUVwxyz"
TG_CHAT_ID="123456789"

# Toggle alerts on/off
ALERT_SSH="on"
ALERT_DOCKER="on"
ALERT_UFW="on"
ALERT_DISK="on"
```

Then install the service manually:

```bash
# Copy service file (edit path first)
sudo cp security-bot.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable security-bot
sudo systemctl start security-bot
```

---

## Usage

### Telegram Commands

Send these commands to your bot on Telegram:

| Command | Description |
|---------|-------------|
| `/start` | Start bot / show info |
| `/help` | List all commands |
| `/status` | Check server status (CPU, RAM, Disk, Uptime) |
| `/ban <ip>` | Block an IP address |
| `/unban <ip>` | Unblock an IP address |
| `/banned` | View list of blocked IPs |
| `/ufw status` | Show UFW firewall status |
| `/ufw allow <port>` | Open port in firewall |
| `/ufw deny <port>` | Close port in firewall |
| `/docker` | Show Docker container status |
| `/restart docker` | Restart Docker service |
| `/reboot` | Reboot server (with confirmation) |
| `/logs <n>` | Show last n log entries |

### Interactive Menu

Run the main script for the interactive hardening menu:

```bash
sudo bash security-hardening.sh
```

Available options:
1. SSH Hardening
2. Firewall Setup
3. System Update
4. Docker Monitoring
5. Disk Usage Check
6. Network Monitoring
7. And more...

---

## File Structure

```
alert-server/
├── install.sh              # Interactive setup wizard
├── security-hardening.sh   # Main hardening menu
├── bot-daemon.sh           # Telegram polling daemon
├── login-alert.sh          # SSH login notifier
├── security-bot.service    # Systemd unit file
├── config.example          # Configuration template
└── README.md               # Documentation (this file)
```

---

## Service Management

```bash
# Start service
sudo systemctl start security-bot

# Stop service
sudo systemctl stop security-bot

# Restart service
sudo systemctl restart security-bot

# Check status
sudo systemctl status security-bot

# View logs
sudo journalctl -u security-bot -f

# Disable auto-start
sudo systemctl disable security-bot
```

---

## Log Files

| File | Content |
|------|---------|
| `/var/log/telegram-alerts/alerts.db` | Alert database |
| `/var/log/telegram-polling.log` | Polling daemon log |
| `/var/log/telegram-actions.log` | Action log (ban, UFW, etc.) |
| `/var/log/login-alerts.log` | SSH login alert log |
| `/etc/banned_ips.txt` | Banned IP list |

---

## Uninstall

```bash
# Stop and remove service
sudo systemctl stop security-bot
sudo systemctl disable security-bot
sudo rm /etc/systemd/system/security-bot.service
sudo systemctl daemon-reload

# Remove SSH alert hook
sudo rm /etc/profile.d/security-alert-ssh.sh

# Remove config and logs
rm ~/.security-hardening.conf
sudo rm -rf /var/log/telegram-alerts
sudo rm /var/log/telegram-polling.log
sudo rm /var/log/telegram-actions.log
sudo rm /var/log/login-alerts.log
```

---

## Security

- Config file is saved with `600` permission (root only)
- Telegram token is **not** stored inside scripts, only in config file
- Service runs as root for full access to system tools
- Remote reboot requires confirmation

**Additional security tips:**
- Never share your Bot Token or Chat ID
- Use a private repository if you fork this project
- Enable 2FA on your GitHub account and server
- Review logs periodically

---

## Contributing

Pull requests and issues are welcome at [https://github.com/Re-xist/alert-server](https://github.com/Re-xist/alert-server)

---

## License

MIT License - Free to use and modify.

---

**Made by [Re-xist](https://github.com/Re-xist)**
