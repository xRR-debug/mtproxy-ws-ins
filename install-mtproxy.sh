#!/usr/bin/env bash
# mtproxy-ws-ins: Flowseal/tg-ws-proxy + zapret (+ WEB-прокси Telegram Desktop 7.1+).
set -euo pipefail

ORIG_ARGC=$#

REPO_URL="https://github.com/xRR-debug/tg-ws-proxy.git"
REPO_REF="main"          # ветка
ZAPRET_URL="https://github.com/bol-van/zapret.git"
APP_DIR="/opt/tg-ws-proxy"
VENV_DIR="${APP_DIR}/.venv"
BRIDGE_PY="${APP_DIR}/proxy/bridge.py"
ZAPRET_DIR="/opt/zapret"
CONF_DIR="/etc/mtproxy-ws"
CONF_FILE="${CONF_DIR}/proxy.conf"
RUN_WRAPPER="${APP_DIR}/run-server.sh"
IPT_RULES="${CONF_DIR}/iptables.rules"
SVC_PROXY="mtproxy-ws.service"
SVC_NFQWS="mtproxy-ws-nfqws.service"
SVC_IPT="mtproxy-ws-iptables.service"
QNUM=201
MSS=536
BASE_URL="https://raw.githubusercontent.com/xRR-debug/tg-ws-proxy/main"
SELF_URL="${BASE_URL}/install.sh"

# WEB-прокси: Caddy :443 -> tproxy-server (relay) -> локальный tg-ws-proxy (без Fake-TLS)
SVC_WEB_BACKEND="mtproxy-ws-web-backend.service"
SVC_RELAY="mtproxy-ws-relay.service"
SVC_CADDY="mtproxy-ws-caddy.service"
WEB_DIR="/opt/mtproxy-ws-web"          # bin/ (tproxy-server, caddy), site/
WEB_CONF_DIR="${CONF_DIR}/web"         # config.json, profiles.json, token.key
CADDY_CONF_DIR="${CONF_DIR}/caddy"     # Caddyfile
CADDY_DATA="/var/lib/mtproxy-ws-caddy" # сертификаты ACME
RELAY_USER="mtpws-relay"
CADDY_USER="mtpws-caddy"
RELAY_LISTEN="127.0.0.1:18080"
RELAY_ADMIN="127.0.0.1:18081"
RELAY_REPO="telegramdesktop/tproxy-server"
CADDY_VER="2.11.4"
CADDY_SHA512_amd64="8220d1f013b6f27510247b2360c9e0ca9f018feebd82515f07635318b34ff9777ccc8fd0b6e6f2486ce3a33fe389fbb7db12d05baa474f4587509fb4f5ebf1c9"
CADDY_SHA512_arm64="d5a7c423853c24a799765e0e8210d5c7c22a8f56ed37a3cae2fb9f58be138853c02b4efd6b59d576e6d8c7c0d30b9c1592deeaa6a536ff69bcca23b8c1ea709c"
GO_VER="1.26.5"                        # ставится временно, только если нет go >= 1.20
GO_SHA256_amd64="5c2c3b16caefa1d968a94c1daca04a7ca301a496d9b086e17ad77bb81393f053"
GO_SHA256_arm64="fe4789e92b1f33358680864bbe8704289e7bb5fc207d80623c308935bd696d49"

# ===== ДЕФОЛТЫ - МЕНЯТЬ ЗДЕСЬ (или флагами при запуске) =====
PORT="443"
SERVER=""                 # пусто => берётся DOMAIN
DOMAIN="max.ru"             # Fake-TLS; для --no-fake-tls не используется
SECRET=""                 # пусто => генерируется; ЗАКРЕПИ свой, чтобы ссылка не менялась
CFPROXY_DOMAIN=""         # пусто => база от DOMAIN
CFPROXY_DISABLE=0
CF_PREFIX="kws"           # префикс CfProxy-субдоменов (<prefix>1..5,203)
DPI_BYPASS=""
NO_FAKE_TLS=0             # 1 = обычный MTProto (dd)
WS_KEEPALIVE="30"
NFQWS_OPTS="--dpi-desync=fake --dpi-desync-ttl=6 --dpi-desync-fooling=md5sig"  # zapret
LOG_LEVEL="info"          # info|warning|error|off - off/error = без логов подключений (IP/сессий)
WEB_PROXY=""              # 1 = WEB-прокси (t.me/webproxy, Telegram Desktop 7.1+)
WEB_HOST=""               # домен WEB-прокси, A-запись -> IP VPS (серое облако)
WEB_EMAIL=""              # e-mail для Let's Encrypt (необязательно)
WEB_BASE_PATH="auto"      # auto = случайный слаг (сохраняется при переустановке), none = корень
WEB_CARRIER="https"       # https|https-lanes|websocket|websocket-lanes
WEB_BACKEND_PORT="12398"  # локальный порт tg-ws-proxy для relay (127.0.0.1)
WEB_SITE_DIR=""           # свой статический сайт-обложка (с index.html)
WEB_SITE_UPSTREAM=""      # или свой локальный сайт http://127.0.0.1:PORT
WEB_RELAY_REF="c8adb8b7c6b7fc46c12ae3acb68be9070c26a8e8"  # коммит tproxy-server
ASSUME_YES=0
DO_UNINSTALL=0
# ============================================================

c_g(){ printf '\033[1;32m%s\033[0m\n' "$*"; }
c_y(){ printf '\033[1;33m%s\033[0m\n' "$*"; }
c_r(){ printf '\033[1;31m%s\033[0m\n' "$*" >&2; }
info(){ printf '  \033[1;36m›\033[0m %s\n' "$*"; }
die(){ c_r "ОШИБКА: $*"; exit 1; }

base_domain(){ awk -F. '{ if (NF>=2) print $(NF-1)"."$NF; else print $0 }' <<<"$1"; }
hexenc(){ printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }
# значение ключа из уже установленного конфига (для сохранения при переустановке)
old_conf(){ [[ -f "$CONF_FILE" ]] && grep -m1 "^$1=" "$CONF_FILE" | cut -d= -f2- || true; }
old_conf_has(){ [[ -f "$CONF_FILE" ]] && grep -q "^$1=" "$CONF_FILE"; }
svc_stop_rm(){ local u; for u in "$@"; do systemctl disable --now "$u" 2>/dev/null || true; rm -f "/etc/systemd/system/${u}"; done; }

