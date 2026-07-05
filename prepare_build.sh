#!/usr/bin/env bash
#
# prepare_build.sh
# Automated environment preparation script for custom ROM building.
#
# What it does:
#   1. Detects your Linux distribution and package manager
#   2. Installs all packages typically required to build AOSP-based ROMs
#   3. Installs/updates the "repo" tool
#   4. Initializes the ROM source repo (repo init)
#   5. Downloads a local_manifest.xml from GitHub into .repo/local_manifests
#   6. Runs "repo sync"
#   7. Reports final readiness status
#
# Usage:
#   ./prepare_build.sh
#   (edit the CONFIG section below before running, or export the
#    variables in your shell before invoking the script)

set -uo pipefail

# ==================== FORCE RUN INSIDE A TERMINAL ======================
# If the script was launched by double-clicking it in a file manager (no
# terminal attached / not run via a shell), stdout won't be a TTY. In that
# case we relaunch ourselves inside a terminal emulator so the user actually
# sees the interactive UI instead of a window that flashes and closes.
ensure_terminal() {
    # Already attached to a terminal (normal ./script.sh usage) - do nothing.
    if [ -t 1 ] && [ -t 0 ]; then
        return 0
    fi

    # RELAUNCHED marker prevents infinite relaunch loops.
    if [ -n "${PREPARE_BUILD_RELAUNCHED:-}" ]; then
        return 0
    fi

    local script_path
    script_path="$(readlink -f "$0" 2>/dev/null || echo "$0")"

    local terminals=(
        x-terminal-emulator gnome-terminal konsole xfce4-terminal
        mate-terminal lxterminal tilix alacritty kitty xterm
    )

    for term in "${terminals[@]}"; do
        if command -v "$term" >/dev/null 2>&1; then
            case "$term" in
                gnome-terminal|mate-terminal|tilix)
                    PREPARE_BUILD_RELAUNCHED=1 exec "$term" -- bash -c \
                        "PREPARE_BUILD_RELAUNCHED=1 bash '$script_path'; echo; read -p 'Press Enter to close...'"
                    ;;
                *)
                    PREPARE_BUILD_RELAUNCHED=1 exec "$term" -e bash -c \
                        "PREPARE_BUILD_RELAUNCHED=1 bash '$script_path'; echo; read -p 'Press Enter to close...'"
                    ;;
            esac
        fi
    done

    # No terminal emulator found - can't self-relaunch, just warn on stderr.
    echo "This script must be run from a terminal." >&2
    echo "No terminal emulator was found to auto-launch one." >&2
    echo "Please open a terminal and run: bash \"$script_path\"" >&2
    exit 1
}

ensure_terminal
# =========================================================================

# =========================== CONFIG ==================================
# Defaults used only as a fallback / when running non-interactively
# (e.g. env vars pre-set, or answering "n" to the interactive prompts).

MANIFEST_URL="${MANIFEST_URL:-https://github.com/LineageOS/android.git}"   # ROM manifest repo
MANIFEST_BRANCH="${MANIFEST_BRANCH:-lineage-21.0}"                          # ROM branch

LOCAL_MANIFEST_REPO="${LOCAL_MANIFEST_REPO:-https://github.com/SkyX-Arch/local_manifest_device_plato.git}"
LOCAL_MANIFEST_BRANCH="${LOCAL_MANIFEST_BRANCH:-main}"

WORK_DIR="${WORK_DIR:-$HOME/android/rom}"
SYNC_JOBS="${SYNC_JOBS:-4}"
GIT_USER_NAME="${GIT_USER_NAME:-}"
GIT_USER_EMAIL="${GIT_USER_EMAIL:-}"

AUTHOR="SkyX-Arch"
AUTHOR_URL="https://github.com/SkyX-Arch"
# =======================================================================

# ------------------------- Colors & symbols ---------------------------
BOLD="\033[1m"; DIM="\033[2m"; RESET="\033[0m"
RED="\033[0;31m"; GREEN="\033[0;32m"; YELLOW="\033[0;33m"
BLUE="\033[0;34m"; CYAN="\033[0;36m"; MAGENTA="\033[0;35m"

CHECK="${GREEN}✔${RESET}"
CROSS="${RED}✘${RESET}"
ARROW="${CYAN}➜${RESET}"
WARN="${YELLOW}⚠${RESET}"

STEP_NUM=0
TOTAL_STEPS=8

