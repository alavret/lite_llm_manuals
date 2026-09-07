#!/usr/bin/env bash
#
# ============================================================================
#  Установка LiteLLM "с нуля" на Ubuntu 24.04 В DOCKER (docker compose).
#
#  Собран по гайдам:
#    docker_01_setup_litellm.md            - Docker Engine + compose, стек litellm
#    docker_02_add_custom_code_guardrails.md - bind-mount guardrail-кода + PYTHONPATH
#    docker_03_debug_requests.md           - LITELLM_LOG в env + ротация логов контейнера
#    docker_04_add_presidio.md             - контейнеры Presidio (+ сборка analyzer с ru-моделью)
#    docker_05_nginx.md                    - nginx/certbot в контейнерах, TLS на 443
#    docker_06_ui.md                       - PostgreSQL-контейнер + Admin UI
#    docker_07_valkey.md                   - Valkey-контейнер (кэш/состояние)
#    docker_08_verify_guardrails_masking.md - финальная проверка маскирования PII
#
#  Запуск:  sudo ./install_litellm_docker.sh
#  Результат: рабочая среда LiteLLM: прокси + guardrails + Presidio + PostgreSQL
#             + Admin UI + Valkey (+ nginx/TLS, если задан LITELLM_PUBLIC_DOMAIN).
# ============================================================================

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ============================================================================
# БЛОК КОНСТАНТ - ЗАПОЛНИТЬ ПЕРЕД ЗАПУСКОМ
# ============================================================================

# --- Параметры провайдера модели (обязательные) ---
# Токен реального провайдера LLM (это НЕ ключ LiteLLM)
CUSTOM_LLM_TOKEN="sk-ВСТАВЬТЕ-ТОКЕН-ПРОВАЙДЕРА"

# Custom URL провайдера (OpenAI-compatible), обычно с /v1 на конце
LITELLM_PROVIDER_API_BASE="https://gpt.mwsapis.ru/projects/my_project/openai/v1/"

# Имя модели У ПРОВАЙДЕРА (без префикса; в конфиг добавится префикс openai/)
LITELLM_PROVIDER_MODEL_NAME="gemma-4-31b-it"

# Алиас модели, под которым её видит GUI
LITELLM_MODEL_ALIAS="corp-llm"

# --- Логирование (гайд 03d): INFO - обычный режим, DEBUG - траблшутинг ---
LITELLM_LOG="INFO"

# --- Язык Presidio (гайд 04d): ru - соберётся кастомный analyzer с ru-моделью, en - официальный образ ---
PRESIDIO_LANGUAGE="ru"

# --- Admin UI (гайд 06d) ---
UI_USERNAME="admin"
UI_PASSWORD=""                     # пусто = сгенерируется автоматически

# --- TLS/публикация через nginx-контейнер (гайд 05d) ---
# Домен, A/AAAA-запись которого указывает на этот сервер.
# Оставьте ПУСТЫМ, чтобы не ставить nginx/TLS: тогда порт 4000 публикуется на все интерфейсы.
LITELLM_PUBLIC_DOMAIN=""
CERTBOT_EMAIL="admin@example.com"  # e-mail для уведомлений Let's Encrypt (нужен при выпуске сертификата)

# --- Секреты. ПУСТО = генерируются автоматически и сохраняются в litellm.env ---
LITELLM_MASTER_KEY=""              # ключ, которым GUI ходит в LiteLLM (sk-litellm-...)
LITELLM_DB_PASSWORD=""             # пароль PostgreSQL (контейнер db)
LITELLM_SALT_KEY=""                # соль шифрования ключей провайдеров в UI (не менять после старта!)
VALKEY_PASSWORD=""                 # пароль Valkey (= REDIS_PASSWORD)

# --- Финальная проверка маскирования по гайду 08d (true/false) ---
RUN_MASKING_VERIFICATION="true"

# ============================================================================
# БЛОК ПУТЕЙ - обычно менять не нужно
# ============================================================================
LITELLM_DIR="/opt/litellm"          # стек LiteLLM: compose, config, env (гайд 01d)
PRESIDIO_DIR="/opt/presidio"        # сборка Presidio (гайд 04d)
NGINX_DIR="/opt/nginx"              # nginx + certbot (гайд 05d)
DOCKER_NET="litellm-net"            # общая docker-сеть всех стеков

