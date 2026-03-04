FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# ─── System packages ────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
        gnupg \
        iptables \
        ip6tables \
        iproute2 \
        dns-root-data \
        dnsutils \
        jq \
        git \
        openssh-client \
        sudo \
    && rm -rf /var/lib/apt/lists/*

# ─── Node.js 22 LTS ─────────────────────────────────────────────────────────
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# ─── AmneziaWG ──────────────────────────────────────────────────────────────
RUN curl -fsSL https://raw.githubusercontent.com/amnezia-vpn/amneziawg-linux-kernel-module/master/install.sh | bash \
    || echo "WARNING: AmneziaWG kernel module install failed (expected in Docker build)"
# Install amneziawg-tools (awg, awg-quick)
RUN apt-get update && apt-get install -y --no-install-recommends \
        software-properties-common \
    && add-apt-repository -y ppa:amnezia/ppa \
    && apt-get update \
    && apt-get install -y --no-install-recommends amneziawg-tools \
    || ( \
        # Fallback: build from source if PPA not available
        apt-get install -y --no-install-recommends build-essential && \
        cd /tmp && \
        curl -fsSL https://github.com/amnezia-vpn/amneziawg-tools/archive/refs/heads/master.tar.gz | tar xz && \
        cd amneziawg-tools-master/src && \
        make && make install && \
        cd / && rm -rf /tmp/amneziawg-tools-master && \
        apt-get purge -y build-essential && apt-get autoremove -y \
    ) \
    && rm -rf /var/lib/apt/lists/*

# Verify at least one WG tool is available
RUN which awg-quick || which wg-quick || (echo "ERROR: No WireGuard tools installed" && exit 1)

# ─── Claude Code CLI ────────────────────────────────────────────────────────
RUN npm install -g @anthropic-ai/claude-code@latest

# ─── User setup ─────────────────────────────────────────────────────────────
RUN useradd -m -s /bin/bash claude \
    && echo "claude ALL=(root) NOPASSWD: /usr/bin/awg-quick, /usr/bin/wg-quick, /usr/sbin/iptables, /usr/sbin/ip6tables, /usr/bin/awg, /usr/bin/wg, /usr/sbin/ip" > /etc/sudoers.d/claude \
    && chmod 440 /etc/sudoers.d/claude

# ─── Directories with correct ownership ─────────────────────────────────────
RUN mkdir -p /home/claude/projects /home/claude/.claude \
    && chown -R claude:claude /home/claude/projects /home/claude/.claude

# ─── Health check script ────────────────────────────────────────────────────
COPY scripts/health-check.sh /usr/local/bin/health-check
RUN chmod +x /usr/local/bin/health-check

# ─── Entrypoint ─────────────────────────────────────────────────────────────
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# ─── Config directory ───────────────────────────────────────────────────────
RUN mkdir -p /etc/amnezia && chmod 700 /etc/amnezia

WORKDIR /home/claude/projects
USER claude

ENTRYPOINT ["/entrypoint.sh"]
CMD ["bash"]
