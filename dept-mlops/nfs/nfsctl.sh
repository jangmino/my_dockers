#!/usr/bin/env bash
set -euo pipefail

NFS_ROOT="/nfs"
TEAMS_DIR="/nfs/teams"
PROJECTS_FILE="/etc/projects"
PROJID_FILE="/etc/projid"

log(){ echo "$@"; }
die(){ echo "ERROR: $*" >&2; exit 1; }

# team -> projid 기본 규칙: team01 => 12001, team02 => 12002 ...
default_projid_for_team() {
  local team="$1"
  if [[ "$team" =~ ^team([0-9]+)$ ]]; then
    local n="${BASH_REMATCH[1]}"
    printf "12%03d\n" "$((10#$n))"
  else
    die "Team name must be like team01, team02 ..."
  fi
}

need_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Run as root (sudo)."
}

ensure_mount() {
  mountpoint -q "${NFS_ROOT}" || die "${NFS_ROOT} is not a mountpoint. Is /nfs mounted?"
}

ensure_quota_on() {
  local st
  st="$(xfs_quota -x -c "state" "${NFS_ROOT}" 2>/dev/null || true)"

  if echo "$st" | grep -qi "^Project quota state"; then
    echo "$st" | grep -qi "Accounting:[[:space:]]*ON" || die "Project quota accounting is OFF on ${NFS_ROOT}."
    echo "$st" | grep -qi "Enforcement:[[:space:]]*ON" || die "Project quota enforcement is OFF on ${NFS_ROOT}."
    return 0
  fi

  if echo "$st" | grep -qi "Accounting:[[:space:]]*ON" && echo "$st" | grep -qi "Enforcement:[[:space:]]*ON"; then
    return 0
  fi

  die "Project quota not enabled on ${NFS_ROOT}. Check /etc/fstab prjquota + remount."
}

ensure_files() {
  touch "${PROJECTS_FILE}" "${PROJID_FILE}"
}

ensure_dirs() {
  mkdir -p "${TEAMS_DIR}"
}

projid_for_team_from_file() {
  # returns projid if exists, else empty
  local team="$1"
  awk -F: -v t="$team" '$1==t {print $2; exit}' "${PROJID_FILE}" 2>/dev/null || true
}

project_path_for_projid_from_file() {
  local projid="$1"
  awk -F: -v id="$projid" '$1==id {print $2; exit}' "${PROJECTS_FILE}" 2>/dev/null || true
}

add_mapping_strict() {
  # Enforce: team -> projid, projid -> path must match what we expect.
  local team="$1" projid="$2" path="$3"

  local cur_projid cur_path

  cur_projid="$(projid_for_team_from_file "${team}")"
  if [[ -n "${cur_projid}" && "${cur_projid}" != "${projid}" ]]; then
    die "PROJID mismatch for ${team}: file has ${cur_projid}, expected ${projid}"
  fi

  cur_path="$(project_path_for_projid_from_file "${projid}")"
  if [[ -n "${cur_path}" && "${cur_path}" != "${path}" ]]; then
    die "PROJECTS mismatch for projid ${projid}: file has ${cur_path}, expected ${path}"
  fi

  if [[ -z "${cur_projid}" ]]; then
    echo "${team}:${projid}" >> "${PROJID_FILE}"
  fi
  if [[ -z "${cur_path}" ]]; then
    echo "${projid}:${path}" >> "${PROJECTS_FILE}"
  fi
}

human_bytes_from_kb() {
  local kb="${1:-0}"
  awk -v kb="${kb}" 'BEGIN{
    gib = kb/1024/1024;
    tib = gib/1024;
    if (tib >= 1) printf "%.2f TiB", tib;
    else if (gib >= 1) printf "%.2f GiB", gib;
    else printf "%d KiB", kb;
  }'
}

quota_line_for_projid() {
  local projid="$1"
  xfs_quota -x -c "report -p -n" "${NFS_ROOT}" 2>/dev/null | awk -v id="#${projid}" '$1==id{print; found=1} END{if(!found) exit 2}'
}

quota_get_for_projid_kb() {
  local projid="$1"
  local rep used_kb soft_kb hard_kb
  rep="$(xfs_quota -x -c "report -p -n" "${NFS_ROOT}" 2>/dev/null || true)"
  read -r used_kb soft_kb hard_kb <<<"$(awk -v id="#${projid}" '
    $1==id {print $2, $3, $4; found=1}
    END { if(!found) print "0 0 0" }
  ' <<<"${rep}")"
  echo "${used_kb} ${soft_kb} ${hard_kb}"
}

cmd_init() {
  need_root
  ensure_mount
  ensure_dirs
  ensure_files
  ensure_quota_on
  echo "OK: ${NFS_ROOT} mounted with prjquota, teams dir = ${TEAMS_DIR}"
}

