# mtproxy-ws-ins

- **Движок** — форк [`xRR-debug/tg-ws-proxy`](https://github.com/xRR-debug/tg-ws-proxy) (на основе [`Flowseal/tg-ws-proxy`](https://github.com/Flowseal/tg-ws-proxy)): принимает MTProto и тоннелирует его в Telegram через **WebSocket (WSS)** к дата-центрам, с фолбэком через CfProxy (Cloudflare). Своих промежуточных серверов Telegram не требует.

Зачем? На RU VPS(IP) прямой путь к дата-центрам Telegram обычно заблокирован на ТСПУ. Проект уводит исходящий трафик в Telegram через **зону Cloudflare**, а вход для клиентов маскирует Fake-TLS либо отдаёт обычным MTProto.

## Архитектура

```
Telegram (клиент)
   │  tg://proxy?server=<entry>&port=<port>&secret=<dd…|ee…>
   ▼
RU IP (VPS) :<port>   (вход = <entry>, серое облако -> IP VPS)
   ├─ tg-ws-proxy: снимает обфускацию MTProto, достаёт DC
   │     └─ опц. Zapret на исходящих sport=<port>: TCPMSS=536 + nfqws
   ▼
WebSocket (WSS) -> Telegram DC
        ├─ прямой: kws{dc}.web.telegram.org
        └─ CfProxy: <prefix>{dc}.<домен>  (проксирование через Cloudflare + SSL/TLS=Flexible)
```

## Быстрый старт

```bash
curl -fsSL https://raw.githubusercontent.com/xRR-debug/mtproxy-ws-ins/main/install-mtproxy.sh -o install.sh && sudo bash install.sh
```

Голый вызов спросит параметры в терминале. Любой переданный флаг => неинтерактивный режим.

Скрипт ставит движок в `/opt/tg-ws-proxy` с отдельным venv и Python-зависимостями сервера (`cryptography`, `certifi`, `httpx[http2]`, как в Dockerfile форка). Повторный запуск = обновление: конфиг перезаписывается переданными флагами, поэтому чтобы ссылка не сменилась, передавай тот же `--secret`.

Пример конфига MTProto без Fake-TLS, своя зона CfProxy, закреплённый сикрет

```bash
curl -fsSL https://raw.githubusercontent.com/xRR-debug/mtproxy-ws-ins/main/install-mtproxy.sh | sudo bash -s -- --yes \
  --secret <32-hex> \
  --port 443 --server <твой-домен-или-IP> \
  --cfproxy-domain <твой домен проксируемый в CF> --cf-prefix node \
  --no-fake-tls --dpi-bypass
```

Пример конфига MTProto без Fake-TLS, встроенные CfProxy-домены (свою Cloudflare/DNS поднимать не нужно)
```bash
curl -fsSL https://raw.githubusercontent.com/xRR-debug/mtproxy-ws-ins/main/install-mtproxy.sh | sudo bash -s -- --yes \
  --secret <32-hex> \
  --port 443 --server <твой-домен-или-IP> \
  --builtin-cfproxy --no-fake-tls --dpi-bypass
```
`--builtin-cfproxy` (`--no-cfproxy-domain`) переводит на режим `CF proxy: enabled (auto)`. Минусы против своей зоны: домены **публичные и общие** (могут быть перегружены/заблокированы), их подсети Cloudflare в РФ временами режутся/блокируются, и ты зависишь от внешнего списка. Своя зона (`--cfproxy-domain` + `node*`) стабильнее и приватнее, но требует настройки. Сервер (`--server` → IP VPS, серое облако) держать всё равно нужно.

Пример конфига MTProto с Fake-TLS (маскировка под --domain, ee-сикрет) - без --no-fake-tls, нужен живой HTTPS-сайт в --domain
```bash
curl -fsSL https://raw.githubusercontent.com/xRR-debug/mtproxy-ws-ins/main/install-mtproxy.sh | sudo bash -s -- --yes \
  --secret <32-hex> \
  --port 443 --server <твой-домен-или-IP> --domain max.ru \
  --cfproxy-domain <твой домен проксируемый в CF> --cf-prefix node \
  --dpi-bypass
```

После установки скрипт печатает готовую `tg://`-ссылку и (если задан `--cfproxy-domain`) точный список DNS-записей.

## Флаги

| Флаг | Назначение | По умолчанию |
|---|---|---|
| `--port N` | порт MTProto | `443` |
| `--server H` | Сервер (`server=` в ссылке) | `= --domain` |
| `--domain D` | Fake-TLS | `max.ru` |
| `--no-fake-tls` | обычный MTProto (`dd`-сикрет, без TLS/SNI) | выкл |
| `--secret HEX` | 32-hex сикрет | генерируется |
| `--cfproxy-domain D` | база CfProxy для исходящего | база от `--domain` |
| `--no-cfproxy-domain` | авто-домены tg-ws-proxy | — |
| `--builtin-cfproxy` | встроенные CfProxy-домены (без своей зоны) | — |
| `--cf-prefix P` | префикс CfProxy-субдоменов | `kws` |
| `--ws-keepalive SEC` | WS keepalive-пинги, 0=выкл; применяется, только если движок поддерживает флаг | `30` |
| `--dpi-bypass` / `--no-dpi-bypass` | слой TCPMSS+nfqws | спрашивается / выкл в пайпе |
| `--dpi-opts "..."` | опции nfqws под ТСПУ | combo из mtproxy-setup |
| `--log-level L` / `--quiet` | `info\|warning\|error\|off` | `info` |
| `--web-proxy` / `--no-web-proxy` | WEB-прокси (см. ниже) | спрашивается / выкл в пайпе |
| `--web-host H` | домен WEB-прокси (A → VPS, серое облако) | — (обязателен) |
| `--web-email E` | e-mail для Let's Encrypt | пусто |
| `--web-base-path P\|none` | путь relay (`none` = корень) | случайный, сохраняется |
| `--web-carrier M` | `https\|https-lanes\|websocket\|websocket-lanes` | `https` |
| `--web-backend-port N` | локальный порт бэкенда (127.0.0.1) | `12398` |
| `--web-site-dir DIR` / `--web-site-upstream URL` | свой сайт-обложка | генерируется |
| `--web-relay-ref REF` | коммит `telegramdesktop/tproxy-server` | закреплённый |
| `--yes` | без вопросов | — |
| `--uninstall` | удалить всё | — |

**`--server`** = куда стучится клиент (твой VPS, серое облако); **`--domain`** = подо что маскируемся (чужой сайт, нужен только для Fake-TLS); **`--cfproxy-domain`** = через что прокси выходит в Telegram (твои поддомены, оранжевое облако).

### CfProxy: DNS + Cloudflare

A-записи (**оранжевое облако**), фиксированные IP адреса дата-центров Telegram:

```
<prefix>1   149.154.175.50
<prefix>2   149.154.167.51
<prefix>3   149.154.175.100
<prefix>4   149.154.167.91
<prefix>5   149.154.171.5
<prefix>203 91.105.192.100
```

Обязательно: **Cloudflare → SSL/TLS → Overview → Flexible.** Без Flexible CF→Telegram отвалится по timeout.

`--cf-prefix` патчит одну строку в `bridge.py` (`kws{dc}` → `<prefix>{dc}`); дефолтный `kws` — известная сигнатура tg-ws-proxy, свой префикс сбивает тривиальное сканирование зоны (но не Cloudflare/Telegram-side фингерпринт).

### Какой режим выбрать

| Режим | Флаги | Когда |
|---|---|---|
| Своя зона CfProxy | `--cfproxy-domain D --cf-prefix P` | на RU VPS прямой путь к DC заблокирован. Стабильно, приватно, но нужны `node*`-записи + Cloudflare Flexible |
| Встроенные домены | `--builtin-cfproxy` | быстро поднять без настройки DNS. Домены публичные/общие, подсети CF в РФ временами режутся — как запасной вариант |
| Только прямой к DC | `--no-cfproxy-domain` + убедиться, что DC доступны | подходит для **не**-RU VPS, где `kws{dc}.web.telegram.org` достижим. На RU VPS обычно мёртво |

## Fake-TLS или обычный MTProto?

- **Fake-TLS (по умолчанию, `ee`-сикрет)** - маскируется под обычный HTTPS к `--domain`. Лучше выглядит, но сейчас мобильные операторы и некоторые провайдеры режут именно TLS/SNI сигнатуру и тогда хендшейк не проходит.
- **`--no-fake-tls` (`dd`-сикрет)** - обычный обфусцированный MTProto без TLS. Если оператор режет Fake-TLS на входе - этот режим часто проходит. Проверить можно через tcpdump: доходит ли первый пакет с данными (`[P.]`) от клиента до сервера.

Ссылки различаются: Fake-TLS → `secret=ee<secret><домен_hex>`; обычный → `secret=dd<secret>`.

## WEB-прокси (Telegram Desktop 7.1+)

В Telegram Desktop 7.1 появился новый тип прокси — **WEB-прокси** (`t.me/webproxy`). Клиент делает обычный MTProxy-хендшейк (obfuscated2 с сикретом), но все TCP-соединения гонит через скрытый WebView по **HTTPS к твоему домену**. Для DPI это выглядит как браузер на обычном сайте с валидным сертификатом. Серверная часть — официальный relay [`telegramdesktop/tproxy-server`](https://github.com/telegramdesktop/tproxy-server).

Upstream ставит за relay официальный MTProxy, но на RU VPS он не достучится до DC. Поэтому здесь бэкендом служит **второй экземпляр tg-ws-proxy** на `127.0.0.1`, без Fake-TLS, с тем же сикретом. Дальше трафик идёт тем же путём: WSS/CfProxy.

```
Telegram Desktop 7.1+
   │  https://t.me/webproxy?server=<web-host>%2F<base-path>&secret=<…>
   ▼
VPS :443  Caddy (Let's Encrypt, <web-host>)          mtproxy-ws-caddy
   ▼
127.0.0.1:18080  tproxy-server (relay, сайт-обложка)  mtproxy-ws-relay
   ▼  по TCP-соединению на каждый поток клиента
127.0.0.1:12398  tg-ws-proxy (без Fake-TLS)           mtproxy-ws-web-backend
   ▼
WebSocket (WSS) / CfProxy -> Telegram DC
```

Требования:

- **Домен** (`--web-host`) с A-записью на IP VPS, **серое облако** (без CDN/Cloudflare-прокси): сертификат выпускает сам Caddy.
- Свободные **80 и 443**. Caddy занимает 443, поэтому MTProto уходит на другой порт (например `--port 8443`). В интерактивном режиме скрипт спросит сам.
- amd64/arm64. Relay собирается из исходников закреплённого коммита. Go, если его нет, ставится временно и удаляется после сборки. Caddy берётся из официального релиза, sha512 сверяется.

```bash
curl -fsSL https://raw.githubusercontent.com/xRR-debug/mtproxy-ws-ins/main/install-mtproxy.sh | sudo bash -s -- --yes \
  --secret <32-hex> \
  --port 8443 --server <твой-домен-или-IP> --domain max.ru \
  --builtin-cfproxy --dpi-bypass \
  --web-proxy --web-host web.example.com --web-email you@example.com
```

Скрипт печатает обе ссылки, MTProto и WEB. Позже их можно получить через `mtproxy-ws link`, только WEB — через `mtproxy-ws weblink`, QR — через `mtproxy-ws qr web`.

**Base path.** По умолчанию relay живёт по случайному пути (`https://<web-host>/<слаг>/`), и без этого пути сканер видит только сайт-обложку. В ссылке тогда `server=<host>%2F<слаг>`, а сикрет имеет вид `base64url(0x70 ‖ secret)`. Клиенты без поддержки base path не подключатся к такой ссылке, а предложат обновиться. Для совместимости со старыми 7.1.x поставь `--web-base-path none`: relay встанет в корень, а сикрет останется обычным hex. Смена base path = перевыпуск ссылки.

**Сайт-обложка.** На домене relay должен открываться «живой» сайт. Одинаковый шаблон у всех установок легко стал бы сигнатурой, поэтому скрипт генерирует случайную страничку в `/opt/mtproxy-ws-web/site`. Её можно заменить своей статикой (`--web-site-dir DIR`, нужен `index.html`) или своим приложением на loopback (`--web-site-upstream http://127.0.0.1:3000`).

**Carrier.** `https` (по умолчанию) — long-poll запросы, самый «браузерный» вариант. `websocket` экономнее, но заметнее. Варианты `*-lanes` разносят потоки по нескольким соединениям.

**Fake-TLS + WEB.** Можно поставить `--domain` равным `--web-host`. Тогда Fake-TLS маскируется под твой же реальный сайт с валидным сертификатом, а не под чужой. Петли нет: MTProto слушает 8443, а маскировка уходит на :443 к Caddy.

Файлы и сервисы:

| Что | Где |
|---|---|
| конфиг relay, профиль, ключ токенов | `/etc/mtproxy-ws/web/{config.json,profiles.json,token.key}` |
| Caddyfile | `/etc/mtproxy-ws/caddy/Caddyfile` |
| бинарники, сайт | `/opt/mtproxy-ws-web/{bin,site}` |
| сертификаты | `/var/lib/mtproxy-ws-caddy` |
| сервисы | `mtproxy-ws-web-backend`, `mtproxy-ws-relay`, `mtproxy-ws-caddy` |

Системный Caddy/nginx скрипт не трогает. Если на 80/443 уже кто-то слушает, установка остановится с сообщением. `mtproxy-ws rotate` меняет сикрет сразу для обеих ссылок.

## Управление, автозапуск

Автозапуск настроен (`systemctl enable --now`).

```bash
systemctl status mtproxy-ws
journalctl -u mtproxy-ws -f                  # логи
journalctl -u mtproxy-ws -f | grep stats     # трафик: down/up
systemctl restart mtproxy-ws                 # сбрасывает подвисшие CfProxy-сессии
systemctl stop|disable mtproxy-ws

curl -fsSL https://raw.githubusercontent.com/xRR-debug/mtproxy-ws-ins/main/install-mtproxy.sh | sudo bash -s -- --uninstall
```

Конфиг: `/etc/mtproxy-ws/proxy.conf` (после правки → `systemctl restart mtproxy-ws`). Wrapper: `/opt/tg-ws-proxy/run-server.sh` (`run-server.sh web` = бэкенд WEB-прокси).

Менеджер: `mtproxy-ws {status|start|stop|restart|link|weblink|webinfo|qr [web]|logs [web]|edit|rotate|update}`. С включённым WEB-прокси `start/stop/restart/status` охватывают и его сервисы.

## Диагностика

```bash
# режим/сикрет на сервере
grep -E '^SERVER=|^PORT=|^SECRET=|^NO_FAKE_TLS=|^KEEPALIVE_OK=' /etc/mtproxy-ws/proxy.conf

# CfProxy жив? (timeout = не отвечает/отфильтрован; 404 = ок)
for d in node1 node2 node3 node4 node5 node203; do
  echo -n "$d: "; curl -sS -o /dev/null -w "%{http_code}\n" --max-time 5 "https://$d.example.com/"
done

# прямое подключение к DC telegram (BLOCKED на RU VPS - норм, идём через CfProxy)
for ip in 149.154.175.50 149.154.167.51 149.154.175.100 149.154.167.91 149.154.171.5; do
  timeout 3 bash -c "echo > /dev/tcp/$ip/443" 2>/dev/null && echo "$ip OK" || echo "$ip BLOCKED"
done
```

| Симптом | Причина / лечение |
|---|---|
| `stats` норм, но `down` застыл при `active>0` | CfProxy лёг: проверь Cloudflare **Flexible**, затем `restart` |
| `masked` растёт | сервер в Fake-TLS режиме, а клиент с `dd`-ссылкой (или наоборот) |
| `bad handshake` | на устройстве старая ссылка: удали все записи прокси, добавь актуальную |
| `No module named …` при старте | старый установщик не доставил зависимости движка: перезапусти актуальный `install-mtproxy.sh` |
| `unrecognized arguments: --ws-keepalive` | старый установщик, а форк флаг не поддерживает: перезапусти актуальный `install-mtproxy.sh` |
| `timeout during handshake` | вход режется DPI: попробуй `--no-fake-tls`, смену порта/`--domain`; сними дамп - доходит ли `[P.]` |
| WEB: клиент пишет «неподдерживаемый тип прокси» | старый Telegram Desktop: обнови до 7.1.3+ или переустанови с `--web-base-path none` |
| WEB: сайт не открывается по HTTPS | A-запись не на VPS / оранжевое облако / закрыт 80: `journalctl -u mtproxy-ws-caddy` |
| WEB: сайт открывается, прокси нет | `curl 127.0.0.1:18081/readyz` и `mtproxy-ws logs web`; бэкенд в `/var/log/mtproxy-ws-web.log` |

```bash
# WEB-прокси
curl -sS http://127.0.0.1:18081/readyz; echo        # relay видит бэкенд
curl -sSI https://<web-host>/ | head -1               # сайт-обложка + сертификат
systemctl status mtproxy-ws-web-backend mtproxy-ws-relay mtproxy-ws-caddy --no-pager
```

### Zapret

`NFQWS_OPTS` в конфиге → `systemctl restart mtproxy-ws-nfqws`. Профиль для серверной обфускации ServerHello:

```
NFQWS_OPTS='--dpi-desync=fake --dpi-desync-any-protocol --dpi-desync-autottl --dpi-desync-fooling=md5sig,badseq --dpi-desync-repeats=6'
```

Слой висит на исходящих `sport=<порт>` (ответы прокси клиенту), отдельная очередь NFQUEUE `201`. Если на VPS уже есть zapret - ставь `--no-dpi-bypass`.

## Лицензия

Наследует MIT [`Flowseal/tg-ws-proxy`](https://github.com/Flowseal/tg-ws-proxy).
