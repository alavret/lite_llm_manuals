#!/usr/bin/env bash
#
# ============================================================================
#  Установка LiteLLM "с нуля" на Ubuntu 24.04 БЕЗ Docker (venv + systemd).
#
#  Собран по гайдам:
#    01_setup_litellm.md                  - venv, конфиг, systemd-служба
#    02_add_custom_code_guardrails.md     - кастомный guardrail (email/SSN)
#    03_debug_requests.md                 - уровень логирования DEBUG (константа LITELLM_LOG)
#    04_add_presidio.md                   - Presidio Analyzer/Anonymizer + guardrail presidio-pii
#    05_nginx.md                          - nginx + Let's Encrypt (TLS на 443)
#    06_ui.md                             - PostgreSQL + Admin UI (+ Prisma для pip-установки)
#    07_valkey.md                         - Valkey (Redis-совместимый кэш/состояние)
#    08_verify_guardrails_masking.md      - финальная проверка маскирования PII по логам
#
#  Запуск:  sudo ./install_litellm.sh
#  Результат: рабочая среда LiteLLM: прокси + guardrails + Presidio + БД + UI + Valkey
#             (+ nginx/TLS, если задан LITELLM_PUBLIC_DOMAIN).
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

# --- Логирование (гайд 03): INFO - обычный режим, DEBUG - траблшутинг ---
LITELLM_LOG="INFO"

# --- Язык Presidio (гайд 04): ru | en ---
PRESIDIO_LANGUAGE="ru"

# --- Admin UI (гайд 06) ---
UI_USERNAME="admin"
UI_PASSWORD=""                     # пусто = сгенерируется автоматически

# --- TLS/публикация через nginx (гайд 05) ---
# Домен, A/AAAA-запись которого указывает на этот сервер.
# Оставьте ПУСТЫМ, чтобы не ставить nginx/TLS: тогда прокси слушает 0.0.0.0:4000.
LITELLM_PUBLIC_DOMAIN=""
CERTBOT_EMAIL="admin@example.com"  # e-mail для уведомлений Let's Encrypt (нужен при выпуске сертификата)

# --- Секреты. ПУСТО = генерируются автоматически и сохраняются в litellm.env ---
LITELLM_MASTER_KEY=""              # ключ, которым GUI ходит в LiteLLM (sk-litellm-...)
LITELLM_DB_PASSWORD=""             # пароль PostgreSQL-пользователя litellm
LITELLM_SALT_KEY=""                # соль шифрования ключей провайдеров в UI (не менять после старта!)
VALKEY_PASSWORD=""                 # пароль Valkey

# --- Финальная проверка маскирования по гайду 08 (true/false) ---
RUN_MASKING_VERIFICATION="true"

# ============================================================================
# БЛОК ПУТЕЙ - обычно менять не нужно
# ============================================================================
LITELLM_HOME="/opt/litellm"              # venv LiteLLM            (гайд 01)
LITELLM_CONF_DIR="/etc/litellm"          # конфиги и env           (гайди 01,02,04,06,07)
LITELLM_LOG_DIR="/var/log/litellm"       # каталог журналов        (гайд 03)
PRESIDIO_HOME="/opt/presidio"            # Presidio venv и серверы (гайд 04)
PRESIDIO_LOG_DIR="/var/log/presidio"     # каталог журналов Presidio

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

# ============================================================================
# БЛОК 1 (гайд 01, п.3): системные пакеты - python, PostgreSQL (гайд 06),
# Valkey (гайд 07), nginx + certbot (гайд 05)
# ============================================================================
log "БЛОК 1: установка системных пакетов"
apt update
apt install -y python3 python3-venv python3-pip \
               postgresql \
               valkey-server \
               nginx certbot python3-certbot-nginx

systemctl enable --now postgresql

# ============================================================================
# БЛОК 2 (гайд 01, п.2): системный пользователь litellm и каталоги.
# Прокси не должен работать от root.
# ============================================================================
log "БЛОК 2: пользователь litellm и каталоги"
id -u litellm >/dev/null 2>&1 || useradd --system --home "$LITELLM_HOME" --shell /usr/sbin/nologin litellm
mkdir -p "$LITELLM_HOME" "$LITELLM_CONF_DIR" "$LITELLM_LOG_DIR" "$PRESIDIO_HOME" "$PRESIDIO_LOG_DIR"
chown -R litellm:litellm "$LITELLM_HOME" "$LITELLM_CONF_DIR" "$LITELLM_LOG_DIR" "$PRESIDIO_HOME" "$PRESIDIO_LOG_DIR"

