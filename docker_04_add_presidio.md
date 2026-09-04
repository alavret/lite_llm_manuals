Docker-версия гайда [04_add_presidio.md](04_add_presidio.md): PII-маскирование через Presidio для LiteLLM, развёрнутого по [01d_setup_litellm.md](01d_setup_litellm.md). Вместо venv, самописных Flask-обёрток и systemd-юнитов — официальные контейнеры Presidio (кастомная сборка нужна только для русской модели).

Presidio в LiteLLM — это не плагин внутри процесса, а **два HTTP-сервиса**. LiteLLM перед вызовом модели (и/или после ответа) отправляет текст в Analyzer, затем в Anonymizer и уже обезличенный запрос пускает на ваш custom URL.

Схема для вашего контура:

```text
GUI  →  LiteLLM :4000 (контейнер)
              →  presidio-analyzer   :3000 (внутри сети Docker)
              →  presidio-anonymizer :3000 (внутри сети Docker)
              →  модель по custom URL + token
```

Для GUI обязательно `default_on: true`: обычный десктопный клиент поле `guardrails` не присылает.

---

## 1. Официальные образы

```bash
docker pull ghcr.io/data-privacy-stack/presidio-analyzer
docker pull ghcr.io/data-privacy-stack/presidio-anonymizer
```

Оба контейнера слушают порт `3000` и имеют встроенный healthcheck (`/health`). Актуальные релизы публикуются в `ghcr.io/data-privacy-stack`; legacy-образы `mcr.microsoft.com/presidio-*` более не обновляются, но по-прежнему работают — если используете их, для продакшена закрепляйте конкретный тег версии.

Стандартный analyzer знает только английский (`en_core_web_lg`). Для русского (PERSON и т.п.), как и в venv-версии гайда, нужна своя сборка с русской spaCy-моделью — см. раздел 2. Если русские имена не нужны, можно пропустить сборку и взять официальный образ как есть (в конфиге LiteLLM тогда `presidio_language: en`).

---

## 2. Кастомный образ analyzer с русской моделью

Каталог сборки:

```bash
mkdir -p /opt/presidio
nano /opt/presidio/analyzer-config.yml
```

`analyzer-config.yml` — конфиг NLP-движка и списка языков:

```yaml
supported_languages:
  - en
  - ru
default_score_threshold: 0.35

nlp_configuration:
  nlp_engine_name: spacy
  models:
    - lang_code: en
      model_name: en_core_web_md
    - lang_code: ru
      model_name: ru_core_news_md
```

`md` достаточно для старта. Если качество имён будет слабым — поменяйте на `en_core_web_lg` / `ru_core_news_lg` и пересоберите образ.

`/opt/presidio/Dockerfile`:

```dockerfile
FROM ghcr.io/data-privacy-stack/presidio-analyzer:latest

USER root
COPY analyzer-config.yml /app/analyzer-config.yml
ENV ANALYZER_CONF_FILE=/app/analyzer-config.yml

# предзагрузка spaCy-моделей из конфига на этапе сборки
RUN python install_nlp_models.py --analyzer_conf_file /app/analyzer-config.yml

USER 1001
```

Модели зашиваются в образ при сборке (потребуется интернет, ~100–300 МБ) — при старте контейнер ничего не скачивает.

---

## 3. docker-compose.yml для Presidio

`/opt/presidio/docker-compose.yml`:

```yaml
services:
  presidio-analyzer:
    build: .
    image: presidio-analyzer-en-ru:latest
    container_name: presidio-analyzer
    restart: unless-stopped
    environment:
      WORKERS: "2"                     # gunicorn-воркеры внутри контейнера
    ports:
      - "127.0.0.1:5002:3000"          # только для ручных проверок с хоста
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
    external: true                      # сеть, созданная docker-compose из 01d
```

Смысл настроек:

| Поле | Зачем |
|---|---|
| `networks: litellm-net (external)` | LiteLLM ходит в Presidio напрямую по имени сервиса, трафик не выходит с хоста |
| `ports: 127.0.0.1:...` | ручные curl-проверки с хоста; наружу из сети порты не торчат. Можно вообще убрать, если тесты не нужны |
| anonymizer без сборки | кастомная обёртка из venv-версии не нужна: официальный образ зафиксировал совместимые версии, проблемы `EngineResult.to_dict()` в нём нет |

Сеть `litellm-net` должна уже существовать (создаётся `docker compose up -d` в `/opt/litellm`). Если Presidio поднимается раньше LiteLLM — сначала поднимите LiteLLM.

Запуск:

```bash
cd /opt/presidio
docker compose up -d --build
docker compose ps
```

Первая сборка займёт несколько минут (скачивание spaCy-моделей). Проверка health:

