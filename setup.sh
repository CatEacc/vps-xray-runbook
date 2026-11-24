#!/bin/bash
# ==============================================================================
# 生产级 VPS 一键部署与调优脚本 (CatEacc/vps-xray-runbook)
# 适用系统: Debian 11/12/13, Ubuntu 20.04/22.04/24.04 (AMD64 / ARM64)
# 核心版本: 3x-ui v3.11.0 | Xray-core v26.11.9 | Hysteria 2 (Latest)
# 四套方案:
#   1) VLESS + REALITY (XHTTP / Vision，回车默认 443，内置一键家宽落地/一键中转)
#   2) Cloudflare CDN 优选 (VLESS + XHTTP + TLS，回车默认 2053)
#   3) Hysteria 2 + 20000-50000 端口跳跃 (错开端口防冲突，可选一键中转家宽)
#   4) 纯系统底层内核调优模式 (不装任何代理面板)
# ==============================================================================

set -euo pipefail
trap 'rm -rf /tmp/setup_result.txt /tmp/xray-install' EXIT

XUI_VERSION="v3.11.0"
XRAY_VERSION="v26.11.9"
XRAY_VER_NUM="26.11.9"

if [ "$(id -u)" != "0" ]; then
    echo "[错误] 必须以 root 用户运行此脚本！请先执行 sudo -i"
    exit 1
fi

SERVER_IP=$(curl -s4m 5 https://api.ipify.org || curl -s4m 5 https://ipv4.icanhazip.com || echo "YOUR_SERVER_IP")
OS_INFO=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-Linux}" || uname -s)
KERNEL_INFO=$(uname -r | cut -d'-' -f1)
ARCH_INFO=$(uname -m)
MEM_SHOW=$(free -m | awk '/Mem:/ {print $2}')
BBR_STAT=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
MPTCP_STAT=$(sysctl -n net.mptcp.enabled 2>/dev/null || echo "0")

# 256 色丝滑渐变配色（参考 Neofetch / 现代云终端美学，深蓝与纯黑终端均极度惊艳）
ESC="$(printf '\033')"
R="${ESC}[0m"
B="${ESC}[1m"
SKY="${ESC}[38;5;39m"
CYAN="${ESC}[38;5;51m"
GREEN="${ESC}[38;5;46m"
YELLOW="${ESC}[38;5;220m"
ORANGE="${ESC}[38;5;208m"
PINK="${ESC}[38;5;205m"
WHITE="${ESC}[1;97m"
DIM="${ESC}[38;5;245m"
NC="${R}"

print_cateacc_logo() {
    G1="${ESC}[38;5;46m"
    G2="${ESC}[38;5;82m"
    G3="${ESC}[38;5;118m"
    G4="${ESC}[38;5;226m"
    G5="${ESC}[38;5;220m"
    G6="${ESC}[38;5;208m"
    G7="${ESC}[38;5;199m"
    awk -v c1="$G1" -v c2="$G2" -v c3="$G3" -v c4="$G4" -v c5="$G5" -v c6="$G6" -v c7="$G7" -v rs="$R" -v bd="$B" '
    {
        line = $0
        while (length(line) < 42) line = line " "
        printf "  %s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n", \
            bd c1, substr(line, 1, 6), \
            c2, substr(line, 7, 6), \
            c3, substr(line, 13, 6), \
            c4, substr(line, 19, 6), \
            c5, substr(line, 25, 6), \
            c6, substr(line, 31, 6), \
            c7, substr(line, 37, 6), \
            rs
    }
    ' <<'BANNER'
   ______      __  ______               
  / ____/___ _/ /_/ ____/___ ___________
 / /   / __ `/ __/ __/ / __ `/ ___/ ___/
/ /___/ /_/ / /_/ /___/ /_/ / /__/ /__  
\____/\__,_/\__/_____/\__,_/\___/\___/  
BANNER
}

svc_badge() {
    if systemctl is-active --quiet "$1" 2>/dev/null; then
        printf "${GREEN}● 运行中${R}"
    elif systemctl list-unit-files 2>/dev/null | grep -q "^$1"; then
        printf "${YELLOW}● 已停止${R}"
    else
        printf "${DIM}○ 未安装${R}"
    fi
}

# ------------------------------------------------------------------------------
# 0. 四套方案交互菜单（也支持命令行传参: bash setup.sh [1|2|3|4]）
# ------------------------------------------------------------------------------
MODE="${1:-}"
if [ -z "$MODE" ]; then
    clear 2>/dev/null || true
    printf '\n'
    print_cateacc_logo
    printf '\n'
    printf "  ${CYAN}猫e/acc (CatEacc)${R} ${DIM}· VPS 生产级部署与调优脚本 ${YELLOW}v1.0${R}\n"
    printf "  ${GREEN}──────────────────────────────────────────────────────────${R}\n"
    printf "  ${SKY}OS:${R}       ${GREEN}${OS_INFO} (${ARCH_INFO})${R}\n"
    printf "  ${SKY}Kernel:${R}   ${GREEN}${KERNEL_INFO}${R}  ${DIM}|${R}  ${SKY}BBR:${R} ${GREEN}${BBR_STAT}${R}  ${DIM}|${R}  ${SKY}MPTCP:${R} ${GREEN}${MPTCP_STAT}${R}\n"
    printf "  ${SKY}Memory:${R}   ${GREEN}${MEM_SHOW} MB${R}  ${DIM}|${R}  ${SKY}IP:${R} ${CYAN}${SERVER_IP}${R}\n"
    printf "  ${SKY}Status:${R}   3x-ui $(svc_badge x-ui)  ${DIM}|${R}  Hy2 $(svc_badge hysteria-server)  ${DIM}|${R}  ${PINK}Xray ${XRAY_VERSION}${R}\n"
    printf "  ${SKY}GitHub:${R}   ${CYAN}https://github.com/CatEacc/vps-xray-runbook${R}\n"
    printf "  ${SKY}Channel:${R}  ${CYAN}https://t.me/CatCryptoMaster${R}\n"
    printf "  ${GREEN}──────────────────────────────────────────────────────────${R}\n\n"
    printf "  ${WHITE}请选择部署方案：${R}\n"
    printf "  ${GREEN}[1]${R} ${WHITE}VLESS + REALITY${R} ${CYAN}★ 推荐 · 支持一键家宽落地 / 一键中转${R}\n"
    printf "      ${DIM}对齐 Project X 规范 (XHTTP / raw+Vision)，回车默认 443 可自选端口${R}\n"
    printf "  ${GREEN}[2]${R} ${WHITE}Cloudflare CDN 优选${R} ${YELLOW}· VLESS + XHTTP + TLS${R}\n"
    printf "      ${DIM}隐藏源站真实 IP、晚高峰兜底，回车默认 2053 可自选回源端口${R}\n"
    printf "  ${GREEN}[3]${R} ${WHITE}Hysteria 2 + 端口跳跃${R} ${PINK}· UDP 20000-50000 · 可选中转家宽${R}\n"
    printf "      ${DIM}精品线 QUIC BBR / 廉价线 Brutal，默认 UDP 8443 错开 TCP 443${R}\n"
    printf "  ${GREEN}[4]${R} ${WHITE}纯系统底层内核调优模式${R} ${ORANGE}· 零代理面板${R}\n"
    printf "      ${DIM}仅部署 BBR / 按内存分档缓冲 / 1GB Swap / MPTCP 防护 / Fail2ban${R}\n"
    printf "  ${GREEN}[5]${R} ${WHITE}一键回滚系统底层调优${R} ${DIM}· 恢复原厂内核/日志/Swap 快照${R}\n\n"
    read -rp "$(printf "${YELLOW}  请输入方案编号 [1-5] (回车默认 1): ${R}")" MODE
    MODE="${MODE:-1}"
