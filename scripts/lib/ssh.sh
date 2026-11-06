#!/usr/bin/env bash
# Shared SSH helpers. Login flow (identical to bpom-deploy.yml):
#   runner -> Autobahn jump host (Vault-signed cert) -> target host -> sudo -u mradmin
# Requires (set by .github/actions/autobahn-ssh): BPOMVAULT_SSH_USER, optional BPOMVAULT_SSH_PORT,
# SSH_AUTH_SOCK, ~/.ssh/id_rsa-atb-svc-cert.pub

: "${BPOMVAULT_SSH_USER:?BPOMVAULT_SSH_USER is not set}"
AUTOBAHN_JUMP_SERVER="${AUTOBAHN_JUMP_SERVER:-jump.autobahn.comcast.com}"
RUN_AS_USER="${RUN_AS_USER:-mradmin}"
SSH_PORT_NUM="${BPOMVAULT_SSH_PORT:-22}"
SSH_CERT="$HOME/.ssh/id_rsa-atb-svc-cert.pub"
LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

BASE_OPTS=(
  -o "CertificateFile=${SSH_CERT}"
  -o "ProxyCommand=ssh -qx -o CertificateFile=${SSH_CERT} -o StrictHostKeyChecking=accept-new -o BatchMode=yes svcAutobahn@${AUTOBAHN_JUMP_SERVER} -W %h:%p"
  -o BatchMode=yes
  -o ConnectTimeout=30
  -o ServerAliveInterval=30
  -o StrictHostKeyChecking=accept-new
)

# remote_plain HOST 'command'   -> run as the SSH login user
remote_plain() {
  local host="$1" cmd="$2"
  ssh -p "$SSH_PORT_NUM" "${BASE_OPTS[@]}" "${BPOMVAULT_SSH_USER}@${host}" "$cmd"
}

# remote_copy HOST LOCAL REMOTE_PATH
remote_copy() {
  local host="$1" src="$2" dst="$3"
  scp -P "$SSH_PORT_NUM" "${BASE_OPTS[@]}" "$src" "${BPOMVAULT_SSH_USER}@${host}:${dst}"
}

# remote_run HOST SCRIPT [VAR=value ...]
# Runs scripts/remote/common.sh + SCRIPT on the host as ${RUN_AS_USER}.
# The script is streamed over stdin, so remote scripts must never read stdin themselves.
remote_run() {
  local host="$1" script="$2"; shift 2
  {
    for kv in "$@"; do printf 'export %q\n' "$kv"; done
    cat "${LIB_DIR}/../remote/common.sh" "$script"
  } | ssh -p "$SSH_PORT_NUM" "${BASE_OPTS[@]}" "${BPOMVAULT_SSH_USER}@${host}" "sudo -u ${RUN_AS_USER} bash -s"
}