# ------------------------- UI helpers ----------------------------------
banner() {
    clear
    echo -e "${CYAN}${BOLD}"
    cat <<'EOF'
   ____                  ____        _ _     _   ____
  |  _ \ ___  _ __ ___   | __ ) _   _(_) | __| | |  _ \ _ __ ___ _ __
  | |_) / _ \| '_ ` _ \  |  _ \| | | | | |/ _` | | |_) | '__/ _ \ '_ \
  |  _ < (_) | | | | | | | |_) | |_| | | | (_| | |  __/| | |  __/ |_) |
  |_| \_\___/|_| |_| |_| |____/ \__,_|_|_|\__,_| |_|   |_|  \___| .__/
                                                                 |_|
EOF
    echo -e "${RESET}${DIM}          Custom ROM Build Environment Preparation Script${RESET}"
    echo -e "${DIM}          ------------------------------------------------------${RESET}"
    echo -e "${MAGENTA}          Author: ${BOLD}${AUTHOR}${RESET}${MAGENTA}  ${DIM}(${AUTHOR_URL})${RESET}\n"
}

step() {
    STEP_NUM=$((STEP_NUM + 1))
    echo -e "\n${BOLD}${BLUE}[${STEP_NUM}/${TOTAL_STEPS}]${RESET} ${BOLD}$1${RESET}"
    echo -e "${DIM}────────────────────────────────────────────────────────────${RESET}"
}

info()    { echo -e "  ${ARROW} $1"; }
success() { echo -e "  ${CHECK} ${GREEN}$1${RESET}"; }
warn()    { echo -e "  ${WARN} ${YELLOW}$1${RESET}"; }
error()   { echo -e "  ${CROSS} ${RED}$1${RESET}"; }
die()     { error "$1"; exit 1; }

spinner() {
    local pid=$1
    local msg=$2
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    tput civis 2>/dev/null || true
    while kill -0 "$pid" 2>/dev/null; do
        i=$(( (i + 1) % ${#spin} ))
        printf "\r  ${CYAN}%s${RESET} %s" "${spin:$i:1}" "$msg"
        sleep 0.1
    done
    wait "$pid"
    local status=$?
    tput cnorm 2>/dev/null || true
    if [ $status -eq 0 ]; then
        printf "\r  ${CHECK} %s\n" "$msg"
    else
        printf "\r  ${CROSS} %s (exit code %s)\n" "$msg" "$status"
    fi
    return $status
}

run_with_spinner() {
    local msg="$1"; shift
    ("$@" >/tmp/prepare_build.log 2>&1) &
    local pid=$!
    spinner "$pid" "$msg"
    return $?
}

confirm() {
    read -rp "$(echo -e "  ${YELLOW}?${RESET} $1 [y/N]: ")" reply
    [[ "$reply" =~ ^[Yy]$ ]]
}

ask() {
    # ask "Prompt text" "default_value" -> echoes chosen value
    local prompt="$1" default="$2" reply
    read -rp "$(echo -e "  ${CYAN}?${RESET} ${prompt} ${DIM}[${default}]${RESET}: ")" reply
    echo "${reply:-$default}"
}

# ------------------------- Step 0: interactive config -----------------------
prompt_configuration() {
    step "ROM manifest configuration"

    info "Press Enter to keep the default shown in brackets."
    echo ""

    MANIFEST_URL=$(ask "ROM manifest repo URL" "$MANIFEST_URL")
    MANIFEST_BRANCH=$(ask "ROM manifest branch" "$MANIFEST_BRANCH")
    echo ""
    LOCAL_MANIFEST_REPO=$(ask "Local manifest repo URL (your device tree config)" "$LOCAL_MANIFEST_REPO")
    LOCAL_MANIFEST_BRANCH=$(ask "Local manifest branch" "$LOCAL_MANIFEST_BRANCH")
    echo ""
    WORK_DIR=$(ask "Build workspace directory" "$WORK_DIR")
    SYNC_JOBS=$(ask "Parallel sync jobs" "$SYNC_JOBS")

    success "Configuration collected"
}

# ------------------------- Step 1: OS detection -------------------------
detect_os() {
    step "Detecting operating system"

    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        DISTRO_ID="${ID:-unknown}"
        DISTRO_LIKE="${ID_LIKE:-}"
        DISTRO_NAME="${PRETTY_NAME:-unknown}"
    elif [ "$(uname -s)" = "Darwin" ]; then
        DISTRO_ID="macos"
        DISTRO_NAME="macOS $(sw_vers -productVersion 2>/dev/null)"
    else
        DISTRO_ID="unknown"
        DISTRO_NAME="unknown"
    fi

    info "Detected: ${BOLD}${DISTRO_NAME}${RESET}"

    case "$DISTRO_ID" in
        ubuntu|debian|linuxmint|pop)
            PKG_MANAGER="apt"
            ;;
        fedora|rhel|centos|rocky|almalinux)
            PKG_MANAGER="dnf"
            ;;
        arch|manjaro|endeavouros)
            PKG_MANAGER="pacman"
            ;;
        opensuse*|sles)
            PKG_MANAGER="zypper"
            ;;
        macos)
            PKG_MANAGER="brew"
            ;;
        *)
            case "$DISTRO_LIKE" in
                *debian*) PKG_MANAGER="apt" ;;
                *rhel*|*fedora*) PKG_MANAGER="dnf" ;;
                *arch*) PKG_MANAGER="pacman" ;;
                *) PKG_MANAGER="unknown" ;;
            esac
            ;;
    esac

    if [ "$PKG_MANAGER" = "unknown" ]; then
        die "Could not determine a supported package manager for this system."
    fi

    success "Package manager: ${PKG_MANAGER}"
}

