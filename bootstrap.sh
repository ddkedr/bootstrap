#!/usr/bin/env bash
#===============================================================================
# Bootstrap script for new Ubuntu/Debian machines
#
# Interactive. At the start you pick a profile:
#   1) cloud - VPS with a public IP (ufw, fail2ban, swap default to YES)
#   2) local - VM/CT on Proxmox behind NAT (those default to NO)
# SSH hardening (root login off, password auth off) defaults to YES on both:
# a sudo user with a key makes root login pointless anywhere, and the
# emergency key plus console cover the lockout case. The profile only
# changes the DEFAULT answers - every step can still be confirmed or
# skipped individually.
#
# Usage, from the console of a fresh machine as root:
#   apt-get update -qq && apt-get install -y -qq curl && curl -fsSL https://raw.githubusercontent.com/ddkedr/bootstrap/main/bootstrap.sh -o bootstrap.sh && bash bootstrap.sh
# (minimal CT/VM images ship without curl; the script needs it too)
#
# This script is the server half of the SSH key scheme; the scheme itself,
# its docs and the `keymaster` command live in the private repo
# github.com/ddkedr/keymaster. Step 6 below only does the first key fetch;
# afterwards `keymaster server-add` (run on the laptop, the exact line is
# printed at the end) installs /usr/local/bin/keymaster on this host, which
# keeps authorized_keys in sync with GitHub via `sudo keymaster pull`.
#===============================================================================

set -euo pipefail

SCRIPT_VERSION="2.0"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a   # keep needrestart from opening interactive dialogs

#-------------------------------------------------------------------------------
# Colors / logging
#-------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1" >&2; }

trap 'log_error "Script failed at line $LINENO"' ERR

#-------------------------------------------------------------------------------
# Helpers
#-------------------------------------------------------------------------------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
}

# Make sure we can read answers even when the script is piped in
ensure_tty() {
    if [[ ! -t 0 ]]; then
        if { exec < /dev/tty; } 2>/dev/null; then
            return
        fi
        log_error "Interactive script needs a terminal."
        log_error "Over ssh run it with -t:  ssh -t root@host 'bash /root/bootstrap.sh'"
        log_error "Do not pipe it into bash."
        exit 1
    fi
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS_NAME="$NAME"
        OS_ID="$ID"
    else
        log_error "Cannot detect OS. Exiting."
        exit 1
    fi

    if [[ "$OS_ID" != "ubuntu" && "$OS_ID" != "debian" ]]; then
        log_warning "This script is designed for Ubuntu/Debian. Detected: $OS_NAME"
        if ! prompt_yes_no "Continue anyway?" "no"; then
            exit 0
        fi
    fi

    log_info "Detected: $OS_NAME"
}

# Drop keystrokes typed while a previous step was busy (e.g. Enter pressed
# during a long curl), so they are not taken as the answer to the next prompt
flush_input() {
    while read -r -t 0; do read -r _ || break; done
}

prompt_yes_no() {
    local prompt="$1"
    local default="${2:-no}"
    local hint="[y/N]" defchar="n" response

    if [[ "$default" == "yes" ]]; then
        hint="[Y/n]"
        defchar="y"
    fi

    while true; do
        flush_input
        read -r -p "$prompt $hint: " response
        response="${response:-$defchar}"
        case "$response" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo])     return 1 ;;
        esac
    done
}

# Default answer depending on profile: pdef <cloud-default> <local-default>
pdef() {
    if [[ "$PROFILE" == "cloud" ]]; then
        echo "$1"
    else
        echo "$2"
    fi
}

