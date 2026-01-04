# Stage 1: Get runner binaries from official image
FROM ghcr.io/actions/actions-runner:latest AS runner-base

# Stage 2: Build Ubuntu 24.04 based runner matching GitHub ubuntu-latest
FROM ubuntu:24.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Create runner user with same UID as official image
RUN useradd -m -u 1001 -s /bin/bash runner

# Copy runner binaries from official image
COPY --from=runner-base /home/runner /home/runner

# Install development tools to match GitHub-hosted ubuntu-latest
# Reference: https://github.com/actions/runner-images/blob/main/images/ubuntu/Ubuntu2404-Readme.md
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Compilers - install multiple gfortran versions like GitHub
    clang \
    clang-format \
    clang-tidy \
    gcc \
    g++ \
    gfortran \
    gfortran-12 \
    gfortran-13 \
    gfortran-14 \
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
    locales \
    patch \
    # Node.js for WASM tests
    nodejs \
    npm \
    # Runner dependencies
    libicu74 \
    libssl3 \
    libkrb5-3 \
    && rm -rf /var/lib/apt/lists/*

# Generate locales
RUN locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LC_ALL=en_US.UTF-8

# Install sccache from binary release
RUN curl -L https://github.com/mozilla/sccache/releases/download/v0.8.2/sccache-v0.8.2-x86_64-unknown-linux-musl.tar.gz | \
    tar xz -C /tmp && \
    mv /tmp/sccache-v0.8.2-x86_64-unknown-linux-musl/sccache /usr/local/bin/ && \
    chmod +x /usr/local/bin/sccache && \
    rm -rf /tmp/sccache-*

# Set up alternatives for compilers
RUN update-alternatives --install /usr/bin/cc cc /usr/bin/gcc 100 && \
    update-alternatives --install /usr/bin/c++ c++ /usr/bin/g++ 100

# Ensure runner user can use sudo without password (like GitHub-hosted runners)
RUN echo "runner ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Fix ownership of runner directory
RUN chown -R runner:runner /home/runner

WORKDIR /home/runner
USER runner