# ----------------------------------------------------------------------------
log()  { echo -e "\n===== [$(date '+%F %T')] $* ====="; }
warn() { echo -e "WARNING: $*"; }

[ "$(id -u)" -eq 0 ] || { echo "Запустите скрипт с sudo или от root."; exit 1; }

# Проверка обязательных констант
if [ "$CUSTOM_LLM_TOKEN" = "sk-ВСТАВЬТЕ-ТОКЕН-ПРОВАЙДЕРА" ] || [ -z "$CUSTOM_LLM_TOKEN" ]; then
    echo "ОШИБКА: задайте CUSTOM_LLM_TOKEN в блоке констант."; exit 1
fi
if [ -z "$LITELLM_PROVIDER_API_BASE" ] || [ -z "$LITELLM_PROVIDER_MODEL_NAME" ]; then
    echo "ОШИБКА: задайте LITELLM_PROVIDER_API_BASE и LITELLM_PROVIDER_MODEL_NAME."; exit 1
fi
if [ -n "$LITELLM_PUBLIC_DOMAIN" ] && [ -z "$CERTBOT_EMAIL" ]; then
    echo "ОШИБКА: при включённом TLS задайте CERTBOT_EMAIL."; exit 1
fi

# ----------------------------------------------------------------------------
# Секреты: используем заданные пользователем или генерируем автоматически
# ----------------------------------------------------------------------------
if [ -z "$LITELLM_MASTER_KEY" ]; then
    LITELLM_MASTER_KEY="sk-litellm-$(openssl rand -hex 32)"
fi
if [ -z "$LITELLM_DB_PASSWORD" ]; then
    LITELLM_DB_PASSWORD="$(openssl rand -hex 24)"
fi
if [ -z "$LITELLM_SALT_KEY" ]; then
    LITELLM_SALT_KEY="$(openssl rand -base64 32)"
fi
if [ -z "$UI_PASSWORD" ]; then
    UI_PASSWORD="$(openssl rand -base64 18)"
fi
if [ -z "$VALKEY_PASSWORD" ]; then
    VALKEY_PASSWORD="$(openssl rand -hex 32)"
fi

# Привязка порта 4000: через nginx - только loopback (гайд 05d п.2),
# иначе - на все интерфейсы
if [ -n "$LITELLM_PUBLIC_DOMAIN" ]; then
    LITELLM_PORT_BIND="127.0.0.1:"
else
    LITELLM_PORT_BIND=""
fi

# ============================================================================
# БЛОК 1 (гайд 01d, п.1): установка Docker Engine из официального репозитория
# (не из docker.io - там старые версии и нет плагина compose)
# ============================================================================
log "БЛОК 1: установка Docker Engine + compose plugin"
apt remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
apt update
apt install -y ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
$(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
apt update
apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin python3-yaml
systemctl enable --now docker

# Работа без sudo для вызывающего пользователя
RUN_USER="${SUDO_USER:-root}"
usermod -aG docker "$RUN_USER" 2>/dev/null || true

docker version >/dev/null && docker compose version

# ============================================================================
# БЛОК 2 (гайд 01d, пп.2,7): общая docker-сеть всех стеков
# ============================================================================
log "БЛОК 2: docker-сеть $DOCKER_NET"
docker network create "$DOCKER_NET" 2>/dev/null || true

# ============================================================================
# БЛОК 3 (гайд 01d пп.2,4,5 + 02d п.2 + 03d п.2 + 06d п.2 + 07d п.4):
# каталог /opt/litellm - docker-compose.yml (litellm + db + valkey),
# litellm.env (секреты), config.yaml, guardrails/my_guardrails.py
# ============================================================================
log "БЛОК 3: файлы стека LiteLLM в $LITELLM_DIR"
mkdir -p "$LITELLM_DIR/guardrails"

# --- 3.1 docker-compose.yml: litellm (bind-mount guardrails, ротация логов),
#         postgres:16 (Admin UI), valkey (кэш). Сеть внешняя, заранее создана. ---
cat > "$LITELLM_DIR/docker-compose.yml" <<'COMPOSEEOF'
services:
  litellm:
    image: ghcr.io/berriai/litellm:main-stable
    container_name: litellm
    restart: unless-stopped
    ports:
      - "__PORT_BIND__4000:4000"          # loopback при публикации через nginx (05d)
    env_file:
      - litellm.env
    environment:
      STORE_MODEL_IN_DB: "True"           # модели из UI хранятся в БД; включает автомиграции (06d)
      PYTHONPATH: /app/custom             # импорт my_guardrails (02d)
    volumes:
      - ./config.yaml:/app/config.yaml:ro
      - ./guardrails:/app/custom:ro       # guardrail-код (02d)
    command: ["--config=/app/config.yaml", "--port", "4000"]
    depends_on:
      db:
        condition: service_healthy        # ждать готовности PostgreSQL (06d)
      valkey:
        condition: service_healthy        # и Valkey (07d)
    healthcheck:
      test:
        - CMD-SHELL
        - python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:4000/health/liveliness')"
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s
    logging:                              # ротация журнала контейнера (03d)
      driver: json-file
      options:
        max-size: "50m"
        max-file: "5"
    networks:
      - litellm-net

  db:
    image: postgres:16
    container_name: litellm_db
    restart: unless-stopped
    environment:
      POSTGRES_DB: litellm
      POSTGRES_USER: litellm
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}   # из /opt/litellm/.env (06d п.3)
    volumes:
      - postgres_data:/var/lib/postgresql/data
    # порт 5432 наружу НЕ публикуем: БД доступна только внутри docker-сети
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -d litellm -U litellm"]
      interval: 5s
      timeout: 5s
      retries: 10
    networks:
      - litellm-net

  valkey:
    image: valkey/valkey:8.1-alpine
    container_name: valkey
    restart: unless-stopped
    env_file:
      - litellm.env
    # пароль подставляется шеллом ВНУТРИ контейнера из env_file (07d)
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
    # ports НЕ публикуем: Docker обходит UFW, единственный надёжный вариант - не публиковать

