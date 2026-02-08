# 🖥️ GPU 서버 팀 운영 가이드 — 팀원용

> VS Code + Remote-SSH + Team Container 환경
>
> 서버 사용 전 **반드시 전체 내용을 숙지**해 주세요.

---

## 원칙 요약

- 접속은 **SSH 키 인증만** 허용 (비밀번호 로그인 불가)
- 작업은 반드시 **`/workspace` 또는 `~`** 에서 진행
- 장시간 학습은 **`screen` 필수**
- 파이썬 환경/패키지는 **`uv` 의무 사용**

---

## 1. 팀별 접속 정보

아래 표에서 본인 팀의 접속 정보를 확인하세요.

| TEAM | HOST (서버IP/도메인) | PORT | GPU | QUOTA (Soft/Hard) | 비고 |
|------|----------------------|------|-----|--------------------|------|
| team01 | `<서버IP>` | 22021 | 0 | 950G / 1000G | 예시 |
| team02 | `<서버IP>` | 22022 | 1 | 950G / 1000G | |
| team03 | `<서버IP>` | 22023 | 2 | 950G / 1000G | |
| team04 | `<서버IP>` | 22024 | 3 | 950G / 1000G | |

---

## 2. SSH 키 생성

> **주의:** `-C` 옵션에 반드시 `팀명/팀원식별자` 형식을 사용하세요.
> 예: `team01/jangmin`, `team01/minji`, `team02/soyeon`

### Mac / Linux

```bash
ssh-keygen -t ed25519 -C "team01/jangmin" -f ~/.ssh/id_ed25519_team01_jangmin
cat ~/.ssh/id_ed25519_team01_jangmin.pub
```

### Windows (PowerShell)

```powershell
ssh-keygen -t ed25519 -C "team01/jangmin" -f $env:USERPROFILE\.ssh\id_ed25519_team01_jangmin
type $env:USERPROFILE\.ssh\id_ed25519_team01_jangmin.pub
```

### 관리자에게 전달

- ✅ **전달할 것:** `.pub` 공개키 내용 (한 줄)
- ❌ **절대 공유 금지:** 비밀키 파일 (`id_ed25519_...`)

---

## 3. VS Code Remote-SSH 접속 설정

### SSH config 작성

SSH config 파일 위치:
- Mac/Linux: `~/.ssh/config`
- Windows: `C:\Users\<사용자>\.ssh\config`

**위 접속 정보 표를 참고하여** 아래를 추가합니다. (예: team01, PORT=22021)

```
Host ss-team01
  HostName <서버IP>
  User team01
  Port 22021
  IdentityFile ~/.ssh/id_ed25519_team01_jangmin
  IdentitiesOnly yes
  ServerAliveInterval 30
```

### 접속 방법

1. VS Code → Command Palette (`Ctrl+Shift+P` / `Cmd+Shift+P`)
2. `Remote-SSH: Connect to Host...` 선택
3. `ss-team01` 선택

터미널에서 확인할 때:

```bash
ssh ss-team01
```

---

## 4. 작업 위치 규칙

컨테이너의 `/` (root, overlay)에 파일을 쌓으면 서버 디스크를 불필요하게 점유합니다.

```bash
# ✅ 항상 여기서 작업
cd /workspace
# 또는
cd ~
```

---

## 5. GPU 사용 규칙

각 팀 컨테이너는 할당된 GPU만 보이도록 격리되어 있으므로, GPU ID를 직접 지정할 필요 없이 컨테이너 안에서 학습/추론을 실행하면 됩니다.

### GPU 상태 확인

```bash
nvidia-smi
```

### ⛔ 금지 사항

- 호스트(컨테이너 밖)에서 직접 학습을 실행하는 행위
- 다른 팀 컨테이너에 접근하는 행위

### 🚨 문제 발생 시

`nvidia-smi`에서 GPU가 보이지 않거나 에러가 발생하면 **즉시 관리자에게 문의**하세요.

---

## 6. 장시간 학습은 screen 필수

VS Code 터미널에서 그냥 실행하면 네트워크 단절이나 VS Code 종료 시 학습이 중단됩니다.

```bash
# screen 시작
screen -S MyRUN

# screen 안에서 학습 실행
cd /workspace
python train.py

# detach (백그라운드 지속): Ctrl+A → D

# 다시 붙기
screen -r MyRUN

# screen 목록 보기
screen -ls
```

**팁:** 로그를 파일로 남기세요.

```bash
python train.py 2>&1 | tee -a train.log
```

---

## 7. 파이썬/패키지 설치는 uv 의무

> ❌ `pip install ...` 직접 사용 금지
> ✅ 항상 `uv pip install ...`

```bash
# 가상환경 생성
cd /workspace
uv venv .venv --python=3.13

# 가상환경 활성화
source .venv/bin/activate

# 패키지 설치
uv pip install unsloth vllm

# 실행
python my-train.py
```

---

## 8. 디스크 사용량 확인

기본 정책 예: 1,000G 할당 / 950G 이상 사용 시 경고

```bash
df -h ~
df -h /workspace
```

출력 예시:

```
Filesystem      Size  Used Avail Use% Mounted on
/dev/nvme0n1p1  950G   45G  906G   5% /home/team01
```

---

## 9. 자주 발생하는 문제

### (A) `REMOTE HOST IDENTIFICATION HAS CHANGED` 경고

컨테이너 교체로 SSH host key가 바뀐 경우입니다. 아래 실행 후 재접속:

```bash
ssh-keygen -R "[<서버IP>]:<PORT>"
# 예:
ssh-keygen -R "[210.125.91.95]:22021"
```

### (B) 접속이 안 될 때

```bash
ssh -vvv ss-team01
```

출력 로그를 관리자에게 전달하세요.

---

## 10. 추천 작업 템플릿

```bash
cd /workspace
uv venv .venv --python=3.13
source .venv/bin/activate
uv pip install -r requirements.txt

screen -S MyRUN
python train.py 2>&1 | tee -a train.log
# Ctrl+A, D 로 detach
```

---

## 작업 전 체크리스트

- [ ] 컨테이너 안에서 실행 중이다 → `hostname` 명령으로 확인
- [ ] 작업 디렉터리는 `/workspace` 또는 `~` 이다
- [ ] `nvidia-smi`에서 GPU가 정상적으로 보인다
- [ ] 장시간 학습은 `screen`에서 실행 중이다
- [ ] 패키지 설치에 `uv pip install`을 사용했다
