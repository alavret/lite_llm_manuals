Docker-версия гайда [01_setup_litellm.md](01_setup_litellm.md): тот же сценарий — **Ubuntu**, **GUI на локальной станции**, **одна модель с custom URL + token**, — но LiteLLM работает в Docker-контейнере вместо venv и systemd. Клиент ходит только в LiteLLM, реальный endpoint и токен модели GUI не видит.

Docker-версии остальных гайдов: [02d_add_custom_code_guardrails.md](02d_add_custom_code_guardrails.md), [03d_debug_requests.md](03d_debug_requests.md), [04d_add_presidio.md](04d_add_presidio.md), [05d_nginx.md](05d_nginx.md), [06d_ui.md](06d_ui.md).

Схема:

```text
GUI (локальная станция)
    →  http(s)://<ubuntu-host>:4000/v1
    →  LiteLLM Proxy (контейнер)
    →  https://<custom-url>  + token провайдера
```

---

## 1. Установка Docker

Если Docker уже установлен — проверьте версию (`docker version`, нужен движок 24+) и плагин compose (`docker compose version`); если оба работают, переходите к разделу 2.

### 1.1. Установка Docker Engine на Ubuntu

Ставим из официального репозитория Docker (не из `docker.io`-репозитория Ubuntu — там старые версии и нет плагина compose):

```bash
# удалить старые пакеты, если были
sudo apt remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true

# зависимости и GPG-ключ репозитория Docker
sudo apt update
sudo apt install -y ca-certificates curl gnupg
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# подключить репозиторий
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# установка движка + CLI + плагин compose
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# автозапуск
sudo systemctl enable --now docker
```

### 1.2. Работа без sudo

По умолчанию `docker` требует root. Добавьте своего пользователя в группу `docker`:

```bash
sudo usermod -aG docker $USER
```

Перелогиньтесь (или выполните `newgrp docker`), затем проверьте:

```bash
docker ps
```

### 1.3. Проверка

```bash
docker run --rm hello-world
docker compose version
```

`docker run --rm hello-world` должен скачать тестовый образ и вывести «Hello from Docker!», а `docker compose version` — версию плагина (например, `Docker Compose version v2.3x.x`).

Если standalone `docker-compose` (первой версии) уже стоит, а плагина нет — гайды используют синтаксис `docker compose` (без дефиса), поставьте `docker-compose-plugin` по инструкции выше.

---

## 2. Каталог и файлы

В отличие от venv-варианта, системный пользователь `litellm` и venv **не нужны** — изоляцию обеспечивает контейнер. На хосте достаточно каталога с тремя файлами:

```bash
sudo mkdir -p /opt/litellm
sudo chown $USER:$USER /opt/litellm
```

В `/opt/litellm` будут лежать:

| Файл | Назначение |
|---|---|
| `docker-compose.yml` | описание контейнера |
| `config.yaml` | конфиг LiteLLM (модели, guardrails) |
| `litellm.env` | секреты (токены), читается через `env_file` |

---

## 3. docker-compose.yml

```bash
nano /opt/litellm/docker-compose.yml
```

Минимальный вариант без БД (Admin UI добавляется в [06d_ui.md](06d_ui.md)):

```yaml
services:
  litellm:
    image: ghcr.io/berriai/litellm:main-stable
    container_name: litellm
    restart: unless-stopped
    ports:
      - "4000:4000"          # в разделе 7 — как ограничить доступ
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
    networks:
      - litellm-net

networks:
  litellm-net:
    name: litellm-net         # именованная сеть: к ней подключится nginx из 05d
```

Пояснения:

| Поле | Зачем |
|---|---|
| `image: ghcr.io/berriai/litellm:main-stable` | стабильный образ (проходит 12-часовые нагрузочные тесты перед публикацией); тег `main-latest` — свежий, но менее проверенный |
| `env_file: litellm.env` | переменные попадают внутрь контейнера |
| `volumes: ./config.yaml:/app/config.yaml:ro` | конфиг смонтирован **read-only** — правится на хосте, применяется рестартом контейнера |
| `restart: unless-stopped` | автоподъём после перезагрузки хоста и падений — заменяет systemd-юнит из venv-варианта |
| `healthcheck` | проверка `/health/liveliness` (незащищённый endpoint); статус виден в `docker compose ps` |

`--host` не указываем: внутри контейнера LiteLLM по умолчанию слушает `0.0.0.0:4000`, а наружу порт публикует Docker.

---

## 4. Секреты

Сгенерировать ключ:

```bash
openssl rand -hex 32
```

```bash
nano /opt/litellm/litellm.env
```

Содержимое:

```bash
# Токен реального провайдера
CUSTOM_LLM_TOKEN=sk-ваш-токен-провайдера

# Ключ, которым GUI будет ходить в LiteLLM.
# Это НЕ токен провайдера. Придумайте свой.
LITELLM_MASTER_KEY=sk-litellm-очень-длинный-случайный-ключ (который получили при генерации через openssl, обратите внимание, что к нему добавляется префикс sk-litellm-)

# Служебное (INFO - обычный уровень логирования, для траблшутинга и проверки работы guardrails установить DEBUG)
LITELLM_LOG=INFO
```