# ============================================================================
# БЛОК 3 (гайд 01, п.3): venv LiteLLM и установка 'litellm[proxy]'
# ============================================================================
log "БЛОК 3: venv и установка litellm[proxy]"
sudo -u litellm python3 -m venv "$LITELLM_HOME/venv"
sudo -u litellm "$LITELLM_HOME/venv/bin/pip" install -U pip
sudo -u litellm "$LITELLM_HOME/venv/bin/pip" install 'litellm[proxy]'
sudo -u litellm "$LITELLM_HOME/venv/bin/litellm" --help >/dev/null && echo "litellm установлен"

# ============================================================================
# БЛОК 4 (гайды 01 п.4, 04 п.4, 06 п.4, 07 п.4): файл секретов litellm.env.
# Токен провайдера, мастер-ключ, БД, Presidio, Valkey, UI - всё здесь.
# ============================================================================
log "БЛОК 4: файл секретов $LITELLM_CONF_DIR/litellm.env"
cat > "$LITELLM_CONF_DIR/litellm.env" <<EOF
# Токен реального провайдера
CUSTOM_LLM_TOKEN=${CUSTOM_LLM_TOKEN}

# Ключ, которым GUI ходит в LiteLLM (НЕ токен провайдера)
LITELLM_MASTER_KEY=${LITELLM_MASTER_KEY}

# Уровень логирования (гайд 03): INFO - рабочий режим, DEBUG - траблшутинг
LITELLM_LOG=${LITELLM_LOG}

# PYTHONPATH для кастомного guardrail-кода (гайд 02)
PYTHONPATH=/etc/litellm

# Presidio HTTP-сервисы (гайд 04): слушают только localhost
PRESIDIO_ANALYZER_API_BASE=http://127.0.0.1:5002
PRESIDIO_ANONYMIZER_API_BASE=http://127.0.0.1:5001

# PostgreSQL для Admin UI / виртуальных ключей / бюджетов (гайд 06)
DATABASE_URL=postgresql://litellm:${LITELLM_DB_PASSWORD}@127.0.0.1:5432/litellm

# Соль шифрования ключей провайдеров в UI (гайд 06).
# ВАЖНО: после первого использования никогда не менять!
LITELLM_SALT_KEY=${LITELLM_SALT_KEY}

# Логин/пароль входа в Admin UI (гайд 06)
UI_USERNAME=${UI_USERNAME}
UI_PASSWORD=${UI_PASSWORD}

# Valkey - общее состояние LiteLLM (гайд 07)
REDIS_HOST=127.0.0.1
REDIS_PORT=6379
REDIS_PASSWORD=${VALKEY_PASSWORD}
EOF
chown root:litellm "$LITELLM_CONF_DIR/litellm.env"
chmod 640 "$LITELLM_CONF_DIR/litellm.env"

# ============================================================================
# БЛОК 5 (гайды 01 п.5, 02 п.2, 04 п.4, 06 п.5, 07 п.5): config.yaml -
# модель с custom URL, master key, БД, оба guardrail'а, кэш/роутер Valkey.
# ============================================================================
log "БЛОК 5: конфиг $LITELLM_CONF_DIR/config.yaml"
cat > "$LITELLM_CONF_DIR/config.yaml" <<EOF
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
  # Кэш и координация через Valkey (гайд 07)
  cache: true
  cache_params:
    type: redis
    host: os.environ/REDIS_HOST
    port: os.environ/REDIS_PORT
    password: os.environ/REDIS_PASSWORD
    namespace: "litellm"
    ttl: 600

# Состояние роутера в Valkey (гайд 07): cooldowns, usage-based routing
router_settings:
  redis_host: os.environ/REDIS_HOST
  redis_port: os.environ/REDIS_PORT
  redis_password: os.environ/REDIS_PASSWORD

# Guardrail 1 - кастомный код: SSN блокируется, email маскируется (гайд 02)
guardrails:
  - guardrail_name: email_detector
    litellm_params:
      guardrail: my_guardrails.myCustomGuardrail
      mode: pre_call
      default_on: true

  # Guardrail 2 - Presidio: PII-маскирование запроса и ответа (гайд 04)
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
chown root:litellm "$LITELLM_CONF_DIR/config.yaml"
chmod 640 "$LITELLM_CONF_DIR/config.yaml"

