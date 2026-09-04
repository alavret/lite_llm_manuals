Docker-версия гайда [06_ui.md](06_ui.md): включаем встроенный Admin UI (веб-интерфейс) в установку LiteLLM в Docker — по [01d_setup_litellm.md](01d_setup_litellm.md), nginx — по [05d_nginx.md](05d_nginx.md). PostgreSQL поднимается тоже в Docker, как соседний контейнер.

Симптом, который лечим: при входе в UI по адресу `https://litellm.domain.com/ui` (или `http://IP_UBUNTU:4000/ui`) браузер показывает:

```text
Authentication Error
Not connected to DB!
```

Причина: Admin UI требует два условия (см. https://docs.litellm.ai/docs/proxy/ui):

1. задан `master_key` — у вас уже есть (`LITELLM_MASTER_KEY`);
2. к прокси подключена база данных PostgreSQL — её пока нет.

UI хранит в БД пользователей, виртуальные ключи, бюджеты и статистику расходов, поэтому без БД он не работает.

Хорошая новость Docker-варианта: **весь раздел про Prisma из venv-версии (`prisma generate`, `prisma db push`, патч `_write_engine`) здесь не нужен** — Prisma-клиент и бинарники уже внутри образа, и при старте контейнер сам применяет схему БД.

Схема после выполнения инструкции:

```text
Браузер
    →  https://litellm.domain.com/ui   (nginx :443, TLS)
    →  http://litellm:4000/ui          (LiteLLM Proxy + Admin UI, контейнер)
    →  http://db:5432                  (PostgreSQL, контейнер, только сеть Docker)

GUI-клиенты (Chatbox и т.п.)
    →  https://litellm.domain.com/v1   (как раньше, ничего не меняется)
```

---

## 1. Что понадобится

- LiteLLM в Docker по [01d_setup_litellm.md](01d_setup_litellm.md)
- ~100 МБ диска под PostgreSQL

Проверка текущего состояния (до изменений):

```bash
curl -sS http://127.0.0.1:4000/health/readiness -H "Authorization: Bearer $LITELLM_MASTER_KEY"
```

Прокси отвечает — идём дальше.

---

## 2. Сервис PostgreSQL в docker-compose.yml

Откройте `/opt/litellm/docker-compose.yml` и приведите к виду (добавляется сервис `db`, у `litellm` — `depends_on`):

```yaml
services:
  litellm:
    image: ghcr.io/berriai/litellm:main-stable
    container_name: litellm
    restart: unless-stopped
    ports:
      - "127.0.0.1:4000:4000"
    env_file:
      - litellm.env
    environment:
      STORE_MODEL_IN_DB: "True"     # модели из UI сохраняются в БД; также включает автомиграции при старте
    volumes:
      - ./config.yaml:/app/config.yaml:ro
      # если подключали guardrails (02d), оставьте и их:
      # - ./guardrails:/app/custom:ro
    command: ["--config=/app/config.yaml", "--port", "4000"]
    depends_on:
      db:
        condition: service_healthy  # ждать готовности БД
    healthcheck:
      test:
        - CMD-SHELL
        - python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:4000/health/liveliness')"
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    networks:
      - litellm-net

  db:
    image: postgres:16
    container_name: litellm_db
    restart: unless-stopped
    environment:
      POSTGRES_DB: litellm
      POSTGRES_USER: litellm
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}   # из litellm.env
    volumes:
      - postgres_data:/var/lib/postgresql/data
    # порт 5432 наружу НЕ публикуем: БД доступна только внутри Docker-сети
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -d litellm -U litellm"]
      interval: 5s
      timeout: 5s
      retries: 10
    networks:
      - litellm-net

networks:
  litellm-net:
    name: litellm-net

volumes:
  postgres_data:
```

> Сеть `litellm-net` здесь объявлена с фиксированным именем — так её подключают compose-проекты Presidio ([04d_add_presidio.md](04d_add_presidio.md)) и nginx ([05d_nginx.md](05d_nginx.md)). Если они уже работают, ничего в блоке `networks` менять не нужно.

---

## 3. Пароль БД

Сгенерируйте пароль:

```bash
openssl rand -hex 24
```

Пользователь и база создаются автоматически при **первом** старте контейнера `db` из переменных `POSTGRES_USER` / `POSTGRES_DB` / `POSTGRES_PASSWORD` — psql и `CREATE USER` из venv-версии не нужны.

Пароль пока просто сохраните — добавим его в `litellm.env` в разделе 4.

Проверка после старта (раздел 7):

```bash
docker compose exec db pg_isready -d litellm -U litellm
# /var/run/postgresql:5432 - accepting connections
```

---

## 4. Переменные окружения

Откройте `/opt/litellm/litellm.env` и добавьте (существующие не трогаем):

```bash
# Подключение к PostgreSQL для Admin UI / виртуальных ключей / бюджетов.
# Хост — имя сервиса db из docker-compose.yml, НЕ 127.0.0.1:
# внутри контейнера LiteLLM это был бы сам LiteLLM.
DATABASE_URL=postgresql://litellm:ВАШ_ПАРОЛЬ_БД@db:5432/litellm

# Соль для шифрования ключей провайдеров, добавляемых через UI.
# Сгенерируйте один раз: openssl rand -base64 32
# ВАЖНО: после первого использования никогда не меняйте —
# ключи, зашифрованные старым значением, станет невозможно расшифровать.
LITELLM_SALT_KEY=СТРОКА_ИЗ_openssl_rand_base64_32

# Логин и пароль для входа в Admin UI (https://docs.litellm.ai/docs/proxy/ui).
# Без них вход по умолчанию: admin / LITELLM_MASTER_KEY.
# Имя можно оставить admin, пароль задайте свой — отдельный от мастер-ключа:
UI_USERNAME=admin
UI_PASSWORD=ОТДЕЛЬНЫЙ_ПАРОЛЬ_ДЛЯ_UI
```

Генерации:

```bash
# соль для LITELLM_SALT_KEY
openssl rand -base64 32

# пароль для UI_PASSWORD
openssl rand -base64 18
```

Пароль для UI не совпадает с `LITELLM_MASTER_KEY` намеренно: мастер-ключ ходит в API-маршруты, а этот — только в веб-форму входа.

---

## 5. Правка config.yaml

Откройте `/opt/litellm/config.yaml`. В `general_settings` добавьте `database_url` (в остальном конфиг не меняется — ваши модели из `model_list` продолжат работать и появятся в UI):

```yaml
model_list:
  - model_name: corp-llm
    litellm_params:
      model: openai/gemma-4-31b-it
      api_base: https://gpt.mwsapis.ru/projects/alavret/openai/v1/
      api_key: os.environ/CUSTOM_LLM_TOKEN
      timeout: 120
      stream_timeout: 120

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  database_url: os.environ/DATABASE_URL

litellm_settings:
  drop_params: true
  request_timeout: 120
```

| Поле | Зачем |
|---|---|
| `database_url` | включает Admin UI, виртуальные ключи, бюджеты, spend tracking |
| `LITELLM_SALT_KEY` (env) | шифрует ключи провайдеров, которые добавляете через UI |

Опционально — управление моделями прямо из UI без правки `config.yaml`. Вместо правки `litellm_settings` в конфиге достаточно переменной в `docker-compose.yml` (уже добавлена в разделе 2):

```yaml
      STORE_MODEL_IN_DB: "True"   # модели из UI сохраняются в БД, конфиг не правится
```

---

## 6. Таблицы Prisma: в Docker ничего делать не нужно

При установке через `pip` (venv-версия гайда) требовались `pip install prisma`, `prisma generate`, патч и `prisma db push`. В Docker-образе LiteLLM Prisma-клиент, бинарники и схема уже есть, а при старте контейнера с заданным `DATABASE_URL` LiteLLM **сам** применяет миграции.

Как это выглядит в `docker compose logs litellm` при успешном старте:

```text
Prisma schema loaded from prisma/schema.prisma
Applying migration ...
Your database is now in sync with your Prisma schema.
```

Единственное условие — сервис `db` должен быть здоров к моменту старта LiteLLM: за это отвечает `depends_on: condition: service_healthy` из раздела 2.

---

## 7. Запуск

Менялись и compose, и `litellm.env`, и `config.yaml` — пересоздание:

```bash
cd /opt/litellm
docker compose up -d
docker compose logs -f litellm
```

Старт занимает 10–60 секунд (при первом старте `db` создаёт базу, затем LiteLLM применяет схему). Успешный старт:

```text
Application startup complete.
Uvicorn running on http://0.0.0.0:4000 (Press CTRL+C to quit)
```

Не пугайтесь такого шума в журнале (это нормально):

- `Unable to connect to DB. DATABASE_URL found in environment, but pri...` — появляется в самом начале старта, до инициализации подключения; бывает и при полностью рабочей БД;
- `401 ... No api key passed in` — чей-то запрос без ключа (сканеры, health-проверки снаружи);
- `Error: Decryption failed. Ciphertext failed verification` + `Set permanent salt key` — кто-то передал в `Authorization` не-virtual-key (например, JWT или чужой токен), litellm попытался расшифровать его как ключ БД и не смог.

Проверьте health (readiness включает статус БД):

```bash
bash -c '
  set -a
  source /opt/litellm/litellm.env
  set +a
  curl -sS http://127.0.0.1:4000/health/readiness -H "Authorization: Bearer ${LITELLM_MASTER_KEY}"
'
```

И что API-маршрут не сломался:

```bash
curl -sS http://127.0.0.1:4000/v1/models -H "Authorization: Bearer ${LITELLM_MASTER_KEY}"
```

Должен вернуться список с `corp-llm`.

---

## 8. Вход в UI

Откройте в браузере:

```text
https://litellm.domain.com/ui      # если настроен nginx (05d_nginx.md)
http://IP_UBUNTU:4000/ui           # если заходите напрямую
```

Данные для входа по умолчанию (если в разделе 4 не заданы `UI_USERNAME`/`UI_PASSWORD`):

| Поле | Значение |
|---|---|
| Username | `admin` |
| Password | значение `LITELLM_MASTER_KEY` (целиком, с префиксом `sk-litellm-`) |

nginx из [05d_nginx.md](05d_nginx.md) уже проксирует все пути, включая `/ui`, — отдельная настройка не нужна.

Как это работает: без сессии `/ui` перенаправляет на страницу логина; форма отправляет `POST /v2/login`, при успехе в БД создаётся/обновляется пользователь `admin` и выдаётся JWT-сессия (если первый вход — в журнале появятся строки про вставку в User Table, это нормально).

Если вы задали в разделе 4 `UI_USERNAME`/`UI_PASSWORD` (рекомендуется, чтобы не логиниться мастер-ключом) — используйте их. Смена позже: правьте эти строки в `/opt/litellm/litellm.env` и пересоздайте контейнер (`docker compose up -d`, `restart` не перечитывает `env_file`).

После входа доступны:

- **Models** — список моделей из `config.yaml` (и добавление новых через UI при `STORE_MODEL_IN_DB=True`);
- **Virtual Keys** — выпуск отдельных ключей для пользователей/приложений с бюджетами и лимитами вместо раздачи мастер-ключа;
- **Usage / Spend** — статистика запросов и расходов;
- **Logs** — лог запросов с задержками и токенами;
- **Playground** — тестовые запросы к моделям прямо из браузера.

---

## 9. Что меняется для клиентов

Ничего. GUI-клиенты продолжают ходить в `https://litellm.domain.com/v1` с `LITELLM_MASTER_KEY` и моделью `corp-llm`.

Рекомендация: после появления UI заведите в **Virtual Keys** отдельный ключ для GUI-клиента и перейдите на него вместо мастер-ключа — так у ключа будут свои лимиты/бюджет, а мастер-ключ останется только для администрирования.

---

## 10. Бэкап

Теперь бэкапьте (в дополнение к [01d_setup_litellm.md](01d_setup_litellm.md)):

- дамп БД из контейнера:
  ```bash
  cd /opt/litellm
  docker compose exec -T db pg_dump -U litellm litellm > litellm_$(date +%F).sql
  ```
  Восстановление: `cat litellm_ГГГГ-ММ-ДД.sql | docker compose exec -T db psql -U litellm litellm`
- `/opt/litellm/litellm.env` — в нём теперь и пароль БД, и `LITELLM_SALT_KEY` (потеря соли = потеря расшифровки ключей, добавленных через UI).

**Осторожно:** `docker compose down -v` удаляет именованный том `postgres_data` вместе со всеми данными UI (ключи, пользователи, статистика). Для простого рестарта используйте `docker compose restart` или `docker compose down` (без `-v`).

---

## 11. Типовые проблемы

| Симптом | Причина / решение |
|---|---|
| `Authentication Error, Not connected to DB!` | `DATABASE_URL` не задан или БД недоступна; проверьте разделы 2–5 и `docker compose logs litellm` |
| В `DATABASE_URL` хост `127.0.0.1` | так подключиться нельзя — `127.0.0.1` внутри контейнера это сам LiteLLM; хост должен быть `db` (раздел 4) |
| В журнале повторяется `TableNotFoundError: LiteLLM_Config` (и т.п.) | миграции не применились: убедитесь, что `DATABASE_URL` доходит до контейнера и `db` healthy (`docker compose ps`); в Docker-образе litellm применяет схему сам |
| `error: database "litellm" does not exist` / `role "litellm" does not exist` | база инициализировалась с другими `POSTGRES_*` значениями (или том от старых попыток); проверьте env сервиса `db` и, если данных нет, `docker compose down -v` и старт заново |
| Контейнер `db` перезапускается | `docker compose logs db`; чаще конфликт пароля: у существующего тома пароль от первой инициализации, `POSTGRES_PASSWORD` его не меняет |
| `Error: Decryption failed. Ciphertext failed verification` + `Set permanent salt key` | в `Authorization` передан не виртуальный ключ (например, JWT или случайный токен) — сам по себе не ошибка; если повторяется от ваших клиентов, они шлют не тот токен. `LITELLM_SALT_KEY` при этом не меняйте (раздел 4) |
| Логин `admin` + мастер-ключ не принимается | вводите ключ целиком с префиксом `sk-`; если заданы `UI_USERNAME`/`UI_PASSWORD` — используются они |
| Служба падает на старте после добавления БД | `docker compose logs litellm`; чаще всего опечатка в `DATABASE_URL` или пароле |
| В UI не видны модели из `config.yaml` | это нормально для моделей, объявленных в конфиге; включите `STORE_MODEL_IN_DB: "True"`, чтобы управлять моделями из UI |
| UI открылся, но «Test» у модели падает | проверьте `CUSTOM_LLM_TOKEN` и доступность `api_base` с хоста (см. раздел 11 в [01d_setup_litellm.md](01d_setup_litellm.md)) |
| Первый старт долго висит | `docker compose logs -f litellm`; первый старт дольше из-за инициализации БД и применения схемы |
| UI нужно выключить | `DISABLE_ADMIN_UI=True` в `/opt/litellm/litellm.env` + `docker compose up -d` |
| Правили `litellm.env`, но поведение старое | `env_file` читается только при создании контейнера — нужен `docker compose up -d`, не `restart` |

---

## Короткий чеклист

1. В `/opt/litellm/docker-compose.yml` добавить сервис `db` (postgres:16) и `depends_on: service_healthy`, volume `postgres_data`.
2. Сгенерировать пароль БД, вписать его в `DATABASE_URL` (хост `db`), `LITELLM_SALT_KEY` и `UI_USERNAME`/`UI_PASSWORD` в `litellm.env`.
3. В `config.yaml` в `general_settings` добавить `database_url: os.environ/DATABASE_URL` (опционально `STORE_MODEL_IN_DB: "True"` в compose).
4. `docker compose up -d` — Prisma-миграции в Docker-образе применяются сами, prisma-шаги из venv-версии не нужны.
5. Дождаться `Application startup complete` в `docker compose logs litellm`.
6. Зайти на `https://litellm.domain.com/ui`: логин/пароль из `UI_USERNAME`/`UI_PASSWORD` (по умолчанию `admin` / `LITELLM_MASTER_KEY`).
7. Выпустить виртуальный ключ для GUI-клиентов и перевести их с мастер-ключа на него.
