# PEFT 도커 제작 히스토리

## 2023-10-08

jangminnature/peft:v1.1dev-torch2.1-cu118
- [Dockerfile.peft.v1.1]
- 출처: pytorch/pytorch:2.1.0-cuda11.8-cudnn8-devel

`jangminnature/peft:v1.1a-dev-torch2.1.cu118`
- 다음과 같은 이유로 컨테이너에서 직접 추가 빌드
    - 루트로 컨테이너 접속하여 아래 패키지 빌드
        - 이유
            - nvidia 환경 설정이 제대로 되어야 cuda extension 빌드 가능하므로
            - 직접 컨테이너에서 빌드함
    - AutoGPTQ 설치
        ```
        git clone https://github.com/PanQiWei/AutoGPTQ.git && cd AutoGPTQ
        pip install -v .
        ```
    - AutoAWQ 설치
        ```
        git clone https://github.com/casper-hansen/AutoAWQ
        cd AutoAWQ
        pip install -v .
        ```