# ------------------------- Step 2: dependencies -------------------------
# ------------------------- Package presence helpers ------------------------
# Returns 0 (true) if the package is already installed / satisfied.
is_pkg_installed() {
    local pkg="$1"
    case "$PKG_MANAGER" in
        apt)
            dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"
            ;;
        dnf|zypper)
            rpm -q "$pkg" >/dev/null 2>&1
            ;;
        pacman)
            # -Qi checks real package names; -T (deptest) additionally resolves
            # virtual packages/providers (e.g. zlib satisfied by zlib-ng-compat),
            # which avoids false "not installed" results that lead to conflicts.
            pacman -Qi "$pkg" >/dev/null 2>&1 && return 0
            [ -z "$(pacman -T "$pkg" 2>/dev/null)" ]
            ;;
        brew)
            brew list --formula "$pkg" >/dev/null 2>&1 || brew list --cask "$pkg" >/dev/null 2>&1
            ;;
        *)
            return 1
            ;;
    esac
}

# Splits $1 (space-separated package list) into already-installed / missing.
# Sets globals: ALREADY_INSTALLED, MISSING_PACKAGES
filter_missing_packages() {
    local pkg_list="$1"
    ALREADY_INSTALLED=""
    MISSING_PACKAGES=""
    local pkg
    for pkg in $pkg_list; do
        if is_pkg_installed "$pkg"; then
            ALREADY_INSTALLED="$ALREADY_INSTALLED $pkg"
        else
            MISSING_PACKAGES="$MISSING_PACKAGES $pkg"
        fi
    done
}

