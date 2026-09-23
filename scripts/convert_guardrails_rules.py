#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Конвертер правил guardrails-llm-filter (cloud-ru-tech) в кастомные
regex-распознаватели Presidio для LiteLLM. Гайд: 09_custom_rules.md.

Источник правил: https://github.com/cloud-ru-tech/guardrails-llm-filter
  - configs/guardrails_regex_rules.yaml                    (46 hand-written правил)
  - configs/guardrails_regex_rules.gitleaks.generated.yaml (220 правил из gitleaks.toml)

Что делает:
  1. Пропускает правила, дублирующие встроенные распознаватели Presidio
     (IP_ADDRESS, EMAIL_ADDRESS, PHONE_NUMBER, CREDIT_CARD, IBAN_CODE, PERSON),
     а также внутрисетевые дубликаты — каждое пропущенное правило попадает в отчёт.
  2. Адаптирует regex-ы под PatternRecognizer (модуль regex, флаги
     DOTALL|MULTILINE|IGNORECASE, результат = весь match):
       - замыкающая группа-граница  (?:X|$)  ->  (?=X|$)   (lookahead)
       - ведущая группа-граница     (?:^|X)  ->  (?<=^|X)  (lookbehind)
       - правила, полагавшиеся на validators/keywords/min_length (СНИЛС, ИНН,
         ОГРН, ОГРНИП, twilio, generic-long-token), заменяются на адаптированные
         regex-ы с вшитым ключевым словом/длиной (checksum-валидация в Presidio
         pattern-распознавателях недоступна — это честно фиксируется в отчёте).
  3. Генерирует:
       custom_recognizers.json           - ad-hoc распознаватели (формат LiteLLM
                                           presidio_ad_hoc_recognizers и
                                           PatternRecognizer.from_dict)
       custom_recognizers.registry.yaml  - записи для секции
                                           recognizer_registry.recognizers
                                           (analyzer-config.yml, Docker-вариант)
       pii_entities_config.snippet.yaml  - новые сущности для guardrail presidio-pii
       conversion_report.md              - отчёт: добавлено / пропущено + причины
  4. Режим --self-test: прогон синтетических сэмплов и "чистого" корпуса
     (проверка ложных срабатываний) по сконвертированным правилам.
     Режим --dataset: прогон официального датасета guardrails-llm-filter
     (tests/dataset/guardrails_dataset.jsonl).

Зависимости: pip install pyyaml regex

Примеры:
  ./convert_guardrails_rules.py --repo ~/github/guardrails-llm-filter --language ru
  ./convert_guardrails_rules.py --repo . --language ru --self-test --dataset
