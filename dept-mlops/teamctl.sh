#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="/opt/mlops"
COMPOSE_FILE="${BASE_DIR}/compose.yaml"
GPU_MODE_FILE="${BASE_DIR}/.gpu_mode"
IMAGE="mlops:latest"

TEAMS_DIR="/data/teams"
SSH_DIR="/data/ssh"

PORT_BASE=22020
UID_BASE=12000
GID_BASE=12000

SHM_SIZE="16g"
IPC_MODE="host"

DEFAULT_SUDO_MODE="full_no_shell"

usage() {
  cat <<EOF
Usage:
  sudo $0 init-compose [--4gpu|--8gpu]
  sudo $0 create TEAM_NAME --gpu N [--port P] [--uid U] [--gid G] [--keys FILE] [--sudo MODE]
  sudo $0 add-key TEAM_NAME [--keys FILE] [--key "ssh-ed25519 AAAA... comment"]
  sudo $0 fix-perms TEAM_NAME
  sudo $0 audit
  sudo $0 reset TEAM_NAME
  sudo $0 remove TEAM_NAME
  sudo $0 list

Sudo MODE: full | full_no_shell | apt_only | none

Notes:
  - init-compose --4gpu writes ${GPU_MODE_FILE}=4 (valid GPUs: 0..3)
  - init-compose --8gpu writes ${GPU_MODE_FILE}=8 (valid GPUs: 0..7)
  - compose GPU allocation uses deploy.resources.reservations.devices
  - SSH key dir perms auto-fixed so sshd (running as team UID/GID) can read /ssh-keys/authorized_keys
  - Security blocks (cap_drop/cap_add/security_opt) are intentionally NOT generated (SSH stability first)
EOF
}

die(){ echo "ERROR: $*" >&2; exit 1; }
warn(){ echo "WARN: $*" >&2; }
info(){ echo "INFO: $*" >&2; }

require_root(){ [[ "$(id -u)" -eq 0 ]] || die "Run as root (sudo)."; }
ensure_dirs(){ mkdir -p "${BASE_DIR}" "${TEAMS_DIR}" "${SSH_DIR}"; }
need_compose(){ [[ -f "${COMPOSE_FILE}" ]] || die "Missing ${COMPOSE_FILE}. Run: sudo $0 init-compose --4gpu|--8gpu"; }

compose_header(){ echo "services:"; }

read_gpu_mode() {
  if [[ -f "${GPU_MODE_FILE}" ]]; then
    local m
    m="$(tr -d '[:space:]' < "${GPU_MODE_FILE}" || true)"
    if [[ "${m}" == "4" || "${m}" == "8" ]]; then
      echo "${m}"
      return 0
    fi
  fi
  echo "8"
}

validate_gpu_index() {
  local gpu="$1"
  local mode
  mode="$(read_gpu_mode)"
  local max=$((mode - 1))
  if (( gpu < 0 || gpu > max )); then
    die "GPU index ${gpu} is invalid for ${mode}-GPU mode (allowed: 0..${max})."
  fi
}

