Как логами подтвердить, что presidio-guardrail из [04_add_presidio.md](04_add_presidio.md) действительно маскирует PII на реальных запросах. Процедура временная: включаем DEBUG → снимаем доказательства → выключаем. Основано на [03_debug_requests.md](03_debug_requests.md) (механика DEBUG), но с конкретными критериями доказательства маскирования и обязательным выключением.

Проверено на практике (litellm main-stable): строка-доказательство выглядит так:

```text
LiteLLM Proxy:DEBUG: presidio.py:519 - redacted_text: {'text': 'Запиши контакты: <PERSON>, email [EMAIL REDACTED], телефон <PHONE_NUMBER> ...'}
```

---

## 1. План проверки

1. Включить `DEBUG` (раздел 2) — **временно**.
2. Отправить контрольный запрос с заведомо известными (вымышленными) PII-значениями (раздел 3).
3. Снять доказательства в файл и проверить три критерия (раздел 4).
4. Выключить DEBUG, удалить временный файл с логами (раздел 5).

> **Важно:** в DEBUG-логах входящий запрос присутствует с **настоящим** текстом (guardrail маскирует то, что уходит провайдеру, а не то, что пришло). Логи на время проверки — это носитель персональных данных: не складывайте их в постоянные каталоги, удалите после проверки.

---

## 2. Включить DEBUG

В `/etc/litellm/litellm.env` строку:

```bash
LITELLM_LOG=info
```

замените на:

```bash
LITELLM_LOG=debug
```

и перезапустите:

```bash
sudo systemctl restart litellm
```

При старте в логе появится баннер про производительность (`Performance warning: DEBUG mode...`) — это норма, он уйдёт вместе с DEBUG.

---

## 3. Контрольный запрос с маркерными значениями

Отправьте запрос через тот же API, что и GUI, с вымышленными значениями — они же будут маркерами поиска в логах:

```bash
curl -s http://127.0.0.1:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"corp-llm","messages":[{"role":"user","content":"Запиши контакты: Иван Тестовый, email ivan.test@example.com, телефон +7 913 555-12-34, карта 4111 1111 1111 1111"}],"max_tokens":50}' \
  | python3 -m json.tool
```

Смысл значений-маркеров: `Иван Тестовый`, `ivan.test@example.com`, `+7 913 555-12-34`, `4111 1111 1111 1111` — легко grep'аются и заведомо не встречаются в других запросах.

Дополнительно: сделайте 2–3 запроса с обычного GUI/клиента — проверка должна быть именно **на реальном трафике**, а не только на контрольном запросе.

---

## 4. Снять доказательства и проверить критерии

Сохраните окно логов в файл (права 600 — там будет сырой текст запросов):

```bash
sudo journalctl -u litellm --since "15 minutes ago" --no-pager \
  | sudo tee /tmp/guardrail-check.log > /dev/null
sudo chmod 600 /tmp/guardrail-check.log
```

### Критерий 1: presidio сформировал маску

```bash
grep "redacted_text" /tmp/guardrail-check.log
```

Ожидается строка вида:

```text
LiteLLM Proxy:DEBUG: presidio.py:519 - redacted_text: {'text': 'Запиши контакты: <PERSON>, email [EMAIL REDACTED], телефон <PHONE_NUMBER> ...'}
```

### Критерий 2 (главный): до провайдера дошло маскированное

Найдите в логе текст, который уходит провайдеру, и убедитесь, что в нём плейсхолдеры:

```bash
grep -oE 'Запиши контакты[^"]{0,120}' /tmp/guardrail-check.log | sort | uniq -c
```

Ожидание — текст к провайдеру содержит `<PERSON_1>`, `[EMAIL REDACTED]`, `<PHONE_NUMBER_2>` (нумерация сущностей — норма):

```text
... Запиши контакты: <PERSON_1>, email [EMAIL REDACTED], телефон <PHONE_NUMBER_2> ...
```

### Критерий 3 (инверсный): исходный PII в исходящем запросе отсутствует

```bash
grep -c "ivan.test@example.com" /tmp/guardrail-check.log
```

Сырые значения встречаются только в строках **входящего** запроса (LiteLLM логирует то, что пришло от клиента). Ключевой вопрос не «есть ли PII в логе», а **есть ли он в исходящем к провайдеру тексте** (критерий 2). Если в исходящем — маскирование не работает.

### Что ещё подтверждает работу

При `output_parse_pii: true` ([04_add_presidio.md](04_add_presidio.md), раздел про режимы) ответ модели содержит те же плейсхолдеры — модель пишет `[EMAIL REDACTED]` буквально, если получила его на вход. Это видно прямо в ответе API без логов.

Про виды плейсхолдеров: `<PERSON_1>` — оператор `MASK`, `[EMAIL REDACTED]` — оператор `REDACT`; вид зависит от `pii_entities_config` в конфиге ([04_add_presidio.md](04_add_presidio.md)).

---

## 5. Выключить DEBUG и убрать артефакты

```bash
# 1. вернуть уровень логирования
sudo sed -i 's/^LITELLM_LOG=debug/LITELLM_LOG=info/' /etc/litellm/litellm.env
sudo systemctl restart litellm

# 2. убедиться, что сервис жив
systemctl is-active litellm
curl -sS http://127.0.0.1:4000/health/liveliness

# 3. удалить файл с сырыми логами
sudo rm -f /tmp/guardrail-check.log
```

Проверьте уровень в логе: строка DEBUG больше не появляется.

---

## 6. Типовые результаты

| Наблюдение | Вывод |
|---|---|
| В `redacted_text` и в исходящем тексте плейсхолдеры, сырой PII только во входящих строках | guardrail работает, доказательство снято |
| Есть `redacted_text`, но исходящий текст содержит исходные значения | пре-маскирование не применилось к запросу — проверьте `mode`/`default_on` в конфиге |
| Строки `redacted_text` нет вообще | presidio-guardrail не в цепочке: не подключён в конфиге или упал при старте; смотрите ошибки подключения к presidio-analyzer |
| Часть сущностей не замаскировалась (например, номер карты на русском тексте) | детект не нашёл сущность — это вопрос качества, а не подключения; см. раздел «Русский язык и качество детекта» в [04_add_presidio.md](04_add_presidio.md) и добавьте pattern/контекст |
| Запрос падает 500, в логе таймаут presidio-analyzer | анализатор не отвечает; проверьте systemd-службу presidio |

---

## Короткий чек-лист

```bash
# 1. /etc/litellm/litellm.env: LITELLM_LOG=debug, systemctl restart litellm
# 2. curl с вымышленными PII + пара реальных запросов с GUI
# 3. journalctl --since ... > /tmp/guardrail-check.log && chmod 600
# 4. grep "redacted_text"            — маска сформирована
# 5. grep -oE 'маркер[^"]{0,120}'    — в исходящем тексте <PERSON_N>/[EMAIL REDACTED]
# 6. инверсный grep исходных значений — их нет в исходящем
# 7. LITELLM_LOG=info, systemctl restart litellm, rm /tmp/guardrail-check.log
```
