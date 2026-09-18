#!/usr/bin/env bash
# ============================================================
# 官方 "without being stolen" 防盗结构
# BBR + fq systemd
# 自动生成 UUID / X25519 / ShortID
#
# 默认：
#   TCP 443
#   REALITY SNI = www.bing.com
#   REALITY fallback = 127.0.0.1:4431
# ============================================================
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
# ------------------------------------------------------------
# 交互式参数
# ------------------------------------------------------------

DEFAULT_SLNAME="${SLNAME:-$DEFAULT_SLNAME}"

# ------------------------------------------------------------
# 基本参数
# ------------------------------------------------------------

XRAY_DIR="/usr/local/etc/xray"
CONFIG="${XRAY_DIR}/config.json"
INFO="/root/client.txt"
BACKUP_DIR="${XRAY_DIR}/backup"
SLNAME="v-vr-xpro"

REALITY_PORT="4431"
XRAY_PORT="443"

# 官方防盗示例使用的目标
REALITY_SNI="www.bing.com"
REALITY_DEST="127.0.0.1:${REALITY_PORT}"

# ------------------------------------------------------------
# 颜色
# ------------------------------------------------------------

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[36m'
RESET='\033[0m'

ok() {
    echo -e "${GREEN}[OK]${RESET} $*"
}
info() {
    echo -e "${CYAN}[INFO]${RESET} $*"
}
warn() {
    echo -e "${YELLOW}[WARN]${RESET} $*"
}
die() {
    echo -e "${RED}[ERROR]${RESET} $*"
    exit 1
}

# ------------------------------------------------------------
# 错误处理
# ------------------------------------------------------------

trap '
echo
echo -e "${RED}[ERROR] 安装过程中发生错误${RESET}"
echo "行号: ${LINENO}"
echo "命令: ${BASH_COMMAND}"
echo
exit 1
' ERR

# ------------------------------------------------------------
# 安装 / 更新
# ------------------------------------------------------------

install_or_update() {
# ------------------------------------------------------------
# Root
# ------------------------------------------------------------

if [[ "${EUID}" != "0" ]]; then
    die "请使用 root 用户运行此脚本"
fi

# ------------------------------------------------------------
# Debian 检查
# ------------------------------------------------------------

if [[ ! -f /etc/os-release ]]; then
    die "无法识别系统"
fi

source /etc/os-release

if [[ "${ID}" != "debian" ]]; then
    die "此脚本仅针对 Debian"
fi

if [[ "${VERSION_ID}" != "13" ]]; then
    warn "当前系统不是 Debian 13"
    warn "检测到：${PRETTY_NAME}"

    read -rp "仍然继续？[y/N] " answer

    if [[ ! "${answer}" =~ ^[Yy]$ ]]; then
        exit 0
    fi
fi

ok "系统：${PRETTY_NAME}"

# ------------------------------------------------------------
# CPU
# ------------------------------------------------------------

ARCH="$(uname -m)"

case "${ARCH}" in
    x86_64|amd64)
        ok "CPU：x86_64"
        ;;
    aarch64|arm64)
        ok "CPU：arm64"
        ;;
    *)
        die "暂不支持 CPU 架构：${ARCH}"
        ;;
esac

# ------------------------------------------------------------
# 安装基础依赖
# ------------------------------------------------------------

info "安装基础依赖..."

apt-get update -qq

apt-get install -y \
    --no-install-recommends \
    curl \
    ca-certificates \
    openssl \
    iproute2 \
    procps \
    >/dev/null

ok "基础依赖安装完成"

# ------------------------------------------------------------
# 检查 systemd
# ------------------------------------------------------------

if ! command -v systemctl >/dev/null 2>&1; then
    die "系统没有 systemd"
fi

ok "systemd 可用"

# ------------------------------------------------------------
# 检查端口
# ------------------------------------------------------------

if ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:)443$|\]:443$'; then

    warn "TCP 443 当前已经被占用："
    ss -lntp 2>/dev/null | grep -E '(:443[[:space:]]|]:443[[:space:]])' || true
    read -rp "是否继续？[y/N] " answer
    if [[ ! "${answer}" =~ ^[Yy]$ ]]; then
        exit 0
    fi