networks:
  litellm-net:
    name: litellm-net
    external: true

volumes:
  postgres_data:
  valkey-data:
COMPOSEEOF
sed -i "s/__PORT_BIND__/${LITELLM_PORT_BIND}/" "$LITELLM_DIR/docker-compose.yml"

# --- 3.2 файл секретов litellm.env (env_file всех контейнеров) ---
cat > "$LITELLM_DIR/litellm.env" <<EOF
# Токен реального провайдера
CUSTOM_LLM_TOKEN=${CUSTOM_LLM_TOKEN}

# Ключ, которым GUI ходит в LiteLLM (НЕ токен провайдера)
LITELLM_MASTER_KEY=${LITELLM_MASTER_KEY}

# Уровень логирования (гайд 03d): INFO - рабочий режим, DEBUG - траблшутинг.
# После правки env обязателен 'docker compose up -d' (не restart!)
LITELLM_LOG=${LITELLM_LOG}

# PostgreSQL для Admin UI; хост - имя сервиса db, НЕ 127.0.0.1 (гайд 06d)
DATABASE_URL=postgresql://litellm:${LITELLM_DB_PASSWORD}@db:5432/litellm

# Соль шифрования ключей провайдеров в UI. После первого использования не менять!
LITELLM_SALT_KEY=${LITELLM_SALT_KEY}

# Логин/пароль входа в Admin UI
UI_USERNAME=${UI_USERNAME}
UI_PASSWORD=${UI_PASSWORD}

# Valkey внутри docker-сети (гайд 07d): имя сервиса, а не 127.0.0.1
REDIS_HOST=valkey
REDIS_PORT=6379
REDIS_PASSWORD=${VALKEY_PASSWORD}

# Тот же пароль нужен контейнеру valkey (healthcheck/command в compose)
VALKEY_PASSWORD=${VALKEY_PASSWORD}

# Presidio внутри docker-сети (гайд 04d): резолвинг по имени сервиса
PRESIDIO_ANALYZER_API_BASE=http://presidio-analyzer:3000
PRESIDIO_ANONYMIZER_API_BASE=http://presidio-anonymizer:3000
EOF
chmod 600 "$LITELLM_DIR/litellm.env"

# --- 3.3 .env для подстановки ${POSTGRES_PASSWORD} в docker-compose.yml (06d п.3);
#         env_file для этого НЕ подходит - compose подставляет до чтения env_file ---
echo "POSTGRES_PASSWORD=${LITELLM_DB_PASSWORD}" > "$LITELLM_DIR/.env"
chmod 600 "$LITELLM_DIR/.env"