# SIGPIPE-safe password generator (head first, tr second)
gen_password() {
    local pw=""
    while (( ${#pw} < 24 )); do
        pw+="$(head -c 48 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')"
    done
    printf '%s' "${pw:0:24}"
}

APT_UPDATED="no"
apt_install() {
    if [[ "$APT_UPDATED" == "no" ]]; then
        log_info "Refreshing package lists..."
        apt-get update -qq
        APT_UPDATED="yes"
    fi
    apt-get install -y -qq "$@"
}

SUMMARY=()
add_summary() { SUMMARY+=("$1"); }

#===============================================================================
# MAIN SCRIPT
#===============================================================================

check_root
ensure_tty

# Log the whole session (prompts and command output) for later diagnostics.
# Secrets are printed straight to the terminal, bypassing the log.
LOG_FILE="/var/log/bootstrap.log"
exec > >(tee -a "$LOG_FILE") 2>&1
log_info "Bootstrap v$SCRIPT_VERSION started at $(date -Is), logging to $LOG_FILE"

detect_os
echo

#-------------------------------------------------------------------------------
# STEP 0: Profile selection
#-------------------------------------------------------------------------------
log_info "=== STEP 0: Server Profile ==="
echo "  1) cloud - VPS with a public IP (UFW, fail2ban, swap default to YES)"
echo "  2) local - VM/CT on Proxmox behind NAT (those default to NO)"
echo "  SSH hardening (root off, password off) defaults to YES for both."

PROFILE=""
while [[ -z "$PROFILE" ]]; do
    read -r -p "Select profile [1/2]: " REPLY
    case "$REPLY" in
        1|cloud) PROFILE="cloud" ;;
        2|local) PROFILE="local" ;;
    esac
done
log_success "Profile: $PROFILE"
add_summary "Profile: $PROFILE"

# curl is used for the GitHub check, the key fetch and later by keymaster
# pull; minimal images come without it
if ! command -v curl &>/dev/null; then
    log_info "curl is missing, installing..."
    apt_install curl ca-certificates
fi

# Keys come from github.com, both here (step 6) and later via keymaster pull.
# A LAN host reaches GitHub only through the tunnel, so check before going on.
if [[ "$PROFILE" == "local" ]]; then
    log_warning "LAN host: make sure this machine is routed through the tunnel to GitHub"
    log_warning "(policy route on OpenWRT), otherwise key fetch and keymaster pull will fail."
fi
while true; do
    if curl -m 10 -sSI https://github.com -o /dev/null 2>/dev/null; then
        log_success "github.com is reachable"
        break
    fi
    log_error "github.com is NOT reachable from this host (10s timeout)"
    if prompt_yes_no "Fix the route and re-check?" "yes"; then
        continue
    fi
    if prompt_yes_no "Continue without GitHub access? (keys must then be pasted by hand)" "no"; then
        break
    fi
    exit 1
done
echo

#-------------------------------------------------------------------------------
# STEP 1: Hostname
#-------------------------------------------------------------------------------
log_info "=== STEP 1: Hostname ==="

CURRENT_HOSTNAME=$(hostname)
log_info "Current hostname: $CURRENT_HOSTNAME"

if prompt_yes_no "Set hostname?" "yes"; then
    NEW_HOSTNAME=""
    while [[ -z "$NEW_HOSTNAME" ]]; do
        read -r -p "New hostname [$CURRENT_HOSTNAME]: " NEW_HOSTNAME
        NEW_HOSTNAME=${NEW_HOSTNAME:-$CURRENT_HOSTNAME}
        if [[ ! "$NEW_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?$ ]]; then
            log_warning "Invalid hostname: $NEW_HOSTNAME"
            NEW_HOSTNAME=""
        fi
    done

    if [[ "$NEW_HOSTNAME" != "$CURRENT_HOSTNAME" ]]; then
        hostnamectl set-hostname "$NEW_HOSTNAME"
        # Hostname must resolve locally, or sudo & co. get slow and whiny
        if grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
            sed -i "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts
        else
            printf '127.0.1.1\t%s\n' "$NEW_HOSTNAME" >> /etc/hosts
        fi
        log_success "Hostname set to $NEW_HOSTNAME"
        add_summary "Hostname: $NEW_HOSTNAME"
    else
        log_info "Hostname unchanged"
    fi
else
    log_info "Keeping hostname $CURRENT_HOSTNAME"
fi
echo

#-------------------------------------------------------------------------------
# STEP 2: System update/upgrade
#-------------------------------------------------------------------------------
log_info "=== STEP 2: System Update ==="
if prompt_yes_no "Update system packages?" "yes"; then
    log_info "Updating package lists..."
    apt-get update -qq
    APT_UPDATED="yes"

    log_info "Upgrading packages (keeping existing config files)..."
    apt-get upgrade -y -qq \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"

    log_success "System updated"
    add_summary "System packages updated"
else
    log_info "Skipping system update"
fi
echo

#-------------------------------------------------------------------------------
# STEP 3: Non-root user
#-------------------------------------------------------------------------------
log_info "=== STEP 3: Non-Root User ==="

# Under sudo, whoami is root - the invoking user is in SUDO_USER
DEFAULT_USER="${SUDO_USER:-}"
if [[ "$DEFAULT_USER" == "root" ]]; then
    DEFAULT_USER=""
fi

NEW_USER=""
while [[ -z "$NEW_USER" ]]; do
    if [[ -n "$DEFAULT_USER" ]]; then
        read -r -p "Username to create/use [$DEFAULT_USER]: " NEW_USER
        NEW_USER=${NEW_USER:-$DEFAULT_USER}
    else
        read -r -p "Username to create/use: " NEW_USER
    fi
    if [[ ! "$NEW_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        log_warning "Invalid username: $NEW_USER"
        NEW_USER=""
    fi
done

if id "$NEW_USER" &>/dev/null; then
    log_warning "User '$NEW_USER' already exists - using it for the following steps."
else
    log_info "Creating user: $NEW_USER"

    if prompt_yes_no "Generate random password?" "yes"; then
        NEW_PASSWORD=$(gen_password)
        GENERATED_PASSWORD="yes"
    else
        NEW_PASSWORD=""
        while [[ -z "$NEW_PASSWORD" ]]; do
            read -r -s -p "Enter password for $NEW_USER: " NEW_PASSWORD
            echo
        done
        GENERATED_PASSWORD="no"
    fi

    useradd -m -s /bin/bash "$NEW_USER"
    echo "$NEW_USER:$NEW_PASSWORD" | chpasswd

    # Debian minimal images may not have sudo at all
    command -v sudo &>/dev/null || apt_install sudo
    usermod -aG sudo "$NEW_USER"

    log_success "User '$NEW_USER' created and added to sudo group"
    if [[ "$GENERATED_PASSWORD" == "yes" ]]; then
        log_warning "Generated password for $NEW_USER (store it now - not saved anywhere, kept out of $LOG_FILE):"
        echo "    $NEW_PASSWORD" > /dev/tty
    fi
    add_summary "Created user: $NEW_USER (sudo)"
fi

# Passwordless sudo: password-based sudo mostly protects against casual
# access to an open session; NOPASSWD removes the lost-password lockout
# scenario for a key-only admin user.
if [[ -f "/etc/sudoers.d/$NEW_USER" ]]; then
    log_info "sudoers drop-in for $NEW_USER already exists - leaving it as is"
elif prompt_yes_no "Enable passwordless sudo (NOPASSWD) for $NEW_USER?" "yes"; then
    echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/$NEW_USER"
    chmod 440 "/etc/sudoers.d/$NEW_USER"
    if visudo -cf "/etc/sudoers.d/$NEW_USER" >/dev/null; then
        log_success "Passwordless sudo enabled for $NEW_USER"
        add_summary "Passwordless sudo (NOPASSWD) for $NEW_USER"
    else
        rm -f "/etc/sudoers.d/$NEW_USER"
        log_error "Generated sudoers entry failed validation - removed, sudo unchanged"
    fi
fi

FINAL_USER="$NEW_USER"
USER_HOME=$(getent passwd "$FINAL_USER" | cut -d: -f6)
echo

#-------------------------------------------------------------------------------
# STEP 4: Common utilities
#-------------------------------------------------------------------------------
log_info "=== STEP 4: Common Utilities ==="
if prompt_yes_no "Install common utilities (curl, git, htop, vim, ...)?" "yes"; then
    apt_install \
        curl \
        git \
        htop \
        vim \
        gnupg \
        lsb-release \
        ca-certificates \
        apt-transport-https \
        software-properties-common
    log_success "Common utilities installed"
    add_summary "Common utilities installed"
else
    log_info "Skipping utilities installation"
fi
echo

#-------------------------------------------------------------------------------
# STEP 5: QEMU Guest Agent (Proxmox/KVM VMs)
#-------------------------------------------------------------------------------
log_info "=== STEP 5: QEMU Guest Agent ==="

VIRT_CONTAINER=$(systemd-detect-virt --container 2>/dev/null) || VIRT_CONTAINER="none"
VIRT_VM=$(systemd-detect-virt --vm 2>/dev/null) || VIRT_VM="none"

if [[ "$VIRT_CONTAINER" != "none" ]]; then
    log_info "Container ($VIRT_CONTAINER) detected - guest agent not needed, Proxmox manages CTs directly"
elif [[ "$VIRT_VM" == "none" ]]; then
    log_info "No hypervisor detected - skipping guest agent"
elif prompt_yes_no "Install qemu-guest-agent (clean shutdown, IP in UI, consistent snapshots)?" "$(pdef no yes)"; then
    apt_install qemu-guest-agent
    if systemctl enable --now qemu-guest-agent 2>/dev/null; then
        log_success "qemu-guest-agent installed and running"
    else
        log_warning "Agent installed but not started - enable the 'QEMU Guest Agent' option in VM settings (Proxmox: VM -> Options), then reboot"
    fi
    add_summary "qemu-guest-agent installed"
else
    log_info "Skipping guest agent"
fi
echo

#-------------------------------------------------------------------------------
# STEP 6: SSH keys for the user
#
# First delivery only: keys are appended as plain lines. Ongoing sync (and
# revocation through GitHub) is done by `keymaster pull`, installed from the
# laptop by `keymaster server-add` once this script is done; its first run
# moves these lines into its managed block.
#-------------------------------------------------------------------------------
log_info "=== STEP 6: SSH Keys ==="

AUTH_KEYS="$USER_HOME/.ssh/authorized_keys"
KEYS_ADDED="no"

validate_ssh_key() {
    ssh-keygen -lf /dev/stdin <<<"$1" &>/dev/null
}

install_ssh_key() {
    local key="$1"
    install -d -m 700 -o "$FINAL_USER" -g "$FINAL_USER" "$USER_HOME/.ssh"
    touch "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"
    chown "$FINAL_USER:$FINAL_USER" "$AUTH_KEYS"
    if grep -qxF "$key" "$AUTH_KEYS" 2>/dev/null; then
        log_info "Key already present, skipping: $(ssh-keygen -lf /dev/stdin <<<"$key" | awk '{print $2}')"
    else
        echo "$key" >> "$AUTH_KEYS"
        log_success "Key added: $(ssh-keygen -lf /dev/stdin <<<"$key" | awk '{print $2}')"
        KEYS_ADDED="yes"
    fi
}

if prompt_yes_no "Add SSH key(s) for $FINAL_USER?" "yes"; then
    while true; do
        echo "  1) Fetch from GitHub (https://github.com/<username>.keys)"
        echo "  2) Paste a public key manually"
        echo "  3) Done / skip"
        read -r -p "Choose [1/2/3]: " KEY_CHOICE

        case "$KEY_CHOICE" in
            1)
                read -r -p "GitHub username: " GH_USER
                if [[ -z "$GH_USER" ]]; then
                    continue
                fi
                if GH_KEYS=$(curl -fsSL --max-time 20 "https://github.com/$GH_USER.keys") && [[ -n "$GH_KEYS" ]]; then
                    while IFS= read -r key; do
                        if [[ -z "$key" ]]; then continue; fi
                        if validate_ssh_key "$key"; then
                            install_ssh_key "$key"
                        else
                            log_warning "Skipping invalid key line from GitHub"
                        fi
                    done <<<"$GH_KEYS"
                else
                    log_error "Failed to fetch keys for GitHub user '$GH_USER'"
                    log_warning "Check that this host can reach github.com: curl -m 10 -sSI https://github.com"
                    log_warning "Without that, keymaster pull will not work here either. Option 2 pastes a key without GitHub."
                fi
                ;;
            2)
                read -r -p "Paste public key (ssh-ed25519/ssh-rsa ...): " PASTED_KEY
                if validate_ssh_key "$PASTED_KEY"; then
                    install_ssh_key "$PASTED_KEY"
                else
                    log_error "That does not look like a valid public key"
                fi
                ;;
            3)
                break
                ;;
        esac

        prompt_yes_no "Add another key?" "no" || break
    done
else
    log_info "Skipping SSH keys"
fi

# Provider may have already put a key into the user's authorized_keys via cloud-init
if [[ "$KEYS_ADDED" == "no" && -s "$AUTH_KEYS" ]]; then
    log_info "Note: $AUTH_KEYS already contains key(s)"
fi
if [[ "$KEYS_ADDED" == "yes" ]]; then
    add_summary "SSH key(s) installed for $FINAL_USER"
fi
echo

#-------------------------------------------------------------------------------
# STEP 7: SSH hardening
#-------------------------------------------------------------------------------
log_info "=== STEP 7: SSH Hardening ==="

SSH_PORT=""
SSHD_DROPIN="/etc/ssh/sshd_config.d/00-bootstrap.conf"

if prompt_yes_no "Configure SSH hardening?" "yes"; then
    # --- Port ---
    while true; do
        read -r -p "SSH port [22]: " SSH_PORT
        SSH_PORT=${SSH_PORT:-22}
        if [[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1 && SSH_PORT <= 65535 )); then
            break
        fi
        log_warning "Invalid port: $SSH_PORT"
    done

    # --- Root login ---
    DISABLE_ROOT="no"
    if prompt_yes_no "Disable root login?" "yes"; then
        DISABLE_ROOT="yes"
    fi

    # --- Password authentication ---
    DISABLE_PASSWORDS="no"
    if [[ -s "$AUTH_KEYS" ]]; then
        if prompt_yes_no "Disable password authentication (key-only login)?" "yes"; then
            DISABLE_PASSWORDS="yes"
        fi
    else
        log_warning "No authorized_keys for $FINAL_USER - refusing to disable password auth (lockout risk)"
    fi

    # --- Write config as a drop-in ---
    # Modern Ubuntu/Debian include /etc/ssh/sshd_config.d/*.conf at the TOP of
    # sshd_config, and sshd uses the FIRST value it sees. A low-sorting file
    # (00-*) therefore overrides both the main config and cloud-init's
    # 50-cloud-init.conf. Editing sshd_config with sed is unreliable for
    # exactly that reason.
    mkdir -p /etc/ssh/sshd_config.d
    if ! grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d' /etc/ssh/sshd_config; then
        cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.backup.$(date +%Y%m%d%H%M%S)"
        sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' /etc/ssh/sshd_config
        log_info "Added Include directive to /etc/ssh/sshd_config (backup created)"
    fi

    {
        echo "# Managed by bootstrap.sh - safe to delete to revert"
        echo "Port $SSH_PORT"
        if [[ "$DISABLE_ROOT" == "yes" ]]; then
            echo "PermitRootLogin no"
        fi
        if [[ "$DISABLE_PASSWORDS" == "yes" ]]; then
            echo "PasswordAuthentication no"
            echo "KbdInteractiveAuthentication no"
        fi
    } > "$SSHD_DROPIN"

    # --- Validate before touching the running daemon ---
    SSHD_BIN=$(command -v sshd || echo /usr/sbin/sshd)
    if ! SSHD_CHECK=$("$SSHD_BIN" -t 2>&1); then
        log_error "sshd config validation failed. Output of 'sshd -t':"
        echo "--------------------------------------------------------------"
        echo "${SSHD_CHECK:-(sshd -t produced no output)}"
        echo "--------------------------------------------------------------"
        mv "$SSHD_DROPIN" "${SSHD_DROPIN}.rejected"
        log_error "Generated config kept for inspection: ${SSHD_DROPIN}.rejected"
        log_error "(inactive - the Include only matches *.conf). sshd was NOT restarted,"
        log_error "the previous working configuration is still in effect."
        log_error "Fix the issue and re-run this step, or inspect with: sshd -T"
        exit 1
    fi

    # --- Apply ---
    # Ubuntu 22.10+ runs ssh socket-activated: systemd's ssh.socket owns the
    # listen port and ignores 'Port' in sshd_config. Ubuntu 24.04+ ships
    # sshd-socket-generator, which syncs the port from sshd_config into the
    # socket on daemon-reload; on releases without it, fall back to the
    # classic always-running ssh.service.
    systemctl daemon-reload
    if [[ "$SSH_PORT" != "22" ]] && systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
        if [[ -x /usr/lib/systemd/system-generators/sshd-socket-generator ]]; then
            log_info "ssh.socket with port generator detected - keeping socket activation"
            systemctl restart ssh.socket
        else
            log_info "ssh.socket without port generator - switching to classic ssh.service..."
            systemctl disable --now ssh.socket
            systemctl enable ssh.service
        fi
    fi
    systemctl restart ssh 2>/dev/null || systemctl restart sshd

    # --- Verify something actually listens on the chosen port ---
    sleep 1
    if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${SSH_PORT}\$"; then
        log_success "SSH is listening on port $SSH_PORT"
    else
        log_warning "Could NOT confirm a listener on port $SSH_PORT!"
        log_warning "Investigate before closing this session: ss -tlnp | grep -i ssh"
    fi

    # --- Verify the effective sshd config, not just the file we wrote ---
    # sshd -T prints the merged result of sshd_config + all drop-ins; if a
    # later drop-in or the main file wins, this is where it shows.
    EFFECTIVE=$("$SSHD_BIN" -T 2>/dev/null | grep -Ei '^(permitrootlogin|passwordauthentication) ' || true)
    log_info "Effective sshd settings:"
    echo "$EFFECTIVE" | sed 's/^/    /'
    if [[ "$DISABLE_ROOT" == "yes" ]] && ! grep -qi '^permitrootlogin no' <<<"$EFFECTIVE"; then
        log_warning "PermitRootLogin is NOT 'no' in the effective config - another file overrides it"
    fi
    if [[ "$DISABLE_PASSWORDS" == "yes" ]] && ! grep -qi '^passwordauthentication no' <<<"$EFFECTIVE"; then
        log_warning "PasswordAuthentication is NOT 'no' in the effective config - another file overrides it"
    fi

    # --- An active firewall must let the (possibly new) port through, or the
    # next login times out even though sshd listens ---
    if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
        if ! ufw status | grep -qE "^${SSH_PORT}/tcp\s+ALLOW"; then
            log_warning "ufw is active and does not allow port $SSH_PORT - adding the rule"
            ufw allow "$SSH_PORT/tcp" comment "SSH"
        fi
        if [[ "$SSH_PORT" != "22" ]] && ufw status | grep -qE "^22/tcp\s+ALLOW"; then
            log_warning "ufw still allows port 22; remove it once port $SSH_PORT is verified: ufw delete allow 22/tcp"
        fi
    fi

    log_success "SSH hardening applied ($SSHD_DROPIN)"
    log_warning "Do NOT close this session yet! Verify in a NEW terminal first:"
    log_warning "    ssh -p $SSH_PORT $FINAL_USER@<this-host>"

    add_summary "SSH: port $SSH_PORT, root login $([[ "$DISABLE_ROOT" == "yes" ]] && echo disabled || echo unchanged), password auth $([[ "$DISABLE_PASSWORDS" == "yes" ]] && echo disabled || echo unchanged)"
else
    log_info "Skipping SSH hardening"
fi
echo

#-------------------------------------------------------------------------------
# STEP 8: Firewall (ufw)
#-------------------------------------------------------------------------------
log_info "=== STEP 8: Firewall (ufw) ==="

if prompt_yes_no "Setup firewall (ufw)?" "$(pdef yes no)"; then
    command -v ufw &>/dev/null || apt_install ufw

    ufw default deny incoming
    ufw default allow outgoing

    UFW_SSH_PORT="${SSH_PORT:-22}"
    log_info "Allowing SSH on port $UFW_SSH_PORT..."
    ufw allow "$UFW_SSH_PORT/tcp" comment "SSH"

    read -r -p "Additional ports to allow (comma-separated, e.g. 80,443,51820/udp): " ADDITIONAL_PORTS
    if [[ -n "$ADDITIONAL_PORTS" ]]; then
        IFS=',' read -ra PORT_LIST <<<"$ADDITIONAL_PORTS"
        for entry in "${PORT_LIST[@]}"; do
            entry=$(echo "$entry" | tr -d '[:space:]')
            if [[ -z "$entry" ]]; then continue; fi
            port="${entry%%/*}"
            proto="tcp"
            if [[ "$entry" == */* ]]; then proto="${entry##*/}"; fi
            if [[ "$port" =~ ^[0-9]+$ ]] && [[ "$proto" =~ ^(tcp|udp)$ ]]; then
                ufw allow "$port/$proto" comment "bootstrap: $port/$proto"
                log_info "Allowed $port/$proto"
            else
                log_warning "Skipping invalid entry: $entry"
            fi
        done
    fi

    if prompt_yes_no "Enable firewall now?" "yes"; then
        if echo "y" | ufw enable; then
            log_success "Firewall enabled"
            add_summary "UFW enabled (SSH on $UFW_SSH_PORT allowed)"
        else
            log_warning "ufw enable failed - possibly running in a container without the needed capabilities"
        fi
    else
        log_info "Firewall rules written but ufw NOT enabled"
    fi

    log_warning "Note: Docker publishes container ports via iptables directly, BYPASSING ufw rules."
    log_warning "Bind containers to 127.0.0.1 (e.g. '127.0.0.1:8080:80') unless they must be public."
else
    log_info "Skipping firewall setup"
fi
echo

#-------------------------------------------------------------------------------
# STEP 9: Fail2ban
#-------------------------------------------------------------------------------
log_info "=== STEP 9: Fail2ban ==="

if prompt_yes_no "Install and configure Fail2ban (SSH jail)?" "$(pdef yes no)"; then
    command -v fail2ban-server &>/dev/null || apt_install fail2ban

    read -r -p "Whitelist IPs/CIDRs (comma-separated, optional): " FAIL2BAN_WHITELIST
    FAIL2BAN_WHITELIST=$(echo "${FAIL2BAN_WHITELIST:-}" | tr ',' ' ')

    # Debian 12+ has no /var/log/auth.log by default - fail2ban must read journald
    F2B_BACKEND=""
    if [[ ! -f /var/log/auth.log ]]; then
        log_info "No /var/log/auth.log found - using systemd journal backend"
        apt_install python3-systemd
        F2B_BACKEND="backend = systemd"
    fi

    cat > /etc/fail2ban/jail.local <<EOF
# Managed by bootstrap.sh
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
ignoreip = 127.0.0.1/8 ::1${FAIL2BAN_WHITELIST:+ $FAIL2BAN_WHITELIST}

[sshd]
enabled  = true
port     = ${SSH_PORT:-ssh}
maxretry = 3
${F2B_BACKEND}
EOF

    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban

    if systemctl is-active --quiet fail2ban; then
        log_success "Fail2ban configured and running"
        add_summary "Fail2ban: SSH jail on port ${SSH_PORT:-22}"
    else
        log_error "Fail2ban failed to start - check: journalctl -u fail2ban"
    fi
else
    log_info "Skipping Fail2ban"
fi
echo

#-------------------------------------------------------------------------------
# STEP 10: Automatic security updates
#-------------------------------------------------------------------------------
log_info "=== STEP 10: Automatic Security Updates ==="

if prompt_yes_no "Enable unattended security upgrades?" "yes"; then
    apt_install unattended-upgrades

    cat > /etc/apt/apt.conf.d/20auto-upgrades <<EOF
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

    systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true

    log_success "Unattended security upgrades enabled (security repos only, no auto-reboot)"
    add_summary "Unattended security upgrades enabled"
else
    log_info "Skipping automatic updates"
fi
echo

#-------------------------------------------------------------------------------
# STEP 11: Docker
#-------------------------------------------------------------------------------
log_info "=== STEP 11: Docker ==="

# Where Docker came from decides whether apt keeps it current:
#   docker-ce  official docker.com repo, updated by step 2 and unattended-upgrades
#   docker.io  distro package, months behind, only bumps with the distro
#   snap       separate world, data lives in /var/snap/docker, not /var/lib/docker
DOCKER_SOURCE="none"
if dpkg -s docker-ce &>/dev/null; then
    DOCKER_SOURCE="docker-ce"
elif dpkg -s docker.io &>/dev/null; then
    DOCKER_SOURCE="docker.io"
elif command -v snap &>/dev/null && snap list docker &>/dev/null; then
    DOCKER_SOURCE="snap"
elif command -v docker &>/dev/null; then
    DOCKER_SOURCE="other"
fi

# Show the current state before asking: the answer means different things
# on a bare host (install) and on one that already runs Docker (only the
# log rotation and group membership below are touched, nothing reinstalled)
if [[ "$DOCKER_SOURCE" != "none" ]]; then
    log_info "Docker: installed ($(docker --version 2>/dev/null | sed 's/,.*//'), source: $DOCKER_SOURCE)"
    DOCKER_PROMPT="Configure Docker (log rotation, docker group for $FINAL_USER)? Nothing is reinstalled."
else
    log_info "Docker: not installed"
    DOCKER_PROMPT="Install Docker?"
fi

if prompt_yes_no "$DOCKER_PROMPT" "yes"; then
    if [[ "$VIRT_CONTAINER" != "none" ]]; then
        log_warning "This looks like a container (LXC/CT). Docker inside a CT needs nesting=1 and may still misbehave - a VM is more reliable."
    fi

    # Distro package: offer to move to the official repo. Images, containers
    # and volumes stay in /var/lib/docker; containers stop for the duration
    # and come back if they have a restart policy.
    if [[ "$DOCKER_SOURCE" == "docker.io" ]]; then
        log_warning "Docker comes from the distro package docker.io ($(docker --version 2>/dev/null | sed 's/,.*//')), which lags behind docker.com by months."
        if prompt_yes_no "Migrate to the official docker-ce repo? (containers restart, data in /var/lib/docker is kept)" "yes"; then
            log_info "Stopping Docker and removing the distro packages..."
            systemctl stop docker docker.socket 2>/dev/null || true
            apt-get remove -y -qq docker.io docker-doc docker-compose podman-docker containerd runc 2>/dev/null || true
            DOCKER_SOURCE="none"
        fi
    elif [[ "$DOCKER_SOURCE" == "snap" ]]; then
        log_warning "Docker is installed as a snap. Its data lives in /var/snap/docker, NOT /var/lib/docker,"
        log_warning "so a migration would not carry containers and volumes over. Not touching it."
        log_warning "To migrate by hand: export what matters, 'snap remove docker', rerun this step."
    elif [[ "$DOCKER_SOURCE" == "docker-ce" ]]; then
        # docker-ce without its apt repo (typically lost in a release upgrade)
        # never gets updates: apt sees no newer candidate. Re-add the repo for
        # the current release so step 2 and unattended-upgrades can do their job.
        CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
        if ! grep -rqs "download.docker.com/linux/$OS_ID $CODENAME" /etc/apt/sources.list.d/; then
            log_warning "docker-ce is installed, but the docker.com apt repo for $OS_ID $CODENAME is missing:"
            log_warning "installed $(dpkg-query -W -f='${Version}' docker-ce 2>/dev/null), apt cannot see anything newer."
            if prompt_yes_no "Add the docker.com repo for $CODENAME and update Docker? (containers restart)" "yes"; then
                install -d -m 755 /etc/apt/keyrings
                curl -fsSL "https://download.docker.com/linux/$OS_ID/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
                chmod a+r /etc/apt/keyrings/docker.gpg
                echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS_ID $CODENAME stable" \
                    > /etc/apt/sources.list.d/docker.list
                apt-get update -qq
                apt-get install -y -qq --only-upgrade docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
                log_success "Docker updated to $(docker --version 2>/dev/null | sed 's/,.*//')"
                add_summary "Docker apt repo restored ($CODENAME), Docker updated"
            fi
        fi
    fi

    if [[ "$DOCKER_SOURCE" != "none" ]]; then
        log_info "Docker already installed, skipping installation"
    elif prompt_yes_no "Use Docker convenience script (get.docker.com)?" "yes"; then
        curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
        sh /tmp/get-docker.sh
        rm -f /tmp/get-docker.sh
    else
        log_info "Installing Docker from the official apt repository..."
        install -d -m 755 /etc/apt/keyrings
        curl -fsSL "https://download.docker.com/linux/$OS_ID/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$OS_ID $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
            > /etc/apt/sources.list.d/docker.list
        apt-get update -qq
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi

    if command -v docker &>/dev/null; then
        systemctl enable --now docker >/dev/null 2>&1 || true

        # Cap container logs: Docker's default json-file driver is unbounded,
        # and a chatty container will eventually fill the disk
        if [[ ! -f /etc/docker/daemon.json ]]; then
            mkdir -p /etc/docker
            cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
EOF
            systemctl restart docker >/dev/null 2>&1 || true
            log_success "Container log rotation configured (10m x 3 files per container)"
        else
            log_warning "/etc/docker/daemon.json already exists - not touching it; verify log-opts (max-size/max-file) yourself"
        fi

        if prompt_yes_no "Add $FINAL_USER to the docker group? (docker group = root-equivalent access)" "yes"; then
            usermod -aG docker "$FINAL_USER"
            log_success "$FINAL_USER added to docker group (re-login required)"
        fi

        log_success "Docker installed"
        add_summary "Docker installed (source: $(dpkg -s docker-ce &>/dev/null && echo docker-ce || echo "$DOCKER_SOURCE"))"
    else
        log_error "Docker installation failed"
    fi
else
    log_info "Skipping Docker installation"
fi
echo

#-------------------------------------------------------------------------------
# STEP 12: Journald: persistent and capped
#-------------------------------------------------------------------------------
log_info "=== STEP 12: Journald ==="

if prompt_yes_no "Make journal persistent (survives reboot) and cap it at 500M?" "yes"; then
    mkdir -p /etc/systemd/journald.conf.d
    cat > /etc/systemd/journald.conf.d/00-bootstrap.conf <<EOF
# Managed by bootstrap.sh
[Journal]
# persistent: auth history survives reboots (needed to audit logins by key fingerprint)
Storage=persistent
SystemMaxUse=500M
EOF
    systemctl restart systemd-journald
    log_success "Journal persistent, capped at 500M"
    add_summary "Journald: persistent storage, capped at 500M"
else
    log_warning "Journal left as is - if it is volatile, login history is lost on reboot"
fi
echo

#-------------------------------------------------------------------------------
# STEP 13: Swap file
#-------------------------------------------------------------------------------
log_info "=== STEP 13: Swap ==="

if [[ "$VIRT_CONTAINER" != "none" ]]; then
    log_info "Container detected - swap is managed by the Proxmox host, skipping"
elif [[ -n "$(swapon --show --noheadings 2>/dev/null)" ]]; then
    log_info "Swap already active:"
    swapon --show
elif prompt_yes_no "Create a swap file (OOM safety net)?" "$(pdef yes no)"; then
    SWAP_SIZE=""
    while [[ -z "$SWAP_SIZE" ]]; do
        read -r -p "Swap size in GiB (1-8) [2]: " SWAP_SIZE
        SWAP_SIZE=${SWAP_SIZE:-2}
        if [[ ! "$SWAP_SIZE" =~ ^[1-8]$ ]]; then
            log_warning "Enter a number from 1 to 8"
            SWAP_SIZE=""
        fi
    done

    log_info "Creating ${SWAP_SIZE}G swap file..."
    if ! fallocate -l "${SWAP_SIZE}G" /swapfile 2>/dev/null; then
        dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_SIZE * 1024)) status=none
    fi
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
    swapon /swapfile
    if ! grep -qE '^/swapfile[[:space:]]' /etc/fstab; then
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi
    # Prefer RAM, keep swap as a safety net only
    echo 'vm.swappiness=10' > /etc/sysctl.d/99-bootstrap-swappiness.conf
    sysctl -q -p /etc/sysctl.d/99-bootstrap-swappiness.conf

    log_success "Swap file ${SWAP_SIZE}G active"
    add_summary "Swap file: ${SWAP_SIZE}G (swappiness=10)"
else
    log_info "Skipping swap"
fi
echo

#-------------------------------------------------------------------------------
# STEP 14: Timezone & time sync
#-------------------------------------------------------------------------------
log_info "=== STEP 14: Timezone & Time Sync ==="

CURRENT_TZ=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "unknown")
log_info "Current timezone: $CURRENT_TZ"

