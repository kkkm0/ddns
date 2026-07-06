#!/usr/bin/env bash
#
# ddns.sh - One-click installer for Cloudflare DDNS (favonia/cloudflare-ddns)
#
# Usage:
#   bash ddns.sh <Cloudflare_API_Token> <Domain>
#
# Example:
#   bash ddns.sh cf_xxxxxx ddns.example.com
#
# This script is idempotent: it can be re-run safely at any time to update
# the configuration and/or the running container to the latest image.
#
# Supported systems: Debian 11+/12+, Ubuntu 20.04+/22.04+/24.04+
#
set -euo pipefail

# --------------------------------------------------------------------------
# Constants
# --------------------------------------------------------------------------
readonly INSTALL_DIR="/opt/cloudflare-ddns"
readonly ENV_FILE="${INSTALL_DIR}/.env"
readonly COMPOSE_FILE="${INSTALL_DIR}/docker-compose.yml"
readonly IMAGE_NAME="favonia/cloudflare-ddns:1"
readonly CONTAINER_NAME="cloudflare-ddns"

# --------------------------------------------------------------------------
# Colors / logging helpers
# --------------------------------------------------------------------------
# Disable colors automatically when not attached to a terminal (e.g. piped
# through `curl | bash`, which is still a TTY-less stdin but stdout may be
# a terminal - we check stdout specifically).
if [[ -t 1 ]]; then
    readonly COLOR_RESET="\033[0m"
    readonly COLOR_BLUE="\033[1;34m"
    readonly COLOR_GREEN="\033[1;32m"
    readonly COLOR_YELLOW="\033[1;33m"
    readonly COLOR_RED="\033[1;31m"
else
    readonly COLOR_RESET=""
    readonly COLOR_BLUE=""
    readonly COLOR_GREEN=""
    readonly COLOR_YELLOW=""
    readonly COLOR_RED=""
fi

log_info() {
    printf "%b[INFO]%b %s\n" "${COLOR_BLUE}" "${COLOR_RESET}" "$1"
}

log_success() {
    printf "%b[SUCCESS]%b %s\n" "${COLOR_GREEN}" "${COLOR_RESET}" "$1"
}

log_warning() {
    printf "%b[WARNING]%b %s\n" "${COLOR_YELLOW}" "${COLOR_RESET}" "$1"
}

log_error() {
    printf "%b[ERROR]%b %s\n" "${COLOR_RED}" "${COLOR_RESET}" "$1" >&2
}

die() {
    log_error "$1"
    exit 1
}

# --------------------------------------------------------------------------
# Usage
# --------------------------------------------------------------------------
print_usage() {
    cat <<'EOF'
Usage:
bash ddns.sh <Cloudflare_API_Token> <Domain> [ipv6]

Example:
bash ddns.sh cf_xxxxxx ddns.example.com
bash ddns.sh cf_xxxxxx ddns.example.com ipv6
EOF
}

# --------------------------------------------------------------------------
# Step 0: Argument validation
# --------------------------------------------------------------------------
validate_args() {
    if [[ "$#" -lt 2 || "$#" -gt 3 ]]; then
        print_usage
        exit 1
    fi

    CF_API_TOKEN="$1"
    DDNS_DOMAIN="$2"

    if [[ -z "${CF_API_TOKEN}" || -z "${DDNS_DOMAIN}" ]]; then
        print_usage
        exit 1
    fi

    # Optional third argument: pass "ipv6" to also let favonia/cloudflare-ddns
    # manage IPv6 records. By default IPv6 is disabled, since most VPS hosts
    # only have an IPv4 address, and leaving IPv6 detection enabled produces
    # noisy/harmless "No valid IPv6 addresses were detected" log spam.
    ENABLE_IPV6=false
    if [[ "${3:-}" == "ipv6" ]]; then
        ENABLE_IPV6=true
    elif [[ -n "${3:-}" ]]; then
        die "Unknown third argument: '${3}'. The only supported value is 'ipv6'."
    fi
}

# --------------------------------------------------------------------------
# Step 1: Must run as root
# --------------------------------------------------------------------------
check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "This script must be run as root. Try: sudo bash ddns.sh <Token> <Domain>"
    fi
}

# --------------------------------------------------------------------------
# Step 2: Detect OS (Debian / Ubuntu only)
# --------------------------------------------------------------------------
detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        die "Cannot detect OS: /etc/os-release not found."
    fi

    # shellcheck disable=SC1091
    source /etc/os-release

    OS_ID="${ID:-}"
    OS_VERSION="${VERSION_ID:-unknown}"

    case "${OS_ID}" in
        debian|ubuntu)
            log_info "Detected OS: ${PRETTY_NAME:-${OS_ID} ${OS_VERSION}}"
            ;;
        *)
            die "Unsupported OS: ${OS_ID}. Only Debian and Ubuntu are supported."
            ;;
    esac
}

# --------------------------------------------------------------------------
# Step 3: Install Docker (official convenience script) if not present
# --------------------------------------------------------------------------
install_docker() {
    if command -v docker >/dev/null 2>&1; then
        log_info "Docker is already installed ($(docker --version)). Skipping installation."
        return
    fi

    log_info "Docker not found. Installing Docker..."

    if ! command -v curl >/dev/null 2>&1; then
        log_info "Installing curl (required to fetch Docker install script)..."
        apt-get update -y || die "Failed to run apt-get update."
        apt-get install -y curl || die "Failed to install curl."
    fi

    # Use Docker's official install script, the most reliable way to support
    # multiple Debian/Ubuntu versions without hardcoding repo details.
    if ! curl -fsSL https://get.docker.com -o /tmp/get-docker.sh; then
        die "Failed to download Docker install script."
    fi

    if ! sh /tmp/get-docker.sh; then
        rm -f /tmp/get-docker.sh
        die "Docker installation failed."
    fi
    rm -f /tmp/get-docker.sh

    if ! command -v docker >/dev/null 2>&1; then
        die "Docker installation appears to have failed: 'docker' command not found."
    fi

    log_success "Docker installed successfully."
}