# --- 3.4 config.yaml: модель, master key, БД, guardrails, кэш/роутер Valkey ---
cat > "$LITELLM_DIR/config.yaml" <<EOF
model_list:
  - model_name: ${LITELLM_MODEL_ALIAS}
    litellm_params:
      model: openai/${LITELLM_PROVIDER_MODEL_NAME}   # префикс openai/ обязателен
      api_base: ${LITELLM_PROVIDER_API_BASE}
      api_key: os.environ/CUSTOM_LLM_TOKEN
      timeout: 120
      stream_timeout: 120

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY
  database_url: os.environ/DATABASE_URL

litellm_settings:
  drop_params: true
  request_timeout: 120
  dump_requests: true
  dump_responses: true
  # Кэш и координация через Valkey (гайд 07d)
  cache: true
  cache_params:
    type: redis
    host: os.environ/REDIS_HOST
    port: os.environ/REDIS_PORT
    password: os.environ/REDIS_PASSWORD
    namespace: "litellm"
    ttl: 600

# Состояние роутера в Valkey (гайд 07d): cooldowns, usage-based routing
router_settings:
  redis_host: os.environ/REDIS_HOST
  redis_port: os.environ/REDIS_PORT
  redis_password: os.environ/REDIS_PASSWORD

# Guardrail 1 - кастомный код: SSN блокируется, email маскируется (гайд 02d)
guardrails:
  - guardrail_name: email_detector
    litellm_params:
      guardrail: my_guardrails.myCustomGuardrail
      mode: pre_call
      default_on: true

  # Guardrail 2 - Presidio: PII-маскирование запроса и ответа (гайд 04d)
  - guardrail_name: presidio-pii
    litellm_params:
      guardrail: presidio
      mode: [pre_call, post_call]
      default_on: true
      presidio_analyzer_api_base: os.environ/PRESIDIO_ANALYZER_API_BASE
      presidio_anonymizer_api_base: os.environ/PRESIDIO_ANONYMIZER_API_BASE
      presidio_language: ${PRESIDIO_LANGUAGE}
      output_parse_pii: true
      presidio_score_thresholds:
        ALL: 0.5
        US_DRIVER_LICENSE: 0.85
      pii_entities_config:
        PERSON: MASK
        EMAIL_ADDRESS: MASK
        PHONE_NUMBER: MASK
        CREDIT_CARD: MASK
        IBAN_CODE: MASK
        IP_ADDRESS: MASK
        LOCATION: MASK
        NRP: MASK
        CRYPTO: MASK
        URL: MASK
        US_SSN: MASK
        MEDICAL_LICENSE: MASK
EOF

# --- 3.5 guardrail-код (гайд 02d п.1) - тот же, что в venv-версии ---
cat > "$LITELLM_DIR/guardrails/my_guardrails.py" <<'PYEOF'
import re
from typing import Any, Dict, List, Optional, Union

from fastapi import HTTPException
from litellm.integrations.custom_guardrail import CustomGuardrail

EMAIL_RE = re.compile(
    r"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}"
)
SSN_RE = re.compile(r"\b\d{3}-\d{2}-\d{4}\b")


class myCustomGuardrail(CustomGuardrail):
    async def apply_guardrail(
        self,
        inputs,
        request_data=None,
        input_type=None,
        logging_obj=None,
        **kwargs,
    ):
        texts = self._get_texts(inputs)

        for text in texts:
            if SSN_RE.search(text or ""):
                raise HTTPException(
                    status_code=400,
                    detail="Request blocked: SSN detected",
                )

        modified = [
            EMAIL_RE.sub("[EMAIL REDACTED]", text or "")
            for text in texts
        ]
        return self._set_texts(inputs, modified)

    @staticmethod
    def _get_texts(inputs) -> List[str]:
        if isinstance(inputs, dict):
            return list(inputs.get("texts") or [])
        if hasattr(inputs, "texts"):
            return list(inputs.texts or [])
        if isinstance(inputs, list):
            return list(inputs)
        raise TypeError(f"Unsupported guardrail inputs type: {type(inputs)}")

    @staticmethod
    def _set_texts(inputs, texts: List[str]):
        if isinstance(inputs, dict):
            out = dict(inputs)
            out["texts"] = texts
            return out
        if hasattr(inputs, "texts"):
            try:
                inputs.texts = texts
                return inputs
            except Exception:
                pass
        return texts
