#!/bin/bash

uninstall() {
  rm -f /usr/local/bin/hysteria
  bash <(curl -fsSL https://get.hy2.sh) --remove
  rm -f "$CONFIG_FILE" "$CERT_FILE" "$KEY_FILE"
  systemctl stop hysteria-server.service
  systemctl disable hysteria-server.service
  rm -rf /etc/hysteria && userdel -r hysteria && rm -f /etc/systemd/system/multi-user.target.wants/hysteria-server.service && rm -f /etc/systemd/system/multi-user.target.wants/hysteria-server@*.service
  systemctl daemon-reload
  echo -e "\033[0;32mHysteria 2 已彻底卸载\033[0m"
  echo "--> 项目地址：https://github.com/bpzx/hy2"
}

SNI="epson.com.cn"
PWD="Ayna$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 10)"
CONFIG_FILE="/etc/hysteria/config.yaml"
CERT_FILE="/etc/hysteria/server.crt"
KEY_FILE="/etc/hysteria/server.key"

get_port() {
  read -p "端口[默认443]：" port_input
  if [[ -z "$port_input" ]]; then
    echo 443
    return
  fi

  if [[ "$port_input" =~ ^[0-9]+$ ]]; then
    echo "$port_input"
  else
    echo "请输入一个合法的数字！"
    get_port
  fi
}

gen_ssl() {
  openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) -keyout "$KEY_FILE" -out "$CERT_FILE" -subj "/CN=$SNI" -days 36500 && chown hysteria "$KEY_FILE" && chown hysteria "$CERT_FILE"
}

install_hy2() {
  bash <(curl -fsSL https://get.hy2.sh/)
}

configure_hy2() {
  local port="$1"
  url="https://$SNI"
  cat << EOF > "$CONFIG_FILE"
listen: :$port

# 自签
tls:
  cert: $CERT_FILE
  key: $KEY_FILE

auth:
  type: password
  password: $PWD

masquerade:
  type: proxy
  proxy:
    url: $url
    rewriteHost: true
EOF
}

start_hy2() {
  systemctl restart hysteria-server.service
  systemctl enable hysteria-server.service
}

get_local_ip() {
  local ip=$(curl ipaddress.sh)
  if [[ -z "$ip" ]]; then
    echo "无法获取公网 IP 地址"
    return 1 # 返回错误码
  fi
  echo "$ip"
}

get_hy2_url() {
  local port=$(get_port)
  install_hy2
  gen_ssl
  configure_hy2 "$port"
  start_hy2
  local ip=$(get_local_ip)
  # ANSI 转义序列：\033[0;32m 表示绿色开始，\033[0m 表示颜色重置
  echo -e "\033[0;32mhysteria2://$PWD@$ip:$port?sni=$SNI&insecure=1#hy2_by_Anya\033[0m"
  echo "--> 项目地址：https://github.com/bpzx/hy2"
}

run() {
  get_hy2_url
}

if [[ "$0" == "$BASH_SOURCE" ]]; then
  if [[ "$1" == "-u" ]]; then
    uninstall
  else
    run
  fi
fi
