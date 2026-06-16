#!/usr/bin/env bash
# mtproxy-ws-ins: Flowseal/tg-ws-proxy + zapret.
# Установка (интерактив):  sudo bash <(curl -fsSL https://raw.githubusercontent.com/xRR-debug/tg-ws-proxy/main/install.sh)
# Или с флагами:           curl -fsSL <url> | sudo bash -s -- --yes ФЛАГИ
# Все флаги: --help
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

usage(){ cat <<USAGE
mtproxy-ws-ins - установка MTProto-прокси (tg-ws-proxy + zapret).

Одной строкой:
  curl -fsSL ${SELF_URL} | sudo bash
  curl -fsSL ${SELF_URL} | sudo bash -s -- --port 443 --server alt2.insage.ru --domain max.ru --cf-prefix node --dpi-bypass

Флаги:
  --port N             порт MTProto (по умолч. 443)
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
    --yes|-y)            ASSUME_YES=1; shift ;;
    --uninstall)         DO_UNINSTALL=1; shift ;;
    -h|--help)           usage; exit 0 ;;
    *)                   die "неизвестный аргумент: $1" ;;
  esac
done

[[ $EUID -eq 0 ]] || die "запускать от root (sudo)."

if [[ $DO_UNINSTALL -eq 1 ]]; then
  c_y "Удаление mtproxy-ws…"
  systemctl disable --now "$SVC_PROXY" "$SVC_NFQWS" "$SVC_IPT" 2>/dev/null || true
  rm -f "/etc/systemd/system/${SVC_PROXY}" \
        "/etc/systemd/system/${SVC_NFQWS}" \
        "/etc/systemd/system/${SVC_IPT}"
  systemctl daemon-reload
  # shellcheck source=/dev/null
  if [[ -f "$CONF_FILE" ]]; then . "$CONF_FILE" 2>/dev/null || true; fi
  iptables -t mangle -D OUTPUT -p tcp --sport "${PORT}" -j TCPMSS --set-mss "$MSS" 2>/dev/null || true
  iptables -t mangle -D OUTPUT -p tcp --sport "${PORT}" -m conntrack --ctstate ESTABLISHED -j NFQUEUE --queue-num "$QNUM" --queue-bypass 2>/dev/null || true
  rm -rf "$APP_DIR" "$CONF_DIR"
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

DOMAIN_HEX="$(hexenc "$DOMAIN")"

c_y "[1/6] Системные пакеты…"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq git python3 python3-venv python3-pip openssl curl iproute2 >/dev/null
info "python: $(python3 --version 2>&1)"

c_y "[2/6] Движок tg-ws-proxy…"
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

# keepalive теперь нативный в форке (PR #925) — рантайм-патч не нужен
KEEPALIVE_OK=1

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
"${VENV_DIR}/bin/pip" install -q cryptography >/dev/null
info "движок: ${APP_DIR}"

c_y "[3/6] Конфигурация…"
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
EOF
chmod 600 "$CONF_FILE"

CF_ARG=""
[[ -n "$CFPROXY_DOMAIN" ]] && CF_ARG="--cfproxy-domain \"${CFPROXY_DOMAIN}\""
KA_ARG=""
[[ "$KEEPALIVE_OK" -eq 1 ]] && KA_ARG="--ws-keepalive \"\${WS_KEEPALIVE}\""
FT_ARG="--fake-tls-domain \"\${DOMAIN}\""
[[ "$NO_FAKE_TLS" -eq 1 ]] && FT_ARG=""
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
exec "${VENV_DIR}/bin/python" -m proxy.tg_ws_proxy \\
  --host 0.0.0.0 \\
  --port "\${PORT}" \\
  --secret "\${SECRET}" \\
  ${FT_ARG} \\
  ${CF_ARG} \\
  ${KA_ARG} \\
  --log-file /var/log/mtproxy-ws.log \\
  --log-max-mb 5 --log-backups 1
EOF
chmod +x "$RUN_WRAPPER"

c_y "[4/6] systemd-сервис прокси…"
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
INSTALLER=/usr/local/share/mtproxy-ws/install.sh
[[ $EUID -eq 0 ]] || { echo "нужен root (sudo mtproxy-ws ...)"; exit 1; }
[[ -f $CONF ]] || { echo "конфиг $CONF не найден — прокси не установлен"; exit 1; }
# shellcheck source=/dev/null
source "$CONF"

UNITS=("$SVC")
systemctl list-unit-files --no-legend 2>/dev/null | grep -q "^${SVC_NFQWS}" && UNITS+=("$SVC_NFQWS" "$SVC_IPT")

hexenc(){ printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }
build_link(){
  local sec
  if [[ "${NO_FAKE_TLS:-0}" == "1" ]]; then sec="dd${SECRET}"
  else sec="ee${SECRET}$(hexenc "$DOMAIN")"; fi
  echo "tg://proxy?server=${SERVER}&port=${PORT}&secret=${sec}"
  echo "https://t.me/proxy?server=${SERVER}&port=${PORT}&secret=${sec}"
}

