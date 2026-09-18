#!/usr/bin/env bash
#
# Debian 13 sing-box
# Hysteria2 + Salamander : UDP/443
# AnyTLS                 : TCP/443
# Let's Encrypt          : Certbot standalone
#
# 功能：
#   安装 / 配置 / 卸载
#   IPv4 / IPv6 自动检测
#   随机密码
#   sing-box 配置检查
#   TCP/UDP 443 检查
#   URI / Mihomo / sing-box 客户端配置生成
#   备份 / 恢复
#   日志 / 重启 / 查看信息
#
# 使用：
#   chmod +x install-singbox-hy2-anytls.sh
#   sudo ./install-singbox-hy2-anytls.sh
#

set -Eeuo pipefail

APP_NAME="singbox-hy2-anytls"
CONFIG_DIR="/etc/sing-box"
CONFIG_FILE="${CONFIG_DIR}/config.json"
DATA_DIR="/etc/${APP_NAME}"
BACKUP_DIR="/root/${APP_NAME}-backup"
CERTBOT_HOOK="/etc/letsencrypt/renewal-hooks/deploy/sing-box-reload.sh"

SB_SERVICE="sing-box.service"
SB_BIN="/usr/bin/sing-box"

DOMAIN_FILE="${DATA_DIR}/domain"
EMAIL_FILE="${DATA_DIR}/email"
HY2_PASS_FILE="${DATA_DIR}/hy2_password"
HY2_OBFS_FILE="${DATA_DIR}/hy2_obfs_password"
ANYTLS_PASS_FILE="${DATA_DIR}/anytls_password"
LISTEN_FILE="${DATA_DIR}/listen"

GREEN="\033[32m"
YELLOW="\033[33m"
RED="\033[31m"
CYAN="\033[36m"
RESET="\033[0m"

log() {
    echo -e "${GREEN}[+]${RESET} $*"
}

warn() {
    echo -e "${YELLOW}[!]${RESET} $*"
}

err() {
    echo -e "${RED}[-]${RESET} $*" >&2
}

die() {
    err "$*"
    exit 1
}

pause() {
    read -rp "按 Enter 继续..." _
}

require_root() {
    [[ "${EUID}" -eq 0 ]] || die "请使用 root 运行此脚本。"
}

check_os() {
    [[ -f /etc/os-release ]] || die "无法检测操作系统。"

    . /etc/os-release

    if [[ "${ID:-}" != "debian" ]]; then
        warn "当前系统不是 Debian。检测到：${PRETTY_NAME:-unknown}"
        read -rp "仍然继续？[y/N]: " answer
        [[ "${answer,,}" == "y" ]] || exit 0
    fi

    if [[ "${VERSION_ID:-}" != "13" ]]; then
        warn "此脚本主要针对 Debian 13。当前版本：${VERSION_ID:-unknown}"
        read -rp "仍然继续？[y/N]: " answer
        [[ "${answer,,}" == "y" ]] || exit 0
    fi
}

install_dependencies() {
    log "安装依赖..."

    export DEBIAN_FRONTEND=noninteractive

    apt-get update

    apt-get install -y \
        ca-certificates \
        curl \
        wget \
        openssl \
        jq \
        dnsutils \
        iproute2 \
        iputils-ping \
        netcat-openbsd \
        procps \
        lsof \
        nftables \
        certbot
}

install_singbox() {
    log "安装 / 更新 sing-box..."

    mkdir -p /etc/apt/keyrings

    curl -fsSL \
        https://sing-box.app/gpg.key \
        -o /etc/apt/keyrings/sagernet.asc

    chmod a+r /etc/apt/keyrings/sagernet.asc

    cat > /etc/apt/sources.list.d/sagernet.sources <<'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF

    apt-get update
    apt-get install -y sing-box

    command -v sing-box >/dev/null 2>&1 ||
        die "sing-box 安装失败。"

    log "sing-box 版本：$(sing-box version | head -n 1)"
}

