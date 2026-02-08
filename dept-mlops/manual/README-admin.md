# 🔧 GPU 서버 팀 운영 가이드 — 관리자용

> VS Code + Remote-SSH + Team Container 환경
>
> 팀 생성, 키 등록, 컨테이너 관리, 쿼터 운영 등 관리 전반을 다룹니다.

---

## 1. 팀별 접속 정보 관리

### 접속 정보 표 템플릿

아래 표를 채워 팀원들에게 공유합니다.

| TEAM | HOST (서버IP/도메인) | PORT | GPU | QUOTA (Soft/Hard) | 비고 |
|------|----------------------|------|-----|--------------------|------|
| team01 | `<서버IP>` | 22021 | 0 | 950G / 1000G | 예시 |
| team02 | `<서버IP>` | 22022 | 1 | 950G / 1000G | |
| team03 | `<서버IP>` | 22023 | 2 | 950G / 1000G | |
| team04 | `<서버IP>` | 22024 | 3 | 950G / 1000G | |

### 표 채우기 — 자동 생성 방법

#### 방법 A) audit 결과 직접 확인

```bash
sudo /opt/mlops/teamctl-xfs.sh audit
```

#### 방법 B) Markdown 표로 변환 (복붙용)

```bash
sudo /opt/mlops/teamctl-xfs.sh audit | awk '
BEGIN {
  print "| TEAM | PORT | GPU | UID | GID | QUOTA(Soft/Hard) |";
  print "|------|------|-----|-----|-----|------------------|";
}
/^[a-zA-Z0-9._-]+[[:space:]]+[0-9]+[[:space:]]+[0-9]+/ {
  team=$1; gpu=$2; port=$3; uid=$4; gid=$5;
  printf("| %s | %s | %s | %s | %s | %s |\n", team, port, gpu, uid, gid, "-");
}'
```

> QUOTA 열이 비어 있습니다. 쿼터까지 필요하면 방법 C를 사용하세요.

#### 방법 C) QUOTA 포함 (권장)

두 명령의 결과를 조합합니다.

```bash
# 1) 팀 구성 (포트/GPU/UID/GID)
sudo /opt/mlops/teamctl-xfs.sh audit

# 2) XFS 쿼터
sudo xfs_quota -x -c 'report -p -n' /data
```

> **운영 규칙:** `팀 = UID = ProjectID`로 운영합니다.
> 예) `team01` → UID `12001` → ProjectID `12001`
> `report -p -n` 출력에서 `#12001` 행이 team01의 쿼터입니다.

#### (선택) md-table 서브커맨드 확장

`teamctl-xfs.sh md-table` 서브커맨드를 추가하면 한 번에 완전한 표를 출력할 수 있습니다.

```bash
sudo /opt/mlops/teamctl-xfs.sh md-table
```

동작: `compose.yaml`에서 team/port/gpu/uid를 읽고, `xfs_quota`에서 soft/hard를 붙여 Markdown 표를 stdout으로 출력.

---

## 2. 팀원 공개키 등록

### 키 문자열로 등록

```bash
sudo /opt/mlops/teamctl-xfs.sh add-key team01 --key "ssh-ed25519 AAAA... team01/jangmin"
```

### pub 파일로 등록

```bash
sudo /opt/mlops/teamctl-xfs.sh add-key team01 --keys /tmp/id_ed25519_team01_jangmin.pub
```

### 등록 확인

```bash
sudo cat /data/ssh/team01/authorized_keys
```

---

## 3. 팀 생성 + 할당량 설정 (XFS project quota)

```bash
sudo /opt/mlops/teamctl-xfs.sh create team01 --gpu 0 --image mlops:latest --size 1000G --soft 950G
```

### 할당량 확인

```bash
sudo xfs_quota -x -c 'report -p -n' /data
```

### 상태 점검

```bash
sudo /opt/mlops/teamctl-xfs.sh audit
```

---

## 4. 컨테이너 상태 확인

```bash
cd /opt/mlops
sudo docker compose -f /opt/mlops/compose.yaml ps
sudo docker logs --tail 200 team01_gpu0
```

---

## 5. 새 이미지로 컨테이너 교체 (롤아웃)

```bash
# 1) 이미지 pull
sudo docker pull <image:tag>

# 2) compose 이미지 갱신
sudo /opt/mlops/teamctl-xfs.sh set-image team01 <image:tag>

# 3) 해당 팀만 재생성
sudo docker compose -f /opt/mlops/compose.yaml up -d --no-deps --force-recreate team01

# 4) 적용 확인
sudo docker inspect -f '{{.Config.Image}}' team01_gpu0
```

---

## 6. SSH host key 영구화 (권장)

컨테이너가 재생성되어도 팀원이 매번 `known_hosts` 경고를 겪지 않도록 합니다.

### 운영 원칙

- 팀별 host key 저장소: `/data/ssh/<team>/hostkeys`
- 컨테이너 마운트: `/etc/ssh/hostkeys`
- entrypoint에서 키가 없으면 생성, sshd가 해당 키를 사용

### 기존 팀 수동 적용

```bash
sudo mkdir -p /data/ssh/team01/hostkeys
sudo chown root:root /data/ssh/team01/hostkeys
sudo chmod 700 /data/ssh/team01/hostkeys
```

---

## 7. Compose 전체 내리기

```bash
cd /opt/mlops
sudo docker compose -f /opt/mlops/compose.yaml down
```

> 모니터링 스택은 `/opt/monitoring` 등 별도 폴더에서 별도로 down합니다.

---

## 8. 장애 체크리스트 (빠른 점검)

### 컨테이너 재시작 루프

```bash
sudo docker ps
sudo docker logs --tail 200 team01_gpu0
```

### authorized_keys 권한/링크

```bash
sudo docker exec -it team01_gpu0 bash -lc \
  'ls -la /home/team01/.ssh && cat /home/team01/.ssh/authorized_keys'
```

### quota 상태

```bash
sudo xfs_quota -x -c 'state' /data
sudo xfs_quota -x -c 'report -p -n' /data
```

### GPU 모니터링

```bash
# 호스트에서 전체 GPU 실시간 확인
watch -n 2 nvidia-smi

# 특정 컨테이너의 GPU 확인
docker exec <container_name> nvidia-smi
```

---

## 9. 일상 운영 체크리스트

### 일일 점검

- [ ] `nvidia-smi`로 전체 GPU 상태 확인 (호스트)
- [ ] `docker ps`로 각 컨테이너 정상 가동 확인
- [ ] 디스크 쿼터 초과 팀 유무 점검

### 주간 점검

- [ ] `teamctl-xfs.sh audit` 실행하여 팀 설정 무결성 확인
- [ ] XFS 쿼터 리포트 확인 및 이상 팀 알림
- [ ] 미사용 컨테이너 / 좀비 프로세스 정리
