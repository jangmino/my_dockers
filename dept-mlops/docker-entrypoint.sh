#!/usr/bin/env bash
set -euo pipefail

USER_NAME="${USER_NAME:-user}"
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

ALLOW_SUDO="${ALLOW_SUDO:-true}"              # true|false
SUDO_POLICY="${SUDO_POLICY:-full_no_shell}"   # full | full_no_shell | apt_only

HOME_DIR="/home/${USER_NAME}"
SSH_DIR="${HOME_DIR}/.ssh"

# 1) group/user 생성
if ! getent group "${PGID}" >/dev/null 2>&1; then
  groupadd -g "${PGID}" "${USER_NAME}" || true
fi

if ! id -u "${USER_NAME}" >/dev/null 2>&1; then
  useradd -m -u "${PUID}" -g "${PGID}" -s /bin/bash "${USER_NAME}"
fi

# 2) SSH authorized_keys: 심볼릭 링크
mkdir -p "${SSH_DIR}"
chmod 700 "${SSH_DIR}"
chown -R "${USER_NAME}:${PGID}" "${SSH_DIR}"

if [[ -f "/ssh-keys/authorized_keys" ]]; then
  rm -f "${SSH_DIR}/authorized_keys"
  ln -s "/ssh-keys/authorized_keys" "${SSH_DIR}/authorized_keys"
  chmod 600 "/ssh-keys/authorized_keys" 2>/dev/null || true
else
  touch "${SSH_DIR}/authorized_keys"
  chmod 600 "${SSH_DIR}/authorized_keys"
  chown "${USER_NAME}:${PGID}" "${SSH_DIR}/authorized_keys"
fi

# 3) workspace 권한 정리(실패해도 진행)
chown -R "${USER_NAME}:${PGID}" /workspace 2>/dev/null || true

# 4) sshd host key 영구화 (/etc/ssh/hostkeys 를 사용)
HOSTKEY_DIR="/etc/ssh/hostkeys"
mkdir -p "${HOSTKEY_DIR}"
chmod 700 "${HOSTKEY_DIR}"

# 키가 없으면 최초 1회 생성 (이 디렉터리가 호스트에 마운트되면 재생성돼도 유지됨)
if [[ ! -f "${HOSTKEY_DIR}/ssh_host_ed25519_key" ]]; then
  echo "[sshd] generating persistent host keys in ${HOSTKEY_DIR}"
  ssh-keygen -t ed25519 -f "${HOSTKEY_DIR}/ssh_host_ed25519_key" -N "" >/dev/null
fi

if [[ ! -f "${HOSTKEY_DIR}/ssh_host_rsa_key" ]]; then
  ssh-keygen -t rsa -b 4096 -f "${HOSTKEY_DIR}/ssh_host_rsa_key" -N "" >/dev/null
fi

chmod 600 "${HOSTKEY_DIR}/ssh_host_"*_key 2>/dev/null || true
chmod 644 "${HOSTKEY_DIR}/ssh_host_"*_key.pub 2>/dev/null || true

# sshd가 위 키를 쓰도록 HostKey 라인 보장(중복 추가 방지)
SSHD_CONFIG="/etc/ssh/sshd_config"
grep -q '^HostKey /etc/ssh/hostkeys/ssh_host_ed25519_key$' "${SSHD_CONFIG}" \
  || echo "HostKey /etc/ssh/hostkeys/ssh_host_ed25519_key" >> "${SSHD_CONFIG}"
grep -q '^HostKey /etc/ssh/hostkeys/ssh_host_rsa_key$' "${SSHD_CONFIG}" \
  || echo "HostKey /etc/ssh/hostkeys/ssh_host_rsa_key" >> "${SSHD_CONFIG}"

# 5) sudo 정책
SUDOERS_FILE="/etc/sudoers.d/${USER_NAME}"
rm -f "${SUDOERS_FILE}" 2>/dev/null || true

if [[ "${ALLOW_SUDO}" == "true" ]]; then
  case "${SUDO_POLICY}" in
    full)
      cat > "${SUDOERS_FILE}" <<EOF
${USER_NAME} ALL=(root) NOPASSWD:ALL
Defaults:${USER_NAME} env_reset
Defaults:${USER_NAME} secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Defaults:${USER_NAME} !requiretty
EOF
      ;;
    full_no_shell)
      cat > "${SUDOERS_FILE}" <<EOF
${USER_NAME} ALL=(root) NOPASSWD:ALL
Defaults:${USER_NAME} env_reset
Defaults:${USER_NAME} secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Defaults:${USER_NAME} !requiretty
# block root shells / su (reduce big accidents)
${USER_NAME} ALL=(root) NOPASSWD:ALL, !/bin/su, !/usr/bin/su, !/bin/bash, !/usr/bin/bash, !/bin/sh, !/usr/bin/sh
EOF
      ;;
    apt_only)
      cat > "${SUDOERS_FILE}" <<EOF
${USER_NAME} ALL=(root) NOPASSWD:/usr/bin/apt,/usr/bin/apt-get
Defaults:${USER_NAME} env_reset
Defaults:${USER_NAME} secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
Defaults:${USER_NAME} !requiretty
EOF
      ;;
    *)
      echo "Unknown SUDO_POLICY='${SUDO_POLICY}'. Use: full | full_no_shell | apt_only" >&2
      exit 1
      ;;
  esac
  chmod 0440 "${SUDOERS_FILE}"
else
  rm -f "${SUDOERS_FILE}" 2>/dev/null || true
fi

exec "$@"