# Проверка синтаксиса YAML (гайд 07 п.5)
"$LITELLM_HOME/venv/bin/python" -c "import yaml;yaml.safe_load(open('$LITELLM_CONF_DIR/config.yaml'))" && echo "config.yaml: синтаксис OK"

# ============================================================================
# БЛОК 6 (гайд 02, п.1): кастомный guardrail-код my_guardrails.py
# (блокировка SSN + маскирование email)
# ============================================================================
log "БЛОК 6: guardrail-код $LITELLM_CONF_DIR/my_guardrails.py"
cat > "$LITELLM_CONF_DIR/my_guardrails.py" <<'PYEOF'
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
chown root:litellm "$LITELLM_CONF_DIR/my_guardrails.py"
chmod 640 "$LITELLM_CONF_DIR/my_guardrails.py"

# ============================================================================
# БЛОК 7 (гайд 01 п.7 + 05 п.2): systemd-служба litellm.
# Слушаем 127.0.0.1 (финальная схема гайда 05 - публикация через nginx);
# без домена - 0.0.0.0. Valkey в After (гайд 07 п.7).
# ============================================================================
log "БЛОК 7: systemd-служба litellm"
if [ -n "$LITELLM_PUBLIC_DOMAIN" ]; then LITELLM_BIND_HOST="127.0.0.1"; else LITELLM_BIND_HOST="0.0.0.0"; fi
cat > /etc/systemd/system/litellm.service <<EOF
[Unit]
Description=LiteLLM Proxy
After=network-online.target valkey-server.service
Wants=network-online.target

[Service]
Type=simple
User=litellm
Group=litellm
WorkingDirectory=${LITELLM_HOME}
EnvironmentFile=${LITELLM_CONF_DIR}/litellm.env
ExecStart=${LITELLM_HOME}/venv/bin/litellm \\
  --config ${LITELLM_CONF_DIR}/config.yaml \\
  --host ${LITELLM_BIND_HOST} \\
  --port 4000
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

StandardOutput=journal
StandardError=journal
SyslogIdentifier=litellm

NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${LITELLM_LOG_DIR}
ReadOnlyPaths=${LITELLM_CONF_DIR} ${LITELLM_HOME}

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

# ============================================================================
# БЛОК 8 (гайд 04, пп.1-3): Presidio - отдельный venv, spaCy-модели (en+ru),
# Flask-обёртки официального API и systemd-службы (analyzer :5002, anonymizer :5001)
# ============================================================================
log "БЛОК 8: Presidio (venv, spaCy, HTTP-обёртки, systemd)"
sudo -u litellm python3 -m venv "$PRESIDIO_HOME/venv"
sudo -u litellm "$PRESIDIO_HOME/venv/bin/pip" install -U pip
sudo -u litellm "$PRESIDIO_HOME/venv/bin/pip" install \
  'presidio-analyzer' 'presidio-anonymizer' 'spacy' 'flask' 'gunicorn'

# spaCy-модели: английский + русский (для PERSON/локаций)
sudo -u litellm "$PRESIDIO_HOME/venv/bin/python" -m spacy download en_core_web_md
sudo -u litellm "$PRESIDIO_HOME/venv/bin/python" -m spacy download ru_core_news_md

# HTTP-обёртка Analyzer (официальная ручка POST /analyze)
cat > "$PRESIDIO_HOME/analyzer_server.py" <<'PYEOF'
from flask import Flask, jsonify, request
from presidio_analyzer import AnalyzerEngine
from presidio_analyzer.nlp_engine import NlpEngineProvider

configuration = {
    "nlp_engine_name": "spacy",
    "models": [
        {"lang_code": "en", "model_name": "en_core_web_md"},
        {"lang_code": "ru", "model_name": "ru_core_news_md"},
    ],
}

nlp_engine = NlpEngineProvider(nlp_configuration=configuration).create_engine()
analyzer = AnalyzerEngine(
    nlp_engine=nlp_engine,
    supported_languages=["en", "ru"],
)
app = Flask(__name__)


@app.get("/health")
def health():
    return jsonify({"status": "ok"})


@app.post("/analyze")
def analyze():
    body = request.get_json(force=True) or {}
    results = analyzer.analyze(
        text=body.get("text") or "",
        language=body.get("language") or "ru",
        entities=body.get("entities"),
        score_threshold=body.get("score_threshold", 0.35),
        correlation_id=body.get("correlation_id"),
        return_decision_process=bool(body.get("return_decision_process", False)),
    )
    return jsonify([r.to_dict() for r in results])