fi

# 通用变量初始化
LISTEN_PORT=""
REALITY_SUBMODE="1"   # 1=XHTTP+REALITY, 2=raw+Vision+REALITY, 3=家宽SS-2022落地
REALITY_SNI="addons.mozilla.org"
CF_DOMAIN="cf.example.com"
HY2_BRUTAL="n"
ENABLE_RELAY="n"
RES_IP=""
RES_PORT=""
RES_SS_PASS=""
RES_WHITELIST_IP=""

case "$MODE" in
    1)
        echo ""
        echo "  --- 方案 1 子模式选择 ---"
        echo "  1) VLESS + XHTTP + REALITY（RPRX 最新 H2/XMUX，适合新版 v2rayN/v2rayNG）"
        echo "  2) VLESS + raw + REALITY + Vision（全客户端通吃，极低延迟）"
        echo "  3) 设为【海外住宅家宽落地机】（随机高位端口 SS-2022，供优化机一键中转）"
        read -rp "请选择子模式 [1-3] (默认 1): " REALITY_SUBMODE
        REALITY_SUBMODE="${REALITY_SUBMODE:-1}"

        if [ "$REALITY_SUBMODE" = "3" ]; then
            DEF_PORT=$((20000 + RANDOM % 30000))
            read -rp "请输入家宽落地 SS-2022 监听端口 (回车默认随机高位端口 ${DEF_PORT}): " LISTEN_PORT
            LISTEN_PORT="${LISTEN_PORT:-$DEF_PORT}"
            read -rp "请输入允许连入的前置优化机 IP（留空则不设白名单，多个用逗号分隔）: " RES_WHITELIST_IP
        else
            read -rp "请输入 REALITY 监听端口 (回车默认 443，也可手动输入如 8443): " LISTEN_PORT
            LISTEN_PORT="${LISTEN_PORT:-443}"
            echo "  请选择 REALITY 回落目标域名 (SNI)："
            echo "    1) 本机自动测速优选最佳 SNI（★ 推荐：1 秒并发实测 TLS 1.3 + H2 + 最低延迟）"
            echo "    2) addons.mozilla.org      （免测默认：纯海外无国内 CDN）"
            echo "    3) dl.google.com           （RPRX 官方示例：支持握手加密）"
            echo "    4) 手动输入自定义域名      （输入后自动 1 秒体检 TLS 1.3 + H2）"
            read -rp "  请输入选项 [1-4] (回车默认 1): " SNI_OPT
            case "${SNI_OPT:-1}" in
                1)
                    if command -v python3 >/dev/null 2>&1; then
                        echo "  -> 正在从本机并发实测 16 个纯海外 TLS 1.3 + H2 目标站..."
                        SNI_LIST=$(python3 - << 'SNIPY'
import ssl, socket, time
from concurrent.futures import ThreadPoolExecutor
CANDIDATES = [
    "addons.mozilla.org", "dl.google.com", "www.cloudflare.com", "pkg.cloudflare.com",
    "www.debian.org", "www.hetzner.com", "www.digitalocean.com", "www.linode.com",
    "www.vultr.com", "www.amd.com", "www.nvidia.com", "www.oracle.com",
    "www.redhat.com", "www.sony.jp", "www.nintendo.co.jp", "www.lovelive-anime.jp"
]
def probe(host):
    ctx = ssl.create_default_context()
    ctx.set_alpn_protocols(["h2", "http/1.1"])
    t0 = time.monotonic()
    try:
        with socket.create_connection((host, 443), timeout=2.5) as sock:
            with ctx.wrap_socket(sock, server_hostname=host) as ss:
                if ss.version() == "TLSv1.3" and ss.selected_alpn_protocol() == "h2":
                    return ((time.monotonic() - t0) * 1000, host)
    except Exception:
        pass
    return None
with ThreadPoolExecutor(max_workers=16) as ex:
    res = sorted([r for r in ex.map(probe, CANDIDATES) if r])
for rtt, host in res[:5]:
    print(f"{host}|{rtt:.1f}")
SNIPY
)
                        if [ -n "$SNI_LIST" ]; then
                            idx=1
                            SNI_ARR=()
                            while IFS='|' read -r h rtt; do
                                [ -z "$h" ] && continue
                                SNI_ARR+=("$h")
                                printf "     %d) %-24s (%s ms | TLSv1.3 + h2)\n" "$idx" "$h" "$rtt"
                                idx=$((idx + 1))
                            done <<< "$SNI_LIST"
                            read -rp "  -> 请选择编号 [1-${#SNI_ARR[@]}] (回车默认 1): " PICK_IDX
                            PICK_IDX="${PICK_IDX:-1}"
                            if [[ "$PICK_IDX" =~ ^[0-9]+$ ]] && [ "$PICK_IDX" -ge 1 ] && [ "$PICK_IDX" -le "${#SNI_ARR[@]}" ]; then
                                REALITY_SNI="${SNI_ARR[$((PICK_IDX - 1))]}"
                            else
                                REALITY_SNI="${SNI_ARR[0]}"
                            fi
                            echo "  -> 已选定本机最优 SNI: ${REALITY_SNI}"
                        else
                            echo "  -> [提示] 测速未命中可用站点，自动回退 addons.mozilla.org"
                            REALITY_SNI="addons.mozilla.org"
                        fi
                    else
                        echo "  -> [提示] 当前环境尚未安装 python3，自动回退 addons.mozilla.org"
                        REALITY_SNI="addons.mozilla.org"
                    fi
                    ;;
                2) REALITY_SNI="addons.mozilla.org" ;;
                3) REALITY_SNI="dl.google.com" ;;
                4)
                    read -rp "  -> 请输入自定义目标域名 (如 www.example.com): " SNI_CUSTOM
                    REALITY_SNI="${SNI_CUSTOM:-addons.mozilla.org}"
                    if command -v python3 >/dev/null 2>&1; then
                        SNI_CHK=$(SNI_TEST="$REALITY_SNI" python3 - << 'CHKPY'
import os, ssl, socket, time
h = os.environ["SNI_TEST"].strip()
ctx = ssl.create_default_context()
ctx.set_alpn_protocols(["h2", "http/1.1"])
t0 = time.monotonic()
try:
    with socket.create_connection((h, 443), timeout=3.0) as sock:
        with ctx.wrap_socket(sock, server_hostname=h) as ss:
            rtt = (time.monotonic() - t0) * 1000
            ver, alpn = ss.version(), ss.selected_alpn_protocol()
            if ver == "TLSv1.3" and alpn == "h2":
                print(f"OK|{ver} + {alpn} ({rtt:.1f} ms)")
            else:
                print(f"WARN|{ver} / ALPN={alpn}")
except Exception as e:
    print(f"WARN|{e}")
CHKPY
)
                        if [[ "$SNI_CHK" == OK\|* ]]; then
                            echo "  -> [体检通过] ${REALITY_SNI}: ${SNI_CHK#OK|}"
                        else
                            echo "  -> [体检警告] ${REALITY_SNI} 未满足 TLS 1.3 + h2 (${SNI_CHK#WARN|})"
                        fi
                    fi
                    ;;
                *) REALITY_SNI="addons.mozilla.org" ;;
            esac
            read -rp "是否一键中转到后端海外家宽机？[y/N]: " ENABLE_RELAY
            ENABLE_RELAY="${ENABLE_RELAY:-n}"
            if [[ "$ENABLE_RELAY" =~ ^[Yy]$ ]]; then
                read -rp "  -> 请输入后端家宽机 IP: " RES_IP
                read -rp "  -> 请输入后端家宽机 SS-2022 端口: " RES_PORT
                read -rp "  -> 请输入后端家宽机 SS-2022 密钥 (Base64): " RES_SS_PASS
            fi
        fi
        ;;
    2)
        read -rp "请输入 Cloudflare 回源端口 (回车默认 2053，支持 443/2053/2083/8443): " LISTEN_PORT
        LISTEN_PORT="${LISTEN_PORT:-2053}"
        read -rp "请输入 Cloudflare CDN 域名 (如 cf.example.com): " CF_IN
        CF_DOMAIN="${CF_IN:-cf.example.com}"
        ;;
    3)
        read -rp "请输入 Hysteria 2 本地 UDP 监听端口 (回车默认 8443 以错开 TCP 443，也可填 443): " LISTEN_PORT
        LISTEN_PORT="${LISTEN_PORT:-8443}"
        read -rp "是否为廉价高丢包线路开启 Brutal？(CN2/9929 精品线强烈选 n) [y/N]: " HY2_BRUTAL
        HY2_BRUTAL="${HY2_BRUTAL:-n}"
        read -rp "是否一键中转到后端海外家宽机？[y/N]: " ENABLE_RELAY
        ENABLE_RELAY="${ENABLE_RELAY:-n}"
        if [[ "$ENABLE_RELAY" =~ ^[Yy]$ ]]; then
            read -rp "  -> 请输入后端家宽机 IP: " RES_IP
            read -rp "  -> 请输入后端家宽机 SS-2022 端口: " RES_PORT
            read -rp "  -> 请输入后端家宽机 SS-2022 密钥 (Base64): " RES_SS_PASS
        fi
        ;;
    4)
        ;;
    5|rollback)
        BACKUP_DIR="/var/backups/vps-xray-tuning"
        echo ""
        printf "  ${YELLOW}即将撤销本脚本写入的底层内核/日志/Fail2ban/Swap 调优（不影响 3x-ui/Xray/Hy2 节点）。${R}\n"
        read -rp "确认执行一键回滚还原？[y/N]: " DO_RB
        if [[ ! "${DO_RB:-n}" =~ ^[Yy]$ ]]; then
            echo "  已取消回滚。"
            exit 0
        fi
        rm -f /etc/sysctl.d/99-zzz-proxy-tuning.conf /etc/modules-load.d/99-proxy.conf
        if [ -f "${BACKUP_DIR}/sysctl_orig.conf" ]; then
            while IFS='=' read -r k v; do
                [ -n "${k:-}" ] && sysctl -w "$(echo "$k" | xargs)=$(echo "$v" | xargs)" >/dev/null 2>&1 || true
            done < "${BACKUP_DIR}/sysctl_orig.conf"
        fi
        sysctl --system >/dev/null 2>&1 || true
        if [ -f "${BACKUP_DIR}/journald.conf.bak" ]; then
            cp -a "${BACKUP_DIR}/journald.conf.bak" /etc/systemd/journald.conf
            systemctl restart systemd-journald 2>/dev/null || true
        fi
        if [ -f "${BACKUP_DIR}/99-nofile.conf.bak" ]; then
            cp -a "${BACKUP_DIR}/99-nofile.conf.bak" /etc/security/limits.d/99-nofile.conf
        else
            rm -f /etc/security/limits.d/99-nofile.conf
        fi
        if [ -f "${BACKUP_DIR}/jail.local.bak" ]; then
            cp -a "${BACKUP_DIR}/jail.local.bak" /etc/fail2ban/jail.local
            systemctl restart fail2ban 2>/dev/null || true
        elif [ -f /etc/fail2ban/jail.local ] && [ -f "${BACKUP_DIR}/snapshot.done" ]; then
            rm -f /etc/fail2ban/jail.local
            systemctl restart fail2ban 2>/dev/null || true
        fi
        if [ -f "${BACKUP_DIR}/swap_created_by_script" ] && [ -f /swapfile ]; then
            swapoff /swapfile 2>/dev/null || true
            sed -i '\|/swapfile|d' /etc/fstab
            rm -f /swapfile "${BACKUP_DIR}/swap_created_by_script"
        fi
        echo "  [完成] 已恢复系统底层调优原厂快照 (拥塞控制: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo N/A))"
        exit 0
        ;;
    *)
        echo "[错误] 无效的方案编号: ${MODE}，仅支持 1 / 2 / 3 / 4 / 5"
        exit 1
        ;;
