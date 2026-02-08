# 🛠️ GPU 서버 초기 세팅 매뉴얼

> PRO 6000×4 GPU 서버 기준
>
> 새 딥러닝 머신을 받았을 때 OS 설치 이후 수행하는 전체 초기화 절차입니다.
> 스토리지 서버 세팅은 [README-initialize-storage.md](README-initialize-storage.md)를 참고하세요.

---

## 1. 저장장치 초기화

### 1.1 현재 상태 확인

```bash
lsblk
lsblk -f
```

출력 예시 (nvme0n1이 미초기화 상태):

```
NAME        MAJ:MIN RM  SIZE RO TYPE MOUNTPOINTS
nvme1n1     259:0    0  3.5T  0 disk
├─nvme1n1p1 259:1    0  512M  0 part /boot/efi
└─nvme1n1p2 259:2    0  3.5T  0 part /
nvme0n1     259:3    0    7T  0 disk
```

### 1.2 XFS + /data + prjquota 세팅

#### 파티션 생성

```bash
# GPT 레이블 생성
sudo parted /dev/nvme0n1 --script mklabel gpt

# 파티션 1개 생성 (전체)
sudo parted /dev/nvme0n1 --script mkpart primary 0% 100%

# 파티션 이름 지정
sudo parted /dev/nvme0n1 --script name 1 team-volumes

# 확인
lsblk /dev/nvme0n1
sudo parted /dev/nvme0n1 print
```

#### XFS 포맷

```bash
sudo mkfs.xfs -f /dev/nvme0n1p1
```

#### /data 마운트

```bash
sudo mkdir -p /data
sudo mount /dev/nvme0n1p1 /data
df -h /data
```

#### fstab 등록 (재부팅 시 자동 마운트)

UUID 확인:

```bash
sudo blkid /dev/nvme0n1p1
# 출력 예:
# /dev/nvme0n1p1: UUID="f0ba4b14-d475-4735-972f-1aca05e016f5" BLOCK_SIZE="4096" TYPE="xfs" PARTLABEL="team-volumes" ...
```

`/etc/fstab`에 추가:

```
UUID=<위에서 확인한 UUID>  /data  xfs  defaults,noatime,prjquota  0  0
```

적용:

```bash
sudo mount -a
```

---

## 2. 네트워크 설정

`/etc/netplan/50-cloud-init.yaml` 편집:

```yaml
network:
    ethernets:
        eth0:
            dhcp4: no
            addresses:
              - 210.125.91.95/24
            routes:
              - to: default
                via: 210.125.91.1
            nameservers:
              addresses: [210.125.88.1, 8.8.8.8]
        eth1:
            dhcp4: true
    version: 2
```

적용:

```bash
sudo netplan apply
```

---

## 3. 디렉터리 구조 생성

```bash
sudo mkdir -p /data/teams /data/ssh /data/ssh_backups
```

---

## 4. teamctl-xfs 설치

### 4.1 소스 클론

```bash
cd ~
mkdir -p work && cd work
git clone https://github.com/jangmino/my_dockers
```

### 4.2 스크립트 배포

```bash
sudo mkdir -p /opt/mlops
sudo cp ~/work/my_dockers/dept-mlops/Dockerfile /opt/mlops/
sudo cp ~/work/my_dockers/dept-mlops/docker-entrypoint.sh /opt/mlops/
sudo cp ~/work/my_dockers/dept-mlops/teamctl-xfs.sh /opt/mlops/
sudo chmod +x /opt/mlops/teamctl-xfs.sh
```

---

## 5. Docker 이미지 빌드

```bash
cd ~/work/my_dockers/dept-mlops

# 태그는 날짜 등으로 지정
sudo docker build -t jangminnature/mlops:dept-20260208 .

# 필요시 Docker Hub에 푸시 (위 이미지는 이미 푸시됨)
```

---

## 6. GPU 모드 설정

GPU 장수에 맞게 설정합니다. (4GPU → 4)

```bash
sudo /opt/mlops/teamctl-xfs.sh set-gpu-mode 4
```

---

## 7. NFS 스토리지 연결

> **전제:** 스토리지 서버([README-initialize-storage.md](README-initialize-storage.md))가 이미 세팅되어 NFS export가 동작 중이어야 합니다.

### 7.1 NFS 클라이언트 설치

```bash
sudo apt update
sudo apt install -y nfs-common
```

### 7.2 마운트 포인트 생성 + 마운트

