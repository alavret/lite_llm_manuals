Подключение Guardrails к litellm (https://docs.litellm.ai/docs/proxy/guardrails/custom_guardrail)

## 1. Создать `/etc/litellm/my_guardrails.py`

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

## 2. Добавить раздел `guardrails` в `config.yaml`

Оставьте один guardrail. Два разных API сразу (`custom_code` и класс) только путают.

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

`guardrail: my_guardrails.myCustomGuardrail` — это `файл.Класс`, без префикса `custom_code.`.

Если Python вдруг перестанет видеть модуль (сейчас он подхватился), в `/etc/litellm/litellm.env` добавьте:

```bash
PYTHONPATH=/etc/litellm
LITELLM_LOG=DEBUG
```

Права:

```bash
sudo chown root:litellm /etc/litellm/my_guardrails.py
sudo chmod 640 /etc/litellm/my_guardrails.py
sudo systemctl restart litellm
```

---

## 3. Проверка

Email должен уйти провайдеру уже замаскированным:

```bash
sudo bash -c '
  set -a
  source /etc/litellm/litellm.env
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
sudo journalctl -u litellm -n 200 --no-pager | grep -E "EMAIL REDACTED|user@mail.ru|apply_guardrail|provider"
```

Ожидание:

- входящий запрос ещё с `user@mail.ru` (это нормально, GUI так прислал);
- после `email_detector` / `apply_guardrail` в теле к модели — `Ответь одним словом: [EMAIL REDACTED]`;
- HTTP 200, не 500.

Блокировка SSN:

```bash
sudo bash -c '
  set -a
  source /etc/litellm/litellm.env
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

## 4. Если снова 500

Смотрите первую строку `TypeError` / `NameError` после рестарта. Частые причины:

| Лог | Что сделать |
|---|---|
| `unexpected keyword argument 'texts'` | переименуйте первый аргумент в `texts` и обрабатывайте список строк |
| `object ... can't be used in 'await'` | метод всё ещё `def`, нужен `async def` |
| `No module named my_guardrails` | `PYTHONPATH=/etc/litellm` и restart |
| email не маскируется, но 200 OK | нет `default_on: true` |
| SSN не блокируется | нет `default_on: true` или guardrail не подхватился |

Итого: ошибки 500 обычно возникают из‑за неверной сигнатуры `apply_guardrail`. После замены файла и одного `guardrail` с `default_on: true` curl с `user@mail.ru` должен проходить с HTTP 200, а в запросе к custom URL останется `[EMAIL REDACTED]`.

> Примечание: на уровне `LITELLM_LOG=INFO` тело запроса в журнал не пишется,
> поэтому маску `[EMAIL REDACTED]` через `journalctl ... | grep` вы не увидите.
> Чтобы проверить маскирование по логам, временно поставьте `LITELLM_LOG=DEBUG`
> (см. `03_debug_requests.md`) и повторите запрос.