install_dependencies() {
    step "Installing build dependencies"

    case "$PKG_MANAGER" in
        apt)
            PACKAGES="git-core gnupg flex bison build-essential zip curl zlib1g-dev \
                      libc6-dev-i386 libncurses-dev x11proto-core-dev libx11-dev \
                      lib32z1-dev libgl1-mesa-dev libxml2-utils xsltproc unzip fontconfig \
                      python3 python3-pip openjdk-11-jdk bc rsync schedtool imagemagick \
                      lib32ncurses-dev lib32readline-dev lib32z1 ccache"
            ;;
        dnf)
            PACKAGES="git gnupg flex bison make automake gcc gcc-c++ zip curl \
                      zlib-devel ncurses-devel libxml2 libxslt unzip fontconfig \
                      python3 python3-pip java-11-openjdk-devel bc rsync \
                      ImageMagick ccache glibc-devel.i686 ncurses-devel.i686"
            ;;
        pacman)
            PACKAGES="git gnupg flex bison base-devel zip curl zlib ncurses \
                      libxml2 libxslt unzip fontconfig python python-pip jdk11-openjdk \
                      bc rsync imagemagick ccache lib32-glibc lib32-ncurses"
            ;;
        zypper)
            PACKAGES="git gpg2 flex bison make gcc gcc-c++ zip curl zlib-devel \
                      ncurses-devel libxml2-tools libxslt-tools unzip fontconfig \
                      python3 python3-pip java-11-openjdk-devel bc rsync ImageMagick ccache"
            ;;
        brew)
            PACKAGES="git gnupg coreutils gnu-sed gawk python3 openjdk@11 ccache rsync"
            ;;
    esac

    info "Checking which packages are already installed..."
    filter_missing_packages "$PACKAGES"

    if [ -n "$ALREADY_INSTALLED" ]; then
        local count
        count=$(echo "$ALREADY_INSTALLED" | wc -w)
        success "$count package(s) already installed, skipping them"
    fi

    if [ -z "$MISSING_PACKAGES" ]; then
        success "All build dependencies are already installed - nothing to do"
        return 0
    fi

    info "Packages to install:${MISSING_PACKAGES}"

    case "$PKG_MANAGER" in
        apt)
            run_with_spinner "Refreshing apt package index" sudo apt update -y \
                || warn "apt update reported issues, continuing anyway"
            run_with_spinner "Installing missing packages" sudo apt install -y $MISSING_PACKAGES \
                || die "Failed to install dependencies. Check /tmp/prepare_build.log"
            ;;
        dnf)
            run_with_spinner "Installing missing packages" sudo dnf install -y $MISSING_PACKAGES \
                || die "Failed to install dependencies. Check /tmp/prepare_build.log"
            ;;
        pacman)
            run_with_spinner "Syncing package databases" sudo pacman -Sy --noconfirm \
                || warn "pacman -Sy reported issues, continuing anyway"
            run_with_spinner "Installing missing packages" sudo pacman -S --needed --noconfirm $MISSING_PACKAGES \
                || die "Failed to install dependencies. Check /tmp/prepare_build.log"
            ;;
        zypper)
            run_with_spinner "Installing missing packages" sudo zypper install -y $MISSING_PACKAGES \
                || die "Failed to install dependencies. Check /tmp/prepare_build.log"
            ;;
        brew)
            run_with_spinner "Installing missing packages" brew install $MISSING_PACKAGES \
                || die "Failed to install dependencies. Check /tmp/prepare_build.log"
            ;;
    esac

    success "All build dependencies installed"
}

# ------------------------- Step 3: repo tool -----------------------------
install_repo_tool() {
    step "Installing/updating the 'repo' tool"

    mkdir -p "$HOME/.bin"
    export PATH="$HOME/.bin:$PATH"

    if command -v repo >/dev/null 2>&1; then
        success "repo tool already available at $(command -v repo)"
        return 0
    fi

    run_with_spinner "Downloading repo launcher" curl -s https://storage.googleapis.com/git-repo-downloads/repo -o "$HOME/.bin/repo" \
        || die "Failed to download the repo tool"

    chmod a+x "$HOME/.bin/repo"

    if ! grep -q '.bin' "$HOME/.bashrc" 2>/dev/null; then
        echo 'export PATH="$HOME/.bin:$PATH"' >> "$HOME/.bashrc"
        info "Added \$HOME/.bin to PATH in ~/.bashrc"
    fi

    success "repo tool installed to \$HOME/.bin/repo"
}

# ------------------------- Step 4: git identity ---------------------------
configure_git_identity() {
    step "Checking git identity"

    local name email
    name=$(git config --global user.name || true)
    email=$(git config --global user.email || true)

    if [ -z "$name" ]; then
        name="${GIT_USER_NAME:-ROM Builder}"
        git config --global user.name "$name"
        info "Set git user.name to '$name'"
    else
        success "git user.name already set: $name"
    fi

    if [ -z "$email" ]; then
        email="${GIT_USER_EMAIL:-builder@localhost}"
        git config --global user.email "$email"
        info "Set git user.email to '$email'"
    else
        success "git user.email already set: $email"
    fi

    git config --global color.ui auto
}

# ------------------------- Step 5: repo init -------------------------------
init_repo_workspace() {
    step "Initializing ROM source workspace"

    mkdir -p "$WORK_DIR"
    cd "$WORK_DIR" || die "Cannot access working directory: $WORK_DIR"
    info "Working directory: $WORK_DIR"

    if [ -d ".repo" ]; then
        warn ".repo already exists here, skipping 'repo init'"
    else
        run_with_spinner "Running repo init (manifest: $MANIFEST_URL, branch: $MANIFEST_BRANCH)" \
            repo init -u "$MANIFEST_URL" -b "$MANIFEST_BRANCH" --depth=1 \
            || die "repo init failed. Check /tmp/prepare_build.log"
    fi

    success "Repo workspace initialized"
}

