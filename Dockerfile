FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# ─── Системные пакеты ────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl \
        ca-certificates \
        gnupg \
        iptables \
        iproute2 \
        dnsutils \
        jq \
        git \
        openssh-client \
        gosu \
    && rm -rf /var/lib/apt/lists/*

# ─── AmneziaWG ───────────────────────────────────────────────────────────────
RUN curl -fsSL https://raw.githubusercontent.com/amnezia-vpn/amneziawg-linux-kernel-module/master/install.sh | bash \
    || echo "ПРЕДУПРЕЖДЕНИЕ: установка модуля ядра AmneziaWG не удалась (ожидаемо при сборке Docker)"
# Установка amneziawg-tools (awg, awg-quick)
RUN apt-get update && apt-get install -y --no-install-recommends \
        software-properties-common \
    && add-apt-repository -y ppa:amnezia/ppa \
    && apt-get update \
    && apt-get install -y --no-install-recommends amneziawg-tools \
    || ( \
        # Фолбэк: сборка из исходников, если PPA недоступен
        apt-get install -y --no-install-recommends build-essential && \
        cd /tmp && \
        curl -fsSL https://github.com/amnezia-vpn/amneziawg-tools/archive/refs/heads/master.tar.gz | tar xz && \
        cd amneziawg-tools-master/src && \
        make && make install && \
        cd / && rm -rf /tmp/amneziawg-tools-master && \
        apt-get purge -y build-essential && apt-get autoremove -y \
    ) \
    && apt-get purge -y software-properties-common && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*

# Проверяем, что хотя бы один WG-инструмент установлен
RUN which awg-quick || which wg-quick || (echo "ОШИБКА: WireGuard-инструменты не установлены" && exit 1)

# ─── Go (latest stable) ─────────────────────────────────────────────────────
ARG GO_VERSION=1.24.1
RUN curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-$(dpkg --print-architecture).tar.gz" \
        | tar -C /usr/local -xz
ENV PATH="/usr/local/go/bin:/home/claude/go/bin:${PATH}"
ENV GOPATH="/home/claude/go"

# ─── Docker CLI (используем Docker хоста через монтирование docker.sock) ────
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
    && chmod a+r /etc/apt/keyrings/docker.asc \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
       https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
       > /etc/apt/sources.list.d/docker.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends docker-ce-cli docker-compose-plugin \
    && rm -rf /var/lib/apt/lists/*

# ─── Node.js (LTS) — нужен для Claude Code CLI ─────────────────────────────
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# ─── Claude Code CLI ────────────────────────────────────────────────────────
# npm-установка надёжнее native installer в constrained-окружениях (OOM при сборке)
RUN npm install -g @anthropic-ai/claude-code

# ─── Создание пользователя (без sudo — entrypoint от root, сброс до claude через gosu)
RUN groupadd docker 2>/dev/null || true \
    && useradd -m -s /bin/bash claude \
    && usermod -aG docker claude \
    && chmod 755 /home/claude

# ─── Директории с правильными правами ─────────────────────────────────────────
RUN mkdir -p /home/claude/projects /home/claude/.claude \
    && chown -R claude:claude /home/claude/projects /home/claude/.claude

# ─── Скрипт диагностики ──────────────────────────────────────────────────────
COPY scripts/health-check.sh /usr/local/bin/health-check
RUN chmod +x /usr/local/bin/health-check

# ─── Обёртка для Claude (инжектит API-ключ per-process, не глобально) ─────────
COPY scripts/claude-wrapper.sh /usr/local/bin/claude-safe
RUN chmod +x /usr/local/bin/claude-safe

# ─── Entrypoint ──────────────────────────────────────────────────────────────
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# ─── Директория для конфигов ──────────────────────────────────────────────────
RUN mkdir -p /etc/amnezia && chmod 700 /etc/amnezia

WORKDIR /home/claude/projects

# Entrypoint запускается от root для настройки VPN/killswitch, затем сбрасывает привилегии до claude
ENTRYPOINT ["/entrypoint.sh"]
CMD ["bash"]
