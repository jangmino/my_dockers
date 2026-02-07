#!/usr/bin/env bash
set -euo pipefail

# =========================
# teamctl-xfs.sh (FINAL)
# - XFS project quota based team workspace management
# - /workspace and /home/<team> share the same quota-controlled volume
# =========================

BASE_DIR="/opt/mlops"
COMPOSE_FILE="${BASE_DIR}/compose.yaml"
GPU_MODE_FILE="${BASE_DIR}/.gpu_mode"

DATA_ROOT="/data"               # must be XFS mounted with prjquota
TEAMS_DIR="${DATA_ROOT}/teams"
SSH_DIR="${DATA_ROOT}/ssh"
SSH_BACKUP_DIR="${DATA_ROOT}/ssh_backups"

PROJECTS_FILE="/etc/projects"
PROJID_FILE="/etc/projid"

DEFAULT_UID_BASE=12000
DEFAULT_PORT_BASE=22020         # team01 -> 22021
DEFAULT_TEAM_HARD="300G"
DEFAULT_TEAM_SOFT="290G"

DEFAULT_IMAGE="mlops:latest"
DEFAULT_SHM_SIZE="16g"
DEFAULT_IPC="host"
DEFAULT_RESTART="unless-stopped"

# security toggles (keep simple; you can harden later)
DEFAULT_ALLOW_SUDO="true"
DEFAULT_SUDO_POLICY="full_no_shell"