detect_network() {
    log "检测网络环境..."

    IPV4=""
    IPV6=""
    IPV4_OK=0
    IPV6_OK=0

    IPV4="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '
        {
            for (i=1;i<=NF;i++)
                if ($i=="src") {print $(i+1); exit}
        }'
    )" || true

    if [[ -n "${IPV4}" ]]; then
        IPV4_OK=1
    fi

    IPV6="$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '
        {
            for (i=1;i<=NF;i++)
                if ($i=="src") {print $(i+1); exit}
        }'
    )" || true

    if [[ -n "${IPV6}" ]]; then
        IPV6_OK=1
    fi

    echo
    echo "IPv4：${IPV4:-不可用}"
    echo "IPv6：${IPV6:-不可用}"
    echo

    if [[ "${IPV6_OK}" -eq 1 ]]; then
        IPV6_BINDONLY="$(sysctl -n net.ipv6.bindv6only 2>/dev/null || echo 0)"

        if [[ "${IPV6_BINDONLY}" == "1" ]]; then
            LISTEN_MODE="dual-separate"
        else
            LISTEN_MODE="dual"
        fi
    elif [[ "${IPV4_OK}" -eq 1 ]]; then
        LISTEN_MODE="ipv4"
    else
        die "没有检测到可用 IPv4 / IPv6 网络。"
    fi

    mkdir -p "${DATA_DIR}"
    echo "${LISTEN_MODE}" > "${LISTEN_FILE}"

    log "网络模式：${LISTEN_MODE}"
}

prompt_domain() {
    mkdir -p "${DATA_DIR}"

    echo
    echo "=============================================="
    echo " 域名配置"
    echo "=============================================="
    echo
    echo "请先确认："
    echo "1. 域名已经解析到本机 IPv4 / IPv6"
    echo "2. TCP/80 可以从公网访问"
    echo "3. TCP/443、UDP/443 可以从公网访问"
    echo

    read -rp "请输入域名，例如 hy.example.com： " DOMAIN

    [[ -n "${DOMAIN}" ]] || die "域名不能为空。"

    if [[ ! "${DOMAIN}" =~ ^[A-Za-z0-9.-]+$ ]]; then
        die "域名格式看起来不正确。"
    fi

    read -rp "Let's Encrypt 邮箱： " EMAIL

    [[ -n "${EMAIL}" ]] || die "邮箱不能为空。"

    echo "${DOMAIN}" > "${DOMAIN_FILE}"
    echo "${EMAIL}" > "${EMAIL_FILE}"

    log "域名：${DOMAIN}"
    log "邮箱：${EMAIL}"
}

resolve_domain() {
    local domain="$1"

    echo
    log "检查 DNS：${domain}"

    echo "A:"
    dig +short A "${domain}" || true

    echo
    echo "AAAA:"
    dig +short AAAA "${domain}" || true

    echo
    read -rp "DNS 是否已经正确指向本服务器？[Y/n]: " answer

    if [[ "${answer,,}" == "n" ]]; then
        die "请先完成 DNS 解析，再重新运行安装。"
    fi
}

generate_passwords() {
    log "生成随机密码..."

    umask 077

    openssl rand -hex 32 > "${HY2_PASS_FILE}"
    openssl rand -hex 32 > "${HY2_OBFS_FILE}"
    openssl rand -hex 32 > "${ANYTLS_PASS_FILE}"

    chmod 600 \
        "${HY2_PASS_FILE}" \
        "${HY2_OBFS_FILE}" \
        "${ANYTLS_PASS_FILE}"

    log "随机密码生成完成。"
}

get_domain() {
    cat "${DOMAIN_FILE}"
}

get_email() {
    cat "${EMAIL_FILE}"
}

get_hy2_password() {
    cat "${HY2_PASS_FILE}"
}

get_hy2_obfs_password() {
    cat "${HY2_OBFS_FILE}"
}

get_anytls_password() {
    cat "${ANYTLS_PASS_FILE}"
}

