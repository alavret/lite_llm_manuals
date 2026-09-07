Docker-версия гайда [05_nginx.md](05_nginx.md): публикуем LiteLLM наружу только через nginx с SSL на порту `443`, причём сам nginx тоже работает в контейнере рядом с LiteLLM из [01d_setup_litellm.md](01d_setup_litellm.md). Прокси остаётся на loopback и в интернет напрямую не светится.

Схема:

```text
GUI / клиенты
    →  https://litellm.domain.com  (nginx :443, TLS от Let's Encrypt, контейнер)
    →  http://litellm:4000         (LiteLLM Proxy, контейнер, сеть Docker)
```

После выполнения инструкции:

- подключение к инсталляции — `https://litellm.domain.com/v1` с ключом `LITELLM_MASTER_KEY`
- прямой доступ к `http://<host>:4000` из сети закрыт

---

## 1. Что понадобится

На Ubuntu:

- LiteLLM в Docker по [01d_setup_litellm.md](01d_setup_litellm.md)
- доменное имя `litellm.domain.com`, A/AAAA-запись которого указывает на IP сервера
- открытые порты `80` и `443` в облаке/firewall (нужны для выпуска и продления сертификата)

Проверьте DNS с машины, откуда будете ходить:

```bash
dig +short litellm.domain.com
# должен вернуться внешний IP Ubuntu-хоста
```

---

## 2. Переводим LiteLLM на 127.0.0.1

Раз публикация идёт через nginx, публиковать порт 4000 на всех интерфейсах не нужно. В `/opt/litellm/docker-compose.yml` замените привязку:

```yaml
    ports:
      - "127.0.0.1:4000:4000"
```

и примените (правился `docker-compose.yml` — нужно пересоздание):

```bash
cd /opt/litellm
docker compose up -d
```

Проверка:

```bash
ss -ltnp | grep 4000
# должно быть 127.0.0.1:4000, а не 0.0.0.0:4000
curl -sS http://127.0.0.1:4000/v1/models \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY"
```

Если LiteLLM отвечает локально — идём дальше. При этом контейнер остаётся доступен по имени `litellm` внутри Docker-сети — этим и воспользуется nginx.

---

## 3. Закрываем порт 4000 извне

Если раньше открывали порт для прямого доступа — закройте на уровне облака/роутера:

```bash
sudo ufw delete allow 4000/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw status
```

Учтите: UFW не фильтрует порты, опубликованные Docker'ом (обход через iptables). Поэтому привязка `127.0.0.1:4000:4000` из раздела 2 — основной механизм закрытия порта; UFW-правила здесь — дополнительная гигиена для сервисов вне Docker.

---

## 4. Каталог и docker-compose для nginx + certbot

```bash
sudo mkdir -p /opt/nginx/conf.d /opt/nginx/www
sudo chown -R $USER:$USER /opt/nginx
nano /opt/nginx/docker-compose.yml
```

```yaml
services:
  nginx:
    image: nginx:stable
    container_name: litellm-nginx
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./conf.d:/etc/nginx/conf.d:ro
      - ./www:/var/www/html
      - ./letsencrypt:/etc/letsencrypt
    networks:
      - litellm-net

  certbot:
    image: certbot/certbot
    container_name: litellm-certbot
    volumes:
      - ./www:/var/www/html
      - ./letsencrypt:/etc/letsencrypt
    # разовая утилита: запускается командой docker compose run --rm certbot ...

networks:
  litellm-net:
    external: true     # сеть, созданная docker-compose из 01d
```

Сеть `litellm-net` должна уже существовать (создаётся при `docker compose up -d` в `/opt/litellm`).

В контейнере nginx нет `sites-available` — конфиги сайтов кладутся в `/etc/nginx/conf.d/*.conf`, поэтому монтируем наш каталог `conf.d`.

---

## 5. Конфигурация nginx (первый запуск, только HTTP)

Сертификата ещё нет, поэтому nginx сначала настраиваем **без секции 443** — иначе он не стартует с ошибкой `BIO_new_file() failed ... No such file or directory` (пути к сертификату указывают на ещё не выпущенный файл). HTTPS добавим в разделе 6 сразу после выпуска сертификата.

Создайте файл `/opt/nginx/conf.d/litellm.conf`:

```nginx
upstream litellm {
    server litellm:4000;
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

Отличие от venv-версии: `proxy_pass` идёт на `http://litellm:4000` — по имени контейнера в общей сети Docker, а не на `127.0.0.1` (внутри контейнера nginx это был бы сам nginx).

Ключевые моменты (относятся и к будущей HTTPS-секции):

| Параметр | Зачем |
|---|---|
| `proxy_pass http://litellm` | бэкенд — контейнер `litellm` в сети `litellm-net` |
| `proxy_buffering off` | чтобы стриминг токенов шёл клиенту сразу, а не пачками |
| `proxy_read_timeout 600s` | длинные генерации не обрываются по таймауту |
| `client_max_body_size 64m` | крупные промпты/вложения не упираются в лимит nginx (по умолчанию 1m; добавить в секцию после включения HTTPS) |

Запустите nginx и проверьте по HTTP (временно, до включения TLS):

```bash
cd /opt/nginx
docker compose up -d nginx
curl -sS http://litellm.domain.com/v1/models \
  -H "Authorization: Bearer LITELLM_MASTER_KEY"
```

---

## 6. Сертификат Let's Encrypt (certbot в Docker)

### 6.1. Выпуск сертификата