log(){ echo "$@"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

need_root(){
  [[ "$(id -u)" -eq 0 ]] || die "Run as root (sudo)."
}

ensure_dirs(){
  mkdir -p "${BASE_DIR}" "${TEAMS_DIR}" "${SSH_DIR}" "${SSH_BACKUP_DIR}"
}

need_compose(){
  [[ -f "${COMPOSE_FILE}" ]] || {
    cat > "${COMPOSE_FILE}" <<'YAML'
services:
YAML
  }
}

# -------------------------
# Helpers: team parsing
# -------------------------
team_num_from_name(){
  # Extract trailing digits; team01 -> 1
  local team="$1"
  local digits
  digits="$(echo "${team}" | sed -n 's/.*\([0-9][0-9]*\)$/\1/p')"
  if [[ -n "${digits}" ]]; then
    echo "$((10#${digits}))"
  else
    echo ""
  fi
}

default_ids_for_team(){
  local team="$1"
  local n
  n="$(team_num_from_name "${team}")"
  [[ -n "${n}" ]] || die "Team name must end with digits (e.g., team01). Got: ${team}"

  local uid gid port
  uid="$((DEFAULT_UID_BASE + n))"
  gid="$((DEFAULT_UID_BASE + n))"
  port="$((DEFAULT_PORT_BASE + n))"
  echo "${uid} ${gid} ${port}"
}

# -------------------------
# GPU mode
# -------------------------
get_gpu_mode(){
  if [[ -f "${GPU_MODE_FILE}" ]]; then
    cat "${GPU_MODE_FILE}"
  else
    echo "4"
  fi
}

set_gpu_mode(){
  local mode="$1"
  [[ "${mode}" == "4" || "${mode}" == "8" ]] || die "GPU mode must be 4 or 8."
  echo "${mode}" > "${GPU_MODE_FILE}"
  log "GPU mode set to ${mode} (file: ${GPU_MODE_FILE})"
}

validate_gpu_id(){
  local gpu="$1"
  [[ "${gpu}" =~ ^[0-9]+$ ]] || die "GPU must be numeric."
  local mode
  mode="$(get_gpu_mode)"
  if [[ "${mode}" == "4" ]]; then
    (( gpu >= 0 && gpu <= 3 )) || die "GPU must be 0..3 in 4-GPU mode."
  else
    (( gpu >= 0 && gpu <= 7 )) || die "GPU must be 0..7 in 8-GPU mode."
  fi
}

# -------------------------
# Compose YAML manipulation (simple + idempotent)
# -------------------------
compose_has_team(){
  local team="$1"
  grep -qE "^[[:space:]]{2}${team}:" "${COMPOSE_FILE}"
}

list_teams_from_compose(){
  # list service names (2-space indent under services:)
  awk '
    /^services:/ {in_services=1; next}
    in_services==1 && /^[ ]{2}[A-Za-z0-9._-]+:/ {
      s=$0; sub(/^  /,"",s); sub(/:.*/,"",s); print s
    }
  ' "${COMPOSE_FILE}"
}

compose_remove_team(){
  local team="$1"
  compose_has_team "${team}" || return 0

  # Remove block starting at "  team:" until next "  <name>:" or EOF
  awk -v team="  "team":" '
    BEGIN{blk=0}
    $0==team {blk=1; next}
    blk==1 && $0 ~ /^  [A-Za-z0-9._-]+:/ {blk=0}
    blk==0 {print}
  ' "${COMPOSE_FILE}" > "${COMPOSE_FILE}.tmp" && mv "${COMPOSE_FILE}.tmp" "${COMPOSE_FILE}"
}

compose_append_team_block(){
  local block="$1"
  printf "\n%s\n" "${block}" >> "${COMPOSE_FILE}"
}

# -------------------------
# Parse env from compose (mawk-safe)
# output: UID GID PORT GPU
# -------------------------
get_team_env_from_compose(){
  local team="$1"
  compose_has_team "${team}" || die "Team not found in compose: ${team}"

  local uid gid port gpu

  uid="$(awk -v team="  ${team}:" '
    BEGIN{blk=0}
    $0==team {blk=1; next}
    blk==1 && $0 ~ /^  [A-Za-z0-9._-]+:/ {blk=0}
    blk==1 && $0 ~ /PUID:/ {s=$0; sub(/.*PUID:[ ]*/,"",s); gsub(/"/,"",s); print s; exit}
  ' "${COMPOSE_FILE}")"

  gid="$(awk -v team="  ${team}:" '
    BEGIN{blk=0}
    $0==team {blk=1; next}
    blk==1 && $0 ~ /^  [A-Za-z0-9._-]+:/ {blk=0}
    blk==1 && $0 ~ /PGID:/ {s=$0; sub(/.*PGID:[ ]*/,"",s); gsub(/"/,"",s); print s; exit}
  ' "${COMPOSE_FILE}")"

  port="$(awk -v team="  ${team}:" '
    BEGIN{blk=0}
    $0==team {blk=1; next}
    blk==1 && $0 ~ /^  [A-Za-z0-9._-]+:/ {blk=0}
    blk==1 && $0 ~ /- "[0-9]+:22"/ {
      s=$0
      sub(/.*- "/,"",s)
      sub(/:22".*/,"",s)
      print s
      exit
    }
  ' "${COMPOSE_FILE}")"

  gpu="$(awk -v team="  ${team}:" '
    BEGIN{blk=0}
    $0==team {blk=1; next}
    blk==1 && $0 ~ /^  [A-Za-z0-9._-]+:/ {blk=0}
    blk==1 && $0 ~ /device_ids:/ {
      s=$0
      sub(/.*\["/,"",s)
      sub(/"\].*/,"",s)
      print s
      exit
    }
  ' "${COMPOSE_FILE}")"

  echo "${uid:-} ${gid:-} ${port:-} ${gpu:-}"
}

# -------------------------
# SSH key directory and perms
# -------------------------
ensure_team_ssh_dir(){
  local team="$1" gid="$2"
  local d="${SSH_DIR}/${team}"
  mkdir -p "${d}"
  touch "${d}/authorized_keys"
  fix_team_ssh_perms "${team}" "${gid}"
}

ensure_team_hostkeys_dir() {
  local team="${1:?team required}"
  local hk_dir="${SSH_DIR}/${team}/hostkeys"

  mkdir -p "${hk_dir}"

  # ssh host keys는 root만 쓰는 게 정석
  chown root:root "${hk_dir}"
  chmod 700 "${hk_dir}"

  # (선택) authorized_keys는 팀 gid로 쓰는 구조라면 기존 로직 유지
  # hostkeys는 root만 접근하는 게 좋다.
}

fix_team_ssh_perms(){
  local team="$1" gid="$2"
  local d="${SSH_DIR}/${team}"
  local f="${d}/authorized_keys"
  [[ -d "${d}" ]] || die "SSH dir not found: ${d}"

  chown -R root:"${gid}" "${d}" 2>/dev/null || true
  chmod 750 "${d}" 2>/dev/null || true
  [[ -f "${f}" ]] || touch "${f}"
  chown root:"${gid}" "${f}" 2>/dev/null || true
  chmod 640 "${f}" 2>/dev/null || true
}

add_key(){
  local team="$1" key="$2" gid="$3"
  ensure_team_ssh_dir "${team}" "${gid}"

  local f="${SSH_DIR}/${team}/authorized_keys"

  if grep -qF "${key}" "${f}" 2>/dev/null; then
    log "Key already present for ${team}."
  else
    echo "${key}" >> "${f}"
    log "Key added for ${team}."
  fi

  fix_team_ssh_perms "${team}" "${gid}"
}

backup_keys(){
  local team="$1" out_dir="${2:-${SSH_BACKUP_DIR}}"
  local src="${SSH_DIR}/${team}/authorized_keys"
  [[ -f "${src}" ]] || die "authorized_keys not found: ${src}"
  mkdir -p "${out_dir}"
  local ts dest
  ts="$(date +%Y%m%d_%H%M%S)"
  dest="${out_dir}/${team}_authorized_keys_${ts}.bak"
  cp -a "${src}" "${dest}"
  chmod 600 "${dest}" 2>/dev/null || true
  log "Backed up: ${src} -> ${dest}"
}

# -------------------------
# XFS project quota
# -------------------------
ensure_xfs_prjquota(){
  command -v xfs_quota >/dev/null 2>&1 || die "xfs_quota not found. Install xfsprogs."
  [[ -d "${DATA_ROOT}" ]] || die "${DATA_ROOT} not found."
  mountpoint -q "${DATA_ROOT}" || die "${DATA_ROOT} is not a mountpoint. Mount XFS disk to ${DATA_ROOT} first."

  local fstype
  fstype="$(stat -f -c %T "${DATA_ROOT}")"
  [[ "${fstype}" == "xfs" ]] || die "${DATA_ROOT} is not XFS (stat reports ${fstype})."

  xfs_quota -x -c "state" "${DATA_ROOT}" >/dev/null 2>&1 || die "xfs_quota state failed. Is prjquota enabled on ${DATA_ROOT} mount?"
}

ensure_proj_files(){
  touch "${PROJECTS_FILE}" "${PROJID_FILE}"
}

ensure_project_mapping(){
  local team="$1" projid="$2" path="$3"

  ensure_xfs_prjquota
  ensure_proj_files

  if ! grep -qE "^${team}:" "${PROJID_FILE}"; then
    echo "${team}:${projid}" >> "${PROJID_FILE}"
  else
    local cur
    cur="$(awk -F: -v t="${team}" '$1==t{print $2; exit}' "${PROJID_FILE}" || true)"
    [[ -z "${cur}" || "${cur}" == "${projid}" ]] || die "projid mismatch for ${team} (have ${cur}, want ${projid})"
  fi

  if ! grep -qE "^${projid}:" "${PROJECTS_FILE}"; then
    echo "${projid}:${path}" >> "${PROJECTS_FILE}"
  else
    local curp
    curp="$(awk -F: -v id="${projid}" '$1==id{print $2; exit}' "${PROJECTS_FILE}" || true)"
    [[ -z "${curp}" || "${curp}" == "${path}" ]] || die "project id ${projid} already mapped to ${curp} (want ${path})"
  fi

  xfs_quota -x -c "project -s ${team}" "${DATA_ROOT}" >/dev/null
}

set_team_quota(){
  local team="$1" soft="$2" hard="$3"
  xfs_quota -x -c "limit -p bsoft=${soft} bhard=${hard} ${team}" "${DATA_ROOT}" >/dev/null
}

report_team_quota(){
  local team="$1"
  xfs_quota -x -c "report -p -n" "${DATA_ROOT}" | sed -n "1,3p;/${team}/p"
}

purge_team_xfs_project(){
  local team="$1" gid="$2"
  ensure_proj_files
  xfs_quota -x -c "limit -p bsoft=0 bhard=0 ${team}" "${DATA_ROOT}" >/dev/null 2>&1 || true

  awk -F: -v id="${gid}" '$1!=id{print}' "${PROJECTS_FILE}" > "${PROJECTS_FILE}.tmp" && mv "${PROJECTS_FILE}.tmp" "${PROJECTS_FILE}"
  awk -F: -v t="${team}" '$1!=t{print}' "${PROJID_FILE}" > "${PROJID_FILE}.tmp" && mv "${PROJID_FILE}.tmp" "${PROJID_FILE}"
}

# -------------------------
# Team storage (XFS quota + perms)
# -------------------------
prepare_team_storage(){
  local team="$1" uid="$2" gid="$3"
  local hard="${4:-${DEFAULT_TEAM_HARD}}"
  local soft="${5:-${DEFAULT_TEAM_SOFT}}"

  ensure_xfs_prjquota
  ensure_dirs

  mkdir -p "${TEAMS_DIR}/${team}"
  chown -R "${uid}:${gid}" "${TEAMS_DIR}/${team}" 2>/dev/null || true
  chmod 2770 "${TEAMS_DIR}/${team}" 2>/dev/null || true

  ensure_project_mapping "${team}" "${gid}" "${TEAMS_DIR}/${team}"
  set_team_quota "${team}" "${soft}" "${hard}"
}

# -------------------------
# Compose team block generator
# IMPORTANT: /home/<team> is mapped to the same volume as /workspace
# -------------------------
render_team_block(){
  local team="$1" image="$2" gpu="$3" port="$4" uid="$5" gid="$6"
  local shm="${DEFAULT_SHM_SIZE}"
  local ipc="${DEFAULT_IPC}"

  cat <<YAML
  ${team}:
    image: ${image}
    container_name: ${team}_gpu${gpu}
    restart: ${DEFAULT_RESTART}
    ports:
      - "${port}:22"
    volumes:
      - ${TEAMS_DIR}/${team}:/workspace
      - ${TEAMS_DIR}/${team}:/home/${team}
      - ${SSH_DIR}/${team}:/ssh-keys:ro
      - ${SSH_DIR}/${team}/hostkeys:/etc/ssh/hostkeys:rw
    environment:
      USER_NAME: ${team}
      PUID: "${uid}"
      PGID: "${gid}"
      ALLOW_SUDO: "${DEFAULT_ALLOW_SUDO}"
      SUDO_POLICY: "${DEFAULT_SUDO_POLICY}"
    shm_size: "${shm}"
    ipc: ${ipc}
    ulimits:
      memlock: -1
      stack: 67108864
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              device_ids: ["${gpu}"]
              capabilities: ["gpu"]
YAML
}

# -------------------------
# Commands
# -------------------------
usage(){
  cat <<EOF
Usage: sudo $0 <command> [args...]

Core:
  sudo $0 set-gpu-mode 4|8
  sudo $0 create TEAM_NAME --gpu N [--image IMG] [--port P] [--uid U] [--gid G] [--size 300G] [--soft 290G]
  sudo $0 add-key TEAM_NAME --key "ssh-ed25519 AAAA... team01/user"
  sudo $0 fix-perms TEAM_NAME
  sudo $0 audit
  sudo $0 list-mounts
  sudo $0 backup-keys TEAM_NAME [--out DIR]
  sudo $0 resize TEAM_NAME --size 500G [--soft 490G]
  sudo $0 reset TEAM_NAME
  sudo $0 remove TEAM_NAME [--purge-data]
  sudo $0 set-image TEAM_NAME image:tag

Notes:
- Requires /data to be XFS mounted with prjquota (fstab option: prjquota).
- Compose file is ${COMPOSE_FILE}
- /home/<team> shares the same volume as /workspace (quota applies to both).
EOF
}

cmd_set_gpu_mode(){
  need_root
  ensure_dirs
  local mode="${1:-}"
  [[ -n "${mode}" ]] || die "Provide 4 or 8."
  set_gpu_mode "${mode}"
}

cmd_create(){
  need_root
  ensure_dirs
  need_compose

  local team="${1:-}"; shift || true
  [[ -n "${team}" ]] || die "TEAM_NAME required."
  [[ "${team}" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid team name."

  local gpu="" image="${DEFAULT_IMAGE}" port="" uid="" gid=""
  local size="${DEFAULT_TEAM_HARD}" soft="${DEFAULT_TEAM_SOFT}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --gpu) gpu="${2:-}"; shift 2;;
      --image) image="${2:-}"; shift 2;;
      --port) port="${2:-}"; shift 2;;
      --uid) uid="${2:-}"; shift 2;;
      --gid) gid="${2:-}"; shift 2;;
      --size) size="${2:-}"; shift 2;;
      --soft) soft="${2:-}"; shift 2;;
      *) die "Unknown arg: $1";;
    esac
  done

  [[ -n "${gpu}" ]] || die "--gpu N required."
  validate_gpu_id "${gpu}"

  if compose_has_team "${team}"; then
    die "Team already exists in compose: ${team}"
  fi

  if [[ -z "${uid}" || -z "${gid}" || -z "${port}" ]]; then
    read -r duid dgid dport <<< "$(default_ids_for_team "${team}")"
    uid="${uid:-${duid}}"
    gid="${gid:-${dgid}}"
    port="${port:-${dport}}"
  fi

  [[ "${uid}" =~ ^[0-9]+$ ]] || die "UID must be numeric."
  [[ "${gid}" =~ ^[0-9]+$ ]] || die "GID must be numeric."
  [[ "${port}" =~ ^[0-9]+$ ]] || die "Port must be numeric."

  prepare_team_storage "${team}" "${uid}" "${gid}" "${size}" "${soft}"
  ensure_team_ssh_dir "${team}" "${gid}"
  ensure_team_hostkeys_dir "${team}"

  local block
  block="$(render_team_block "${team}" "${image}" "${gpu}" "${port}" "${uid}" "${gid}")"
  compose_append_team_block "${block}"

  log "Created team ${team}: gpu=${gpu}, port=${port}, uid=${uid}, gid=${gid}, soft=${soft}, hard=${size}"
  log "Workspace: ${TEAMS_DIR}/${team}  (also mounted to /home/${team})"
  log "SSH keys:  ${SSH_DIR}/${team}/authorized_keys"
  log "Next: docker compose -f ${COMPOSE_FILE} up -d ${team}"
}

cmd_add_key(){
  need_root
  ensure_dirs
  need_compose

  local team="${1:-}"; shift || true
  [[ -n "${team}" ]] || die "TEAM_NAME required."
  compose_has_team "${team}" || die "Team not found in compose: ${team}"

  local key=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --key) key="${2:-}"; shift 2;;
      *) die "Unknown arg: $1";;
    esac
  done
  [[ -n "${key}" ]] || die "--key \"ssh-...\" required."

  read -r uid gid port gpu <<< "$(get_team_env_from_compose "${team}")"
  [[ -n "${gid}" ]] || die "Could not determine GID from compose for ${team}"

  add_key "${team}" "${key}" "${gid}"
  log "Done."
}

cmd_fix_perms(){
  need_root
  ensure_dirs
  need_compose
  local team="${1:-}"; shift || true
  [[ -n "${team}" ]] || die "TEAM_NAME required."
  compose_has_team "${team}" || die "Team not found in compose: ${team}"

  read -r uid gid port gpu <<< "$(get_team_env_from_compose "${team}")"
  [[ -n "${gid}" ]] || die "Could not determine GID."

  fix_team_ssh_perms "${team}" "${gid}"
  log "Fixed SSH perms for ${team} (root:${gid}, 750/640)."
}

cmd_backup_keys(){
  need_root
  ensure_dirs
  need_compose
  local team="${1:-}"; shift || true
  [[ -n "${team}" ]] || die "TEAM_NAME required."
  compose_has_team "${team}" || die "Team not found in compose: ${team}"

  local out="${SSH_BACKUP_DIR}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --out) out="${2:-}"; shift 2;;
      *) die "Unknown arg: $1";;
    esac
  done
  backup_keys "${team}" "${out}"
}

cmd_list_mounts(){
  need_root
  ensure_dirs
  need_compose

  log "== teamctl list-mounts =="
  log "- Data root: ${DATA_ROOT}"
  log "- Teams dir: ${TEAMS_DIR}"
  echo ""

  printf "%-10s %-28s %-8s %-8s %-8s %-8s\n" "TEAM" "PATH" "SIZE" "USED" "AVAIL" "USE%"
  printf "%-10s %-28s %-8s %-8s %-8s %-8s\n" "----------" "----------------------------" "--------" "--------" "--------" "--------"

  local teams
  teams="$(list_teams_from_compose || true)"
  if [[ -z "${teams}" ]]; then
    log "No teams found in compose."
    return 0
  fi

  while read -r t; do
    [[ -n "${t}" ]] || continue
    local mnt="${TEAMS_DIR}/${t}"
    if [[ -d "${mnt}" ]]; then
      local line size used avail usep
      line="$(df -h "${mnt}" 2>/dev/null | awk 'NR==2{print $2,$3,$4,$5}' || true)"
      if [[ -n "${line}" ]]; then
        read -r size used avail usep <<< "${line}"
        printf "%-10s %-28s %-8s %-8s %-8s %-8s\n" "${t}" "${mnt}" "${size}" "${used}" "${avail}" "${usep}"
      else
        printf "%-10s %-28s %-8s %-8s %-8s %-8s\n" "${t}" "${mnt}" "-" "-" "-" "-"
      fi
    else
      printf "%-10s %-28s %-8s %-8s %-8s %-8s\n" "${t}" "${mnt}" "MISSING" "-" "-" "-"
    fi
  done <<< "${teams}"
}

cmd_audit(){
  need_root
  ensure_dirs
  need_compose

  log "== teamctl audit =="
  log "- GPU mode: $(get_gpu_mode) (file: ${GPU_MODE_FILE})"
  log "- Compose: ${COMPOSE_FILE}"
  echo ""

  printf "%-8s %-4s %-6s %-6s %-6s %-10s %-6s %-s\n" "TEAM" "GPU" "PORT" "UID" "GID" "SSH_DIR_OK" "AK_OK" "NOTES"
  printf "%-8s %-4s %-6s %-6s %-6s %-10s %-6s %-s\n" "-----" "---" "-----" "-----" "-----" "----------" "-----" "-----"

  local teams
  teams="$(list_teams_from_compose || true)"
  [[ -n "${teams}" ]] || { log "No teams found."; return 0; }

  while read -r team; do
    [[ -n "${team}" ]] || continue
    read -r uid gid port gpu <<< "$(get_team_env_from_compose "${team}")"

    local notes=""
    local ssh_ok="NO" ak_ok="NO"

    local sshd="${SSH_DIR}/${team}"
    local ak="${sshd}/authorized_keys"

    [[ -d "${sshd}" ]] && ssh_ok="YES"
    [[ -f "${ak}" ]] && ak_ok="YES"

    local downer fowner
    downer="$(stat -c "%u:%g" "${sshd}" 2>/dev/null || echo "?")"
    fowner="$(stat -c "%u:%g" "${ak}" 2>/dev/null || echo "?")"

    if [[ "${downer}" != "0:${gid}" ]]; then notes+="SSH_DIR_OWNER(${downer}) "; fi
    if [[ "${fowner}" != "0:${gid}" ]]; then notes+="AK_OWNER(${fowner}) "; fi

    local dperm fperm
    dperm="$(stat -c "%a" "${sshd}" 2>/dev/null || echo "?")"
    fperm="$(stat -c "%a" "${ak}" 2>/dev/null || echo "?")"
    if [[ "${dperm}" != "750" ]]; then notes+="SSH_DIR_PERM(${dperm}) "; fi
    if [[ "${fperm}" != "640" ]]; then notes+="AK_PERM(${fperm}) "; fi

    printf "%-8s %-4s %-6s %-6s %-6s %-10s %-6s %-s\n" \
      "${team}" "${gpu:-?}" "${port:-?}" "${uid:-?}" "${gid:-?}" "${ssh_ok}" "${ak_ok}" "${notes}"
  done <<< "${teams}"

  echo ""
  echo "Tips:"
  echo "- Fix perms: sudo $0 fix-perms TEAM"
  echo "- Show quota: sudo xfs_quota -x -c 'report -p -n' ${DATA_ROOT}"
}

cmd_resize(){
  need_root
  ensure_dirs
  need_compose

  local team="${1:-}"; shift || true
  [[ -n "${team}" ]] || die "TEAM_NAME required."
  compose_has_team "${team}" || die "Team not found in compose: ${team}"

  local size="" soft=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --size) size="${2:-}"; shift 2;;
      --soft) soft="${2:-}"; shift 2;;
      *) die "Unknown arg: $1";;
    esac
  done
  [[ -n "${size}" ]] || die "--size NEW_SIZE required (e.g., 500G)."

  read -r uid gid port gpu <<< "$(get_team_env_from_compose "${team}")"
  [[ -n "${gid}" ]] || die "Could not determine GID."

  ensure_project_mapping "${team}" "${gid}" "${TEAMS_DIR}/${team}"

  if [[ -z "${soft}" ]]; then
    soft="${size}"
    if [[ "${size}" =~ ^([0-9]+)G$ ]]; then
      local n="${BASH_REMATCH[1]}"
      if (( n > 20 )); then soft="$((n-10))G"; fi
    fi
  fi

  set_team_quota "${team}" "${soft}" "${size}"
  log "Quota updated for ${team}: soft=${soft} hard=${size}"
  report_team_quota "${team}"
}