usage(){ cat <<USAGE
mtproxy-ws-ins - установка MTProto-прокси (tg-ws-proxy + zapret) и WEB-прокси Telegram.

Одной строкой:
  curl -fsSL ${SELF_URL} | sudo bash
  curl -fsSL ${SELF_URL} | sudo bash -s -- --port 443 --server alt2.insage.ru --domain max.ru --cf-prefix node --dpi-bypass
  curl -fsSL ${SELF_URL} | sudo bash -s -- --port 8443 --web-proxy --web-host web.example.com

Флаги:
  --port N             порт MTProto (по умолч. 443; с --web-proxy нужен другой, напр. 8443)
  --server H           точка входа, server= в ссылке (серое облако -> VPS)
  --domain D           Fake-TLS/маскировка, живой сайт != точки входа (по умолч. max.ru)
  --secret HEX         32-hex сикрет (по умолч. генерируется)
  --cfproxy-domain D   база CfProxy для исходящего (по умолч. база от --domain)
  --no-cfproxy-domain  использовать авто-домены движка
  --builtin-cfproxy    встроенные CfProxy-домены (без своей зоны; синоним --no-cfproxy-domain)
  --cf-prefix P        префикс CfProxy-субдоменов (по умолч. kws)
  --ws-keepalive SEC   интервал WS keepalive-пингов к Telegram, 0=выкл (по умолч. 30)
  --dpi-opts "..."     опции nfqws для тюнинга под TSPU (см. README)
  --dpi-bypass | --no-dpi-bypass   слой TCPMSS=536 + nfqws fake
  --no-fake-tls        обычный MTProto (dd-сикрет, без TLS-маскировки и SNI)
  --log-level L        info|warning|error|off (off/error = без логов подключений)
  --quiet              синоним --log-level error

WEB-прокси (Telegram Desktop 7.1+, ссылка t.me/webproxy; занимает порты 80 и 443):
  --web-proxy | --no-web-proxy     включить/выключить WEB-прокси
  --web-host H         домен WEB-прокси (A-запись -> IP VPS, серое облако), обязателен
  --web-email E        e-mail для Let's Encrypt (необязательно)
  --web-base-path P    путь relay: слаг [A-Za-z0-9_-] или none = корень (по умолч. случайный)
  --web-carrier M      https|https-lanes|websocket|websocket-lanes (по умолч. https)
  --web-backend-port N локальный порт бэкенда на 127.0.0.1 (по умолч. 12398)
  --web-site-dir DIR   свой статический сайт-обложка (должен содержать index.html)
  --web-site-upstream URL  свой локальный сайт, http://127.0.0.1:PORT
  --web-relay-ref REF  коммит/тег telegramdesktop/tproxy-server (по умолч. закреплённый)

  --yes                без вопросов (для пайпа)
  --uninstall          удалить всё установленное
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)              PORT="${2:?}"; shift 2 ;;
    --port=*)            PORT="${1#*=}"; shift ;;
    --server)            SERVER="${2:?}"; shift 2 ;;
    --server=*)          SERVER="${1#*=}"; shift ;;
    --domain)            DOMAIN="${2:?}"; shift 2 ;;
    --domain=*)          DOMAIN="${1#*=}"; shift ;;
    --secret)            SECRET="${2:?}"; shift 2 ;;
    --secret=*)          SECRET="${1#*=}"; shift ;;
    --cfproxy-domain)    CFPROXY_DOMAIN="${2:?}"; shift 2 ;;
    --cfproxy-domain=*)  CFPROXY_DOMAIN="${1#*=}"; shift ;;
    --no-cfproxy-domain) CFPROXY_DISABLE=1; shift ;;
    --builtin-cfproxy)   CFPROXY_DISABLE=1; shift ;;
    --cf-prefix)         CF_PREFIX="${2:?}"; shift 2 ;;
    --cf-prefix=*)       CF_PREFIX="${1#*=}"; shift ;;
    --ws-keepalive)      WS_KEEPALIVE="${2:?}"; shift 2 ;;
    --ws-keepalive=*)    WS_KEEPALIVE="${1#*=}"; shift ;;
    --dpi-opts)          NFQWS_OPTS="${2:?}"; shift 2 ;;
    --dpi-opts=*)        NFQWS_OPTS="${1#*=}"; shift ;;
    --dpi-bypass)        DPI_BYPASS=1; shift ;;
    --no-dpi-bypass)     DPI_BYPASS=0; shift ;;
    --no-fake-tls)       NO_FAKE_TLS=1; shift ;;
    --log-level)         LOG_LEVEL="${2:?}"; shift 2 ;;
    --log-level=*)       LOG_LEVEL="${1#*=}"; shift ;;
    --quiet)             LOG_LEVEL="error"; shift ;;
    --web-proxy)         WEB_PROXY=1; shift ;;
    --no-web-proxy)      WEB_PROXY=0; shift ;;
    --web-host)          WEB_HOST="${2:?}"; shift 2 ;;
    --web-host=*)        WEB_HOST="${1#*=}"; shift ;;
    --web-email)         WEB_EMAIL="${2:?}"; shift 2 ;;
    --web-email=*)       WEB_EMAIL="${1#*=}"; shift ;;
    --web-base-path)     WEB_BASE_PATH="${2:?}"; shift 2 ;;
    --web-base-path=*)   WEB_BASE_PATH="${1#*=}"; shift ;;
    --web-carrier)       WEB_CARRIER="${2:?}"; shift 2 ;;
    --web-carrier=*)     WEB_CARRIER="${1#*=}"; shift ;;
    --web-backend-port)  WEB_BACKEND_PORT="${2:?}"; shift 2 ;;
    --web-backend-port=*) WEB_BACKEND_PORT="${1#*=}"; shift ;;
    --web-site-dir)      WEB_SITE_DIR="${2:?}"; shift 2 ;;
    --web-site-dir=*)    WEB_SITE_DIR="${1#*=}"; shift ;;
    --web-site-upstream) WEB_SITE_UPSTREAM="${2:?}"; shift 2 ;;
    --web-site-upstream=*) WEB_SITE_UPSTREAM="${1#*=}"; shift ;;
    --web-relay-ref)     WEB_RELAY_REF="${2:?}"; shift 2 ;;
    --web-relay-ref=*)   WEB_RELAY_REF="${1#*=}"; shift ;;
    --yes|-y)            ASSUME_YES=1; shift ;;
    --uninstall)         DO_UNINSTALL=1; shift ;;
    -h|--help)           usage; exit 0 ;;
    *)                   die "неизвестный аргумент: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "запускать от root (sudo)."

if [[ $DO_UNINSTALL -eq 1 ]]; then
  c_y "Удаление mtproxy-ws…"
  svc_stop_rm "$SVC_CADDY" "$SVC_RELAY" "$SVC_WEB_BACKEND" "$SVC_PROXY" "$SVC_NFQWS" "$SVC_IPT"
  systemctl daemon-reload
  # shellcheck source=/dev/null
  if [[ -f "$CONF_FILE" ]]; then . "$CONF_FILE" 2>/dev/null || true; fi
  iptables -t mangle -D OUTPUT -p tcp --sport "${PORT}" -j TCPMSS --set-mss "$MSS" 2>/dev/null || true
  iptables -t mangle -D OUTPUT -p tcp --sport "${PORT}" -m conntrack --ctstate ESTABLISHED -j NFQUEUE --queue-num "$QNUM" --queue-bypass 2>/dev/null || true
  rm -rf "$APP_DIR" "$CONF_DIR" "$WEB_DIR" "$CADDY_DATA"
  userdel "$RELAY_USER" 2>/dev/null || true
  userdel "$CADDY_USER" 2>/dev/null || true
  rm -f /usr/local/bin/mtproxy-ws
  rm -rf /usr/local/share/mtproxy-ws
  c_g "Готово. (Каталог $ZAPRET_DIR не трогаю — мог использоваться другими сервисами.)"
  exit 0
fi

RD=-1
PUBIP="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
[[ -z "$PUBIP" ]] && PUBIP="$(hostname -I 2>/dev/null | awk '{print $1}')"
if [[ $ASSUME_YES -eq 0 && $ORIG_ARGC -eq 0 ]]; then
  if [[ -t 0 ]]; then RD=0
  elif [[ -r /dev/tty ]]; then { exec 3</dev/tty 2>/dev/null && RD=3; } || RD=-1
  fi
fi
if [[ $RD -ge 0 ]]; then
  c_y "─── Настройка mtproxy-ws ───"
  info "Точка входа = IP этого VPS: ${PUBIP:-не определён} (переопределить: флаг --server)"

  read -rp "Порт MTProto [${PORT}]: " _v <&$RD || true; PORT="${_v:-$PORT}"

  read -rp "Использовать Fake-TLS маскировку (вход под видом HTTPS)? [Y/n]: " _v <&$RD || true
  case "${_v:-y}" in [Nn]*) NO_FAKE_TLS=1 ;; *) NO_FAKE_TLS=0 ;; esac
  if [[ "$NO_FAKE_TLS" -eq 0 ]]; then
    read -rp "  Домен Fake-TLS — живой HTTPS-сайт [${DOMAIN}]: " _v <&$RD || true
    DOMAIN="${_v:-$DOMAIN}"
  else
    info "Fake-TLS выключен -> обычный MTProto (dd-ссылка)"
  fi

  read -rp "Сикрет — 32 hex без dd/ee (пусто = сгенерировать): " _v <&$RD || true
  SECRET="${_v:-$SECRET}"

  read -rp "CfProxy: свой домен для node*-записей (пусто = встроенные домены движка): " _v <&$RD || true
  if [[ -n "$_v" ]]; then
    CFPROXY_DISABLE=0; CFPROXY_DOMAIN="$_v"
    read -rp "  Префикс CfProxy-субдоменов [${CF_PREFIX}]: " _v <&$RD || true
    CF_PREFIX="${_v:-$CF_PREFIX}"
  else
    CFPROXY_DISABLE=1; info "CfProxy: встроенные домены (своя зона/DNS не нужны)"
  fi

  if [[ -z "$DPI_BYPASS" ]]; then
    read -rp "Включить обход DPI/TSPU (TCPMSS=536 + nfqws)? [Y/n]: " _v <&$RD || true
    case "${_v:-y}" in [Nn]*) DPI_BYPASS=0 ;; *) DPI_BYPASS=1 ;; esac
  fi

  read -rp "Логировать подключения (IP клиентов, сессии, статистику)? [Y/n]: " _v <&$RD || true
  case "${_v:-y}" in [Nn]*) LOG_LEVEL="error" ;; *) LOG_LEVEL="info" ;; esac

  info "WEB-прокси: t.me/webproxy для Telegram Desktop 7.1+, трафик идёт как обычный HTTPS к твоему домену."
  info "Нужен домен с A-записью на этот VPS и свободные порты 80/443."
  read -rp "Включить WEB-прокси? [y/N]: " _v <&$RD || true
  case "${_v:-n}" in [Yy]*) WEB_PROXY=1 ;; *) WEB_PROXY=0 ;; esac
  if [[ "$WEB_PROXY" -eq 1 ]]; then
    _d="$(old_conf WEB_HOST)"
    read -rp "  Домен WEB-прокси (A-запись -> ${PUBIP:-IP VPS}, серое облако)${_d:+ [$_d]}: " _v <&$RD || true
    WEB_HOST="${_v:-$_d}"
    _d="$(old_conf WEB_EMAIL)"
    read -rp "  E-mail для Let's Encrypt (можно пусто)${_d:+ [$_d]}: " _v <&$RD || true
    WEB_EMAIL="${_v:-$_d}"
    if [[ "$PORT" == "443" ]]; then
      info "Порт 443 займёт WEB-прокси (Caddy) — MTProto нужен другой порт."
      read -rp "  Новый порт MTProto [8443]: " _v <&$RD || true; PORT="${_v:-8443}"
    fi
  fi
