#!/usr/bin/env bash
#
# ddns.sh - One-click installer for Cloudflare DDNS (favonia/cloudflare-ddns)
#
# Usage:
#   bash ddns.sh <Cloudflare_API_Token> <Domain> [ipv6]
#
# This script is idempotent: it can be re-run safely at any time to update
# the configuration and/or the running container to the latest image.
#
# Supported systems: Debian 11+/12+, Ubuntu 20.04+/22.04+/24.04+
#
set +x # Do not trace credentials, even when invoked with bash -x.
set -euo pipefail
umask 077

# --------------------------------------------------------------------------
# Constants
# --------------------------------------------------------------------------
readonly INSTALL_DIR="/opt/cloudflare-ddns"
readonly TOKEN_FILE="${INSTALL_DIR}/cloudflare-api-token"
readonly CF_API_BASE="https://api.cloudflare.com/client/v4"
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
bash ddns.sh <Domain> [ipv6]  # optional hidden token prompt
EOF
}

# Use the controlling terminal even when Bash is reading the installer from
# a pipe. Restore its previous settings on both normal exit and signals.
prompt_for_token() (
    { exec 8</dev/tty; } 2>/dev/null || return 1
    tty_settings=$(stty -g <&8) || return 1
    trap 'stty "$tty_settings" <&8; printf "\n" >&2' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    stty -echo -echonl <&8 || return 1
    printf '%s' 'Cloudflare API Token: ' >&2
    IFS= read -r token <&8 || return 1
    printf '%s' "$token"
)