cmd_reset(){
  need_root
  ensure_dirs
  need_compose

  local team="${1:-}"; shift || true
  [[ -n "${team}" ]] || die "TEAM_NAME required."
  compose_has_team "${team}" || die "Team not found in compose: ${team}"

  docker compose -f "${COMPOSE_FILE}" stop "${team}" >/dev/null 2>&1 || true
  docker compose -f "${COMPOSE_FILE}" rm -s -f "${team}" >/dev/null 2>&1 || true
  log "Reset container for ${team}. Data preserved."
  log "Next: docker compose -f ${COMPOSE_FILE} up -d ${team}"
}

cmd_remove(){
  need_root
  ensure_dirs
  need_compose

  local team="${1:-}"; shift || true
  [[ -n "${team}" ]] || die "TEAM_NAME required."
  compose_has_team "${team}" || die "Team not found: ${team}"

  local purge="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --purge-data) purge="true"; shift 1;;
      *) die "Unknown arg: $1";;
    esac
  done

  docker compose -f "${COMPOSE_FILE}" stop "${team}" >/dev/null 2>&1 || true
  docker compose -f "${COMPOSE_FILE}" rm -s -f "${team}" >/dev/null 2>&1 || true

  local uid gid port gpu
  read -r uid gid port gpu <<< "$(get_team_env_from_compose "${team}")"

  compose_remove_team "${team}"
  log "Removed ${team} from compose."

  if [[ "${purge}" == "true" ]]; then
    if [[ -f "${SSH_DIR}/${team}/authorized_keys" ]]; then
      backup_keys "${team}" "${SSH_BACKUP_DIR}" || true
    fi

    if [[ -n "${gid:-}" ]]; then
      purge_team_xfs_project "${team}" "${gid}" || true
    fi

    rm -rf "${TEAMS_DIR:?}/${team}" || true
    rm -rf "${SSH_DIR:?}/${team}" || true
    log "Purged data for ${team}."
  else
    log "Data preserved:"
    log "- workspace: ${TEAMS_DIR}/${team}"
    log "- ssh keys:  ${SSH_DIR}/${team}"
    log "To purge everything: sudo $0 remove ${team} --purge-data"
  fi
}

