Docker-версия гайда [07_valkey.md](07_valkey.md): тот же результат — общее состояние LiteLLM (rate limits, бюджеты, cooldown'ы, кэш ответов и виртуальных ключей) вынесено в Redis-совместимую БД Valkey, — но Valkey запускается не системным пакетом, а контейнером в общем `docker-compose.yml` с LiteLLM из [01d_setup_litellm.md](01d_setup_litellm.md).

Отличия от venv-варианта:

- Valkey живёт в той же docker-сети `litellm-net`, что и LiteLLM, наружу **не публикуется вовсе** — порт 6379 доступен только контейнерам внутри сети;
- данные кэша хранятся в docker-томе, переживают рестарты контейнера;
- правка env/compose требует `docker compose up -d` (а не `restart`) — см. таблицу правил в конце.

Схема:

```
клиент ──> nginx ──> litellm (контейнер, :4000) ──> LLM API (gpt.mwsapis.ru)
                          │        │
                          │        └── docker-сеть litellm-net
                          └──────────> valkey (контейнер, 6379, requirepass)
                                          ↑ volume valkey-data
                                            общее состояние: rate limits,
                                            бюджеты, cooldowns, кэш ключей и ответов
```

## 1. Что понадобится

- VM из [01d_setup_litellm.md](01d_setup_litellm.md): Ubuntu 24.04, Docker Engine + плагин compose, LiteLLM-стек в `/opt/litellm` (`docker-compose.yml`, `config.yaml`, `litellm.env`) и работает.
- Права `sudo` (только если Docker не настроен на работу без sudo).
- Valkey добавляется **к уже существующему** compose-стеку как ещё один сервис.

## 2. Пароль Valkey

Генерируем пароль:

```bash
openssl rand -hex 32
```

## 3. Секреты

Добавляем переменные в `/opt/litellm/litellm.env` (файл уже существует из [01d_setup_litellm.md](01d_setup_litellm.md), там же лежат `LITELLM_MASTER_KEY` и `CUSTOM_LLM_TOKEN`):

```bash
nano /opt/litellm/litellm.env
```

```ini
# адрес Valkey ВНУТРИ docker-сети — имя сервиса из docker-compose.yml
REDIS_HOST=valkey
REDIS_PORT=6379
REDIS_PASSWORD=<пароль из шага 2>

# тот же пароль нужен контейнеру valkey (см. docker-compose.yml)
VALKEY_PASSWORD=<пароль из шага 2>
```

Важно:

- `REDIS_HOST=valkey` — это DNS-имя контейнера в сети `litellm-net`, а не `127.0.0.1` (внутри контейнера litellm loopback — это он сам).
- Сами по себе переменные `REDIS_*` ничего не включают — LiteLLM читает их только когда конфиг указывает на Redis (см. шаг 5).
- Файл должен оставаться читаемым вашим пользователем: `chmod 600 /opt/litellm/litellm.env` (владелец — `$USER`, как в [01d_setup_litellm.md](01d_setup_litellm.md)).

## 4. docker-compose.yml: сервис valkey

```bash
nano /opt/litellm/docker-compose.yml
```

Добавляем сервис `valkey` и том; у сервиса `litellm` появляется `depends_on`:

```yaml
services:
  litellm:
    image: ghcr.io/berriai/litellm:main-stable
    container_name: litellm
    restart: unless-stopped
    ports:
      - "127.0.0.1:4000:4000"   # как было в 01d (или "4000:4000")
    env_file:
      - litellm.env
    volumes:
      - ./config.yaml:/app/config.yaml:ro
    command: ["--config=/app/config.yaml", "--port", "4000"]
    healthcheck:
      test:
        - CMD-SHELL
        - python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:4000/health/liveliness')"
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    depends_on:
      valkey:
        condition: service_healthy   # litellm стартует после готовности valkey
    networks:
      - litellm-net

  valkey:
    image: valkey/valkey:8.1-alpine
    container_name: valkey
    restart: unless-stopped
    env_file:
      - litellm.env
    # пароль подставляется шеллом ВНУТРИ контейнера из env_file;
    # двойной $$ нужен, чтобы compose не пытался подставить его сам на хосте
    command: ["sh", "-c", "exec valkey-server --requirepass \"$$VALKEY_PASSWORD\""]
    volumes:
      - valkey-data:/data
    healthcheck:
      test:
        - CMD-SHELL
        - valkey-cli -a "$$VALKEY_PASSWORD" --no-auth-warning ping | grep -q PONG
      interval: 10s
      timeout: 3s
      retries: 5
    networks:
      - litellm-net
    # ports для valkey НЕ публикуем: снаружи он не нужен.
    # Помните: Docker обходит UFW, так что «спрятать» порт через ufw deny нельзя —
    # самый надёжный вариант — просто не публиковать.

volumes:
  valkey-data:

networks:
  litellm-net:
    name: litellm-net
```

Пояснения:

| Поле | Зачем |
|---|---|
| `image: valkey/valkey:8.1-alpine` | официальный образ Valkey; зафиксирован мажор `8.1` — обновления внутри мажора приходят с `docker compose pull` |
| `command: sh -c ...` | пароль берётся из env-файла внутри контейнера; дублировать его в compose-файле не нужно |
| `volumes: valkey-data:/data` | кэш переживает рестарт и пересоздание контейнера |
| `depends_on: condition: service_healthy` | litellm не стартует раньше, чем valkey примет соединения |
| нет `ports` у valkey | 6379 доступен только внутри `litellm-net`; Docker публикует порты через iptables в обход UFW, поэтому «не публиковать» — единственный надёжный вариант |

Проверка синтаксиса:

```bash
docker compose config --quiet && echo OK
```

## 5. Конфиг litellm

В `/opt/litellm/config.yaml` нужны два блока — `router_settings.redis_*` (состояние роутера: cooldowns, usage-based routing) и `litellm_settings.cache` + `cache_params` (ответный кэш и вся прокси-координация: rate limits, бюджеты, инвалидация кэша ключей). Настроены должны быть оба. Конфиг тот же, что в venv-варианте [07_valkey.md](07_valkey.md):

```bash
nano /opt/litellm/config.yaml
```

Дополняем (переменные берутся из env-файла через `os.environ/`):

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

Пояснения — см. раздел 5 в [07_valkey.md](07_valkey.md): `type: redis` — безопасный exact-match кэш, `namespace` удобен для просмотра ключей, `ttl` — время жизни ответа в секундах.

## 6. Запуск и проверка

Менялись и env, и compose-файл, и конфиг — пересоздаём контейнеры:

```bash
cd /opt/litellm
docker compose up -d
docker compose ps
```

Оба контейнера должны стать `healthy`. Смотрим журнал litellm:

```bash
docker compose logs -f litellm
```

Признак успеха — строка о подключении Redis-кэша при старте, без ошибок `NOAUTH` / `Connection refused`.

Проверяем healthcheck и доступ к valkey:

```bash
docker compose exec valkey valkey-cli -a "$(grep VALKEY_PASSWORD litellm.env | cut -d= -f2)" --no-auth-warning ping
```

Ожидаем `PONG` (до этой команды `valkey-cli ping` без пароля отвечает `NOAUTH` — это норма).

Проверяем кэш через litellm (env-файл в docker-варианте принадлежит вашему пользователю, `sudo` не нужен):

```bash
bash -c 'set -a; source /opt/litellm/litellm.env; set +a; \
curl -s http://127.0.0.1:4000/cache/ping -H "Authorization: Bearer ${LITELLM_MASTER_KEY}"'
```

Ожидаем:

```json
{"status":"healthy","cache_type":"redis","ping_response":true,...}
```

Обычный путь — модели и чат:

```bash
bash -c 'set -a; source /opt/litellm/litellm.env; set +a; \
curl -s http://127.0.0.1:4000/v1/models -H "Authorization: Bearer ${LITELLM_MASTER_KEY}"; \
echo; \
curl -s http://127.0.0.1:4000/v1/chat/completions \
  -H "Content-Type: application/json" -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -d "{\"model\":\"corp-llm\",\"messages\":[{\"role\":\"user\",\"content\":\"Привет\"}]}"'
```

Контрольный тест кэша — два одинаковых запроса подряд, во втором ответе есть заголовок `x-litellm-cache-key` и ответ возвращается быстрее:

```bash
bash -c 'set -a; source /opt/litellm/litellm.env; set +a; \
curl -si http://127.0.0.1:4000/v1/chat/completions \
  -H "Content-Type: application/json" -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
  -d "{\"model\":\"corp-llm\",\"messages\":[{\"role\":\"user\",\"content\":\"Тест кэша\"}]}" \
  | grep -i x-litellm-cache-key'
```

И смотрим, что ключи появились в valkey (с префиксом namespace):

```bash
docker compose exec valkey valkey-cli -a "$(grep VALKEY_PASSWORD litellm.env | cut -d= -f2)" \
  --no-auth-warning keys "litellm:*" | head
```

## 7. Правила применения изменений

| Что поменяли | Команда |
|---|---|
| `config.yaml` | `docker compose restart litellm` |
| `litellm.env` или `docker-compose.yml` | `docker compose up -d` (пересоздаёт контейнер; простой `restart` новые env **не подхватит**) |
| пароль `requirepass` внутри valkey (из `VALKEY_PASSWORD`) | `docker compose up -d` — и обновите `REDIS_PASSWORD` в env; старые соединения litellm умирают не сразу |

## 8. Обновление и бэкап

Обновление вместе с остальным стеком:

```bash
cd /opt/litellm
docker compose pull
docker compose up -d
docker image prune -f
```

Кэш — эфемерная вещь: том `valkey-data` бэкапить не нужно, при желании его можно просто сбросить:

```bash
docker compose down   # контейнеры остановлены, том остаётся
docker volume rm litellm_valkey-data   # полный сброс кэша
```

(перед `rm` тома убедитесь, что litellm остановлен: `docker compose down` уже сделал это).

Бэкапить по-прежнему нужно только `/opt/litellm/config.yaml`, `/opt/litellm/litellm.env` и свои guardrail-скрипты (см. [02d_add_custom_code_guardrails.md](02d_add_custom_code_guardrails.md)).

## Типовые поломки

| Симптом | Что проверить |
|---|---|
| litellm в цикле рестартов, в логах `Error connecting to Redis` | valkey не поднялся: `docker compose ps` (статус должен быть `healthy`), `docker compose logs valkey` |
| В логах litellm `NOAUTH` / `Authentication required` | `REDIS_PASSWORD` (litellm.env) не совпадает с `VALKEY_PASSWORD`; оба лежат в одном файле и должны быть одинаковыми; после правки — `docker compose up -d` (не `restart`) |
| `Name or service not known` / `valkey` не резолвится | Оба сервиса в одной сети `litellm-net`; `docker network inspect litellm-net` |
| `/cache/ping` отдаёт ошибку или `ping_response: false` | `docker compose logs litellm`; блоки `router_settings` и `cache_params` в config.yaml должны указывать на одни и те же host/port/password |
| Banner «no Redis» в Admin UI ([06d_ui.md](06d_ui.md)) | В config.yaml нет блоков `router_settings.redis_*` / `cache` — только переменные окружения недостаточны |
| Изменили `VALKEY_PASSWORD` — litellm отвечает 500-ми | Обновите и `REDIS_PASSWORD`, и `VALKEY_PASSWORD`, затем `docker compose up -d` — пересоздаст оба контейнера |
| `valkey-cli ping` внутри контейнера без `-a` отвечает `NOAUTH` | Это норма после настройки пароля, а не поломка |
| Кэш «не работает» — повторные запросы медленные | Запросы должны быть байт-в-байт одинаковы (exact-match); проверьте, что `supported_call_types: []` не отключил кэш ответов; смотрите заголовок `x-litellm-cache-key` |
| `No permissions to access a channel` в логах | Используется ACL-пользователь без прав на pub/sub (`&*` / `&litellm:*`); для default-пользователя с `requirepass` не встречается |
| Пробовали закрыть 6379 через `ufw deny` | Бесполезно: Docker обходит UFW. Порт 6379 не должен быть опубликован в `ports:` вовсе |

## Короткий чеклист

1. `openssl rand -hex 32` — пароль Valkey.
2. Добавить в `/opt/litellm/litellm.env`: `REDIS_HOST=valkey`, `REDIS_PORT=6379`, `REDIS_PASSWORD=<пароль>`, `VALKEY_PASSWORD=<тот же пароль>`.
3. Добавить сервис `valkey` (образ `valkey/valkey:8.1-alpine`, том `valkey-data`, healthcheck, без `ports`) и `depends_on` у litellm в `docker-compose.yml`; `docker compose config --quiet` → OK.
4. Дописать в `/opt/litellm/config.yaml` блоки `router_settings.redis_*` и `litellm_settings.cache` + `cache_params` (оба обязательны).
5. `docker compose up -d` (env и compose менялись — именно `up -d`, не `restart`); оба контейнера `healthy`.
6. `curl /cache/ping` → `"status":"healthy","cache_type":"redis"`.
7. `curl /v1/chat/completions` → обычный ответ модели; ключи с префиксом `litellm:` видны в `docker compose exec valkey valkey-cli -a ... keys "litellm:*"`.