# Fresh images come up in UTC. A LAN box is read by a human in local time,
# so offer to change it; a VPS is fine in UTC (logs, cron and the rest of
# the world agree), so leave the default at no there.
TZ_DEFAULT="Europe/Moscow"
TZ_ASK="no"
if [[ "$CURRENT_TZ" == "Etc/UTC" || "$CURRENT_TZ" == "UTC" ]] && [[ "$PROFILE" == "local" ]]; then
    TZ_ASK="yes"
fi

if prompt_yes_no "Change timezone?" "$TZ_ASK"; then
    read -r -p "Enter timezone [$TZ_DEFAULT]: " TIMEZONE
    TIMEZONE="${TIMEZONE:-$TZ_DEFAULT}"
    if [[ -n "${TIMEZONE:-}" ]]; then
        if timedatectl set-timezone "$TIMEZONE" 2>/dev/null; then
            log_success "Timezone set to $TIMEZONE"
            add_summary "Timezone: $TIMEZONE"
        else
            log_error "Failed to set timezone '$TIMEZONE' (see: timedatectl list-timezones)"
        fi
    fi
else
    log_info "Keeping timezone $CURRENT_TZ"
fi

# Sanity check: a correct clock matters for TLS, apt and fail2ban
if [[ "$VIRT_CONTAINER" != "none" ]]; then
    log_info "Container: system clock is synced by the Proxmox host"
