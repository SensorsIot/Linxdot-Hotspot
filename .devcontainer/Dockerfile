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
RUN if id -u vscode >/dev/null 2>&1; then \
        usermod -l ${USERNAME} -d /home/${USERNAME} -m vscode && \
        groupmod -n ${USERNAME} vscode; \
    elif ! id -u ${USERNAME} >/dev/null 2>&1; then \
        useradd -m -s /bin/bash -u 1000 ${USERNAME}; \
    fi

# Passwordless sudo for dev user (needed by SSHD feature init script)
RUN echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} && \
    chmod 0440 /etc/sudoers.d/${USERNAME}

USER ${USERNAME}