issue_certificate() {
    local domain email

    domain="$(get_domain)"
    email="$(get_email)"

    log "申请 Let's Encrypt 证书：${domain}"

    if systemctl is-active --quiet nginx 2>/dev/null; then
        warn "检测到 nginx 正在运行。Certbot standalone 需要 TCP/80 空闲。"
    fi

    if systemctl is-active --quiet apache2 2>/dev/null; then
        warn "检测到 Apache 正在运行。Certbot standalone 需要 TCP/80 空闲。"
    fi

    systemctl stop "${SB_SERVICE}" 2>/dev/null || true

    certbot certonly \
        --standalone \
        --preferred-challenges http \
        --non-interactive \
        --agree-tos \
        --email "${email}" \
        -d "${domain}"

    [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]] ||
        die "Let's Encrypt 证书申请失败。"

    [[ -f "/etc/letsencrypt/live/${domain}/privkey.pem" ]] ||
        die "Let's Encrypt 私钥不存在。"

    log "证书申请成功。"
}

build_inbounds() {
    local mode="$1"

    local common_tls
    local hy2
    local anytls

    common_tls=$(cat <<EOF
{
  "enabled": true,
  "server_name": "$(get_domain)",
  "certificate_path": "/etc/letsencrypt/live/$(get_domain)/fullchain.pem",
  "key_path": "/etc/letsencrypt/live/$(get_domain)/privkey.pem"
}
EOF
)

    hy2=$(cat <<EOF
{
  "type": "hysteria2",
  "tag": "hy2-in",
  "listen": "LISTEN_ADDRESS",
  "listen_port": 443,
  "users": [
    {
      "name": "default",
      "password": "$(get_hy2_password)"
    }
  ],
  "obfs": {
    "type": "salamander",
    "password": "$(get_hy2_obfs_password)"
  },
  "tls": ${common_tls}
}
EOF
)

    anytls=$(cat <<EOF
{
  "type": "anytls",
  "tag": "anytls-in",
  "listen": "LISTEN_ADDRESS",
  "listen_port": 443,
  "users": [
    {
      "name": "default",
      "password": "$(get_anytls_password)"
    }
  ],
  "tls": ${common_tls}
}
EOF
)

    case "${mode}" in
        ipv4)
            hy2="${hy2//LISTEN_ADDRESS/0.0.0.0}"
            anytls="${anytls//LISTEN_ADDRESS/0.0.0.0}"
            ;;

        dual)
            hy2="${hy2//LISTEN_ADDRESS/::}"
            anytls="${anytls//LISTEN_ADDRESS/::}"
            ;;

        dual-separate)
            # bindv6only=1 时，需要分别绑定 IPv4 / IPv6。
            hy2="${hy2//LISTEN_ADDRESS/0.0.0.0}"

            local hy2v6
            hy2v6="${hy2//0.0.0.0/::}"

            anytls="${anytls//LISTEN_ADDRESS/0.0.0.0}"

            local anytlsv6
            anytlsv6="${anytls//0.0.0.0/::}"

            cat > "${CONFIG_DIR}/inbounds.tmp" <<EOF
${hy2},
${hy2v6},
${anytls},
${anytlsv6}
EOF
            return
            ;;

        *)
            die "未知网络模式：${mode}"
            ;;
    esac

    cat > "${CONFIG_DIR}/inbounds.tmp" <<EOF
${hy2},
${anytls}
EOF
}

write_config() {
    local mode

    mode="$(cat "${LISTEN_FILE}")"

    mkdir -p "${CONFIG_DIR}"
    chmod 700 "${CONFIG_DIR}"

    build_inbounds "${mode}"

    {
        echo '{'
        echo '  "log": {'
        echo '    "level": "info",'
        echo '    "timestamp": true'
        echo '  },'
        echo '  "inbounds": ['

        sed '$s/,$//' "${CONFIG_DIR}/inbounds.tmp"

        echo '  ],'
        echo '  "outbounds": ['
        echo '    {'
        echo '      "type": "direct",'
        echo '      "tag": "direct"'
        echo '    }'
        echo '  ]'
        echo '}'
    } > "${CONFIG_FILE}"

    rm -f "${CONFIG_DIR}/inbounds.tmp"

    chmod 600 "${CONFIG_FILE}"

    log "sing-box 配置已生成：${CONFIG_FILE}"
}

