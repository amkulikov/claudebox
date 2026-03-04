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

# 2. Сохранить API-ключ (через файл — безопаснее чем env var)
mkdir -p secrets
echo -n "sk-ant-your-key-here" > secrets/anthropic_api_key
chmod 600 secrets/anthropic_api_key

# 3. Создать .env файл
cat > .env <<EOF
PROJECTS_PATH="/home/youruser/projects"
EOF

# 4. Собрать и запустить
docker compose build
docker compose up -d

# 5. Войти в контейнер
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

## Конфигурация

| Параметр | Описание | По умолчанию |
|---|---|---|
| `secrets/anthropic_api_key` | Файл с API-ключом Anthropic (безопаснее чем env) | — |
| `PROJECTS_PATH` | Путь к проектам на хосте (в `.env`) | `./_projects` |
| `KILLSWITCH` | Kill-switch: блокировать трафик вне VPN (в `.env`) | `1` (включён) |

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

## Безопасность

**Что защищено:**
- API-ключ хранится в файле (`secrets/`), а не в env-переменной — не виден через `docker inspect`
- Kill-switch блокирует весь трафик вне VPN (включая IPv6)
- sudo внутри контейнера ограничен только командами VPN и iptables
- Capabilities: только `NET_ADMIN`, все остальные сброшены (`cap_drop: ALL`)
- Ресурсные лимиты: 4 GB RAM, 2 CPU, 256 процессов
- VPN-конфиг монтируется read-only

**Что стоит учитывать:**
- Claude Code по дизайну выполняет произвольные команды — вредоносный код в проекте может прочитать API-ключ из `/run/secrets/`
- Директория с проектами монтируется с полным RW-доступом — контейнер может модифицировать/удалять файлы
- Рекомендуется монтировать только конкретные проекты, а не всю домашнюю директорию
- Не храните в примонтированных проектах файлы с секретами (`.env`, ключи, токены)

**Файлы, которые НЕЛЬЗЯ коммитить:**
- `secrets/` — API-ключ
- `configs/amnezia.conf` — VPN-ключи
- `.env` — пути и настройки

Все перечисленные файлы добавлены в `.gitignore`.

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
├── secrets/                # (gitignored) API-ключ
└── README.md
```