calc_default_num(){
  local team="$1"
  local num
  num="$(echo "${team}" | grep -oE '[0-9]+' | tail -n1 || true)"
  [[ -n "${num}" ]] || die "TEAM_NAME should include a number (e.g., team01) or pass --port/--uid/--gid explicitly."
  echo "${num}"
}
calc_default_port(){ local n; n="$(calc_default_num "$1")"; echo $((PORT_BASE + 10#${n})); }
calc_default_uid(){  local n; n="$(calc_default_num "$1")"; echo $((UID_BASE + 10#${n})); }
calc_default_gid(){  local n; n="$(calc_default_num "$1")"; echo $((GID_BASE + 10#${n})); }

compose_has_team(){ grep -qE "^  ${1}:" "${COMPOSE_FILE}"; }

compose_gpu_in_use(){
  local gpu="$1"
  grep -qE "device_ids:\s*\[\"${gpu}\"\]" "${COMPOSE_FILE}"
}

compose_port_in_use(){ grep -qE "\"${1}:22\"" "${COMPOSE_FILE}"; }

compose_find_team_by_gpu(){
  local gpu="$1"
  awk -v target="device_ids: [\"${gpu}\"]" '
    BEGIN{team=""}
    /^  [A-Za-z0-9._-]+:$/ {team=$1; sub(":", "", team)}
    index($0, target)>0 {print team; exit}
  ' "${COMPOSE_FILE}"
}

compose_find_team_by_port(){
  local port="$1"
  awk -v p="\"${port}:22\"" '
    BEGIN{team=""}
    /^  [A-Za-z0-9._-]+:$/ {team=$1; sub(":", "", team)}
    index($0, p)>0 {print team; exit}
  ' "${COMPOSE_FILE}"
}

list_teams_from_compose(){
  grep -E "^  [A-Za-z0-9._-]+:" "${COMPOSE_FILE}" | sed 's/:$//' | sed 's/^  //' || true
}

get_team_env_from_compose(){
  local team="$1"
  compose_has_team "${team}" || die "Team not found in compose: ${team}"

  # output: UID GID PORT GPU
  local uid="" gid="" port="" gpu=""

  uid="$(awk -v team="  ${team}:" '
    BEGIN{blk=0}
    $0 ~ "^"team"$" {blk=1; next}
    blk==1 && $0 ~ "^  [A-Za-z0-9._-]+:" {blk=0}
    blk==1 && $0 ~ "PUID:" {gsub(/"/,"",$2); print $2; exit}
  ' "${COMPOSE_FILE}")"

  gid="$(awk -v team="  ${team}:" '
    BEGIN{blk=0}
    $0 ~ "^"team"$" {blk=1; next}
    blk==1 && $0 ~ "^  [A-Za-z0-9._-]+:" {blk=0}
    blk==1 && $0 ~ "PGID:" {gsub(/"/,"",$2); print $2; exit}
  ' "${COMPOSE_FILE}")"

  port="$(awk -v team="  ${team}:" '
    BEGIN{blk=0}
    $0 ~ "^"team"$" {blk=1; next}
    blk==1 && $0 ~ "^  [A-Za-z0-9._-]+:" {blk=0}
    blk==1 && $0 ~ "- \"[0-9]+:22\"" {
      s=$0
      sub(/.*- "/,"",s)      # 앞부분 제거
      sub(/:22".*/,"",s)     # :22" 이후 제거
      print s
      exit
    }
  ' "${COMPOSE_FILE}")"

  gpu="$(awk -v team="  ${team}:" '
    BEGIN{blk=0}
    $0 ~ "^"team"$" {blk=1; next}
    blk==1 && $0 ~ "^  [A-Za-z0-9._-]+:" {blk=0}
    blk==1 && $0 ~ "device_ids:" {
      s=$0
      sub(/.*\["/,"",s)      # 앞부분 제거
      sub(/"\].*/,"",s)      # "\] 이후 제거
      print s
      exit
    }
  ' "${COMPOSE_FILE}")"

  echo "${uid:-} ${gid:-} ${port:-} ${gpu:-}"
}

sudo_env_lines(){
  local mode="$1"
  case "${mode}" in
    full)          echo '      ALLOW_SUDO: "true"'; echo '      SUDO_POLICY: "full"';;
    full_no_shell) echo '      ALLOW_SUDO: "true"'; echo '      SUDO_POLICY: "full_no_shell"';;
    apt_only)      echo '      ALLOW_SUDO: "true"'; echo '      SUDO_POLICY: "apt_only"';;
    none)          echo '      ALLOW_SUDO: "false"';;
    *) die "Unknown sudo mode: ${mode}";;
  esac
}

# --- Compose service block (NO cap_drop/cap_add/security_opt) ---
service_block(){
  local team="$1" gpu="$2" port="$3" uid="$4" gid="$5" sudo_mode="$6"
  cat <<EOF

  ${team}:
    image: ${IMAGE}
    container_name: ${team}_gpu${gpu}
    restart: unless-stopped

    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              device_ids: ["${gpu}"]
              capabilities: ["gpu"]

    ports:
      - "${port}:22"
    volumes:
      - ${TEAMS_DIR}/${team}:/workspace
      - ${SSH_DIR}/${team}:/ssh-keys:ro
    environment:
      USER_NAME: ${team}
      PUID: "${uid}"
      PGID: "${gid}"
$(sudo_env_lines "${sudo_mode}")
    shm_size: "${SHM_SIZE}"
    ipc: ${IPC_MODE}
    ulimits:
      memlock: -1
      stack: 67108864
EOF
}

compose_append_team(){
  compose_has_team "$1" && die "Team '$1' already exists in compose."
  service_block "$@" >> "${COMPOSE_FILE}"
}

compose_remove_team(){
  local team="$1"
  compose_has_team "${team}" || die "Team '${team}' not found in compose."
  awk -v team="  ${team}:" '
    BEGIN{del=0}
    $0 ~ "^"team"$" {del=1; next}
    del==1 && $0 ~ "^  [A-Za-z0-9._-]+:" {del=0}
    del==0 {print}
  ' "${COMPOSE_FILE}" > "${COMPOSE_FILE}.tmp" && mv "${COMPOSE_FILE}.tmp" "${COMPOSE_FILE}"
}

# --- Key perms fix: allow team(GID) to traverse dir + read file ---
fix_key_perms(){
  local team="$1" gid="$2"
  [[ -n "${gid}" ]] || die "fix_key_perms: gid is empty"

  mkdir -p "${SSH_DIR}/${team}"
  touch "${SSH_DIR}/${team}/authorized_keys"

  # Directory: root:<gid>, 750 so team-group can traverse + read file, others blocked
  chown root:"${gid}" "${SSH_DIR}/${team}" 2>/dev/null || true
  chmod 750 "${SSH_DIR}/${team}" 2>/dev/null || true

  # File: root:<gid>, 640 so team-group can read, others blocked
  chown root:"${gid}" "${SSH_DIR}/${team}/authorized_keys" 2>/dev/null || true
  chmod 640 "${SSH_DIR}/${team}/authorized_keys" 2>/dev/null || true
}

ensure_key_dir(){
  local team="$1" gid="$2"
  fix_key_perms "${team}" "${gid}"
}

append_keys_file(){
  local team="$1" gid="$2" keys_src="$3"
  [[ -f "${keys_src}" ]] || die "--keys file not found: ${keys_src}"
  ensure_key_dir "${team}" "${gid}"

  cat "${keys_src}" >> "${SSH_DIR}/${team}/authorized_keys"
  sort -u "${SSH_DIR}/${team}/authorized_keys" -o "${SSH_DIR}/${team}/authorized_keys" || true

  fix_key_perms "${team}" "${gid}"
  echo "Added keys from ${keys_src}"
}

append_key_line(){
  local team="$1" gid="$2" keyline="$3"
  [[ "${keyline}" =~ ^ssh-(rsa|ed25519|ecdsa) ]] || die "--key must start with ssh-ed25519/ssh-rsa/ssh-ecdsa"
  ensure_key_dir "${team}" "${gid}"

  echo "${keyline}" >> "${SSH_DIR}/${team}/authorized_keys"
  sort -u "${SSH_DIR}/${team}/authorized_keys" -o "${SSH_DIR}/${team}/authorized_keys" || true

  fix_key_perms "${team}" "${gid}"
  echo "Added one key line"
}

prepare_team_storage(){
  local team="$1" uid="$2" gid="$3"
  mkdir -p "${TEAMS_DIR}/${team}"
  chown -R "${uid}:${gid}" "${TEAMS_DIR}/${team}" 2>/dev/null || true
  chmod 2770 "${TEAMS_DIR}/${team}" 2>/dev/null || true
}

cmd_init_compose(){
  ensure_dirs
  local mode="${1:-}"
  case "${mode}" in
    --4gpu) echo "4" > "${GPU_MODE_FILE}" ;;
    --8gpu) echo "8" > "${GPU_MODE_FILE}" ;;
    "" )    echo "8" > "${GPU_MODE_FILE}" ;;
    * ) die "Unknown option for init-compose: ${mode} (use --4gpu|--8gpu)" ;;
  esac

  if [[ -f "${COMPOSE_FILE}" ]]; then
    echo "Compose already exists: ${COMPOSE_FILE}"
    echo "GPU mode set to $(cat "${GPU_MODE_FILE}") (file: ${GPU_MODE_FILE})"
    exit 0
  fi

  compose_header > "${COMPOSE_FILE}"
  echo "Created ${COMPOSE_FILE}"
  echo "GPU mode set to $(cat "${GPU_MODE_FILE}") (file: ${GPU_MODE_FILE})"
}

cmd_list(){
  need_compose
  echo "GPU mode: $(read_gpu_mode) (from ${GPU_MODE_FILE})"
  echo "Compose: ${COMPOSE_FILE}"
  list_teams_from_compose | sed 's/^/- /' || true
}

cmd_fix_perms(){
  need_compose
  local team="${1:-}"
  [[ -n "${team}" ]] || die "TEAM_NAME required."
  compose_has_team "${team}" || die "Team not found in compose: ${team}"

  local uid gid port gpu
  read -r uid gid port gpu < <(get_team_env_from_compose "${team}")

  [[ -n "${gid}" ]] || die "Cannot determine PGID for ${team} in compose."
  fix_key_perms "${team}" "${gid}"
  info "Fixed perms: ${SSH_DIR}/${team} (root:${gid}, 750) and authorized_keys (root:${gid}, 640)"
}

cmd_audit(){
  need_compose
  local mode
  mode="$(read_gpu_mode)"
  echo "== teamctl audit =="
  echo "- GPU mode: ${mode} (file: ${GPU_MODE_FILE})"
  echo "- Compose: ${COMPOSE_FILE}"
  echo ""

  local teams
  teams="$(list_teams_from_compose)"
  [[ -n "${teams}" ]] || { echo "No services found."; exit 0; }

  echo "TEAM   GPU  PORT   UID    GID    SSH_DIR_OK  AK_OK  NOTES"
  echo "-----  ---  -----  -----  -----  ----------  -----  -----"

  local used_ports used_gpus
  used_ports="$(mktemp -t teamctl_ports.XXXXXX)"
  used_gpus="$(mktemp -t teamctl_gpus.XXXXXX)"
  # bash -u 안전: 변수가 항상 세팅된 뒤에 trap 등록
  trap 'rm -f "'"${used_ports}"'" "'"${used_gpus}"'"' EXIT

  while read -r t; do
    [[ -n "${t}" ]] || continue
    local uid gid port gpu
    read -r uid gid port gpu < <(get_team_env_from_compose "${t}")

    local ssh_dir="${SSH_DIR}/${t}"
    local ak="${SSH_DIR}/${t}/authorized_keys"

    local ssh_ok="NO" ak_ok="NO" notes=""

    # validate gpu in range
    if [[ -n "${gpu}" ]]; then
      local max=$((mode - 1))
      if (( gpu < 0 || gpu > max )); then
        notes+="GPU_OUT_OF_RANGE "
      fi
      if grep -qx "${gpu}" "${used_gpus}"; then
        notes+="GPU_DUP "
      else
        echo "${gpu}" >> "${used_gpus}"
      fi
    else
      notes+="GPU_MISSING "
    fi

    # port duplication
    if [[ -n "${port}" ]]; then
      if grep -qx "${port}" "${used_ports}"; then
        notes+="PORT_DUP "
      else
        echo "${port}" >> "${used_ports}"
      fi
    else
      notes+="PORT_MISSING "
    fi

    # dirs/files exist
    if [[ -d "${ssh_dir}" ]]; then ssh_ok="YES"; else notes+="SSH_DIR_MISSING "; fi
    if [[ -f "${ak}" ]]; then ak_ok="YES"; else notes+="AK_MISSING "; fi

    # perms check (best effort)
    if [[ -d "${ssh_dir}" && -f "${ak}" && -n "${gid}" ]]; then
      local dperm fperm downer fowner
      dperm="$(stat -c "%a" "${ssh_dir}" 2>/dev/null || echo "?")"
      fperm="$(stat -c "%a" "${ak}" 2>/dev/null || echo "?")"
      downer="$(stat -c "%u:%g" "${ssh_dir}" 2>/dev/null || echo "?")"
      fowner="$(stat -c "%u:%g" "${ak}" 2>/dev/null || echo "?")"

      # expected: dir 750 root:<gid>, file 640 root:<gid>
      if [[ "${dperm}" != "750" ]]; then notes+="SSH_DIR_PERM(${dperm}) "; fi
      if [[ "${fperm}" != "640" ]]; then notes+="AK_PERM(${fperm}) "; fi
      if [[ "${downer}" != "root:${gid}" ]]; then notes+="SSH_DIR_OWNER(${downer}) "; fi
      if [[ "${fowner}" != "root:${gid}" ]]; then notes+="AK_OWNER(${fowner}) "; fi
    fi

    printf "%-6s %-3s %-5s %-5s %-5s %-10s %-5s %s\n" \
      "${t}" "${gpu:-?}" "${port:-?}" "${uid:-?}" "${gid:-?}" "${ssh_ok}" "${ak_ok}" "${notes}"
  done <<< "${teams}"

  echo ""
  echo "Tips:"
  echo "- To fix perms for a team: sudo $0 fix-perms TEAM_NAME"
  echo "- After permission changes, sshd usually doesn't need restart, but container restart is OK if needed."
}

cmd_create(){
  need_compose

  local team="${1:-}"; shift || true
  [[ -n "${team}" ]] || die "TEAM_NAME required."

  local gpu="" port="" uid="" gid="" keys="" sudo_mode="${DEFAULT_SUDO_MODE}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --gpu) gpu="${2:-}"; shift 2;;
      --port) port="${2:-}"; shift 2;;
      --uid) uid="${2:-}"; shift 2;;
      --gid) gid="${2:-}"; shift 2;;
      --keys) keys="${2:-}"; shift 2;;
      --sudo) sudo_mode="${2:-}"; shift 2;;
      *) die "Unknown arg: $1";;
    esac
  done

  [[ -n "${gpu}" ]] || die "--gpu N required."
  [[ "${gpu}" =~ ^[0-9]+$ ]] || die "--gpu must be number."
  validate_gpu_index "${gpu}"

  case "${sudo_mode}" in full|full_no_shell|apt_only|none) : ;; *) die "Invalid --sudo ${sudo_mode}";; esac

  [[ -n "${port}" ]] || port="$(calc_default_port "${team}")"
  [[ -n "${uid}"  ]] || uid="$(calc_default_uid "${team}")"
  [[ -n "${gid}"  ]] || gid="$(calc_default_gid "${team}")"

  if compose_gpu_in_use "${gpu}"; then
    die "GPU ${gpu} already used by '$(compose_find_team_by_gpu "${gpu}")'"
  fi
  if compose_port_in_use "${port}"; then
    die "Port ${port} already used by '$(compose_find_team_by_port "${port}")'"
  fi

  ensure_dirs
  prepare_team_storage "${team}" "${uid}" "${gid}"

  if [[ -n "${keys}" ]]; then
    append_keys_file "${team}" "${gid}" "${keys}"
  else
    ensure_key_dir "${team}" "${gid}"
    echo "authorized_keys created: ${SSH_DIR}/${team}/authorized_keys"
  fi

  compose_append_team "${team}" "${gpu}" "${port}" "${uid}" "${gid}" "${sudo_mode}"
  echo "Added ${team} (GPU=${gpu}, PORT=${port}, UID/GID=${uid}/${gid}, SUDO=${sudo_mode})"
  echo "Start: sudo docker compose -f ${COMPOSE_FILE} up -d ${team}"
}

