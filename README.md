# Claudebox

Docker-контейнер с Claude Code и Amnezia VPN. Позволяет использовать Claude Code через VPN, не затрагивая основную сеть хоста.

## Требования

- Docker (с Docker Compose)
- Конфиг AmneziaWG (от вашего Amnezia VPN сервера)
- API-ключ Anthropic или аккаунт для интерактивного логина

## Быстрый старт

```bash
git clone <repo-url> && cd claudebox
./setup.sh
```

`setup.sh` — интерактивный wizard, который:

1. Проверит что Docker установлен и запущен
2. Попросит путь к вашему AmneziaWG конфигу
3. Настроит аутентификацию Claude (API-ключ или browser login)
4. Спросит путь к директории с проектами
5. Соберёт и запустит контейнер

## Ручная настройка

Если предпочитаете настроить вручную:

```bash
# 1. Скопировать конфиг VPN
cp configs/amnezia.conf.example configs/amnezia.conf
# Отредактировать configs/amnezia.conf — вставить данные вашего сервера

# 2. Создать .env файл
cat > .env <<EOF
ANTHROPIC_API_KEY="sk-ant-your-key-here"
PROJECTS_PATH="/home/youruser/projects"
EOF

# 3. Собрать и запустить
docker compose build
docker compose up -d

# 4. Войти в контейнер
docker compose exec claudebox bash
```

## Использование

```bash
# Войти в контейнер
docker compose exec claudebox bash

# Запустить Claude Code
claude

# Проверить статус VPN и API
health-check
```

Ваши проекты доступны внутри контейнера в `/home/claude/projects`.

## Переменные окружения

| Переменная | Описание | По умолчанию |
|---|---|---|
| `ANTHROPIC_API_KEY` | API-ключ Anthropic | — |
| `PROJECTS_PATH` | Путь к проектам на хосте | `~/projects` |
| `KILLSWITCH` | Kill-switch: блокировать трафик вне VPN | `1` (включён) |

## Kill Switch

По умолчанию включён. Если VPN-соединение упадёт, весь исходящий трафик из контейнера будет заблокирован (кроме локальной сети). Это предотвращает утечку трафика мимо VPN.

Отключить: `KILLSWITCH=0` в `.env`.

## Troubleshooting

**VPN не поднимается:**
```bash
# Внутри контейнера
sudo awg-quick up awg0
# Проверить логи
health-check
```

**Claude API недоступен:**
```bash
# Проверить VPN
health-check
# Попробовать вручную
curl -v https://api.anthropic.com
```

**Ошибка `NET_ADMIN` или `/dev/net/tun`:**
- Убедитесь что Docker запущен не в rootless режиме, или добавьте capabilities вручную
- На macOS и Windows `/dev/net/tun` проксируется через Docker Desktop

**Контейнер перезапускается:**
```bash
docker compose logs claudebox
```

## Структура проекта

```
claudebox/
├── Dockerfile              # Образ: Ubuntu + Node.js + Claude Code + AmneziaWG
├── docker-compose.yml      # Orchestration: volumes, capabilities, env
├── entrypoint.sh           # Запуск VPN → kill-switch → проверка API → shell
├── setup.sh                # Интерактивный wizard для настройки
├── scripts/
│   └── health-check.sh     # Диагностика VPN и API
├── configs/
│   └── amnezia.conf.example  # Пример конфига VPN
└── README.md
```