case "${1:-status}" in
  status)  systemctl status "${UNITS[@]}" --no-pager || true
           echo; journalctl -u "$SVC" -n 1 --no-pager | grep -i stats || true ;;
  start)   systemctl start   "${UNITS[@]}"; echo "запущено" ;;
  stop)    systemctl stop    "${UNITS[@]}"; echo "остановлено" ;;
  restart) systemctl restart "${UNITS[@]}"; echo "перезапущено" ;;
  link)    build_link ;;
  qr)      command -v qrencode >/dev/null || { echo "поставь qrencode: apt install -y qrencode"; exit 1; }
           build_link | head -1 | qrencode -t ANSIUTF8 ;;
  logs)    shift; journalctl -u "$SVC" -f "$@" ;;
  edit)    "${EDITOR:-nano}" "$CONF"; systemctl restart "$SVC"; echo "сохранено, перезапущено" ;;
  rotate)
    NEW="$(openssl rand -hex 16)"
    sed -i "s/^SECRET=.*/SECRET=${NEW}/" "$CONF"
    SECRET="$NEW"; systemctl restart "$SVC"
    echo "Новый сикрет: $NEW"
    echo "Новая ссылка (старая больше НЕ работает):"; build_link ;;
  update)
    [[ -f "$INSTALLER" ]] || { echo "сохранённый install.sh не найден — переустанови вручную"; exit 1; }
    a=(--yes --secret "$SECRET" --port "$PORT" --server "$SERVER" --cf-prefix "$CF_PREFIX"
       --ws-keepalive "$WS_KEEPALIVE" --log-level "${LOG_LEVEL:-info}" --dpi-opts "$NFQWS_OPTS")
    [[ "${NO_FAKE_TLS:-0}" == "1" ]] && a+=(--no-fake-tls) || a+=(--domain "$DOMAIN")
    [[ -n "${CFPROXY_DOMAIN:-}" ]] && a+=(--cfproxy-domain "$CFPROXY_DOMAIN") || a+=(--builtin-cfproxy)
    [[ "${DPI_BYPASS:-0}" == "1" ]] && a+=(--dpi-bypass) || a+=(--no-dpi-bypass)
    bash "$INSTALLER" "${a[@]}" ;;
  *) echo "mtproxy-ws {status|start|stop|restart|link|qr|logs|edit|rotate|update}"; exit 1 ;;
esac
MGR
chmod +x /usr/local/bin/mtproxy-ws

c_y "[5/6] Слой обхода DPI/TSPU…"
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
  systemctl disable --now "$SVC_NFQWS" "$SVC_IPT" 2>/dev/null || true
  rm -f "/etc/systemd/system/${SVC_NFQWS}" "/etc/systemd/system/${SVC_IPT}"
  iptables -t mangle -D OUTPUT -p tcp --sport "${PORT}" -j TCPMSS --set-mss "$MSS" 2>/dev/null || true
  iptables -t mangle -D OUTPUT -p tcp --sport "${PORT}" -m conntrack --ctstate ESTABLISHED -j NFQUEUE --queue-num "$QNUM" --queue-bypass 2>/dev/null || true
  info "anti-DPI: выключен"
fi

if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
  ufw allow "${PORT}/tcp" >/dev/null 2>&1 || true
  info "ufw: открыт ${PORT}/tcp"
fi

c_y "[6/6] Запуск…"
systemctl daemon-reload
systemctl enable --now "$SVC_PROXY" >/dev/null
[[ "$DPI_BYPASS" -eq 1 ]] && systemctl enable --now "$SVC_IPT" "$SVC_NFQWS" >/dev/null
sleep 2
systemctl is-active --quiet "$SVC_PROXY" || { journalctl -u "$SVC_PROXY" -n 20 --no-pager; die "прокси не стартовал"; }

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
echo "  Keepalive:    $([[ $KEEPALIVE_OK -eq 1 ]] && echo "WS PING каждые ${WS_KEEPALIVE}s" || echo 'нет (патч не применён)')"
echo "  Логи:         LOG_LEVEL=${LOG_LEVEL}$([[ "$LOG_LEVEL" != "info" ]] && echo ' (логи подключений отключены)')"
echo
echo "  Ссылка для Telegram:"
c_y "  ${LINK}"
echo "  ${TME}"
echo
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
echo "  Менеджер: mtproxy-ws {status|start|stop|restart|link|qr|logs|edit|rotate|update}"
echo "  Снести:  curl -fsSL ${SELF_URL} | sudo bash -s -- --uninstall"
c_g "════════════════════════════════════════════════════════════"

RESOLVED="$(getent hosts "$SERVER" | awk '{print $1}' | head -1 || true)"
if [[ -n "$SRV_IP" && -n "$RESOLVED" && "$RESOLVED" != "$SRV_IP" ]]; then
  c_y "  ⚠  Точка входа ${SERVER} резолвится в ${RESOLVED}, а IP сервера ${SRV_IP}."
  c_y "     Поправь A-запись (серое облако), иначе клиенты не подключатся."
fi
DOM_IP="$(getent hosts "$DOMAIN" | awk '{print $1}' | head -1 || true)"
if [[ "$NO_FAKE_TLS" -ne 1 ]] && { [[ "$DOMAIN" == "$SERVER" ]] || { [[ -n "$DOM_IP" && "$DOM_IP" == "$SRV_IP" && "$PORT" == "443" ]]; }; }; then
  c_y "  ⚠  Fake-TLS домен совпадает с точкой входа на :443 — риск петли маскировки."
  c_y "     Возьми для --domain отдельный реальный сайт (например insage.ru), не ${SERVER}."
fi
