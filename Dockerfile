FROM ghcr.io/anomalyco/opencode:1.2.10

USER root

RUN apk add --no-cache \
    bash \
    git \
    curl \
    xdg-utils \
    wl-clipboard \
    ca-certificates \
    unzip

# Create user with UID=1000 to match the host user
RUN addgroup -g 1000 achuie && \
    adduser -D -u 1000 -G achuie -h /home/achuie -s /bin/bash achuie

USER achuie

# Set git config for OpenCode to recognize user
RUN git config --global user.name "achuie" && \
    git config --global user.email "achuie@protonmail.com"

WORKDIR /workspace