cmd_create() {
  need_root
  ensure_mount
  ensure_dirs
  ensure_files
  ensure_quota_on

  local team="${1:-}"; shift || true
  [[ -n "$team" ]] || die "Usage: $0 create TEAM --uid 12001 --gid 12001 --soft 950G --hard 1000G"

  local uid="" gid="" soft="950G" hard="1000G"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --uid) uid="${2:-}"; shift 2;;
      --gid) gid="${2:-}"; shift 2;;
      --soft) soft="${2:-}"; shift 2;;
      --hard) hard="${2:-}"; shift 2;;
      *) die "Unknown arg: $1";;
    esac
  done

  [[ "$uid" =~ ^[0-9]+$ ]] || die "--uid numeric required"
  [[ "$gid" =~ ^[0-9]+$ ]] || die "--gid numeric required"

  local projid path
  projid="$(default_projid_for_team "$team")"
  path="${TEAMS_DIR}/${team}"

  mkdir -p "$path"
  chown "${uid}:${gid}" "$path"
  chmod 2770 "$path"

  add_mapping_strict "$team" "$projid" "$path"

  # Apply project mapping
  xfs_quota -x -c "project -s ${team}" "${NFS_ROOT}" >/dev/null

  # Apply quota to PROJECT NAME (=team)
  xfs_quota -x -c "limit -p bsoft=${soft} bhard=${hard} ${team}" "${NFS_ROOT}" >/dev/null

  echo "Created ${team}"
  echo "- path: ${path}"
  echo "- uid:gid = ${uid}:${gid}"
  echo "- quota: soft=${soft}, hard=${hard}"
  echo "- projid: ${projid}"
}

cmd_resize() {
  need_root
  ensure_mount
  ensure_files
  ensure_quota_on

  local team="${1:-}"; shift || true
  [[ -n "${team}" ]] || die "TEAM_NAME required."
  [[ "${team}" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid team name."

  local soft="" hard=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --soft) soft="${2:-}"; shift 2;;
      --hard) hard="${2:-}"; shift 2;;
      *) die "Unknown arg: $1";;
    esac
  done
  [[ -n "${soft}" && -n "${hard}" ]] || die "Usage: resize TEAM --soft 950G --hard 1000G"

  local dir projid
  dir="${TEAMS_DIR}/${team}"
  [[ -d "${dir}" ]] || die "Team dir not found: ${dir}"

  # ensure mapping consistency (if missing, add it using rule)
  projid="$(default_projid_for_team "${team}")"
  add_mapping_strict "${team}" "${projid}" "${dir}"
  xfs_quota -x -c "project -s ${team}" "${NFS_ROOT}" >/dev/null

  # IMPORTANT: limit applies to project NAME (=team)
  xfs_quota -x -c "limit -p bsoft=${soft} bhard=${hard} ${team}" "${NFS_ROOT}" >/dev/null

  echo "Resized ${team}: soft=${soft}, hard=${hard}"
  cmd_who "${team}"
}

cmd_remove() {
  need_root
  ensure_files
  ensure_quota_on

  local team="${1:-}"; shift || true
  [[ -n "${team}" ]] || { echo "Usage: $0 remove TEAM [--purge-dir]"; exit 1; }
  [[ "${team}" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "Invalid team name: ${team}"; exit 1; }

  local purge_dir="false"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --purge-dir) purge_dir="true"; shift 1;;
      *) echo "Unknown arg: $1"; exit 1;;
    esac
  done

  # projid는 기존 규칙 그대로 사용 (team01 -> 12001 ...)
  local projid
  projid="$(default_projid_for_team "${team}")" || {
    echo "Team name must be like team01, team02 ... (for default projid rule)"
    exit 1
  }

  local path="${TEAMS_DIR}/${team}"

  echo "== REMOVE TEAM =="
  echo "team  : ${team}"
  echo "projid: ${projid}"
  echo "path  : ${path}"
  echo

  # 1) quota 해제 (실패해도 계속 진행)
  xfs_quota -x -c "limit -p bsoft=0 bhard=0 ${team}" "${NFS_ROOT}" >/dev/null 2>&1 || true

  # 2) /etc/projid 에서 team 라인 제거
  if [[ -f "${PROJID_FILE}" ]]; then
    cp -a "${PROJID_FILE}" "${PROJID_FILE}.bak.$(date +%Y%m%d_%H%M%S)" || true
    sed -i "/^${team}:/d" "${PROJID_FILE}" || true
  fi

  # 3) /etc/projects 에서 projid 라인 제거
  if [[ -f "${PROJECTS_FILE}" ]]; then
    cp -a "${PROJECTS_FILE}" "${PROJECTS_FILE}.bak.$(date +%Y%m%d_%H%M%S)" || true
    sed -i "/^${projid}:/d" "${PROJECTS_FILE}" || true
  fi

  # 4) 실제 디렉토리 삭제(옵션)
  if [[ "${purge_dir}" == "true" ]]; then
    if [[ -d "${path}" ]]; then
      rm -rf "${path}"
      echo "Deleted dir: ${path}"
    else
      echo "Dir not found (skip): ${path}"
    fi
  else
    echo "Dir preserved (use --purge-dir to delete): ${path}"
  fi

  echo
  echo "Done."
  echo "Tip: $0 who ${team}  (should fail or show 0 quota after removal)"
}