Права:

```bash
chmod 600 /opt/litellm/litellm.env
```

`env_file` читается docker compose на хосте при создании контейнера, поэтому файл должен быть читаем вашим пользователем; `600` закрывает его от остальных.

---

## 5. Конфиг LiteLLM

```bash
nano /opt/litellm/config.yaml
```

Минимальный рабочий вариант для OpenAI-compatible custom URL:

```yaml
model_list:
  - model_name: corp-llm
    litellm_params:
      model: openai/ИМЯ_МОДЕЛИ_У_ПРОВАЙДЕРА       # префикс openai/ обязателен
      api_base: https://ВАШ-CUSTOM-URL/v1
      api_key: os.environ/CUSTOM_LLM_TOKEN
      timeout: 120
      stream_timeout: 120

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY

litellm_settings:
  drop_params: true
  request_timeout: 120
```

Что здесь важно:

| Поле | Зачем |
|---|---|
| `model_name: corp-llm` | Имя, которое укажете в GUI |
| `model: openai/...` | Префикс `openai/` говорит LiteLLM говорить с endpoint по OpenAI API |
| `api_base` | Custom URL провайдера, обычно с `/v1` |
| `api_key: os.environ/CUSTOM_LLM_TOKEN` | Берёт токен из `litellm.env` |
| `master_key` | Ключ для GUI. Без него прокси лучше не оставлять в сети |

Если endpoint **не** OpenAI-compatible (Anthropic, Azure, Gemini и т.д.), префикс другой, например `anthropic/claude-3-5-sonnet`. Для типичного корпоративного/self-hosted OpenAI API оставляйте `openai/`.

Пример конфигурации:

```yaml
model_list:
  - model_name: corp-llm
    litellm_params:
      model: openai/gemma-4-31b-it
      api_base: https://gpt.mwsapis.ru/projects/my_project/openai/v1/
      api_key: os.environ/CUSTOM_LLM_TOKEN
      timeout: 120
      stream_timeout: 120

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY

litellm_settings:
  drop_params: true
  request_timeout: 120
```

---

## 6. Запуск и проверка

```bash
cd /opt/litellm
docker compose up -d
docker compose ps
```

Подождите, пока статус станет `healthy` (первый старт 10–60 секунд — скачается образ), и посмотрите журнал:

```bash
docker compose logs -f litellm
```

Успешный старт заканчивается строками:

```text
Application startup complete.
Uvicorn running on http://0.0.0.0:4000 (Press CTRL+C to quit)
```

Проверка списка моделей:

```bash
bash -c '
  set -a
  source /opt/litellm/litellm.env
  set +a
  curl -sS http://127.0.0.1:4000/v1/models \
    -H "Authorization: Bearer ${LITELLM_MASTER_KEY}"
'
```

Должен вернуться список, где есть `corp-llm`.

Тестовый чат:

```bash
bash -c '
  set -a
  source /opt/litellm/litellm.env
  set +a
  curl -sS http://127.0.0.1:4000/v1/chat/completions \
    -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"corp-llm\",\"messages\":[{\"role\":\"user\",\"content\":\"Ответь одним словом: ping\"}],\"max_tokens\":32}"
'
```

Если это работает — прокси и custom URL настроены верно.

---

## 7. Публикация порта и сеть

**Важно: Docker обходит UFW.** Публикация порта через `ports:` добавляет правило в iptables в обход UFW, поэтому `ufw deny 4000` не закроет контейнер. Варианты контроля доступа:

1. **Только loopback** (если наружу пускаете через nginx из [05d_nginx.md](05d_nginx.md)) — в `docker-compose.yml`:
   ```yaml
   ports:
     - "127.0.0.1:4000:4000"
   ```
2. **Доступ из LAN** — оставьте `"4000:4000"` и при необходимости ограничьте источники через цепочку `DOCKER-USER`:
   ```bash
   # разрешить только сеть 192.168.0.0/16, остальное — DROP
   sudo iptables -I DOCKER-USER -p tcp --dport 4000 ! -s 192.168.0.0/16 -j DROP
   ```
   (правило не переживёт ребут без `iptables-persistent`; для большинства сценариев достаточно варианта 1 + nginx)
3. Порт 4000 не публиковать в интернет; GUI ходит из LAN/VPN.

Открыть порт, если фильтрация на уровне облака/роутера:

```bash
sudo ufw allow 4000/tcp
```

Для публикации наружу только через nginx с TLS — см. [05d_nginx.md](05d_nginx.md).

---

## 8. Настройка GUI на локальной станции

В клиенте выберите провайдера **OpenAI** / **OpenAI Compatible** / **Custom OpenAI**.

Параметры:

