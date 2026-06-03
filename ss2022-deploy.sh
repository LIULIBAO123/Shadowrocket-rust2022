#!/usr/bin/env bash
set -euo pipefail

# ============================================================
#  Shadowsocks 2022 (shadowsocks-rust) 一键部署脚本
#  适用系统: Ubuntu 20.04+ / Debian 11+
#  协议:     2022-blake3-aes-128-gcm
# ============================================================

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

SS_PORT="${SS_PORT:-8388}"
SS_METHOD="2022-blake3-aes-128-gcm"
SS_BIN="/usr/local/bin/ssserver"
SS_CONFIG="/etc/shadowsocks-rust/config.json"
SS_SERVICE="shadowsocks-rust"

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
    apt-get install -y -qq curl wget tar jq > /dev/null 2>&1
}

install_ssrust() {
    if [[ -f "$SS_BIN" ]]; then
        local ver
        ver=$("$SS_BIN" --version 2>/dev/null | head -1)
        log "已安装: $ver"
        return 0
    fi

    log "获取 shadowsocks-rust 最新版本..."
    local latest_tag api_url download_url arch
    api_url="https://api.github.com/repos/shadowsocks/shadowsocks-rust/releases/latest"
    latest_tag=$(curl -sL "$api_url" | jq -r '.tag_name')
    [[ -n "$latest_tag" && "$latest_tag" != "null" ]] || err "无法获取最新版本号"

    arch=$(uname -m)
    case "$arch" in
        x86_64)  arch="x86_64-unknown-linux-gnu" ;;
        aarch64) arch="aarch64-unknown-linux-gnu" ;;
        *)       err "不支持的架构: $arch" ;;
    esac

    download_url="https://github.com/shadowsocks/shadowsocks-rust/releases/download/${latest_tag}/shadowsocks-${latest_tag}.${arch}.tar.xz"
    log "下载 shadowsocks-rust ${latest_tag} (${arch})..."

    local tmpdir
    tmpdir=$(mktemp -d)
    trap "rm -rf $tmpdir" EXIT

    wget -qO "$tmpdir/ss.tar.xz" "$download_url" || err "下载失败"
    tar -xJf "$tmpdir/ss.tar.xz" -C "$tmpdir"
    install -m 755 "$tmpdir/ssserver" "$SS_BIN"
    install -m 755 "$tmpdir/sslocal"  "/usr/local/bin/sslocal" 2>/dev/null || true

    log "安装完成: $("$SS_BIN" --version | head -1)"
}

generate_key() {
    openssl rand -base64 16
}

create_config() {
    local key
    key=$(generate_key)

    mkdir -p "$(dirname "$SS_CONFIG")"

    cat > "$SS_CONFIG" <<CONF
{
    "server": "0.0.0.0",
    "server_port": ${SS_PORT},
    "password": "${key}",
    "method": "${SS_METHOD}",
    "fast_open": true,
    "mode": "tcp_and_udp",
    "timeout": 300,
    "no_delay": true
}
CONF
    chmod 600 "$SS_CONFIG"
    log "配置已写入 $SS_CONFIG"
    echo "$key"
}

setup_systemd() {
    cat > /etc/systemd/system/${SS_SERVICE}.service <<EOF
[Unit]
Description=Shadowsocks-Rust Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SS_BIN} -c ${SS_CONFIG}
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now ${SS_SERVICE}
    log "systemd 服务已启动并设为开机自启"
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
    local sysctl_conf="/etc/sysctl.d/99-shadowsocks.conf"
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
    local key="$1"
    local ip
    ip=$(get_public_ip)

    local ss_uri_raw="${SS_METHOD}:${key}@${ip}:${SS_PORT}"
    local ss_uri="ss://$(echo -n "$ss_uri_raw" | base64 -w0)#SS2022-TW"

    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
    echo -e "${CYAN}  Shadowsocks 2022 部署成功${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
    echo ""
    echo -e "  服务器:   ${GREEN}${ip}${NC}"
    echo -e "  端口:     ${GREEN}${SS_PORT}${NC}"
    echo -e "  密码:     ${GREEN}${key}${NC}"
    echo -e "  加密方式: ${GREEN}${SS_METHOD}${NC}"
    echo -e "  模式:     ${GREEN}tcp_and_udp${NC}"
    echo ""
    echo -e "  ${YELLOW}SS URI (可直接导入客户端):${NC}"
    echo -e "  ${GREEN}${ss_uri}${NC}"
    echo ""
    echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
    echo -e "  管理命令:"
    echo -e "    状态:   systemctl status ${SS_SERVICE}"
    echo -e "    重启:   systemctl restart ${SS_SERVICE}"
    echo -e "    日志:   journalctl -u ${SS_SERVICE} -f"
    echo -e "    配置:   cat ${SS_CONFIG}"
    echo -e "${CYAN}═══════════════════════════════════════════════${NC}"
    echo ""
}

uninstall() {
    warn "开始卸载 shadowsocks-rust..."
    systemctl stop ${SS_SERVICE} 2>/dev/null || true
    systemctl disable ${SS_SERVICE} 2>/dev/null || true
    rm -f /etc/systemd/system/${SS_SERVICE}.service
    rm -f "$SS_BIN" /usr/local/bin/sslocal
    rm -rf /etc/shadowsocks-rust
    rm -f /etc/sysctl.d/99-shadowsocks.conf
    sysctl --system > /dev/null 2>&1
    systemctl daemon-reload
    log "卸载完成"
}

main() {
    echo ""
    echo -e "${CYAN}Shadowsocks 2022 一键部署脚本${NC}"
    echo -e "${CYAN}协议: ${SS_METHOD}${NC}"
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
            install_ssrust
            local key
            key=$(create_config)
            optimize_sysctl
            setup_firewall
            setup_systemd
            show_result "$key"
            ;;
    esac
}

main "$@"
