#!/usr/bin/env bash
set -eu

SNI="epson.com.cn"
HY2_PASSWORD="Ayna$(openssl rand -hex 6)"
CONFIG_DIR="/etc/hysteria"
CONFIG_FILE="$CONFIG_DIR/config.yaml"
CERT_FILE="$CONFIG_DIR/server.crt"
KEY_FILE="$CONFIG_DIR/server.key"
BIN_FILE="/usr/local/bin/hysteria"
SERVICE_NAME="hysteria-server"

OS_ID=""
INIT_SYSTEM=""

log() {
  echo -e "\033[0;32m$*\033[0m"
}

err() {
  echo -e "\033[0;31m$*\033[0m" >&2
}

require_root() {
  if [[ "$(id -u)" -ne 0 ]]; then
    err "请使用 root 运行"
    exit 1
  fi
}

detect_env() {
  if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    OS_ID="${ID:-}"
  fi

  case "$OS_ID" in
    alpine)
      INIT_SYSTEM="openrc"
      ;;
    debian|ubuntu)
      INIT_SYSTEM="systemd"
      ;;
    *)
      if command -v systemctl >/dev/null 2>&1; then
        INIT_SYSTEM="systemd"
      elif command -v rc-service >/dev/null 2>&1; then
        INIT_SYSTEM="openrc"
      else
        err "暂不支持当前系统"
        exit 1
      fi
      ;;
  esac
}

install_deps() {
  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    apt-get update -y
    apt-get install -y curl openssl ca-certificates bash
  else
    apk add --no-cache bash curl openssl ca-certificates
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv7|armhf|arm) echo "arm" ;;
    i386|i686) echo "386" ;;
    s390x) echo "s390x" ;;
    riscv64) echo "riscv64" ;;
    *)
      err "不支持的架构: $(uname -m)"
      exit 1
      ;;
  esac
}

ensure_hysteria_user() {
  if id hysteria >/dev/null 2>&1; then
    return
  fi

  if [[ "$INIT_SYSTEM" == "openrc" ]]; then
    adduser -D -h /var/lib/hysteria -s /sbin/nologin hysteria
  else
    useradd -r -m -d /var/lib/hysteria -s /usr/sbin/nologin hysteria 2>/dev/null \
      || useradd -r -m -d /var/lib/hysteria -s /sbin/nologin hysteria
  fi

  mkdir -p /var/lib/hysteria
  chown hysteria:hysteria /var/lib/hysteria
}

install_openrc_service() {
  cat > "/etc/init.d/${SERVICE_NAME}" <<'EOF'
#!/sbin/openrc-run

name="Hysteria 2 Server"
description="Hysteria 2 Server"

command="/usr/local/bin/hysteria"
command_args="server --config /etc/hysteria/config.yaml"
command_user="hysteria:hysteria"
pidfile="/run/${RC_SVCNAME}.pid"
command_background=true
retry="TERM/30/KILL/5"

depend() {
    need net
    after firewall
}
EOF

  chmod +x "/etc/init.d/${SERVICE_NAME}"
}

