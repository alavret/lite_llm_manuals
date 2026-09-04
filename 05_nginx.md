Инструкция: публикуем LiteLLM наружу только через nginx с SSL на порту `443`. Сам прокси остаётся на loopback и в интернет напрямую не светится.

Схема:

```text
GUI / клиенты
    →  https://litellm.domain.com  (nginx :443, TLS от Let's Encrypt)
    →  http://127.0.0.1:4000       (LiteLLM Proxy, только localhost)
```

После выполнения инструкции:

- подключение к инсталляции — `https://litellm.domain.com/v1` с ключом `LITELLM_MASTER_KEY`
- прямой доступ к `http://<host>:4000` из сети закрыт

---

## 1. Что понадобится

На Ubuntu:

- установленный по [01_setup_litellm.md](01_setup_litellm.md) LiteLLM systemd-сервисом
- доменное имя `litellm.domain.com`, A/AAAA-запись которого указывает на IP сервера
- открытые порты `80` и `443` в облаке/firewall (нужны для выпуска и продления сертификата)

Проверьте DNS с машины, откуда будете ходить:

```bash
dig +short litellm.domain.com
# должен вернуться внешний IP Ubuntu-хоста
```

---

## 2. Переводим LiteLLM на 127.0.0.1

Раз публикация идёт через nginx, прокси больше не нужно слушать все интерфейсы. В unit-файле меняем привязку с `0.0.0.0` на `127.0.0.1`.

Откройте unit:

```bash
sudo systemctl edit --full litellm
```

Приведите строку к виду:

```ini
ExecStart=/opt/litellm/venv/bin/litellm \
  --config /etc/litellm/config.yaml \
  --host 127.0.0.1 \
  --port 4000
```

Примените изменения:

```bash
sudo systemctl daemon-reload
sudo systemctl restart litellm
```

Проверка:

```bash
ss -ltnp | grep 4000
# должно быть 127.0.0.1:4000, а не 0.0.0.0:4000
curl -sS http://127.0.0.1:4000/v1/models \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY"
```

Если LiteLLM отвечает локально — идём дальше.

---

## 3. Закрываем порт 4000 извне

Если раньше открывали порт для прямого доступа — закройте:

```bash
sudo ufw delete allow 4000/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw status
```

Теперь до LiteLLM можно добраться только через nginx.

---

## 4. Установка nginx и certbot

```bash
sudo apt update
sudo apt install -y nginx certbot python3-certbot-nginx
sudo systemctl enable --now nginx
```

---

## 5. Конфигурация nginx (первый запуск, только HTTP)

Сертификата ещё нет, поэтому nginx сначала настраиваем **без секции 443** — иначе он не стартует с ошибкой `BIO_new_file() failed ... No such file or directory` (пути к сертификату указывают на ещё не выпущенный файл). HTTPS добавим в разделе 6 сразу после выпуска сертификата.

Создайте файл `/etc/nginx/sites-available/litellm.conf`:

```nginx
upstream litellm {
    server 127.0.0.1:4000;
    keepalive 32;
}

server {
    listen 80;
    server_name litellm.domain.com;

    # сюда certbot кладёт файлы проверки при выпуске/продлении
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        proxy_pass http://litellm;

        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto http;
        proxy_set_header Connection        "";

        # важное для стриминга ответов модели (SSE):
        proxy_buffering off;
        proxy_cache off;

        # долгие запросы к LLM не должны рваться
        proxy_read_timeout  600s;
        proxy_send_timeout  600s;
        proxy_connect_timeout 60s;
    }
}
```

Ключевые моменты (относятся и к будущей HTTPS-секции):

| Параметр | Зачем |
|---|---|
| `proxy_pass http://litellm` | бэкенд — LiteLLM на `127.0.0.1:4000` |
| `proxy_buffering off` | чтобы стриминг токенов шёл клиенту сразу, а не пачками |
| `proxy_read_timeout 600s` | длинные генерации не обрываются по таймауту |
| `client_max_body_size 64m` | крупные промпты/вложения не упираются в лимит nginx (по умолчанию 1m; добавить в секцию после включения HTTPS) |

Включите сайт и проверьте:

```bash
sudo ln -s /etc/nginx/sites-available/litellm.conf /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default
sudo nginx -t && sudo systemctl reload nginx
```

Проверка работы по HTTP (временно, до включения TLS):

```bash
curl -sS http://litellm.domain.com/v1/models \
  -H "Authorization: Bearer LITELLM_MASTER_KEY"
```

---

## 6. Сертификат Let's Encrypt

### Вариант A: certbot c nginx-плагином (рекомендуется)

Certbot найдёт ваш `server_name`, выпустит сертификат и сам пропишет пути к нему в конфигурацию:

```bash
sudo certbot --nginx -d litellm.domain.com
```

При выпуске согласитесь на редирект HTTP→HTTPS, если certbot предложит его добавить.

### Вариант B: webroot

Если хотите оставить полный контроль над конфигурацией:

1. Убедитесь, что секция `location /.well-known/acme-challenge/ { root /var/www/html; }` присутствует в блоке `listen 80`.
2. Выпустите сертификат:

