FROM ghcr.io/anomalyco/opencode:1.2.10

USER root

RUN apk add --no-cache \
    bash \
    git \
    curl \
    xdg-utils \
    wl-clipboard \
    ca-certificates \
    unzip \
    clang \
    mise

# Set up system-wide bash config:
#   - mise shell integration for interactive use
#   - auto-start opencode as a child of the login shell (SHLVL guard prevents
#     recursive launches when bash spawns subshells)
RUN printf '%s\n' \
    'eval "$(mise activate bash)"' \
    >> /etc/bash.bashrc

# Create user with UID=1000 to match the host user
RUN addgroup -g 1000 achuie && \
    adduser -D -u 1000 -G achuie -h /home/achuie -s /bin/bash achuie

USER achuie

# Set git config for OpenCode to recognize user
RUN git config --global user.name "achuie" && \
    git config --global user.email "achuie@protonmail.com"

WORKDIR /workspace

# Clear the base image's ENTRYPOINT so CMD runs directly.
# Start an interactive bash shell; bash auto-starts opencode via /etc/bash.bashrc.
# Running opencode as a child of bash enables job control (Ctrl+Z / fg / bg).
ENTRYPOINT []
CMD ["/bin/bash", "--rcfile", "/etc/bash.bashrc"]