install_hy2() {
  mkdir -p "$CONFIG_DIR"

  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    bash <(curl -fsSL https://get.hy2.sh/)
  else
    local arch tmp_file
    arch="$(detect_arch)"
    tmp_file="$(mktemp)"

    curl -fsSL "https://download.hysteria.network/app/latest/hysteria-linux-${arch}" -o "$tmp_file"
    install -Dm755 "$tmp_file" "$BIN_FILE"
    rm -f "$tmp_file"

    ensure_hysteria_user
    install_openrc_service
  fi

  ensure_hysteria_user
}

get_port() {
  local port_input
  read -r -p "端口[默认443]：" port_input

  if [[ -z "${port_input}" ]]; then
    echo 443
    return
  fi

  if [[ "$port_input" =~ ^[0-9]+$ ]] && (( port_input >= 1 && port_input <= 65535 )); then
    echo "$port_input"
  else
    err "请输入 1~65535 的合法端口"
    get_port
  fi
}

gen_ssl() {
  mkdir -p "$CONFIG_DIR"

  openssl req -x509 -nodes \
    -newkey ec:<(openssl ecparam -name prime256v1) \
    -keyout "$KEY_FILE" \
    -out "$CERT_FILE" \
    -subj "/CN=${SNI}" \
    -days 36500

  chown hysteria:hysteria "$KEY_FILE" "$CERT_FILE"
  chmod 600 "$KEY_FILE"
  chmod 644 "$CERT_FILE"
}

configure_hy2() {
  local port="$1"

  cat > "$CONFIG_FILE" <<EOF
listen: :$port

tls:
  cert: $CERT_FILE
  key: $KEY_FILE

auth:
  type: password
  password: $HY2_PASSWORD

masquerade:
  type: proxy
  proxy:
    url: https://$SNI
    rewriteHost: true
EOF
}

start_hy2() {
  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    systemctl daemon-reload
    systemctl enable --now "${SERVICE_NAME}.service"
  else
    rc-update add "$SERVICE_NAME" default >/dev/null 2>&1 || true
    rc-service "$SERVICE_NAME" restart >/dev/null 2>&1 || rc-service "$SERVICE_NAME" start
  fi
}

stop_disable_hy2() {
  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    systemctl stop "${SERVICE_NAME}.service" >/dev/null 2>&1 || true
    systemctl disable "${SERVICE_NAME}.service" >/dev/null 2>&1 || true

    rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
    rm -f "/etc/systemd/system/${SERVICE_NAME}@.service"
    rm -f /etc/systemd/system/multi-user.target.wants/${SERVICE_NAME}.service
    rm -f /etc/systemd/system/multi-user.target.wants/${SERVICE_NAME}@*.service || true

    systemctl daemon-reload >/dev/null 2>&1 || true
  else
    rc-service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
    rc-update del "$SERVICE_NAME" default >/dev/null 2>&1 || true
    rm -f "/etc/init.d/${SERVICE_NAME}"
  fi
}

remove_hysteria_user() {
  if ! id hysteria >/dev/null 2>&1; then
    return
  fi

  if [[ "$INIT_SYSTEM" == "systemd" ]]; then
    userdel -r hysteria >/dev/null 2>&1 || true
  else
    deluser --remove-home hysteria >/dev/null 2>&1 || deluser hysteria >/dev/null 2>&1 || true
    rm -rf /var/lib/hysteria
  fi
}

uninstall() {
  require_root
  detect_env

  stop_disable_hy2
  rm -f "$BIN_FILE"
  rm -rf "$CONFIG_DIR"
  remove_hysteria_user

  log "Hysteria 2 已彻底卸载"
  echo "--> 项目地址：https://github.com/bpzx/hy2"
}

get_local_ip() {
  local ip
  ip="$(curl -4fsSL https://api.ipify.org 2>/dev/null || true)"
  [[ -n "$ip" ]] || ip="$(curl -4fsSL https://ifconfig.me 2>/dev/null || true)"

  if [[ -z "$ip" ]]; then
    err "无法获取公网 IP 地址"
    return 1
  fi

  echo "$ip"
}

get_hy2_url() {
  local port ip

  port="$(get_port)"
  install_hy2
  gen_ssl
  configure_hy2 "$port"
  start_hy2
  ip="$(get_local_ip)"

  log "hysteria2://${HY2_PASSWORD}@${ip}:${port}?sni=${SNI}&insecure=1#hy2_by_Anya"
  echo "--> 项目地址：https://github.com/bpzx/hy2"
}

run() {
  require_root
  detect_env
  install_deps
  get_hy2_url
}

if [[ "$0" == "$BASH_SOURCE" ]]; then
  if [[ "${1:-}" == "-u" ]]; then
    uninstall
  else
    run
  fi
fi