cmd_who() {
  need_root
  ensure_mount
  ensure_files
  ensure_quota_on

  local team="${1:-}"; shift || true
  [[ -n "${team}" ]] || die "TEAM_NAME required."
  [[ "${team}" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid team name."

  local dir projid
  dir="${TEAMS_DIR}/${team}"
  [[ -d "${dir}" ]] || die "Team dir not found: ${dir}"

  projid="$(default_projid_for_team "${team}")"

  # show info
  local uid gid mode
  uid="$(stat -c '%u' "${dir}")"
  gid="$(stat -c '%g' "${dir}")"
  mode="$(stat -c '%a' "${dir}")"

  local used_kb soft_kb hard_kb
  read -r used_kb soft_kb hard_kb <<<"$(quota_get_for_projid_kb "${projid}")"

  echo "== TEAM INFO =="
  echo "team   : ${team}"
  echo "path   : ${dir}"
  echo "uid:gid: ${uid}:${gid}"
  echo "projid : ${projid}  (rule: teamNN -> 12NNN)"
  echo "mode   : ${mode} (expect setgid e.g. 2770)"
  echo "quota  : used=$(human_bytes_from_kb "${used_kb}")  soft=$(human_bytes_from_kb "${soft_kb}")  hard=$(human_bytes_from_kb "${hard_kb}")"
  echo
  echo "Raw quota line:"
  quota_line_for_projid "${projid}" || echo "(no quota line found for #${projid})"
}

cmd_quota() {
  need_root
  ensure_mount
  ensure_quota_on
  xfs_quota -x -c 'report -p -n' "${NFS_ROOT}"
}

cmd_audit() {
  need_root
  ensure_mount
  ensure_quota_on
  ensure_dirs
  ensure_files

  echo "== NFS teams audit =="
  echo "Root: ${NFS_ROOT}"
  echo "Teams: ${TEAMS_DIR}"
  echo

  printf "%-10s %-8s %-8s %-6s %-18s\n" "TEAM" "UID" "GID" "MODE" "QUOTA(used/soft/hard)"
  printf "%-10s %-8s %-8s %-6s %-18s\n" "----------" "--------" "--------" "------" "------------------"

  for d in "${TEAMS_DIR}"/*; do
    [[ -d "$d" ]] || continue
    local team uid gid mode projid used_kb soft_kb hard_kb
    team="$(basename "$d")"
    uid="$(stat -c "%u" "$d")"
    gid="$(stat -c "%g" "$d")"
    mode="$(stat -c "%a" "$d")"

    if [[ "$team" =~ ^team[0-9]+$ ]]; then
      projid="$(default_projid_for_team "$team")"
      read -r used_kb soft_kb hard_kb <<<"$(quota_get_for_projid_kb "${projid}")"
      printf "%-10s %-8s %-8s %-6s %-18s\n" \
        "$team" "$uid" "$gid" "$mode" \
        "$(human_bytes_from_kb "$used_kb")/$(human_bytes_from_kb "$soft_kb")/$(human_bytes_from_kb "$hard_kb")"
    else
      printf "%-10s %-8s %-8s %-6s %-18s\n" "$team" "$uid" "$gid" "$mode" "-"
    fi
  done

  echo
  echo "Quota full report (head):"
  xfs_quota -x -c 'report -p -n' "${NFS_ROOT}" | head -n 60
}

usage() {
  cat <<EOF
Usage:
  $0 init
  $0 create TEAM --uid 12001 --gid 12001 --soft 950G --hard 1000G
  $0 resize TEAM --soft 950G --hard 1000G
  $0 who TEAM
  $0 remove TEAM [--purge-dir]
  $0 quota
  $0 audit

Notes:
  - Team names should be like team01, team02 ... (projid rule: teamNN -> 12NNN)
  - NFS root must be mounted at ${NFS_ROOT} with XFS prjquota
EOF
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    init) cmd_init;;
    create) cmd_create "$@";;
    resize) cmd_resize "$@";;
    remove) cmd_remove "$@";;
    who) cmd_who "$@";;
    quota) cmd_quota;;
    audit) cmd_audit;;
    *) usage; exit 1;;
  esac
}

main "$@"