fi

if ss -lnt 2>/dev/null | awk '{print $4}' | grep -Eq '(^|:)4431$|\]:4431$'; then
    die "TCP 4431 已经被占用"
fi

# ------------------------------------------------------------
# 获取公网 IPv4
# ------------------------------------------------------------

info "检测公网 IPv4..."

SERVER_IP=""

for api in \
    "https://api.ipify.org" \
    "https://ifconfig.me/ip" \
    "https://ipv4.icanhazip.com"
do
    SERVER_IP="$(curl -4 -fsSL --connect-timeout 5 --max-time 8 "${api}" 2>/dev/null || true)"

    if [[ -n "${SERVER_IP}" ]]; then
        break
    fi
done

if [[ -z "${SERVER_IP}" ]]; then
    SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')"
fi

if [[ -z "${SERVER_IP}" ]]; then
    die "无法获取服务器 IPv4"
fi

ok "公网 IPv4：${SERVER_IP}"

# ------------------------------------------------------------
# 安装 Xray
#
# 官方安装器：
# --without-geodata \
# --without-logfiles \
# -install-user nobody
# ------------------------------------------------------------

info "安装 Xray-core..."

INSTALL_SCRIPT="/tmp/xray-install.sh"

curl -fsSL \
    https://github.com/XTLS/Xray-install/raw/main/install-release.sh \
    -o "${INSTALL_SCRIPT}"

chmod 700 "${INSTALL_SCRIPT}"

bash "${INSTALL_SCRIPT}" install

rm -f "${INSTALL_SCRIPT}"

if [[ ! -x /usr/local/bin/xray ]]; then
    die "Xray 安装失败"
fi

XRAY_VERSION="$(/usr/local/bin/xray version 2>/dev/null | head -n 1)" || XRAY_VERSION="NULL"
echo $XRAY_VERSION

# ------------------------------------------------------------
# 创建目录
# ------------------------------------------------------------

mkdir -p "${XRAY_DIR}"
mkdir -p "${BACKUP_DIR}"
chmod 755 "${XRAY_DIR}"
chown nobody:nogroup "${CONFIG}"

# ------------------------------------------------------------
# 备份旧配置
# ------------------------------------------------------------

if [[ -f "${CONFIG}" ]]; then

    BACKUP_FILE="${BACKUP_DIR}/config-$(date '+%Y%m%d-%H%M%S').json"
    cp -a "${CONFIG}" "${BACKUP_FILE}"
    ok "旧配置已备份：${BACKUP_FILE}"
fi

# ------------------------------------------------------------
# 生成 UUID
# ------------------------------------------------------------

UUID="$(/usr/local/bin/xray uuid)"

if [[ -z "${UUID}" ]]; then
    die "UUID 生成失败"
fi

ok "UUID 已生成"

# ------------------------------------------------------------
# 生成 REALITY X25519
# ------------------------------------------------------------

X25519_OUTPUT="$(/usr/local/bin/xray x25519)"

PRIVATE_KEY="$(echo "${X25519_OUTPUT}" | grep -i "PrivateKey" | awk -F ': ' '{print $2}' | tr -d '\r ')"
PUBLIC_KEY="$(echo "${X25519_OUTPUT}" | grep -i "PublicKey" | awk -F ': ' '{print $2}' | tr -d '\r ')"
echo $PRIVATE_KEY
echo $PUBLIC_KEY
# 某些版本输出格式可能不同
if [[ -z "${PUBLIC_KEY}" ]]; then
    PUBLIC_KEY="$(echo "${X25519_OUTPUT}" \
        | awk -F ': ' '/PublicKey:/ {print $2}' \
        | tr -d '\r')"
fi

if [[ -z "${PRIVATE_KEY}" || -z "${PUBLIC_KEY}" ]]; then
    echo "${X25519_OUTPUT}"
    die "REALITY X25519 密钥生成失败"
fi

ok "REALITY X25519 密钥已生成"

# ------------------------------------------------------------
# Short ID
# 16 位十六进制
# ------------------------------------------------------------

SHORT_ID="$(openssl rand -hex 8)"