fi

[[ -z "$DPI_BYPASS" ]] && DPI_BYPASS=0
[[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )) || die "порт должен быть 1..65535"
[[ -n "$DOMAIN" ]] || die "домен Fake-TLS не задан"
[[ -z "$SERVER" ]] && SERVER="${PUBIP:-$DOMAIN}"
[[ "$CF_PREFIX" =~ ^[a-zA-Z][a-zA-Z0-9-]*$ ]] || die "cf-prefix: буквы/цифры/дефис, начинается с буквы"
LOG_LEVEL="$(printf '%s' "$LOG_LEVEL" | tr '[:upper:]' '[:lower:]')"
case "$LOG_LEVEL" in info|warning|error|off) ;; *) die "log-level: info|warning|error|off" ;; esac

if [[ $CFPROXY_DISABLE -eq 1 ]]; then
  CFPROXY_DOMAIN=""
elif [[ -z "$CFPROXY_DOMAIN" ]]; then
  CFPROXY_DOMAIN="$(base_domain "$DOMAIN")"
fi

if [[ -z "$SECRET" ]]; then
  SECRET="$(openssl rand -hex 16 2>/dev/null || head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
fi
[[ "${#SECRET}" -eq 32 && "$SECRET" =~ ^[0-9a-fA-F]+$ ]] || die "secret должен быть 32 hex-символа"
SECRET="$(printf '%s' "$SECRET" | tr '[:upper:]' '[:lower:]')"

DOMAIN_HEX="$(hexenc "$DOMAIN")"

[[ -z "$WEB_PROXY" ]] && WEB_PROXY=0
WEB_ARCH=""
if [[ "$WEB_PROXY" -eq 1 ]]; then
  WEB_HOST="$(printf '%s' "$WEB_HOST" | tr '[:upper:]' '[:lower:]')"
  [[ -n "$WEB_HOST" ]] || die "для WEB-прокси нужен домен: --web-host web.example.com"
  [[ "$WEB_HOST" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]*[a-z0-9]$ ]] \
    || die "web-host: нужен домен (не IP), например web.example.com"
  [[ "$PORT" != "443" ]] \
    || die "WEB-прокси занимает 443 (Caddy) — задай MTProto другой порт: --port 8443"
  [[ "$PORT" != "80" ]] || die "порт 80 нужен Caddy для выпуска сертификата — выбери другой --port"
  [[ "$WEB_BACKEND_PORT" =~ ^[0-9]+$ ]] && (( WEB_BACKEND_PORT >= 1 && WEB_BACKEND_PORT <= 65535 )) \
    || die "web-backend-port должен быть 1..65535"
  [[ "$WEB_BACKEND_PORT" != "$PORT" ]] || die "web-backend-port не должен совпадать с --port"
  for _p in 18080 18081; do
    [[ "$WEB_BACKEND_PORT" != "$_p" && "$PORT" != "$_p" ]] || die "порт ${_p} занят relay — выбери другой"
  done
  case "$WEB_CARRIER" in https|https-lanes|websocket|websocket-lanes) ;;
    *) die "web-carrier: https|https-lanes|websocket|websocket-lanes" ;; esac
  [[ -z "$WEB_EMAIL" || "$WEB_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] \
    || die "web-email: некорректный адрес"

  # base path: none = корень; auto = сохранить прежний или сгенерировать (как в upstream)
  if [[ "$WEB_BASE_PATH" == "none" ]]; then
    WEB_BASE_PATH=""
  elif [[ "$WEB_BASE_PATH" == "auto" ]]; then
    if old_conf_has WEB_BASE_PATH && [[ "$(old_conf WEB_HOST)" == "$WEB_HOST" ]]; then
      WEB_BASE_PATH="$(old_conf WEB_BASE_PATH)"
    else
      WEB_BASE_PATH="$(head -c 10 /dev/urandom | base32 | tr 'A-Z' 'a-z')"
    fi
  fi
  WEB_BASE_PATH="${WEB_BASE_PATH#/}"; WEB_BASE_PATH="${WEB_BASE_PATH%/}"
  if [[ -n "$WEB_BASE_PATH" ]]; then
    [[ ${#WEB_BASE_PATH} -le 128 && "$WEB_BASE_PATH" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*(/[A-Za-z0-9][A-Za-z0-9_-]*)*$ ]] \
      || die "web-base-path: сегменты [A-Za-z0-9][A-Za-z0-9_-]*, через /, до 128 символов (или none)"
  fi

  [[ -z "$WEB_SITE_DIR" || -z "$WEB_SITE_UPSTREAM" ]] || die "--web-site-dir и --web-site-upstream взаимоисключающие"
  if [[ -n "$WEB_SITE_DIR" ]]; then
    [[ -f "${WEB_SITE_DIR}/index.html" ]] || die "в ${WEB_SITE_DIR} нет index.html"
  fi
  if [[ -n "$WEB_SITE_UPSTREAM" ]]; then
    [[ "$WEB_SITE_UPSTREAM" =~ ^http://(127\.[0-9]+\.[0-9]+\.[0-9]+|\[::1\]):[1-9][0-9]{0,4}$ ]] \
      || die "web-site-upstream: только http://127.x.x.x:PORT или http://[::1]:PORT"
  elif [[ -z "$WEB_SITE_DIR" ]] && old_conf_has WEB_SITE_UPSTREAM && [[ -n "$(old_conf WEB_SITE_UPSTREAM)" ]]; then
    WEB_SITE_UPSTREAM="$(old_conf WEB_SITE_UPSTREAM)"
  fi
  [[ "$WEB_RELAY_REF" =~ ^[A-Za-z0-9._/-]+$ ]] || die "web-relay-ref: некорректная ссылка"

  case "$(uname -m)" in
    x86_64|amd64)  WEB_ARCH=amd64 ;;
    aarch64|arm64) WEB_ARCH=arm64 ;;
    *) die "WEB-прокси: архитектура $(uname -m) не поддерживается (нужна amd64/arm64)" ;;
  esac

  # 80/443 должны быть свободны (кроме наших же сервисов, которые перезапустятся)
  port_busy_foreign(){
    local out u p
    out="$(ss -Hltnp "sport = :$1" 2>/dev/null || true)"
    [[ -z "$out" ]] && return 1
    for u in "$SVC_PROXY" "$SVC_CADDY"; do
      p="$(systemctl show -p MainPID --value "$u" 2>/dev/null || echo 0)"
      [[ "$p" =~ ^[1-9][0-9]*$ ]] && out="$(grep -v "pid=${p}," <<<"$out" || true)"
    done
    [[ -n "$out" ]]
  }
  for _p in 80 443; do
    if port_busy_foreign "$_p"; then
      ss -Hltnp "sport = :${_p}" 2>/dev/null | sed 's/^/    /' >&2 || true
      die "порт ${_p} занят другим сервисом (nginx/apache/caddy?). WEB-прокси нужны 80 и 443."
    fi
  done

  WEB_DNS_IP="$(getent ahostsv4 "$WEB_HOST" 2>/dev/null | awk '{print $1; exit}' || true)"
  if [[ -z "$WEB_DNS_IP" ]]; then
    c_y "  ⚠  ${WEB_HOST} не резолвится. Создай A-запись -> ${PUBIP:-IP VPS}, иначе сертификат не выпустится."
  elif [[ -n "$PUBIP" && "$WEB_DNS_IP" != "$PUBIP" ]]; then
    c_y "  ⚠  ${WEB_HOST} -> ${WEB_DNS_IP}, а IP VPS ${PUBIP}. Нужна A-запись на VPS и серое облако (без CDN)."
  fi
fi

OLD_PORT="$(old_conf PORT)"

c_y "[1/7] Системные пакеты…"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git python3 python3-venv python3-pip openssl curl iproute2 >/dev/null
[[ "$WEB_PROXY" -eq 1 ]] && apt-get install -y -qq ca-certificates tar coreutils >/dev/null
info "python: $(python3 --version 2>&1)"

c_y "[2/7] Движок tg-ws-proxy…"
if [[ -d "${APP_DIR}/.git" ]]; then
  git -C "$APP_DIR" remote set-url origin "$REPO_URL" 2>/dev/null || true
  git -C "$APP_DIR" fetch --depth 1 origin "$REPO_REF" -q && git -C "$APP_DIR" reset --hard FETCH_HEAD -q
else
  rm -rf "$APP_DIR"; git clone --depth 1 --branch "$REPO_REF" -q "$REPO_URL" "$APP_DIR" \
    || { rm -rf "$APP_DIR"; git clone --depth 1 -q "$REPO_URL" "$APP_DIR" && git -C "$APP_DIR" checkout -q "$REPO_REF"; }
fi

if [[ "$CF_PREFIX" != "kws" ]]; then
  sed -i "s|f'kws{dc}\.{base_domain}'|f'${CF_PREFIX}{dc}.{base_domain}'|" "$BRIDGE_PY"
  grep -q "f'${CF_PREFIX}{dc}.{base_domain}'" "$BRIDGE_PY" \
    || die "не удалось пропатчить префикс CfProxy в bridge.py"
  info "CfProxy-префикс пропатчен: ${CF_PREFIX}{dc}.<домен>"
fi

# патч уровня логов: читать MTPROXY_LOG_LEVEL из окружения (для --log-level/--quiet)
if python3 - "$APP_DIR" <<'PYEOF'
import sys, ast, os
p = os.path.join(sys.argv[1], 'proxy/tg_ws_proxy.py')
s = open(p, encoding='utf-8').read()
if 'MTPROXY_LOG_LEVEL' not in s:
    find = '    log_level = logging.DEBUG if args.verbose else logging.INFO'
    repl = ("    log_level = logging.DEBUG if args.verbose else getattr(\n"
            "        logging, os.environ.get('MTPROXY_LOG_LEVEL', 'INFO').upper(), logging.INFO)")
    if find not in s:
        print("log-anchor-miss", file=sys.stderr); sys.exit(1)
    s = s.replace(find, repl, 1)
    ast.parse(s)
    open(p, 'w', encoding='utf-8').write(s)
PYEOF
then
  info "лог-уровень управляем через конфиг (LOG_LEVEL=${LOG_LEVEL})"
else
  c_y "  ⚠  патч лог-уровня не применился — LOG_LEVEL может не действовать"
fi

python3 -m venv "$VENV_DIR"
"${VENV_DIR}/bin/pip" install -q --upgrade pip >/dev/null
# зависимости серверной части движка (как в Dockerfile форка; GUI-пакеты не нужны)
"${VENV_DIR}/bin/pip" install -q --upgrade cryptography certifi "httpx[http2]==0.28.1" >/dev/null \
  || die "pip не смог поставить зависимости движка"
( cd "$APP_DIR" && "${VENV_DIR}/bin/python" -c 'import proxy.tg_ws_proxy' ) \
  || die "движок не импортируется — см. ошибку выше (не хватает Python-зависимости?)"
info "движок: ${APP_DIR}"

# --ws-keepalive есть не во всех версиях форка — передаём только если движок его знает
KEEPALIVE_OK=0
ENGINE_HELP="$( cd "$APP_DIR" && "${VENV_DIR}/bin/python" -m proxy.tg_ws_proxy --help 2>/dev/null || true )"
if [[ "$ENGINE_HELP" == *"--ws-keepalive"* ]]; then
  KEEPALIVE_OK=1
elif [[ "$WS_KEEPALIVE" != "0" ]]; then
  c_y "  ⚠  движок не поддерживает --ws-keepalive — опция пропущена"
fi

c_y "[3/7] Конфигурация…"
mkdir -p "$CONF_DIR"
cat > "$CONF_FILE" <<EOF
# mtproxy-ws — конфигурация прокси
PORT=${PORT}
SERVER=${SERVER}
DOMAIN=${DOMAIN}
SECRET=${SECRET}
CFPROXY_DOMAIN=${CFPROXY_DOMAIN}
CF_PREFIX=${CF_PREFIX}
DPI_BYPASS=${DPI_BYPASS}
NO_FAKE_TLS=${NO_FAKE_TLS}
LOG_LEVEL=${LOG_LEVEL}
WS_KEEPALIVE=${WS_KEEPALIVE}
KEEPALIVE_OK=${KEEPALIVE_OK}
NFQWS_OPTS='${NFQWS_OPTS}'
QNUM=${QNUM}
MSS=${MSS}
# WEB-прокси (t.me/webproxy); WEB_BASE_PATH пусто = корень
WEB_PROXY=${WEB_PROXY}
WEB_HOST=${WEB_HOST}
WEB_EMAIL=${WEB_EMAIL}
WEB_BASE_PATH=${WEB_BASE_PATH}
WEB_CARRIER=${WEB_CARRIER}
WEB_BACKEND_PORT=${WEB_BACKEND_PORT}
WEB_SITE_UPSTREAM=${WEB_SITE_UPSTREAM}
EOF
chmod 600 "$CONF_FILE"

CF_ARG=""
[[ -n "$CFPROXY_DOMAIN" ]] && CF_ARG="--cfproxy-domain \"${CFPROXY_DOMAIN}\""
KA_ARG=""
[[ "$KEEPALIVE_OK" -eq 1 ]] && KA_ARG="--ws-keepalive \"\${WS_KEEPALIVE}\""
# run-server.sh        — публичный MTProto на 0.0.0.0:PORT (Fake-TLS по конфигу)
# run-server.sh web    — бэкенд WEB-прокси на 127.0.0.1:WEB_BACKEND_PORT, всегда без Fake-TLS:
#                        relay передаёт байты obfuscated2 как есть, TLS снимает Caddy
cat > "$RUN_WRAPPER" <<EOF
#!/usr/bin/env bash
set -euo pipefail
source "${CONF_FILE}"
case "\${LOG_LEVEL:-info}" in
  warning) export MTPROXY_LOG_LEVEL=WARNING ;;
  error)   export MTPROXY_LOG_LEVEL=ERROR ;;
  off)     export MTPROXY_LOG_LEVEL=CRITICAL ;;
  *)       export MTPROXY_LOG_LEVEL=INFO ;;