PYEOF
chmod 640 "$LITELLM_DIR/guardrails/my_guardrails.py"

docker compose -f "$LITELLM_DIR/docker-compose.yml" config --quiet && echo "docker-compose.yml: синтаксис OK"

# ============================================================================
# БЛОК 4 (гайд 01d п.6): первый запуск стека LiteLLM (db + valkey + litellm).
# Prisma-миграции Docker-образ применяет сам при старте с DATABASE_URL (06d п.6).
# ============================================================================
log "БЛОК 4: запуск стека LiteLLM (docker compose up -d)"
cd "$LITELLM_DIR"
docker compose up -d
wait_container_healthy() {
  local name="$1" i
  for i in $(seq 1 36); do
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$name" 2>/dev/null)" = "healthy" ] && return 0
    sleep 5
  done
  return 1
}
wait_container_healthy valkey      && echo "valkey: healthy"      || warn "valkey не стал healthy"
wait_container_healthy litellm_db  && echo "litellm_db: healthy"  || warn "litellm_db не стал healthy"
wait_container_healthy litellm     && echo "litellm: healthy"     || warn "litellm не стал healthy (смотрите docker compose logs litellm)"

# ============================================================================
# БЛОК 5 (гайд 04d): Presidio в контейнерах.
# Для ru - кастомный образ analyzer с русской spaCy-моделью и inline-секцией
# recognizer_registry (обязательна, иначе контейнер падает с
# 'Misconfigured engine...'); anonymizer - официальный образ без сборки.
# ============================================================================
log "БЛОК 5: Presidio (контейнеры)"
mkdir -p "$PRESIDIO_DIR"

if [ "$PRESIDIO_LANGUAGE" = "ru" ]; then
  # Вытаскиваем дефолтный реестр рекогнайзеров из официального образа
  docker pull ghcr.io/data-privacy-stack/presidio-analyzer:latest
  docker run --rm --entrypoint cat ghcr.io/data-privacy-stack/presidio-analyzer:latest \
    /app/presidio_analyzer/conf/default_recognizers.yaml > /tmp/default_recognizers.yaml

  # analyzer-config.yml: ru+en NLP-движок + recognizer_registry с языками en,ru
  python3 - <<'PYEOF'
import yaml

reg = yaml.safe_load(open("/tmp/default_recognizers.yaml")) or {}
reg["supported_languages"] = ["en", "ru"]
config = {
    "supported_languages": ["en", "ru"],
    "default_score_threshold": 0.35,
    "nlp_configuration": {
        "nlp_engine_name": "spacy",
        "models": [
            {"lang_code": "en", "model_name": "en_core_web_md"},
            {"lang_code": "ru", "model_name": "ru_core_news_md"},
        ],
    },
    "recognizer_registry": reg,
}
yaml.safe_dump(config, open("/opt/presidio/analyzer-config.yml", "w"),
               allow_unicode=True, sort_keys=False)
PYEOF
  rm -f /tmp/default_recognizers.yaml

  # Dockerfile: конфиг + предзагрузка spaCy-моделей на этапе сборки
  cat > "$PRESIDIO_DIR/Dockerfile" <<'DOCKEOF'
FROM ghcr.io/data-privacy-stack/presidio-analyzer:latest

USER root
COPY analyzer-config.yml /app/analyzer-config.yml
ENV ANALYZER_CONF_FILE=/app/analyzer-config.yml

RUN python install_nlp_models.py --analyzer_conf_file /app/analyzer-config.yml

USER 1001
DOCKEOF
  ANALYZER_SERVICE_BLOCK="build: .
    image: presidio-analyzer-en-ru:latest"
else
  ANALYZER_SERVICE_BLOCK="image: ghcr.io/data-privacy-stack/presidio-analyzer:latest"
fi

