GUIDE - https://github.com/cloud-ru-tech/guardrails-llm-filter + https://microsoft.github.io/presidio/analyzer/adding_recognizers/

Гайд расширяет стек из `04_add_presidio.md`: берём ~266 regex-правил маскирования секретов и ПИД из open-source проекта [guardrails-llm-filter](https://github.com/cloud-ru-tech/guardrails-llm-filter) (Cloud.ru) и подключаем их к уже работающему Presidio Analyzer как кастомные распознаватели. Docker-вариант того же гайда — `docker_09_custom_rules.md` (там правила вставляются в `analyzer-config.yml` вместо патча кода).

Что даёт: Presidio из коробки ловит «универсальные» ПИД (email, карты, IBAN, IP, имена через NER), но **не знает про секреты** — API-ключи, токены, пароли, DSN, приватные ключи, российские документы (СНИЛС/ИНН/ОГРН). Правила guardrails-llm-filter закрывают именно этот провал: модель перестаёт видеть `sk_live_...`, `ghp_...`, `postgres://user:pass@...`, PEM-ключи и т.п.

Схема не меняется — добавляются только правила внутрь Analyzer:

```text
GUI  →  LiteLLM :4000
               →  Presidio Analyzer  :5002   (найти PII  + 250 новых правил)
               →  Presidio Anonymizer :5001  (замаскировать — без изменений)
               →  модель по custom URL + token
```

Anonymizer трогать не нужно: он просто заменяет найденные спаны на плейсхолдеры.

---

## 1. Источник правил

В репозитории guardrails-llm-filter два файла правил (формат — Go RE2 regex + плейсхолдеры):

| Файл | Правил | Что внутри |
|---|---|---|
| `configs/guardrails_regex_rules.yaml` | 46 | hand-written: учётные данные, пароли, DSN, IP, ПИД (СНИЛС/ИНН/ОГРН/ФИО/адрес) |
| `configs/guardrails_regex_rules.gitleaks.generated.yaml` | 220 | сгенерированы из `configs/gitleaks.toml`: API-ключи и токены сотен сервисов (AWS, GitHub, Slack, Stripe, ...) |
| `EXTRA_RULES` в конвертере | 4 | добавлены вручную (нет в guardrails-llm-filter): публичные SSH-ключи, OpenRouter `sk-or-v1-`, ключи `sk-rt_`, токены LLM-провайдеров `v1.<128 base64url>` |

```bash
git clone https://github.com/cloud-ru-tech/guardrails-llm-filter
```

Клон нужен только на машине, где запускается конвертер (можно на локальной, не на сервере).

---

## 2. Почему не копируем всё подряд

Правила писались под Go-движок с возможностями, которых нет у Presidio `PatternRecognizer`: валидаторы контрольных сумм (Luhn, mod97, СНИЛС/ИНН/ОГРН), entropy-пороги, pre-filter по ключевым словам, min_length, маскирование только capture-group. Поэтому конвертер не копирует, а **адаптирует**, и логирует каждое решение.

### 2.1 Пропуск: дубликаты встроенных распознавателей Presidio

Если Presidio уже ловит сущность — правило пропускается (факт фиксируется в отчёте конвертации):

| Правила guardrails | Покрывается | Причина |
|---|---|---|
| `ip-addrs.*` (8 правил: ipv4/ipv6 ± cidr/public/private) | `IP_ADDRESS` | IpRecognizer: IPv4/IPv6/CIDR + валидация `ipaddress` |
| `pii.email` | `EMAIL_ADDRESS` | EmailRecognizer |
| `pii.fin.credit-card`, `pii.fin.credit-card.context` | `CREDIT_CARD` | CreditCardRecognizer + Luhn |
| `pii.fin.iban` | `IBAN_CODE` | IbanRecognizer + mod97 |
| `pii.fio-ru`, `pii.fio-ru.initials`, `pii.fio-ru.short` | `PERSON` | spaCy NER `ru_core_news_md` |
| `api_keys.stripe-key`, `api_keys.stripe-restricted` | `access_tokens.stripe-access-token.gl` | intra-дубликат: gitleaks-правило шире (`sk|rk` + `test|live|prod`) |
| `access_tokens.npm-token` | `access_tokens.npm-access-token.gl` | intra-дубликат: тот же regex |
| `access_tokens.private-key.gl` | `access_tokens.private-key-pem` | intra-дубликат: PEM-правило корректнее |
| `access_tokens.bittrex-secret-key.gl` | `access_tokens.bittrex-secret-key.gl` (первое вхождение) | идентичный regex в наборе |

Итого из 270 правил (266 из репозитория + 4 дополнительных): **250 добавляется, 20 пропускается**. Полная таблица с причинами — в `conversion_report.md` (артефакт конвертера, п. 3).

Исключение из «дублей»: `pii.phone-ru` **добавляется** как отдельная сущность `PHONE_RU`. Встроенный PhoneRecognizer (библиотека phonenumbers) не знает RU-региона (`DEFAULT_SUPPORTED_REGIONS` = US,GB,DE,FR,IL,IN,CA,BR) — «слитые» номера вида `89030054516` / `+79030054516` без разделителей он не ловит. Правило ловит форматы `8XXXXXXXXXX`, `+7XXXXXXXXXX`, `+7 XXX XXX-XX-XX`, `8 (XXX) XXX XX XX`.

Дополнительные правила (`EXTRA_RULES` в конвертере, сущности `SSH_PUBLIC_KEY`, `OPENROUTER_API_KEY`, `SK_RT_API_KEY`, `LLM_PROVIDER_TOKEN`):

| Правило | Regex (суть) | Что ловит |
|---|---|---|
| `extra.ssh-public-key` | `ssh-(ed25519\|rsa\|dss\|ecdsa-...)` + base64-блоб ≥60 | публичные SSH-ключи (`authorized_keys`); приватные PEM покрывает `private-key-pem` |
| `extra.openrouter-api-key` | `sk-or-v1-` + 64 hex | ключи OpenRouter |
| `extra.sk-rt-key` | `sk-rt_` + 60–96 hex | провайдерские ключи вида `sk-rt_...` |
| `extra.llm-provider-token` | `v1.` + ≥100 base64url | токены LLM-провайдеров (формат mwsapis и подобных); длина 100+ отсекает версии `v1.2.3` |

### 2.2 Адаптация под PatternRecognizer

| Механика Go-фильтра | Что делает конвертер |
|---|---|
| `capture_groups` (маскировать только группу) | Presidio маскирует весь match. Замыкающая группа-граница `(?:...|$)` в конце regex превращается в lookahead `(?=...)`, ведущая `(?:^|\...)` — в lookbehind `(?<=...)`: маска не съедает символы-разделители вокруг секрета |
| `validators` (СНИЛС/ИНН/ОГРН/ОГРНИП) | Контрольные суммы не переносятся. Вместо них ключевое слово вшивается в regex: `(?i)(?:снилс|snils)[^\d\r\n]{0,20}(\d{3}...)` — число маскируется только рядом со словом «СНИЛС» |
| `keywords` (pre-filter) | Для правил, где ключевое слово было единственной защитой от FP (twilio, ИНН, ОГРН...), — вшивается в regex (см. выше); для остальных передаётся как `context` (повышает score при найденном контексте) |
| `min_length` | Вшивается в regex, где длина не была задана (например, generic-long-token: `{32,}`) |
| `entropy` (Shannon-порог) | Отбрасывается с записью в отчёте. FP-риск чуть выше, чем у Go-фильтра; для маскирования это приемлемо (лучше замаскировать лишнее, чем пропустить секрет) |
| `banlist` (исключения, напр. частые пароли) | Отбрасывается: в Presidio `deny_list` — противоположная семантика (список того, что НАДО ловить) |
| score | `0.8` для всех правил (порог `ALL: 0.5` из гайда 04 проходит), `0.6` для `generic-token` (широкое правило) |

Каждый regex после трансформации компилируется модулем `regex` с флагами Presidio (`DOTALL|MULTILINE|IGNORECASE`); не скомпилировался — конвертер пробует оригинал, не получилось — правило пропускается с логом.

---

## 3. Конвертер

Скрипт `scripts/convert_guardrails_rules.py` читает оба YAML репозитория-источника и генерирует готовые артефакты. Зависимости: Python 3.10+, `pyyaml`, `regex` (тот же модуль, что использует Presidio):

```bash
pip install pyyaml regex
```

> Если конвертер запускать не хочется — в репозитории лежит готовый снапшот: папка `artefacts/` (250 правил / 247 сущностей, язык `ru`). Процесс работы с ним и ограничения — раздел 9 «Метод подстановки».

Запуск (на любой машине; сервер не нужен):

```bash
python3 scripts/convert_guardrails_rules.py \
  --repo /путь/к/guardrails-llm-filter \
  --language ru \
  --out-dir presidio_custom_rules \
  --self-test --dataset
```

Параметры:

| Параметр | Зачем |
|---|---|
| `--repo` | путь к клону guardrails-llm-filter (обязателен) |
| `--language` | язык распознавателей: `ru` (по умолчанию, как `presidio_language` в гайде 04) или `en` |
| `--out-dir` | каталог артефактов (по умолчанию `./presidio_custom_rules`) |
| `--self-test` | прогнать сэмплы по ~51 правилу (включая 4 формата российских телефонов и 4 дополнительных правила) + FP-корпус (git SHA, UUID, даты, код): 0 FAIL / 0 FP ожидается |
| `--dataset` | прогнать официальный тестовый датасет guardrails (`tests/dataset/guardrails_dataset.jsonl`, 280 кейсов): 97 пройдено / 32 пропущено (дубликаты Presidio) / 0 провалено |

Артефакты в `--out-dir`:

| Файл | Формат | Куда идёт |
|---|---|---|
| `custom_recognizers.json` (~110 КБ) | ad-hoc формат LiteLLM/Presidio: `[{name, supported_language, supported_entity, patterns, context?}]` | **основной для venv**: грузится analyzer'ом при старте (п. 4); он же — файл для `presidio_ad_hoc_recognizers` (альтернатива, п. 6) |
| `custom_recognizers.registry.yaml` (~85 КБ) | записи для `recognizer_registry.recognizers` (с `supported_languages:` списком) | только для Docker-варианта — см. `docker_09_custom_rules.md` |
| `pii_entities_config.snippet.yaml` | `СУЩНОСТЬ: MASK` × 247 | в `pii_entities_config` конфига LiteLLM |
| `conversion_report.md` | отчёт: таблицы пропущенных (с причинами) и добавленных (с адаптациями) | читать вам; это и есть «лог пропусков» |

Пример записи из `custom_recognizers.json`:

```json
{
  "name": "pii.docs.snils",
  "supported_language": "ru",
  "supported_entity": "SNILS",
  "patterns": [
    {
      "name": "pii.docs.snils",
      "regex": "(?i)(?:снилс|snils)[^\\d\\r\\n]{0,20}(\\d{3}[\\s-]?\\d{3}[\\s-]?\\d{3}[\\s-]?\\d{2})",
      "score": 0.8
    }
  ]
}
```

Имя сущности = плейсхолдер исходного правила: маска будет выглядеть как `<SNILS>`, `<STRIPE_ACCESS_TOKEN>`, `<DB_DSN>`, `<PEM_KEY>` — модель по плейсхолдеру понимает, *что* было скрыто.

---

## 4. Подключение правил к Analyzer

Правила регистрируются в реестре Analyzer при старте — LiteLLM ничего дополнительно не отправляет.

1. Скопируйте артефакты на сервер:

```bash
sudo cp presidio_custom_rules/custom_recognizers.json /etc/presidio/custom_recognizers.json
sudo chown litellm:litellm /etc/presidio/custom_recognizers.json
```

2. В `/opt/presidio/analyzer_server.py` добавьте загрузку после создания `analyzer` (и до `app = Flask(...)` — или в любом месте после `analyzer`):

```python
import json
from presidio_analyzer import PatternRecognizer

CUSTOM_RECOGNIZERS_FILE = "/etc/presidio/custom_recognizers.json"


def _load_custom_recognizers(path):
    """Кастомные правила из guardrails-llm-filter (гайд 09)."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            entries = json.load(f)
    except FileNotFoundError:
        print(f"custom recognizers: {path} не найден, пропускаю")
        return []
    recognizers = []
    for entry in entries:
        try:
            recognizers.append(PatternRecognizer.from_dict(entry))
        except Exception as exc:  # одно битое правило не должно ронять сервис
            print(f"custom recognizer {entry.get('name')} пропущен: {exc}")
    print(f"custom recognizers: загружено {len(recognizers)} из {len(entries)}")
    return recognizers


for _rec in _load_custom_recognizers(CUSTOM_RECOGNIZERS_FILE):
    analyzer.registry.add_recognizer(_rec)
```

3. Перезапуск и проверка лога:

```bash
sudo systemctl restart presidio-analyzer
sudo journalctl -u presidio-analyzer -n 20 --no-pager | grep custom
# ожидается: custom recognizers: загружено 250 из 250
```

Быстрая проверка новых сущностей напрямую:

```bash
curl -sS http://127.0.0.1:5002/analyze \
  -H 'Content-Type: application/json' \
  -d '{
    "text": "СНИЛС 112-233-445 95, ИНН 7707083893, ключ sk_live_51Nq2Lk9s9mPqR2sA1bCdEfGhIjKlMnOpQrStUvWxYz1234567890",
    "language": "ru",
    "entities": ["SNILS", "INN_ORG", "STRIPE_ACCESS_TOKEN"]
  }'
```

Должны прийти три результата: `SNILS`, `INN_ORG`, `STRIPE_ACCESS_TOKEN` со score 0.8.

---

## 5. Привязка к LiteLLM

LiteLLM передаёт в `/analyze` список сущностей из `pii_entities_config` — Presidio возвращает результаты только по ним. Поэтому каждая новая сущность обязана попасть в конфиг.

В `/etc/litellm/config.yaml` добавьте в существующий `pii_entities_config` (guardrail `presidio-pii` из гайда 04) все 247 строк из `pii_entities_config.snippet.yaml` (250 правил → 247 сущностей: `BEARER_TOKEN`, `API_KEY_HEADER` и `TOKEN` используются двумя правилами каждая):

```yaml
      pii_entities_config:
        PERSON: MASK
        EMAIL_ADDRESS: MASK
        PHONE_NUMBER: MASK
        # ... существующие сущности из гайда 04 без изменений ...
        # --- добавлено из pii_entities_config.snippet.yaml (гайд 09) ---
        1PASSWORD_SECRET_KEY: MASK
        ADDRESS: MASK
        ADOBE_CLIENT_ID: MASK
        # ... все строки из сниппета ...
        DB_DSN: MASK
        INN_ORG: MASK
        INN_PERSON: MASK
        OGRN: MASK
        OGRNIP: MASK
        PASSWORD: MASK
        PEM_KEY: MASK
        PHONE_RU: MASK
        SNILS: MASK
        STRIPE_ACCESS_TOKEN: MASK
        TWILIO_AUTH_TOKEN: MASK
        URL_WITH_CREDS: MASK
        # ... и т.д. — вставляйте файл целиком, не выборочно
```

Перезапуск:

```bash
sudo systemctl restart litellm
```

Проверка через тот же API, что и GUI:

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
        "content": "Проверь подключение: postgres://admin:s3cretPw@db.corp.local:5432/prod и токен sk_live_51Nq2Lk9s9mPqR2sA1bCdEfGhIjKlMnOpQrStUvWxYz1234567890"
      }
    ],
    "max_tokens": 100
  }'