esac
HOST=0.0.0.0; LPORT="\${PORT}"; LOG=/var/log/mtproxy-ws.log
FT=()
[[ "\${NO_FAKE_TLS:-0}" == "1" ]] || FT=(--fake-tls-domain "\${DOMAIN}")
if [[ "\${1:-}" == "web" ]]; then
  HOST=127.0.0.1; LPORT="\${WEB_BACKEND_PORT:-12398}"; LOG=/var/log/mtproxy-ws-web.log; FT=()
fi
exec "${VENV_DIR}/bin/python" -m proxy.tg_ws_proxy \\
  --host "\${HOST}" \\
  --port "\${LPORT}" \\
  --secret "\${SECRET}" \\
  \${FT[@]+"\${FT[@]}"} \\
  ${CF_ARG} \\
  ${KA_ARG} \\
  --log-file "\${LOG}" \\
  --log-max-mb 5 --log-backups 1
EOF
chmod +x "$RUN_WRAPPER"

c_y "[4/7] systemd-сервис прокси…"
cat > "/etc/systemd/system/${SVC_PROXY}" <<EOF
[Unit]
Description=MTProto WS Proxy (tg-ws-proxy, Fake-TLS ${DOMAIN})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${APP_DIR}
ExecStart=${RUN_WRAPPER}
Restart=always
RestartSec=3
LimitNOFILE=65535
TasksMax=65535
NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

# команда-менеджер mtproxy-ws + копия установщика для `update`
mkdir -p /usr/local/share/mtproxy-ws
if [[ -f "${BASH_SOURCE[0]:-}" ]] && head -1 "${BASH_SOURCE[0]}" 2>/dev/null | grep -q bash; then
  cp "${BASH_SOURCE[0]}" /usr/local/share/mtproxy-ws/install.sh 2>/dev/null || true
fi
# запущено через bash <(curl ...) — файла нет, докачаем для будущего `mtproxy-ws update`
[[ -f /usr/local/share/mtproxy-ws/install.sh ]] || \
  curl -fsSL "$SELF_URL" -o /usr/local/share/mtproxy-ws/install.sh 2>/dev/null || true
cat > /usr/local/bin/mtproxy-ws <<'MGR'
#!/usr/bin/env bash
set -euo pipefail
CONF=/etc/mtproxy-ws/proxy.conf
SVC=mtproxy-ws.service
SVC_NFQWS=mtproxy-ws-nfqws.service
SVC_IPT=mtproxy-ws-iptables.service
SVC_WEB_BACKEND=mtproxy-ws-web-backend.service
SVC_RELAY=mtproxy-ws-relay.service
SVC_CADDY=mtproxy-ws-caddy.service
WEB_PROFILES=/etc/mtproxy-ws/web/profiles.json
INSTALLER=/usr/local/share/mtproxy-ws/install.sh
[[ $EUID -eq 0 ]] || { echo "нужен root (sudo mtproxy-ws ...)"; exit 1; }
[[ -f $CONF ]] || { echo "конфиг $CONF не найден — прокси не установлен"; exit 1; }
# shellcheck source=/dev/null
source "$CONF"

