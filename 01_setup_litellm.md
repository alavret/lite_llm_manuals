Сохраню контекст проекта и сразу дам пошаговую инструкцию под ваш сценарий: Ubuntu без Docker, GUI на локальной станции, модель по custom URL + token.
Зафиксирую сценарий развёртывания и сразу дам пошаговую инструкцию под Ubuntu без Docker.
Ниже — рабочая инструкция под ваш сценарий: **Ubuntu без Docker**, **GUI на локальной станции**, **одна модель с custom URL + token**. Клиент ходит только в LiteLLM, реальный endpoint и токен модели GUI не видит.

Схема:

```text
GUI (локальная станция)
    →  http(s)://<ubuntu-host>:4000/v1
    →  LiteLLM Proxy
    →  https://<custom-url>  + token провайдера
```

---

## 1. Что понадобится

На Ubuntu:

- Python 3.10+ (лучше 3.11/3.12)
- доступ в интернет для `pip`
- custom URL провайдера, например `https://llm.example.com/v1`
- token провайдера
- имя модели у провайдера, например `qwen2.5-72b` или `gpt-4o`

На станции с GUI:

- любое ПО с OpenAI-compatible API (Chatbox, Open WebUI, Continue, AnythingLLM, свой клиент)
- сетевой доступ до Ubuntu на порт `4000`

Проверьте Python:

```bash
python3 --version
```

---

## 2. Пользователь и каталоги

Не запускайте прокси от root.

```bash
sudo useradd --system --home /opt/litellm --shell /usr/sbin/nologin litellm
sudo mkdir -p /opt/litellm /etc/litellm /var/log/litellm
sudo chown -R litellm:litellm /opt/litellm /etc/litellm /var/log/litellm
```

---

## 3. Установка без Docker

```bash
sudo apt update
sudo apt install -y python3 python3-venv python3-pip

sudo -u litellm python3 -m venv /opt/litellm/venv
sudo -u litellm /opt/litellm/venv/bin/pip install -U pip
sudo -u litellm /opt/litellm/venv/bin/pip install 'litellm[proxy]'
```

Проверка:

```bash
sudo -u litellm /opt/litellm/venv/bin/litellm --help
```

---

## 4. Секреты

Сгенерировать ключ:

```bash
openssl rand -hex 32
```

Токен модели и ключ самого прокси держите в файле окружения, не в `config.yaml`.

```bash
sudo nano /etc/litellm/litellm.env
```

Содержимое:

```bash
# Токен реального провайдера
CUSTOM_LLM_TOKEN=sk-ваш-токен-провайдера

# Ключ, которым GUI будет ходить в LiteLLM.
# Это НЕ токен провайдера. Придумайте свой.
LITELLM_MASTER_KEY=sk-litellm-очень-длинный-случайный-ключ (который получили при генерации через openssl, обратите внимание, что к нему добавляется префикс sk-litellm-)

# Служебное (INFO - обычный уровень логирования, для траблшутинга и проверки работы railguards установить DEBUG)
LITELLM_LOG=INFO
```

Права:

```bash
sudo chown root:litellm /etc/litellm/litellm.env
sudo chmod 640 /etc/litellm/litellm.env
```

---

## 5. Конфиг LiteLLM

```bash
sudo nano /etc/litellm/config.yaml
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


Права на конфиг:

```bash
sudo chown root:litellm /etc/litellm/config.yaml
sudo chmod 640 /etc/litellm/config.yaml
```

---

## 6. Проверка руками, до systemd

```bash
sudo -u litellm bash -c '
  set -a
  source /etc/litellm/litellm.env
  set +a
  /opt/litellm/venv/bin/litellm \
    --config /etc/litellm/config.yaml \
    --host 127.0.0.1 \
    --port 4000
'
```

В другом терминале:

```bash
sudo bash -c '
  set -a
  source /etc/litellm/litellm.env
  set +a
  curl -sS http://127.0.0.1:4000/v1/models \
    -H "Authorization: Bearer ${LITELLM_MASTER_KEY}"
'
```

Должен вернуться список, где есть `corp-llm`.

Тестовый чат:

```bash
sudo bash -c '
  set -a
  source /etc/litellm/litellm.env
  set +a
  curl -sS http://127.0.0.1:4000/v1/chat/completions \
    -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"corp-llm\",\"messages\":[{\"role\":\"user\",\"content\":\"Ответь одним словом: ping\"}],\"max_tokens\":32}"