```

В провайдер должен уйти текст с `<DB_DSN>` и `<STRIPE_ACCESS_TOKEN>` (проверяется по логам из гайда 08: `sudo journalctl -u litellm`, либо DEBUG-уровнем из гайда 03).

### 5.1. Конфликт с email_detector из гайда 02

Если стоит guardrail `email_detector` (`my_guardrails.py`) из гайда 02, он срабатывает **раньше** presidio и заменяет email-подобные фрагменты на `[EMAIL REDACTED]`. В строках вида `postgres://admin:s3cretPw@db.corp.local:5432/prod` он съедает `s3cretPw@db.corp.local` — после этого regex `DB_DSN` (и `URL_WITH_CREDS`) уже не матчится: пароль скрыт, но пользователь и хост провайдеру видны.

Решение: убрать из `my_guardrails.py` email-маскирование (`EMAIL_RE.sub("[EMAIL REDACTED]", ...)`), оставив SSN-блок. Email теперь маскирует presidio (`EMAIL_ADDRESS: MASK`) — с восстановлением значения клиенту через `output_parse_pii`, а `[EMAIL REDACTED]` терял данные безвозвратно. SSN-политика гайда 02 сохраняется.

Контракт при правке `my_guardrails.py`: `apply_guardrail()` обязан **вернуть `inputs`** (dict), не `None` — иначе LiteLLM падает с `AttributeError: 'NoneType' object has no attribute 'get'` и клиент получает 400. После правки — `sudo systemctl restart litellm`.

