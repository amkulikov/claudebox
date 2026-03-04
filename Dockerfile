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

# ─── Node.js 22 LTS ──────────────────────────────────────────────────────────
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
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

# ─── Claude Code CLI ─────────────────────────────────────────────────────────
RUN npm install -g @anthropic-ai/claude-code@latest

# ─── Создание пользователя (без sudo — entrypoint от root, сброс до claude через gosu)
RUN useradd -m -s /bin/bash claude \
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