esac

# ------------------------------------------------------------------------------
# 阶段一：改前自动原厂快照 + 系统底层优化、Swap 兜底、日志收敛、Fail2ban 与高并发内核栈
# ------------------------------------------------------------------------------
BACKUP_DIR="/var/backups/vps-xray-tuning"
if [ ! -f "${BACKUP_DIR}/snapshot.done" ]; then
    (
        umask 077
        mkdir -p "$BACKUP_DIR"
        [ -f /etc/systemd/journald.conf ] && cp -a /etc/systemd/journald.conf "${BACKUP_DIR}/journald.conf.bak"
        [ -f /etc/fail2ban/jail.local ] && cp -a /etc/fail2ban/jail.local "${BACKUP_DIR}/jail.local.bak"
        [ -f /etc/security/limits.d/99-nofile.conf ] && cp -a /etc/security/limits.d/99-nofile.conf "${BACKUP_DIR}/99-nofile.conf.bak"
        : > "${BACKUP_DIR}/sysctl_orig.conf"
        for key in \
            net.core.default_qdisc net.ipv4.tcp_congestion_control net.mptcp.enabled \
            net.core.somaxconn net.core.netdev_max_backlog net.ipv4.tcp_max_syn_backlog \
            net.ipv4.ip_local_port_range net.ipv4.tcp_tw_reuse net.ipv4.tcp_fin_timeout \
            net.ipv4.tcp_keepalive_time net.ipv4.tcp_keepalive_intvl net.ipv4.tcp_keepalive_probes \
            net.ipv4.tcp_max_tw_buckets net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_mtu_probing \
            net.ipv4.tcp_no_metrics_save net.ipv4.tcp_ecn net.core.rmem_max net.core.wmem_max \
            net.core.rmem_default net.core.wmem_default net.ipv4.udp_rmem_min net.ipv4.udp_wmem_min \
            net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_fastopen net.ipv4.tcp_notsent_lowat \
            net.ipv4.tcp_adv_win_scale net.netfilter.nf_conntrack_max \
            net.netfilter.nf_conntrack_udp_timeout net.netfilter.nf_conntrack_udp_timeout_stream \
            net.ipv4.ip_forward fs.file-max vm.swappiness; do
            val=$(sysctl -n "$key" 2>/dev/null || true)
            if [ -n "$val" ]; then
                printf "%s = %s\n" "$key" "$(echo "$val" | tr '\t' ' ' | tr -s ' ')" >> "${BACKUP_DIR}/sysctl_orig.conf"
            fi
        done
        date -u +"%Y-%m-%dT%H:%M:%SZ" > "${BACKUP_DIR}/snapshot.done"
    )
    echo "[快照] 已自动保存原厂底层参数快照至 ${BACKUP_DIR}（随时可用模式 5 一键回滚）"
