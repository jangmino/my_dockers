# 🛠️ GPU 서버 초기 세팅 매뉴얼

> PRO 6000×4 GPU 서버 기준
>
> 새 머신을 받았을 때 OS 설치 이후 수행하는 전체 초기화 절차입니다.

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

## 7. 팀 생성 및 컨테이너 기동

### 7.1 팀 생성

```bash
sudo /opt/mlops/teamctl-xfs.sh create team01 --gpu 0 --image mlops:latest --size 1000G --soft 950G
```

### 7.2 컨테이너 기동

```bash
sudo docker compose -f /opt/mlops/compose.yaml up -d team01
sudo docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
```

### 7.3 검증

```bash
sudo xfs_quota -x -c "report -p -n" /data | head -n 20
df -h /data/teams/team01
sudo /opt/mlops/teamctl-xfs.sh audit
```

---

## 8. 모니터링 대시보드 설정

### 8.1 소스 배포 및 기동

```bash
sudo cp -r ~/work/my_dockers/dept-mlops/monitoring/ /opt/
cd /opt/monitoring
sudo docker compose up -d
sudo docker compose ps
```

### 8.2 Grafana 설정

접속: `http://<서버IP>:3000/`

초기 계정: `admin` / `admin` → 로그인 후 비밀번호 변경

#### 대시보드 Import

왼쪽 패널 **Dashboards** → 우상단 **New** → **Import** → ID 입력 후 **Load**:

| 대시보드 | Import ID | 비고 |
|----------|-----------|------|
| Node Exporter Full | `1860` | |
| Docker (cAdvisor) | `13946` | 소스: Prometheus 선택 |
| NVIDIA DCGM Exporter | `12239` | 소스: Prometheus 선택 |

### 8.3 Prometheus

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
- [ ] 팀 생성 + 컨테이너 기동 + audit 검증
- [ ] 모니터링 스택 기동 (Grafana + Prometheus)
- [ ] Grafana 대시보드 Import (1860, 13946, 12239)
