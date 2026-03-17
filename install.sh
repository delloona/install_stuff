#!/usr/bin/env bash
# ============================================================================
#  Server Bootstrap Script
#  Sets up: zsh, fzf, docker, bat, vim + SpaceVim, NVIDIA Container Toolkit
# ============================================================================

set -euo pipefail

# --- Colors & helpers -------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()      { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()    { echo -e "${RED}[FAIL]${NC}  $*"; }
section() { echo -e "\n${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; echo -e "${GREEN}  $*${NC}"; echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; }

# --- Pre-flight checks ------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    fail "This script must be run as root (or with sudo)."
    exit 1
fi

REAL_USER="${SUDO_USER:-$USER}"
REAL_HOME=$(eval echo "~${REAL_USER}")

# Detect distro family
if command -v apt-get &>/dev/null; then
    PKG_MANAGER="apt"
elif command -v dnf &>/dev/null; then
    PKG_MANAGER="dnf"
elif command -v yum &>/dev/null; then
    PKG_MANAGER="yum"
else
    fail "Unsupported package manager. This script supports apt, dnf, and yum."
    exit 1
fi

info "Detected package manager: ${PKG_MANAGER}"
info "Real user: ${REAL_USER} (home: ${REAL_HOME})"

# --- Helper: install packages -----------------------------------------------
pkg_update() {
    case "$PKG_MANAGER" in
        apt) apt-get update -qq ;;
        dnf) dnf makecache -q ;;
        yum) yum makecache -q ;;
    esac
}

pkg_install() {
    case "$PKG_MANAGER" in
        apt) apt-get install -y -qq "$@" ;;
        dnf) dnf install -y -q "$@" ;;
        yum) yum install -y -q "$@" ;;
    esac
}

# --- Update package cache ---------------------------------------------------
section "Updating package cache"
pkg_update
pkg_install curl wget git ca-certificates gnupg lsb-release
ok "Base dependencies installed"

# ============================================================================
#  1) ZSH
# ============================================================================
section "Installing Zsh"

if command -v zsh &>/dev/null; then
    warn "Zsh is already installed ($(zsh --version))"
else
    pkg_install zsh
    ok "Zsh installed"
fi

# Set zsh as default shell for the real user
if [[ "$(getent passwd "${REAL_USER}" | cut -d: -f7)" != *"zsh"* ]]; then
    chsh -s "$(command -v zsh)" "${REAL_USER}"
    ok "Default shell changed to zsh for ${REAL_USER}"
else
    warn "Zsh is already the default shell for ${REAL_USER}"
fi

# ============================================================================
#  2) FZF
# ============================================================================
section "Installing fzf"

FZF_DIR="${REAL_HOME}/.fzf"

if [[ -d "${FZF_DIR}" ]]; then
    warn "fzf directory already exists, updating..."
    sudo -u "${REAL_USER}" git -C "${FZF_DIR}" pull --quiet
else
    sudo -u "${REAL_USER}" git clone --depth 1 https://github.com/junegunn/fzf.git "${FZF_DIR}"
fi

sudo -u "${REAL_USER}" bash "${FZF_DIR}/install" --all --no-bash --no-fish
ok "fzf installed"

# ============================================================================
#  3) DOCKER
# ============================================================================
section "Installing Docker"

if command -v docker &>/dev/null; then
    warn "Docker is already installed ($(docker --version))"
else
    case "$PKG_MANAGER" in
        apt)
            # Add Docker's official GPG key and repo
            install -m 0755 -d /etc/apt/keyrings
            DISTRO_ID=$(. /etc/os-release && echo "$ID")
            curl -fsSL "https://download.docker.com/linux/${DISTRO_ID}/gpg" \
                | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
            chmod a+r /etc/apt/keyrings/docker.gpg

            echo \
                "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
                https://download.docker.com/linux/${DISTRO_ID} \
                $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
                > /etc/apt/sources.list.d/docker.list

            apt-get update -qq
            apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
        dnf|yum)
            ${PKG_MANAGER} install -y -q yum-utils || true
            yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo 2>/dev/null \
                || yum-config-manager --add-repo https://download.docker.com/linux/fedora/docker-ce.repo
            ${PKG_MANAGER} install -y -q docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
            ;;
    esac

    ok "Docker installed"