if [[ -z "${SHORT_ID}" ]]; then
    die "ShortID 生成失败"
fi
ok "ShortID：${SHORT_ID}"

# ------------------------------------------------------------
# 生成 Xray 配置
# ------------------------------------------------------------

cat > "${CONFIG}" <<EOF
{
  "log": {
    "loglevel": "warning"
  },

  "inbounds": [
    {
      "listen": "127.0.0.1",
      "port": ${REALITY_PORT},
      "protocol": "dokodemo-door",
      "settings": {
        "address": "${REALITY_SNI}",
        "port": 443,
        "network": "tcp"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls",
          "quic"
        ],
        "routeOnly": true
      },
      "tag": "dokodemo-in"
    },
    {
      "listen": "0.0.0.0",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "email": "xpro",
			"id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${REALITY_DEST}",
          "xver": 0,
          "maxClientVer": "",
          "minClientVer": "1.0.0",
          "serverNames": [
            "${REALITY_SNI}"
          ],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "tls"
        ],
        "routeOnly": true
      },
      "tag": "vless-reality"
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "inboundTag": [
          "dokodemo-in"
        ],
        "domain": [
          "full:${REALITY_SNI}"
        ],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "inboundTag": [
          "dokodemo-in"
        ],
        "outboundTag": "block"
      }
    ]
  }
}
EOF

chmod 600 "${CONFIG}"

ok "Xray 配置生成完成"

# ------------------------------------------------------------
# 配置 BBR
# ------------------------------------------------------------

info "配置 BBR..."

cat > /etc/sysctl.d/99-xray-bbr.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

sysctl --system >/dev/null 2>&1 || true

BBR="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
QDISC="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"

ok "TCP congestion control：${BBR}"
ok "Default qdisc：${QDISC}"

# ------------------------------------------------------------
# 检查 BBR 模块
# ------------------------------------------------------------

if [[ "${BBR}" != "bbr" ]]; then

    warn "当前内核没有成功启用 BBR"

    if modprobe bbr 2>/dev/null; then

        sysctl -w \
            net.ipv4.tcp_congestion_control=bbr \
            >/dev/null 2>&1 || true
        BBR="$(sysctl -n \
            net.ipv4.tcp_congestion_control \
            2>/dev/null || true)"
    fi
fi

# ------------------------------------------------------------
# Xray 配置测试
# ------------------------------------------------------------

info "检查 Xray 配置..."

if ! /usr/local/bin/xray run \
    -test \
    -config "${CONFIG}"
then

    die "Xray 配置检查失败"
fi

ok "Xray 配置检查通过"

# ------------------------------------------------------------
# systemd 服务
#
# 官方安装脚本已经创建 xray.service
# 这里确保：
#   User=nobody
#   自动启动
# ------------------------------------------------------------

if [[ -f /etc/systemd/system/xray.service ]]; then

    if ! grep -q '^User=nobody' \
        /etc/systemd/system/xray.service
    then
        warn "当前 systemd Xray 服务不是 nobody"
    fi
fi

systemctl daemon-reload
systemctl enable xray >/dev/null
systemctl restart xray

sleep 2

if ! systemctl is-active --quiet xray; then
    echo
    echo "================ Xray 日志 ================"
    journalctl \
        -u xray \
        --no-pager \
        -n 80
    echo "============================================"
    die "Xray 启动失败"
fi
ok "Xray systemd 服务运行正常"

# ------------------------------------------------------------
# 防火墙
# ------------------------------------------------------------

if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -q \
        "Status: active"
    then
        info "检测到 UFW"
        ufw allow 443/tcp >/dev/null 2>&1 || true
        ok "UFW 已允许 TCP 443"
    fi
fi


while true; do
    echo -e "请输入配置名"
    read -r config_subName
    
    # -z 检查变量是否为空（长度为0）
    if [ -z "$config_subName" ]; then
        echo -e "\033[31m错误：配置名不能为空，请重新输入！\033[0m\n"
    else
        # 输入不为空，跳出循环
        break
    fi
done

# 输出并显示结果
echo -e "您输入的配置名是: \033[32m$config_subName\033[0m"