# docker-compose.yml Presidio: сеть внешняя litellm-net,
# порты на хосте - только 127.0.0.1 для ручных проверок
cat > "$PRESIDIO_DIR/docker-compose.yml" <<COMPOSEEOF
services:
  presidio-analyzer:
    ${ANALYZER_SERVICE_BLOCK}
    container_name: presidio-analyzer
    restart: unless-stopped
    environment:
      WORKERS: "2"
    ports:
      - "127.0.0.1:5002:3000"          # только для ручных curl-проверок с хоста
    networks:
      - litellm-net

  presidio-anonymizer:
    image: ghcr.io/data-privacy-stack/presidio-anonymizer:latest
    container_name: presidio-anonymizer
    restart: unless-stopped
    ports:
      - "127.0.0.1:5001:3000"
    networks:
      - litellm-net

networks:
  litellm-net:
    external: true
COMPOSEEOF

cd "$PRESIDIO_DIR"
docker compose up -d --build
wait_container_healthy presidio-analyzer   && echo "presidio-analyzer: healthy"   || warn "presidio-analyzer не стал healthy (первая сборка/загрузка модели до минуты)"
wait_container_healthy presidio-anonymizer && echo "presidio-anonymizer: healthy" || warn "presidio-anonymizer не стал healthy"

# После появления новых контейнеров nginx (если уже работал) держит старый IP litellm.
if docker ps --format '{{.Names}}' | grep -q '^litellm-nginx$'; then
  docker restart litellm-nginx
fi

# ============================================================================
# БЛОК 6 (гайд 05d): nginx + certbot в контейнерах, TLS на 443.
# Без домена - пропускаем (порт 4000 уже опубликован согласно LITELLM_PORT_BIND).
# ============================================================================
if [ -n "$LITELLM_PUBLIC_DOMAIN" ]; then
  log "БЛОК 6: nginx-контейнер + Let's Encrypt для $LITELLM_PUBLIC_DOMAIN"
  mkdir -p "$NGINX_DIR/conf.d" "$NGINX_DIR/www"

  cat > "$NGINX_DIR/docker-compose.yml" <<'COMPOSEEOF'
services:
  nginx:
    image: nginx:stable
    container_name: litellm-nginx
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./conf.d:/etc/nginx/conf.d:ro
      - ./www:/var/www/html
      - ./letsencrypt:/etc/letsencrypt
    networks:
      - litellm-net

  certbot:
    image: certbot/certbot
    container_name: litellm-certbot
    volumes:
      - ./www:/var/www/html
      - ./letsencrypt:/etc/letsencrypt
    # разовая утилита: запускается 'docker compose run --rm certbot ...';
    # ENTRYPOINT образа - certbot, команду передаём в run

networks:
  litellm-net:
    external: true
COMPOSEEOF

  # Шаг 1: конфиг без секции 443 (сертификата ещё нет); proxy_pass по имени
  # контейнера litellm в общей сети, а не 127.0.0.1
  cat > "$NGINX_DIR/conf.d/litellm.conf" <<'NGXEOF'
upstream litellm {
    server litellm:4000;
    keepalive 32;
}

server {
    listen 80;
    server_name __DOMAIN__;

    # certbot кладёт сюда файлы проверки при выпуске/продлении
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        proxy_pass http://litellm;

        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto http;
        proxy_set_header Connection        "";

        # стриминг ответов модели (SSE)
        proxy_buffering off;
        proxy_cache off;

        # долгие запросы к LLM не должны рваться
        proxy_read_timeout  600s;
        proxy_send_timeout  600s;
        proxy_connect_timeout 60s;
    }
}
NGXEOF
  sed -i "s/__DOMAIN__/${LITELLM_PUBLIC_DOMAIN}/g" "$NGINX_DIR/conf.d/litellm.conf"

  cd "$NGINX_DIR"
  docker compose up -d nginx

  # Шаг 2: выпуск сертификата webroot-контейнером certbot
  docker compose run --rm certbot certonly --webroot -w /var/www/html \
    -d "$LITELLM_PUBLIC_DOMAIN" --non-interactive --agree-tos --email "$CERTBOT_EMAIL"

  # Шаг 3: финальный конфиг - HTTP->HTTPS редирект + сервер на 443
  cat > "$NGINX_DIR/conf.d/litellm.conf" <<'NGXEOF'
upstream litellm {
    server litellm:4000;
    keepalive 32;
}

