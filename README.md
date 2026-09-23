# lite_llm_manuals — ручное развёртывание LiteLLM Proxy

## Цель проекта

Официальная документация LiteLLM - https://docs.litellm.ai/docs/simple_proxy

Набор пошаговых руководств и автоматизирующих скриптов для развёртывания **корпоративного шлюза к LLM** на базе [LiteLLM Proxy](https://docs.litellm.ai) на Ubuntu 24.04. Клиенты (Chatbox, Open WebUI, Continue и любые OpenAI-compatible приложения) обращаются только к прокси; реальный endpoint провайдера и его токен остаются скрытыми.

Полный стек включает:

- **LiteLLM Proxy** — шлюз OpenAI-compatible API на порту `4000`, проксирование на custom URL провайдера с авторизацией по токену
- **Guardrails (custom code)** — контроль запросов, маскирование email/SSN
- **Presidio Analyzer/Anonymizer** — маскирование PII (поддержка русского языка: ru-модель spaCy собирается кастомным analyzer) + ~250 кастомных правил секретов/ПИД из guardrails-llm-filter + EXTRA_RULES (гайд 09)
- **PostgreSQL** — хранение ключей, виртуальных ключей, данных Admin UI
- **Admin UI** — веб-интерфейс управления LiteLLM
- **Valkey** (Redis-совместимый) — кэш и состояние
- **nginx + Let's Encrypt** — TLS на 443, публикация наружу по домену
- **systemd**-службы (или docker compose) для всех компонентов
- **Верификация маскирования PII** — финальная проверка по логам

## Структура репозитория

- `NN_*.md` — руководства для установки **без Docker** (venv + systemd):
  - `01_setup_litellm.md` — прокси, конфиг, systemd-служба
  - `02_add_custom_code_guardrails.md` — кастомный guardrail
  - `03_debug_requests.md` — уровни логирования (`LITELLM_LOG`)
  - `04_add_presidio.md` — Presidio + guardrail `presidio-pii`
  - `05_nginx.md` — nginx + Let's Encrypt
  - `06_ui.md` — PostgreSQL + Admin UI
  - `07_valkey.md` — Valkey
  - `08_verify_guardrails_masking.md` — проверка маскирования
  - `09_custom_rules.md` — кастомные правила из guardrails-llm-filter (секреты, СНИЛС/ИНН/ОГРН); конвертер `scripts/convert_guardrails_rules.py` или готовые артефакты `artefacts/` без конвертации
- `docker_NN_*.md` — те же шаги для варианта **в Docker** (docker compose):
  - `docker_01_setup_litellm.md` … `docker_08_verify_guardrails_masking.md` — аналоги гайдов 01–08
  - `docker_09_custom_rules.md` — кастомные правила для Docker-варианта (вставка в `analyzer-config.yml` вместо патча кода)
- `config.txt` — пример параметров подключения (endpoint, токен, модель, хост) для тестового провайдера
- `scripts/` — скрипты автоматической установки (см. ниже)

## Варианты развёртывания

1. **Без Docker** (`01–09_*.md`): компоненты ставятся в venv, работают как systemd-службы. Подходит, если Docker запрещён или нужна максимальная прозрачность.
2. **В Docker** (`docker_01–09_*.md`): весь стек в контейнерах через docker compose; guardrail-код подключается bind-mount'ом с `PYTHONPATH`; Presidio с ru-моделью собирается в кастомный образ.

Оба варианта дают одинаковую функциональность (прокси + guardrails + Presidio + PostgreSQL + UI + Valkey + опциональный nginx/TLS).

## Использование скриптов

Скрипты разворачивают весь стек одной командой:

```bash
# Вариант 1: без Docker (venv + systemd)
sudo ./scripts/install_litellm.sh

# Вариант 2: в Docker (docker compose)
sudo ./scripts/install_litellm_docker.sh
```

Запускать от root или через `sudo` (скрипт проверяет). Каждый скрипт объединяет шаги всех восьми гайдов соответствующего варианта: установка пакетов, системный пользователь `litellm` и каталоги (`/opt/litellm`, `/etc/litellm`, `/var/log/litellm`, `/opt/presidio`), venv/контейнеры, файл секретов `/etc/litellm/litellm.env`, конфиги, systemd-службы/compose, nginx и финальная проверка.

Отдельно: `scripts/convert_guardrails_rules.py` — конвертер правил guardrails-llm-filter в кастомные распознаватели Presidio (гайды 09 / docker_09; не входит в установочные скрипты, запускается вручную при обновлении правил).

Альтернатива без конвертации: `artefacts/` — готовый снапшот (250 правил / 247 сущностей, язык `ru`): `custom_recognizers.yaml` (правила для Presidio), `pii_entities_config.snippet.yaml` (сущности для LiteLLM), `analyzer_server.py` (пример сервера с загрузкой YAML — для варианта без Docker), `conversion_report.md` (отчёт пропусков). Подключение — подстановкой файлов по гайдам 09 / docker_09, раздел 9; ограничения метода — там же.

## Ключевые параметры, задаваемые пользователем

Все параметры находятся в блоке констант в начале скрипта («БЛОК КОНСТАНТ — ЗАПОЛНИТЬ ПЕРЕД ЗАПУСКОМ»).

### Обязательные (скрипт прервётся с ошибкой, если не заданы)

| Параметр | Назначение |
|---|---|
| `CUSTOM_LLM_TOKEN` | Токен реального провайдера LLM (не ключ LiteLLM) |
| `LITELLM_PROVIDER_API_BASE` | Custom URL провайдера (OpenAI-compatible), обычно с `/v1` на конце |
| `LITELLM_PROVIDER_MODEL_NAME` | Имя модели у провайдера (без префикса; в конфиг добавится `openai/`) |

### Настройка модели и публикация

| Параметр | Назначение |
|---|---|
| `LITELLM_MODEL_ALIAS` | Алиас модели, под которым её видит GUI |
| `LITELLM_LOG` | Уровень логирования: `INFO` — обычный режим, `DEBUG` — траблшутинг |
| `PRESIDIO_LANGUAGE` | Язык Presidio: `ru` (сборка кастомного analyzer с ru-моделью) или `en` (официальный образ) |
| `LITELLM_PUBLIC_DOMAIN` | Домен с A/AAAA-записью на сервер; **пусто** = без nginx/TLS (порт 4000 напрямую) |
| `CERTBOT_EMAIL` | E-mail для Let's Encrypt (обязателен при заданном домене) |

### Admin UI

| Параметр | Назначение |
|---|---|
| `UI_USERNAME` | Логин администратора UI |
| `UI_PASSWORD` | Пароль UI; пусто = генерируется автоматически |

### Секреты (пусто = генерируются автоматически и сохраняются в `litellm.env`)

| Параметр | Назначение |
|---|---|
| `LITELLM_MASTER_KEY` | Ключ (`sk-litellm-...`), которым GUI ходит в LiteLLM |
| `LITELLM_DB_PASSWORD` | Пароль пользователя PostgreSQL `litellm` |
| `LITELLM_SALT_KEY` | Соль шифрования ключей провайдеров в UI — **не менять после старта** |
| `VALKEY_PASSWORD` | Пароль Valkey |

### Прочее

| Параметр | Назначение |
|---|---|
| `RUN_MASKING_VERIFICATION` | `true`/`false` — выполнять финальную проверку маскирования PII по логам |

Блок путей (`LITELLM_HOME`, `LITELLM_CONF_DIR`, `LITELLM_LOG_DIR`, `PRESIDIO_HOME`, `PRESIDIO_LOG_DIR`) обычно менять не нужно.
