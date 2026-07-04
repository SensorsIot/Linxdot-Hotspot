FROM mcr.microsoft.com/devcontainers/base:debian

ARG USERNAME=dev

# Remove unused zsh/oh-my-zsh
RUN rm -rf /home/*/.oh-my-zsh /root/.oh-my-zsh && \
    apt-get purge -y zsh && apt-get autoremove -y

# Buildroot build dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    gcc \
    g++ \
    make \
    patch \
    cpio \
    unzip \
    rsync \
    bc \
    wget \
    curl \
    file \
    libncurses-dev \
    python3 \
    python-is-python3 \
    perl \
    bzip2 \
    xz-utils \
    dosfstools \
    mtools \
    fdisk \
    parted \
    device-tree-compiler \
    u-boot-tools \
    sshpass \
    libssl-dev \
    && rm -rf /var/lib/apt/lists/*

# Rename default 'vscode' user to 'dev' (keeps UID 1000)
RUN usermod -l dev -d /home/dev -m vscode \
    && groupmod -n dev vscode \
    && sed -i 's/vscode/dev/g' /etc/sudoers.d/vscode || true \
    && mv /etc/sudoers.d/vscode /etc/sudoers.d/dev 2>/dev/null || true

# Passwordless sudo for dev user (needed by SSHD feature init script)
RUN echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} && \
    chmod 0440 /etc/sudoers.d/${USERNAME}

# SSH quiet config
RUN mkdir -p /home/${USERNAME}/.ssh \
    && printf 'Host *\n    StrictHostKeyChecking accept-new\n    LogLevel ERROR\n' > /home/${USERNAME}/.ssh/config \
    && chmod 700 /home/${USERNAME}/.ssh \
    && chmod 600 /home/${USERNAME}/.ssh/config \
    && chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.ssh

USER ${USERNAME}

# Set default working directory for SSH logins
WORKDIR /workspaces/Linxdot-Hotspot
RUN echo 'cd /workspaces/Linxdot-Hotspot 2>/dev/null' >> /home/dev/.bashrc

# tmux — terminal multiplexer for SSH sessions
USER root
RUN apt-get update && apt-get install -y --no-install-recommends tmux \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
USER ${USERNAME}