check_config() {
    log "检查 sing-box 配置..."

    if sing-box check -c "${CONFIG_FILE}"; then
        log "配置检查通过。"
        return 0
    else
        err "配置检查失败。"
        return 1
    fi
}

setup_systemd() {
    log "配置 systemd..."

    systemctl daemon-reload
    systemctl enable "${SB_SERVICE}"

    if ! systemctl restart "${SB_SERVICE}"; then
        err "sing-box 启动失败。"
        journalctl -u "${SB_SERVICE}" --no-pager -n 80
        return 1
    fi

    sleep 2

    if systemctl is-active --quiet "${SB_SERVICE}"; then
        log "sing-box 已启动。"
    else
        err "sing-box 未正常运行。"
        journalctl -u "${SB_SERVICE}" --no-pager -n 80
        return 1
    fi
}

setup_cert_renewal() {
    log "配置 Let's Encrypt 自动续期..."

    mkdir -p "$(dirname "${CERTBOT_HOOK}")"

    cat > "${CERTBOT_HOOK}" <<'EOF'
#!/usr/bin/env bash

systemctl restart sing-box.service
EOF

    chmod 700 "${CERTBOT_HOOK}"

    systemctl enable --now certbot.timer 2>/dev/null || true

    log "证书自动续期已配置。"
}

configure_firewall() {
    echo
    echo "=============================================="
    echo " 防火墙"
    echo "=============================================="
    echo
    echo "需要至少允许："
    echo "  TCP 80"
    echo "  TCP 443"
    echo "  UDP 443"
    echo

    if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
        log "检测到 UFW，自动放行 80/443。"

        ufw allow 80/tcp
        ufw allow 443/tcp
        ufw allow 443/udp

    elif systemctl is-active --quiet nftables 2>/dev/null; then
        warn "检测到 nftables 正在运行。"
        warn "脚本不会覆盖现有防火墙规则，请确认 VPS 控制台已经放行：TCP 80/443、UDP 443。"

    else
        warn "未检测到正在运行的 UFW/nftables。"
        warn "请确认云厂商安全组已经放行 TCP 80/443、UDP 443。"
    fi
}

check_ports() {
    echo
    echo "=============================================="
    echo " 端口检查"
    echo "=============================================="

    echo
    log "TCP/443："

    if ss -lntp | grep -qE '(:443[[:space:]]|:443$)'; then
        echo -e "${GREEN}OK${RESET} TCP/443 正在监听"
        ss -lntp | grep -E '(:443[[:space:]]|:443$)' || true
    else
        echo -e "${RED}FAIL${RESET} TCP/443 没有监听"
    fi

    echo
    log "UDP/443："

    if ss -lnup | grep -qE '(:443[[:space:]]|:443$)'; then
        echo -e "${GREEN}OK${RESET} UDP/443 正在监听"
        ss -lnup | grep -E '(:443[[:space:]]|:443$)' || true
    else
        echo -e "${RED}FAIL${RESET} UDP/443 没有监听"
    fi

    echo
    log "本机 TCP/443 连接测试："

    if timeout 5 bash -c '</dev/tcp/127.0.0.1/443' 2>/dev/null; then
        echo -e "${GREEN}OK${RESET} 127.0.0.1:443 TCP 可连接"
    else
        echo -e "${YELLOW}WARN${RESET} 本机 TCP/443 连接失败或服务未接受普通 TLS 探测"
    fi

    echo
    warn "UDP 无连接握手，因此从服务器本机无法严格证明公网 UDP/443 可达。"
    warn "这里的 UDP 检查仅确认 sing-box 已监听 UDP/443。"
    echo

    log "当前监听："
    ss -lntup | grep -E '(:443[[:space:]]|:443$)' || true
}