PYEOF

# HTTP-обёртка Anonymizer (ручка POST /anonymize; сериализация EngineResult вручную -
# в presidio-anonymizer >= 2.2.35x у EngineResult нет .to_dict())
cat > "$PRESIDIO_HOME/anonymizer_server.py" <<'PYEOF'
from flask import Flask, jsonify, request
from presidio_anonymizer import AnonymizerEngine
from presidio_anonymizer.entities import OperatorConfig, RecognizerResult

engine = AnonymizerEngine()
app = Flask(__name__)


@app.get("/health")
def health():
    return jsonify({"status": "ok"})


@app.post("/anonymize")
def anonymize():
    body = request.get_json(force=True) or {}
    analyzer_results = [
        RecognizerResult(
            entity_type=item["entity_type"],
            start=item["start"],
            end=item["end"],
            score=item.get("score", 1.0),
        )
        for item in body.get("analyzer_results") or []
    ]

    operators = None
    if body.get("anonymizers"):
        operators = {
            key: OperatorConfig(value.get("type", "replace"), value)
            for key, value in body["anonymizers"].items()
        }

    result = engine.anonymize(
        text=body.get("text") or "",
        analyzer_results=analyzer_results,
        operators=operators,
    )
    return jsonify(
        {
            "text": result.text,
            "items": [item.to_dict() for item in result.items],
        }
    )
PYEOF
chown litellm:litellm "$PRESIDIO_HOME"/*.py

# systemd-служба Presidio Analyzer (только 127.0.0.1 - наружу не нужен)
cat > /etc/systemd/system/presidio-analyzer.service <<EOF
[Unit]
Description=Presidio Analyzer
After=network-online.target

[Service]
Type=simple
User=litellm
Group=litellm
WorkingDirectory=${PRESIDIO_HOME}
ExecStart=${PRESIDIO_HOME}/venv/bin/gunicorn \\
  --bind 127.0.0.1:5002 \\
  --workers 2 \\
  --timeout 120 \\
  analyzer_server:app
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF

# systemd-служба Presidio Anonymizer
cat > /etc/systemd/system/presidio-anonymizer.service <<EOF
[Unit]
Description=Presidio Anonymizer
After=network-online.target

[Service]
Type=simple
User=litellm
Group=litellm
WorkingDirectory=${PRESIDIO_HOME}
ExecStart=${PRESIDIO_HOME}/venv/bin/gunicorn \\
  --bind 127.0.0.1:5001 \\
  --workers 1 \\
  --timeout 60 \\
  anonymizer_server:app
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now presidio-analyzer presidio-anonymizer

# Ждём готовности Presidio и проверяем ручной вызов Analyzer
sleep 5
for i in $(seq 1 12); do
  curl -sf http://127.0.0.1:5002/health >/dev/null && break; sleep 5
done
curl -sf http://127.0.0.1:5002/health >/dev/null && echo "presidio-analyzer: OK" || warn "presidio-analyzer не отвечает"
curl -sf http://127.0.0.1:5001/health >/dev/null && echo "presidio-anonymizer: OK" || warn "presidio-anonymizer не отвечает"

# ============================================================================
# БЛОК 9 (гайд 06, п.3): база и пользователь PostgreSQL для LiteLLM
# ============================================================================
log "БЛОК 9: PostgreSQL - база и пользователь litellm"
systemctl enable --now postgresql
sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='litellm'" | grep -q 1 || \
  sudo -u postgres psql -c "CREATE USER litellm WITH PASSWORD '${LITELLM_DB_PASSWORD}';"
sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='litellm'" | grep -q 1 || \
  sudo -u postgres psql -c "CREATE DATABASE litellm OWNER litellm;"

# ============================================================================
# БЛОК 10 (гайд 06, п.6): Prisma для pip-установки:
# prisma-клиент -> prisma generate -> патч _write_engine (litellm <= 1.99.x) -> prisma db push
# ============================================================================
log "БЛОК 10: Prisma-клиент и создание таблиц БД"
sudo -u litellm "$LITELLM_HOME/venv/bin/pip" install 'prisma==0.15.0'

# Каталог исходников litellm в venv (путь зависит от версии python)
PROXY_DIR="$(sudo -u litellm "$LITELLM_HOME/venv/bin/python" -c "import litellm,os;print(os.path.join(os.path.dirname(litellm.__file__),'proxy'))")"
echo "Каталог litellm/proxy: $PROXY_DIR"

# generate: PATH с venv обязателен, иначе Node-CLI не найдёт генератор prisma-client-py
sudo -u litellm bash -c "export PATH=${LITELLM_HOME}/venv/bin:\$PATH && cd '${PROXY_DIR}' && prisma generate"

# Патч несовместимости litellm <= 1.99.x с prisma >= 0.13 (issue #39114).
# На свежих версиях шаблон не найдётся - sed отработает без изменений.
sudo sed -i 's/prisma_client\._Prisma__engine = engine/prisma_client._engine = engine/' \
  "${PROXY_DIR}/db/prisma_client.py"

# Создание таблиц: pip-установка сама схему НЕ применяет
sudo -u litellm bash -c "set -a; source ${LITELLM_CONF_DIR}/litellm.env; set +a; export PATH=${LITELLM_HOME}/venv/bin:\$PATH; cd '${PROXY_DIR}' && prisma db push --accept-data-loss --skip-generate"

sudo -u litellm "$LITELLM_HOME/venv/bin/python" -c 'from prisma import Prisma; print("prisma ok")'

# ============================================================================
# БЛОК 11 (гайд 07, пп.2-3): Valkey - пароль requirepass и перезапуск
# ============================================================================
log "БЛОК 11: Valkey - установка пароля"
VALKEY_CONF="/etc/valkey/valkey.conf"
sed -i "s/^# requirepass foobared/requirepass ${VALKEY_PASSWORD}/" "$VALKEY_CONF"
if ! grep -q "^requirepass ${VALKEY_PASSWORD}" "$VALKEY_CONF"; then
  sed -i "s/^requirepass .*/requirepass ${VALKEY_PASSWORD}/" "$VALKEY_CONF"
  grep -q "^requirepass ${VALKEY_PASSWORD}" "$VALKEY_CONF" || echo "requirepass ${VALKEY_PASSWORD}" >> "$VALKEY_CONF"
