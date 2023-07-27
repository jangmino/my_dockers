
# 최초 기동된 도커 컨테이너에 필요한 추가 설정

## git 관련

```bash
    git config --global user.name "Jangmin Oh"
    git config --global user.email "jangmin.o@gmail.com"
    git config --global credential.helper store
    git config --global pull.rebase false
```

만약 프라이빗 리포등에 연동 작업시 최초 클로닝시
```
    git clone https://토큰@github/리포주소
```
- 토큰 -> 실제 인증 토큰으로 교체
- 리포주소 -> 실제 리포 주소로 교체

lfs 관련 설정 (필요시)
```bash
git lfs install
```

## vscode 관련

확장 관리
- devcontainer마다 매번 설치하지 말고 확장 관리 가능
- 로컬 vscode 에서
    - CMD + SHIFT + P: Dev > Containers : Default Extensions
    - 를 통해 다음과 같은 (또는 상황에 맞게) 확장 세팅
    ```json
    "dev.containers.defaultExtensions": [
    "ms-python.black-formatter",
    "GitHub.copilot",
    "ms-python.black-formatter",
    "ms-python.python",
    "ms-vscode.cpptools",
    "ms-vscode.cpptools-extension-pack",
    "ms-vscode.cpptools-themes",
    "ms-vscode.makefile-tools",
    "ms-python.autopep8",
    "mhutchie.git-graph",
    "ms-toolsai.jupyter",
    "ms-toolsai.jupyter-keymap",
    "ms-toolsai.jupyter-renderers",
    "shd101wyy.markdown-preview-enhanced",
    "hbenl.vscode-test-explorer"
    ]
    ```

## 참고: AWS 관련 추가 설정

Aws cli 설치 (컨테이너에서)
- curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
- unzip awscliv2.zip
- sudo ./aws/install
    - 이 과정에서 RLLIMIT (?) 가 권한 문제로 설정 불가하다고 하나… 무시한다.
        - aws configure
        - aws configure list-profiles
- aws configure --profile 로 프로파일 지정 가능
    - 그후
        - aws s3 ls --profile user2
        - export AWS_PROFILE=user2
- pip install sagemaker (SageMaker 사용하려면 설치 필요)