elif [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null)" == "yes" ]]; then
    log_success "Clock is NTP-synchronized"
else
    log_warning "Clock is not NTP-synchronized - enabling systemd-timesyncd..."
    apt_install systemd-timesyncd || true
    if systemctl enable --now systemd-timesyncd 2>/dev/null; then
        log_success "systemd-timesyncd enabled"
    else
        log_warning "Could not enable time sync - check manually: timedatectl"
    fi
fi
echo

#-------------------------------------------------------------------------------
# Summary
#-------------------------------------------------------------------------------
log_info "============================================"
log_info "            BOOTSTRAP COMPLETE"
log_info "============================================"
echo
echo "Summary of changes:"
echo "-------------------"
if [[ ${#SUMMARY[@]} -eq 0 ]]; then
    echo "  (nothing was changed)"
else
    for item in "${SUMMARY[@]}"; do
        echo "  - $item"
    done
fi
echo

# Marker: was this host bootstrapped, when and how
cat > /var/local/bootstrap-done <<EOF
date: $(date -Is)
script_version: $SCRIPT_VERSION
profile: $PROFILE
hostname: $(hostname)
user: $FINAL_USER
log: $LOG_FILE
EOF
log_info "Marker written: /var/local/bootstrap-done"
echo

HOST_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
if [[ -n "${SSH_PORT:-}" ]]; then
    log_warning "Before closing this session, verify SSH access in a NEW terminal:"
    log_warning "    ssh -p $SSH_PORT $FINAL_USER@${HOST_IP:-<this-host>}"
    echo
fi

# Hand-off to the laptop side: keymaster server-add installs keymaster on
# this host, adds the hosts.conf block and verifies the result
# (keymaster/docs/ssh-playbook.md, "Новый сервер"). Alias = prefix + hostname,
# unless the hostname already carries the prefix.
ALIAS_PREFIX=$([[ "$PROFILE" == "cloud" ]] && echo vps || echo pve)
ALIAS=$(hostname)
if [[ "$ALIAS" != ${ALIAS_PREFIX}-* ]]; then ALIAS="${ALIAS_PREFIX}-${ALIAS}"; fi
log_info "Next, on your laptop:"
log_info "    keymaster server-add $ALIAS ${HOST_IP:-<this-host>} ${SSH_PORT:-22} $FINAL_USER"
echo

if [[ -f /var/run/reboot-required ]]; then
    log_warning "Reboot required to finish updates:"
    if [[ -f /var/run/reboot-required.pkgs ]]; then
        sed 's/^/    /' /var/run/reboot-required.pkgs
    fi
    if prompt_yes_no "Reboot now?" "no"; then
        log_info "Rebooting..."
        reboot
    else
        log_info "Remember to reboot later"
    fi
else
    log_info "No reboot required"
fi