fi

echo "[1/5] 更新系统组件并安装基础依赖..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y && apt-get upgrade -y
apt-get install -y curl wget unzip chrony iptables nftables iptables-persistent sqlite3 fail2ban python3 python3-systemd openssl

echo "[2/5] 配置原子钟对时、1GB Swap 兜底、日志限额与 SSH/Fail2ban 加固..."
systemctl enable --now chrony
chronyc makestep || true
timedatectl set-timezone Asia/Shanghai 2>/dev/null || true
systemctl restart cron 2>/dev/null || true

if [ ! -f /swapfile ]; then
    fallocate -l 1G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=1024
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile || true
    touch "${BACKUP_DIR}/swap_created_by_script"
fi
grep -q "/swapfile" /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
if [ -f /swap.img ] && [ "$(stat -c%s /swap.img 2>/dev/null || echo 1073741824)" -lt 943718400 ]; then
    swapoff /swap.img 2>/dev/null || true
    sed -i '\|/swap\.img|d' /etc/fstab
    rm -f /swap.img
fi

cat << 'EOF' > /etc/systemd/journald.conf
[Journal]
SystemMaxUse=50M
SystemMaxFileSize=10M
RuntimeMaxUse=20M
MaxRetentionSec=7day
ForwardToSyslog=no
EOF
systemctl restart systemd-journald 2>/dev/null || true
journalctl --rotate 2>/dev/null || true
journalctl --vacuum-size=40M >/dev/null 2>&1 || true

systemctl disable --now apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service 2>/dev/null || true
apt-get clean >/dev/null 2>&1 || true

if [ -f /etc/gai.conf ]; then
    sed -i '/^precedence ::ffff:0:0\/96\s\+100/d' /etc/gai.conf
    echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
fi
if [ ! -L /etc/resolv.conf ] && [ -f /etc/resolv.conf ]; then
    sed -i '/^options /d' /etc/resolv.conf
    if [ -z "$(ip -6 addr show scope global 2>/dev/null | grep inet6 || true)" ]; then
        sed -i '/^nameserver .*:/d' /etc/resolv.conf
    fi
    echo "options timeout:1 attempts:2" >> /etc/resolv.conf
elif systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    mkdir -p /etc/systemd/resolved.conf.d
    printf "[Resolve]\nDNS=1.1.1.1 8.8.8.8\nFallbackDNS=1.0.0.1 9.9.9.9\n" > /etc/systemd/resolved.conf.d/99-fast-dns.conf
    systemctl restart systemd-resolved 2>/dev/null || true
fi

sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true
grep -q "^PubkeyAuthentication yes" /etc/ssh/sshd_config || echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config
if [ -s /root/.ssh/authorized_keys ] || [ -s ~/.ssh/authorized_keys ]; then
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true
    grep -q "^PasswordAuthentication no" /etc/ssh/sshd_config || echo "PasswordAuthentication no" >> /etc/ssh/sshd_config
fi
sshd -t && (systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true)

SSH_PORTS=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | paste -sd, -)
SSH_PORTS=${SSH_PORTS:-22}
cat << EOF > /etc/fail2ban/jail.local
[DEFAULT]
bantime = 86400
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 2592000
findtime = 600
maxretry = 3
backend = systemd

[sshd]
enabled = true
port = $SSH_PORTS
mode = aggressive
EOF
systemctl enable --now fail2ban && systemctl restart fail2ban

echo "[3/5] 注入按内存分档的高并发内核栈 (BBR + MPTCP 防护)..."
mkdir -p /etc/modules-load.d
printf "tcp_bbr\nnf_conntrack\n" > /etc/modules-load.d/99-proxy.conf
modprobe tcp_bbr 2>/dev/null || true
modprobe nf_conntrack 2>/dev/null || true

MEM_MB=$(free -m | awk '/Mem:/ {print $2}')
if [ "${MEM_MB:-1000}" -le 700 ]; then
    RMEM_MAX=16777216; TCP_MAX=8388608; DEF_BUF=262144; CONN_MAX=65536
elif [ "${MEM_MB:-1000}" -lt 1500 ]; then
    RMEM_MAX=33554432; TCP_MAX=16777216; DEF_BUF=524288; CONN_MAX=65536
else
    RMEM_MAX=67108864; TCP_MAX=33554432; DEF_BUF=1048576; CONN_MAX=131072
fi

rm -f /etc/sysctl.d/99-network-tuning.conf /etc/sysctl.d/99-proxy-tuning.conf* /etc/sysctl.d/99-bbr-network.conf
cat << EOF > /etc/sysctl.d/99-zzz-proxy-tuning.conf
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
-net.mptcp.enabled = 0
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 16384
net.ipv4.ip_local_port_range = 10000 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 3
net.ipv4.tcp_max_tw_buckets = 262144
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_no_metrics_save = 1
net.ipv4.tcp_ecn = 0
net.core.rmem_max = $RMEM_MAX
net.core.wmem_max = $RMEM_MAX
net.core.rmem_default = $DEF_BUF
net.core.wmem_default = $DEF_BUF
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_rmem = 4096 87380 $TCP_MAX
net.ipv4.tcp_wmem = 4096 65536 $TCP_MAX
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_adv_win_scale = 1
-net.netfilter.nf_conntrack_max = $CONN_MAX
-net.netfilter.nf_conntrack_udp_timeout = 30
-net.netfilter.nf_conntrack_udp_timeout_stream = 60
net.ipv4.ip_forward = 1
fs.file-max = 2097152
vm.swappiness = 10
EOF

grep -vE '^\s*#|^\s*$' /etc/sysctl.d/99-zzz-proxy-tuning.conf | sed 's/^-//' | while IFS='=' read -r k v; do
    sysctl -w "$(echo "$k" | xargs)=$(echo "$v" | xargs)" >/dev/null 2>&1 || true
done

cat << 'EOF' > /etc/security/limits.d/99-nofile.conf
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

if [ "$MODE" = "4" ]; then
    echo "=================================================================="
    echo "  【方案 4】纯系统底层内核调优已全部完成！"
    echo "  拥塞控制 : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
    echo "  MPTCP    : $(sysctl -n net.mptcp.enabled 2>/dev/null || echo 0)"
    echo "=================================================================="
    exit 0