fi
systemctl restart valkey-server
sleep 2
valkey-cli -a "$VALKEY_PASSWORD" --no-auth-warning ping | grep -q PONG && echo "valkey: PONG"

# ============================================================================
# БЛОК 12 (гайд 05): nginx + Let's Encrypt (если задан домен).
# Иначе - открываем порт 4000 напрямую (UFW) и пропускаем блок.
# ============================================================================
if [ -n "$LITELLM_PUBLIC_DOMAIN" ]; then
  log "БЛОК 12: nginx + TLS для $LITELLM_PUBLIC_DOMAIN"
  systemctl enable --now nginx

  # Шаг 1: конфиг без секции 443 (сертификата ещё нет - иначе nginx не стартует)
  cat > /etc/nginx/sites-available/litellm.conf <<'NGXEOF'
upstream litellm {
    server 127.0.0.1:4000;
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
  sed -i "s/__DOMAIN__/${LITELLM_PUBLIC_DOMAIN}/g" /etc/nginx/sites-available/litellm.conf
  ln -sf /etc/nginx/sites-available/litellm.conf /etc/nginx/sites-enabled/litellm.conf
  rm -f /etc/nginx/sites-enabled/default
  nginx -t && systemctl reload nginx

  # Шаг 2: выпуск сертификата (webroot-вариант B из гайда)
  certbot certonly --webroot -w /var/www/html -d "$LITELLM_PUBLIC_DOMAIN" \
    --non-interactive --agree-tos -m "$CERTBOT_EMAIL"

  # Шаг 3: финальный конфиг - HTTP->HTTPS редирект + сервер на 443
  cat > /etc/nginx/sites-available/litellm.conf <<'NGXEOF'
upstream litellm {
    server 127.0.0.1:4000;
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
  sed -i "s/__DOMAIN__/${LITELLM_PUBLIC_DOMAIN}/g" /etc/nginx/sites-available/litellm.conf
  nginx -t && systemctl reload nginx

  # deploy-hook: reload nginx после каждого продления сертификата
  cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/bin/sh
nginx -t && systemctl reload nginx
EOF
  chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

  # Файрвол: только 80/443, порт 4000 наружу закрыт
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    ufw delete allow 4000/tcp >/dev/null 2>&1 || true
    ufw allow 80/tcp  >/dev/null 2>&1 || true
    ufw allow 443/tcp >/dev/null 2>&1 || true
  fi
else
  log "БЛОК 12: домен не задан - nginx/TLS пропускаем, открываем порт 4000"
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    ufw allow 4000/tcp >/dev/null 2>&1 || true
  fi
fi

# ============================================================================
# БЛОК 13 (гайд 01 п.6-7 + 07 п.6 + 06 п.7): запуск litellm и проверки
# ============================================================================
log "БЛОК 13: запуск litellm и проверки"
systemctl enable --now litellm

# Ждём готовности прокси (старт занимает 10-60 секунд)
wait_for_litellm() {
  for i in $(seq 1 36); do
    curl -sf http://127.0.0.1:4000/health/liveliness >/dev/null 2>&1 && return 0
    sleep 5
  done
  return 1
}
wait_for_litellm && echo "litellm: прокси отвечает" || { echo "ОШИБКА: litellm не поднялся"; journalctl -u litellm -n 50 --no-pager; exit 1; }

# Проверка кэша Valkey (гайд 07 п.6)
curl -s http://127.0.0.1:4000/cache/ping -H "Authorization: Bearer $LITELLM_MASTER_KEY" && echo

# Проверка списка моделей
curl -s http://127.0.0.1:4000/v1/models -H "Authorization: Bearer $LITELLM_MASTER_KEY" && echo

# Тестовый чат (не фатально: зависит от доступности провайдера)
echo "--- тестовый чат ---"
curl -s http://127.0.0.1:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${LITELLM_MODEL_ALIAS}\",\"messages\":[{\"role\":\"user\",\"content\":\"Ответь одним словом: ping\"}],\"max_tokens\":32}" \
  && echo || warn "чат-запрос не прошёл - проверьте доступность провайдера и CUSTOM_LLM_TOKEN"

# ============================================================================
# БЛОК 14 (гайд 08): проверка маскирования PII по логам (временно включает DEBUG,
# снимает доказательства, возвращает уровень логирования и удаляет артефакты)
# ============================================================================
verify_masking() {
  log "БЛОК 14: проверка маскирования (временный DEBUG, гайд 08)"

  sed -i "s/^LITELLM_LOG=.*/LITELLM_LOG=DEBUG/" "$LITELLM_CONF_DIR/litellm.env"
  systemctl restart litellm
  wait_for_litellm

  # Контрольный запрос с вымышленными PII-маркерами
  curl -s http://127.0.0.1:4000/v1/chat/completions \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -H "Content-Type: application/json" \
    -d '{"model":"'"$LITELLM_MODEL_ALIAS"'","messages":[{"role":"user","content":"Запиши контакты: Иван Тестовый, email ivan.test@example.com, телефон +7 913 555-12-34, карта 4111 1111 1111 1111"}],"max_tokens":50}' \
    >/dev/null || true

  # Выгрузка окна логов (права 600 - там сырой текст запросов)
  journalctl -u litellm --since "5 minutes ago" --no-pager > /tmp/guardrail-check.log
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
  sed -i "s/^LITELLM_LOG=.*/LITELLM_LOG=${LITELLM_LOG}/" "$LITELLM_CONF_DIR/litellm.env"
  systemctl restart litellm
  wait_for_litellm
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
Установка завершена. Рабочая среда LiteLLM готова.

  API для GUI:      ${PUBLIC_URL}/v1
  Admin UI:         ${PUBLIC_URL}/ui
  Модель (алиас):   ${LITELLM_MODEL_ALIAS}
  Мастер-ключ:      ${LITELLM_MASTER_KEY}
  Логин UI:         ${UI_USERNAME} / ${UI_PASSWORD}

  Секреты и пароли: ${LITELLM_CONF_DIR}/litellm.env  (root:litellm, 640)
  Конфиг:           ${LITELLM_CONF_DIR}/config.yaml
  Guardrail-код:    ${LITELLM_CONF_DIR}/my_guardrails.py

  Службы:           systemctl status litellm presidio-analyzer presidio-anonymizer valkey-server postgresql
  Журнал:           journalctl -u litellm -f

  GUI-клиент: OpenAI-compatible, Base URL ${PUBLIC_URL}/v1,
              API Key = LITELLM_MASTER_KEY, Model = ${LITELLM_MODEL_ALIAS}
============================================================================
EOF