cmd_set_image() {
  local team="${1:-}"
  local image="${2:-}"
  local compose="${COMPOSE_FILE:-/opt/mlops/compose.yaml}"

  if [[ -z "$team" || -z "$image" ]]; then
    echo "Usage: $0 set-image TEAM image:tag"
    return 2
  fi
  if [[ ! -f "$compose" ]]; then
    echo "ERROR: compose file not found: $compose"
    return 1
  fi

  # Update only the `image:` line inside the target service block:
  # services:
  #   team01:
  #     image: ...
  #   team02:
  #     image: ...
  local tmp
  tmp="$(mktemp)"

  awk -v TEAM="$team" -v NEWIMG="$image" '
    BEGIN { in_services=0; in_team=0; updated=0 }

    # Enter services section
    /^services:[[:space:]]*$/ { in_services=1; print; next }

    # If we are in services, detect service headers at indent=2: "  name:"
    in_services && match($0, /^[[:space:]]{2}([A-Za-z0-9_.-]+):[[:space:]]*$/, m) {
      # leaving previous team block if any
      in_team = (m[1] == TEAM)
      print
      next
    }

    # Replace image line at indent=4 inside target team block
    in_services && in_team && $0 ~ /^[[:space:]]{4}image:[[:space:]]*/ {
      print "    image: " NEWIMG
      updated=1
      next
    }

    { print }

    END {
      if (updated == 0) {
        # exit code 3: team block or image line not found
        exit 3
      }
    }
  ' "$compose" > "$tmp"

  local rc=$?
  if [[ $rc -eq 0 ]]; then
    sudo mv "$tmp" "$compose"
    echo "Updated image for ${team} -> ${image}"
    echo "Next: sudo docker compose -f ${compose} up -d --no-deps --force-recreate ${team}"
    return 0
  elif [[ $rc -eq 3 ]]; then
    rm -f "$tmp"
    echo "ERROR: Could not find service '${team}' or its image line in ${compose}"
    echo "Tip: check that '${team}' exists under 'services:' and has an 'image:' line."
    return 1
  else
    rm -f "$tmp"
    echo "ERROR: Failed to update compose (awk exit $rc)"
    return 1
  fi
}

# -------------------------
# Main
# -------------------------
main(){
  local cmd="${1:-}"
  shift || true

  case "${cmd}" in
    set-gpu-mode) cmd_set_gpu_mode "$@";;
    create) cmd_create "$@";;
    add-key) cmd_add_key "$@";;
    fix-perms) cmd_fix_perms "$@";;
    audit) cmd_audit;;
    list-mounts) cmd_list_mounts;;
    backup-keys) cmd_backup_keys "$@";;
    resize) cmd_resize "$@";;
    reset) cmd_reset "$@";;
    remove) cmd_remove "$@";;
    set-image) cmd_set_image "${1:-}" "${2:-}" ;;
    ""|-h|--help|help) usage;;
    *) die "Unknown command: ${cmd}. Use --help.";;
  esac
}

main "$@"