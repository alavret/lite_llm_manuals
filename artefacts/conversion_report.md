# Отчёт конвертации правил guardrails-llm-filter -> Presidio

- Источник: https://github.com/cloud-ru-tech/guardrails-llm-filter (configs/guardrails_regex_rules.yaml, configs/guardrails_regex_rules.gitleaks.generated.yaml)
- Язык распознавателей: `ru`
- Добавлено правил: **250**
- Пропущено правил: **20**

## Пропущено: дубликаты встроенных распознавателей Presidio

| rule_id | покрывается | причина |
|---|---|---|
| `ip-addrs.ipv4` | IP_ADDRESS | IpRecognizer: IPv4 + валидация ipaddress |
| `ip-addrs.ipv4-cidr` | IP_ADDRESS | IpRecognizer: IPv4/CIDR + валидация |
| `ip-addrs.ipv4-public` | IP_ADDRESS | IpRecognizer: IPv4 + валидация |
| `ip-addrs.ipv4-private` | IP_ADDRESS | IpRecognizer: IPv4 + валидация |
| `ip-addrs.ipv6` | IP_ADDRESS | IpRecognizer: IPv6 + валидация |
| `ip-addrs.ipv6-cidr` | IP_ADDRESS | IpRecognizer: IPv6/CIDR + валидация |
| `ip-addrs.ipv6-public` | IP_ADDRESS | IpRecognizer: IPv6 + валидация |
| `ip-addrs.ipv6-private` | IP_ADDRESS | IpRecognizer: IPv6 + валидация |
| `pii.fio-ru` | PERSON | spaCy NER ru_core_news_md (PERSON); при слабом recall можно вернуть правило |
| `pii.fio-ru.initials` | PERSON | spaCy NER ru_core_news_md (PERSON) |
| `pii.fio-ru.short` | PERSON | spaCy NER ru_core_news_md (PERSON) |
| `pii.email` | EMAIL_ADDRESS | EmailRecognizer (полное покрытие) |
| `pii.fin.credit-card` | CREDIT_CARD | CreditCardRecognizer (Luhn) |
| `pii.fin.credit-card.context` | CREDIT_CARD | CreditCardRecognizer (Luhn) |
| `pii.fin.iban` | IBAN_CODE | IbanRecognizer (mod97) |

## Пропущено: дубликаты внутри набора guardrails-llm-filter

| rule_id | причина |
|---|---|
| `api_keys.stripe-key` | дубликат правила access_tokens.stripe-access-token.gl: покрывается шире: (sk|rk)_(test|live|prod)_[A-Za-z0-9]{10,99} |
| `api_keys.stripe-restricted` | дубликат правила access_tokens.stripe-access-token.gl: покрывается шире: (sk|rk)_(test|live|prod)_... |
| `access_tokens.npm-token` | дубликат правила access_tokens.npm-access-token.gl: тот же шаблон npm_[a-z0-9]{36}, .gl-вариант шире (регистронезависимость) |
| `access_tokens.bittrex-secret-key.gl` | regex идентичен правилу access_tokens.bittrex-access-key.gl |
| `access_tokens.private-key.gl` | дубликат правила access_tokens.private-key-pem: PEM-блок полностью покрывается private-key-pem; хвост .gl-варианта обрезан генератором |

## Добавленные правила и адаптации

