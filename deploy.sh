#!/usr/bin/env bash
set -euo pipefail

readonly REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly ANSIBLE_DIR="${REPO_ROOT}/ansible"
readonly ANSIBLE_PLAYBOOK="${REPO_ROOT}/.venv/bin/ansible-playbook"
readonly STATE_DIR="/etc/matrix-deploy"
readonly RUNTIME_DIR="/run/matrix-deploy"
readonly CONFIG_FILE="${STATE_DIR}/deployment.yml"
readonly VERSION_LOCK_FILE="${STATE_DIR}/versions.yml"
readonly SECRET_FILE="${RUNTIME_DIR}/secrets.yml"

log() {
  printf '[deploy] %s\n' "$*"
}

fatal() {
  printf '[deploy] ERROR: %s\n' "$*" >&2
  exit 1
}

prompt_default() {
  local prompt="$1"
  local default="$2"
  local value

  read -r -p "${prompt} [${default}]: " value
  printf '%s' "${value:-$default}"
}

prompt_yes_no() {
  local prompt="$1"
  local default="${2:-y}"
  local suffix='[Y/n]'
  local answer

  [[ "$default" == 'n' ]] && suffix='[y/N]'

  while true; do
    read -r -p "${prompt} ${suffix}: " answer
    answer="${answer:-$default}"
    answer="${answer//$'\r'/}"
    answer="${answer#"${answer%%[![:space:]]*}"}"
    answer="${answer%"${answer##*[![:space:]]}"}"

    case "${answer,,}" in
      y|yes) return 0 ;;
      n|no) return 1 ;;
      *) printf 'Please answer y/yes or n/no.\n' >&2 ;;
    esac
  done
}

detect_external_ipv4() {
  curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true
}

detect_ssh_port() {
  local port=''

  # Prefer the server port of the current remote session. This remains correct
  # when sshd listens on multiple Port directives.
  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    port="$(awk '{print $4}' <<<"$SSH_CONNECTION")"
  fi

  if [[ -z "$port" ]] && command -v sshd >/dev/null 2>&1; then
    port="$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2; exit}')"
  fi

  printf '%s' "${port:-22}"
}

