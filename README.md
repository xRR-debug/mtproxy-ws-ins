# mtproxy-ws-ins

- **Движок** — [`Flowseal/tg-ws-proxy`](https://github.com/Flowseal/tg-ws-proxy): принимает MTProto и тоннелирует его в Telegram через **WebSocket (WSS)** к дата-центрам, с фолбэком через CfProxy (Cloudflare). Своих промежуточных серверов Telegram не требует.

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
curl -fsSL https://insage.ru/mtproxy/install.sh -o install.sh
sudo bash install.sh
```

Голый вызов спросит параметры в терминале. Любой переданный флаг => неинтерактивный режим.

Пример конфига MTProto без Fake-TLS, своя зона CfProxy, закреплённый сикрет

```bash
curl -fsSL https://insage.ru/mtproxy/install.sh | sudo bash -s -- --yes \
  --secret <32-hex> \
  --port 443 --server <твой-домен-или-IP> \
  --cfproxy-domain <твой домен проксируемый в CF> --cf-prefix node \
  --no-fake-tls --dpi-bypass
```

Пример конфига MTProto без Fake-TLS, встроенные CfProxy-домены (свою Cloudflare/DNS поднимать не нужно)
```bash
curl -fsSL https://insage.ru/mtproxy/install.sh | sudo bash -s -- --yes \
  --secret <32-hex> \
  --port 443 --server <твой-домен-или-IP> \
  --builtin-cfproxy --no-fake-tls --dpi-bypass
```
`--builtin-cfproxy` (`--no-cfproxy-domain`) переводит на режим `CF proxy: enabled (auto)`. Минусы против своей зоны: домены **публичные и общие** (могут быть перегружены/заблокированы), их подсети Cloudflare в РФ временами режутся/блокируются, и ты зависишь от внешнего списка. Своя зона (`--cfproxy-domain` + `node*`) стабильнее и приватнее, но требует настройки. Сервер (`--server` → IP VPS, серое облако) держать всё равно нужно.

Пример конфига MTProto с Fake-TLS (маскировка под --domain, ee-сикрет) - без --no-fake-tls, нужен живой HTTPS-сайт в --domain
```bash
curl -fsSL https://insage.ru/mtproxy/install.sh | sudo bash -s -- --yes \
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
| `--cf-prefix P` | префикс CfProxy-субдоменов | `node` |
| `--ws-keepalive SEC` | WS keepalive-пинги, 0=выкл | `30` |
| `--dpi-bypass` / `--no-dpi-bypass` | слой TCPMSS+nfqws | спрашивается / выкл в пайпе |
| `--dpi-opts "..."` | опции nfqws под ТСПУ | combo из mtproxy-setup |
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

Проверка на блокировку CfProxy(на RU IP будет заблокировано):
```bash
for ip in 149.154.175.50 149.154.167.51 149.154.175.100 149.154.167.91 149.154.171.5; do
  timeout 3 bash -c "echo > /dev/tcp/$ip/443" 2>/dev/null && echo "$ip OK" || echo "$ip BLOCKED"
done
```
`BLOCKED` → прямой путь недоступен, нужен CfProxy (своя зона или встроенные).`OK` → можно и без CfProxy.

## Fake-TLS или обычный MTProto?

- **Fake-TLS (по умолчанию, `ee`-сикрет)** - маскируется под обычный HTTPS к `--domain`. Лучше выглядит, но сейчас мобильные операторы и некоторые провайдеры режут именно TLS/SNI сигнатуру и тогда хендшейк не проходит.
- **`--no-fake-tls` (`dd`-сикрет)** - обычный обфусцированный MTProto без TLS. Если оператор режет Fake-TLS на входе - этот режим часто проходит. Проверить можно через tcpdump: доходит ли первый пакет с данными (`[P.]`) от клиента до сервера.

Ссылки различаются: Fake-TLS → `secret=ee<secret><домен_hex>`; обычный → `secret=dd<secret>`.

## Управление, автозапуск

Автозапуск настроен (`systemctl enable --now`).

```bash
systemctl status mtproxy-ws
journalctl -u mtproxy-ws -f                  # логи
journalctl -u mtproxy-ws -f | grep stats     # трафик: down/up
systemctl restart mtproxy-ws                 # сбрасывает подвисшие CfProxy-сессии
systemctl stop|disable mtproxy-ws

curl -fsSL https://insage.ru/mtproxy/install.sh | sudo bash -s -- --uninstall
```

Конфиг: `/etc/mtproxy-ws/proxy.conf` (после правки → `systemctl restart mtproxy-ws`). Wrapper: `/opt/tg-ws-proxy/run-server.sh`.

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
| `bad handshake` / на устройстве старая ссылка - удали все записи прокси, добавь актуальную |
| `timeout during handshake` | вход режется DPI: попробуй `--no-fake-tls`, смену порта/`--domain`; сними дамп - доходит ли `[P.]` |

### Zapret

`NFQWS_OPTS` в конфиге → `systemctl restart mtproxy-ws-nfqws`. Профиль для серверной обфускации ServerHello:

```
NFQWS_OPTS='--dpi-desync=fake --dpi-desync-any-protocol --dpi-desync-autottl --dpi-desync-fooling=md5sig,badseq --dpi-desync-repeats=6'
```

Слой висит на исходящих `sport=<порт>` (ответы прокси клиенту), отдельная очередь NFQUEUE `201`. Если на VPS уже есть zapret - ставь `--no-dpi-bypass`.

## Лицензия

Наследует MIT [`Flowseal/tg-ws-proxy`](https://github.com/Flowseal/tg-ws-proxy).
