FROM ghcr.io/actions/actions-runner:latest

USER root

# Install development tools to match GitHub-hosted ubuntu-latest
# Reference: https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2404-Readme.md
RUN apt-get update && apt-get install -y \
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
    ccache \
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
    # Node.js for WASM tests
    nodejs \
    npm

# Install sccache from binary release
RUN curl -L https://github.com/mozilla/sccache/releases/download/v0.8.2/sccache-v0.8.2-x86_64-unknown-linux-musl.tar.gz | \
    tar xz -C /tmp && \
    mv /tmp/sccache-v0.8.2-x86_64-unknown-linux-musl/sccache /usr/local/bin/ && \
    chmod +x /usr/local/bin/sccache && \
    rm -rf /tmp/sccache-*

# Symlink clang/clang++ to versioned names if needed
RUN update-alternatives --install /usr/bin/cc cc /usr/bin/clang 100 && \
    update-alternatives --install /usr/bin/c++ c++ /usr/bin/clang++ 100

# Ensure runner user can use sudo without password (like GitHub-hosted runners)
RUN echo "runner ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

USER runner