server {
    listen 80;
    server_name __DOMAIN__;

    # certbot при продлении продолжает класть сюда файлы проверки
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    # всё остальное - на HTTPS
    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    listen 443 ssl http2;
    server_name __DOMAIN__;

    ssl_certificate     /etc/letsencrypt/live/__DOMAIN__/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/__DOMAIN__/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_session_cache shared:SSL:10m;

    client_max_body_size 64m;

    access_log /var/log/nginx/litellm.access.log;
    error_log  /var/log/nginx/litellm.error.log warn;

    location / {
        proxy_pass http://litellm;

        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Connection        "";

        # стриминг ответов модели (SSE)
        proxy_buffering off;
        proxy_cache off;

        # долгие запросы к LLM не должны рваться
        proxy_read_timeout  600s;
        proxy_send_timeout  600s;
        proxy_connect_timeout 60s;
    }
}
NGXEOF
  sed -i "s/__DOMAIN__/${LITELLM_PUBLIC_DOMAIN}/g" "$NGINX_DIR/conf.d/litellm.conf"
  docker compose exec nginx nginx -t && docker compose exec nginx nginx -s reload

  # Шаг 4: продление сертификата - скрипт + cron (гайд 05d п.6.3)
  cat > /usr/local/bin/litellm-cert-renew.sh <<'EOF'
#!/bin/sh
cd /opt/nginx
docker compose run --rm certbot renew --webroot -w /var/www/html
docker compose exec -T nginx nginx -t && docker compose exec -T nginx nginx -s reload
EOF
  chmod +x /usr/local/bin/litellm-cert-renew.sh
  echo '0 4 * * 1 root /usr/local/bin/litellm-cert-renew.sh >> /var/log/litellm-cert-renew.log 2>&1' \
    > /etc/cron.d/litellm-cert-renew

  # Файрвол: 80/443 наружу. Порт 4000 закрыт привязкой 127.0.0.1 в compose
  # (Docker обходит UFW - gид 01d п.7)
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    ufw delete allow 4000/tcp >/dev/null 2>&1 || true
    ufw allow 80/tcp  >/dev/null 2>&1 || true
    ufw allow 443/tcp >/dev/null 2>&1 || true
  fi
else
  log "БЛОК 6: домен не задан - nginx/TLS пропускаем"
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    ufw allow 4000/tcp >/dev/null 2>&1 || true
  fi
fi

# ============================================================================
# БЛОК 7 (гайды 01d п.6, 07d п.6, 06d п.7): итоговые проверки
# ============================================================================
log "БЛОК 7: проверки работоспособности"
cd "$LITELLM_DIR"
docker compose ps

# Presidio на хосте (анalyzer должен вернуть сущности PERSON/PHONE_NUMBER/EMAIL_ADDRESS)
curl -sS http://127.0.0.1:5002/health && echo
curl -sS http://127.0.0.1:5001/health && echo
curl -sS http://127.0.0.1:5002/analyze -H 'Content-Type: application/json' \
  -d '{"text": "Позвоните Ивану Петрову +7 916 123-45-67 или на ivan@example.com", "language": "'"${PRESIDIO_LANGUAGE}"'"}' | head -c 400 && echo

# Кэш Valkey через litellm (гайд 07d п.6)
curl -s http://127.0.0.1:4000/cache/ping -H "Authorization: Bearer $LITELLM_MASTER_KEY" && echo

# Список моделей и readiness (включая статус БД, гайд 06d п.7)
curl -s http://127.0.0.1:4000/v1/models -H "Authorization: Bearer $LITELLM_MASTER_KEY" && echo
curl -s http://127.0.0.1:4000/health/readiness -H "Authorization: Bearer $LITELLM_MASTER_KEY" | head -c 400 && echo

# Тестовый чат (не фатально: зависит от доступности провайдера)
echo "--- тестовый чат ---"
curl -s http://127.0.0.1:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${LITELLM_MODEL_ALIAS}\",\"messages\":[{\"role\":\"user\",\"content\":\"Ответь одним словом: ping\"}],\"max_tokens\":32}" \
  && echo || warn "чат-запрос не прошёл - проверьте доступность провайдера и CUSTOM_LLM_TOKEN"

# Ключи с префиксом namespace реально в Valkey (гайд 07d п.6)
docker compose exec valkey valkey-cli -a "$VALKEY_PASSWORD" --no-auth-warning keys "litellm:*" | head || true

