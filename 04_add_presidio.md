Уточню ваш текущий контур LiteLLM и свежую схему интеграции Presidio, затем дам настройку без Docker под ваш GUI.
Сверюсь с актуальной схемой LiteLLM + Presidio, чтобы дать рабочий конфиг под ваш Ubuntu-прокси.
Зафиксирую, что PII пойдёт через Presidio, и дам схему под ваш текущий Ubuntu-прокси без Docker.
Presidio в LiteLLM — это не плагин внутри процесса, а **два локальных HTTP-сервиса**. LiteLLM перед вызовом модели (и/или после ответа) отправляет текст в Analyzer, затем в Anonymizer и уже обезличенный запрос пускает на ваш custom URL.

Схема для вашего контура:

```text
GUI  →  LiteLLM :4000
              →  Presidio Analyzer  :5002   (найти PII)
              →  Presidio Anonymizer :5001  (замаскировать)
              →  модель по custom URL + token
```

Для GUI обязательно `default_on: true`: обычный десктопный клиент поле `guardrails` не присылает.

---

## 1. Что поставить

На той же Ubuntu, отдельный venv. spaCy-модели тяжёлые, это нормально.

```bash
sudo mkdir -p /opt/presidio /etc/presidio /var/log/presidio
sudo chown -R litellm:litellm /opt/presidio /var/log/presidio

sudo -u litellm python3 -m venv /opt/presidio/venv
sudo -u litellm /opt/presidio/venv/bin/pip install -U pip
sudo -u litellm /opt/presidio/venv/bin/pip install \
  'presidio-analyzer' \
  'presidio-anonymizer' \
  'spacy' \
  'flask' \
  'gunicorn'

# английский + русский (для PERSON/локаций)
sudo -u litellm /opt/presidio/venv/bin/python -m spacy download en_core_web_md
sudo -u litellm /opt/presidio/venv/bin/python -m spacy download ru_core_news_md
```

`md` достаточно для старта. Если качество имён будет слабым — поставьте `en_core_web_lg` и `ru_core_news_lg`.

---

## 2. HTTP-обёртки под официальный API Presidio

LiteLLM дергает стандартные ручки: `POST /analyze` и `POST /anonymize`. Без Docker удобнее поднять их самим.

`/opt/presidio/analyzer_server.py`:

```python
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
```

`/opt/presidio/anonymizer_server.py`:

```python
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
    # В presidio-anonymizer >= 2.2.35x anonymize() возвращает EngineResult
    # без метода .to_dict() — сериализуем вручную.
    return jsonify(
        {
            "text": result.text,
            "items": [item.to_dict() for item in result.items],
        }
    )
```

Права:

```bash
sudo chown litellm:litellm /opt/presidio/*.py
```

---

## 3. systemd для Presidio

`/etc/systemd/system/presidio-analyzer.service`:

```ini
[Unit]
Description=Presidio Analyzer
After=network-online.target

[Service]
Type=simple
User=litellm
Group=litellm
WorkingDirectory=/opt/presidio
ExecStart=/opt/presidio/venv/bin/gunicorn \
  --bind 127.0.0.1:5002 \
  --workers 2 \
  --timeout 120 \
  analyzer_server:app
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true

[Install]
WantedBy=multi-user.target
```

`/etc/systemd/system/presidio-anonymizer.service`:

```ini
[Unit]
Description=Presidio Anonymizer
After=network-online.target

[Service]
Type=simple
User=litellm
Group=litellm
WorkingDirectory=/opt/presidio
ExecStart=/opt/presidio/venv/bin/gunicorn \
  --bind 127.0.0.1:5001 \
  --workers 1 \
  --timeout 60 \
  anonymizer_server:app
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true

[Install]
WantedBy=multi-user.target
```

Слушайте только `127.0.0.1`: GUI ходит в LiteLLM, Presidio наружу не нужен.

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now presidio-analyzer presidio-anonymizer
curl -sS http://127.0.0.1:5002/health
curl -sS http://127.0.0.1:5001/health
```

Ручная проверка Analyzer:

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

В `/etc/litellm/litellm.env` добавьте:

```bash
PRESIDIO_ANALYZER_API_BASE=http://127.0.0.1:5002
PRESIDIO_ANONYMIZER_API_BASE=http://127.0.0.1:5001
```

В `/etc/litellm/config.yaml` к уже существующему `model_list` добавьте guardrail:

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

Перезапуск:

```bash
sudo systemctl restart litellm
sudo journalctl -u litellm -n 100 -f
```

LiteLLM должен стартовать без ошибок вида `Presidio analyzer is not running`.

---

## 5. Проверка через тот же API, что и GUI

```bash
source /etc/litellm/litellm.env

curl -sS http://127.0.0.1:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "corp-llm",
    "messages": [
      {
        "role": "user",
        "content": "Напиши письмо Ивану Петрову на ivan.petrov@example.com, телефон +7 916 123-45-67"
      }
    ],
    "max_tokens": 200
  }'
```

Ожидаемое поведение:

1. В провайдер уходит уже маска: `Ивану <PERSON>` / `<EMAIL_ADDRESS>` / `<PHONE_NUMBER>`.
2. GUI получает обычный ответ; при `output_parse_pii: true` плейсхолдеры могут быть собраны обратно.
3. В логах LiteLLM видно вызов `presidio-pii`.

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
- «Иван Петров» на `ru_core_news_md` ловится часто, но не всегда. Если мало — ставьте `lg` и/или свой recognizer.

Свой recognizer (например корпоративный табельный номер) кладётся JSON-файлом и подключается так:

```yaml
litellm_params:
  guardrail: presidio
  presidio_ad_hoc_recognizers: /etc/litellm/presidio_recognizers.json
```

Пример `/etc/litellm/presidio_recognizers.json`:

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
| LiteLLM: connection refused :5002/:5001 | не запущен analyzer/anonymizer |
| PII не маскируется из GUI | нет `default_on: true` |
| Имена не находятся, email находится | неверный `presidio_language` или слабая spaCy-модель |
| 500 от analyzer на русском тексте | не скачан `ru_core_news_md` / язык не в `supported_languages` |
| 500 от anonymizer (`Presidio anonymizer returned HTTP 500` в логах LiteLLM) | в свежих `presidio-anonymizer` у `EngineResult` нет `.to_dict()`; обновите `anonymizer_server.py` (см. п.2) и проверьте traceback: `sudo journalctl -u presidio-anonymizer -n 50 --no-pager` |
| Модель «глупеет», не понимает задачу | слишком агрессивный MASK, модель видит одни `<PERSON>` |
| Стриминг в GUI странно себя ведёт | `post_call` ждёт полный ответ; для стрима чаще оставляют только `pre_call` |
| Долгий первый запрос | spaCy грузит модель в память, это разово |

Порядок диагностики:

```bash
sudo systemctl status presidio-analyzer presidio-anonymizer litellm --no-pager
curl -sS http://127.0.0.1:5002/health
curl -sS http://127.0.0.1:5001/health
sudo journalctl -u litellm -n 200 --no-pager
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

Это самый стабильный старт: сущности языконезависимые, ложных срабатываний мало, GUI менять не нужно.

Если пришлёте кусок текущего `config.yaml` (без токенов) и язык промптов в GUI (только RU / смесь), можно сузить `pii_entities_config` и выбрать один `mode` под ваш UX.