validate_args() {
    local LC_ALL=C token="" mode="" domain_pattern
    case "$#" in
        1) DDNS_DOMAIN="$1" ;;
        2)
            if [[ "$2" == ipv6 ]]; then
                DDNS_DOMAIN="$1"; mode="$2"
            else
                token="$1"; DDNS_DOMAIN="$2"
            fi
            ;;
        3) token="$1"; DDNS_DOMAIN="$2"; mode="$3" ;;
        *) print_usage; exit 1 ;;
    esac

    domain_pattern='^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$'
    DDNS_DOMAIN="${DDNS_DOMAIN%.}"
    [[ ${#DDNS_DOMAIN} -le 253 && "$DDNS_DOMAIN" =~ $domain_pattern && ! "${DDNS_DOMAIN##*.}" =~ ^[0-9]+$ ]] ||
        die "Enter one fully qualified domain name (use Punycode for international names)."
    DDNS_DOMAIN=$(tr "[:upper:]" "[:lower:]" <<<"$DDNS_DOMAIN")
    [[ -z "$mode" || "$mode" == ipv6 ]] || die "The optional argument must be 'ipv6'."
    ENABLE_IPV6=false
    if [[ "$mode" == ipv6 ]]; then
        ENABLE_IPV6=true
    fi

    if [[ $# == 3 || ( $# == 2 && "$2" != ipv6 ) ]]; then
        log_warning "A token passed as an argument can be visible in process listings."
    else
        token=$(prompt_for_token) || die "Could not read the API token from the terminal."
    fi
    [[ "$token" =~ ^[a-zA-Z0-9_-]+$ ]] || die "Invalid Cloudflare API Token format."
    API_TOKEN="$token"
    export -n API_TOKEN
}

# --------------------------------------------------------------------------
# Step 1: Must run as root
# --------------------------------------------------------------------------
check_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "This script must be run as root. Try: sudo bash ddns.sh <Cloudflare_API_Token> <Domain>"
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

    local installer
    installer=$(mktemp) || die "Could not create a temporary Docker installer."
    if ! curl -q -fsSL https://get.docker.com -o "$installer" || ! sh "$installer"; then
        rm -f -- "$installer"
        die "Docker installation failed."
    fi
    rm -f -- "$installer"

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
# DNS initialization
# --------------------------------------------------------------------------
install_dns_dependencies() {
    local -a missing=()
    local tool
    for tool in curl jq; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    if [[ -n "${missing[*]:-}" ]]; then
        if ! apt-get update -y || ! apt-get install -y "${missing[@]}"; then
            die "Could not install DNS setup dependencies."
        fi
    fi
}

discover_ipv4() {
    local trace ip
    trace=$(curl -q -4fsS --noproxy '*' --connect-timeout 5 --max-time 15 https://api.cloudflare.com/cdn-cgi/trace) ||
        die "Could not detect the VPS public IPv4."
    ip=$(sed -n 's/^ip=//p' <<<"$trace")
    # Require a single, canonical IPv4 address. Reject non-public ranges that
    # may be returned by a misconfigured IP detection endpoint.
    jq -en --arg ip "$ip" '
        $ip | select(test("\\A(0|[1-9][0-9]{0,2})(\\.(0|[1-9][0-9]{0,2})){3}\\z")) |
        split(".") | map(tonumber) as [$a, $b, $c, $d] |
        ($a > 0 and $a < 224 and $a != 10 and $a != 127 and
         $b < 256 and $c < 256 and $d < 256 and
         (($a == 100 and $b >= 64 and $b <= 127) or
          ($a == 169 and $b == 254) or ($a == 172 and $b >= 16 and $b <= 31) or
          ($a == 192 and (($b == 0 and ($c == 0 or $c == 2)) or $b == 168)) or
          ($a == 198 and ($b == 18 or $b == 19 or ($b == 51 and $c == 100))) or
          ($a == 203 and $b == 0 and $c == 113) | not))
    ' >/dev/null || die "IP discovery did not return a usable public IPv4."
    PUBLIC_IPV4="$ip"
}

cf_api() {
    local method="$1" endpoint="$2" response status
    shift 2
    # Read auth from stdin, not argv or the environment. Disable ~/.curlrc
    # and never print raw API error messages (which could contain secrets).
    response=$(printf 'header = "Authorization: Bearer %s"\n' "$API_TOKEN" |
        curl -q -sS --config - --connect-timeout 5 --max-time 30 --write-out $'\n%{http_code}' \
            --request "$method" --header 'Content-Type: application/json' \
            "$@" "${CF_API_BASE}${endpoint}") || {
        log_error "Cloudflare request failed ($method $endpoint). Check connectivity and token permissions."
        return 1
    }
    status="${response##*$'\n'}"
    response="${response%$'\n'*}"
    if [[ ! "$status" =~ ^[0-9]{3}$ ]]; then
        log_error "Cloudflare response had no HTTP status ($method $endpoint)."
        return 1
    fi
    if [[ ! "$status" =~ ^2[0-9]{2}$ ]]; then
        log_error "Cloudflare returned HTTP $status ($method $endpoint). Check token permissions and zone access."
        return 1
    fi
    if ! jq -se 'length == 1 and (.[0] | .success == true and has("result"))' <<<"$response" >/dev/null 2>&1; then
        log_error "Cloudflare rejected the request or returned invalid JSON ($method $endpoint)."
        return 1
    fi
    printf '%s\n' "$response"
}

find_zone() {
    local candidate="$DDNS_DOMAIN" response zone_id
    # Try the most specific name first, including a possible delegated zone.
    while [[ "$candidate" == *.* ]]; do
        response=$(cf_api GET "/zones?name=${candidate}&per_page=50") || return 1
        zone_id=$(jq -er --arg name "$candidate" '
            if (.result | type) != "array" or (.result_info.total_pages // 1) > 1 then error("invalid zone list") else . end |
            [.result[] | select(.name == $name)] |
            if length == 0 then "" elif length == 1 then
                .[0].id | strings | select(test("\\A[0-9a-f]{32}\\z"))
            else error("ambiguous zone") end
        ' <<<"$response" 2>/dev/null) || return 1
        if [[ -n "$zone_id" ]]; then
            printf '%s\n' "$zone_id"
            return
        fi
        candidate="${candidate#*.}"
    done
    return 1
}

check_a_result() {
    jq -e --argjson wanted "$1" --arg id "${2:-}" '
        .result as $r |
        ($r.id | type == "string" and test("\\A[0-9a-f]{32}\\z")) and
        ($id == "" or $r.id == $id) and
        ($r | {name, type, content, proxied, ttl}) == $wanted
    ' >/dev/null 2>&1
}

initialize_dns() {
    local zone endpoint response records count id wanted backup original restore_payload
    zone=$(find_zone) || die "Could not identify a unique Cloudflare zone for $DDNS_DOMAIN."
    endpoint="/zones/${zone}/dns_records"
    response=$(cf_api GET "${endpoint}?name.exact=${DDNS_DOMAIN}&per_page=100") ||
        die "Could not list DNS records for $DDNS_DOMAIN."
    records=$(jq -ce --arg name "$DDNS_DOMAIN" '
        if (.result | type) != "array" or (.result_info.total_pages // 1) > 1 then error("incomplete DNS list") else . end |
        [.result[] | select(.name == $name)]
    ' <<<"$response" 2>/dev/null) || die "Could not verify the DNS record list."
    # A proxied AAAA would also make the same name's A effectively proxied.
    if jq -e 'any(.[]; .type == "AAAA" and .proxied == true)' <<<"$records" >/dev/null; then
        die "A proxied AAAA record exists for $DDNS_DOMAIN; disable its proxy before installing."
    fi
    records=$(jq -c 'map(select(.type == "A" or .type == "CNAME"))' <<<"$records")
    count=$(jq 'length' <<<"$records")
    (( count <= 1 )) || die "Multiple A/CNAME records exist for $DDNS_DOMAIN; resolve them before installing."

    wanted=$(jq -cn --arg name "$DDNS_DOMAIN" --arg ip "$PUBLIC_IPV4" \
        '{name:$name, type:"A", content:$ip, proxied:false, ttl:1}')
    if (( count == 0 )); then
        if ! response=$(cf_api POST "$endpoint" --data-binary "$wanted") ||
            ! check_a_result "$wanted" <<<"$response"; then
            die "Could not create and verify the A record."
        fi
    else
        id=$(jq -er '.[0].id | strings | select(test("\\A[0-9a-f]{32}\\z"))' <<<"$records") ||
            die "Invalid DNS record ID; no record was modified."
        if [[ $(jq -r '.[0].type' <<<"$records") == A ]]; then
            # Send all desired fields, even when the address already matches.
            # This also verifies write access when the record is already correct.
            if ! response=$(cf_api PATCH "${endpoint}/${id}" --data-binary "$wanted") ||
                ! check_a_result "$wanted" "$id" <<<"$response"; then
                die "Could not update and verify the A record."
            fi
        else
            original=$(jq -c '.[0]' <<<"$records")
            restore_payload=$(jq -ce '
                select((.content | type == "string" and length > 0) and
                       (.proxied | type == "boolean") and (.ttl | type == "number")) |
                {type, name, content, proxied, ttl, comment, tags, settings, private_routing} |
                with_entries(select(.value != null))
            ' <<<"$original") || die "Invalid CNAME data; no record was deleted."
            backup=$(mktemp "${INSTALL_DIR}/cname-backup.XXXXXXXX") ||
                die "Could not create a CNAME backup; no record was deleted."
            printf '%s\n' "$original" >"$backup" ||
                die "Could not write the CNAME backup; no record was deleted."
            log_info "Saved the original CNAME at $backup."

            if ! response=$(cf_api DELETE "${endpoint}/${id}") ||
                ! jq -e --arg id "$id" '.result.id == $id' <<<"$response" >/dev/null 2>&1; then
                die "Could not confirm CNAME deletion. Check DNS before retrying; backup: $backup."
            fi

            if ! response=$(cf_api POST "$endpoint" --data-binary "$wanted") ||
                ! check_a_result "$wanted" <<<"$response"; then
                log_warning "A record creation could not be confirmed; attempting to restore the original CNAME."
                if response=$(cf_api POST "$endpoint" --data-binary "$restore_payload") &&
                    jq -e --argjson original "$restore_payload" '
                        .result as $r |
                        ($r.id | type == "string" and test("\\A[0-9a-f]{32}\\z")) and
                        all($original | keys_unsorted[]; . as $key | $r[$key] == $original[$key])
                    ' <<<"$response" >/dev/null 2>&1; then
                    die "A record creation failed; the original CNAME was restored. Backup: $backup."
                fi
                die "A record creation failed and CNAME restoration could not be verified. Check DNS; backup: $backup."
            fi
        fi
    fi
    log_success "$DDNS_DOMAIN → $PUBLIC_IPV4 (A, DNS only, Auto TTL)."
}

# --------------------------------------------------------------------------
# Write protected installation files
# --------------------------------------------------------------------------
setup_install_dir() {
    [[ ! -L "$INSTALL_DIR" ]] || die "Install directory must not be a symlink."
    if ! mkdir -p "$INSTALL_DIR" || [[ ! -O "$INSTALL_DIR" ]] || ! chmod 700 "$INSTALL_DIR"; then
        die "Could not secure $INSTALL_DIR."
    fi
    # Serialize installer runs on this VPS.
    exec 9<"$INSTALL_DIR"
    flock -n 9 || die "Another DDNS installer is running, or the install lock is unavailable."
}

write_env_file() {
    local env_tmp token_tmp
    env_tmp=$(mktemp "${INSTALL_DIR}/.env.XXXXXXXX") || die "Could not prepare DDNS configuration."
    token_tmp=$(mktemp "${INSTALL_DIR}/.token.XXXXXXXX") || die "Could not prepare token file."
    printf '%s\n' "$API_TOKEN" >"$token_tmp"
    # The image runs unprivileged. The root-only parent directory protects
    # the token on the host while the container receives just this file.
    chmod 444 "$token_tmp"
    mv -fT -- "$token_tmp" "$TOKEN_FILE"
    unset API_TOKEN

    cat >"$env_tmp" <<EOF
CLOUDFLARE_API_TOKEN_FILE=/run/secrets/cloudflare_api_token
DOMAINS=${DDNS_DOMAIN}
PROXIED=false
TTL=1
UPDATE_CRON=@every 2m
EOF
    if [[ "$ENABLE_IPV6" != true ]]; then
        printf '%s\n' 'IP6_PROVIDER=none' >>"$env_tmp"
    fi
    # Replace the legacy .env (which stored the token inline).
    mv -fT -- "$env_tmp" "$ENV_FILE"
}

write_compose_file() {
    local compose_tmp
    compose_tmp=$(mktemp "${INSTALL_DIR}/.compose.XXXXXXXX") || die "Could not prepare Docker Compose configuration."
    cat >"$compose_tmp" <<EOF
services:
  cloudflare-ddns:
    image: ${IMAGE_NAME}
    container_name: ${CONTAINER_NAME}
    network_mode: host
    restart: unless-stopped
    env_file:
      - .env
    secrets:
      - cloudflare_api_token

secrets:
  cloudflare_api_token:
    file: ./cloudflare-api-token
EOF

    mv -fT -- "$compose_tmp" "$COMPOSE_FILE"
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
    check_root
    validate_args "$@"
    detect_os
    install_dns_dependencies
    discover_ipv4
    setup_install_dir
    initialize_dns
    install_docker
    enable_docker_service
    check_docker_compose
    write_env_file
    write_compose_file
    deploy_container
    print_summary
}

if [[ "${BASH_SOURCE[0]:-$0}" == "$0" ]]; then
    main "$@"
fi