```bash
curl -sS http://127.0.0.1:5002/health
curl -sS http://127.0.0.1:5001/health
```

Ручная проверка Analyzer на русском:

```bash
curl -sS http://127.0.0.1:5002/analyze \
  -H 'Content-Type: application/json' \
  -d '{
    "text": "Позвоните Ивану Петрову +7 916 123-45-67 или на ivan@example.com",
    "language": "ru"
  }'
```

Должны прийти сущности вроде `PERSON`, `PHONE_NUMBER`, `EMAIL_ADDRESS`.

---

## 4. Привязка к LiteLLM

В `/opt/litellm/litellm.env` добавьте:

```bash
PRESIDIO_ANALYZER_API_BASE=http://presidio-analyzer:3000
PRESIDIO_ANONYMIZER_API_BASE=http://presidio-anonymizer:3000
```

Имена `presidio-analyzer` / `presidio-anonymizer` резолвятся внутри общей Docker-сети — никаких `127.0.0.1` и `host.docker.internal` не нужно (`127.0.0.1` внутри контейнера LiteLLM указывал бы на сам контейнер).

В `/opt/litellm/config.yaml` к уже существующему `model_list` добавьте guardrail:

```yaml
model_list:
  - model_name: corp-llm
    litellm_params:
      model: openai/ИМЯ_МОДЕЛИ_У_ПРОВАЙДЕРА
      api_base: https://ВАШ-CUSTOM-URL/v1
      api_key: os.environ/CUSTOM_LLM_TOKEN
      timeout: 120
      stream_timeout: 120

general_settings:
  master_key: os.environ/LITELLM_MASTER_KEY

litellm_settings:
  drop_params: true
  request_timeout: 120

guardrails:
  - guardrail_name: presidio-pii
    litellm_params:
      guardrail: presidio
      mode: [pre_call, post_call]
      default_on: true
      presidio_analyzer_api_base: os.environ/PRESIDIO_ANALYZER_API_BASE
      presidio_anonymizer_api_base: os.environ/PRESIDIO_ANONYMIZER_API_BASE
      presidio_language: ru
      output_parse_pii: true
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
```

Смысл полей:

| Поле | Зачем |
|---|---|
| `guardrail: presidio` | встроенный хук LiteLLM |
| `mode: [pre_call, post_call]` | чистить и запрос к модели, и её ответ |
| `default_on: true` | работает для GUI без спец. заголовков |
| `presidio_language: ru` | язык NLP. Для английских промптов поставьте `en` |
| `output_parse_pii: true` | если в промпте `Иван` стал `<PERSON>`, в ответе клиенту LiteLLM может вернуть обратно `Иван` |
| `pii_entities_config` | какие сущности трогать и как |

Действия в `pii_entities_config`:

- `MASK` — `<EMAIL_ADDRESS>`, `<PERSON>`
- `REPLACE` — фиксированная замена
- `HASH` — хеш
- `REDACT` — вырезать
- `ENCRYPT` — шифрование (нужен ключ)

Применение: менялся и `litellm.env`, и `config.yaml` — пересоздание:

```bash
cd /opt/litellm
docker compose up -d
docker compose logs -f litellm
```

LiteLLM должен стартовать без ошибок вида `Presidio analyzer is not running`.

---

## 5. Проверка через тот же API, что и GUI

```bash
bash -c '
  set -a
  source /opt/litellm/litellm.env
  set +a
  curl -sS http://127.0.0.1:4000/v1/chat/completions \
    -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"corp-llm\",
      \"messages\": [
        {
          \"role\": \"user\",
          \"content\": \"Напиши письмо Ивану Петрову на ivan.petrov@example.com, телефон +7 916 123-45-67\"
        }
      ],
      \"max_tokens\": 200
    }"
'
```

Ожидаемое поведение:

1. В провайдер уходит уже маска: `Ивану <PERSON>` / `<EMAIL_ADDRESS>` / `<PHONE_NUMBER>`.
2. GUI получает обычный ответ; при `output_parse_pii: true` плейсхолдеры могут быть собраны обратно.
3. В логах LiteLLM видно вызов `presidio-pii` (`docker compose logs litellm | grep presidio`).

В GUI ничего дополнительно настраивать не нужно: тот же `http://IP:4000/v1`, `LITELLM_MASTER_KEY`, модель `corp-llm`.

---

## 6. Режимы: что выбрать

| Задача | `mode` |
|---|---|
| Модель не должна видеть PII | `pre_call` |
| В GUI/логи не должны утекать PII из ответа модели | `post_call` |
| И то и другое (ваш случай) | `[pre_call, post_call]` |
| Только логировать, запрос не менять | `logging_only` |

