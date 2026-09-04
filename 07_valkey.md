LiteLLM хранит своё рабочее состояние (rate limits, бюджеты, cooldown'ы деплоев, кэш ответов, кэш виртуальных ключей) в Redis. Если Redis не подключён, каждый worker держит копию состояния в памяти: при нескольких workers лимиты умножаются на их число, отозванный ключ продолжает работать на «непроинформированных» workers, а Admin UI показывает предупреждение о Redis. Valkey — Redis-совместимая БД под лицензией BSD (форк Redis 7.2, поддерживается Linux Foundation), протокол полностью совместим, поэтому LiteLLM работает с ним через штатный Redis-клиент без каких-либо изменений. В Ubuntu 24.04 пакет есть в стандартном репозитории (universe) и называется `valkey-server`.

Инструкция продолжает [01_setup_litellm.md](01_setup_litellm.md): litellm установлен через venv и запущен как systemd-сервис на `127.0.0.1:4000`, конфиги лежат в `/etc/litellm/`. Docker-вариант описан в [07d_valkey.md](07d_valkey.md).

Схема:

```
клиент ──> nginx ──> litellm (127.0.0.1:4000) ──> LLM API (gpt.mwsapis.ru)
                          │
                          └──> Valkey (127.0.0.1:6379, requirepass)
                                   ↑ общее состояние: rate limits, бюджеты,
                                     cooldowns, кэш ключей и ответов
```

## 1. Что понадобится

- VM из [01_setup_litellm.md](01_setup_litellm.md): Ubuntu 24.04, litellm в venv `/opt/litellm/venv`, сервис `litellm` работает.
- Права `sudo`.
- Valkey ставится на той же VM, слушает `127.0.0.1:6379` и закрыт паролем; наружу не публикуется.

## 2. Установка Valkey

Пакеты: `valkey-server` (сервер) и `valkey-tools` (клиент `valkey-cli`) ставятся вместе автоматически.

```bash
sudo apt update
sudo apt install -y valkey-server
```

Проверка:

```bash
systemctl status valkey-server --no-pager
valkey-cli ping        # до настройки пароля должен ответить PONG
valkey-server --version
```

После установки сервис `valkey-server` уже добавлен в автозапуск и слушает `127.0.0.1:6379`.

## 3. Пароль Valkey

Генерируем пароль:

```bash
openssl rand -hex 32
```

Вписываем его в конфиг `/etc/valkey/valkey.conf` (строка `requirepass`, по умолчанию закомментирована):

```bash
sudo nano /etc/valkey/valkey.conf
```

Найдите (Ctrl+W) строку `# requirepass foobared` и замените на:

```ini
requirepass <пароль из openssl>
```

Заодно убедитесь, что включены (по умолчанию включены):

```ini
bind 127.0.0.1 -::1
protected-mode yes
```

Перезапуск и проверка:

```bash
sudo systemctl restart valkey-server
valkey-cli ping                     # ожидаемо: NOAUTH Authentication required
valkey-cli -a <пароль> ping         # PONG
```

Флаг `--no-auth-warning` убирает предупреждение «Using a password with '-a'...» в интерактиве:

```bash
valkey-cli -a <пароль> --no-auth-warning ping
```

## 4. Секреты для litellm

Добавляем три переменные в `/etc/litellm/litellm.env` (файл уже существует из [01_setup_litellm.md](01_setup_litellm.md), там же лежат `LITELLM_MASTER_KEY` и `CUSTOM_LLM_TOKEN`):

```bash
sudo nano /etc/litellm/litellm.env
```

```ini
REDIS_HOST=127.0.0.1
REDIS_PORT=6379
REDIS_PASSWORD=<пароль Valkey из шага 3>
```

Важно: сами по себе переменные `REDIS_*` ничего не включают — LiteLLM читает их только когда конфиг указывает на Redis (см. шаг 5). Права на файл не меняются: `root:litellm`, `640`.

## 5. Конфиг litellm

В `/etc/litellm/config.yaml` нужны два блока:

- `router_settings.redis_*` — состояние роутера (cooldowns, usage-based routing);
- `litellm_settings.cache` + `cache_params` — ответный кэш и вся прокси-координация (rate limits, бюджеты, инвалидация кэша ключей).

Настроены должны быть оба. Открываем конфиг:

```bash
sudo nano /etc/litellm/config.yaml
```

и дополняем (переменные берутся из env-файла через `os.environ/`):

```yaml
router_settings:
  redis_host: os.environ/REDIS_HOST
  redis_port: os.environ/REDIS_PORT
  redis_password: os.environ/REDIS_PASSWORD

litellm_settings:
  # ...уже существующие настройки (drop_params, request_timeout и т.д.)...
  cache: true
  cache_params:
    type: redis
    host: os.environ/REDIS_HOST
    port: os.environ/REDIS_PORT
    password: os.environ/REDIS_PASSWORD
    namespace: "litellm"   # все ключи получат префикс litellm:
    ttl: 600               # кэшировать ответы на 10 минут
    # supported_call_types: []
    #   ^ раскомментируйте, если НЕ нужен кэш ответов LLM,
    #     но нужна общая координация (rate limits, бюджеты, cooldowns)
```

Пояснения:

- `type: redis` — точный кэш (exact-match): ключ — хеш полного запроса, одинаковый запрос повторно не дёргает LLM в течение `ttl`. Для агентных/multi-turn сценариев это безопасно, в отличие от семантического кэша.
- `namespace: "litellm"` — полезен всегда: ключи видны в `valkey-cli` с префиксом и не путаются с чужими данными, если Valkey когда-нибудь станет общим.
- `ttl` — время жизни кэшированного ответа в секундах; при `ttl: 600` закомментируйте или уберите `supported_call_types: []`.
- Если хотите вообще без кэша ответов — оставьте `supported_call_types: []`, координация (лимиты, бюджеты) продолжит работать.

Проверка синтаксиса перед перезапуском:

```bash
sudo /opt/litellm/venv/bin/python -c "import yaml;yaml.safe_load(open('/etc/litellm/config.yaml'))" && echo OK
```

## 6. Ручная проверка

Перезапускаем litellm (правились и env, и конфиг — нужен рестарт сервиса) и смотрим логи:

```bash
sudo systemctl restart litellm
sudo journalctl -u litellm -f
```

Признак успеха в логах при старте — строка о подключении Redis-кэша, без ошибок `NOAUTH`/`Connection refused`. Проверяем `/cache/ping`:

Важно: env-файл принадлежит `root:litellm` с правами `640`, поэтому `source` от обычного пользователя упадёт с `Permission denied` — проверки запускаем через `sudo bash -c`:

```bash
sudo bash -c 'set -a; source /etc/litellm/litellm.env; set +a; \
curl -s http://127.0.0.1:4000/cache/ping -H "Authorization: Bearer ${LITELLM_MASTER_KEY}"'
```

Ожидаем в ответе:

```json
{"status":"healthy","cache_type":"redis","ping_response":true,...}
```

Проверяем обычный путь — модели и чат:

```bash
sudo bash -c 'set -a; source /etc/litellm/litellm.env; set +a; \
curl -s http://127.0.0.1:4000/v1/models -H "Authorization: Bearer ${LITELLM_MASTER_KEY}"; \
echo; \
curl -s http://127.0.0.1:4000/v1/chat/completions \
  -H "Content-Type: application/json" -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -d "{\"model\":\"corp-llm\",\"messages\":[{\"role\":\"user\",\"content\":\"Привет\"}]}"'
```

Смотрим, что ключи реально появились в Valkey (с префиксом namespace):

```bash
sudo bash -c 'set -a; source /etc/litellm/litellm.env; set +a; \
valkey-cli -h ${REDIS_HOST} -p ${REDIS_PORT} -a ${REDIS_PASSWORD} --no-auth-warning keys "litellm:*" | head'
```

И контрольный тест кэша: два одинаковых запроса подряд — во втором ответе заголовок `x-litellm-cache-key` будет присутствовать и ответ вернётся быстрее:

```bash
sudo bash -c 'set -a; source /etc/litellm/litellm.env; set +a; \
curl -si http://127.0.0.1:4000/v1/chat/completions \
  -H "Content-Type: application/json" -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -d "{\"model\":\"corp-llm\",\"messages\":[{\"role\":\"user\",\"content\":\"Тест кэша\"}]}" \
  | grep -i x-litellm-cache-key'
```

## 7. Автозапуск и порядок старта

Оба сервиса уже в автозапуске. Сеть поднимается раньше litellm (`After=network-online.target`), а Redis-клиент LiteLLM умеет переподключаться, поэтому порядок старта не критичен. Если хотите строгую гарантию, добавьте в `/etc/systemd/system/litellm.service`:

```ini
[Unit]
After=network-online.target valkey-server.service
```

и выполните:

```bash
sudo systemctl daemon-reload
sudo systemctl restart litellm
```

## Типовые поломки

| Симптом | Что проверить |
|---|---|
| `source /etc/litellm/litellm.env`: `Permission denied` | Файл имеет права `640 root:litellm` — проверки запускаются через `sudo bash -c` |
| В логах litellm `NOAUTH` / `Authentication required` | Пароль в `REDIS_PASSWORD` (litellm.env) не задан или не совпадает с `requirepass` в `/etc/valkey/valkey.conf`; после правки env — `sudo systemctl restart litellm` |
| `Connection refused` / `Error connecting to Redis` | `systemctl status valkey-server`; сервис слушает `127.0.0.1:6379` (`ss -tlnp \| grep 6379`) |
| `/cache/ping` отдаёт ошибку или `ping_response: false` | Смотрите логи `sudo journalctl -u litellm -n 50`; пароль и host/port в двух блоках config.yaml должны быть одинаковыми |
| Banner «no Redis» в Admin UI ([06_ui.md](06_ui.md)) | В config.yaml нет блока `router_settings.redis_*` / `cache` — только переменные окружения недостаточны |
| Изменили `requirepass` — litellm стал отвечать 500-ми | Обновите `REDIS_PASSWORD` в litellm.env и перезапустите `litellm`; старые соединения умирают не сразу |
| `valkey-cli ping` без `-a` отвечает `NOAUTH` | Это норма после настройки пароля, а не поломка |
| Кэш «не работает» — повторные запросы медленные | Убедитесь, что запросы байт-в-байт одинаковы (exact-match), и что `supported_call_types: []` не отключил кэш ответов; проверьте заголовок `x-litellm-cache-key` |
| `No permissions to access a channel` в логах | Используется ACL-пользователь без прав на pub/sub (`&*` / `&litellm:*`); для default-пользователя с `requirepass` не встречается |

## Короткий чеклист

1. `sudo apt update && sudo apt install -y valkey-server`
2. `systemctl status valkey-server` — активен; `valkey-cli ping` → PONG.
3. `openssl rand -hex 32`; вписать `requirepass <пароль>` в `/etc/valkey/valkey.conf`; `sudo systemctl restart valkey-server`; `valkey-cli -a <пароль> ping` → PONG.
4. Добавить `REDIS_HOST`, `REDIS_PORT`, `REDIS_PASSWORD` в `/etc/litellm/litellm.env`.
5. Добавить в `/etc/litellm/config.yaml` блоки `router_settings.redis_*` и `litellm_settings.cache` + `cache_params` (оба блока обязательны).
6. `sudo systemctl restart litellm` и `sudo journalctl -u litellm -f` — без ошибок Redis.
7. `curl /cache/ping` → `"status":"healthy","cache_type":"redis"`.
8. `curl /v1/chat/completions` → обычный ответ модели; ключи с префиксом `litellm:` видны в `valkey-cli keys`.