# ------------------------------------------------------------
# 生成 VLESS URI
# ------------------------------------------------------------

VLESS_URI="vless://${UUID}@${SERVER_IP}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&type=tcp#${config_subName}"

# ------------------------------------------------------------
# 保存客户端信息
# ------------------------------------------------------------

cat > "${INFO}" <<EOF
============================================================
Debian 13
Xray-core
VLESS + XTLS Vision + REALITY
Official "without being stolen" structure
============================================================

Server IP:${SERVER_IP}
Port:${XRAY_PORT}
Protocol:VLESS
Flow:xtls-rprx-vision
Network:TCP
Security:REALITY
SNI:${REALITY_SNI}
Fingerprint:chrome
UUID:${UUID}
PrivateKey:${PRIVATE_KEY}
PublicKey:${PUBLIC_KEY}
ShortID:${SHORT_ID}
REALITY fallback:127.0.0.1:${REALITY_PORT}
BBR:${BBR}
QDISC${QDISC}

============================================================
VLESS URI
============================================================

${VLESS_URI}

============================================================

IMPORTANT

PrivateKey 只保存在服务器。
客户端使用 PublicKey。

============================================================
EOF

chmod 600 "${INFO}"

# ------------------------------------------------------------
# 最终检查
# ------------------------------------------------------------

echo
info "执行最终检查..."

echo
echo "Xray："
systemctl is-active xray

echo
echo "监听端口："
ss -lntp | grep -E '(:443 |:4431 )' || true

echo
echo "BBR："
sysctl net.ipv4.tcp_congestion_control

echo
echo "QDISC："
sysctl net.core.default_qdisc

    echo
    echo "安装/更新流程已完成。"
}

# ------------------------------------------------------------
# 管理菜单
# ------------------------------------------------------------

show_info() {
    echo
    echo "================ Xray 信息 ================"
    if [[ -f "${INFO}" ]]; then
        cat "${INFO}"
    else
        echo "客户端信息文件不存在：${INFO}"
    fi
    echo
    echo "服务状态："
    systemctl status xray --no-pager -l 2>/dev/null || true
    echo "============================================"
}

restart_xray() {
    echo
    systemctl restart xray
    sleep 1
    if systemctl is-active --quiet xray; then
        ok "Xray 已重启并正在运行"
    else
        warn "Xray 重启后未正常运行，最近日志："
        journalctl -u xray --no-pager -n 50
        return 1
    fi
}

show_logs() {
    echo
    echo "显示最近 100 条 Xray 日志。按 Ctrl+C 退出。"
    journalctl -u xray --no-pager -n 100
}

edit_config() {
    if [[ ! -f "${CONFIG}" ]]; then
        warn "配置文件不存在：${CONFIG}"
        return 1
    fi

    if command -v nano >/dev/null 2>&1; then
        nano "${CONFIG}"
    elif command -v vi >/dev/null 2>&1; then
        vi "${CONFIG}"
    else
        die "未找到 nano 或 vi"
    fi

    echo
    info "检查配置..."
    if /usr/local/bin/xray run -test -config "${CONFIG}"; then
        ok "配置检查通过"
        systemctl restart xray
        sleep 1
        systemctl is-active --quiet xray && ok "Xray 已应用新配置" || warn "Xray 未正常运行，请查看日志"
    else
        warn "配置检查失败，未应用新配置"
    fi
}

