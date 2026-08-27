Чтобы увидеть точный текст запроса к провайдеру, сделаем уровень `DEBUG`.

---

## 1. Включить уровень DEBUG

Главное для отладки — уровень логирования в `/etc/litellm/litellm.env`.
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

Перезапуск:

```bash
sudo systemctl restart litellm
```

---

## 2. Смотреть логи

Канал журнала:

```bash
sudo journalctl -u litellm -f
```

Отфильтровать по модели/guardrail:

```bash
sudo journalctl -u litellm --since "10 minutes ago" | grep -i presidio
```

Искать конкретный текст запроса в последних логах:

```bash
sudo journalctl -u litellm -n 500 | grep -i "messages"
```

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
`LITELLM_LOG=DEBUG` плюс `journalctl`:

```bash
sudo journalctl -u litellm --since "10 minutes ago" --no-pager | grep -E "EMAIL REDACTED|<PERSON>|<PHONE_NUMBER>"
```

Каталог `/var/log/litellm` всё равно полезно иметь созданным с нужными правами
(systemd-служба ссылается на него через `ReadWritePaths`):

```bash
sudo mkdir -p /var/log/litellm
sudo chown -R litellm:litellm /var/log/litellm
sudo systemctl restart litellm
```

Если нужен именно файловый журнал, добавьте `StandardOutput=append:/var/log/litellm/litellm.log`
в `[Service]` секции юнита `litellm.service`, но обычно достаточно journald.

---

## Важные предупреждения

1. **DEBUG-логи содержат потенциально чувствительные данные.** Даже маскированные запросы и, особенно, входящие от GUI — это персональные данные. Включайте `DEBUG` только на время диагностики, потом возвращайте `LITELLM_LOG=INFO`.
2. **Не путайте** `provider_call` в логе (то, что уходит провайдеру — должно быть маскировано) и входящий от GUI запрос (там настоящий текст, прежде чем его обработает guardrail). Сравнивать для проверки маскирования надо именно `anonymized text` и `provider_call`.

Минимальный короткий чек-лист:

```bash
# 1. включить DEBUG в env
# 2. restart litellm
# 3. запустить один тестовый запрос с GUI или curl
# 4. journalctl -u litellm -n 300 | grep anonymized
# 5. journalctl -u litellm -n 300 | grep provider_call
# 6. сверить, что в provider_call стоят <...> плейсхолдеры
```

Если после этого в `provider_call` всё ещё виден реальный PII — это признак, что guardrail не подключился (например, `default_on: false` или промах `mode`). Тогда вернитесь к проверке конфига, но чаще всего в этой точке видно, что маскирование на месте.