#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

# DuckDNS + Let's Encrypt + acme.sh setup for this Docker routing project
# Target: Ubuntu/Debian
#
# Example:
#   sudo bash letencrypt-setup.sh \
#     --domain stvoid \
#     --token YOUR_DUCKDNS_TOKEN \
#     --email you@example.com
#
# This script uses DNS-01 validation through DuckDNS.
# It does NOT require port 80 to be open for certificate issuing.

PROJECT_DIR="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

DOMAIN=""
TOKEN=""
EMAIL=""

WILDCARD="no"
PRE_CLEAR_TXT="yes"
DNS_SLEEP="300"
FORCE_ISSUE="no"
DEBUG_ACME="no"
REUSE_EXISTING="no"

ACME_HOME="/root/.acme.sh"

usage() {
  cat <<EOF
Usage:
  sudo bash $0 --domain DOMAIN --token TOKEN --email EMAIL [options]
  sudo bash $0 --domain DOMAIN --reuse-existing

Required:
  --domain DOMAIN          DuckDNS subdomain, e.g. stvoid or stvoid.duckdns.org
  --token TOKEN            DuckDNS token (new setup only)
  --email EMAIL            Email for Let's Encrypt account (new setup only)

Options:
  --reuse-existing         Reuse /etc/ssl/duckdns/DOMAIN without issuing a cert
  --wildcard               Also cover *.DOMAIN.duckdns.org
  --dns-sleep SECONDS      Wait time for DuckDNS TXT propagation. Default: 300
  --no-clear-txt           Do not clear old DuckDNS TXT before issuing
  --force-issue            Force acme.sh to issue again
  --debug                  Run acme.sh issue command with --debug 2
  -h, --help               Show this help

Examples:
  sudo bash $0 --domain stvoid --reuse-existing

  sudo bash $0 --domain stvoid --token TOKEN --email me@example.com

  sudo bash $0 --domain stvoid.duckdns.org --token TOKEN --email me@example.com --dns-sleep 600

  sudo bash $0 --domain stvoid --token TOKEN --email me@example.com --wildcard
EOF
}

log() {
  echo
  echo "==> $*"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require_value() {
  local option="$1"
  local value="${2:-}"

  [[ -n "$value" && "$value" != --* ]] || die "$option requires a value"
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Run this script with sudo or as root."
  fi
}

require_debian_like() {
  if ! command -v apt-get >/dev/null 2>&1; then
    die "This script expects Ubuntu/Debian with apt-get."
  fi
}

require_docker_compose() {
  command -v docker >/dev/null 2>&1 || die "Docker is required."
  docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required."
}

normalize_domain() {
  local input="$1"

  input="${input#http://}"
  input="${input#https://}"
  input="${input%%/*}"

  # Accept wildcard-looking input but normalize to the DuckDNS base subdomain.
  input="${input#*.}"

  # Accept either "stvoid" or "stvoid.duckdns.org".
  input="${input%.duckdns.org}"

  if [[ ! "$input" =~ ^[a-zA-Z0-9-]+$ ]]; then
    die "Invalid DuckDNS subdomain: $input"
  fi

  DOMAIN="$(echo "$input" | tr '[:upper:]' '[:lower:]')"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --domain)
        require_value "$1" "${2:-}"
        DOMAIN="$2"
        shift 2
        ;;
      --token)
        require_value "$1" "${2:-}"
        TOKEN="$2"
        shift 2
        ;;
      --email)
        require_value "$1" "${2:-}"
        EMAIL="$2"
        shift 2
        ;;
      --wildcard)
        WILDCARD="yes"
        shift
        ;;
      --reuse-existing)
        REUSE_EXISTING="yes"
        shift
        ;;
      --dns-sleep)
        require_value "$1" "${2:-}"
        DNS_SLEEP="$2"
        shift 2
        ;;
      --no-clear-txt)
        PRE_CLEAR_TXT="no"
        shift
        ;;
      --force-issue)
        FORCE_ISSUE="yes"
        shift
        ;;
      --debug)
        DEBUG_ACME="yes"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done

  [[ -n "$DOMAIN" ]] || die "--domain is required"

  normalize_domain "$DOMAIN"

  if [[ "$REUSE_EXISTING" == "no" ]]; then
    [[ -n "$TOKEN" ]] || die "--token is required"
    [[ -n "$EMAIL" ]] || die "--email is required"
  fi

  if [[ ! "$DNS_SLEEP" =~ ^[0-9]+$ ]]; then
    die "--dns-sleep must be a number of seconds"
  fi

  if [[ "$DNS_SLEEP" -lt 120 ]]; then
    echo "WARNING: --dns-sleep below 120 may be too short for DuckDNS."
  fi
}

