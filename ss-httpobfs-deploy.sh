#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  Shadowsocks + HTTP 伪装 一键部署脚本 (Xray-core)
#  适用系统: Ubuntu 20.04+ / Debian 11+
#  协议:     Shadowsocks aes-128-gcm + TCP HTTP 伪装
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

SS_PORT="${SS_PORT:-13101}"
SS_METHOD="aes-128-gcm"
OBFS_HOST="${OBFS_HOST:-e5481fec62d1.microsoft.com}"
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_SERVICE="xray"

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }

check_root() {
    [[ $EUID -eq 0 ]] || err "请以 root 权限运行: sudo bash $0"
}

check_os() {
    if ! grep -qiE 'ubuntu|debian' /etc/os-release 2>/dev/null; then
        warn "此脚本针对 Ubuntu/Debian 设计，其他发行版可能需要调整"
    fi
}

get_public_ip() {
    local ip
    ip=$(curl -4s --connect-timeout 5 https://ifconfig.me 2>/dev/null \
      || curl -4s --connect-timeout 5 https://api.ipify.org 2>/dev/null \
      || curl -4s --connect-timeout 5 https://icanhazip.com 2>/dev/null)
    echo "${ip:-<无法获取，请手动填写>}"
}

install_deps() {
    log "更新包管理器..."
    apt-get update -qq
    apt-get install -y -qq curl wget unzip jq > /dev/null 2>&1
}

install_xray() {
    if [[ -f "$XRAY_BIN" ]]; then
        local ver
        ver=$("$XRAY_BIN" version 2>/dev/null | head -1)
        log "已安装: $ver"
        return 0
    fi

    log "安装 Xray-core..."
    bash -c "$(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    [[ -f "$XRAY_BIN" ]] || err "Xray 安装失败"
    log "安装完成: $("$XRAY_BIN" version | head -1)"
}

generate_password() {
    openssl rand -hex 8
}

create_config() {
    SS_PASSWORD=$(generate_password)

    mkdir -p "$(dirname "$XRAY_CONFIG")"

    cat > "$XRAY_CONFIG" <<CONF
{
    "log": {
        "loglevel": "warning"
    },
    "inbounds": [
        {
            "tag": "ss-in",
            "port": ${SS_PORT},
            "protocol": "shadowsocks",
            "settings": {
                "method": "${SS_METHOD}",
                "password": "${SS_PASSWORD}",
                "network": "tcp,udp"
            },
            "streamSettings": {
                "network": "tcp",
                "tcpSettings": {
                    "header": {
                        "type": "http",
                        "request": {
                            "version": "1.1",
                            "method": "GET",
                            "path": ["/"],
                            "headers": {
                                "Host": ["${OBFS_HOST}"],
                                "User-Agent": [
                                    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
                                ],
                                "Accept-Encoding": ["gzip, deflate"],
                                "Connection": ["keep-alive"],
                                "Pragma": "no-cache"
                            }
                        },
                        "response": {
                            "version": "1.1",
                            "status": "200",
                            "reason": "OK",
                            "headers": {
                                "Content-Type": ["application/octet-stream"],
                                "Transfer-Encoding": ["chunked"],
                                "Connection": ["keep-alive"],
                                "Pragma": "no-cache"
                            }
                        }
                    }
                }
            }
        }
    ],
    "outbounds": [
        {
            "tag": "direct",
            "protocol": "freedom"
        },
        {
            "tag": "block",
            "protocol": "blackhole"
        }
    ]
}
CONF
    chmod 644 "$XRAY_CONFIG"
    log "配置已写入 $XRAY_CONFIG"
}

setup_systemd() {
    systemctl daemon-reload
    systemctl enable ${XRAY_SERVICE} 2>/dev/null || true
    systemctl restart ${XRAY_SERVICE}
    sleep 1
    if systemctl is-active --quiet ${XRAY_SERVICE}; then
        log "Xray 服务已启动并设为开机自启"
    else
        err "Xray 服务启动失败，请检查 journalctl -u ${XRAY_SERVICE}"
    fi
}

setup_firewall() {
    if command -v ufw &>/dev/null; then
        ufw allow "${SS_PORT}/tcp" > /dev/null 2>&1
        ufw allow "${SS_PORT}/udp" > /dev/null 2>&1
        log "ufw 已放行端口 ${SS_PORT}"
    elif command -v firewall-cmd &>/dev/null; then
        firewall-cmd --permanent --add-port="${SS_PORT}/tcp" > /dev/null 2>&1
        firewall-cmd --permanent --add-port="${SS_PORT}/udp" > /dev/null 2>&1
        firewall-cmd --reload > /dev/null 2>&1
        log "firewalld 已放行端口 ${SS_PORT}"
    else
        warn "未检测到防火墙，请手动确保端口 ${SS_PORT} 已开放"
    fi
}

optimize_sysctl() {
    local sysctl_conf="/etc/sysctl.d/99-xray-ss.conf"
    cat > "$sysctl_conf" <<'SYSCTL'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_max_syn_backlog = 8192
net.core.somaxconn = 4096
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
SYSCTL
    sysctl -p "$sysctl_conf" > /dev/null 2>&1
    log "网络优化已应用 (BBR + TCP Fast Open)"
}

show_result() {
    local password="$1"
    local ip
    ip=$(get_public_ip)

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Shadowsocks + HTTP 伪装 部署成功${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  服务器:     ${GREEN}${ip}${NC}"
    echo -e "  端口:       ${GREEN}${SS_PORT}${NC}"
    echo -e "  密码:       ${GREEN}${password}${NC}"
    echo -e "  加密方式:   ${GREEN}${SS_METHOD}${NC}"
    echo -e "  传输协议:   ${GREEN}tcp${NC}"
    echo -e "  伪装类型:   ${GREEN}http${NC}"
    echo -e "  伪装域名:   ${GREEN}${OBFS_HOST}${NC}"
    echo ""
    echo -e "  ${YELLOW}v2rayN 手动配置:${NC}"
    echo -e "    协议: Shadowsocks"
    echo -e "    地址: ${ip}"
    echo -e "    端口: ${SS_PORT}"
    echo -e "    密码: ${password}"
    echo -e "    加密: ${SS_METHOD}"
    echo -e "    传输协议: tcp"
    echo -e "    伪装类型: http"
    echo -e "    伪装域名: ${OBFS_HOST}"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
    echo -e "  管理命令:"
    echo -e "    状态:   systemctl status ${XRAY_SERVICE}"
    echo -e "    重启:   systemctl restart ${XRAY_SERVICE}"
    echo -e "    日志:   journalctl -u ${XRAY_SERVICE} -f"
    echo -e "    配置:   cat ${XRAY_CONFIG}"
    echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
    echo ""
}

uninstall() {
    warn "开始卸载 Xray Shadowsocks..."
    systemctl stop ${XRAY_SERVICE} 2>/dev/null || true
    systemctl disable ${XRAY_SERVICE} 2>/dev/null || true
    rm -f /etc/systemd/system/${XRAY_SERVICE}.service
    rm -f "$XRAY_BIN"
    rm -rf /usr/local/etc/xray
    rm -rf /usr/local/share/xray
    rm -f /etc/sysctl.d/99-xray-ss.conf
    sysctl --system > /dev/null 2>&1
    systemctl daemon-reload
    log "卸载完成"
}

main() {
    echo ""
    echo -e "${CYAN}Shadowsocks + HTTP 伪装 一键部署脚本 (Xray-core)${NC}"
    echo -e "${CYAN}加密: ${SS_METHOD} | 伪装域名: ${OBFS_HOST}${NC}"
    echo ""

    case "${1:-install}" in
        uninstall|remove)
            check_root
            uninstall
            exit 0
            ;;
        install|*)
            check_root
            check_os
            install_deps
            install_xray
            create_config
            optimize_sysctl
            setup_firewall
            setup_systemd
            show_result "$SS_PASSWORD"
            ;;
    esac
}

main "$@"
