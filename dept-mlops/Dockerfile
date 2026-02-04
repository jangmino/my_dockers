FROM pytorch/pytorch:2.10.0-cuda13.0-cudnn9-runtime

# uv
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

ENV DEBIAN_FRONTEND=noninteractive
WORKDIR /workspace
SHELL ["/bin/bash", "-c"]

RUN apt update && apt install -y --no-install-recommends \
    # 기본 유틸
    ca-certificates curl wget git git-lfs vim nano tmux screen htop tree unzip zip rsync \
    # ssh / sudo
    openssh-server sudo \
    # 빌드/컴파일(파이썬 패키지 빌드 실패 방지)
    build-essential pkg-config cmake ninja-build python3-dev \
    # 비전/GUI없는 서버에서 opencv 등에서 자주 필요한 런타임
    libgl1 libglib2.0-0 libsm6 libxext6 libxrender1 \
    # 오디오/영상
    ffmpeg libsndfile1 \
    # 압축
    zstd pigz \
    # 디버깅/관측
    gdb lsof strace \
 && rm -rf /var/lib/apt/lists/* \
 && mkdir -p /var/run/sshd

# SSH: key-only, root login 금지 + VS Code/터널 편의 + 세션 안정화
RUN sed -i 's/#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config \
 && sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config \
 && sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config \
 && echo "AllowTcpForwarding yes" >> /etc/ssh/sshd_config \
 && echo "X11Forwarding no" >> /etc/ssh/sshd_config \
 && echo "ClientAliveInterval 60" >> /etc/ssh/sshd_config \
 && echo "ClientAliveCountMax 3" >> /etc/ssh/sshd_config \
 && echo "StrictModes no" >> /etc/ssh/sshd_config

COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 22
ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["/usr/sbin/sshd", "-D", "-e"]