# ------------------------- Step 6: local manifest --------------------------
download_local_manifest() {
    step "Downloading local_manifest into .repo/local_manifests"

    mkdir -p "$WORK_DIR/.repo/local_manifests"
    cd "$WORK_DIR" || die "Cannot access working directory: $WORK_DIR"

    local tmp_clone
    tmp_clone=$(mktemp -d)

    run_with_spinner "Cloning local manifest repo ($LOCAL_MANIFEST_REPO)" \
        git clone --depth=1 -b "$LOCAL_MANIFEST_BRANCH" "$LOCAL_MANIFEST_REPO" "$tmp_clone" \
        || die "Failed to clone local manifest repository. Check /tmp/prepare_build.log"

    local xml_count
    xml_count=$(find "$tmp_clone" -maxdepth 1 -name "*.xml" | wc -l)

    if [ "$xml_count" -eq 0 ]; then
        die "No .xml manifest files found in $LOCAL_MANIFEST_REPO"
    fi

    cp "$tmp_clone"/*.xml "$WORK_DIR/.repo/local_manifests/"
    rm -rf "$tmp_clone"

    success "Copied $xml_count local manifest file(s):"
    for f in "$WORK_DIR"/.repo/local_manifests/*.xml; do
        info "$(basename "$f")"
    done
}

# ------------------------- Step 7: repo sync --------------------------------
run_repo_sync() {
    step "Running repo sync (this can take a long time)"

    cd "$WORK_DIR" || die "Cannot access working directory: $WORK_DIR"
    export PATH="$HOME/.bin:$PATH"

    echo -e "  ${DIM}Syncing with ${SYNC_JOBS} parallel jobs. Live output below:${RESET}\n"

    if repo sync -c -j"$SYNC_JOBS" --force-sync --no-clone-bundle --no-tags; then
        success "repo sync completed successfully"
    else
        die "repo sync failed. Re-run 'repo sync' manually inside $WORK_DIR to see full errors."
    fi
}

# ------------------------- Final report -------------------------------------
final_report() {
    echo -e "\n${GREEN}${BOLD}════════════════════════════════════════════════════════════${RESET}"
    echo -e "${GREEN}${BOLD}   BUILD ENVIRONMENT READY${RESET}"
    echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════════${RESET}\n"

    echo -e "  ${CHECK} OS               : ${DISTRO_NAME}"
    echo -e "  ${CHECK} Package manager  : ${PKG_MANAGER}"
    echo -e "  ${CHECK} Workspace        : ${WORK_DIR}"
    echo -e "  ${CHECK} Manifest         : ${MANIFEST_URL} (${MANIFEST_BRANCH})"
    echo -e "  ${CHECK} Local manifest   : ${LOCAL_MANIFEST_REPO} (${LOCAL_MANIFEST_BRANCH})"
    echo -e "  ${CHECK} repo tool        : $(command -v repo 2>/dev/null || echo "$HOME/.bin/repo")"

    echo -e "\n${CYAN}Next steps:${RESET}"
    echo -e "  1. cd ${WORK_DIR}"
    echo -e "  2. source build/envsetup.sh"
    echo -e "  3. lunch <your_device_lunch_combo>"
    echo -e "  4. mka bacon   ${DIM}# or 'm bacon', 'brunch <device>' depending on your ROM${RESET}\n"

    echo -e "${DIM}Log file for this run: /tmp/prepare_build.log${RESET}"
    echo -e "${MAGENTA}Script by ${BOLD}${AUTHOR}${RESET}${MAGENTA} — ${AUTHOR_URL}${RESET}\n"
}

# ------------------------- Main -------------------------------------------
main() {
    banner

    prompt_configuration

    echo ""
    echo -e "${BOLD}Final configuration:${RESET}"
    echo -e "  ${DIM}Manifest:${RESET}       $MANIFEST_URL ($MANIFEST_BRANCH)"
    echo -e "  ${DIM}Local manifest:${RESET} $LOCAL_MANIFEST_REPO ($LOCAL_MANIFEST_BRANCH)"
    echo -e "  ${DIM}Workspace:${RESET}      $WORK_DIR"
    echo ""

    if ! confirm "Proceed with the above configuration?"; then
        warn "Aborted by user. Re-run the script to start over."
        exit 0
    fi

    detect_os
    install_dependencies
    install_repo_tool
    configure_git_identity
    init_repo_workspace
    download_local_manifest
    run_repo_sync
    final_report
}

main "$@"
