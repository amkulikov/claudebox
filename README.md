# Claudebox

Docker-контейнер с Claude Code. Опционально — через Amnezia VPN, не затрагивая основную сеть хоста.

## Быстрый старт

```bash
git clone <repo-url> && cd claudebox
./setup.sh
```

Wizard спросит всё сам: VPN, API-ключ, путь к проектам. После этого контейнер соберётся и запустится автоматически.

## Использование

```bash
# Войти в контейнер
docker compose exec claudebox bash

# Запустить Claude Code
claude-safe

# Проверить что всё работает
health-check
```

Ваши проекты доступны внутри контейнера в `/home/claude/projects`.

## Что делает setup.sh

1. Проверяет что Docker установлен и запущен
2. Спрашивает про VPN (Amnezia) — можно пропустить
3. Настраивает аутентификацию (API-ключ или браузер)
4. Спрашивает путь к директории с проектами
5. Предлагает скрыть чувствительные директории от Claude
6. Собирает и запускает контейнер

## Требования

- Docker (с Docker Compose)
- bash 3.2+ (встроенный bash на macOS работает)
- API-ключ Anthropic или аккаунт для интерактивного логина
- (Опционально) Конфиг AmneziaWG — если нужен VPN для доступа к Claude API

## Troubleshooting

**VPN не поднимается:**
```bash
# Внутри контейнера — проверить статус
health-check
# Перезапустить контейнер (VPN поднимается автоматически через entrypoint)
docker compose restart claudebox
```

**Claude API недоступен:**
```bash
health-check
curl -v https://api.anthropic.com
```

**Ошибка `NET_ADMIN` или `/dev/net/tun`:**
- Убедитесь что Docker запущен не в rootless режиме, или добавьте capabilities вручную
- На macOS и Windows `/dev/net/tun` проксируется через Docker Desktop

**Контейнер перезапускается:**
```bash
docker compose logs claudebox
```

---

## Для продвинутых

### Ручная настройка (без setup.sh)

```bash
# 1. Скопировать конфиг VPN (пропустить, если без VPN)
cp configs/amnezia.conf.example configs/amnezia.conf
# Отредактировать configs/amnezia.conf — вставить данные вашего сервера

# 2. Сохранить API-ключ (через файл — безопаснее чем env var)
mkdir -p secrets
echo -n "sk-ant-your-key-here" > secrets/anthropic_api_key
chmod 600 secrets/anthropic_api_key

# 3. Создать .env файл
cat > .env <<EOF
PROJECTS_PATH="/home/youruser/projects"
VPN_ENABLED="1"
EOF

# 4. Собрать и запустить
docker compose build
docker compose up -d
docker compose exec claudebox bash
```

### Конфигурация (.env)

| Параметр | Описание | По умолчанию |
|---|---|---|
| `PROJECTS_PATH` | Путь к проектам на хосте | `./_projects` |
| `VPN_ENABLED` | Включить Amnezia VPN | `1` (включён) |
| `KILLSWITCH` | Блокировать трафик вне VPN | `1` (включён) |
| `CORP_BYPASS` | Домены, которые идут мимо VPN через хост | — (пусто) |

API-ключ хранится в файле `secrets/anthropic_api_key`, а не в `.env`.

### Kill Switch

По умолчанию включён. Если VPN-соединение упадёт, весь исходящий трафик из контейнера блокируется. Это предотвращает утечку трафика мимо VPN.

Отключить: `KILLSWITCH=0` в `.env`.

### Корпоративный bypass

Если у вас есть корпоративный VPN на хосте и нужен доступ к корпоративным ресурсам из контейнера:

```bash
# В .env (или через setup.sh, шаг 3)
CORP_BYPASS="git.mycorp.com,registry.mycorp.com,*.internal.mycorp.com"
```

Трафик к этим доменам пойдёт через хост (и ваш корпоративный VPN), минуя Amnezia VPN. DNS-запросы тоже проксируются через хост.

IP-адреса резолвятся при старте контейнера. Если DNS-запись изменится — перезапустите контейнер.

### Скрытие директорий от Claude

**Мягкое** — `.claudeignore` (синтаксис как `.gitignore`):
```
datafixes/
*.sql
secrets/
```
Claude Code не будет искать/читать эти пути, но они физически доступны в контейнере.

**Жёсткое** — tmpfs overlay (настраивается через `setup.sh` шаг 5 или вручную):
```yaml
# docker-compose.override.yml
services:
  claudebox:
    volumes:
      - type: tmpfs
        target: /home/claude/projects/myproject/datafixes
```
Пустой tmpfs монтируется поверх реальной директории — физически невидимо внутри контейнера.

После изменения override: `docker compose down && docker compose up -d`

### Безопасность

**Что защищено:**
- API-ключ в файле (`secrets/`), не в env — не виден через `docker inspect`
- API-ключ инжектится только в процесс Claude (`claude-safe`), не глобально — не виден в `/proc/1/environ`
- Kill-switch блокирует весь трафик вне VPN (включая IPv6)
- Entrypoint от root для VPN, затем сброс до `claude` через `gosu`
- `no-new-privileges`, нет sudo, capabilities: только `NET_ADMIN`
- Лимиты: 4 GB RAM, 2 CPU, 256 процессов
- VPN-конфиг read-only, доступен только root

**Что стоит учитывать:**
- Claude Code выполняет произвольные команды — вредоносный код может прочитать API-ключ из `/run/secrets/`
- Проекты монтируются с RW-доступом — контейнер может модифицировать/удалять файлы
- Не монтируйте всю домашнюю директорию — только конкретные проекты
- Не храните секреты (`.env`, ключи, токены) в примонтированных проектах

**Файлы, которые нельзя коммитить** (все в `.gitignore`):
- `secrets/` — API-ключ
- `configs/amnezia.conf` — VPN-ключи
- `.env` — пути и настройки

### Структура проекта

```
claudebox/
├── Dockerfile              # Ubuntu + Node.js + Claude Code + AmneziaWG
├── docker-compose.yml      # Orchestration: volumes, capabilities, env
├── entrypoint.sh           # VPN → kill-switch → проверка API → shell
├── setup.sh                # Интерактивный wizard
├── scripts/
│   ├── health-check.sh     # Диагностика VPN и API
│   └── claude-wrapper.sh   # Инжектит API-ключ только в процесс Claude
├── configs/
│   └── amnezia.conf.example
├── secrets/                # (gitignored) API-ключ
└── README.md
```