Для «модель не видит ФИО/телефоны, а оператор в GUI видит нормальный текст» — `pre_call` + `output_parse_pii: true`.

Если политика жёсткая («в чате тоже не светить PII») — оставьте `post_call` и `output_parse_pii: false`.

---

## 7. Русский язык и качество детекта

Presidio хорошо ловит формальные сущности: email, карты, IBAN, IP, URL.  
Имена и адреса зависят от spaCy-модели и **языка**, который вы передали.

Практические правила:

- Диалоги в основном на русском — `presidio_language: ru`.
- В основном английские промпты — `en`.
- Смешанные тексты: один язык на весь запрос. Presidio не детектит язык сам.
- Телефоны вида `+7 916 …` обычно ловятся стандартным `PHONE_NUMBER`.
- «Иван Петров» на `ru_core_news_md` ловится часто, но не всегда. Если мало — замените в `analyzer-config.yml` на `ru_core_news_lg` и пересоберите образ (`docker compose up -d --build`).

Свой recognizer (например корпоративный табельный номер): JSON-файл кладётся рядом с конфигом LiteLLM и монтируется в контейнер. В `docker-compose.yml` сервиса `litellm`:

```yaml
    volumes:
      - ./config.yaml:/app/config.yaml:ro
      - ./presidio_recognizers.json:/app/presidio_recognizers.json:ro
```

Подключение в `config.yaml`:

```yaml
litellm_params:
  guardrail: presidio
  presidio_ad_hoc_recognizers: /app/presidio_recognizers.json
```

Пример `/opt/litellm/presidio_recognizers.json`:

```json
[
  {
    "name": "employee_id",
    "supported_language": "ru",
    "patterns": [
      {
        "name": "tab_number",
        "regex": "\\bТАБ-\\d{5,8}\\b",
        "score": 0.8
      }
    ],
    "supported_entity": "EMPLOYEE_ID"
  }
]
```

И добавьте `EMPLOYEE_ID: MASK` в `pii_entities_config`.

---

## 8. Типовые поломки

| Симптом | Причина |
|---|---|
| LiteLLM: connection refused `presidio-analyzer:3000` | контейнер не запущен или не в сети `litellm-net`; `docker compose ps` в `/opt/presidio` |
| LiteLLM: `Presidio analyzer is not running` | Presidio ещё стартует (модель грузится в память, до минуты) или адрес в `PRESIDIO_*_API_BASE` указан с портом хоста вместо `:3000` |
| analyzer: `ValueError: language ru not supported` | LiteLLM ходит в официальный образ без русской модели — пересоберите кастомный образ из раздела 2 |
| PII не маскируется из GUI | нет `default_on: true` |
| Имена не находятся, email находится | неверный `presidio_language` или слабая spaCy-модель (перейдите на `lg`-модели) |
| 500 от analyzer на русском тексте | `ru_core_news_md` не попал в образ при сборке; смотрите `docker compose logs presidio-analyzer` |
| Ошибки сборки образа | нет доступа в интернет с хоста (Hugging Face/GitHub); повторите сборку |
| Модель «глупеет», не понимает задачу | слишком агрессивный MASK, модель видит одни `<PERSON>` |
| Стриминг в GUI странно себя ведёт | `post_call` ждёт полный ответ; для стрима чаще оставляют только `pre_call` |
| Долгий первый запрос | spaCy грузит модель в память, это разово |
| Analyzer съедает много RAM | это нормально для двух spaCy-моделей; снизьте `WORKERS` до `1` |

Порядок диагностики:

```bash
docker compose ps                       # в /opt/presidio
curl -sS http://127.0.0.1:5002/health
curl -sS http://127.0.0.1:5001/health
cd /opt/litellm && docker compose logs litellm --since 10m | grep -i presidio
```

---

## 9. Минимальный безопасный вариант

Если нужен только «не отправлять email/телефоны/карты провайдеру», без возни с именами:

```yaml
guardrails:
  - guardrail_name: presidio-pii
    litellm_params:
      guardrail: presidio
      mode: pre_call
      default_on: true
      presidio_language: ru
      output_parse_pii: true
      pii_entities_config:
        EMAIL_ADDRESS: MASK
        PHONE_NUMBER: MASK
        CREDIT_CARD: MASK
        IBAN_CODE: MASK
```

Это самый стабильный старт: сущности языконезависимые, ложных срабатываний мало, GUI менять не нужно. Для такого набора даже не обязательна русская spaCy-модель — достаточно официального образа analyzer.

Если пришлёте кусок текущего `config.yaml` (без токенов) и язык промптов в GUI (только RU / смесь), можно сузить `pii_entities_config` и выбрать один `mode` под ваш UX.