cmd_add_key(){
  need_compose
  local team="${1:-}"; shift || true
  [[ -n "${team}" ]] || die "TEAM_NAME required."
  compose_has_team "${team}" || die "Team not found in compose: ${team}"

  local keys_file="" key_line=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --keys) keys_file="${2:-}"; shift 2;;
      --key) key_line="${2:-}"; shift 2;;
      *) die "Unknown arg: $1";;
    esac
  done
  [[ -n "${keys_file}" || -n "${key_line}" ]] || die "Provide --keys FILE or --key 'ssh-ed25519 ...'"

  local uid gid port gpu
  read -r uid gid port gpu < <(get_team_env_from_compose "${team}")
  [[ -n "${gid}" ]] || die "Could not find PGID for ${team} in compose."

  [[ -n "${keys_file}" ]] && append_keys_file "${team}" "${gid}" "${keys_file}"
  [[ -n "${key_line}" ]] && append_key_line "${team}" "${gid}" "${key_line}"

  echo "Done."
}

cmd_reset(){
  need_compose
  local team="${1:-}"; shift || true
  [[ -n "${team}" ]] || die "TEAM_NAME required."
  compose_has_team "${team}" || die "Team not found: ${team}"
  docker compose -f "${COMPOSE_FILE}" rm -s -f "${team}" >/dev/null 2>&1 || true
  docker compose -f "${COMPOSE_FILE}" up -d "${team}"
  docker compose -f "${COMPOSE_FILE}" ps "${team}"
}

cmd_remove(){
  need_compose
  local team="${1:-}"; shift || true
  [[ -n "${team}" ]] || die "TEAM_NAME required."
  compose_has_team "${team}" || die "Team not found: ${team}"
  docker compose -f "${COMPOSE_FILE}" rm -s -f "${team}" >/dev/null 2>&1 || true
  compose_remove_team "${team}"
  echo "Removed ${team} from compose. (Data remains: ${TEAMS_DIR}/${team}, ${SSH_DIR}/${team})"
}

require_root
cmd="${1:-}"; shift || true
case "${cmd}" in
  init-compose) cmd_init_compose "${1:-}";;
  list) cmd_list;;
  create) cmd_create "$@";;
  add-key) cmd_add_key "$@";;
  fix-perms) cmd_fix_perms "$@";;
  audit) cmd_audit;;
  reset) cmd_reset "$@";;
  remove) cmd_remove "$@";;
  *) usage; exit 1;;
esac