configure_project_env() {
  local env_file="${PROJECT_DIR}/.env"
  local fqdn="${DOMAIN}.duckdns.org"
  local cert_dir="/etc/ssl/duckdns/${DOMAIN}"

  if [[ ! -f "$env_file" ]]; then
    cp "${PROJECT_DIR}/.env.example" "$env_file"
  fi

  sed -i \
    -e "s|^ROUTING_CERT_DIR=.*$|ROUTING_CERT_DIR=${cert_dir}|" \
    -e "s|^VOID_OCCULT_HOST=.*$|VOID_OCCULT_HOST=${fqdn}|" \
    "$env_file"

  grep -q '^ROUTING_CERT_DIR=' "$env_file" ||
    printf 'ROUTING_CERT_DIR=%s\n' "$cert_dir" >> "$env_file"
  grep -q '^VOID_OCCULT_HOST=' "$env_file" ||
    printf 'VOID_OCCULT_HOST=%s\n' "$fqdn" >> "$env_file"
}

install_packages() {
  log "Installing required packages"

  apt-get update
  apt-get install -y curl socat cron ca-certificates dnsutils

  systemctl enable cron
  systemctl start cron
}

update_duckdns_ip() {
  log "Updating DuckDNS IPv4 record"

  local response
  response="$(curl -fsS "https://www.duckdns.org/update?domains=${DOMAIN}&token=${TOKEN}&ip=&verbose=true" || true)"

  echo "$response"

  if ! echo "$response" | grep -q "OK"; then
    die "DuckDNS IP update failed. Check your domain and token."
  fi
}

setup_duckdns_ip_cron() {
  log "Creating DuckDNS IP updater cron"

  local updater="/usr/local/bin/duckdns-update-${DOMAIN}.sh"
  local cron_file="/etc/cron.d/duckdns-update-${DOMAIN}"

  cat > "$updater" <<EOF
#!/usr/bin/env bash
curl -fsS "https://www.duckdns.org/update?domains=${DOMAIN}&token=${TOKEN}&ip=" >/var/log/duckdns-${DOMAIN}.log 2>&1
EOF

  chmod 700 "$updater"

  cat > "$cron_file" <<EOF
*/5 * * * * root ${updater}
EOF

  chmod 644 "$cron_file"

  echo "Created:"
  echo "  $updater"
  echo "  $cron_file"
}

clear_duckdns_txt() {
  if [[ "$PRE_CLEAR_TXT" != "yes" ]]; then
    log "Skipping DuckDNS TXT clear because --no-clear-txt was used"
    return
  fi

  log "Clearing old DuckDNS TXT record"

  local response
  response="$(curl -fsS "https://www.duckdns.org/update?domains=${DOMAIN}&token=${TOKEN}&txt=&clear=true&verbose=true" || true)"

  echo "$response"

  if ! echo "$response" | grep -q "OK"; then
    die "Failed to clear DuckDNS TXT record. Check your domain and token."
  fi

  log "Waiting 60 seconds after TXT clear"
  sleep 60
}

install_acme_sh() {
  log "Installing acme.sh"

  if [[ ! -x "${ACME_HOME}/acme.sh" ]]; then
    curl -fsSL https://get.acme.sh | sh -s email="$EMAIL"
  else
    echo "acme.sh already installed at ${ACME_HOME}/acme.sh"
  fi

  "${ACME_HOME}/acme.sh" --set-default-ca --server letsencrypt
  "${ACME_HOME}/acme.sh" --register-account -m "$EMAIL" --server letsencrypt || true
}

issue_certificate() {
  log "Issuing Let's Encrypt certificate using DuckDNS DNS-01"

  export DuckDNS_Token="$TOKEN"

  local cert_domain="${DOMAIN}.duckdns.org"

  local cmd=(
    "${ACME_HOME}/acme.sh"
    --issue
    --dns dns_duckdns
    -d "$cert_domain"
    --keylength ec-256
    --dnssleep "$DNS_SLEEP"
    --server letsencrypt
  )

  if [[ "$WILDCARD" == "yes" ]]; then
    cmd+=(-d "*.${cert_domain}")
  fi

  if [[ "$FORCE_ISSUE" == "yes" ]]; then
    cmd+=(--force)
  fi

  if [[ "$DEBUG_ACME" == "yes" ]]; then
    cmd+=(--debug 2)
  fi

  "${cmd[@]}"
}