```bash
sudo certbot certonly --webroot -w /var/www/html -d litellm.domain.com
```

Проверьте, что файлы появились:

```bash
sudo ls /etc/letsencrypt/live/litellm.domain.com/
# fullchain.pem  privkey.pem  chain.pem
```

### Включаем HTTPS (обязательно, для обоих вариантов)

После выпуска сертификата допишите в `/etc/nginx/sites-available/litellm.conf` второй `server`-блок и замените редирект в блоке `listen 80`. Итоговый файл:

```nginx
upstream litellm {
    server 127.0.0.1:4000;
    keepalive 32;
}

server {
    listen 80;
    server_name litellm.domain.com;

    # certbot при продлении продолжает класть сюда файлы проверки
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    # всё остальное — на HTTPS
    location / {
        return 301 https://$host$request_uri;
    }
}

server {
    # для nginx >= 1.25.1 вместо этого: `listen 443 ssl;` + отдельная директива `http2 on;`
    listen 443 ssl http2;
    server_name litellm.domain.com;

    ssl_certificate     /etc/letsencrypt/live/litellm.domain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/litellm.domain.com/privkey.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_session_cache shared:SSL:10m;

    client_max_body_size 64m;

    access_log /var/log/nginx/litellm.access.log;
    error_log  /var/log/nginx/litellm.error.log warn;

    location / {
        proxy_pass http://litellm;

        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Connection        "";

        # важное для стриминга ответов модели (SSE):
        proxy_buffering off;
        proxy_cache off;

        # долгие запросы к LLM не должны рваться
        proxy_read_timeout  600s;
        proxy_send_timeout  600s;
        proxy_connect_timeout 60s;
    }
}
```

Примените:

```bash
sudo nginx -t && sudo systemctl reload nginx
```

Продление: certbot ставит systemd-timer автоматически. Проверка:

```bash
sudo certbot renew --dry-run
systemctl list-timers | grep certbot
```

Certbot при продлении сам вызовет `reload nginx` (через deploy-hook пакета `python3-certbot-nginx`). Для webroot добавьте хук вручную, если его нет:

```bash
sudo sh -c 'cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<"EOF"
#!/bin/sh
nginx -t && systemctl reload nginx
EOF'
sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
```

---

## 7. Проверка итоговой работы

Из внешней машины:

```bash
curl -sS https://litellm.domain.com/v1/models \
  -H "Authorization: Bearer LITELLM_MASTER_KEY"
```

Стриминг:

```bash
curl -N https://litellm.domain.com/v1/chat/completions \
  -H "Authorization: Bearer LITELLM_MASTER_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"corp-llm","messages":[{"role":"user","content":"Привет"}],"stream":true}'
```

В GUI теперь указывайте:

| Поле | Значение |
|---|---|
| API Base / Base URL | `https://litellm.domain.com/v1` |
| API Key | `LITELLM_MASTER_KEY` |
| Model | `corp-llm` |

Также проверьте, что прямой доступ закрыт: `http://IP_UBUNTU:4000/v1/models` извне должен отвечать connection refused/timeout.

---

## 8. Типовые проблемы

| Симптом | Причина / решение |
|---|---|
| `certbot` выдаёт ошибку «DNS problem» | запись ещё не разошлась или указывает не на этот сервер; проверьте `dig +short` |
| Certbot «connection refused» на 80 порт | UFW/cloud firewall не пропускает `80/tcp`; `sudo ufw allow 80/tcp` |
| Ответы приходят не потоком, а всё сразу | забыли `proxy_buffering off` |
| Долгие генерации обрываются ~60 сек | увеличьте `proxy_read_timeout` |
| 502 Bad Gateway | LiteLLM не работает или слушает не `127.0.0.1:4000`; проверьте `ss -ltnp \| grep 4000` и `journalctl -u litellm -f` |
| 413 Request Entity Too Large | увеличьте `client_max_body_size` |
| Не работает после рестарта nginx | путь к сертификату неверен — сверьте каталог `/etc/letsencrypt/live/litellm.domain.com/` |
| `unknown directive "http2"` | nginx старше 1.25.1: используйте `listen 443 ssl http2;` (как в конфигурации), для 1.25.1+ — `listen 443 ssl;` + `http2 on;` |
| `BIO_new_file() failed ... fullchain.pem` при `nginx -t` | секция 443 включена до выпуска сертификата; сначала выпустите сертификат (раздел 6), затем добавляйте HTTPS-блок |

---

## 9. Итоговая архитектура

```text
GUI (клиенты)                        Ubuntu-сервер
┌──────────────┐   HTTPS :443   ┌──────────────────────────┐
│ Chatbox /    │ ─────────────▶ │ nginx (TLS Let's Encrypt)│
│ Open WebUI / │                │   ↓                      │
│ Continue     │                │ http://127.0.0.1:4000    │
└──────────────┘                │   ↓                      │
                                │ LiteLLM Proxy            │
                                │   ↓                      │
                                │ custom URL провайдера    │
                                └──────────────────────────┘
```

- Единственная точка входа — `https://litellm.domain.com`.
- LiteLLM слушает только `127.0.0.1`, недоступен по сети.
- Сертификат продлевается автоматически.