```bash
sudo mkdir -p /mnt/nfs/teams
sudo mount -t nfs4 210.125.91.94:/teams /mnt/nfs/teams
df -h /mnt/nfs/teams
```

### 7.3 fstab 영구 마운트

`/etc/fstab`에 추가:

```
210.125.91.94:/teams  /mnt/nfs/teams  nfs4  nfsvers=4.2,_netdev,hard,intr,timeo=600,retrans=2  0  0
```

적용:

```bash
sudo systemctl daemon-reload
sudo mount -a
```

### 7.4 스토리지 서버 원격 제어용 SSH 키 생성

teamctl-xfs.sh가 스토리지 서버의 nfsctl.sh를 SSH로 호출하기 위한 키입니다.

```bash
sudo mkdir -p /opt/mlops/keys
sudo chmod 700 /opt/mlops/keys

sudo ssh-keygen -t ed25519 -C "teamctl->nfsctl" -f /opt/mlops/keys/nfsctl_ed25519
sudo chmod 600 /opt/mlops/keys/nfsctl_ed25519
sudo chmod 644 /opt/mlops/keys/nfsctl_ed25519.pub
```

공개키 확인 후 스토리지 서버의 `nfsadmin` 계정에 등록합니다. (자세한 절차는 [README-initialize-storage.md](README-initialize-storage.md) 참고)

```bash
sudo cat /opt/mlops/keys/nfsctl_ed25519.pub
```

### 7.5 원격 연결 테스트

```bash
sudo ssh -i /opt/mlops/keys/nfsctl_ed25519 \
  -o BatchMode=yes \
  -o StrictHostKeyChecking=accept-new \
  nfsadmin@210.125.91.94 "sudo /opt/nfs/nfsctl.sh audit"
```

---

## 8. 팀 생성 및 컨테이너 기동

### 8.1 팀 생성 (로컬 + NFS 통합)

```bash
sudo /opt/mlops/teamctl-xfs.sh create team01 \
  --gpu 0 \
  --image jangminnature/mlops:dept-20260208 \
  --size 300G --soft 290G \
  --nfs --nfs-size 2000G --nfs-soft 1950G
```

### 8.2 컨테이너 기동

```bash
sudo docker compose -f /opt/mlops/compose.yaml up -d team01
sudo docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

### 8.3 검증

```bash
sudo xfs_quota -x -c "report -p -n" /data | head -n 20
df -h /data/teams/team01
sudo /opt/mlops/teamctl-xfs.sh audit
```

---

## 9. 모니터링 대시보드 설정

### 9.1 소스 배포 및 기동

```bash
sudo cp -r ~/work/my_dockers/dept-mlops/monitoring/ /opt/
cd /opt/monitoring
sudo docker compose up -d
sudo docker compose ps
```

### 9.2 Grafana 설정

접속: `http://<서버IP>:3000/`

초기 계정: `admin` / `admin` → 로그인 후 비밀번호 변경

#### 대시보드 Import

왼쪽 패널 **Dashboards** → 우상단 **New** → **Import** → ID 입력 후 **Load**:

| 대시보드 | Import ID | 비고 |
|----------|-----------|------|
| Node Exporter Full | `1860` | |
| Docker (cAdvisor) | `13946` | 소스: Prometheus 선택 |
| NVIDIA DCGM Exporter | `12239` | 소스: Prometheus 선택 |

### 9.3 Prometheus

접속: `http://<서버IP>:9090/`

---

## 전체 초기화 체크리스트

- [ ] nvme0n1 파티션 생성 + XFS 포맷
- [ ] `/data` 마운트 + fstab 등록 (`prjquota` 옵션 포함)
- [ ] 네트워크 설정 (IP, 게이트웨이, DNS)
- [ ] `/data/teams`, `/data/ssh`, `/data/ssh_backups` 디렉터리 생성
- [ ] `my_dockers` 리포지토리 클론
- [ ] `teamctl-xfs.sh` 및 관련 파일 `/opt/mlops/`에 배포
- [ ] Docker 이미지 빌드
- [ ] GPU 모드 설정 (`set-gpu-mode`)
- [ ] NFS 클라이언트 설치 + `/mnt/nfs/teams` 마운트 + fstab 등록
- [ ] 스토리지 서버 원격 제어용 SSH 키 생성 + 등록 + 연결 테스트
- [ ] 팀 생성 (`--nfs` 포함) + 컨테이너 기동 + audit 검증
- [ ] 모니터링 스택 기동 (Grafana + Prometheus)
- [ ] Grafana 대시보드 Import (1860, 13946, 12239)
