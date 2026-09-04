Docker-версия гайда [02_add_custom_code_guardrails.md](02_add_custom_code_guardrails.md): подключение кастомного guardrail-кода к LiteLLM, развёрнутому по [01d_setup_litellm.md](01d_setup_litellm.md). Вместо `/etc/litellm` и `PYTHONPATH` для systemd — bind-mount каталога с кодом в контейнер.

Код guardrail тот же, что в venv-версии: блокировка запросов с SSN и маскирование email.

---

## 1. Создать `/opt/litellm/guardrails/my_guardrails.py`

Каталог `guardrails/` рядом с `docker-compose.yml`:

```bash
mkdir -p /opt/litellm/guardrails
nano /opt/litellm/guardrails/my_guardrails.py
```

```python
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
```

---

## 2. Подключить код в docker-compose.yml

Откройте `/opt/litellm/docker-compose.yml` и добавьте сервису `litellm` монтирование каталога с guardrail-кодом и `PYTHONPATH`:

```yaml
services:
  litellm:
    image: ghcr.io/berriai/litellm:main-stable
    container_name: litellm
    restart: unless-stopped
    ports:
      - "4000:4000"
    env_file:
      - litellm.env
    environment:
      PYTHONPATH: /app/custom        # чтобы import my_guardrails находил модуль
    volumes:
      - ./config.yaml:/app/config.yaml:ro
      - ./guardrails:/app/custom:ro   # <-- новый mount
    command: ["--config=/app/config.yaml", "--port", "4000"]
    # ... healthcheck, networks — без изменений
```

Альтернатива — собрать собственный образ поверх официального (код «вшивается» в образ, mount не нужен):

```dockerfile
FROM ghcr.io/berriai/litellm:main-stable
COPY guardrails/my_guardrails.py /app/my_guardrails.py
```

```bash
docker build -t litellm-custom /opt/litellm
# в docker-compose.yml: image: litellm-custom
```

Для начала достаточно варианта с bind-mount: правки кода применяются рестартом контейнера, без пересборки.

---

## 3. Добавить раздел `guardrails` в `config.yaml`

В `/opt/litellm/config.yaml` к существующим настройкам добавьте:

```yaml
litellm_settings:
  drop_params: true
  request_timeout: 120
  dump_requests: true
  dump_responses: true

guardrails:
  - guardrail_name: email_detector
    litellm_params:
      guardrail: my_guardrails.myCustomGuardrail
      mode: pre_call
      default_on: true
```

Оставьте один guardrail. Два разных API сразу (`custom_code` и класс) только путают.

`guardrail: my_guardrails.myCustomGuardrail` — это `файл.Класс`, без префикса `custom_code.`.

---

## 4. Применить изменения

Добавлялись `environment` и `volumes` в compose — это пересоздание контейнера, а не restart:

```bash
cd /opt/litellm
docker compose up -d
docker compose logs -f litellm
```

Если `PYTHONPATH=/app/custom` уже был прописан и менялся только `.py`-файл — достаточно рестарта:

```bash
docker compose restart litellm
```

Модуль импортируется при старте прокси, поэтому правки кода без рестарта не применяются, даже если файл лежит на хосте по bind-mount.

Права на файл с кодом:

```bash
chmod 640 /opt/litellm/guardrails/my_guardrails.py
```

---

## 5. Проверка

Email должен уйти провайдеру уже замаскированным:

```bash
bash -c '
  set -a
  source /opt/litellm/litellm.env
  set +a
  curl -sS http://127.0.0.1:4000/v1/chat/completions \
    -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"corp-llm\",
      \"messages\": [{\"role\": \"user\", \"content\": \"Ответь одним словом: user@mail.ru\"}],
      \"max_tokens\": 32
    }"
'
```

В логе до вызова провайдера ищите не исходный email, а маску:

```bash
docker compose logs litellm --since 10m | grep -E "EMAIL REDACTED|user@mail.ru|apply_guardrail|provider"
```

Ожидание:

- входящий запрос ещё с `user@mail.ru` (это нормально, GUI так прислал);
- после `email_detector` / `apply_guardrail` в теле к модели — `Ответь одним словом: [EMAIL REDACTED]`;
- HTTP 200, не 500.

Блокировка SSN:

```bash
bash -c '
  set -a
  source /opt/litellm/litellm.env
  set +a
  curl -sS -o /tmp/ssn.json -w "%{http_code}\n" http://127.0.0.1:4000/v1/chat/completions \
    -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
    -H "Content-Type: application/json" \
    -d "{
      \"model\": \"corp-llm\",
      \"messages\": [{\"role\": \"user\", \"content\": \"ssn 123-45-6789\"}],
      \"max_tokens\": 32
    }"
  cat /tmp/ssn.json
'
```

Должен быть **400** и `Request blocked: SSN detected`, без похода к модели.

---

## 6. Если снова 500

Смотрите первую строку `TypeError` / `NameError` в `docker compose logs litellm` после рестарта. Частые причины:

| Лог | Что сделать |
|---|---|
| `unexpected keyword argument 'texts'` | переименуйте первый аргумент в `texts` и обрабатывайте список строк |
| `object ... can't be used in 'await'` | метод всё ещё `def`, нужен `async def` |
| `No module named my_guardrails` | проверьте mount `./guardrails:/app/custom:ro` и `PYTHONPATH=/app/custom`, затем `docker compose up -d` |
| правки `.py` не применяются | модуль импортируется при старте — `docker compose restart litellm` |
| email не маскируется, но 200 OK | нет `default_on: true` |
| SSN не блокируется | нет `default_on: true` или guardrail не подхватился |

Итого: ошибки 500 обычно возникают из‑за неверной сигнатуры `apply_guardrail`. После замены файла, одного `guardrail` с `default_on: true` и рестарта контейнера curl с `user@mail.ru` должен проходить с HTTP 200, а в запросе к custom URL останется `[EMAIL REDACTED]`.

> Примечание: на уровне `LITELLM_LOG=INFO` тело запроса в журнал не пишется,
> поэтому маску `[EMAIL REDACTED]` через `docker compose logs ... | grep` вы не увидите.
> Чтобы проверить маскирование по логам, временно поставьте `LITELLM_LOG=DEBUG`
> (см. [03d_debug_requests.md](03d_debug_requests.md)) и повторите запрос.