Проверка после правки (модель `corp-llm`):

```bash
# 1. DSN маскируется целиком: модель видит <DB_DSN_1>
#    «перечисли имена всех плейсхолдеров вида <ИМЯ_НОМЕР>» → DB_DSN_1
# 2. Email маскируется и восстанавливается: модель видит <EMAIL_ADDRESS_1>,
#    в ответе клиенту — исходный адрес
# 3. SSN по-прежнему блокируется: HTTP 400 "Request blocked: SSN detected"
```

Малая модель ненадёжна как верификатор «видела ли она маску» — просите перечислить **имена плейсхолдеров** (имя без значения не восстанавливается и доказывает, что модель видела маску), а не «первое слово по символам».

---

## 6. Альтернатива: presidio_ad_hoc_recognizers

Если патчить analyzer нельзя, тот же `custom_recognizers.json` подключается через LiteLLM — он будет отправлять правила в каждом запросе `/analyze`:

```bash
sudo cp presidio_custom_rules/custom_recognizers.json /etc/litellm/custom_recognizers.json
sudo chown litellm:litellm /etc/litellm/custom_recognizers.json
```

```yaml
      presidio_ad_hoc_recognizers: /etc/litellm/custom_recognizers.json
```

Минусы: ~110 КБ в **каждом** запросе к analyzer (LiteLLM ещё и чанкит большие тексты — каждый чанк понесёт полную пачку правил), плюс разбор 250 распознавателей на каждый запрос. Регистрация при старте (п. 4) свободна от этого — используйте её как основной способ; ad-hoc оставьте для быстрых экспериментов с отдельными правилами.