is_dns_label() {
  local label="$1"
  [[ ${#label} -le 63 ]] &&
    [[ "$label" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]]
}

is_dns_name() {
  local name="$1"
  local label
  local labels=()

  [[ -n "$name" && ${#name} -le 253 ]] || return 1
  IFS='.' read -r -a labels <<<"$name"
  (( ${#labels[@]} >= 2 )) || return 1

  for label in "${labels[@]}"; do
    is_dns_label "$label" || return 1
  done
}

is_acme_email() {
  local email="$1"
  local domain

  [[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]] || return 1
  domain="${email##*@}"

  case "${domain,,}" in
    example.com|*.example.com|example.org|*.example.org|example.net|*.example.net) return 1 ;;
  esac

  return 0
}

prompt_acme_email() {
  local email

  while true; do
    read -r -p "Let's Encrypt email: " email
    if is_acme_email "$email"; then
      printf '%s' "$email"
      return 0
    fi

    printf 'A real email address is required for Let\x27s Encrypt; example.com/example.org/example.net placeholders are not accepted.\n' >&2
  done
}

is_ipv4() {
  local address="$1"
  python3 -c 'import ipaddress,sys; a=ipaddress.ip_address(sys.argv[1]); raise SystemExit(0 if a.version == 4 else 1)' "$address" >/dev/null 2>&1
}

is_local_ipv4() {
  local address="$1"
  local addresses

  addresses="$(ip -4 -o addr show 2>/dev/null | awk '{split($4, a, "/"); print a[1]}')"
  grep -Fxq -- "$address" <<<"$addresses"
}

if [[ ${EUID} -ne 0 ]]; then
  fatal "deploy.sh must be run as root"
fi

if [[ ! -x "$ANSIBLE_PLAYBOOK" ]]; then
  fatal "Ansible venv is missing; run ./bootstrap.sh first"
fi

if [[ -e "$CONFIG_FILE" ]]; then
  fatal "an existing installation was found (${CONFIG_FILE}). Running deploy again would overwrite the topology and upgrade versions without a backup. Use 'matrix-deploy converge' (or 'matrix-deploy converge --admin-password' for an unfinished installation) or 'matrix-deploy upgrade'."
fi

install -d -m 0700 "$STATE_DIR" "$RUNTIME_DIR"

cleanup() {
  rm -f "$SECRET_FILE"
}
trap cleanup EXIT INT TERM

printf '\nMatrix Deploy\n============\n\n'

BASE_DOMAIN="$(prompt_default 'Base domain' 'example.com')"
SYNAPSE_PREFIX="$(prompt_default 'Matrix homeserver prefix' 'matrix')"
ELEMENT_PREFIX="$(prompt_default 'Element Web prefix' 'element')"
ADMIN_PREFIX="$(prompt_default 'Ketesa/Synapse Admin prefix' 'synad')"
CALL_PREFIX="$(prompt_default 'Element Call prefix' 'call')"
RTC_PREFIX="$(prompt_default 'LiveKit/MatrixRTC prefix' 'rtc')"
TURN_PREFIX="$(prompt_default 'Legacy TURN prefix' 'turn')"
CERTBOT_EMAIL="$(prompt_acme_email)"

is_dns_name "$BASE_DOMAIN" || fatal "invalid base domain: $BASE_DOMAIN"
for prefix in "$SYNAPSE_PREFIX" "$ELEMENT_PREFIX" "$ADMIN_PREFIX" "$CALL_PREFIX" "$RTC_PREFIX" "$TURN_PREFIX"; do
  is_dns_label "$prefix" || fatal "invalid DNS prefix: $prefix"
done
is_acme_email "$CERTBOT_EMAIL" || fatal "invalid Let's Encrypt email: $CERTBOT_EMAIL"

if prompt_yes_no 'Enable Matrix federation?' 'y'; then
  FEDERATION=true
else
  FEDERATION=false
fi

DETECTED_IP="$(detect_external_ipv4)"
if [[ -z "$DETECTED_IP" ]]; then
  MATRIX_EXTERNAL_IP="$(prompt_default 'Could not detect the public IPv4. Enter it' '')"
else
  printf 'Detected external IPv4: %s\n' "$DETECTED_IP"
  if prompt_yes_no 'Use this IPv4?' 'y'; then
    MATRIX_EXTERNAL_IP="$DETECTED_IP"
  else
    MATRIX_EXTERNAL_IP="$(prompt_default 'Public IPv4' "$DETECTED_IP")"
  fi
fi

is_ipv4 "$MATRIX_EXTERNAL_IP" || fatal "invalid IPv4: $MATRIX_EXTERNAL_IP"

SSH_PORT="$(detect_ssh_port)"
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || fatal "invalid SSH port: $SSH_PORT"
printf 'SSH port: %s\n' "$SSH_PORT"

if is_local_ipv4 "$MATRIX_EXTERNAL_IP"; then
  COTURN_NETWORK_MODE='direct_public'
  COTURN_RELAY_IP="$MATRIX_EXTERNAL_IP"
  printf 'TURN network mode: direct_public\n'
else
  COTURN_NETWORK_MODE='nat'
  DEFAULT_RELAY_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") print $(i+1)}')"
  COTURN_RELAY_IP="$(prompt_default 'The public IPv4 is not assigned to this host. Local relay IP for Coturn' "$DEFAULT_RELAY_IP")"
  is_ipv4 "$COTURN_RELAY_IP" || fatal "invalid local relay IPv4: $COTURN_RELAY_IP"
  printf 'TURN network mode: NAT (%s -> %s)\n' "$COTURN_RELAY_IP" "$MATRIX_EXTERNAL_IP"
  printf 'The external NAT must forward the TURN/RTC ports to this server.\n'
fi

read -r -s -p 'Matrix admin password: ' MATRIX_ADMIN_PASSWORD
printf '\n'
[[ -n "$MATRIX_ADMIN_PASSWORD" ]] || fatal 'Matrix admin password must not be empty'

cat > "$CONFIG_FILE" <<EOF_CONFIG
---
matrix_base_domain: "${BASE_DOMAIN}"
matrix_subdomains:
  synapse: "${SYNAPSE_PREFIX}"
  element: "${ELEMENT_PREFIX}"
  admin: "${ADMIN_PREFIX}"
  turn: "${TURN_PREFIX}"
  livekit: "${RTC_PREFIX}"
  element_call: "${CALL_PREFIX}"
certbot_email: "${CERTBOT_EMAIL}"
matrix_external_ip: "${MATRIX_EXTERNAL_IP}"
matrix_ssh_port: ${SSH_PORT}
matrix_ipv6_enabled: false
synapse_enable_federation: ${FEDERATION}
coturn_network_mode: "${COTURN_NETWORK_MODE}"
coturn_relay_ip: "${COTURN_RELAY_IP}"
EOF_CONFIG
chmod 0600 "$CONFIG_FILE"

cat > "$SECRET_FILE" <<EOF_SECRET
---
matrix_admin_password: '${MATRIX_ADMIN_PASSWORD//\'/\'\'}'
EOF_SECRET
chmod 0600 "$SECRET_FILE"
unset MATRIX_ADMIN_PASSWORD

printf '\nDeployment plan\n---------------\n'
printf 'Matrix:       %s.%s\n' "$SYNAPSE_PREFIX" "$BASE_DOMAIN"
printf 'Element:      %s.%s\n' "$ELEMENT_PREFIX" "$BASE_DOMAIN"
printf 'Admin:        %s.%s\n' "$ADMIN_PREFIX" "$BASE_DOMAIN"
printf 'Element Call: %s.%s\n' "$CALL_PREFIX" "$BASE_DOMAIN"
printf 'MatrixRTC:    %s.%s\n' "$RTC_PREFIX" "$BASE_DOMAIN"
printf 'Legacy TURN:  %s.%s\n' "$TURN_PREFIX" "$BASE_DOMAIN"
printf 'Public IPv4: %s\n' "$MATRIX_EXTERNAL_IP"
printf 'Federation:  %s\n' "$FEDERATION"
printf 'Runtime config: %s\n\n' "$CONFIG_FILE"

log 'running Ansible preflight and resolving the latest stable upstream versions'
(
  cd "$ANSIBLE_DIR"
  "$ANSIBLE_PLAYBOOK" playbooks/preflight.yml \
    --extra-vars "@${CONFIG_FILE}" \
    --extra-vars "@${SECRET_FILE}" \
    --extra-vars 'matrix_refresh_versions=true'
)

[[ -r "$VERSION_LOCK_FILE" ]] || fatal "preflight did not create the version lock: $VERSION_LOCK_FILE"

if ! prompt_yes_no 'Preflight succeeded. Start the deployment?' 'n'; then
  printf 'Deployment cancelled. Configuration saved: %s\n' "$CONFIG_FILE"
  printf 'Selected versions saved: %s\n' "$VERSION_LOCK_FILE"
  printf 'To continue later: matrix-deploy converge --admin-password\n'
  exit 0
fi

log 'running the main playbook with versions from the preflight lock'
(
  cd "$ANSIBLE_DIR"
  "$ANSIBLE_PLAYBOOK" playbooks/site.yml \
    --extra-vars "@${CONFIG_FILE}" \
    --extra-vars "@${VERSION_LOCK_FILE}" \
    --extra-vars "@${SECRET_FILE}"
)