| rule_id | сущность | score | адаптации |
|---|---|---|---|
| `credentials.url_with_creds` | URL_WITH_CREDS | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `credentials.db_connection` | DB_DSN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `credentials.redis_connection` | REDIS_DSN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `credentials.amqp_connection` | AMQP_DSN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `credentials.nats_connection` | NATS_DSN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `credentials.http_auth_basic` | HTTP_AUTH_BASIC | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `credentials.http_auth_bearer` | BEARER_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `credentials.url_encoded_bearer_token` | BEARER_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `credentials.api_key_header` | API_KEY_HEADER | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `credentials.nested_json_api_key` | API_KEY_HEADER | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `credentials.password` | PASSWORD | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=2.5 отброшен (нет аналога в PatternRecognizer; риск FP повышен); banlist=['password', 'qwerty', '123456', '12345678', '111111', 'letmein', 'admin', 'welcome', 'secret', 'changeme', 'pass'] отброшен (deny_list в Presidio имеет другой смысл — слова для детекции, а не исключения) |
| `credentials.oauth_query_secret` | OAUTH_QUERY_SECRET | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `credentials.oauth_body_secret` | OAUTH_BODY_SECRET | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `access_tokens.twilio-auth-token` | TWILIO_AUTH_TOKEN | 0.8 | regex заменён (override): вшито ключевое слово twilio (был keywords-гейт + entropy 3.5); отброшено (недоступно в PatternRecognizer): entropy=3.5 |
| `access_tokens.generic-token` | TOKEN | 0.6 | — |
| `access_tokens.generic-long-token` | TOKEN | 0.6 | regex заменён (override): вшит min_length=32 (был отдельным полем); score понижен до 0.6; отброшено (недоступно в PatternRecognizer): min_length=32 |
| `access_tokens.vault-token` | VAULT_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `access_tokens.private-key-pem` | PEM_KEY | 0.8 | — |
| `pii.phone-ru` | PHONE_RU | 0.8 | ведущая (?:^|...) -> (?<=...) lookbehind |
| `pii.docs.snils` | SNILS | 0.8 | regex заменён (override): вшито ключевое слово «снилс/snils»; checksum-валидатор snils недоступен в PatternRecognizer — вместо него гейт по ключевому слову; отброшено (недоступно в PatternRecognizer): validators=['snils'] |
| `pii.docs.passport` | PASSPORT_RF | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `pii.docs.kpp` | KPP | 0.8 | — |
| `pii.docs.address` | ADDRESS | 0.8 | — |
| `pii.docs.inn-person` | INN_PERSON | 0.8 | regex заменён (override): вшито ключевое слово «инн/inn»; checksum inn_person заменён гейтом по ключевому слову; отброшено (недоступно в PatternRecognizer): validators=['inn_person'], min_length=12 |
| `pii.docs.inn-org` | INN_ORG | 0.8 | regex заменён (override): вшито ключевое слово «инн/inn»; checksum inn_org заменён гейтом по ключевому слову; отброшено (недоступно в PatternRecognizer): validators=['inn_org'], min_length=10 |
| `pii.docs.ogrn` | OGRN | 0.8 | regex заменён (override): вшито ключевое слово «огрн/ogrn»; checksum ogrn заменён гейтом по ключевому слову; отброшено (недоступно в PatternRecognizer): validators=['ogrn'], min_length=13 |
| `pii.docs.ogrnip` | OGRNIP | 0.8 | regex заменён (override): вшито ключевое слово «огрнип/ogrnip»; checksum ogrnip заменён гейтом по ключевому слову; отброшено (недоступно в PatternRecognizer): validators=['ogrnip'], min_length=15 |
| `pii.fin.cvc` | CVC | 0.8 | — |
| `credentials.adobe-client-id.gl` | ADOBE_CLIENT_ID | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `credentials.adobe-client-secret.gl` | ADOBE_CLIENT_SECRET | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `credentials.asana-client-id.gl` | ASANA_CLIENT_ID | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `credentials.asana-client-secret.gl` | ASANA_CLIENT_SECRET | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `credentials.azure-ad-client-secret.gl` | AZURE_AD_CLIENT_SECRET | 0.8 | ведущая (?:^|...) -> (?<=...) lookbehind; entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `credentials.bitbucket-client-id.gl` | BITBUCKET_CLIENT_ID | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `credentials.bitbucket-client-secret.gl` | BITBUCKET_CLIENT_SECRET | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `credentials.curl-auth-header.gl` | CURL_AUTH_HEADER | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=2.75 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `credentials.curl-auth-user.gl` | CURL_AUTH_USER | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `credentials.digitalocean-refresh-token.gl` | DIGITALOCEAN_REFRESH_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `credentials.discord-client-id.gl` | DISCORD_CLIENT_ID | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `credentials.discord-client-secret.gl` | DISCORD_CLIENT_SECRET | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `credentials.facebook-secret.gl` | FACEBOOK_SECRET | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `credentials.finicity-client-secret.gl` | FINICITY_CLIENT_SECRET | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `credentials.github-oauth.gl` | GITHUB_OAUTH | 0.8 | entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `credentials.github-refresh-token.gl` | GITHUB_REFRESH_TOKEN | 0.8 | entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `credentials.gitlab-oauth-app-secret.gl` | GITLAB_OAUTH_APP_SECRET | 0.8 | entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `credentials.gitlab-session-cookie.gl` | GITLAB_SESSION_COOKIE | 0.8 | entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `credentials.hashicorp-tf-password.gl` | HASHICORP_TF_PASSWORD | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `credentials.intra42-client-secret.gl` | INTRA42_CLIENT_SECRET | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен); keywords-гейт (intra) не воспроизводим; префикс s-s4t2ud-/s-s4t2af- специфичен |
| `credentials.jwt-base64.gl` | JWT_BASE64 | 0.8 | entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `credentials.jwt.gl` | JWT | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `credentials.kubernetes-secret-yaml.gl` | KUBERNETES_SECRET_YAML | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `credentials.linear-client-secret.gl` | LINEAR_CLIENT_SECRET | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `credentials.linkedin-client-id.gl` | LINKEDIN_CLIENT_ID | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `credentials.linkedin-client-secret.gl` | LINKEDIN_CLIENT_SECRET | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `credentials.looker-client-id.gl` | LOOKER_CLIENT_ID | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `credentials.looker-client-secret.gl` | LOOKER_CLIENT_SECRET | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `credentials.messagebird-client-id.gl` | MESSAGEBIRD_CLIENT_ID | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `credentials.new-relic-user-api-id.gl` | NEW_RELIC_USER_API_ID | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `credentials.nuget-config-password.gl` | NUGET_CONFIG_PASSWORD | 0.8 | entropy=1.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `credentials.plaid-client-id.gl` | PLAID_CLIENT_ID | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=3.5 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `credentials.planetscale-oauth-token.gl` | PLANETSCALE_OAUTH_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `credentials.planetscale-password.gl` | PLANETSCALE_PASSWORD | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `credentials.sendbird-access-id.gl` | SENDBIRD_ACCESS_ID | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `credentials.shopify-shared-secret.gl` | SHOPIFY_SHARED_SECRET | 0.8 | entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `credentials.sidekiq-secret.gl` | SIDEKIQ_SECRET | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `credentials.sidekiq-sensitive-url.gl` | SIDEKIQ_SENSITIVE_URL | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `credentials.slack-config-refresh-token.gl` | SLACK_CONFIG_REFRESH_TOKEN | 0.8 | entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `credentials.sumologic-access-id.gl` | SUMOLOGIC_ACCESS_ID | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `credentials.twitter-access-secret.gl` | TWITTER_ACCESS_SECRET | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `credentials.twitter-api-secret.gl` | TWITTER_API_SECRET | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `api_keys.adafruit-api-key.gl` | ADAFRUIT_API_KEY | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `api_keys.airtable-api-key.gl` | AIRTABLE_API_KEY | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `api_keys.algolia-api-key.gl` | ALGOLIA_API_KEY | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `api_keys.anthropic-admin-api-key.gl` | ANTHROPIC_ADMIN_API_KEY | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `api_keys.anthropic-api-key.gl` | ANTHROPIC_API_KEY | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `api_keys.artifactory-api-key.gl` | ARTIFACTORY_API_KEY | 0.8 | entropy=4.5 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.atlassian-api-token.gl` | ATLASSIAN_API_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=3.5 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.aws-amazon-bedrock-api-key-long-lived.gl` | AWS_AMAZON_BEDROCK_API_KEY_LONG_LIVED | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.aws-amazon-bedrock-api-key-short-lived.gl` | AWS_AMAZON_BEDROCK_API_KEY_SHORT_LIVED | 0.8 | entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.beamer-api-token.gl` | BEAMER_API_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `api_keys.cisco-meraki-api-key.gl` | CISCO_MERAKI_API_KEY | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.clickhouse-cloud-api-secret-key.gl` | CLICKHOUSE_CLOUD_API_SECRET_KEY | 0.8 | entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.clojars-api-token.gl` | CLOJARS_API_TOKEN | 0.8 | entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.cloudflare-api-key.gl` | CLOUDFLARE_API_KEY | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.cloudflare-global-api-key.gl` | CLOUDFLARE_GLOBAL_API_KEY | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.cohere-api-token.gl` | COHERE_API_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=4.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.contentful-delivery-api-token.gl` | CONTENTFUL_DELIVERY_API_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `api_keys.databricks-api-token.gl` | DATABRICKS_API_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.defined-networking-api-token.gl` | DEFINED_NETWORKING_API_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `api_keys.discord-api-token.gl` | DISCORD_API_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `api_keys.doppler-api-token.gl` | DOPPLER_API_TOKEN | 0.8 | entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.dropbox-api-token.gl` | DROPBOX_API_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `api_keys.dropbox-long-lived-api-token.gl` | DROPBOX_LONG_LIVED_API_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `api_keys.dropbox-short-lived-api-token.gl` | DROPBOX_SHORT_LIVED_API_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `api_keys.duffel-api-token.gl` | DUFFEL_API_TOKEN | 0.8 | entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.dynatrace-api-token.gl` | DYNATRACE_API_TOKEN | 0.8 | entropy=4.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.easypost-api-token.gl` | EASYPOST_API_TOKEN | 0.8 | entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.easypost-test-api-token.gl` | EASYPOST_TEST_API_TOKEN | 0.8 | entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.fastly-api-token.gl` | FASTLY_API_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `api_keys.finicity-api-token.gl` | FINICITY_API_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `api_keys.flyio-access-token.gl` | FLYIO_ACCESS_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=4.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.frameio-api-token.gl` | FRAMEIO_API_TOKEN | 0.8 | — |
| `api_keys.gcp-api-key.gl` | GCP_API_KEY | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=4.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.gocardless-api-token.gl` | GOCARDLESS_API_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `api_keys.grafana-api-key.gl` | GRAFANA_API_KEY | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.grafana-cloud-api-token.gl` | GRAFANA_CLOUD_API_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.harness-api-key.gl` | HARNESS_API_KEY | 0.8 | — |
| `api_keys.hashicorp-tf-api-token.gl` | HASHICORP_TF_API_TOKEN | 0.8 | entropy=3.5 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.heroku-api-key-v2.gl` | HEROKU_API_KEY_V2 | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=4.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.heroku-api-key.gl` | HEROKU_API_KEY | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `api_keys.hubspot-api-key.gl` | HUBSPOT_API_KEY | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `api_keys.huggingface-organization-api-token.gl` | HUGGINGFACE_ORGANIZATION_API_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.infracost-api-token.gl` | INFRACOST_API_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.intercom-api-key.gl` | INTERCOM_API_KEY | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `api_keys.jfrog-api-key.gl` | JFROG_API_KEY | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `api_keys.linear-api-key.gl` | LINEAR_API_KEY | 0.8 | entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.lob-api-key.gl` | LOB_API_KEY | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `api_keys.lob-pub-api-key.gl` | LOB_PUB_API_KEY | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `api_keys.mailchimp-api-key.gl` | MAILCHIMP_API_KEY | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `api_keys.mailgun-private-api-token.gl` | MAILGUN_PRIVATE_API_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `api_keys.mapbox-api-token.gl` | MAPBOX_API_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `api_keys.messagebird-api-token.gl` | MESSAGEBIRD_API_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `api_keys.new-relic-browser-api-token.gl` | NEW_RELIC_BROWSER_API_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `api_keys.new-relic-user-api-key.gl` | NEW_RELIC_USER_API_KEY | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `api_keys.notion-api-token.gl` | NOTION_API_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=4.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.octopus-deploy-api-key.gl` | OCTOPUS_DEPLOY_API_KEY | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.openai-api-key.gl` | OPENAI_API_KEY | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.perplexity-api-key.gl` | PERPLEXITY_API_KEY | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=4.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.plaid-api-token.gl` | PLAID_API_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `api_keys.planetscale-api-token.gl` | PLANETSCALE_API_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.postman-api-token.gl` | POSTMAN_API_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.prefect-api-token.gl` | PREFECT_API_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.privateai-api-token.gl` | PRIVATEAI_API_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.pulumi-api-token.gl` | PULUMI_API_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.readme-api-token.gl` | README_API_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.rubygems-api-token.gl` | RUBYGEMS_API_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.scalingo-api-token.gl` | SCALINGO_API_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.sendgrid-api-token.gl` | SENDGRID_API_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.sendinblue-api-token.gl` | SENDINBLUE_API_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.shippo-api-token.gl` | SHIPPO_API_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.snyk-api-token.gl` | SNYK_API_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `api_keys.sonar-api-token.gl` | SONAR_API_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `api_keys.telegram-bot-api-token.gl` | TELEGRAM_BOT_API_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `api_keys.twilio-api-key.gl` | TWILIO_API_KEY | 0.8 | entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `api_keys.twitch-api-token.gl` | TWITCH_API_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `api_keys.twitter-api-key.gl` | TWITTER_API_KEY | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `api_keys.twitter-bearer-token.gl` | TWITTER_BEARER_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `api_keys.typeform-api-token.gl` | TYPEFORM_API_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `api_keys.yandex-api-key.gl` | YANDEX_API_KEY | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `access_tokens.1password-secret-key.gl` | 1PASSWORD_SECRET_KEY | 0.8 | entropy=3.8 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.1password-service-account-token.gl` | 1PASSWORD_SERVICE_ACCOUNT_TOKEN | 0.8 | entropy=4.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.age-secret-key.gl` | AGE_SECRET_KEY | 0.8 | — |
| `access_tokens.airtable-personnal-access-token.gl` | AIRTABLE_PERSONNAL_ACCESS_TOKEN | 0.8 | keywords-гейт (airtable) не воспроизводим; regex специфичен (pat + 14 alnum + точка + 64 hex) |
| `access_tokens.alibaba-access-key-id.gl` | ALIBABA_ACCESS_KEY_ID | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.alibaba-secret-key.gl` | ALIBABA_SECRET_KEY | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.artifactory-reference-token.gl` | ARTIFACTORY_REFERENCE_TOKEN | 0.8 | entropy=4.5 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.authress-service-client-access-key.gl` | AUTHRESS_SERVICE_CLIENT_ACCESS_KEY | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.aws-access-token.gl` | AWS_ACCESS_TOKEN | 0.8 | entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.bittrex-access-key.gl` | BITTREX_ACCESS_KEY | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `access_tokens.cloudflare-origin-ca-key.gl` | CLOUDFLARE_ORIGIN_CA_KEY | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.codecov-access-token.gl` | CODECOV_ACCESS_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `access_tokens.coinbase-access-token.gl` | COINBASE_ACCESS_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `access_tokens.confluent-access-token.gl` | CONFLUENT_ACCESS_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `access_tokens.confluent-secret-key.gl` | CONFLUENT_SECRET_KEY | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `access_tokens.datadog-access-token.gl` | DATADOG_ACCESS_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `access_tokens.digitalocean-access-token.gl` | DIGITALOCEAN_ACCESS_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.digitalocean-pat.gl` | DIGITALOCEAN_PAT | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.droneci-access-token.gl` | DRONECI_ACCESS_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `access_tokens.etsy-access-token.gl` | ETSY_ACCESS_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.facebook-access-token.gl` | FACEBOOK_ACCESS_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен); keywords-гейт (facebook где угодно в тексте) не воспроизводим; regex достаточно специфичен (15-16 цифр + |/% + 27-40 символов) |
| `access_tokens.facebook-page-access-token.gl` | FACEBOOK_PAGE_ACCESS_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=4.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.finnhub-access-token.gl` | FINNHUB_ACCESS_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `access_tokens.flickr-access-token.gl` | FLICKR_ACCESS_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `access_tokens.flutterwave-encryption-key.gl` | FLUTTERWAVE_ENCRYPTION_KEY | 0.8 | entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.flutterwave-public-key.gl` | FLUTTERWAVE_PUBLIC_KEY | 0.8 | entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.flutterwave-secret-key.gl` | FLUTTERWAVE_SECRET_KEY | 0.8 | entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.freemius-secret-key.gl` | FREEMIUS_SECRET_KEY | 0.8 | — |
| `access_tokens.freshbooks-access-token.gl` | FRESHBOOKS_ACCESS_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `access_tokens.github-app-token.gl` | GITHUB_APP_TOKEN | 0.8 | entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.github-fine-grained-pat.gl` | GITHUB_FINE_GRAINED_PAT | 0.8 | entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.github-pat.gl` | GITHUB_PAT | 0.8 | entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.gitlab-cicd-job-token.gl` | GITLAB_CICD_JOB_TOKEN | 0.8 | entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.gitlab-deploy-token.gl` | GITLAB_DEPLOY_TOKEN | 0.8 | entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.gitlab-feature-flag-client-token.gl` | GITLAB_FEATURE_FLAG_CLIENT_TOKEN | 0.8 | entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.gitlab-feed-token.gl` | GITLAB_FEED_TOKEN | 0.8 | entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.gitlab-incoming-mail-token.gl` | GITLAB_INCOMING_MAIL_TOKEN | 0.8 | entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.gitlab-kubernetes-agent-token.gl` | GITLAB_KUBERNETES_AGENT_TOKEN | 0.8 | entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.gitlab-pat-routable.gl` | GITLAB_PAT_ROUTABLE | 0.8 | entropy=4.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.gitlab-pat.gl` | GITLAB_PAT | 0.8 | entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.gitlab-ptt.gl` | GITLAB_PTT | 0.8 | entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.gitlab-rrt.gl` | GITLAB_RRT | 0.8 | entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.gitlab-runner-authentication-token-routable.gl` | GITLAB_RUNNER_AUTHENTICATION_TOKEN_ROUTABLE | 0.8 | entropy=4.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.gitlab-runner-authentication-token.gl` | GITLAB_RUNNER_AUTHENTICATION_TOKEN | 0.8 | entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.gitlab-scim-token.gl` | GITLAB_SCIM_TOKEN | 0.8 | entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.gitter-access-token.gl` | GITTER_ACCESS_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `access_tokens.grafana-service-account-token.gl` | GRAFANA_SERVICE_ACCOUNT_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.huggingface-access-token.gl` | HUGGINGFACE_ACCESS_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.jfrog-identity-token.gl` | JFROG_IDENTITY_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `access_tokens.kraken-access-token.gl` | KRAKEN_ACCESS_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `access_tokens.kucoin-access-token.gl` | KUCOIN_ACCESS_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `access_tokens.kucoin-secret-key.gl` | KUCOIN_SECRET_KEY | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `access_tokens.launchdarkly-access-token.gl` | LAUNCHDARKLY_ACCESS_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `access_tokens.mailgun-pub-key.gl` | MAILGUN_PUB_KEY | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `access_tokens.mailgun-signing-key.gl` | MAILGUN_SIGNING_KEY | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `access_tokens.mattermost-access-token.gl` | MATTERMOST_ACCESS_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `access_tokens.maxmind-license-key.gl` | MAXMIND_LICENSE_KEY | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=4.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.microsoft-teams-webhook.gl` | MICROSOFT_TEAMS_WEBHOOK | 0.8 | — |
| `access_tokens.netlify-access-token.gl` | NETLIFY_ACCESS_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `access_tokens.new-relic-insert-key.gl` | NEW_RELIC_INSERT_KEY | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `access_tokens.npm-access-token.gl` | NPM_ACCESS_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.nytimes-access-token.gl` | NYTIMES_ACCESS_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `access_tokens.okta-access-token.gl` | OKTA_ACCESS_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=4.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.openshift-user-token.gl` | OPENSHIFT_USER_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=3.5 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.plaid-secret-key.gl` | PLAID_SECRET_KEY | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=3.5 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.pypi-upload-token.gl` | PYPI_UPLOAD_TOKEN | 0.8 | entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.rapidapi-access-token.gl` | RAPIDAPI_ACCESS_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `access_tokens.sendbird-access-token.gl` | SENDBIRD_ACCESS_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `access_tokens.sentry-access-token.gl` | SENTRY_ACCESS_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.sentry-org-token.gl` | SENTRY_ORG_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=4.5 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.sentry-user-token.gl` | SENTRY_USER_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=3.5 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.settlemint-application-access-token.gl` | SETTLEMINT_APPLICATION_ACCESS_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.settlemint-personal-access-token.gl` | SETTLEMINT_PERSONAL_ACCESS_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.settlemint-service-access-token.gl` | SETTLEMINT_SERVICE_ACCESS_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.shopify-access-token.gl` | SHOPIFY_ACCESS_TOKEN | 0.8 | entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.shopify-custom-access-token.gl` | SHOPIFY_CUSTOM_ACCESS_TOKEN | 0.8 | entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.shopify-private-app-access-token.gl` | SHOPIFY_PRIVATE_APP_ACCESS_TOKEN | 0.8 | entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.slack-app-token.gl` | SLACK_APP_TOKEN | 0.8 | entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.slack-bot-token.gl` | SLACK_BOT_TOKEN | 0.8 | entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.slack-config-access-token.gl` | SLACK_CONFIG_ACCESS_TOKEN | 0.8 | entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.slack-legacy-bot-token.gl` | SLACK_LEGACY_BOT_TOKEN | 0.8 | entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.slack-legacy-token.gl` | SLACK_LEGACY_TOKEN | 0.8 | entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.slack-legacy-workspace-token.gl` | SLACK_LEGACY_WORKSPACE_TOKEN | 0.8 | entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.slack-user-token.gl` | SLACK_USER_TOKEN | 0.8 | entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.slack-webhook-url.gl` | SLACK_WEBHOOK_URL | 0.8 | — |
| `access_tokens.sourcegraph-access-token.gl` | SOURCEGRAPH_ACCESS_TOKEN | 0.8 | regex заменён (override): удалена «голая» ветка [a-fA-F0-9]{40} (ловила git SHA и любой 40-символьный hex); оставлены только ветки с префиксом sgp_; entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.square-access-token.gl` | SQUARE_ACCESS_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.squarespace-access-token.gl` | SQUARESPACE_ACCESS_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `access_tokens.stripe-access-token.gl` | STRIPE_ACCESS_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=2.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.sumologic-access-token.gl` | SUMOLOGIC_ACCESS_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=3.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.travisci-access-token.gl` | TRAVISCI_ACCESS_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `access_tokens.twitter-access-token.gl` | TWITTER_ACCESS_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `access_tokens.vault-batch-token.gl` | VAULT_BATCH_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=4.0 отброшен (нет аналога в PatternRecognizer; риск FP повышен) |
| `access_tokens.vault-service-token.gl` | VAULT_SERVICE_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead; entropy=3.5 отброшен (нет аналога в PatternRecognizer; риск FP повышен); ветка s\.[a-z0-9]{24} без бренд-префикса; основная ветка hvs. специфична |
| `access_tokens.yandex-access-token.gl` | YANDEX_ACCESS_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `access_tokens.yandex-aws-access-token.gl` | YANDEX_AWS_ACCESS_TOKEN | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `access_tokens.zendesk-secret-key.gl` | ZENDESK_SECRET_KEY | 0.8 | замыкающая (?:...) -> (?=...) lookahead |
| `extra.ssh-public-key` | SSH_PUBLIC_KEY | 0.8 | — |
| `extra.openrouter-api-key` | OPENROUTER_API_KEY | 0.8 | — |
| `extra.sk-rt-key` | SK_RT_API_KEY | 0.8 | — |
| `extra.llm-provider-token` | LLM_PROVIDER_TOKEN | 0.8 | — |

## Важные отличия от оригинального Go-фильтра

- Presidio маскирует **весь match**; границы `(?:X|$)`/`(?:^|X)` переведены в lookahead/lookbehind, чтобы не съедать символы вокруг секрета.
- `entropy`, `banlist`, `validators`, `min_length` (отдельное поле) не имеют аналогов в PatternRecognizer и отброшены; для правил, чья точность на них держалась, ключевые слова/длины вшиты в regex (см. таблицу выше).
- `capture_groups` не поддерживаются: маскируется весь match (для правил с ключевым словом в regex маска накрывает и его — например, `ИНН 7707083893` -> `<INN_ORG>`).