UNITS=("$SVC")
systemctl list-unit-files --no-legend 2>/dev/null | grep -q "^${SVC_NFQWS}" && UNITS+=("$SVC_NFQWS" "$SVC_IPT")
[[ "${WEB_PROXY:-0}" == "1" ]] && UNITS+=("$SVC_WEB_BACKEND" "$SVC_RELAY" "$SVC_CADDY")

hexenc(){ printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }
build_link(){
  local sec
  if [[ "${NO_FAKE_TLS:-0}" == "1" ]]; then sec="dd${SECRET}"
  else sec="ee${SECRET}$(hexenc "$DOMAIN")"; fi
  echo "tg://proxy?server=${SERVER}&port=${PORT}&secret=${sec}"
  echo "https://t.me/proxy?server=${SERVER}&port=${PORT}&secret=${sec}"
}
# Сикрет WEB-ссылки: в корне — обычный hex; с base path — base64url(0x70 || secret),
# чтобы клиент без поддержки base path попросил обновиться, а не стучался в корень.
web_secret(){
  if [[ -z "${WEB_BASE_PATH:-}" ]]; then printf %s "$SECRET"; return; fi
  # shellcheck disable=SC2059
  { printf '\x70'; printf "$(printf %s "$SECRET" | sed 's/../\\x&/g')"; } \
    | base64 | tr '+/' '-_' | tr -d '=\n'
}
web_server(){ if [[ -n "${WEB_BASE_PATH:-}" ]]; then printf %s "${WEB_HOST}/${WEB_BASE_PATH}"; else printf %s "$WEB_HOST"; fi; }
build_weblink(){
  local srv sec
  srv="$(web_server)"; srv="${srv//\//%2F}"; sec="$(web_secret)"
  echo "tg://webproxy?server=${srv}&secret=${sec}"
  echo "https://t.me/webproxy?server=${srv}&secret=${sec}"
}
web_on(){ [[ "${WEB_PROXY:-0}" == "1" ]] || { echo "WEB-прокси не включён (mtproxy-ws update после установки с --web-proxy)"; exit 1; }; }
write_profiles(){
  local tmp
  tmp="$(mktemp "${WEB_PROFILES}.XXXXXX")"
  printf '{"profiles":[{"name":"default","secret":"%s","backend":"127.0.0.1:%s","carrier_mode":"%s"}]}\n' \
    "$SECRET" "${WEB_BACKEND_PORT:-12398}" "${WEB_CARRIER:-https}" > "$tmp"
  chown root:root "$tmp"; chmod 0400 "$tmp"; mv -f "$tmp" "$WEB_PROFILES"
}

case "${1:-status}" in
  status)  systemctl status "${UNITS[@]}" --no-pager || true
           echo; journalctl -u "$SVC" -n 1 --no-pager | grep -i stats || true
           if [[ "${WEB_PROXY:-0}" == "1" ]]; then
             printf 'WEB relay readyz: '; curl -fsS --max-time 3 http://127.0.0.1:18081/readyz 2>/dev/null || echo "НЕ готов"
             echo
           fi ;;
  start)   systemctl start   "${UNITS[@]}"; echo "запущено" ;;
  stop)    systemctl stop    "${UNITS[@]}"; echo "остановлено" ;;
  restart) systemctl restart "${UNITS[@]}"; echo "перезапущено" ;;
  link)    build_link
           if [[ "${WEB_PROXY:-0}" == "1" ]]; then
             echo; echo "WEB-прокси (Telegram Desktop 7.1+):"; build_weblink
           fi ;;
  weblink) web_on; build_weblink ;;
  webinfo) web_on
           echo "Сервер: $(web_server)"; echo "Сикрет: $(web_secret)"; build_weblink ;;
  qr)      command -v qrencode >/dev/null || { echo "поставь qrencode: apt install -y qrencode"; exit 1; }
           if [[ "${2:-}" == "web" ]]; then web_on; build_weblink | tail -1 | qrencode -t ANSIUTF8
           else build_link | head -1 | qrencode -t ANSIUTF8; fi ;;
  logs)    shift
           if [[ "${1:-}" == "web" ]]; then shift; journalctl -u "$SVC_WEB_BACKEND" -u "$SVC_RELAY" -u "$SVC_CADDY" -f "$@"
           else journalctl -u "$SVC" -f "$@"; fi ;;
  edit)    "${EDITOR:-nano}" "$CONF"
           # shellcheck source=/dev/null
           source "$CONF"
           [[ "${WEB_PROXY:-0}" == "1" && -f "$WEB_PROFILES" ]] && write_profiles
           systemctl restart "${UNITS[@]}"; echo "сохранено, перезапущено"
           echo "(смена PORT/WEB_HOST/DPI применяется полностью только через: mtproxy-ws update)" ;;
  rotate)
    NEW="$(openssl rand -hex 16)"
    sed -i "s/^SECRET=.*/SECRET=${NEW}/" "$CONF"
    SECRET="$NEW"
    if [[ "${WEB_PROXY:-0}" == "1" ]]; then
      write_profiles; systemctl restart "$SVC" "$SVC_WEB_BACKEND" "$SVC_RELAY"
    else
      systemctl restart "$SVC"
    fi
    echo "Новый сикрет: $NEW"
    echo "Новая ссылка (старая больше НЕ работает):"; build_link
    if [[ "${WEB_PROXY:-0}" == "1" ]]; then echo "Новая WEB-ссылка:"; build_weblink; fi ;;
  update)
    [[ -f "$INSTALLER" ]] || { echo "сохранённый install.sh не найден — переустанови вручную"; exit 1; }
    a=(--yes --secret "$SECRET" --port "$PORT" --server "$SERVER" --cf-prefix "$CF_PREFIX"
       --ws-keepalive "$WS_KEEPALIVE" --log-level "${LOG_LEVEL:-info}" --dpi-opts "$NFQWS_OPTS")
    [[ "${NO_FAKE_TLS:-0}" == "1" ]] && a+=(--no-fake-tls) || a+=(--domain "$DOMAIN")
    [[ -n "${CFPROXY_DOMAIN:-}" ]] && a+=(--cfproxy-domain "$CFPROXY_DOMAIN") || a+=(--builtin-cfproxy)
    [[ "${DPI_BYPASS:-0}" == "1" ]] && a+=(--dpi-bypass) || a+=(--no-dpi-bypass)
    if [[ "${WEB_PROXY:-0}" == "1" ]]; then
      a+=(--web-proxy --web-host "$WEB_HOST" --web-base-path "${WEB_BASE_PATH:-none}"
          --web-carrier "${WEB_CARRIER:-https}" --web-backend-port "${WEB_BACKEND_PORT:-12398}")
      [[ -n "${WEB_EMAIL:-}" ]] && a+=(--web-email "$WEB_EMAIL")
      [[ -n "${WEB_SITE_UPSTREAM:-}" ]] && a+=(--web-site-upstream "$WEB_SITE_UPSTREAM")
    else
      a+=(--no-web-proxy)
    fi
    bash "$INSTALLER" "${a[@]}" ;;
  *) echo "mtproxy-ws {status|start|stop|restart|link|weblink|webinfo|qr [web]|logs [web]|edit|rotate|update}"; exit 1 ;;
esac
MGR
chmod +x /usr/local/bin/mtproxy-ws

c_y "[5/7] Слой обхода DPI/TSPU…"
# сменили порт — снять правила со старого (иначе MSS=536/nfqws повиснут, например, на 443 Caddy)
if [[ -n "$OLD_PORT" && "$OLD_PORT" != "$PORT" ]]; then
  iptables -t mangle -D OUTPUT -p tcp --sport "${OLD_PORT}" -j TCPMSS --set-mss "$MSS" 2>/dev/null || true
  iptables -t mangle -D OUTPUT -p tcp --sport "${OLD_PORT}" -m conntrack --ctstate ESTABLISHED -j NFQUEUE --queue-num "$QNUM" --queue-bypass 2>/dev/null || true
fi
if [[ "$DPI_BYPASS" -eq 1 ]]; then
  apt-get install -y -qq build-essential libnetfilter-queue-dev libcap-dev libmnl-dev zlib1g-dev iptables >/dev/null
  if [[ ! -x "${ZAPRET_DIR}/nfq/nfqws" ]]; then
    [[ -d "${ZAPRET_DIR}/.git" ]] || git clone --depth 1 -q "$ZAPRET_URL" "$ZAPRET_DIR"
    make -C "${ZAPRET_DIR}/nfq" -j"$(nproc)" >/dev/null 2>&1 || die "не удалось собрать nfqws"
  fi
  iptables -t mangle -C OUTPUT -p tcp --sport "${PORT}" -j TCPMSS --set-mss "$MSS" 2>/dev/null \
    || iptables -t mangle -A OUTPUT -p tcp --sport "${PORT}" -j TCPMSS --set-mss "$MSS"
  iptables -t mangle -C OUTPUT -p tcp --sport "${PORT}" -m conntrack --ctstate ESTABLISHED -j NFQUEUE --queue-num "$QNUM" --queue-bypass 2>/dev/null \
    || iptables -t mangle -A OUTPUT -p tcp --sport "${PORT}" -m conntrack --ctstate ESTABLISHED -j NFQUEUE --queue-num "$QNUM" --queue-bypass
  iptables-save > "$IPT_RULES"

  cat > "/etc/systemd/system/${SVC_NFQWS}" <<EOF
