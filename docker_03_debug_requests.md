Docker-версия гайда [03_debug_requests.md](03_debug_requests.md): как увидеть точный текст запроса к провайдеру для LiteLLM, развёрнутого по [01d_setup_litellm.md](01d_setup_litellm.md). Отличия от venv-варианта: уровень логирования задаётся в `litellm.env`, а журнал смотрится через `docker compose logs` вместо `journalctl`.

---

## 1. Включить уровень DEBUG

Главное для отладки — уровень логирования в `/opt/litellm/litellm.env`.
Строку:

```bash
LITELLM_LOG=info
```

замените на:

```bash
LITELLM_LOG=debug
```

`DEBUG` — самый подробный: показывает и call-параметры, и тело входящего запроса, и то, что уходит провайдеру.

Настройки `dump_requests: true` / `dump_responses: true` в `litellm_settings`
для этого **не требуются** (и полноценной записи тел запросов не дают) —
достаточно `DEBUG`.

Альтернатива — флаг запуска: в `docker-compose.yml` добавьте в `command` аргумент `--detailed_debug`:

```yaml
    command: ["--config=/app/config.yaml", "--port", "4000", "--detailed_debug"]
```

**Важно:** `env_file` и `command` читаются только при создании контейнера. Применять так:

```bash
cd /opt/litellm
docker compose up -d        # пересоздаст контейнер с новым env/command
```

`docker compose restart litellm` новые значения `litellm.env` **не подхватит** — типичная ловушка Docker-варианта.

---

## 2. Смотреть логи

Канал журнала (аналог `journalctl -u litellm -f`):

```bash
cd /opt/litellm
docker compose logs -f litellm
```

Отфильтровать по модели/guardrail:

```bash
docker compose logs --since 10m litellm | grep -i presidio
```

Искать конкретный текст запроса в последних логах:

```bash
docker compose logs litellm | grep -i "messages"
```

Логи контейнера также доступны напрямую (`docker logs litellm`) и, если на хосте работает journald c драйвером `journald`, через `journalctl -u docker`. Практичнее первый вариант.

Чтобы журналы не заполнили диск, ограничьте ротацию в `docker-compose.yml`:

```yaml
services:
  litellm:
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "5"
```

и примените `docker compose up -d`.

---

## 3. Как выглядит маскированный запрос в логах

В DEBUG-выводе LiteLLM обычно печатает что-то вроде:

```text
provider_call: Performing OpenAI call with raw request
raw_request =
{
  "model": "ИМЯ_МОДЕЛИ",
  "messages": [
    {
      "role": "user",
      "content": "Напиши письмо <PERSON> на <EMAIL_ADDRESS>, телефон <PHONE_NUMBER>"
    }
  ],
  ...
}
```

Ключевой признак того, что охранник отработал: в поле `content` вместо реальных ФИО/email/телефона стоят **плейсхолдеры `<PERSON>`, `<EMAIL_ADDRESS>`, `<PHONE_NUMBER>`** (или иные ваши masks). Если там по-прежнему `Иван Петров` / `ivan@example.com` — значит `pre_call` не сработал.

---

## 4. Как убедиться — логика vs лог

Важно: verbosity покажет `provider_call`, но лучший способ убедиться, что guardrail работает — это сверить **цель лога**:

1. В логе видно `prereq > presidio-pii` / запись `anonymous_text` — это то, что уже обезличенное.
2. Сразу следом `provider_call` с этим же masked-текстом в `content`.

Схема в логе такая:

```text
… presidio: anonymized text: "Напиши письмо <PERSON> на <EMAIL_ADDRESS> …"
… provider_call: { "content": "Напиши письмо <PERSON> на <EMAIL_ADDRESS> …" }
```

`anonymized text` — это маска, `provider_call` — это то, что в итоге ушло на custom URL. Совпадение этих двух строк — и есть доказательство маскировки на сервере.

---

## 5. Про запись логов в файл

> **Внимание: этот вариант не работает.** Проверено на практике
> (litellm 1.98.0): настройка вида
>
> ```yaml
> litellm_settings:
>   dump_requests: /var/log/litellm/requests.jsonl
>   dump_responses: /var/log/litellm/responses.jsonl
> ```
>
> не создаёт файлов — `dump_requests`/`dump_responses` как пути к файлам
> LiteLLM не поддерживает (неизвестные ключи в `litellm_settings` молча
> игнорируются). Значения `dump_requests: true` тоже не пишут тела запросов.

Практичный способ получить полные тела запросов и ответов — уровень
`LITELLM_LOG=DEBUG` плюс `docker compose logs`:

```bash
docker compose logs litellm --since 10m | grep -E "EMAIL REDACTED|<PERSON>|<PHONE_NUMBER>"
```

В Docker-варианте каталог `/var/log/litellm` на хосте **не нужен** — journald-хаки из venv-версии (`StandardOutput=append:...` в unit-файле) не применяются. Если нужен файловый журнал:

```bash
docker compose logs litellm > /tmp/litellm.log
```

или постоянное сохранение — направьте вывод `docker compose logs` в файл через cron/systemd-timer. Обычно достаточно `docker compose logs` — файловый журнал внутри контейнера для этих задач не нужен.

---

## Важные предупреждения

1. **DEBUG-логи содержат потенциально чувствительные данные.** Даже маскированные запросы и, особенно, входящие от GUI — это персональные данные. Включайте `DEBUG` только на время диагностики, потом возвращайте `LITELLM_LOG=INFO` и не забудьте `docker compose up -d` (см. ловушку с `restart` в разделе 1).
2. **Не путайте** `provider_call` в логе (то, что уходит провайдеру — должно быть маскировано) и входящий от GUI запрос (там настоящий текст, прежде чем его обработает guardrail). Сравнивать для проверки маскирования надо именно `anonymized text` и `provider_call`.

Минимальный короткий чек-лист:

```bash
# 1. включить DEBUG в /opt/litellm/litellm.env
# 2. docker compose up -d   (не restart!)
# 3. запустить один тестовый запрос с GUI или curl
# 4. docker compose logs litellm | grep anonymized
# 5. docker compose logs litellm | grep provider_call
# 6. сверить, что в provider_call стоят <...> плейсхолдеры
# 7. вернуть LITELLM_LOG=INFO и снова docker compose up -d
```

Если после этого в `provider_call` всё ещё виден реальный PII — это признак, что guardrail не подключился (например, `default_on: false` или промах `mode`). Тогда вернитесь к проверке конфига ([02d_add_custom_code_guardrails.md](02d_add_custom_code_guardrails.md)), но чаще всего в этой точке видно, что маскирование на месте.
