# Shadowsocks 2022 一键部署脚本

基于 **shadowsocks-rust** 的 Shadowsocks 2022 一键部署方案，使用 `2022-blake3-aes-128-gcm` 加密协议。

## 特性

- 自动下载安装最新版 shadowsocks-rust（支持 x86_64 / ARM64）
- 使用 SS2022 (`2022-blake3-aes-128-gcm`) 加密，带完整重放保护
- TCP + UDP 双模式
- BBR 拥塞控制 + TCP Fast Open 网络优化
- 自动配置防火墙（ufw / firewalld）
- systemd 托管，开机自启、崩溃自动重启
- 部署完成输出 SS URI，可直接导入客户端

## 系统要求

- Ubuntu 20.04+ / Debian 11+
- root 权限

## 使用方法

### 一键安装

```bash
# 默认端口 8388
bash ss2022-deploy.sh

# 自定义端口
SS_PORT=12345 bash ss2022-deploy.sh
```

### 卸载

```bash
bash ss2022-deploy.sh uninstall
```

## 部署后管理

```bash
# 查看状态
systemctl status shadowsocks-rust

# 重启服务
systemctl restart shadowsocks-rust

# 查看日志
journalctl -u shadowsocks-rust -f

# 查看配置
cat /etc/shadowsocks-rust/config.json
```

## 客户端推荐

| 平台 | 客户端 |
|------|--------|
| iOS | Shadowrocket / Stash |
| Android | v2rayNG / SagerNet |
| Windows | v2rayN / Clash Verge |
| macOS | ClashX Pro / Surge |
| Linux | clash-meta |

## 协议说明

SS2022 (`2022-blake3-aes-128-gcm`) 相比旧版 `aes-128-gcm` 的改进：

- 基于时间戳的重放保护
- 无效请求静默关闭连接，防主动探测
- Blake3 密钥派生，更快更安全
- 协议层面解决安全问题，无需额外 HTTP 伪装