[Unit]
Description=mtproxy-ws nfqws TCP desync (zapret, queue ${QNUM})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${ZAPRET_DIR}/nfq/nfqws --qnum=${QNUM} ${NFQWS_OPTS}
Restart=always
RestartSec=3
NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

  cat > "/etc/systemd/system/${SVC_IPT}" <<EOF
[Unit]
Description=mtproxy-ws restore iptables rules
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore ${IPT_RULES}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
  info "anti-DPI: TCPMSS=${MSS}, nfqws fake на sport ${PORT}, queue ${QNUM}"
else
  svc_stop_rm "$SVC_NFQWS" "$SVC_IPT"
  iptables -t mangle -D OUTPUT -p tcp --sport "${PORT}" -j TCPMSS --set-mss "$MSS" 2>/dev/null || true
  iptables -t mangle -D OUTPUT -p tcp --sport "${PORT}" -m conntrack --ctstate ESTABLISHED -j NFQUEUE --queue-num "$QNUM" --queue-bypass 2>/dev/null || true
  info "anti-DPI: выключен"
fi

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
  info "ufw: открыт ${PORT}/tcp"
  if [[ "$WEB_PROXY" -eq 1 ]]; then
    ufw allow 80/tcp >/dev/null 2>&1 || true
    ufw allow 443/tcp >/dev/null 2>&1 || true
    info "ufw: открыты 80/tcp, 443/tcp (WEB-прокси)"
  fi
fi

# ---------- WEB-прокси ----------
# сайт-обложка: на хосте relay должен жить «свой» сайт; одинаковый шаблон у всех = сигнатура,
# поэтому генерируем случайный (заголовок, цвета, тексты). Свой сайт: --web-site-dir/--web-site-upstream.
gen_site(){
  local dir="$1" a n t hue y p1 p2 p3
  local adj=(Тихая Северная Светлая Летняя Дальняя Зелёная Старая Новая Ясная Вечерняя Утренняя Морская)
  local noun=(мастерская заметка пристань гавань полка тропа веранда комната студия лаборатория библиотека)
  local par=(
    "Здесь мы собираем заметки о проектах, которые делаем по вечерам и в выходные."
    "Раз в месяц обновляем список прочитанных книг и короткие рецензии на них."
    "Фотографии из поездок постепенно переезжают сюда из старого архива."
    "Если вы нашли ошибку в материалах — напишите нам, мы обязательно поправим."
    "Страница обновляется нерегулярно: мы пишем, когда есть что рассказать."
    "Большая часть текстов — черновики, которые со временем превращаются в статьи."
    "Небольшая коллекция рецептов, проверенных на друзьях и родственниках."
    "Мы любим простые вещи: хорошую бумагу, крепкий чай и долгие прогулки."
  )
  a="${adj[RANDOM % ${#adj[@]}]}"; n="${noun[RANDOM % ${#noun[@]}]}"; t="${a} ${n}"
  hue=$((RANDOM % 360)); y=$((2019 + RANDOM % 7))
  p1="${par[RANDOM % ${#par[@]}]}"; p2="${par[RANDOM % ${#par[@]}]}"; p3="${par[RANDOM % ${#par[@]}]}"
  mkdir -p "$dir"
  cat > "${dir}/index.html" <<HTML
<!doctype html>
<html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${t}</title>
<style>
body{margin:0;font:17px/1.6 Georgia,serif;background:hsl(${hue},30%,96%);color:hsl(${hue},25%,18%)}
main{max-width:$((600 + RANDOM % 120))px;margin:0 auto;padding:48px 20px}
h1{font-weight:normal;border-bottom:2px solid hsl(${hue},45%,55%);padding-bottom:8px}
footer{margin-top:48px;font-size:14px;opacity:.7}
</style></head><body><main>
<h1>${t}</h1>
<p>${p1}</p>
<p>${p2}</p>
<p>${p3}</p>
<footer>© ${y}–$(date +%Y) ${t}</footer>
</main></body></html>
HTML
  cat > "${dir}/404.html" <<HTML
<!doctype html>
<html lang="ru"><head><meta charset="utf-8"><title>Не найдено — ${t}</title></head>
<body style="font:17px Georgia,serif;background:hsl(${hue},30%,96%);text-align:center;padding:80px 20px">
<h1>404</h1><p>Такой страницы нет. <a href="/">На главную</a></p></body></html>
HTML
  printf 'User-agent: *\nDisallow:\n' > "${dir}/robots.txt"
}