# --------------------------------------------------------------------------
# Step 4: Ensure Docker is running and enabled on boot
# --------------------------------------------------------------------------
enable_docker_service() {
    if command -v systemctl >/dev/null 2>&1; then
        log_info "Enabling and starting Docker service..."
        systemctl enable docker >/dev/null 2>&1 || log_warning "Could not enable docker service (systemctl enable failed)."
        systemctl start docker || die "Failed to start Docker service."
    else
        # Fallback for systems without systemd (rare on Debian/Ubuntu, but be safe)
        log_warning "systemctl not found. Attempting to start docker via service command."
        service docker start || die "Failed to start Docker service."
    fi

    # Verify docker daemon is actually reachable
    if ! docker info >/dev/null 2>&1; then
        die "Docker daemon is not responding. Please check Docker installation."
    fi

    log_success "Docker service is running."
}

# --------------------------------------------------------------------------
# Step 5: Verify Docker Compose plugin is available
# --------------------------------------------------------------------------
check_docker_compose() {
    if ! docker compose version >/dev/null 2>&1; then
        die "'docker compose' (Compose Plugin) is not available. Please ensure Docker was installed with the Compose plugin."
    fi
    log_info "Docker Compose plugin detected: $(docker compose version --short 2>/dev/null || echo 'OK')"
}

# --------------------------------------------------------------------------
# Step 6: Create installation directory and configuration files
# --------------------------------------------------------------------------
setup_install_dir() {
    log_info "Creating install directory at ${INSTALL_DIR}..."
    mkdir -p "${INSTALL_DIR}" || die "Failed to create ${INSTALL_DIR}."
}

write_env_file() {
    log_info "Writing configuration to ${ENV_FILE}..."

    # Overwrite any existing .env file (idempotent re-run support).
    cat > "${ENV_FILE}" <<EOF
CLOUDFLARE_API_TOKEN=${CF_API_TOKEN}
DOMAINS=${DDNS_DOMAIN}
EOF

    # By default, disable IPv6 management. Most VPS hosts only have an IPv4
    # address, so leaving IPv6 detection enabled just produces harmless but
    # noisy "No valid IPv6 addresses were detected" log spam. Users who pass
    # the optional "ipv6" argument opt in to IPv6 management instead.
    if [[ "${ENABLE_IPV6}" != "true" ]]; then
        echo "IP6_PROVIDER=none" >> "${ENV_FILE}"
    fi

    # Restrict permissions since this file contains a sensitive API token.
    chmod 600 "${ENV_FILE}" || log_warning "Could not set permissions on ${ENV_FILE}."

    log_success "Configuration written."
}

write_compose_file() {
    log_info "Writing Docker Compose file to ${COMPOSE_FILE}..."

    cat > "${COMPOSE_FILE}" <<EOF
services:
  cloudflare-ddns:
    image: ${IMAGE_NAME}
    container_name: ${CONTAINER_NAME}
    network_mode: host
    restart: unless-stopped
    env_file:
      - .env
EOF

    log_success "Docker Compose file written."
}

# --------------------------------------------------------------------------
# Step 7: Deploy / update the container (idempotent)
# --------------------------------------------------------------------------
deploy_container() {
    log_info "Pulling latest image (${IMAGE_NAME})..."
    if ! (cd "${INSTALL_DIR}" && docker compose pull); then
        die "Failed to pull image ${IMAGE_NAME}."
    fi

    log_info "Starting/recreating container..."
    # --force-recreate ensures that re-running this script always applies
    # any new .env values and the freshly pulled image, even if the
    # container already exists and looks "up to date" to Compose.
    if ! (cd "${INSTALL_DIR}" && docker compose up -d --force-recreate --remove-orphans); then
        die "Failed to start the DDNS container via docker compose."
    fi

    log_success "Container is up and running."
}

# --------------------------------------------------------------------------
# Step 8: Final summary
# --------------------------------------------------------------------------
print_summary() {
    echo
    log_success "Cloudflare DDNS Installed Successfully"
    echo
    echo "Domain:"
    echo "${DDNS_DOMAIN}"
    echo
    if [[ "${ENABLE_IPV6}" == "true" ]]; then
        echo "IPv6 Management: enabled"
    else
        echo "IPv6 Management: disabled (IP6_PROVIDER=none)"
    fi
    echo
    echo "Install Path:"
    echo "${INSTALL_DIR}"
    echo
    echo "Useful Commands:"
    echo
    echo "cd ${INSTALL_DIR} && docker compose logs -f"
    echo "cd ${INSTALL_DIR} && docker compose restart"
    echo "cd ${INSTALL_DIR} && docker compose down"
    echo
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
main() {
    validate_args "$@"
    check_root
    detect_os
    install_docker
    enable_docker_service
    check_docker_compose
    setup_install_dir
    write_env_file
    write_compose_file
    deploy_container
    print_summary
}

main "$@"
