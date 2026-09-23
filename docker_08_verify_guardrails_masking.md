Docker-версия гайда [08_verify_guardrails_masking.md](08_verify_guardrails_masking.md): тот же результат — логами подтвердить, что presidio-guardrail из [04d_add_presidio.md](04d_add_presidio.md) действительно маскирует PII на реальных запросах, — но DEBUG включается через env-файл compose-стека, доказательства снимаются из `docker logs`, и после каждой правки env контейнер пересоздаётся (а не рестартует). Механика DEBUG описана в [03d_debug_requests.md](03d_debug_requests.md).

Проверено на практике (litellm main-stable в Docker): строка-доказательство выглядит так:

```text
LiteLLM Proxy:DEBUG: presidio.py:519 - redacted_text: {'text': 'Запиши контакты: <PERSON>, email [EMAIL REDACTED], телефон <PHONE_NUMBER> ...'}
```

Отличия от venv-варианта:

- env правится в `/opt/litellm/litellm.env`; применяется **только** `docker compose up -d` — простой `restart` новый уровень логирования не подхватит (env читается при создании контейнера);
- доказательства снимаются из `docker compose logs` — журналирование Docker перезаписывается при ротации (`max-size` из [01d_setup_litellm.md](01d_setup_litellm.md)), а при пересоздании контейнера старые DEBUG-логи теряются вовсе: снимайте доказательства **до** отката;
- после пересоздания `litellm` нужен рестарт `litellm-nginx` (ловушка stale DNS — см. «Типовые поломки» в [05d_nginx.md](05d_nginx.md)).

---

## 1. План проверки

1. Включить `DEBUG` (раздел 2) — **временно**.
2. Отправить контрольный запрос с заведомо известными (вымышленными) PII-значениями (раздел 3).
3. Снять доказательства из логов контейнера и проверить три критерия (раздел 4).
4. Выключить DEBUG, убрать временный файл с логами (раздел 5).

> **Важно:** в DEBUG-логах входящий запрос присутствует с **настоящим** текстом (guardrail маскирует то, что уходит провайдеру, а не то, что пришло). Файл с выгрузкой логов — носитель персональных данных: храните его в `/tmp`, а после проверки удаляйте.

---

## 2. Включить DEBUG

В `/opt/litellm/litellm.env` добавьте (или замените, если строка уже есть):

```bash
LITELLM_LOG=debug
```

и примените:

```bash
cd /opt/litellm
docker compose up -d
docker restart litellm-nginx
```

Требуется именно `up -d` (пересоздание контейнера), а не `restart`: переменные env-файла читаются только при создании. После пересоздания `litellm` получает новый IP — nginx кэширует адрес upstream'а при старте, поэтому сразу рестартуйте и `litellm-nginx`, иначе снаружи получите 502 ([05d_nginx.md](05d_nginx.md), раздел «Типовые поломки»).

При старте в логе появится баннер про производительность (`Performance warning: DEBUG mode...`) — это норма, он уйдёт вместе с DEBUG.

Проверка готовности:

```bash
curl -sS http://127.0.0.1:4000/health/liveliness
```

---

## 3. Контрольный запрос с маркерными значениями

Отправьте запрос через тот же API, что и GUI, с вымышленными значениями — они же будут маркерами поиска в логах:

```bash
cd /opt/litellm
source ./litellm.env

curl -s http://127.0.0.1:4000/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"corp-llm","messages":[{"role":"user","content":"Запиши контакты: Иван Тестовый, email ivan.test@example.com, телефон +7 913 555-12-34, карта 4111 1111 1111 1111"}],"max_tokens":50}' \
  | python3 -m json.tool
```

Смысл значений-маркеров: `Иван Тестовый`, `ivan.test@example.com`, `+7 913 555-12-34`, `4111 1111 1111 1111` — легко grep'аются и заведомо не встречаются в других запросах.

Если виртуальный ключ упёрся в бюджет (`429 ExceededBudget`) — это норма, проверку выполняйте мастер-ключом или заведите отдельный тестовый ключ с большим лимитом.

Дополнительно: сделайте 2–3 запроса с обычного GUI/клиента — проверка должна быть именно **на реальном трафике**, а не только на контрольном запросе.

---

## 4. Снять доказательства и проверить критерии

Сохраните окно логов контейнера в файл (права 600 — там будет сырой текст запросов):

```bash
cd /opt/litellm
docker compose logs --since 15m litellm --no-log-prefix \
  | sudo tee /tmp/guardrail-check.log > /dev/null
sudo chmod 600 /tmp/guardrail-check.log
```