'
```

Если это работает — прокси и custom URL настроены верно. Остановите ручной процесс (`Ctrl+C`) и переходите к службе.

---

## 7. systemd-служба

```bash
sudo nano /etc/systemd/system/litellm.service
```

```ini
[Unit]
Description=LiteLLM Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=litellm
Group=litellm
WorkingDirectory=/opt/litellm
EnvironmentFile=/etc/litellm/litellm.env
ExecStart=/opt/litellm/venv/bin/litellm \
  --config /etc/litellm/config.yaml \
  --host 0.0.0.0 \
  --port 4000
Restart=on-failure
RestartSec=5
LimitNOFILE=65535

# Логи в journald
StandardOutput=journal
StandardError=journal
SyslogIdentifier=litellm

# Базовое ужесточение
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/log/litellm
ReadOnlyPaths=/etc/litellm /opt/litellm

[Install]
WantedBy=multi-user.target
```

`--host 0.0.0.0` нужен, чтобы GUI с другой машины дотянулся до прокси. Если GUI и LiteLLM на **одной** Ubuntu-станции, безопаснее `--host 127.0.0.1`.

Запуск:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now litellm
sudo systemctl status litellm --no-pager
sudo journalctl -u litellm -f
```

---

## 8. Сеть и доступ с локальной станции

Узнайте IP Ubuntu:

```bash
hostname -I
```

Откройте порт, если включён UFW:

```bash
sudo ufw allow 4000/tcp
sudo ufw reload
```

С локальной станции проверьте:

```bash
curl -sS http://IP_UBUNTU:4000/v1/models \
  -H "Authorization: Bearer ВАШ_LITELLM_MASTER_KEY"
```

Для постоянной работы лучше не светить голый HTTP в сеть. Варианты:

1. GUI и прокси в одной LAN / VPN, порт 4000 не публиковать в интернет.
2. Поставить nginx + TLS на `443` и проксировать на `127.0.0.1:4000`.

Короткий пример nginx (если нужен HTTPS):

```nginx
server {
    listen 443 ssl;
    server_name litellm.internal;

    ssl_certificate     /etc/ssl/certs/litellm.crt;
    ssl_certificate_key /etc/ssl/private/litellm.key;

    location / {
        proxy_pass http://127.0.0.1:4000;
        proxy_set_header Host $host;
        proxy_set_header Authorization $http_authorization;
        proxy_read_timeout 300s;
        proxy_buffering off;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
    }
}
```

Тогда в GUI будет `https://litellm.internal/v1`.

---

## 9. Настройка GUI на локальной станции

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
GUI  →  LiteLLM  →  custom URL + token провайдера
```

---

## 10. Несколько моделей / несколько custom URL

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

После правки:

```bash
sudo systemctl restart litellm
```

---

## 11. Обновление и бэкап

Обновление:

```bash
sudo -u litellm /opt/litellm/venv/bin/pip install -U 'litellm[proxy]'
sudo systemctl restart litellm
```

Бэкапьте только:

- `/etc/litellm/config.yaml`
- `/etc/litellm/litellm.env`
- при наличии — свои guardrail-скрипты

---

## 12. Типовые поломки

| Симптом | Что проверить |
|---|---|
| GUI: 401 / Unauthorized | В GUI должен быть `LITELLM_MASTER_KEY`, не токен провайдера |
| GUI: connection refused | `litellm` слушает `0.0.0.0`, UFW открыт, IP верный |
| 404 / model not found | В GUI указан `corp-llm`, не имя у провайдера |
| 401/403 уже от провайдера | Неверный `CUSTOM_LLM_TOKEN` или `api_base` |
| timeout | увеличьте `timeout` / `request_timeout`; проверьте, что custom URL доступен **с Ubuntu** |
| стриминг в GUI рвётся | nginx/`proxy_buffering off`, таймауты 300s |
| прокси стартует и сразу падает | `journalctl -u litellm -e`, чаще YAML или нет переменной из `os.environ/...` |

Проверка, что Ubuntu сама видит провайдера:

```bash
source /etc/litellm/litellm.env

curl -sS https://ВАШ-CUSTOM-URL/v1/models \
  -H "Authorization: Bearer $CUSTOM_LLM_TOKEN"
```

Если этот `curl` не работает, LiteLLM тоже не заработает.

---

## Короткий чеклист

1. Поставить `litellm[proxy]` в venv под пользователем `litellm`.
2. В `litellm.env` положить token провайдера и отдельный `LITELLM_MASTER_KEY`.
3. В `config.yaml` описать алиас `corp-llm` с `api_base` и `openai/...`.
4. Запустить systemd на `0.0.0.0:4000`.
5. В GUI указать **только** LiteLLM: `http://IP:4000/v1`, ключ `LITELLM_MASTER_KEY`, модель `corp-llm`.

Если пришлёте реальный вид custom URL (OpenAI-compatible или нет) и название GUI, можно дать точные значения полей под этот клиент и готовый `config.yaml` без плейсхолдеров.