install_certificate() {
  log "Installing certificate files for Docker Nginx"

  local cert_domain="${DOMAIN}.duckdns.org"
  local cert_dir="/etc/ssl/duckdns/${DOMAIN}"
  local reload_script="${PROJECT_DIR}/scripts/reload-nginx.sh"

  mkdir -p "$cert_dir"
  chmod +x "$reload_script"

  "${ACME_HOME}/acme.sh" --install-cert \
    -d "$cert_domain" \
    --ecc \
    --key-file "${cert_dir}/privkey.pem" \
    --fullchain-file "${cert_dir}/fullchain.pem" \
    --reloadcmd "$reload_script"

  chmod 600 "${cert_dir}/privkey.pem"
  chmod 644 "${cert_dir}/fullchain.pem"
}

start_router() {
  log "Starting the production routing stack"

  docker compose \
    -f "${PROJECT_DIR}/docker-compose.yml" \
    -f "${PROJECT_DIR}/docker-compose.prod.yml" \
    up -d
}

show_dns_check_commands() {
  log "Useful DNS TXT check commands"

  echo "During an ACME challenge, you can check DuckDNS TXT records with:"
  echo
  echo "  dig TXT _acme-challenge.${DOMAIN}.duckdns.org @ns1.duckdns.org"
  echo "  dig TXT _acme-challenge.${DOMAIN}.duckdns.org @ns2.duckdns.org"
  echo "  dig TXT _acme-challenge.${DOMAIN}.duckdns.org @ns3.duckdns.org"
}

show_summary() {
  local fqdn="${DOMAIN}.duckdns.org"
  local cert_dir="/etc/ssl/duckdns/${DOMAIN}"

  log "Setup complete"

  echo "DuckDNS domain:"
  echo "  ${fqdn}"
  echo

  echo "Certificate files:"
  echo "  ${cert_dir}/fullchain.pem"
  echo "  ${cert_dir}/privkey.pem"
  echo

  echo "DuckDNS IP updater:"
  echo "  /usr/local/bin/duckdns-update-${DOMAIN}.sh"
  echo "  /etc/cron.d/duckdns-update-${DOMAIN}"
  echo

  echo "acme.sh renewal check:"
  echo "  ${ACME_HOME}/acme.sh --cron --home ${ACME_HOME}"
  echo

  echo "Root crontab:"
  crontab -l || true
  echo

  echo "Open:"
  echo "  https://${fqdn}"
  echo

  echo "To force re-issue later:"
  echo "  sudo bash $0 --domain ${DOMAIN} --token YOUR_TOKEN --email YOUR_EMAIL --force-issue"
}

main() {
  parse_args "$@"
  require_root
  require_debian_like
  require_docker_compose
  configure_project_env

  if [[ "$REUSE_EXISTING" == "yes" ]]; then
    [[ -s "/etc/ssl/duckdns/${DOMAIN}/fullchain.pem" ]] ||
      die "Missing /etc/ssl/duckdns/${DOMAIN}/fullchain.pem"
    [[ -s "/etc/ssl/duckdns/${DOMAIN}/privkey.pem" ]] ||
      die "Missing /etc/ssl/duckdns/${DOMAIN}/privkey.pem"
    [[ -x "${ACME_HOME}/acme.sh" ]] ||
      die "acme.sh was not found at ${ACME_HOME}/acme.sh"

    log "Reusing the existing certificate in /etc/ssl/duckdns/${DOMAIN}"
    install_certificate
    start_router
    show_summary
    return
  fi

  install_packages
  update_duckdns_ip
  setup_duckdns_ip_cron
  install_acme_sh

  if [[ -s "/etc/ssl/duckdns/${DOMAIN}/fullchain.pem" &&
        -s "/etc/ssl/duckdns/${DOMAIN}/privkey.pem" ]]; then
    log "Reusing the existing certificate in /etc/ssl/duckdns/${DOMAIN}"
  else
    clear_duckdns_txt
    issue_certificate
  fi

  install_certificate
  start_router
  show_dns_check_commands
  show_summary
}

main "$@"