Снимайте выгрузку **до** отката DEBUG: при пересоздании контейнера (раздел 5) старые DEBUG-логи пропадут вместе с контейнером.

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

При `output_parse_pii: true` ([04d_add_presidio.md](04d_add_presidio.md)) LiteLLM **восстанавливает исходные значения** в ответе: модель получает на вход плейсхолдеры (`<PERSON_1>`, `[EMAIL REDACTED]`), а клиенту в ответе возвращаются настоящие значения (проверено на практике: на вход уходило `Меня зовут <PERSON_1>`, в ответе клиент получил реальное имя). Это не утечка — провайдер PII не видел; восстановление происходит на стороне LiteLLM после получения ответа. Поэтому главный критерий того, что маскирование работает, — критерий 2 (плейсхолдеры в исходящем к провайдеру тексте), а не содержимое ответа.

Про виды плейсхолдеров: `<PERSON_1>` — оператор `MASK`, `[EMAIL REDACTED]` — оператор `REDACT`; вид зависит от `pii_entities_config` в конфиге ([04d_add_presidio.md](04d_add_presidio.md)).

---

## 5. Выключить DEBUG и убрать артефакты

Если по требованиям эксплуатации нужно постоянное логирование текстов запросов (DEBUG) — раздел можно пропустить: оставьте `LITELLM_LOG=debug` в `litellm.env`, но учтите, что в логи контейнера попадает сырой PII из входящих запросов (ограничьте доступ к хосту и `docker logs`).

```bash
cd /opt/litellm

# 1. вернуть уровень логирования (sed правит env — пересоздание, не restart)
sed -i 's/^LITELLM_LOG=debug/LITELLM_LOG=info/' litellm.env
docker compose up -d
docker restart litellm-nginx

# 2. убедиться, что стек жив
docker compose ps
curl -sS http://127.0.0.1:4000/health/liveliness
curl -sS -o /dev/null -w '%{http_code}\n' https://litellm.domain.com/ui/

# 3. удалить файл с сырыми логами
rm -f /tmp/guardrail-check.log
```

Проверьте уровень в логе: строка DEBUG больше не появляется:

```bash
docker compose logs --since 5m litellm | grep -c DEBUG
```

Если строки в env не было (добавляли временно) — удалите её вовсе: `sed -i '/^LITELLM_LOG=/d' litellm.env`.

---

## 6. Типовые результаты

| Наблюдение | Вывод |
|---|---|
| В `redacted_text` и в исходящем тексте плейсхолдеры, сырой PII только во входящих строках | guardrail работает, доказательство снято |
| Есть `redacted_text`, но исходящий текст содержит исходные значения | пре-маскирование не применилось к запросу — проверьте `mode`/`default_on` в конфиге |
| Строки `redacted_text` нет вообще | presidio-guardrail не в цепочке: не подключён в конфиге или упал при старте; смотрите ошибки подключения к контейнерам presidio-analyzer/anonymizer (`docker compose logs presidio-analyzer`) |
| Часть сущностей не замаскировалась (например, номер карты на русском тексте) | детект не нашёл сущность — это вопрос качества, а не подключения; см. раздел «Русский язык и качество детекта» в [04d_add_presidio.md](04d_add_presidio.md) и добавьте pattern/контекст |
| Запрос падает 500, в логе таймаут presidio-analyzer | контейнер анализатора не отвечает; `docker compose ps`, логи presidio-контейнеров |
| После включения DEBUG снаружи 502, а `curl http://127.0.0.1:4000/health/liveliness` отвечает | пропущен `docker restart litellm-nginx` после пересоздания litellm (stale DNS) — см. «Типовые поломки» в [05d_nginx.md](05d_nginx.md) |
| После отката DEBUG логи остались прежними (DEBUG всё ещё пишется) | правили env при работающем контейнере: нужен `docker compose up -d`, а не `restart` |

---

## Короткий чек-лист

```bash
# 1. /opt/litellm/litellm.env: LITELLM_LOG=debug; docker compose up -d; docker restart litellm-nginx
# 2. curl с вымышленными PII + пара реальных запросов с GUI
# 3. docker compose logs --since 15m litellm > /tmp/guardrail-check.log && chmod 600
# 4. grep "redacted_text"            — маска сформирована
# 5. grep -oE 'маркер[^"]{0,120}'    — в исходящем тексте <PERSON_N>/[EMAIL REDACTED]
# 6. инверсный grep исходных значений — их нет в исходящем
# 7. LITELLM_LOG=info; docker compose up -d; docker restart litellm-nginx; rm /tmp/guardrail-check.log
```