# ============================================================================
# БЛОК 8 (гайд 08d): проверка маскирования PII по логам.
# env правится только через 'docker compose up -d' (не restart!); после
# пересоздания litellm нужен рестарт nginx (stale DNS, гайд 05d).
# ============================================================================
verify_masking() {
  log "БЛОК 8: проверка маскирования (временный DEBUG, гайд 08d)"
  cd "$LITELLM_DIR"

  sed -i "s/^LITELLM_LOG=.*/LITELLM_LOG=DEBUG/" litellm.env
  docker compose up -d                 # пересоздание: env читается только при создании
  wait_container_healthy litellm
  if docker ps --format '{{.Names}}' | grep -q '^litellm-nginx$'; then docker restart litellm-nginx; fi

  # Контрольный запрос с вымышленными PII-маркерами
  curl -s http://127.0.0.1:4000/v1/chat/completions \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -H "Content-Type: application/json" \
    -d '{"model":"'"$LITELLM_MODEL_ALIAS"'","messages":[{"role":"user","content":"Запиши контакты: Иван Тестовый, email ivan.test@example.com, телефон +7 913 555-12-34, карта 4111 1111 1111 1111"}],"max_tokens":50}' \
    >/dev/null || true

  # Выгрузка окна логов ДО отката DEBUG (при пересоздании контейнера логи пропадут)
  docker compose logs --since 15m litellm --no-log-prefix > /tmp/guardrail-check.log
  chmod 600 /tmp/guardrail-check.log

  # Критерий 1: presidio сформировал маску
  if grep -q "redacted_text" /tmp/guardrail-check.log; then
    echo "OK: presidio сформировал маску (redacted_text найден)"
    grep "redacted_text" /tmp/guardrail-check.log | tail -n 1
  else
    warn "критерий 1 провален: строки redacted_text нет - presidio-guardrail не в цепочке"
  fi

  # Критерий 2: в тексте к провайдеру плейсхолдеры
  echo "Текст к провайдеру (критерий 2):"
  grep -oE 'Запиши контакты[^"]{0,120}' /tmp/guardrail-check.log | sort | uniq -c || warn "критерий 2 провален: исходящий текст не найден"

  # Возврат уровня логирования и удаление артефактов
  sed -i "s/^LITELLM_LOG=.*/LITELLM_LOG=${LITELLM_LOG}/" litellm.env
  docker compose up -d
  wait_container_healthy litellm
  if docker ps --format '{{.Names}}' | grep -q '^litellm-nginx$'; then docker restart litellm-nginx; fi
  rm -f /tmp/guardrail-check.log
}

if [ "$RUN_MASKING_VERIFICATION" = "true" ]; then
  verify_masking
fi

# ============================================================================
# ИТОГ
# ============================================================================
if [ -n "$LITELLM_PUBLIC_DOMAIN" ]; then
  PUBLIC_URL="https://${LITELLM_PUBLIC_DOMAIN}"
else
  PUBLIC_URL="http://$(hostname -I | awk '{print $1}'):4000"
fi
cat <<EOF

============================================================================
Установка завершена. Рабочая среда LiteLLM (Docker) готова.

  API для GUI:      ${PUBLIC_URL}/v1
  Admin UI:         ${PUBLIC_URL}/ui
  Модель (алиас):   ${LITELLM_MODEL_ALIAS}
  Мастер-ключ:      ${LITELLM_MASTER_KEY}
  Логин UI:         ${UI_USERNAME} / ${UI_PASSWORD}

  Каталог стека:    ${LITELLM_DIR}   (docker-compose.yml, config.yaml, litellm.env)
  Presidio:         ${PRESIDIO_DIR}  (контейнеры presidio-analyzer / presidio-anonymizer)
  Nginx:            ${NGINX_DIR}     (контейнер litellm-nginx + certbot)

  Управление:       cd ${LITELLM_DIR} && docker compose ps / logs -f litellm
                    config.yaml -> 'docker compose restart litellm'
                    litellm.env -> 'docker compose up -d' (не restart!)
  Продление TLS:    /usr/local/bin/litellm-cert-renew.sh (cron: /etc/cron.d/litellm-cert-renew)

  GUI-клиент: OpenAI-compatible, Base URL ${PUBLIC_URL}/v1,
              API Key = LITELLM_MASTER_KEY, Model = ${LITELLM_MODEL_ALIAS}
============================================================================
EOF
