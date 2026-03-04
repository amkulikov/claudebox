# Plan: Docker-контейнер с Claude Code + Amnezia VPN

## Контекст
- Корпоративный VPN = split tunnel (только корп. ресурсы)
- Трафик из Docker-контейнера идёт напрямую → нужен Amnezia VPN внутри контейнера для доступа к Claude API
- Целевая аудитория: мидл-разработчик, пошаговая инструкция

## Структура проекта

```
claudebox/
├── Dockerfile                    # Основной образ
├── docker-compose.yml            # Удобный запуск с volumes, env, capabilities
├── entrypoint.sh                 # Инициализация VPN → проверка → запуск shell
├── scripts/
│   └── health-check.sh           # Проверка что VPN работает и Claude API доступен
├── configs/
│   └── amnezia.conf.example      # Пример конфига Amnezia VPN
└── README.md                     # Пошаговая инструкция
```

## Шаги реализации

### 1. Dockerfile
- Базовый образ: `ubuntu:24.04`
- Установка: Node.js 22 LTS, npm, Claude Code CLI (`@anthropic-ai/claude-code`)
- Установка: AmneziaWG (amnezia-wg клиент) — форк WireGuard с обфускацией
- Установка: утилиты (curl, jq, ip, iptables для kill-switch)
- Создание непривилегированного пользователя `claude`

### 2. entrypoint.sh
- Проверка наличия VPN-конфига (`/etc/amnezia/awg0.conf`)
- Поднятие AmneziaWG интерфейса: `awg-quick up awg0`
- Опциональный kill-switch: если VPN упал — трафик блокируется
- Проверка доступности `api.anthropic.com`
- Запуск интерактивного shell (bash) с Claude Code

### 3. docker-compose.yml
```yaml
services:
  claudebox:
    build: .
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    volumes:
      - ./configs/amnezia.conf:/etc/amnezia/awg0.conf:ro  # VPN конфиг
      - ~/projects:/home/claude/projects                    # Рабочие проекты
      - claude-config:/home/claude/.claude                  # Сохранение auth Claude
    environment:
      - ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}            # Опционально, можно логиниться интерактивно
    stdin_open: true
    tty: true
```

### 4. README.md — пошаговая инструкция
1. Требования (Docker, конфиг Amnezia VPN, API-ключ или аккаунт)
2. Как получить конфиг Amnezia VPN (ссылка на доку)
3. `cp configs/amnezia.conf.example configs/amnezia.conf` → вставить свой конфиг
4. `docker compose up -d && docker compose exec claudebox bash`
5. Внутри контейнера: `claude` — запуск Claude Code
6. Как подключить свой проект
7. Troubleshooting (VPN не поднялся, API недоступен, и т.д.)

### 5. health-check.sh
- Проверка VPN-интерфейса (`awg show`)
- Проверка DNS-резолва `api.anthropic.com`
- Проверка HTTPS-доступа к API
- Цветной вывод статуса для наглядности

## Особенности
- **Kill-switch**: если VPN-соединение упадёт, трафик не пойдёт напрямую (iptables правила)
- **Persistent auth**: volume для `~/.claude` чтобы не логиниться каждый раз
- **Amnezia WG, а не полный Amnezia VPN**: клиент AmneziaWG легче, работает из CLI, не требует GUI