fi

systemctl enable --now docker
usermod -aG docker "${REAL_USER}"
ok "Docker running & ${REAL_USER} added to docker group"

# ============================================================================
#  4) BAT
# ============================================================================
section "Installing bat"

if command -v bat &>/dev/null || command -v batcat &>/dev/null; then
    warn "bat is already installed"
else
    case "$PKG_MANAGER" in
        apt)
            pkg_install bat
            # On Debian/Ubuntu the binary is called 'batcat' — create a symlink
            if command -v batcat &>/dev/null && ! command -v bat &>/dev/null; then
                ln -sf "$(command -v batcat)" /usr/local/bin/bat
                ok "Created symlink: bat -> batcat"
            fi
            ;;
        dnf|yum)
            pkg_install bat
            ;;
    esac
    ok "bat installed"
fi

# ============================================================================
#  5) VIM + SPACEVIM
# ============================================================================
section "Installing Vim + SpaceVim"

if ! command -v vim &>/dev/null; then
    pkg_install vim
    ok "Vim installed"
else
    warn "Vim is already installed ($(vim --version | head -1))"
fi

SPACEVIM_DIR="${REAL_HOME}/.SpaceVim"

if [[ -d "${SPACEVIM_DIR}" ]]; then
    warn "SpaceVim is already installed, updating..."
    sudo -u "${REAL_USER}" git -C "${SPACEVIM_DIR}" pull --quiet
else
    sudo -u "${REAL_USER}" curl -sLf https://spacevim.org/install.sh | sudo -u "${REAL_USER}" bash
    ok "SpaceVim installed"
fi

# ============================================================================
#  6) NVIDIA CONTAINER TOOLKIT (if GPU detected)
# ============================================================================
section "Checking for NVIDIA GPU"

HAS_GPU=false
if lspci 2>/dev/null | grep -iq nvidia; then
    HAS_GPU=true
elif [[ -e /dev/nvidia0 ]]; then
    HAS_GPU=true
fi

if $HAS_GPU; then
    info "NVIDIA GPU detected — installing NVIDIA Container Toolkit"

    case "$PKG_MANAGER" in
        apt)
            curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
                | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg

            DIST=$(. /etc/os-release; echo "${ID}${VERSION_ID}" | sed 's/\.//g')
            curl -s -L "https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list" \
                | sed "s#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g" \
                > /etc/apt/sources.list.d/nvidia-container-toolkit.list

            apt-get update -qq
            apt-get install -y -qq nvidia-container-toolkit
            ;;
        dnf|yum)
            curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
                > /etc/yum.repos.d/nvidia-container-toolkit.repo
            ${PKG_MANAGER} install -y -q nvidia-container-toolkit
            ;;
    esac

    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker
    ok "NVIDIA Container Toolkit installed and configured with Docker"
else
    warn "No NVIDIA GPU detected — skipping NVIDIA Container Toolkit"
fi

# ============================================================================
#  SUMMARY
# ============================================================================
section "Setup Complete!"

echo -e "  ${GREEN}✔${NC} zsh        (default shell)"
echo -e "  ${GREEN}✔${NC} fzf        (~/.fzf)"
echo -e "  ${GREEN}✔${NC} docker     (+ compose plugin)"
echo -e "  ${GREEN}✔${NC} bat"
echo -e "  ${GREEN}✔${NC} vim        (+ SpaceVim)"
if $HAS_GPU; then
    echo -e "  ${GREEN}✔${NC} nvidia-container-toolkit"
else
    echo -e "  ${YELLOW}—${NC} nvidia-container-toolkit (no GPU)"
fi

echo ""
warn "Log out and back in for docker group + zsh shell changes to take effect."