"""

import argparse
import json
import sys
from pathlib import Path

import regex as re
import yaml

# Presidio PatternRecognizer компилирует паттерны модулем `regex` с этими
# глобальными флагами (значение по умолчанию global_regex_flags).
GLOBAL_FLAGS = re.DOTALL | re.MULTILINE | re.IGNORECASE

DEFAULT_SCORE = 0.8   # > порога ALL: 0.5 из presidio_score_thresholds
LOW_SCORE = 0.6       # для generic-правил (повышенный риск FP)

SOURCE_FILES = [
    "configs/guardrails_regex_rules.yaml",
    "configs/guardrails_regex_rules.gitleaks.generated.yaml",
]

# ---------------------------------------------------------------------------
# Дополнительные правила, ОТСУТСТВУЮЩИЕ в guardrails-llm-filter (добавлены
# вручную по запросу). Формат записи - как у правил источника после загрузки.
# ---------------------------------------------------------------------------
EXTRA_RULES = [
    {
        # Публичные SSH-ключи (authorized_keys): ssh-ed25519/rsa/dss/ecdsa +
        # base64-блоб. Приватные PEM-ключи покрывает access_tokens.private-key-pem.
        "rule_id": "extra.ssh-public-key",
        "group": "EXTRA",
        "source": "extra",
        "regex": r"\bssh-(?:ed25519|rsa|dss|ecdsa-sha2-nistp(?:256|384|521)) "
                 r"[A-Za-z0-9+/]{60,}={0,3}(?![A-Za-z0-9+/=])",
        "keywords": None, "entropy": None, "min_length": None,
        "validators": None, "banlist": None, "capture_groups": None,
        "placeholder": "SSH_PUBLIC_KEY",
    },
    {
        # OpenRouter API key: sk-or-v1- + 64 hex.
        "rule_id": "extra.openrouter-api-key",
        "group": "EXTRA",
        "source": "extra",
        "regex": r"\bsk-or-v1-[a-f0-9]{64}\b",
        "keywords": None, "entropy": None, "min_length": None,
        "validators": None, "banlist": None, "capture_groups": None,
        "placeholder": "OPENROUTER_API_KEY",
    },
    {
        # Провайдерский ключ вида sk-rt_ + 60-96 hex.
        "rule_id": "extra.sk-rt-key",
        "group": "EXTRA",
        "source": "extra",
        "regex": r"\bsk-rt_[a-f0-9]{60,96}\b",
        "keywords": None, "entropy": None, "min_length": None,
        "validators": None, "banlist": None, "capture_groups": None,
        "placeholder": "SK_RT_API_KEY",
    },
    {
        # Токены LLM-провайдеров вида v1.<128 base64url-символов>
        # (формат mwsapis и подобных). Длина 100+ отсекает версии (v1.2.3).
        # Граница: только символы, способные продолжить токен (точка
        # предложения в конце НЕ должна ломать матч).
        "rule_id": "extra.llm-provider-token",
        "group": "EXTRA",
        "source": "extra",
        "regex": r"\bv1\.[A-Za-z0-9_-]{100,}(?![A-Za-z0-9_-])",
        "keywords": None, "entropy": None, "min_length": None,
        "validators": None, "banlist": None, "capture_groups": None,
        "placeholder": "LLM_PROVIDER_TOKEN",
    },
]

# ---------------------------------------------------------------------------
# Правила, ДУБЛИРУЮЩИЕ встроенные распознаватели Presidio -> пропускаем.
#   rule_id -> (сущность Presidio, причина)
# ---------------------------------------------------------------------------
SKIP_PRESIDIO = {
    "ip-addrs.ipv4":         ("IP_ADDRESS",   "IpRecognizer: IPv4 + валидация ipaddress"),
    "ip-addrs.ipv4-cidr":    ("IP_ADDRESS",   "IpRecognizer: IPv4/CIDR + валидация"),
    "ip-addrs.ipv4-public":  ("IP_ADDRESS",   "IpRecognizer: IPv4 + валидация"),
    "ip-addrs.ipv4-private": ("IP_ADDRESS",   "IpRecognizer: IPv4 + валидация"),
    "ip-addrs.ipv6":         ("IP_ADDRESS",   "IpRecognizer: IPv6 + валидация"),
    "ip-addrs.ipv6-cidr":    ("IP_ADDRESS",   "IpRecognizer: IPv6/CIDR + валидация"),
    "ip-addrs.ipv6-public":  ("IP_ADDRESS",   "IpRecognizer: IPv6 + валидация"),
    "ip-addrs.ipv6-private": ("IP_ADDRESS",   "IpRecognizer: IPv6 + валидация"),
    "pii.email":             ("EMAIL_ADDRESS", "EmailRecognizer (полное покрытие)"),
    # pii.phone-ru НЕ пропускаем: PhoneRecognizer (phonenumbers) не знает
    # RU-региона (DEFAULT_SUPPORTED_REGIONS = US,GB,DE,FR,IL,IN,CA,BR) и не
    # ловит голые номера 8XXXXXXXXXX / +7XXXXXXXXXX без разделителей.
    "pii.fin.credit-card":       ("CREDIT_CARD", "CreditCardRecognizer (Luhn)"),
    "pii.fin.credit-card.context": ("CREDIT_CARD", "CreditCardRecognizer (Luhn)"),
    "pii.fin.iban":          ("IBAN_CODE",    "IbanRecognizer (mod97)"),
    "pii.fio-ru":            ("PERSON",       "spaCy NER ru_core_news_md (PERSON); при слабом "
                                               "recall можно вернуть правило"),
    "pii.fio-ru.initials":   ("PERSON",       "spaCy NER ru_core_news_md (PERSON)"),
    "pii.fio-ru.short":      ("PERSON",       "spaCy NER ru_core_news_md (PERSON)"),
}

# ---------------------------------------------------------------------------
# Внутрисетевые дубликаты (правило покрывается другим правилом того же набора).
#   rule_id -> (rule_id покрывающего правила, причина)
# ---------------------------------------------------------------------------
SKIP_INTRA = {
    "api_keys.stripe-key":        ("access_tokens.stripe-access-token.gl",
                                   "покрывается шире: (sk|rk)_(test|live|prod)_[A-Za-z0-9]{10,99}"),
    "api_keys.stripe-restricted": ("access_tokens.stripe-access-token.gl",
                                   "покрывается шире: (sk|rk)_(test|live|prod)_..."),
    "access_tokens.npm-token":    ("access_tokens.npm-access-token.gl",
                                   "тот же шаблон npm_[a-z0-9]{36}, .gl-вариант шире (регистронезависимость)"),
    "access_tokens.private-key.gl": ("access_tokens.private-key-pem",
                                     "PEM-блок полностью покрывается private-key-pem; "
                                     "хвост .gl-варианта обрезан генератором"),
}

# ---------------------------------------------------------------------------
# Ручные адаптации: правила, которые нельзя использовать как есть, потому что
# их точность держалась на validators / keywords-гейте / min_length, которых
# нет у PatternRecognizer. Ключевое слово/длина вшиты в regex.
#   rule_id -> {"regex": ..., "score": ..., "note": ...}
# ---------------------------------------------------------------------------
OVERRIDES = {
    "access_tokens.twilio-auth-token": {
        "regex": r"(?i)twilio[^\r\n]{0,60}?([a-f0-9]{32})\b",
        "score": DEFAULT_SCORE,
        "note": "вшито ключевое слово twilio (был keywords-гейт + entropy 3.5)",
    },
    "access_tokens.generic-long-token": {
        "regex": r"(?-i)\b(?=[a-z0-9]*[A-Z])[A-Za-z0-9]{32,}\b",
        "score": LOW_SCORE,
        "note": "вшит min_length=32 (был отдельным полем); score понижен до 0.6",
    },
    "pii.docs.snils": {
        "regex": r"(?i)(?:снилс|snils)[^\d\r\n]{0,20}(\d{3}[\s-]?\d{3}[\s-]?\d{3}[\s-]?\d{2})",
        "score": DEFAULT_SCORE,
        "note": "вшито ключевое слово «снилс/snils»; checksum-валидатор snils "
                "недоступен в PatternRecognizer — вместо него гейт по ключевому слову",
    },
    "pii.docs.inn-person": {
        "regex": r"(?i)(?:инн|inn)[^\d\r\n]{0,20}(\d{12})",
        "score": DEFAULT_SCORE,
        "note": "вшито ключевое слово «инн/inn»; checksum inn_person заменён "
                "гейтом по ключевому слову",
    },
    "pii.docs.inn-org": {
        "regex": r"(?i)(?:инн|inn)[^\d\r\n]{0,20}(\d{10})",
        "score": DEFAULT_SCORE,
        "note": "вшито ключевое слово «инн/inn»; checksum inn_org заменён "
                "гейтом по ключевому слову",
    },
    "pii.docs.ogrn": {
        "regex": r"(?i)(?:огрн|ogrn)[^\d\r\n]{0,20}(\d{13})",
        "score": DEFAULT_SCORE,
        "note": "вшито ключевое слово «огрн/ogrn»; checksum ogrn заменён "
                "гейтом по ключевому слову",
    },
    "pii.docs.ogrnip": {
        "regex": r"(?i)(?:огрнип|ogrnip)[^\d\r\n]{0,20}(3\d{14})",
        "score": DEFAULT_SCORE,
        "note": "вшито ключевое слово «огрнип/ogrnip»; checksum ogrnip заменён "
                "гейтом по ключевому слову",
    },
}

# Правила с повышенным риском ложных срабатываний (entropy-гейт отброшен).
LOW_SCORE_RULES = {"access_tokens.generic-token"}

# ---------------------------------------------------------------------------
# Особые случаи для gitleaks-правил, где точность держалась на text-level
# keywords-гейте Go-фильтра (ключевое слово где угодно в тексте, не рядом с
# match) — в Presidio такого гейта нет.
#   rule_id -> {"regex": ..., "note": ...}
# ---------------------------------------------------------------------------
GITLEAKS_OVERRIDES = {
    # В оригинале есть «голая» ветка [a-fA-F0-9]{40} без префикса sgp_ —
    # она ловит любой 40-символьный hex (например, git SHA). Оставляем только
    # ветки с префиксом sgp_.
    "access_tokens.sourcegraph-access-token.gl": {
        "regex": r"(?i)\b(sgp_(?:[a-fA-F0-9]{16}|local)_[a-fA-F0-9]{40}|sgp_[a-fA-F0-9]{40})\b",
        "note": "удалена «голая» ветка [a-fA-F0-9]{40} (ловила git SHA и любой "
                "40-символьный hex); оставлены только ветки с префиксом sgp_",
    },
}

# Правила, чей keywords-гейт не воспроизводим в Presidio, но regex достаточно
# специфичен — добавляются как есть (с пометкой в отчёте).
KEYWORD_GATE_NOTES = {
    "access_tokens.facebook-access-token.gl":
        "keywords-гейт (facebook где угодно в тексте) не воспроизводим; regex "
        "достаточно специфичен (15-16 цифр + |/% + 27-40 символов)",
    "access_tokens.airtable-personnal-access-token.gl":
        "keywords-гейт (airtable) не воспроизводим; regex специфичен "
        "(pat + 14 alnum + точка + 64 hex)",
    "access_tokens.vault-service-token.gl":
        "ветка s\\.[a-z0-9]{24} без бренд-префикса; основная ветка hvs. специфична",
    "credentials.intra42-client-secret.gl":
        "keywords-гейт (intra) не воспроизводим; префикс s-s4t2ud-/s-s4t2af- специфичен",
}

# ---------------------------------------------------------------------------
# Синтетические сэмплы для --self-test: rule_id -> [(текст, обязательная
# подстрока ожидаемого match), ...]
# ---------------------------------------------------------------------------
SAMPLES = {
    "pii.phone-ru": [
        ("Мой номер 89030054516, набери после 18:00", "89030054516"),
        ("Телефон: +7 903 005-45-16", "+7 903 005-45-16"),
        ("+79030054516 — рабочий", "+79030054516"),
        ("8 (903) 005 45 16 домашний", "8 (903) 005 45 16"),
    ],
    "credentials.url_with_creds": [
        ("Скачай https://user:pass123@example.com/file.zip", "user:pass123"),
        ("ftp://backup:Net123pass@files.corp.ru/dir", "backup:Net123pass"),
    ],
    "credentials.db_connection": [
        ("DSN: postgresql://svc_app:hunter2@db01.internal:5432/appdb", "svc_app:hunter2"),
    ],
    "credentials.redis_connection": [
        ("redis://default:MyRedisPass2024@cache-01:6379/0", "default:MyRedisPass2024"),
    ],
    "credentials.amqp_connection": [
        ("amqps://guest:guestpass@mq.internal:5671/vhost", "guest:guestpass"),
    ],
    "credentials.nats_connection": [
        ("nats://user:natspass@nats-1:4222", "user:natspass"),
    ],
    "credentials.http_auth_basic": [
        ("Authorization: Basic dXNlcjpwYXNzd29yZA==", "dXNlcjpwYXNzd29yZA=="),
    ],
    "credentials.http_auth_bearer": [
        ("Authorization: Bearer ya29.a0AfH6SMBwc1234567890", "ya29.a0AfH6SMBwc1234567890"),
    ],
    "credentials.url_encoded_bearer_token": [
        ("https://api.example.com/v1?auth=Bearer%20AbCdEf123456789012", "AbCdEf123456789012"),
    ],
    "credentials.api_key_header": [
        ("X-API-Key: a1b2c3d4e5f6g7h8i9j0", "a1b2c3d4e5f6g7h8i9j0"),
    ],
    "credentials.nested_json_api_key": [
        ('{"api_key": "sk-proj-AbCdEf123456789012"}', "sk-proj-AbCdEf123456789012"),
    ],
    "credentials.password": [
        ("В конфиге password: Str0ngP@ssw0rd!", "Str0ngP@ssw0rd"),
        ("DB_PASSWORD='Qwerty12345'", "Qwerty12345"),
    ],
    "credentials.oauth_query_secret": [
        ("https://id.example.com/cb?access_token=ya29.1234567890abcdef&state=1",
         "ya29.1234567890abcdef"),
    ],
    "credentials.oauth_body_secret": [
        ('{"client_secret": "supersecretvalue123"}', "supersecretvalue123"),
    ],
    "access_tokens.twilio-auth-token": [
        ("twilio auth token: 0123456789abcdef0123456789abcdef", "0123456789abcdef0123456789abcdef"),
    ],
    "access_tokens.generic-token": [
        ("токен: AbCdEf1234567890", "AbCdEf1234567890"),
        ("sk_1234567890abcdef", "sk_1234567890abcdef"),
        ("смс с кодом 123456", "123456"),
    ],
    "access_tokens.generic-long-token": [
        ("Вот ключ: aBcDeFgHiJkLmNoPqRsTuVwXyZ012345", "aBcDeFgHiJkLmNoPqRsTuVwXyZ012345"),
    ],
    "access_tokens.vault-token": [
        ("hvs.CAESIJ" + "x" * 90, "hvs.CAESIJ"),
    ],
    "access_tokens.private-key-pem": [
        ("-----BEGIN RSA PRIVATE KEY-----\nMIIEow...\n-----END RSA PRIVATE KEY-----",
         "-----BEGIN RSA PRIVATE KEY-----"),
    ],
    "pii.docs.snils": [
        ("СНИЛС 112-233-445 95", "112-233-445 95"),
        ("снилс: 11223344595", "11223344595"),
    ],
    "pii.docs.passport": [
        ("паспорт 45 10 №765432", "45 10 №765432"),
    ],
    "pii.docs.kpp": [
        ("КПП 770101001", "770101001"),
    ],
    "pii.docs.address": [
        ("Проживает: ул. Тверская, д. 15, кв. 7", "ул. Тверская, д. 15, кв. 7"),
    ],
    "pii.docs.inn-person": [
        ("ИНН 770123456789", "770123456789"),
    ],
    "pii.docs.inn-org": [
        ("ИНН 7707083893", "7707083893"),
    ],
    "pii.docs.ogrn": [
        ("ОГРН 1077701234567", "1077701234567"),
    ],
    "pii.docs.ogrnip": [
        ("ОГРНИП 307770123456789", "307770123456789"),
    ],
    "pii.fin.cvc": [
        ("CVC: 123", "123"),
        ("код безопасности 456", "456"),
    ],
    # gitleaks-правила (проверка, что keywords уже вшиты в regex)
    "credentials.github-oauth.gl": [
        ("токен gho_AbCdEfGhIjKlMnOpQrStUvWxYz1234567890", "gho_AbCdEfGhIjKlMnOpQrStUvWxYz1234567890"),
    ],
    "credentials.jwt.gl": [
        ("jwt: eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4",
         "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.SflKxwRJSMeKKF2QT4"),
    ],
    "api_keys.twilio-api-key.gl": [
        ("twilio SK0123456789abcdef0123456789abcdef", "SK0123456789abcdef0123456789abcdef"),
    ],
    "access_tokens.stripe-access-token.gl": [
        ("ключ sk_live_51Nq2Lk9s9mPqR2sA1bCdEfGhIjKlMnOp", "sk_live_51Nq2Lk9s9mPqR2sA1bCdEfGhIjKlMnOp"),
    ],
    "access_tokens.npm-access-token.gl": [
        ("npm_AbCdEfGhIjKlMnOpQrStUvWxYz1234567890", "npm_AbCdEfGhIjKlMnOpQrStUvWxYz1234567890"),
    ],
    "access_tokens.age-secret-key.gl": [
        ("AGE-SECRET-KEY-1" + "Q" * 58, "AGE-SECRET-KEY-1"),
    ],
    "access_tokens.sourcegraph-access-token.gl": [
        # формат: sgp_<16 hex>_<40 hex>
        ("sgp_0123456789abcdef_0123456789abcdef0123456789abcdef01234567",
         "sgp_0123456789abcdef_0123456789abcdef0123456789abcdef01234567"),
    ],
    "extra.ssh-public-key": [
        ("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBCS2c7qDTI+7XmIkBXE/ZA58nkCGk6Ae79TYdcg0M/j alavret@alavret-osx",
         "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBCS2c7qDTI+7XmIkBXE/ZA58nkCGk6Ae79TYdcg0M/j"),
        ("ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQD" + "X" * 330 + "x1 user@host",
         "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQD" + "X" * 330 + "x1"),
    ],
    "extra.openrouter-api-key": [
        ("ключ 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 проверь",
         "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"),
    ],
    "extra.sk-rt-key": [
        ("токен sk-rt_9d7e59d2fd1aeb80c7ebdba542a5805f83fe4724e2e55db4c29c58d2565da97082d7f5 в конфиге",
         "sk-rt_9d7e59d2fd1aeb80c7ebdba542a5805f83fe4724e2e55db4c29c58d2565da97082d7f5"),
    ],
    "extra.llm-provider-token": [
        ("провайдер v1.ClISN8a3CjO5zjjjWxTY2TBr0uX4W83ugfYuWMznD-Uj2EiXEJxTxin53czgRgPXtTFdWd3InoP37HJA04VTRLbyuKb37cVhauEvBQoirPgYDiKIktaEXYdr3nCWvsPD",
         "v1.ClISN8a3CjO5zjjjWxTY2TBr0uX4W83ugfYuWMznD-Uj2EiXEJxTxin53czgRgPXtTFdWd3InoP37HJA04VTRLbyuKb37cVhauEvBQoirPgYDiKIktaEXYdr3nCWvsPD"),
        # токен в конце предложения (точка после токена НЕ должна ломать матч)
        ("вот токен v1.ClISN8a3CjO5zjjjWxTY2TBr0uX4W83ugfYuWMznD-Uj2EiXEJxTxin53czgRgPXtTFdWd3InoP37HJA04VTRLbyuKb37cVhauEvBQoirPgYDiKIktaEXYdr3nCWvsPD. Конец.",
         "v1.ClISN8a3CjO5zjjjWxTY2TBr0uX4W83ugfYuWMznD-Uj2EiXEJxTxin53czgRgPXtTFdWd3InoP37HJA04VTRLbyuKb37cVhauEvBQoirPgYDiKIktaEXYdr3nCWvsPD"),
        # токен с запятой после
        ("ключи v1.ClISN8a3CjO5zjjjWxTY2TBr0uX4W83ugfYuWMznD-Uj2EiXEJxTxin53czgRgPXtTFdWd3InoP37HJA04VTRLbyuKb37cVhauEvBQoirPgYDiKIktaEXYdr3nCWvsPD, ещё один",
         "v1.ClISN8a3CjO5zjjjWxTY2TBr0uX4W83ugfYuWMznD-Uj2EiXEJxTxin53czgRgPXtTFdWd3InoP37HJA04VTRLbyuKb37cVhauEvBQoirPgYDiKIktaEXYdr3nCWvsPD"),
    ],
}

# "Чистый" корпус для проверки ложных срабатываний (FP).
BENIGN = [
    "Обычное рабочее сообщение без каких-либо секретов и персональных данных.",
    "Созвон в 15:30, комната 4B. Повестка: релиз 2.4.1, баги, планирование.",
    "commit 3f2a9c1d8e5b7f0a3c6d9e2b5f8a1c4d7e0b3f6a помечен тегом v1.2.3",
    "UUID задачи: 550e8400-e29b-41d4-a716-446655440000, приоритет низкий.",
    "Дата: 2024-01-15, сумма: 12 345,67 руб., срок: 3 дня.",
    "def calculate(x, y):\n    return x + y * 2  # обычный код без секретов",
    "Пользователь user42 создал репозиторий my-project и открыл 3 issue.",
    "Идентификатор заказа 1234567890123, статус: доставлен.",
    "Координаты офиса: 55.7558, 37.6173. Вход со двора.",
    "Версия Python 3.12.4, ОС Ubuntu 24.04, ядро 6.8.0-45-generic.",
    "СНИЛС упоминается в заявлении, но номер не приводится.",
    "https://example.com/docs/page?section=intro&lang=ru — обычная ссылка.",
    "ssh-конфиг: Port 22, PasswordAuthentication no, PermitRootLogin no.",
    "Версия API v1.2.3 объявлена стабильной, миграция с v1.1 планируется.",
]


# ---------------------------------------------------------------------------
# Загрузка правил
# ---------------------------------------------------------------------------
def load_rules(repo_dir: Path) -> list[dict]:
    rules = []
    for rel in SOURCE_FILES:
        path = repo_dir / rel
        if not path.exists():
            sys.exit(f"ERROR: не найден {path}")
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
        for group in data["guardrails_regex_rules"]:
            for r in group["rules"]:
                masking = r.get("masking") or {}
                rules.append({
                    "rule_id": r["rule_id"],
                    "group": group["name"],
                    "source": rel,
                    "regex": r["regex"],
                    "keywords": r.get("keywords"),
                    "entropy": r.get("entropy"),
                    "min_length": r.get("min_length"),
                    "validators": r.get("validators"),
                    "banlist": r.get("banlist"),
                    "placeholder": masking.get("placeholder"),
                    "capture_groups": masking.get("capture_groups"),
                })
    rules.extend(EXTRA_RULES)
    return rules


# ---------------------------------------------------------------------------
# Трансформации regex
# ---------------------------------------------------------------------------
def _open_paren_of_close(s: str, close_idx: int) -> int | None:
    """Индекс открывающей '(' для закрывающей ')' на close_idx."""
    depth = 0
    for i in range(close_idx, -1, -1):
        if s[i] == ")":
            depth += 1
        elif s[i] == "(":
            depth -= 1
            if depth == 0:
                return i
    return None


def _close_paren_of_open(s: str, open_idx: int) -> int | None:
    """Индекс закрывающей ')' для открывающей '(' на open_idx."""
    depth = 0
    for i in range(open_idx, len(s)):
        if s[i] == "(":
            depth += 1
        elif s[i] == ")":
            depth -= 1
            if depth == 0:
                return i
    return None


def _prev_char_escaped(s: str, idx: int) -> bool:
    """Экранирована ли позиция idx (нечётное число бэкслэшей перед ней)."""
    n = 0
    j = idx - 1
    while j >= 0 and s[j] == "\\":
        n += 1
        j -= 1
    return n % 2 == 1


def transform_regex(rx: str) -> tuple[str, list[str]]:
    """Адаптация regex под PatternRecognizer (match = маскируемый фрагмент).

    1. Замыкающая группа-граница (?:X|$) -> (?=X|$):
       в Go-фильтре группа выделяла capture group, а граница «съедалась»;
       Presidio маскирует ВЕСЬ match, поэтому границу превращаем в lookahead,
       иначе в маску попадает один символ-разделитель после секрета.
    2. Ведущая группа-граница (?:^|X) -> (?<=^|X): аналогично, иначе в маску
       попадает один символ перед секретом.
    """
    notes = []
    s = rx

    # 1. Замыкающая (?:...) в самом конце
    if s.endswith(")"):
        close = len(s) - 1
        if not _prev_char_escaped(s, close):
            op = _open_paren_of_close(s, close)
            if op is not None and op > 0 and s[op:op + 3] == "(?:":
                s = s[:op] + "(?=" + s[op + 3:]
                notes.append("замыкающая (?:...) -> (?=...) lookahead")

    # 2. Ведущая (?:^|...) в начале
    if s.startswith("(?:"):
        close = _close_paren_of_open(s, 0)
        if close is not None and close < len(s) - 1:
            content = s[3:close]
            if content.startswith("^|"):
                s = "(?<=" + content + ")" + s[close + 1:]
                notes.append("ведущая (?:^|...) -> (?<=...) lookbehind")

    return s, notes


# ---------------------------------------------------------------------------
# Конвертация
# ---------------------------------------------------------------------------
def convert(rules: list[dict], language: str) -> tuple[list[dict], list[dict]]:
    """Возвращает (added, skipped): added - распознаватели в формате from_dict,
    skipped - записи для отчёта {rule_id, decision, reason, ...}."""
    added, skipped = [], []
    seen_regex = {}  # нормализованный regex -> rule_id (защита от дублей)

    for r in rules:
        rid = r["rule_id"]

        if rid in SKIP_PRESIDIO:
            entity, reason = SKIP_PRESIDIO[rid]
            skipped.append({"rule_id": rid, "decision": "SKIP",
                            "reason": f"дубликат встроенного {entity}: {reason}"})
            continue

        if rid in SKIP_INTRA:
            other, reason = SKIP_INTRA[rid]
            skipped.append({"rule_id": rid, "decision": "SKIP",
                            "reason": f"дубликат правила {other}: {reason}"})
            continue

        notes = []
        if rid in OVERRIDES:
            ov = OVERRIDES[rid]
            rx = ov["regex"]
            score = ov["score"]
            notes.append("regex заменён (override): " + ov["note"])
            dropped = []
            if r["validators"]:
                dropped.append(f"validators={r['validators']}")
            if r["entropy"]:
                dropped.append(f"entropy={r['entropy']}")
            if r["min_length"]:
                dropped.append(f"min_length={r['min_length']}")
            if dropped:
                notes.append("отброшено (недоступно в PatternRecognizer): " +
                             ", ".join(dropped))
        elif rid in GITLEAKS_OVERRIDES:
            gov = GITLEAKS_OVERRIDES[rid]
            rx = gov["regex"]
            score = DEFAULT_SCORE
            notes.append("regex заменён (override): " + gov["note"])
            if r["entropy"]:
                notes.append(f"entropy={r['entropy']} отброшен "
                             "(нет аналога в PatternRecognizer; риск FP повышен)")
        else:
            rx, tnotes = transform_regex(r["regex"])
            notes.extend(tnotes)
            score = LOW_SCORE if rid in LOW_SCORE_RULES else DEFAULT_SCORE
            if r["entropy"]:
                notes.append(f"entropy={r['entropy']} отброшен "
                             "(нет аналога в PatternRecognizer; риск FP повышен)")
            if r["banlist"]:
                notes.append(f"banlist={r['banlist']} отброшен "
                             "(deny_list в Presidio имеет другой смысл — слова для "
                             "детекции, а не исключения)")
            if r["validators"]:
                notes.append(f"validators={r['validators']} отброшены "
                             "(нет аналога в PatternRecognizer)")
            if rid in KEYWORD_GATE_NOTES:
                notes.append(KEYWORD_GATE_NOTES[rid])

        # Проверка компиляции модулем regex с глобальными флагами Presidio
        try:
            re.compile(rx, GLOBAL_FLAGS)
        except re.error as e:
            # fallback: попробовать оригинальный regex
            try:
                re.compile(r["regex"], GLOBAL_FLAGS)
            except re.error:
                skipped.append({"rule_id": rid, "decision": "SKIP",
                                "reason": f"regex не компилируется модулем regex: {e}"})
                continue
            rx = r["regex"]
            notes.append("трансформация отменена (не компилируется), "
                         "использован оригинальный regex")

        # Защита от точных дублей regex внутри набора
        norm = rx.replace("(?i)", "")
        if norm in seen_regex:
            skipped.append({"rule_id": rid, "decision": "SKIP",
                            "reason": f"regex идентичен правилу {seen_regex[norm]}"})
            continue
        seen_regex[norm] = rid

        rec = {
            "name": rid,
            "supported_language": language,
            "supported_entity": r["placeholder"],
            "patterns": [{"name": rid, "regex": rx, "score": score}],
        }
        if r["keywords"]:
            rec["context"] = list(r["keywords"])
        added.append({"recognizer": rec, "source": r, "notes": notes,
                      "regex_final": rx, "score": score})

    return added, skipped


# ---------------------------------------------------------------------------
# Запись артефактов
# ---------------------------------------------------------------------------
def write_outputs(out_dir: Path, added: list[dict], skipped: list[dict],
                  language: str, repo_dir: Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)

    # 1. Ad-hoc JSON (формат LiteLLM presidio_ad_hoc_recognizers)
    json_path = out_dir / "custom_recognizers.json"
    json_path.write_text(
        json.dumps([a["recognizer"] for a in added], ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8")

    # 2. Записи для recognizer_registry.recognizers (Docker: analyzer-config.yml)
    registry_entries = []
    for a in added:
        rec = dict(a["recognizer"])
        rec.pop("supported_language")
        rec["supported_languages"] = [language]
        registry_entries.append(rec)
    registry_path = out_dir / "custom_recognizers.registry.yaml"
    registry_path.write_text(
        "# Кастомные распознаватели из guardrails-llm-filter (гайд 09).\n"
        "# Добавьте эти записи в секцию recognizer_registry.recognizers\n"
        "# файла analyzer-config.yml (Docker-вариант) ПОСЛЕ существующих\n"
        "# предустановленных распознавателей.\n"
        "# Сгенерировано convert_guardrails_rules.py, язык: " + language + "\n"
        "# Источник: " + str(repo_dir) + "\n"
        "recognizers:\n" +
        yaml.safe_dump(registry_entries, allow_unicode=True, sort_keys=False,
                       default_flow_style=False, width=10 ** 6),
        encoding="utf-8")

    # 3. Сниппет pii_entities_config
    entities = sorted({a["recognizer"]["supported_entity"] for a in added})
    snippet_path = out_dir / "pii_entities_config.snippet.yaml"
    snippet_path.write_text(
        "# Новые сущности для guardrail presidio-pii (гайд 09).\n"
        "# Добавьте в pii_entities_config рядом с существующими сущностями.\n"
        "pii_entities_config:\n" +
        "".join(f"  {e}: MASK\n" for e in entities),
        encoding="utf-8")

    # 4. Отчёт
    report = build_report(added, skipped, language, repo_dir)
    (out_dir / "conversion_report.md").write_text(report, encoding="utf-8")

    print(f"OK: {len(added)} правил добавлено, {len(skipped)} пропущено")
    print(f"  {json_path}")
    print(f"  {registry_path}")
    print(f"  {snippet_path}")
    print(f"  {out_dir / 'conversion_report.md'}")


def build_report(added: list[dict], skipped: list[dict], language: str,
                 repo_dir: Path) -> str:
    lines = [
        "# Отчёт конвертации правил guardrails-llm-filter -> Presidio",
        "",
        f"- Источник: `{repo_dir}` ({', '.join(SOURCE_FILES)})",
        f"- Язык распознавателей: `{language}`",
        f"- Добавлено правил: **{len(added)}**",
        f"- Пропущено правил: **{len(skipped)}**",
        "",
        "## Пропущено: дубликаты встроенных распознавателей Presidio",
        "",
        "| rule_id | покрывается | причина |",
        "|---|---|---|",
    ]
    for s in skipped:
        if "встроенного" in s["reason"]:
            entity = s["reason"].split("встроенного ")[1].split(":")[0]
            reason = s["reason"].split(": ", 1)[1] if ": " in s["reason"] else ""
            lines.append(f"| `{s['rule_id']}` | {entity} | {reason} |")

    lines += [
        "",
        "## Пропущено: дубликаты внутри набора guardrails-llm-filter",
        "",
        "| rule_id | причина |",
        "|---|---|",
    ]
    for s in skipped:
        if "встроенного" not in s["reason"]:
            lines.append(f"| `{s['rule_id']}` | {s['reason']} |")

    lines += [
        "",
        "## Добавленные правила и адаптации",
        "",
        "| rule_id | сущность | score | адаптации |",
        "|---|---|---|---|",
    ]
    for a in added:
        notes = "; ".join(a["notes"]) if a["notes"] else "—"
        lines.append(f"| `{a['recognizer']['name']}` | "
                     f"{a['recognizer']['supported_entity']} | {a['score']} | {notes} |")

    lines += [
        "",
        "## Важные отличия от оригинального Go-фильтра",
        "",
        "- Presidio маскирует **весь match**; границы `(?:X|$)`/`(?:^|X)` "
        "переведены в lookahead/lookbehind, чтобы не съедать символы вокруг секрета.",
        "- `entropy`, `banlist`, `validators`, `min_length` (отдельное поле) "
        "не имеют аналогов в PatternRecognizer и отброшены; для правил, чья "
        "точность на них держалась, ключевые слова/длины вшиты в regex (см. "
        "таблицу выше).",
        "- `capture_groups` не поддерживаются: маскируется весь match "
        "(для правил с ключевым словом в regex маска накрывает и его — "
        "например, `ИНН 7707083893` -> `<INN_ORG>`).",
        "",
    ]
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# Самопроверка
# ---------------------------------------------------------------------------
def run_match(recognizer: dict, text: str) -> list[str]:
    """Имитация PatternRecognizer.__analyze_patterns: finditer с GLOBAL_FLAGS."""
    out = []
    for pat in recognizer["patterns"]:
        compiled = re.compile(pat["regex"], GLOBAL_FLAGS)
        for m in compiled.finditer(text):
            if m.span() != (0, 0) and m.group(0):
                out.append(m.group(0))
    return out


def self_test(added: list[dict]) -> bool:
    by_id = {a["recognizer"]["name"]: a for a in added}
    ok = True
    print("\n=== SELF-TEST: синтетические сэмплы ===")
    for rid, cases in SAMPLES.items():
        if rid not in by_id:
            print(f"  ?? {rid}: правило не в наборе (пропущено?) — проверьте отчёт")
            continue
        for text, expect in cases:
            matches = run_match(by_id[rid]["recognizer"], text)
            hit = any(expect in m for m in matches)
            mark = "OK " if hit else "FAIL"
            if not hit:
                ok = False
            print(f"  {mark} {rid}: {text[:60]!r} -> {matches[:2]}")
    print("\n=== SELF-TEST: чистый корпус (ожидаются пустые результаты) ===")
    for text in BENIGN:
        hits = []
        for a in added:
            matches = run_match(a["recognizer"], text)
            if matches:
                hits.append((a["recognizer"]["name"], matches[:2]))
        if hits:
            ok = False
            print(f"  FP  {text[:60]!r} -> {hits}")
        else:
            print(f"  OK  {text[:60]!r}")
    return ok


def dataset_test(added: list[dict], dataset_path: Path) -> bool:
    """Прогон датасета guardrails-llm-filter (tests/dataset/guardrails_dataset.jsonl).

    id правил вида gitleaks.<gitleaks-id> отображаются на <группа>.<gitleaks-id>.gl.
    Кейсы, чьи правила пропущены как дубликаты Presidio, отмечаются отдельно
    (проверить их можно только живым Presidio — см. гайд 09, раздел проверки)."""
    by_id = {a["recognizer"]["name"]: a for a in added}
    skip_ids = set(SKIP_PRESIDIO) | set(SKIP_INTRA)

    def resolve(rid: str) -> str | None:
        if rid in by_id:
            return rid
        if rid.startswith("gitleaks."):
            suffix = rid[len("gitleaks."):]
            for cand in by_id:
                if cand.endswith("." + suffix + ".gl"):
                    return cand
        return None

    ok, total, passed, skipped_cases = True, 0, 0, 0
    print("\n=== DATASET-TEST:", dataset_path.name, "===")
    fails = []
    marker_cases = 0  # кейсы-маркеры recheck.* (не привязаны к конкретному правилу)
    for line in dataset_path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        case = json.loads(line)
        total += 1
        rids = case["rule_ids"]
        if all(x.startswith("recheck.") for x in rids):
            marker_cases += 1
            continue
        targets = [resolve(x) for x in rids]
        if all(t is None for t in targets):
            if all(x in skip_ids for x in rids):
                skipped_cases += 1
                continue
            continue  # правило не найдено вообще (не из нашего набора)
        hit = False
        for t in targets:
            if t and run_match(by_id[t]["recognizer"], case["content"]):
                hit = True
                break
        if hit:
            passed += 1
        else:
            ok = False
            fails.append((case["id"], rids, case["content"][:70]))
    print(f"  проверено кейсов: {total}, прошло: {passed}, "
          f"пропущено (дубликаты Presidio): {skipped_cases}, "
          f"маркерные (recheck.*): {marker_cases}, провалено: {len(fails)}")
    for cid, rids, content in fails[:15]:
        print(f"  FAIL {cid} {rids}: {content!r}")
    if len(fails) > 15:
        print(f"  ... и ещё {len(fails) - 15}")
    return ok


# ---------------------------------------------------------------------------
def main() -> None:
    p = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    p.add_argument("--repo", required=True,
                   help="путь к клону guardrails-llm-filter")
    p.add_argument("--language", default="ru", choices=["ru", "en"],
                   help="supported_language распознавателей (default: ru; должен "
                        "совпадать с presidio_language в конфиге LiteLLM)")
    p.add_argument("--out-dir", default=None,
                   help="куда писать артефакты (default: ./presidio_custom_rules)")
    p.add_argument("--self-test", action="store_true",
                   help="прогнать синтетические сэмплы и чистый корпус")
    p.add_argument("--dataset", action="store_true",
                   help="прогнать датасет tests/dataset/guardrails_dataset.jsonl")
    args = p.parse_args()

    repo_dir = Path(args.repo).expanduser().resolve()
    out_dir = Path(args.out_dir).expanduser() if args.out_dir else \
        Path("presidio_custom_rules")

    rules = load_rules(repo_dir)
    print(f"Загружено правил: {len(rules)} "
          f"({', '.join(SOURCE_FILES)})")

    added, skipped = convert(rules, args.language)
    write_outputs(out_dir, added, skipped, args.language, repo_dir)

    ok = True
    if args.self_test:
        ok = self_test(added) and ok
    if args.dataset:
        ds = repo_dir / "tests/dataset/guardrails_dataset.jsonl"
        ok = dataset_test(added, ds) and ok

    if not ok:
        sys.exit(1)


if __name__ == "__main__":
    main()