change_slname() {
    local new_name
    read -rp "输入新的 SLNAME [${SLNAME}]: " new_name
    new_name="${new_name:-$SLNAME}"

    if [[ ! "${new_name}" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
        warn "SLNAME 只能包含字母、数字、点、下划线和连字符，长度 1-64"
        return 1
    fi

    SLNAME="${new_name}"

    # Update only the fragment after # in the saved URI, if available.
    if [[ -f "${INFO}" ]]; then
        local uuid server_ip public_key short_id
        uuid="$(grep '^UUID:' "${INFO}" | cut -d: -f2- | xargs || true)"
        server_ip="$(grep '^Server IP:' "${INFO}" | cut -d: -f2- | xargs || true)"
        public_key="$(grep '^PublicKey:' "${INFO}" | cut -d: -f2- | xargs || true)"
        short_id="$(grep '^ShortID:' "${INFO}" | cut -d: -f2- | xargs || true)"
        if [[ -n "${uuid}" && -n "${server_ip}" && -n "${public_key}" && -n "${short_id}" ]]; then
            local uri
            uri="vless://${uuid}@${server_ip}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SNI}&fp=chrome&pbk=${public_key}&sid=${short_id}&type=tcp#${SLNAME}"
            # Replace the URI line immediately following the VLESS URI heading.
            awk -v uri="${uri}" '
                /VLESS URI/ {print; getline; while ($0 ~ /^[[:space:]]*$/) {print; getline}; print uri; next}
                {print}
            ' "${INFO}" > "${INFO}.tmp" && mv "${INFO}.tmp" "${INFO}"
            chmod 600 "${INFO}"
        fi
    fi

    ok "SLNAME 已设置为：${SLNAME}"
}

menu() {
    if [[ "${EUID}" != "0" ]]; then
        die "请使用 root 用户运行此脚本"
    fi

    while true; do
        echo
        echo "============================================================"
        echo "        VLESS + REALITY Xray 管理菜单"
        echo "============================================================"
        echo "当前 SLNAME：${SLNAME}"
        echo
        echo "  1) 安装 / 更新 Xray"
        echo "  2) 重启 Xray"
        echo "  3) 修改 Xray 配置"
        echo "  4) 查看服务器 / 客户端信息"
        echo "  5) 查看 Xray 日志"
        echo "  6) 修改 SLNAME"
        echo "  7) 查看服务状态"
        echo "  0) 退出"
        echo "============================================================"
        read -rp "请选择 [0-7]: " choice

        case "${choice}" in
            1)
                read -rp "SLNAME [${SLNAME}]: " input_name
                if [[ -n "${input_name}" ]]; then
                    if [[ "${input_name}" =~ ^[A-Za-z0-9._-]{1,64}$ ]]; then
                        SLNAME="${input_name}"
                    else
                        warn "SLNAME 格式无效，使用当前值：${SLNAME}"
                    fi
                fi
                install_or_update
                ;;
            2) restart_xray ;;
            3) edit_config ;;
            4) show_info ;;
            5) show_logs ;;
            6) change_slname ;;
            7)
                echo
                systemctl status xray --no-pager -l 2>/dev/null || true
                ;;
            0)
                echo "已退出。"
                exit 0
                ;;
            *) warn "无效选项，请输入 0-7" ;;
        esac

        echo
        read -rp "按 Enter 返回菜单..." _
    done
}

menu

# 以下内容保留为安装函数主体的原始完成输出（不可达，仅作为历史参考）
# ------------------------------------------------------------
# 完成
# ------------------------------------------------------------

echo
echo "============================================================"
echo -e "${GREEN}      Debian 13 VLESS + REALITY 安装完成${RESET}"
echo "============================================================"
echo
echo "服务器 IP："
echo "  ${SERVER_IP}"
echo
echo "端口："
echo "  443/TCP"
echo
echo "协议："
echo "  VLESS"
echo
echo "Flow："
echo "  xtls-rprx-vision"
echo
echo "REALITY SNI："
echo "  ${REALITY_SNI}"
echo
echo "Fingerprint："
echo "  chrome"
echo
echo "UUID："
echo "  ${UUID}"
echo
echo "PublicKey："
echo "  ${PUBLIC_KEY}"
echo
echo "ShortID："
echo "  ${SHORT_ID}"
echo
echo "BBR："
echo "  ${BBR}"
echo
echo "============================================================"
echo "客户端 VLESS 链接："
echo
echo "${VLESS_URI}"
echo
echo "============================================================"
echo
echo "客户端参数保存在："
echo
echo "  ${INFO}"
echo
echo "服务器配置："
echo
echo "  ${CONFIG}"
echo
echo "服务管理："
echo
echo "  systemctl status xray"
echo "  systemctl restart xray"
echo "  systemctl stop xray"
echo "  journalctl -u xray -f"
echo
echo "============================================================"
echo -e "${GREEN}安装完成${RESET}"
echo "============================================================"