install_web(){
  local arch="$WEB_ARCH" tmp gobin="" relay_bin="${WEB_DIR}/bin/tproxy-server" caddy_bin="${WEB_DIR}/bin/caddy"
  local sha want public_src
  mkdir -p "${WEB_DIR}/bin"
  tmp="$(mktemp -d /var/tmp/mtproxy-ws-web.XXXXXX)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT

  # --- relay tproxy-server (сборка из исходников закреплённого коммита) ---
  if [[ -x "$relay_bin" && "$(cat "${WEB_DIR}/.built-ref" 2>/dev/null)" == "$WEB_RELAY_REF" ]]; then
    info "relay tproxy-server уже собран (${WEB_RELAY_REF:0:12})"
  else
    if command -v go >/dev/null 2>&1; then
      local gv; gv="$(go env GOVERSION 2>/dev/null || true)"; gv="${gv#go}"
      local gmaj="${gv%%.*}" gmin="${gv#*.}"; gmin="${gmin%%[!0-9]*}"
      if [[ "$gmaj" =~ ^[0-9]+$ && -n "$gmin" ]] && { (( gmaj > 1 )) || (( gmin >= 20 )); }; then
        gobin="$(command -v go)"
      fi
    fi
    if [[ -z "$gobin" ]]; then
      info "ставлю временный Go ${GO_VER} (только для сборки)…"
      local gsha_var="GO_SHA256_${arch}"
      curl -fsSL --proto '=https' --tlsv1.2 -o "${tmp}/go.tgz" "https://dl.google.com/go/go${GO_VER}.linux-${arch}.tar.gz" \
        || die "не удалось скачать Go"
      sha="$(sha256sum "${tmp}/go.tgz" | awk '{print $1}')"
      [[ "$sha" == "${!gsha_var}" ]] || die "контрольная сумма Go не совпала"
      tar -C "$tmp" -xzf "${tmp}/go.tgz"; gobin="${tmp}/go/bin/go"
    fi
    info "скачиваю ${RELAY_REPO}@${WEB_RELAY_REF:0:12}…"
    mkdir -p "${tmp}/src"
    curl -fsSL --proto '=https' --tlsv1.2 -o "${tmp}/relay.tgz" "https://codeload.github.com/${RELAY_REPO}/tar.gz/${WEB_RELAY_REF}" \
      || die "не удалось скачать tproxy-server"
    tar -C "${tmp}/src" --strip-components=1 -xzf "${tmp}/relay.tgz"
    info "собираю relay…"
    ( cd "${tmp}/src" && env CGO_ENABLED=0 GOTOOLCHAIN=local GOFLAGS=-modcacherw \
        GOPATH="${tmp}/gopath" GOCACHE="${tmp}/gocache" HOME="$tmp" \
        "$gobin" build -trimpath -ldflags='-s -w' -o "${tmp}/tproxy-server" ./cmd/tproxy-server ) \
      || die "не удалось собрать tproxy-server"
    install -m 0755 "${tmp}/tproxy-server" "$relay_bin"
    printf '%s\n' "$WEB_RELAY_REF" > "${WEB_DIR}/.built-ref"
    info "relay: ${relay_bin}"
  fi

  # --- Caddy (официальный релиз, sha512 закреплён) ---
  if [[ -x "$caddy_bin" ]] && "$caddy_bin" version 2>/dev/null | grep -q "^v${CADDY_VER} "; then
    info "Caddy ${CADDY_VER} уже установлен"
  else
    local csha_var="CADDY_SHA512_${arch}"
    curl -fsSL --proto '=https' --proto-redir '=https' --tlsv1.2 -o "${tmp}/caddy.tgz" \
      "https://github.com/caddyserver/caddy/releases/download/v${CADDY_VER}/caddy_${CADDY_VER}_linux_${arch}.tar.gz" \
      || die "не удалось скачать Caddy"
    sha="$(sha512sum "${tmp}/caddy.tgz" | awk '{print $1}')"
    [[ "$sha" == "${!csha_var}" ]] || die "контрольная сумма Caddy не совпала"
    mkdir -p "${tmp}/caddy"; tar -C "${tmp}/caddy" -xzf "${tmp}/caddy.tgz" caddy
    install -m 0755 "${tmp}/caddy/caddy" "$caddy_bin"
    info "Caddy ${CADDY_VER}: ${caddy_bin}"
  fi
  rm -rf "$tmp"; trap - EXIT

  # --- пользователи ---
  id -u "$RELAY_USER" >/dev/null 2>&1 || useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin "$RELAY_USER"
  id -u "$CADDY_USER" >/dev/null 2>&1 || useradd --system --no-create-home --home-dir "$CADDY_DATA" --shell /usr/sbin/nologin "$CADDY_USER"
  install -d -o "$CADDY_USER" -g "$CADDY_USER" -m 0700 "$CADDY_DATA"

  # --- сайт-обложка ---
  if [[ -n "$WEB_SITE_UPSTREAM" ]]; then
    public_src="  \"public_upstream\": \"${WEB_SITE_UPSTREAM}\","
    info "сайт-обложка: ${WEB_SITE_UPSTREAM}"
  else
    if [[ -n "$WEB_SITE_DIR" ]]; then
      rm -rf "${WEB_DIR}/site.new"; mkdir -p "${WEB_DIR}/site.new"
      cp -a "${WEB_SITE_DIR}/." "${WEB_DIR}/site.new/"
      rm -rf "${WEB_DIR}/site"; mv "${WEB_DIR}/site.new" "${WEB_DIR}/site"
      info "сайт-обложка: скопирован из ${WEB_SITE_DIR}"
    elif [[ ! -f "${WEB_DIR}/site/index.html" ]]; then
      gen_site "${WEB_DIR}/site"
      info "сайт-обложка: сгенерирован (${WEB_DIR}/site — можно заменить своим)"
    else
      info "сайт-обложка: оставлен прежний (${WEB_DIR}/site)"
    fi
    chown -R root:root "${WEB_DIR}/site"; chmod -R u=rwX,go=rX "${WEB_DIR}/site"
    public_src="  \"public_dir\": \"${WEB_DIR}/site\","
  fi

  # --- конфиг relay ---
  install -d -o root -g "$RELAY_USER" -m 0750 "$WEB_CONF_DIR"
  local key="${WEB_CONF_DIR}/token.key"
  if [[ ! -f "$key" || "$(wc -c < "$key")" -ne 32 ]]; then
    rm -f "$key"; ( umask 077; head -c 32 /dev/urandom > "$key" )
  fi
  chown "$RELAY_USER:$RELAY_USER" "$key"; chmod 0400 "$key"
  cat > "${WEB_CONF_DIR}/config.json" <<EOF
{
  "public_hostname": "${WEB_HOST}",
  "base_path": "${WEB_BASE_PATH}",
  "listen": "${RELAY_LISTEN}",
  "admin_listen": "${RELAY_ADMIN}",
${public_src}
  "static_routes": "exact",
  "token_key_file": "${key}",
  "profiles_file": "/run/credentials/${SVC_RELAY}/profiles.json"
}
EOF
  chown "root:$RELAY_USER" "${WEB_CONF_DIR}/config.json"; chmod 0640 "${WEB_CONF_DIR}/config.json"
  ( umask 077
    printf '{"profiles":[{"name":"default","secret":"%s","backend":"127.0.0.1:%s","carrier_mode":"%s"}]}\n' \
      "$SECRET" "$WEB_BACKEND_PORT" "$WEB_CARRIER" > "${WEB_CONF_DIR}/profiles.json" )
  chown root:root "${WEB_CONF_DIR}/profiles.json"; chmod 0400 "${WEB_CONF_DIR}/profiles.json"
  "$relay_bin" -config "${WEB_CONF_DIR}/config.json" -profiles-file "${WEB_CONF_DIR}/profiles.json" -check \
    || die "tproxy-server отклонил конфиг (${WEB_CONF_DIR}/config.json)"

  # --- Caddyfile (по образцу deploy/Caddyfile из tproxy-server) ---
  install -d -o root -g "$CADDY_USER" -m 0750 "$CADDY_CONF_DIR"
  {
    echo "{"
    [[ -n "$WEB_EMAIL" ]] && echo "	email ${WEB_EMAIL}"
    cat <<EOF
	admin off
	servers {
		protocols h1 h2
		# read_body должен быть заметно больше long_poll relay (25s)
		timeouts {
			read_header 10s
			read_body 60s
		}
	}
}

${WEB_HOST} {
	# все пути — в relay: сайт, bridge-страница и API отвечают одним стеком
	encode zstd gzip
	header {
		-Via
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
	}
	reverse_proxy ${RELAY_LISTEN} {
		transport http {
			response_header_timeout 40s
		}
	}
	handle_errors {
		header {
			Cache-Control "no-store"
			Strict-Transport-Security "max-age=31536000; includeSubDomains"
		}
		respond "{http.error.status_code} {http.error.status_text}" {http.error.status_code}
	}
}
EOF
  } > "${CADDY_CONF_DIR}/Caddyfile"
  chown "root:$CADDY_USER" "${CADDY_CONF_DIR}/Caddyfile"; chmod 0640 "${CADDY_CONF_DIR}/Caddyfile"
  "$caddy_bin" validate --config "${CADDY_CONF_DIR}/Caddyfile" --adapter caddyfile >/dev/null 2>&1 \
    || die "Caddyfile не прошёл проверку (${CADDY_CONF_DIR}/Caddyfile)"

  # --- systemd ---
  cat > "/etc/systemd/system/${SVC_WEB_BACKEND}" <<EOF
[Unit]
Description=mtproxy-ws WEB backend (tg-ws-proxy on 127.0.0.1:${WEB_BACKEND_PORT}, no Fake-TLS)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${APP_DIR}
ExecStart=${RUN_WRAPPER} web
Restart=always
RestartSec=3
LimitNOFILE=65535
TasksMax=65535
NoNewPrivileges=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF

  cat > "/etc/systemd/system/${SVC_RELAY}" <<EOF
[Unit]
Description=mtproxy-ws WEB relay (telegramdesktop/tproxy-server)
After=network-online.target ${SVC_WEB_BACKEND}
Wants=network-online.target ${SVC_WEB_BACKEND}

[Service]
Type=simple
User=${RELAY_USER}
Group=${RELAY_USER}
LoadCredential=profiles.json:${WEB_CONF_DIR}/profiles.json
ExecStart=${relay_bin} -config ${WEB_CONF_DIR}/config.json
Restart=on-failure
RestartSec=3s
TimeoutStopSec=20s
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateDevices=true
PrivateTmp=true
ProtectClock=true
ProtectControlGroups=true
ProtectHome=true
ProtectHostname=true
ProtectKernelLogs=true
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectProc=invisible
ProtectSystem=strict
ProcSubset=pid
RestrictAddressFamilies=AF_INET AF_INET6
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
CapabilityBoundingSet=
IPAddressDeny=any
IPAddressAllow=localhost
SystemCallArchitectures=native
SystemCallFilter=@system-service
UMask=0077

[Install]
WantedBy=multi-user.target
EOF

  cat > "/etc/systemd/system/${SVC_CADDY}" <<EOF
[Unit]
Description=mtproxy-ws WEB front (Caddy ${CADDY_VER}, ${WEB_HOST})
After=network-online.target ${SVC_RELAY}
Wants=network-online.target ${SVC_RELAY}

[Service]
Type=notify
User=${CADDY_USER}
Group=${CADDY_USER}
Environment=HOME=${CADDY_DATA}
Environment=XDG_DATA_HOME=${CADDY_DATA}
Environment=XDG_CONFIG_HOME=${CADDY_DATA}
ExecStart=${caddy_bin} run --environ --config ${CADDY_CONF_DIR}/Caddyfile --adapter caddyfile
Restart=on-failure
RestartSec=3s
TimeoutStopSec=10s
LimitNOFILE=1048576
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateDevices=true
PrivateTmp=true
ProtectHome=true
ProtectProc=invisible
ProtectSystem=full
ProcSubset=pid
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=true
RestrictRealtime=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF
}

c_y "[6/7] WEB-прокси…"
if [[ "$WEB_PROXY" -eq 1 ]]; then
  install_web
  info "WEB: ${WEB_HOST}${WEB_BASE_PATH:+/$WEB_BASE_PATH}, carrier=${WEB_CARRIER}, бэкенд 127.0.0.1:${WEB_BACKEND_PORT}"