fi

# ------------------------------------------------------------------------------
# 阶段二：安装 3x-ui v3.11.0 + 锁定 Xray v26.11.9 + 模板安全加固
# ------------------------------------------------------------------------------
echo "[4/5] 安装 3x-ui ${XUI_VERSION} 并锁定 Xray ${XRAY_VERSION}..."

cat << 'EOF' > /etc/logrotate.d/x-ui
/var/log/x-ui/*.log {
    weekly
    size 2M
    rotate 2
    compress
    missingok
    notifempty
    copytruncate
}
EOF

mkdir -p /etc/systemd/system/x-ui.service.d /etc/systemd/system/hysteria-server.service.d
cat << 'EOF' > /etc/systemd/system/x-ui.service.d/limits.conf
[Unit]
StartLimitIntervalSec=0

[Service]
LimitNOFILE=1048576
Restart=always
RestartSec=3s
OOMScoreAdjust=-500
ExecStartPre=-/bin/rm -f /etc/x-ui/system_metrics.gob
EOF
cat << 'EOF' > /etc/systemd/system/hysteria-server.service.d/limits.conf
[Unit]
StartLimitIntervalSec=0

[Service]
LimitNOFILE=1048576
Restart=always
RestartSec=3s
OOMScoreAdjust=-500
EOF
systemctl daemon-reload

if [ ! -x /usr/local/x-ui/x-ui ]; then
    printf "n\n" | bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh) "$XUI_VERSION"
fi

systemctl stop x-ui 2>/dev/null || true
rm -f /usr/local/x-ui/bin/*.bak
ARCH=$(uname -m)
if [ "$ARCH" = "x86_64" ]; then
    XRAY_ARCH="64"; XRAY_BIN="/usr/local/x-ui/bin/xray-linux-amd64"
else
    XRAY_ARCH="arm64-v8a"; XRAY_BIN="/usr/local/x-ui/bin/xray-linux-arm64"
fi
mkdir -p /tmp/xray-install
curl -fsSL -o /tmp/xray-install/xray.zip "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-${XRAY_ARCH}.zip"
python3 -m zipfile -e /tmp/xray-install/xray.zip /tmp/xray-install/
chmod +x /tmp/xray-install/xray
/tmp/xray-install/xray version | grep -q "$XRAY_VER_NUM"
cp -f /tmp/xray-install/xray "${XRAY_BIN}.new" && chmod +x "${XRAY_BIN}.new" && mv -f "${XRAY_BIN}.new" "$XRAY_BIN"
cp -f /tmp/xray-install/geoip.dat /usr/local/x-ui/bin/geoip.dat 2>/dev/null || true
cp -f /tmp/xray-install/geosite.dat /usr/local/x-ui/bin/geosite.dat 2>/dev/null || true
rm -rf /tmp/xray-install

if [ ! -f /etc/x-ui/panel_local.key ] || [ ! -f /etc/x-ui/panel_local.crt ]; then
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 -nodes \
      -keyout /etc/x-ui/panel_local.key -out /etc/x-ui/panel_local.crt \
      -subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1" 2>/dev/null
fi
chmod 700 /etc/x-ui && chmod 600 /etc/x-ui/panel_local.key && chmod 644 /etc/x-ui/panel_local.crt

systemctl start x-ui
sleep 2

# ------------------------------------------------------------------------------
# 阶段三：按用户所选方案自动创建入站、中转出站与安全规则
# ------------------------------------------------------------------------------
echo "[5/5] 写入 Xray 安全路由并按所选方案创建节点..."

# 若选择方案 2（CF TLS）或方案 3（Hy2），提前准备证书（若尚无证书）
if [ "$MODE" = "2" ] || [ "$MODE" = "3" ]; then
    mkdir -p /etc/hysteria
    if [ ! -f /etc/hysteria/server.crt ] || [ ! -f /etc/hysteria/server.key ]; then
        openssl ecparam -genkey -name prime256v1 -out /etc/hysteria/server.key
        openssl req -new -x509 -days 3650 -key /etc/hysteria/server.key -out /etc/hysteria/server.crt \
          -subj "/CN=www.bing.com" -addext "subjectAltName=DNS:www.bing.com" 2>/dev/null
    fi
    chmod 644 /etc/hysteria/server.crt
    chmod 640 /etc/hysteria/server.key
fi

install -m 600 /dev/null /tmp/setup_result.txt
XRAY_BUF=$([ "${MEM_MB:-1000}" -le 700 ] && echo 32 || echo 64) \
MODE="$MODE" REALITY_SUBMODE="$REALITY_SUBMODE" LISTEN_PORT="$LISTEN_PORT" \
REALITY_SNI="$REALITY_SNI" CF_DOMAIN="$CF_DOMAIN" SERVER_IP="$SERVER_IP" \
ENABLE_RELAY="$ENABLE_RELAY" RES_IP="$RES_IP" RES_PORT="$RES_PORT" RES_SS_PASS="$RES_SS_PASS" \
XRAY_BIN="$XRAY_BIN" \
python3 - << 'PYEOF' > /tmp/setup_result.txt
import sqlite3, json, os, uuid, secrets, subprocess, base64
os.umask(0o077)

mode = os.environ['MODE']
submode = os.environ['REALITY_SUBMODE']
port = int(os.environ['LISTEN_PORT'])
sni = os.environ['REALITY_SNI']
cf_domain = os.environ['CF_DOMAIN']
server_ip = os.environ['SERVER_IP']
enable_relay = os.environ['ENABLE_RELAY'].lower() == 'y'
res_ip = os.environ['RES_IP'].strip()
res_port = os.environ['RES_PORT'].strip()
res_ss_pass = os.environ['RES_SS_PASS'].strip()
xray_bin = os.environ['XRAY_BIN']

conn = sqlite3.connect('/etc/x-ui/x-ui.db')
c = conn.cursor()

# 1. 基础模板与安全路由
row = c.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()
cfg = json.loads(row[0]) if (row and row[0]) else {}
cfg['log'] = {"access": "none", "dnsLog": False, "error": "", "loglevel": "warning", "maskAddress": ""}
cfg['inbounds'] = [{
    "listen": "127.0.0.1", "port": 62789, "protocol": "dokodemo-door",
    "settings": {"address": "127.0.0.1"}, "tag": "api"
}]
lvl0 = cfg.setdefault('policy', {}).setdefault('levels', {}).setdefault('0', {})
lvl0.pop('udpTimeout', None)
lvl0.update({
    'handshake': 4, 'connIdle': 120, 'uplinkOnly': 2, 'downlinkOnly': 5,
    'bufferSize': int(os.environ.get('XRAY_BUF', '64')),
    'statsUserUplink': True, 'statsUserDownlink': True, 'statsUserOnline': True
})

outbounds = cfg.setdefault('outbounds', [])
if not outbounds:
    outbounds.append({"protocol": "freedom", "settings": {"domainStrategy": "UseIPv4"}, "tag": "direct"})
else:
    for ob in outbounds:
        if ob.get('protocol') == 'freedom':
            ob.setdefault('settings', {})['domainStrategy'] = 'UseIPv4'
if not any(ob.get('tag') == 'blocked' for ob in outbounds):
    outbounds.append({"protocol": "blackhole", "settings": {}, "tag": "blocked"})

# 若开启一键家宽中转，写入按入站隔离的专属出站 (out-res-<tag>)，避免多入站不同家宽互相覆盖
relay_tag = None
if mode == '1' and submode != '3':
    expected_inb_tag = f"inbound-{port}"
elif mode == '3':
    expected_inb_tag = "socks-in-10855"
else:
    expected_inb_tag = None

if expected_inb_tag:
    cand_relay_tag = f"out-res-{expected_inb_tag}"
    outbounds = [ob for ob in outbounds if ob.get('tag') != cand_relay_tag]
    if enable_relay and res_ip and res_port and res_ss_pass:
        outbounds.append({
            "tag": cand_relay_tag,
            "protocol": "shadowsocks",
            "settings": {
                "servers": [{
                    "address": res_ip,
                    "port": int(res_port),
                    "method": "2022-blake3-aes-256-gcm",
                    "password": res_ss_pass
                }]
            }
        })
        relay_tag = cand_relay_tag
    cfg['outbounds'] = outbounds

tables = [r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()]
has_clients_tbl = 'clients' in tables and 'client_inbounds' in tables

def insert_inbound(remark, listen, in_port, proto, settings_obj, stream_obj, tag, client_email=None, client_uuid=None, client_flow=""):
    if c.execute("SELECT id FROM inbounds WHERE port=? AND listen=?", (in_port, listen)).fetchone():
        return None
    sniff = {"enabled": True, "destOverride": ["http", "tls", "quic", "fakedns"], "metadataOnly": False, "routeOnly": True}
    c.execute("""
        INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing)
        VALUES (1, 0, 0, 0, ?, 1, 0, ?, ?, ?, ?, ?, ?, ?)
    """, (remark, listen, in_port, proto, json.dumps(settings_obj, indent=2), json.dumps(stream_obj, indent=2), tag, json.dumps(sniff)))
    inb_id = c.lastrowid
    if client_email:
        c.execute("INSERT INTO client_traffics (inbound_id, enable, email, up, down, expiry_time, total, reset) VALUES (?, 1, ?, 0, 0, 0, 0, 0)", (inb_id, client_email))
        if has_clients_tbl and client_uuid:
            cols = [r[1] for r in c.execute("PRAGMA table_info(clients)").fetchall()]
            if 'uuid' in cols:
                if 'flow' in cols:
                    c.execute("INSERT OR IGNORE INTO clients (email, uuid, flow, enable) VALUES (?, ?, ?, 1)", (client_email, client_uuid, client_flow))
                else:
                    c.execute("INSERT OR IGNORE INTO clients (email, uuid, enable) VALUES (?, ?, 1)", (client_email, client_uuid))
                cid = c.execute("SELECT id FROM clients WHERE email=?", (client_email,)).fetchone()[0]
                ci_cols = [r[1] for r in c.execute("PRAGMA table_info(client_inbounds)").fetchall()]
                if 'flow_override' in ci_cols:
                    c.execute("INSERT OR IGNORE INTO client_inbounds (client_id, inbound_id, flow_override) VALUES (?, ?, ?)", (cid, inb_id, client_flow))
                else:
                    c.execute("INSERT OR IGNORE INTO client_inbounds (client_id, inbound_id) VALUES (?, ?)", (cid, inb_id))
    return inb_id

inbound_tag_for_relay = None

if mode == '1' and submode == '3':
    # 住宅家宽落地机：自动生成 SS-2022
    ss_pass = base64.b64encode(os.urandom(32)).decode()
    tag = f"in-ss-{port}"
    settings_obj = {"method": "2022-blake3-aes-256-gcm", "password": ss_pass, "network": "tcp,udp", "clients": []}
    stream_obj = {"network": "tcp", "security": "none", "sockopt": {"tcpKeepAliveIdle": 120, "tcpKeepAliveInterval": 20}}
    insert_inbound("Residential-SS2022", "", port, "shadowsocks", settings_obj, stream_obj, tag)
    print(f"RESULT_TYPE=RESIDENTIAL_SS")
    print(f"SS_IP={server_ip}")
    print(f"SS_PORT={port}")
    print(f"SS_PASS={ss_pass}")

elif mode == '1':
    # 方案 1：VLESS + REALITY (XHTTP 或 raw+Vision)
    out = subprocess.check_output([xray_bin, 'x25519'], text=True)
    priv = pub = ''
    for line in out.splitlines():
        if 'Private' in line: priv = line.split(':', 1)[1].strip()
        elif 'Public' in line or 'Password' in line: pub = line.split(':', 1)[1].strip()
    sid = secrets.token_hex(4)
    u = str(uuid.uuid4())
    email = f"reality-{port}"
    tag = f"inbound-{port}"
    flow = "" if submode == '1' else "xtls-rprx-vision"
    net = "xhttp" if submode == '1' else "tcp"
    settings_obj = {
        "clients": [{"id": u, "flow": flow, "email": email, "limitIp": 0, "totalGB": 0, "expiryTime": 0, "enable": True, "subId": secrets.token_hex(8), "reset": 0}],
        "decryption": "none", "fallbacks": []
    }
    stream_obj = {
        "network": net, "security": "reality", "externalProxy": [],
        "realitySettings": {
            "show": False, "xver": 0, "target": f"{sni}:443", "serverNames": [sni],
            "privateKey": priv, "minClientVer": "", "maxClientVer": "", "maxTimeDiff": 0,
            "shortIds": [sid],
            "settings": {"publicKey": pub, "fingerprint": "chrome", "serverName": "", "spiderX": "/"}
        },
        "sockopt": {"tcpKeepAliveIdle": 120, "tcpKeepAliveInterval": 20}
    }
    if submode == '1':
        stream_obj["xhttpSettings"] = {"path": "/vless-xhttp", "host": "", "mode": "auto"}
        remark = "VLESS-XHTTP-REALITY"
        link = f"vless://{u}@{server_ip}:{port}?type=xhttp&path=%2Fvless-xhttp&mode=auto&security=reality&pbk={pub}&fp=chrome&sni={sni}&sid={sid}&spx=%2F#{remark}"
    else:
        remark = "VLESS-Vision-REALITY"
        link = f"vless://{u}@{server_ip}:{port}?type=tcp&security=reality&pbk={pub}&fp=chrome&sni={sni}&sid={sid}&spx=%2F&flow=xtls-rprx-vision#{remark}"
    insert_inbound(remark, "", port, "vless", settings_obj, stream_obj, tag, email, u, flow)
    inbound_tag_for_relay = tag
    print(f"RESULT_TYPE=LINK")
    print(f"SHARE_LINK={link}")

elif mode == '2':
    # 方案 2：Cloudflare CDN (VLESS + XHTTP + TLS)
    u = str(uuid.uuid4())
    email = f"cf-xhttp-{port}"
    tag = f"inbound-{port}"
    settings_obj = {
        "clients": [{"id": u, "flow": "", "email": email, "limitIp": 0, "totalGB": 0, "expiryTime": 0, "enable": True, "subId": secrets.token_hex(8), "reset": 0}],
        "decryption": "none", "fallbacks": []
    }
    stream_obj = {
        "network": "xhttp", "security": "tls", "externalProxy": [],
        "tlsSettings": {
            "serverName": cf_domain, "minVersion": "1.2", "maxVersion": "1.3",
            "certificates": [{"certificateFile": "/etc/hysteria/server.crt", "keyFile": "/etc/hysteria/server.key", "ocspStapling": 3600}],
            "alpn": ["h2", "http/1.1"]
        },
        "xhttpSettings": {"path": "/vless-xhttp", "host": cf_domain, "mode": "auto"},
        "sockopt": {"tcpKeepAliveIdle": 120, "tcpKeepAliveInterval": 20, "trustedXForwardedFor": ["CF-Connecting-IP", "X-Forwarded-For"]}
    }
    insert_inbound("CF-VLESS-XHTTP-TLS", "", port, "vless", settings_obj, stream_obj, tag, email, u)
    link = f"vless://{u}@{cf_domain}:{port}?type=xhttp&path=%2Fvless-xhttp&mode=auto&host={cf_domain}&security=tls&sni={cf_domain}#CF-VLESS-XHTTP-TLS"
    print(f"RESULT_TYPE=LINK")
    print(f"SHARE_LINK={link}")

elif mode == '3' and relay_tag:
    # 方案 3 Hy2 启用家宽中转：在 Xray 侧开启本地 127.0.0.1:10855 SOCKS5 桥接
    tag = "socks-in-10855"
    settings_obj = {"auth": "noauth", "udp": True, "ip": "127.0.0.1"}
    stream_obj = {"network": "tcp", "security": "none"}
    insert_inbound("Hy2-SOCKS5-Bridge", "127.0.0.1", 10855, "socks", settings_obj, stream_obj, tag)
    inbound_tag_for_relay = tag

# 写入置顶防私网/BT/回国路由 + 中转规则
old_rules = cfg.setdefault('routing', {}).setdefault('rules', [])
custom_rules = [
    r for r in old_rules
    if not (r.get('outboundTag') == 'api' and r.get('inboundTag') == ['api'])
    and not (r.get('outboundTag') == 'blocked' and set(r.get('ip', [])) <= {'geoip:private', 'geoip:cn'} and not r.get('protocol') and not r.get('inboundTag') and not r.get('user'))
    and not (r.get('outboundTag') == 'blocked' and r.get('protocol') == ['bittorrent'] and not r.get('ip') and not r.get('domain'))
    and not (inbound_tag_for_relay and r.get('inboundTag') == [inbound_tag_for_relay] and str(r.get('outboundTag', '')).startswith('out-res'))
]
if relay_tag and inbound_tag_for_relay:
    custom_rules.append({'type': 'field', 'inboundTag': [inbound_tag_for_relay], 'outboundTag': relay_tag})

cfg.setdefault('routing', {})['domainStrategy'] = 'IPOnDemand'
cfg['routing']['rules'] = [
    {'type': 'field', 'inboundTag': ['api'], 'outboundTag': 'api'},
    {'type': 'field', 'outboundTag': 'blocked', 'ip': ['geoip:private']},
    {'type': 'field', 'outboundTag': 'blocked', 'protocol': ['bittorrent']},
    {'type': 'field', 'outboundTag': 'blocked', 'ip': ['geoip:cn']},
] + custom_rules

for k, v in [
    ('xrayTemplateConfig', json.dumps(cfg, indent=2)),
    ('webListen', '127.0.0.1'),
    ('webCertFile', '/etc/x-ui/panel_local.crt'),
    ('webKeyFile', '/etc/x-ui/panel_local.key'),
    ('subEnable', 'false'),
    ('subListen', '127.0.0.1'),
]:
    c.execute("DELETE FROM settings WHERE key=?", (k,))
    c.execute("INSERT INTO settings (key, value) VALUES (?, ?)", (k, v))

conn.commit()
conn.execute("VACUUM")
conn.close()
PYEOF
chmod 600 /etc/x-ui/x-ui.db 2>/dev/null || true

# 若为家宽落地机且填写了前置白名单 IP，自动部署 nftables 保护端口
if [ "$MODE" = "1" ] && [ "$REALITY_SUBMODE" = "3" ] && [ -n "$RES_WHITELIST_IP" ]; then
    mkdir -p /etc/nftables.d
    cat << EOF > /etc/nftables.d/res-guard.nft
table inet res_guard
delete table inet res_guard
table inet res_guard {
    set trusted_relays_v4 {
        type ipv4_addr
        flags interval
        elements = { 127.0.0.0/8, ${RES_WHITELIST_IP} }
    }
    chain input {
        type filter hook input priority filter; policy accept;
        iifname "lo" accept
        ct state established,related accept
        tcp dport ${LISTEN_PORT} ip saddr @trusted_relays_v4 accept
        udp dport ${LISTEN_PORT} ip saddr @trusted_relays_v4 accept
        tcp dport ${LISTEN_PORT} drop
        udp dport ${LISTEN_PORT} drop
    }
}
EOF
    nft -f /etc/nftables.d/res-guard.nft || true
    cat << 'EOF' > /etc/systemd/system/res-guard.service
[Unit]
Description=Residential Landing Port Whitelist
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/nftables.d/res-guard.nft
ExecStop=/usr/sbin/nft delete table inet res_guard
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable res-guard.service >/dev/null 2>&1 || true
fi

# 方案 3：部署 Hysteria 2 + 20000-50000 端口跳跃
HY2_LINK=""
if [ "$MODE" = "3" ]; then
    HY2_PASS=""
    if [ -f /etc/hysteria/config.yaml ]; then
        HY2_PASS=$(awk '/^[[:space:]]*password:[[:space:]]*/ {print $2; exit}' /etc/hysteria/config.yaml | tr -d '"' | tr -d "'" | tr -dc 'a-zA-Z0-9' || true)
    fi
    if ! command -v hysteria >/dev/null 2>&1; then
        bash <(curl -fsSL https://get.hy2.sh/)
    fi
    HY2_PIN=$(openssl x509 -in /etc/hysteria/server.crt -noout -sha256 -fingerprint | cut -d'=' -f2)
    HY2_PASS="${HY2_PASS:-$(openssl rand -base64 24 | tr -dc 'a-zA-Z0-9' | head -c 16)}"

    if [ "${MEM_MB:-1000}" -le 700 ]; then
        HY2_STREAM_WIN=6291456; HY2_CONN_WIN=15728640
    else
        HY2_STREAM_WIN=8388608; HY2_CONN_WIN=20971520
    fi

    if [[ "$HY2_BRUTAL" =~ ^[Yy]$ ]]; then
        IGNORE_BW="false"
        BW_BLOCK="bandwidth:
  up: 500 mbps
  down: 100 mbps"
    else
        IGNORE_BW="true"
        BW_BLOCK="# bandwidth:
#   up: 500 mbps
#   down: 100 mbps"
    fi

    if [[ "$ENABLE_RELAY" =~ ^[Yy]$ ]] && [ -n "$RES_IP" ]; then
        ACL_GEOIP_LINE=""
        ACL_CN_LINE=""
        OUTBOUND_BLOCK="outbounds:
  - name: residential-landing
    type: socks5
    socks5:
      addr: 127.0.0.1:10855"
    else
        ACL_GEOIP_LINE="  geoip: /usr/local/x-ui/bin/geoip.dat"
        ACL_CN_LINE="    - reject(geoip:cn)"
        OUTBOUND_BLOCK="outbounds:
  - name: direct
    type: direct
    direct:
      mode: 4"
    fi

    (
    umask 077
    cat << EOF > /etc/hysteria/config.yaml
listen: :${LISTEN_PORT}
${BW_BLOCK}
ignoreClientBandwidth: ${IGNORE_BW}
quic:
  initStreamReceiveWindow: ${HY2_STREAM_WIN}
  maxStreamReceiveWindow: ${HY2_STREAM_WIN}
  initConnReceiveWindow: ${HY2_CONN_WIN}
  maxConnReceiveWindow: ${HY2_CONN_WIN}
  maxIdleTimeout: 30s
  keepAlivePeriod: 10s
tls:
  sniGuard: disable
  cert: /etc/hysteria/server.crt
  key: /etc/hysteria/server.key
auth:
  type: password
  password: ${HY2_PASS}
acl:
${ACL_GEOIP_LINE}
  inline:
    - reject(127.0.0.0/8)
    - reject(10.0.0.0/8)
    - reject(172.16.0.0/12)
    - reject(192.168.0.0/16)
    - reject(169.254.0.0/16)
    - reject(::1/128)
    - reject(fc00::/7)
    - reject(fe80::/10)
${ACL_CN_LINE}
masquerade:
  type: proxy
  proxy:
    url: https://www.bing.com/
    rewriteHost: true
${OUTBOUND_BLOCK}
EOF
    )
    id -u hysteria >/dev/null 2>&1 && chown -R hysteria:hysteria /etc/hysteria || true
    chmod 644 /etc/hysteria/server.crt
    chmod 640 /etc/hysteria/server.key /etc/hysteria/config.yaml

    cat << EOF > /etc/systemd/system/hy2-port-hopping.service
[Unit]
Description=Hysteria 2 Port Hopping (IPv4/IPv6 Idempotent)
After=network.target
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'iptables -t nat -C PREROUTING -p udp -m addrtype --dst-type LOCAL --dport 20000:50000 -j REDIRECT --to-ports ${LISTEN_PORT} 2>/dev/null || iptables -t nat -A PREROUTING -p udp -m addrtype --dst-type LOCAL --dport 20000:50000 -j REDIRECT --to-ports ${LISTEN_PORT}; ip6tables -t nat -C PREROUTING -p udp -m addrtype --dst-type LOCAL --dport 20000:50000 -j REDIRECT --to-ports ${LISTEN_PORT} 2>/dev/null || ip6tables -t nat -A PREROUTING -p udp -m addrtype --dst-type LOCAL --dport 20000:50000 -j REDIRECT --to-ports ${LISTEN_PORT} 2>/dev/null || true; sysctl -w net.netfilter.nf_conntrack_max=${CONN_MAX} net.netfilter.nf_conntrack_udp_timeout=30 net.netfilter.nf_conntrack_udp_timeout_stream=60 >/dev/null 2>&1 || true'
ExecStop=/bin/sh -c 'iptables -t nat -D PREROUTING -p udp -m addrtype --dst-type LOCAL --dport 20000:50000 -j REDIRECT --to-ports ${LISTEN_PORT} 2>/dev/null || true; ip6tables -t nat -D PREROUTING -p udp -m addrtype --dst-type LOCAL --dport 20000:50000 -j REDIRECT --to-ports ${LISTEN_PORT} 2>/dev/null || true'
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable --now hy2-port-hopping.service
    systemctl enable --now hysteria-server
    HY2_LINK="hysteria2://${HY2_PASS}@${SERVER_IP}:${LISTEN_PORT}?insecure=1&sni=www.bing.com&pinSHA256=${HY2_PIN}&mport=20000-50000#Hy2-PortHopping"
fi

# 每周日 04:00 平滑重启 x-ui 释放内存缓存
( (crontab -l 2>/dev/null | grep -v "systemctl restart x-ui") || true; echo "0 4 * * 0 systemctl restart x-ui" ) | crontab -
systemctl restart x-ui

PANEL_PORT=$(python3 -c "import sqlite3; r=sqlite3.connect('/etc/x-ui/x-ui.db').execute(\"SELECT value FROM settings WHERE key='webPort' LIMIT 1\").fetchone(); print(r[0].strip() if r and r[0] else '54321')" 2>/dev/null | tr -dc '0-9' || true)
PANEL_PATH=$(python3 -c "import sqlite3; r=sqlite3.connect('/etc/x-ui/x-ui.db').execute(\"SELECT value FROM settings WHERE key='webBasePath' LIMIT 1\").fetchone(); print(r[0].strip().strip('/') if r and r[0] else '')" 2>/dev/null || true)

echo ""
echo "=================================================================="
echo "  部署完成！服务状态验收："
echo "  - x-ui          : $(systemctl is-active x-ui 2>/dev/null || true)"
[ "$MODE" = "3" ] && echo "  - hysteria      : $(systemctl is-active hysteria-server 2>/dev/null || true)"
echo "  - Xray 内核     : $($XRAY_BIN version | head -n 1)"
echo "------------------------------------------------------------------"
echo "  3x-ui 面板已锁定 127.0.0.1:${PANEL_PORT}，本地 SSH 隧道访问命令："
echo "  ssh -L ${PANEL_PORT}:127.0.0.1:${PANEL_PORT} root@${SERVER_IP}"
echo "  本地浏览器打开: https://127.0.0.1:${PANEL_PORT}/${PANEL_PATH}"
if [ -f /tmp/setup_result.txt ]; then
    if grep -q "RESULT_TYPE=RESIDENTIAL_SS" /tmp/setup_result.txt; then
        echo "------------------------------------------------------------------"
        echo "  【家宽落地 SS-2022 中转凭据】（请复制到前置优化机脚本中）："
        grep -E "^SS_(IP|PORT|PASS)=" /tmp/setup_result.txt | sed 's/^/  /'
    elif grep -q "RESULT_TYPE=LINK" /tmp/setup_result.txt; then
        echo "------------------------------------------------------------------"
        echo "  【客户端导入链接】："
        grep "^SHARE_LINK=" /tmp/setup_result.txt | cut -d'=' -f2- | sed 's/^/  /'
    fi
    rm -f /tmp/setup_result.txt
fi
if [ -n "$HY2_LINK" ]; then
    echo "------------------------------------------------------------------"
    echo "  【Hysteria 2 导入链接】："
    echo "  ${HY2_LINK}"
fi
echo -e "${CYAN}══════════════════════════════════════════════════════════════════"
echo -e "  本脚本由 猫e/acc (CatEacc) 维护提供"
echo -e "  GitHub : https://github.com/CatEacc/vps-xray-runbook"
echo -e "  TG 频道: https://t.me/CatCryptoMaster"
echo -e "══════════════════════════════════════════════════════════════════${NC}"