| Поле в GUI | Значение |
|---|---|
| API Base / Base URL | `http://IP_UBUNTU:4000/v1` |
| API Key | значение `LITELLM_MASTER_KEY` |
| Model | `corp-llm` |

Частые ошибки GUI:

- Указали URL провайдера, а не LiteLLM — тогда guardrails и прокси обходятся.
- Указали `http://IP:4000` **без** `/v1`, а клиент сам `/v1` не добавляет. Если не работает — попробуйте оба варианта: с `/v1` и без.
- В поле модели написали настоящее имя у провайдера, а не алиас `corp-llm`.
- Подставили token провайдера вместо `LITELLM_MASTER_KEY`.

Пример для клиентов, где base задаётся явно:

```text
OPENAI_BASE_URL=http://192.168.10.20:4000/v1
OPENAI_API_KEY=sk-litellm-...
OPENAI_MODEL=corp-llm
```

После этого все промпты из GUI идут так:

```text
GUI  →  LiteLLM (контейнер)  →  custom URL + token провайдера
```

---

## 9. Несколько моделей / несколько custom URL

Если позже появятся ещё endpoint’ы, добавляйте блоки в `model_list`. GUI будет выбирать модель по `model_name`.

```yaml
model_list:
  - model_name: corp-llm
    litellm_params:
      model: openai/model-a
      api_base: https://llm-a.example.com/v1
      api_key: os.environ/CUSTOM_LLM_TOKEN

  - model_name: local-llama
    litellm_params:
      model: openai/llama3
      api_base: http://10.0.0.50:8000/v1
      api_key: none
```

После правки `config.yaml` (bind-mount читается при старте контейнера):

```bash
docker compose restart litellm
```

Правило применения изменений:

| Что поменяли | Команда |
|---|---|
| `config.yaml` | `docker compose restart litellm` |
| `litellm.env` или сам `docker-compose.yml` | `docker compose up -d` (пересоздаёт контейнер; простой `restart` новые env **не подхватит**) |

---

## 10. Обновление и бэкап

Обновление:

```bash
cd /opt/litellm
docker compose pull
docker compose up -d
docker image prune -f   # убрать старый образ
```

Обновляйте на свежий `main-stable`; перед мажорным скачком загляните в release notes LiteLLM.

Бэкапьте только:

- `/opt/litellm/config.yaml`
- `/opt/litellm/litellm.env`
- при наличии — свои guardrail-скрипты (см. [02d_add_custom_code_guardrails.md](02d_add_custom_code_guardrails.md))

---

## 11. Типовые поломки

| Симптом | Что проверить |
|---|---|
| GUI: 401 / Unauthorized | В GUI должен быть `LITELLM_MASTER_KEY`, не токен провайдера |
| GUI: connection refused | `ports` публикует порт наружу (`ss -ltnp \| grep 4000`), IP верный; помните, что `127.0.0.1:4000:4000` доступен только с самого хоста |
| Контейнер постоянно перезапускается | `docker compose logs litellm` — чаще опечатка в YAML или нет переменной из `os.environ/...` |
| `config.yaml` не применился | проверьте путь монтирования `./config.yaml:/app/config.yaml` и команду `--config=/app/config.yaml` |
| 404 / model not found | В GUI указан `corp-llm`, не имя у провайдера |
| 401/403 уже от провайдера | Неверный `CUSTOM_LLM_TOKEN` или `api_base` |
| timeout | увеличьте `timeout` / `request_timeout`; проверьте, что custom URL доступен **с хоста** (контейнер ходит в сеть через хост, отдельной проверки изнутри обычно не нужно) |
| стриминг в GUI рвётся | nginx/`proxy_buffering off`, таймауты 300s (см. [05d_nginx.md](05d_nginx.md)) |
| поменяли `litellm.env`, а поведение старое | `docker compose up -d` вместо `restart` — env_file читается только при создании контейнера |

Проверка, что хост видит провайдера:

```bash
source /opt/litellm/litellm.env

curl -sS https://ВАШ-CUSTOM-URL/v1/models \
  -H "Authorization: Bearer $CUSTOM_LLM_TOKEN"
```

Если этот `curl` не работает, LiteLLM тоже не заработает.

---

## Короткий чеклист

1. Установить Docker Engine + плагин compose, добавить пользователя в группу `docker`.
2. Создать `/opt/litellm` с `docker-compose.yml`, `config.yaml`, `litellm.env`.
3. В `litellm.env` положить token провайдера и отдельный `LITELLM_MASTER_KEY`.
4. В `config.yaml` описать алиас `corp-llm` с `api_base` и `openai/...`.
5. `docker compose up -d`, дождаться `Application startup complete` в `docker compose logs`.
6. В GUI указать **только** LiteLLM: `http://IP:4000/v1`, ключ `LITELLM_MASTER_KEY`, модель `corp-llm`.

Если пришлёте реальный вид custom URL (OpenAI-compatible или нет) и название GUI, можно дать точные значения полей под этот клиент и готовый `config.yaml` без плейсхолдеров.