urlencode() {
    # 当前密码由 hex 生成，本身无需 URL encode。
    printf '%s' "$1"
}

generate_hy2_uri() {
    local domain password obfs

    domain="$(get_domain)"
    password="$(get_hy2_password)"
    obfs="$(get_hy2_obfs_password)"

    printf 'hy2://%s@%s:443/?obfs=salamander&obfs-password=%s&sni=%s#Hysteria2\n' \
        "$(urlencode "${password}")" \
        "${domain}" \
        "$(urlencode "${obfs}")" \
        "${domain}"
}

generate_anytls_uri() {
    local domain password

    domain="$(get_domain)"
    password="$(get_anytls_password)"

    printf 'anytls://%s@%s:443?sni=%s#AnyTLS\n' \
        "$(urlencode "${password}")" \
        "${domain}" \
        "${domain}"
}

generate_mihomo_config() {
    local domain hy2pass obfspass anypass

    domain="$(get_domain)"
    hy2pass="$(get_hy2_password)"
    obfspass="$(get_hy2_obfs_password)"
    anypass="$(get_anytls_password)"

    cat <<EOF
proxies:

  - name: "Hysteria2-${domain}"
    type: hysteria2
    server: ${domain}
    port: 443
    password: "${hy2pass}"
    obfs: salamander
    obfs-password: "${obfspass}"
    sni: "${domain}"
    skip-cert-verify: false
    alpn:
      - h3
    udp: true

  - name: "AnyTLS-${domain}"
    type: anytls
    server: ${domain}
    port: 443
    password: "${anypass}"
    sni: "${domain}"
    skip-cert-verify: false
    client-fingerprint: chrome
    udp: true
EOF
}

generate_singbox_client() {
    local domain hy2pass obfspass anypass

    domain="$(get_domain)"
    hy2pass="$(get_hy2_password)"
    obfspass="$(get_hy2_obfs_password)"
    anypass="$(get_anytls_password)"

    cat <<EOF
{
  "outbounds": [
    {
      "type": "hysteria2",
      "tag": "hy2",
      "server": "${domain}",
      "server_port": 443,
      "password": "${hy2pass}",
      "obfs": {
        "type": "salamander",
        "password": "${obfspass}"
      },
      "tls": {
        "enabled": true,
        "server_name": "${domain}"
      }
    },
    {
      "type": "anytls",
      "tag": "anytls",
      "server": "${domain}",
      "server_port": 443,
      "password": "${anypass}",
      "tls": {
        "enabled": true,
        "server_name": "${domain}"
      }
    }
  ]
}
EOF
}

save_client_configs() {
    mkdir -p "${DATA_DIR}/clients"
    chmod 700 "${DATA_DIR}/clients"

    generate_hy2_uri > "${DATA_DIR}/clients/hysteria2.uri"
    generate_anytls_uri > "${DATA_DIR}/clients/anytls.uri"
    generate_mihomo_config > "${DATA_DIR}/clients/mihomo.yaml"
    generate_singbox_client > "${DATA_DIR}/clients/sing-box-client.json"

    chmod 600 "${DATA_DIR}/clients/"*

    log "客户端配置已保存："
    echo "  ${DATA_DIR}/clients/hysteria2.uri"
    echo "  ${DATA_DIR}/clients/anytls.uri"
    echo "  ${DATA_DIR}/clients/mihomo.yaml"
    echo "  ${DATA_DIR}/clients/sing-box-client.json"
}

