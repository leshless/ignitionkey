#!/bin/bash
set -e

RED='\033[1;31m'
CYAN='\033[1;96m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m'

BASE_PACKAGES="curl tree wget git tmux unzip gnupg software-properties-common apt-transport-https ca-certificates ufw fail2ban docker-ce docker-ce-cli containerd.io docker-compose-plugin"
DEFAULT_HOSTNAME="vm"
DEFAULT_TIMEZONE="Europe/Moscow"
DEFAULT_USER_NAME="admin"

print_default() {
    echo -e "[$(date "+%d %b %Y %H:%M:%S")] ${CYAN}$1${NC}"
}

print_success() {
    echo -e "[$(date "+%d %b %Y %H:%M:%S")] ${GREEN}$1${NC}"
}

print_warning() {
    echo -e "[$(date "+%d %b %Y %H:%M:%S")] ${YELLOW}$1${NC}"
}

print_error() {
    echo -e "[$(date "+%d %b %Y %H:%M:%S")] ${RED}$1${NC}"
}

if [[ $EUID -ne 0 ]]; then
   print_error "Root access required, try rerunning with sudo"
   exit 1
fi

print_default "🔥 Ignition started!"

# Update packages
print_default "Updating packages (this may take a while)..."

apt update 1>/dev/null
DEBIAN_FRONTEND=noninteractive apt upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" 1>/dev/null


print_success "Packages sucessfully updated"

# Install docker
set +e
command -v docker 1>/dev/null

if [ $? -gt 0 ]; then
    set -e

    print_default "Fetching docker installation script..."

    wget -O get-docker.sh https://get.docker.com 1>/dev/null

    print_default "Installing docker..."

    sh get-docker.sh &> /dev/null
    rm -f get-docker.sh 

    print_success "Docker successfully installed"
else
    print_warning "Docker seems to be already installed, skip installation"
fi

set -e

# Install base packages
print_default "Installing base utilites..."

apt install -y $BASE_PACKAGES &> /dev/null

print_success "Utilites sucessfully installed"

# Set hostname
read -p "Specify hostname to set for this machine (default \"$DEFAULT_HOSTNAME\"): " HOSTNAME
HOSTNAME=${HOSTNAME:-$DEFAULT_HOSTNAME}

hostnamectl set-hostname "$HOSTNAME"
echo "127.0.1.1 $HOSTNAME" >> /etc/hosts

print_success "Hostname successfully set"

# Set timezone
read -p "Specify timezone (default \"$DEFAULT_TIMEZONE\"): " TIMEZONE
TIMEZONE=${TIMEZONE:-$DEFAULT_TIMEZONE}

timedatectl set-timezone "$TIMEZONE"

print_success "Timezone successfully set"

# Create user
read -p "Specify name for a default user (default \"$DEFAULT_USER_NAME\"): " USER_NAME
USER_NAME=${USER_NAME:-$DEFAULT_USER_NAME}

if id "$USER_NAME" &>/dev/null; then
    print_warning "User \"$USER_NAME\" already exists, skip adding user"
else
    read -sp "Enter password for a default user: " USER_PASSWORD
    echo ""
    if [ -z "$USER_PASSWORD" ]; then
        print_error "User password shouldn't be blank"
        exit 1
    fi

    print_default "Creating default user..."

    useradd -m -s /bin/bash "$USER_NAME"
    echo "$USER_NAME:$USER_PASSWORD" | chpasswd

    usermod -aG sudo,docker "$USER_NAME"
    echo "$USER_NAME ALL=(ALL:ALL) ALL" >> /etc/sudoers.d/"$USER_NAME"
    chmod 0440 /etc/sudoers.d/"$USER_NAME"
fi

# Add ssh keys
echo "Enter public ssh keys (one by line):"
SSH_KEYS=""
while true; do
    read SSH_KEY
    if [ -z "$SSH_KEY" ]; then
        break
    fi
    SSH_KEYS+="$SSH_KEY"$'\n'
done

if [ -z "$SSH_KEYS" ]; then
    print_error "At least one ssh key should be provided"
    exit 1
fi

print_default "Adding ssh keys..."

