FROM ghcr.io/actions/actions-runner:latest

USER root

# Install development tools to match GitHub-hosted ubuntu-latest
# Reference: https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2404-Readme.md
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Compilers
    clang \
    clang-format \
    clang-tidy \
    gcc \
    g++ \
    gfortran \
    # Build tools
    cmake \
    ninja-build \
    make \
    autoconf \
    automake \
    libtool \
    pkg-config \
    # Parser generators
    bison \
    flex \
    # Libraries
    zlib1g-dev \
    libssl-dev \
    libcurl4-openssl-dev \
    libbz2-dev \
    libffi-dev \
    libreadline-dev \
    libsqlite3-dev \
    liblzma-dev \
    libopenblas-dev \
    liblapack-dev \
    # Python
    python3 \
    python3-pip \
    python3-venv \
    python3-dev \
    # Git and tools
    git \
    curl \
    wget \
    jq \
    unzip \
    zip \
    xz-utils \
    # Other utilities
    sudo \
    ca-certificates \
    gnupg \
    lsb-release \
    && rm -rf /var/lib/apt/lists/*

# Symlink clang/clang++ to versioned names if needed
RUN update-alternatives --install /usr/bin/cc cc /usr/bin/clang 100 && \
    update-alternatives --install /usr/bin/c++ c++ /usr/bin/clang++ 100

# Ensure runner user can use sudo without password (like GitHub-hosted runners)
RUN echo "runner ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

USER runner