show_info() {
    [[ -f "${DOMAIN_FILE}" ]] || {
        warn "尚未安装。"
        return
    }

    local domain

    domain="$(get_domain)"

    echo
    echo "============================================================"
    echo " sing-box Hysteria2 + AnyTLS"
    echo "============================================================"
    echo
    echo "域名：${domain}"
    echo "IPv4：${IPV4:-自动检测}"
    echo "IPv6：${IPV6:-自动检测}"
    echo
    echo "Hysteria2：UDP/443"
    echo "AnyTLS：TCP/443"
    echo
    echo "Hysteria2 密码："
    cat "${HY2_PASS_FILE}"
    echo
    echo
    echo "Salamander 密码："
    cat "${HY2_OBFS_FILE}"
    echo
    echo
    echo "AnyTLS 密码："
    cat "${ANYTLS_PASS_FILE}"
    echo
    echo
    echo "------------------------------------------------------------"
    echo "Hysteria2 URI"
    echo "------------------------------------------------------------"
    generate_hy2_uri
    echo
    echo "------------------------------------------------------------"
    echo "AnyTLS URI"
    echo "------------------------------------------------------------"
    generate_anytls_uri
    echo
    echo "------------------------------------------------------------"
    echo "systemd"
    echo "------------------------------------------------------------"
    systemctl --no-pager --full status "${SB_SERVICE}" 2>/dev/null | head -n 12 || true
    echo
    echo "配置文件：${CONFIG_FILE}"
    echo "数据目录：${DATA_DIR}"
    echo
}

show_client_configs() {
    [[ -d "${DATA_DIR}/clients" ]] || save_client_configs

    echo
    echo "============================================================"
    echo " Hysteria2 URI"
    echo "============================================================"
    cat "${DATA_DIR}/clients/hysteria2.uri"

    echo
    echo "============================================================"
    echo " AnyTLS URI"
    echo "============================================================"
    cat "${DATA_DIR}/clients/anytls.uri"

    echo
    echo "============================================================"
    echo " Mihomo"
    echo "============================================================"
    cat "${DATA_DIR}/clients/mihomo.yaml"

    echo
    echo "============================================================"
    echo " sing-box client"
    echo "============================================================"
    cat "${DATA_DIR}/clients/sing-box-client.json"
}

backup_all() {
    mkdir -p "${BACKUP_DIR}"

    local timestamp
    timestamp="$(date '+%Y%m%d-%H%M%S')"

    local target
    target="${BACKUP_DIR}/${APP_NAME}-${timestamp}.tar.gz"

    log "创建备份：${target}"

    tar \
        --ignore-failed-read \
        -czf "${target}" \
        "${CONFIG_DIR}" \
        "${DATA_DIR}" \
        /etc/systemd/system/sing-box.service \
        /etc/letsencrypt/live/"$(get_domain)" \
        /etc/letsencrypt/archive/"$(get_domain)" \
        /etc/letsencrypt/renewal/"$(get_domain)".conf \
        2>/dev/null || true

    chmod 600 "${target}"

    log "备份完成。"
}

restart_service() {
    log "重启 sing-box..."
    systemctl restart "${SB_SERVICE}"
    sleep 1
    systemctl --no-pager --full status "${SB_SERVICE}" | head -n 15
}

show_logs() {
    echo
    echo "1. 最近日志"
    echo "2. 实时日志"
    echo

    read -rp "选择 [1/2]： " choice

    case "${choice}" in
        2)
            journalctl -u "${SB_SERVICE}" -f
            ;;
        *)
            journalctl -u "${SB_SERVICE}" --no-pager -n 100
            ;;
    esac
}

modify_config() {
    [[ -f "${CONFIG_FILE}" ]] || {
        warn "尚未安装。"
        return
    }

    echo
    echo "修改项目："
    echo "1. 修改域名"
    echo "2. 重新生成所有随机密码"
    echo "3. 重新申请证书"
    echo "4. 编辑 sing-box 配置"
    echo "0. 返回"
    echo

    read -rp "选择： " choice

    case "${choice}" in
        1)
            prompt_domain
            resolve_domain "$(get_domain)"
            issue_certificate
            write_config
            save_client_configs
            check_config
            restart_service
            ;;

        2)
            generate_passwords
            write_config
            save_client_configs
            check_config
            restart_service
            ;;

        3)
            issue_certificate
            restart_service
            ;;

        4)
            if command -v nano >/dev/null 2>&1; then
                nano "${CONFIG_FILE}"
            else
                vi "${CONFIG_FILE}"
            fi

            if check_config; then
                restart_service
            else
                warn "配置错误，未重启服务。"
            fi
            ;;

        0)
            return
            ;;

        *)
            warn "无效选择。"
            ;;
    esac
}