else
  if [[ -f "/etc/systemd/system/${SVC_RELAY}" ]]; then
    svc_stop_rm "$SVC_CADDY" "$SVC_RELAY" "$SVC_WEB_BACKEND"
    info "WEB-прокси: выключен (сервисы удалены; бинарники в ${WEB_DIR} оставлены)"
  else
    info "WEB-прокси: выключен"
  fi
fi

c_y "[7/7] Запуск…"
systemctl daemon-reload
systemctl enable "$SVC_PROXY" >/dev/null 2>&1
systemctl restart "$SVC_PROXY"
[[ "$DPI_BYPASS" -eq 1 ]] && systemctl enable --now "$SVC_IPT" "$SVC_NFQWS" >/dev/null
sleep 2
systemctl is-active --quiet "$SVC_PROXY" || { journalctl -u "$SVC_PROXY" -n 20 --no-pager; die "прокси не стартовал"; }

WEB_READY=0; WEB_HTTPS_OK=0
if [[ "$WEB_PROXY" -eq 1 ]]; then
  systemctl enable "$SVC_WEB_BACKEND" "$SVC_RELAY" "$SVC_CADDY" >/dev/null 2>&1
  systemctl restart "$SVC_WEB_BACKEND"
  sleep 1
  systemctl restart "$SVC_RELAY"
  for _i in $(seq 1 15); do
    curl -fsS --max-time 2 "http://${RELAY_ADMIN}/readyz" >/dev/null 2>&1 && { WEB_READY=1; break; }
    sleep 1
  done
  if [[ "$WEB_READY" -ne 1 ]]; then
    journalctl -u "$SVC_WEB_BACKEND" -u "$SVC_RELAY" -n 30 --no-pager
    die "WEB relay не готов (readyz) — бэкенд 127.0.0.1:${WEB_BACKEND_PORT} или relay не стартовали"
  fi
  systemctl restart "$SVC_CADDY"
  sleep 2
  systemctl is-active --quiet "$SVC_CADDY" || { journalctl -u "$SVC_CADDY" -n 30 --no-pager; die "Caddy не стартовал"; }
  # сертификат выпускается в фоне — даём немного времени
  for _i in $(seq 1 10); do
    curl -fsS --max-time 5 -o /dev/null "https://${WEB_HOST}/" 2>/dev/null && { WEB_HTTPS_OK=1; break; }
    sleep 3
  done
fi

if [[ "$NO_FAKE_TLS" -eq 1 ]]; then
  SEC_LINK="dd${SECRET}"; MODE="обычный MTProto (dd, без Fake-TLS)"
else
  SEC_LINK="ee${SECRET}${DOMAIN_HEX}"; MODE="Fake-TLS под ${DOMAIN}"
fi
LINK="tg://proxy?server=${SERVER}&port=${PORT}&secret=${SEC_LINK}"
TME="https://t.me/proxy?server=${SERVER}&port=${PORT}&secret=${SEC_LINK}"
SRV_IP="${PUBIP:-$(hostname -I | awk '{print $1}')}"

echo
c_g "════════════════════════════════════════════════════════════"
c_g "  Готово. MTProto-прокси запущен."
c_g "════════════════════════════════════════════════════════════"
if [[ "$SERVER" == "$SRV_IP" ]]; then
  echo "  Точка входа:  ${SERVER}  (IP VPS)"
else
  echo "  Точка входа:  ${SERVER}  (A-запись, серое облако -> ${SRV_IP})"
fi
echo "  Режим:        ${MODE}"
[[ "$NO_FAKE_TLS" -ne 1 ]] && echo "  Fake-TLS:     ${DOMAIN}  (живой HTTPS-сайт для маскировки)"
echo "  Порт:         ${PORT}"
echo "  Secret:       ${SEC_LINK}"
if [[ -n "$CFPROXY_DOMAIN" ]]; then
  echo "  CfProxy:      ${CF_PREFIX}{dc}.${CFPROXY_DOMAIN}  (исходящее через твою зону)"
else
  echo "  CfProxy:      встроенные/авто домены движка (своя зона не нужна)"
fi
echo "  DPI:          $([[ $DPI_BYPASS -eq 1 ]] && echo 'включён (TCPMSS+nfqws)' || echo 'выключен')"
echo "  Keepalive:    $([[ $KEEPALIVE_OK -eq 1 ]] && echo "WS PING каждые ${WS_KEEPALIVE}s" || echo 'нет (движок не поддерживает --ws-keepalive)')"
echo "  Логи:         LOG_LEVEL=${LOG_LEVEL}$([[ "$LOG_LEVEL" != "info" ]] && echo ' (логи подключений отключены)')"
echo
echo "  Ссылка для Telegram:"
c_y "  ${LINK}"
echo "  ${TME}"
echo
if [[ "$WEB_PROXY" -eq 1 ]]; then
  echo "  WEB-прокси (Telegram Desktop 7.1+):"
  echo "    Сайт:       https://${WEB_HOST}/  $([[ $WEB_HTTPS_OK -eq 1 ]] && echo '(HTTPS ок)' || echo '(сертификат ещё выпускается — проверь позже)')"
  echo "    Carrier:    ${WEB_CARRIER}    Base path: ${WEB_BASE_PATH:-нет (корень)}"
  echo "    Ссылка:"
  /usr/local/bin/mtproxy-ws weblink | sed -n '2p' | while IFS= read -r l; do c_y "    ${l}"; done
  /usr/local/bin/mtproxy-ws weblink | sed -n '1p' | sed 's/^/    /'
  [[ -n "$WEB_BASE_PATH" ]] && echo "    (с base path ссылку открывают только клиенты с его поддержкой; для старых — --web-base-path none)"
  echo
fi
if [[ -n "$CFPROXY_DOMAIN" ]]; then
  echo "  DNS для CfProxy (оранжевое облако + SSL/TLS=Flexible):"
  printf "    %-7s %s\n" "${CF_PREFIX}1.${CFPROXY_DOMAIN}"   "149.154.175.50"
  printf "    %-7s %s\n" "${CF_PREFIX}2.${CFPROXY_DOMAIN}"   "149.154.167.51"
  printf "    %-7s %s\n" "${CF_PREFIX}3.${CFPROXY_DOMAIN}"   "149.154.175.100"
  printf "    %-7s %s\n" "${CF_PREFIX}4.${CFPROXY_DOMAIN}"   "149.154.167.91"
  printf "    %-7s %s\n" "${CF_PREFIX}5.${CFPROXY_DOMAIN}"   "149.154.171.5"
  printf "    %-7s %s\n" "${CF_PREFIX}203.${CFPROXY_DOMAIN}" "91.105.192.100"
  echo
fi
echo "  Логи:    journalctl -u ${SVC_PROXY} -f   |   /var/log/mtproxy-ws.log"
[[ "$WEB_PROXY" -eq 1 ]] && echo "  WEB:     mtproxy-ws logs web   |   /var/log/mtproxy-ws-web.log"
echo "  Менеджер: mtproxy-ws {status|start|stop|restart|link|weblink|qr [web]|logs [web]|edit|rotate|update}"
echo "  Снести:  curl -fsSL ${SELF_URL} | sudo bash -s -- --uninstall"
c_g "════════════════════════════════════════════════════════════"

RESOLVED="$(getent hosts "$SERVER" | awk '{print $1}' | head -1 || true)"
if [[ -n "$SRV_IP" && -n "$RESOLVED" && "$RESOLVED" != "$SRV_IP" ]]; then
  c_y "  ⚠  Точка входа ${SERVER} резолвится в ${RESOLVED}, а IP сервера ${SRV_IP}."
  c_y "     Поправь A-запись (серое облако), иначе клиенты не подключатся."
fi
if [[ "$WEB_PROXY" -eq 1 ]]; then
  WEB_RESOLVED="$(getent ahostsv4 "$WEB_HOST" 2>/dev/null | awk '{print $1; exit}' || true)"
  if [[ -n "$SRV_IP" && "$WEB_RESOLVED" != "$SRV_IP" ]]; then
    c_y "  ⚠  ${WEB_HOST} резолвится в '${WEB_RESOLVED:-ничего}', а IP сервера ${SRV_IP}."
    c_y "     Нужна A-запись на VPS без CDN (серое облако) — иначе нет сертификата и WEB-прокси не работает."
  fi
fi
DOM_IP="$(getent hosts "$DOMAIN" | awk '{print $1}' | head -1 || true)"
# Fake-TLS отдаёт «чужой» трафик на DOMAIN:443 — петля, только если там же наш MTProto
if [[ "$NO_FAKE_TLS" -ne 1 && "$PORT" == "443" ]] && { [[ "$DOMAIN" == "$SERVER" ]] || [[ -n "$DOM_IP" && "$DOM_IP" == "$SRV_IP" ]]; }; then
  c_y "  ⚠  Fake-TLS домен совпадает с точкой входа на :443 — риск петли маскировки."
  c_y "     Возьми для --domain отдельный реальный сайт (например insage.ru), не ${SERVER}."
fi