---

## 7. Особенности поведения

| Поведение | Пример | Почему |
|---|---|---|
| Маска накрывает и ключевое слово | `ИНН 7707083893` → `<INN_ORG>` | Presidio маскирует весь match; для keyword-gated правил слово — часть match. Это осознанная адаптация вместо контрольных сумм |
| Маска включает ведущий `?`/`&` | `?auth=Bearer%20abc...` → `<URL_ENCODED_BEARER_TOKEN>` | regex правила начинается с разделителя запроса; особенность исходного правила |
| `generic-token` срабатывает реже остальных | score 0.6 | широкое правило (любой токен-подобный идентификатор), чтобы не задавить порогом более точные |
| FP-риск чуть выше, чем у Go-фильтра | длинный случайный идентификатор может уйти в `<GENERIC_TOKEN>` | entropy-пороги не переносятся; компенсировано вшиванием ключевых слов и FP-корпусом в self-test |
| Правила не ловят секрет без контекста | `7707083893` без слова «ИНН» не маскируется | защита от FP вместо валидатора контрольной суммы |

Если какое-то пропущенное правило всё-таки нужно (например, `pii.fio-ru` при слабом NER) — верните его вручную: возьмите regex из исходного YAML, примените трансформации п. 2.2 (или попросите конвертер добавить override) и допишите запись в `custom_recognizers.json`.

