#!/usr/bin/env bash
set -euo pipefail

readonly LOG_FILE="$(mktemp)"
trap 'rm -f "$LOG_FILE"' EXIT

SPINNER_PID=""

spinner_loop() {
  local msg="$1"
  local frames='|/-\'
  local i=0
  while true; do
    printf '\r\033[K  %s %s' "${frames:i++%4:1}" "$msg"
    sleep 0.12
  done
}

step_start() {
  local msg="$1"
  spinner_loop "$msg" &
  SPINNER_PID=$!
}

step_ok() {
  local msg="$1"
  if [[ -n "${SPINNER_PID:-}" ]]; then
    kill "$SPINNER_PID" 2>/dev/null || true
    wait "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=""
  fi
  printf '\r\033[K  ✓ %s\n' "$msg"
}

step_fail() {
  local msg="$1"
  if [[ -n "${SPINNER_PID:-}" ]]; then
    kill "$SPINNER_PID" 2>/dev/null || true
    wait "$SPINNER_PID" 2>/dev/null || true
    SPINNER_PID=""
  fi
  printf '\r\033[K  ✗ %s\n' "$msg" >&2
  echo >&2
  echo "--- Installation logs ---" >&2
  cat "$LOG_FILE" >&2
  echo "-------------------------" >&2
  exit 1
}

run_step() {
  local msg="$1"
  shift
  step_start "$msg"
  if "$@" >>"$LOG_FILE" 2>&1; then
    step_ok "$msg"
  else
    step_fail "$msg"
  fi
}

log() {
  echo "$*" >>"$LOG_FILE"
}

info() {
  echo "→ $*"
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    info "Elevating privileges (sudo)..."
    exec sudo -E "$0" "$@"
  fi
}

docker_works() {
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

load_os() {
  if [[ ! -f /etc/os-release ]]; then
    echo "Cannot read /etc/os-release — unsupported OS." >&2
    exit 1
  fi
  . /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_ID_LIKE="${ID_LIKE:-}"
  OS_NAME="${PRETTY_NAME:-$OS_ID}"
  OS_VERSION_CODENAME="${VERSION_CODENAME:-}"
  OS_UBUNTU_CODENAME="${UBUNTU_CODENAME:-$OS_VERSION_CODENAME}"
}

detect_family() {
  load_os

  case "$OS_ID" in
    ubuntu)                          echo "ubuntu" ;;
    debian)                          echo "debian" ;;
    linuxmint|pop|elementary|zorin)  echo "ubuntu" ;;
    kali|parrot)                     echo "debian" ;;
    fedora)                          echo "fedora" ;;
    centos|rocky|almalinux|ol|amzn)  echo "centos" ;;
    rhel)                            echo "rhel" ;;
    arch|cachyos|endeavouros|manjaro|garuda|artix) echo "arch" ;;
    opensuse-leap|opensuse-tumbleweed|opensuse-suse|sles) echo "opensuse" ;;
    alpine)                          echo "alpine" ;;
    *)
      if [[ "$OS_ID_LIKE" == *ubuntu* ]]; then
        echo "ubuntu"
      elif [[ "$OS_ID_LIKE" == *debian* ]]; then
        echo "debian"
      elif [[ "$OS_ID_LIKE" == *fedora* ]] || [[ "$OS_ID_LIKE" == *rhel* ]] || [[ "$OS_ID_LIKE" == *centos* ]]; then
        echo "centos"
      elif [[ "$OS_ID_LIKE" == *arch* ]]; then
        echo "arch"
      elif [[ "$OS_ID_LIKE" == *suse* ]]; then
        echo "opensuse"
      else
        echo "unknown"
      fi
      ;;
  esac
}

readonly DOCKER_APT_PKGS="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"
readonly DOCKER_DNF_PKGS="docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin"

apt_remove_conflicts() {
  log "Removing conflicting packages (apt)..."
  apt-get remove -y \
    docker.io docker-compose docker-compose-v2 docker-doc podman-docker \
    containerd runc 2>/dev/null || true
}

apt_setup_repo() {
  local distro="$1"
  local codename="$2"
  local gpg_url="https://download.docker.com/linux/${distro}/gpg"
  local repo_url="https://download.docker.com/linux/${distro}"

  apt-get update -qq
  apt-get install -y -qq ca-certificates curl gnupg

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "$gpg_url" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  tee /etc/apt/sources.list.d/docker.sources >/dev/null <<EOF
Types: deb
URIs: ${repo_url}
Suites: ${codename}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  apt-get update -qq
}

install_ubuntu() {
  local codename="${OS_UBUNTU_CODENAME:-}"
  if [[ -z "$codename" ]]; then
    echo "Ubuntu codename not found (VERSION_CODENAME / UBUNTU_CODENAME)." >&2
    exit 1
  fi

  run_step "Removing old Docker versions" apt_remove_conflicts
  run_step "Configuring Docker repository (Ubuntu ${codename})" apt_setup_repo ubuntu "$codename"
  run_step "Installing Docker packages" apt-get install -y -qq $DOCKER_APT_PKGS
}

install_debian() {
  local codename="${OS_VERSION_CODENAME:-}"
  if [[ -z "$codename" ]]; then
    echo "Debian codename not found (VERSION_CODENAME)." >&2
    exit 1
  fi

  run_step "Removing old Docker versions" apt_remove_conflicts
  run_step "Configuring Docker repository (Debian ${codename})" apt_setup_repo debian "$codename"
  run_step "Installing Docker packages" apt-get install -y -qq $DOCKER_APT_PKGS
}