```bash
cd /opt/nginx
docker compose run --rm certbot certonly --webroot -w /var/www/html -d litellm.domain.com
```

Certbot спросит e-mail (для уведомлений о продлении) и согласия с условиями. Успешный выпуск заканчивается строкой вида `Congratulations! Your certificate... is saved at: /etc/letsencrypt/live/litellm.domain.com/fullchain.pem`.

Файлы лежат в `/opt/nginx/letsencrypt/live/litellm.domain.com/` на хосте (том `./letsencrypt` смонтирован и в nginx, и в certbot).

### 6.2. Включаем HTTPS

Допишите в `/opt/nginx/conf.d/litellm.conf` второй `server`-блок и замените обработку в блоке `listen 80`. Итоговый файл:

```nginx
upstream litellm {
    server litellm:4000;
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

Проверьте конфиг и перезагрузите nginx **без остановки** (reload подхватит сертификат, а restart при ошибке в конфиге уронит публикацию):

```bash
cd /opt/nginx
docker compose exec nginx nginx -t
docker compose exec nginx nginx -s reload
```

### 6.3. Продление

Сертификат живёт 90 дней. Продление — тот же certbot-контейнер по cron или systemd-timer; после продления нужен reload nginx.

Создайте скрипт `/usr/local/bin/litellm-cert-renew.sh`:

```bash
sudo tee /usr/local/bin/litellm-cert-renew.sh > /dev/null <<'EOF'
#!/bin/sh
cd /opt/nginx
docker compose run --rm certbot renew --webroot -w /var/www/html
docker compose exec -T nginx nginx -t && docker compose exec -T nginx nginx -s reload
EOF
sudo chmod +x /usr/local/bin/litellm-cert-renew.sh
```

И запись в cron (`sudo crontab -e`) — certbot сам продлит только близкие к истечению сертификаты:

```cron
0 4 * * 1 /usr/local/bin/litellm-cert-renew.sh >> /var/log/litellm-cert-renew.log 2>&1
```

Разовая проверка продления:

```bash
sudo /usr/local/bin/litellm-cert-renew.sh
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
| Certbot «connection refused» на 80 порт | cloud firewall/роутер не пропускает `80/tcp`; проверьте проброс портов |
| Ответы приходят не потоком, а всё сразу | забыли `proxy_buffering off` |
| Долгие генерации обрываются ~60 сек | увеличьте `proxy_read_timeout` |
| 502 Bad Gateway | контейнер `litellm` не работает или nginx не в сети `litellm-net`; `cd /opt/litellm && docker compose ps`, логи nginx: `docker compose logs nginx` |
| 502 после `docker compose up -d` в `/opt/litellm` (контейнер litellm пересоздавался), хотя сам litellm работает локально (`curl http://127.0.0.1:4000/health/liveliness` → 200) | nginx закэшировал старый IP контейнера: имя `litellm` из `upstream` резолвится **один раз при старте nginx**, а пересозданному контейнеру Docker выдал новый IP. Лечится `docker restart litellm-nginx` (или `cd /opt/nginx && docker compose restart nginx`). Постоянное решение — динамический резолв: в `server`-блок добавить `resolver 127.0.0.11 valid=10s ipv6=off;` (встроенный DNS Docker), вынести адрес в переменную и использовать её в `proxy_pass`: `set $litellm_upstream http://litellm:4000;` + `proxy_pass $litellm_upstream;` — тогда nginx будет перечитывать IP каждые 10 сек. Замечание: при `proxy_pass` через переменную nginx подставляет URI как есть, поэтому для проксирования `/ui/` и т.п. с сохранением пути это безопасно только без подстановки URI в `proxy_pass` |
| nginx: `host not found in upstream "litellm"` | nginx не подключён к сети `litellm-net` или контейнер LiteLLM не запущен |
| 413 Request Entity Too Large | увеличьте `client_max_body_size` |
| Не работает после рестарта nginx | путь к сертификату неверен — сверьте каталог `/opt/nginx/letsencrypt/live/litellm.domain.com/` |
| `unknown directive "http2"` | образ nginx старше 1.25.1: используйте `listen 443 ssl http2;` (как в конфигурации), для 1.25.1+ — `listen 443 ssl;` + `http2 on;` |
| `BIO_new_file() failed ... fullchain.pem` при `nginx -t` | секция 443 включена до выпуска сертификата; сначала выпустите сертификат (раздел 6.1), затем добавляйте HTTPS-блок |
| Порт 80/443 занят чем-то на хосте | `ss -ltnp | grep -E ':80|:443'`; остановите/перенастройте занявший сервис — в контейнере они обязаны быть свободны на хосте |

---

## 9. Итоговая архитектура

```text
GUI (клиенты)                        Ubuntu-сервер (Docker)
┌──────────────┐   HTTPS :443   ┌────────────────────────────────┐
│ Chatbox /    │ ─────────────▶ │ nginx (контейнер, TLS Let's    │
│ Open WebUI / │                │ Encrypt)                       │
│ Continue     │                │   ↓ сеть litellm-net           │
└──────────────┘                │ http://litellm:4000            │
                                │   ↓                            │
                                │ LiteLLM Proxy (контейнер)      │
                                │   ↓                            │
                                │ custom URL провайдера          │
                                └────────────────────────────────┘
```

- Единственная точка входа — `https://litellm.domain.com`.
- LiteLLM публикуется только на `127.0.0.1` хоста, из сети недоступен; внутри Docker ходит по имени сервиса.
- Сертификат продлевается автоматически (cron/systemd-timer + certbot-контейнер).