---

## 8. Типовые поломки

| Симптом | Причина |
|---|---|
| Новые правила не срабатывают через LiteLLM, но `/analyze` напрямую работает | сущности не добавлены в `pii_entities_config` (или добавлены не все) — LiteLLM фильтрует по ним |
| `/analyze` напрямую не находит сущность | правила сгенерированы с другим `--language`, чем `presidio_language` (перегенерируйте) |
| В логе `custom recognizers: загружено 0 из 250` | неверный путь в `CUSTOM_RECOGNIZERS_FILE` или права на файл |
| `загружено 249 из 250` | одно правило не прошло `PatternRecognizer.from_dict` — имя правила в логе рядом; проверьте, что JSON не правили вручную |
| LiteLLM: `Presidio analyzer is not running` | analyzer не поднялся после правок — `sudo journalctl -u presidio-analyzer` |
| Маска съедает лишний символ рядом | правило добавлено вручную без lookahead/lookbehind-трансформации — см. п. 2.2 |
| DSN вида `postgres://user:pass@host` маскируется частично (пароль → `[EMAIL REDACTED]`) | конфликт с `email_detector` из гайда 02 — см. п. 5.1 |
| После правки `my_guardrails.py` все запросы падают с 400 | `apply_guardrail()` вернул `None` вместо `inputs` — см. п. 5.1 |
| Обновили guardrails-llm-filter — правила не поменялись | артефакты не перегенерированы; перезапустите конвертер и повторите пп. 4–5 |