mkdir -p "/home/$USER_NAME/.ssh"
echo "$SSH_KEYS" > "/home/$USER_NAME/.ssh/authorized_keys"
chmod 700 "/home/$USER_NAME/.ssh"
chmod 600 "/home/$USER_NAME/.ssh/authorized_keys"
chown -R "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.ssh"

print_success "SSH keys sucessfully added..."

# Configure ssh
print_default "Configuring ssh..."

cat > /etc/ssh/sshd_config << EOF
Port 22

ListenAddress 0.0.0.0

Protocol 2

PubkeyAuthentication yes
PasswordAuthentication no
PermitEmptyPasswords no

PermitRootLogin no
StrictModes yes
MaxAuthTries 3
MaxSessions 10
ClientAliveInterval 300
ClientAliveCountMax 2

AllowUsers $USER_NAME

X11Forwarding no
PrintMotd no
PrintLastLog yes
TCPKeepAlive yes
UsePAM yes
EOF

print_success "SSH config sucessfully updated"

# Restart SSH
print_default "Restarting ssh..."

systemctl restart ssh

print_success "SSH daemon sucessfully restarted"

# Configure firewall
print_default "Configuring firewall..."

ufw --force reset &> /dev/null
ufw default deny incoming
ufw default allow outgoing

ufw allow 22/tcp comment 'SSH'

ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'

ufw --force enable &> /dev/null
ufw status verbose

print_success "Firewall successfully configured"

# Configure shell
print_default "Configuring shell..."

cat > "/home/$USER_NAME/.bashrc" << EOF
export PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '

alias ll='ls -la'
alias la='ls -A'
alias l='ls -CF'
alias grep='grep --color=auto'
alias egrep='egrep --color=auto'
alias fgrep='fgrep --color=auto'
alias df='df -h'
alias du='du -h'

alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'

alias free='free -h'

export HISTSIZE=10000
export HISTFILESIZE=20000
export HISTCONTROL=ignoreboth
shopt -s histappend

export LS_COLORS='rs=0:di=01;34:ln=01;36:mh=00:pi=40;33'

export PATH=$PATH:/usr/local/bin:/usr/local/sbin
EOF

chown "$USER_NAME:$USER_NAME" "/home/$USER_NAME/.bashrc"

print_success "BASH successfully configured"

# Configure MOTD
print_default "Configuring MOTD..."

rm -rf /etc/update-motd.d/* 2>/dev/null

rm -f /etc/motd
rm -f /etc/motd.tail 2>/dev/null
rm -f /etc/motd.head 2>/dev/null
rm -f /var/run/motd.dynamic 2>/dev/null

systemctl disable motd-news.timer 2>/dev/null
systemctl stop motd-news.timer 2>/dev/null
systemctl mask motd-news.timer 2>/dev/null

systemctl disable apt-daily.timer 2>/dev/null
systemctl stop apt-daily.timer 2>/dev/null

cat > /etc/update-motd.d/00-header << 'EOF'
#!/bin/bash

G='\033[0;32m'
Y='\033[1;33m'
R='\033[0;31m'
B='\033[0;34m'
C='\033[0;96m'
CB='\033[1;96m'
N='\033[0m'

echo ""
echo -e "=== ${CB}Welcome to $(hostname)${N}! ==="
echo -e "Date:          ${C}$(date '+%H:%M:%S %d.%m.%Y')${N}"
echo -e "Uptime:        ${C}$(uptime -p)${N}"
echo -e "LA:            ${C}$(cat /proc/loadavg | awk '{print $1"/"$2"/"$3}')${N}"

mem=$(free -m | awk '/^Mem:/ {printf "%.1f/%.1fG (%.0f%%)", $3/1024, $2/1024, $3/$2*100}')
echo -e "Memory:        ${C}$mem${N}"

root_disk=$(df -h / | awk 'NR==2 {print $5 " (" $3 "/" $2 ")"}')
echo -e "Disk Usage:    ${C}$root_disk${N}"
echo ""
EOF

chmod +x /etc/update-motd.d/00-header

print_success "MOTD successfully configured"

print_success "🔥 Ignition completed!"

echo ""
echo "To connect to this machine again use ssh $USER_NAME@$(curl -s ifconfig.me)"
echo "You should finish current session and reconnect as soon as possible"
echo ""