uninstall() {
    echo
    echo "============================================================"
    echo " 卸载"
    echo "============================================================"
    echo
    warn "这将停止并删除 sing-box、配置、密码以及本脚本生成的数据。"
    warn "Let's Encrypt 证书也可以选择删除。"
    echo

    read -rp "确认卸载？请输入 REMOVE： " answer

    [[ "${answer}" == "REMOVE" ]] || {
        warn "已取消。"
        return
    }

    backup_all

    systemctl disable --now "${SB_SERVICE}" 2>/dev/null || true

    rm -f "${CERTBOT_HOOK}"

    if command -v certbot >/dev/null 2>&1 && [[ -f "${DOMAIN_FILE}" ]]; then
        local domain
        domain="$(get_domain)"

        certbot delete \
            --cert-name "${domain}" \
            --non-interactive 2>/dev/null || true
    fi

    rm -rf "${CONFIG_DIR}"
    rm -rf "${DATA_DIR}"

    apt-get remove -y sing-box 2>/dev/null || true

    rm -f /etc/apt/sources.list.d/sagernet.sources
    rm -f /etc/apt/keyrings/sagernet.asc

    systemctl daemon-reload

    log "卸载完成。"
    log "备份保存在：${BACKUP_DIR}"
}

install_all() {
    check_os
    install_dependencies
    install_singbox
    detect_network
    prompt_domain
    resolve_domain "$(get_domain)"
    generate_passwords
    configure_firewall
    issue_certificate
    write_config

    if ! check_config; then
        die "sing-box 配置检查失败，请检查配置。"
    fi

    setup_systemd
    setup_cert_renewal
    save_client_configs

    check_ports

    echo
    log "安装完成。"
    show_info
}

main_menu() {
    while true; do
        clear

        echo "============================================================"
        echo " Debian 13 sing-box"
        echo " Hysteria2 + Salamander / AnyTLS"
        echo " UDP/443 + TCP/443"
        echo "============================================================"
        echo

        if [[ -f "${CONFIG_FILE}" ]]; then
            if systemctl is-active --quiet "${SB_SERVICE}" 2>/dev/null; then
                echo -e "状态：${GREEN}运行中${RESET}"
            else
                echo -e "状态：${RED}未运行${RESET}"
            fi
        else
            echo -e "状态：${YELLOW}未安装${RESET}"
        fi

        echo
        echo "1. 安装 / 更新"
        echo "2. 查看信息"
        echo "3. 查看客户端 URI / 配置"
        echo "4. 检查 sing-box 配置"
        echo "5. 检查 TCP/443 + UDP/443"
        echo "6. 重启 sing-box"
        echo "7. 查看日志"
        echo "8. 修改配置"
        echo "9. 一键备份"
        echo "10. 一键卸载"
        echo "0. 退出"
        echo

        read -rp "请选择： " choice

        case "${choice}" in
            1)
                install_all
                pause
                ;;

            2)
                show_info
                pause
                ;;

            3)
                show_client_configs
                pause
                ;;

            4)
                check_config
                pause
                ;;

            5)
                check_ports
                pause
                ;;

            6)
                restart_service
                pause
                ;;

            7)
                show_logs
                ;;

            8)
                modify_config
                pause
                ;;

            9)
                backup_all
                pause
                ;;

            10)
                uninstall
                pause
                ;;

            0)
                exit 0
                ;;

            *)
                warn "无效选择。"
                sleep 1
                ;;
        esac
    done
}

require_root
check_os
main_menu