Порядок диагностики:

```bash
sudo systemctl status presidio-analyzer --no-pager
curl -sS http://127.0.0.1:5002/analyze -H 'Content-Type: application/json' \
  -d '{"text":"СНИЛС 112-233-445 95","language":"ru","entities":["SNILS"]}'
sudo journalctl -u litellm -n 200 --no-pager
```

---

## 9. Метод подстановки: готовые артефакты без конвертера

Если запускать конвертер не хочется (нет Python/зависимостей, правила нужны «как есть»), используйте готовый снапшот в папке `artefacts/` этого репозитория:

| Файл | Что это |
|---|---|
| `artefacts/custom_recognizers.yaml` | 250 правил / 247 сущностей, язык `ru` — готовый YAML для Presidio |
| `artefacts/analyzer_server.py` | пример analyzer-сервера (база из гайда 04) с загрузкой этого YAML при старте |
| `artefacts/pii_entities_config.snippet.yaml` | 247 строк `СУЩНОСТЬ: MASK` для `pii_entities_config` LiteLLM |
| `artefacts/conversion_report.md` | статический отчёт: что пропущено (дубликаты Presidio) и какие адаптации применены |

### 9.1 Процесс подключения

1. Скопируйте файл правил на сервер и пример сервера:

```bash
sudo cp artefacts/custom_recognizers.yaml /etc/presidio/custom_recognizers.yaml
sudo chown litellm:litellm /etc/presidio/custom_recognizers.yaml
sudo cp artefacts/analyzer_server.py /opt/presidio/analyzer_server.py
```

2. `analyzer_server.py` грузит `/etc/presidio/custom_recognizers.yaml` при старте (функция `_load_custom_recognizers`): разворачивает `supported_languages` → по распознавателю на язык, регистрирует через `analyzer.registry.add_recognizer`, пропускает битое правило без падения сервиса. Если файла нет — стартует без кастомных правил (warning в логе).

3. Перезапуск и проверка (как в п. 4):

```bash
sudo systemctl restart presidio-analyzer
sudo journalctl -u presidio-analyzer -n 20 --no-pager | grep custom
# ожидается: custom recognizers: загружено 250 из 250
```

4. Привязка к LiteLLM — без изменений по п. 5: все 247 сущностей из `artefacts/pii_entities_config.snippet.yaml` — в `pii_entities_config` конфига LiteLLM, затем `sudo systemctl restart litellm`.

### 9.2 Ограничения метода подстановки

Метод подстановки берёт файлы как есть — в отличие от конвертера, ничего не пересчитывает:

| Ограничение | Следствие |
|---|---|
| Снапшот на дату генерации | новые правила в guardrails-llm-filter и новые форматы секретов не появятся сами; обновление — только перезапуском конвертера (п. 3) и заменой файлов |
| Язык зафиксирован: `ru` | при `presidio_language: en` правила не сработают: Presidio фильтрует распознаватели по языку. Для `en` — прогнать конвертер с `--language en` |
| Решения SKIP/OVERRIDE зашиты | пропуски (дубликаты Presidio, intra-дубли) и адаптации (keyword в regex, score 0.8/0.6) уже применены; изменить их можно только ручным редактированием YAML — тогда это уже не «подстановка», и проще вернуться к конвертеру |
| Отчёт пропусков статический | `conversion_report.md` отражает снапшот; после ручных правок YAML он рассинхронизируется |
| Новые форматы секретов | добавить можно только правкой regex в YAML вручную (с учётом трансформаций п. 2.2) или через `EXTRA_RULES` в конвертере |
| Совместимость проверена на момент генерации | regex совместимы с модулем `regex` актуального presidio-analyzer; при сильном обновлении Presidio (смена regex-движка/формата распознавателей) файл нужно перегенерировать |

Когда какой метод: подстановка — быстрый старт и «поставил и забыл»; конвертер — контроль пропусков/адаптаций, другой язык, обновления набора правил.