dnf_remove_conflicts() {
  log "Removing conflicting packages (dnf)..."
  dnf remove -y \
    docker docker-client docker-client-latest docker-common \
    docker-latest docker-latest-logrotate docker-logrotate \
    docker-selinux docker-engine-selinux docker-engine 2>/dev/null || true
}

install_fedora() {
  run_step "Removing old Docker versions" dnf_remove_conflicts
  run_step "Configuring Docker repository (Fedora)" \
    dnf config-manager addrepo --from-repofile=https://download.docker.com/linux/fedora/docker-ce.repo
  run_step "Installing Docker packages" \
    dnf install -y $DOCKER_DNF_PKGS
}

install_centos() {
  run_step "Removing old Docker versions" dnf_remove_conflicts
  run_step "Installing dnf-plugins-core" dnf install -y dnf-plugins-core
  run_step "Configuring Docker repository (CentOS/RHEL family)" \
    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  run_step "Installing Docker packages" \
    dnf install -y $DOCKER_DNF_PKGS
}

install_rhel() {
  run_step "Removing old Docker versions" dnf_remove_conflicts
  run_step "Installing dnf-plugins-core" dnf install -y dnf-plugins-core
  run_step "Configuring Docker repository (RHEL)" \
    dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo
  run_step "Installing Docker packages" \
    dnf install -y $DOCKER_DNF_PKGS
}

install_arch() {
  run_step "Updating package databases (pacman)" pacman -Sy --noconfirm
  run_step "Installing Docker packages" \
    pacman -S --needed --noconfirm docker docker-compose
}

install_opensuse() {
  run_step "Installing Docker packages (zypper)" \
    zypper --non-interactive install -y docker docker-compose
}

install_alpine() {
  run_step "Installing Docker packages (apk)" \
    apk add --no-cache docker docker-cli-compose
}

install_via_convenience_script() {
  local tmp
  tmp="$(mktemp)"
  run_step "Downloading Docker install script" \
    curl -fsSL https://get.docker.com -o "$tmp"
  run_step "Installing via official Docker script" sh "$tmp"
  rm -f "$tmp"
}

install_docker() {
  local family
  family="$(detect_family)"

  export DEBIAN_FRONTEND=noninteractive

  info "Detected system: ${OS_NAME} (${family})"
  echo

  case "$family" in
    ubuntu)   install_ubuntu ;;
    debian)   install_debian ;;
    fedora)   install_fedora ;;
    centos)   install_centos ;;
    rhel)     install_rhel ;;
    arch)     install_arch ;;
    opensuse) install_opensuse ;;
    alpine)   install_alpine ;;
    unknown)
      info "Unknown distribution — falling back to get.docker.com"
      install_via_convenience_script
      ;;
  esac
}

postinstall() {
  if command -v systemctl >/dev/null 2>&1; then
    run_step "Enabling Docker service on boot" \
      systemctl enable --now docker.service
    if systemctl list-unit-files containerd.service >/dev/null 2>&1; then
      run_step "Enabling containerd service" \
        systemctl enable --now containerd.service 2>/dev/null || true
    fi
  elif command -v rc-service >/dev/null 2>&1; then
    run_step "Starting Docker service" rc-service docker start
    run_step "Enabling Docker on boot" rc-update add docker default
  fi

  local target_user="${SUDO_USER:-${USER:-}}"
  if [[ -n "$target_user" && "$target_user" != "root" ]]; then
    run_step "Adding \"${target_user}\" to docker group" \
      usermod -aG docker "$target_user"
  fi
}

verify_install() {
  run_step "Verifying installation (docker run hello-world)" \
    docker run --rm hello-world
}

main() {
  echo
  echo "╔══════════════════════════════════════╗"
  echo "║       Docker Engine Installation     ║"
  echo "╚══════════════════════════════════════╝"
  echo

  case "$(uname -s)" in
    Darwin)
      echo "macOS detected — install Docker Desktop: https://docs.docker.com/desktop/setup/install/mac-install/" >&2
      exit 1
      ;;
    MINGW*|MSYS*|CYGWIN*)
      echo "Windows detected — install Docker Desktop: https://docs.docker.com/desktop/setup/install/windows-install/" >&2
      exit 1
      ;;
    Linux) ;;
    *)
      echo "Unsupported OS: $(uname -s)" >&2
      exit 1
      ;;
  esac

  if docker_works; then
    info "Docker is already installed and working — nothing to do."
    docker --version
    exit 0
  fi

  require_root "$@"

  if command -v docker >/dev/null 2>&1; then
    info "Docker found but daemon is down — trying to start it..."
    if command -v systemctl >/dev/null 2>&1; then
      systemctl start docker 2>/dev/null || true
    fi
    if docker_works; then
      info "Docker is now working."
      exit 0
    fi
    info "Reinstalling..."
  fi

  install_docker
  postinstall
  verify_install

  echo
  info "Installation completed successfully."
  docker --version

  local target_user="${SUDO_USER:-${USER:-}}"
  if [[ -n "$target_user" && "$target_user" != "root" ]]; then
    echo
    info "Log out and back in (or run \"newgrp docker\") to use docker without sudo."
  fi
}

main "$@"
