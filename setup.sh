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
RED="${ESC}[38;5;196m"
WHITE="${ESC}[1;97m"
DIM="${ESC}[38;5;245m"
NC="${R}"

SCRIPT_VER=$(curl -fsSm 2 https://api.github.com/repos/CatEacc/vps-xray-runbook/releases/latest 2>/dev/null | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n 1 | cut -d'"' -f4 || true)
SCRIPT_VER="${SCRIPT_VER:-v1.2.3}"

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
    printf "  ${CYAN}猫e/acc (CatEacc)${R} ${DIM}· VPS 生产级部署与调优脚本 ${YELLOW}${SCRIPT_VER}${R}\n"
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
    printf "  ${GREEN}[5]${R} ${WHITE}一键回滚系统底层调优${R} ${DIM}· 恢复原厂内核/日志/Swap 快照${R}\n"
    printf "  ${GREEN}[6]${R} ${WHITE}一键导出所有节点链接 & 面板访问命令${R} ${CYAN}· 只读${R}\n\n"
    read -rp "$(printf "${YELLOW}  请输入方案编号 [1-6] (回车默认 1): ${R}")" MODE
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

verify_reality_sni() {
    local target_sni="$1"
    if ! command -v python3 >/dev/null 2>&1; then
        return 0
    fi
    printf "  ${SKY}-> 正在对 ${WHITE}%s${SKY} 执行实时四重复检 (TLS 1.3+H2 / 非 CF / 无国内 CDN / 中国大陆可达)...${R}\n" "$target_sni"
    local chk_out
    chk_out=$(SNI_TEST="$target_sni" python3 - << 'CHKPY'
import os, ssl, socket, time, json, http.client, urllib.request
h = os.environ["SNI_TEST"].strip()
ctx = ssl.create_default_context()
ctx.set_alpn_protocols(["h2", "http/1.1"])
t0 = time.monotonic()
try:
    with socket.create_connection((h, 443), timeout=3.0) as sock:
        with ctx.wrap_socket(sock, server_hostname=h) as ss:
            rtt = (time.monotonic() - t0) * 1000
            ver, alpn = ss.version(), ss.selected_alpn_protocol()
    is_cf = False
    try:
        conn = http.client.HTTPSConnection(h, timeout=2.5)
        conn.request("HEAD", "/", headers={"User-Agent": "Mozilla/5.0"})
        hdrs = {k.lower(): v for k, v in conn.getresponse().getheaders()}
        is_cf = ('cf-ray' in hdrs) or ('cloudflare' in hdrs.get('server', '').lower())
    except Exception:
        pass
    cn_note = "国内探针暂跳过"
    cn_warn = ""
    try:
        payload = json.dumps({
            "type": "http", "target": h, "locations": [{"country": "CN"}], "limit": 2,
            "measurementOptions": {"protocol": "HTTPS", "request": {"method": "HEAD", "path": "/"}}
        }).encode()
        req = urllib.request.Request("https://api.globalping.io/v1/measurements", data=payload,
            headers={"Content-Type": "application/json", "User-Agent": "CatEacc-SNI-Check/1.0"})
        mid = json.loads(urllib.request.urlopen(req, timeout=5).read().decode()).get("id")
        if mid:
            finished = None
            for _ in range(12):
                time.sleep(1.0)
                r = json.loads(urllib.request.urlopen(f"https://api.globalping.io/v1/measurements/{mid}", timeout=5).read().decode())
                if r.get("status") == "finished":
                    finished = r.get("results", [])
                    break
            if finished is None:
                cn_warn = "中国大陆探针超时未响应，疑似已被 GFW 阻断或国内无法访问！"
            elif finished:
                ok_cnt, cn_cdn_ip = 0, ""
                for item in finished:
                    rr = item.get("result", {})
                    if rr.get("status") == "finished" and rr.get("statusCode"):
                        ok_cnt += 1
                    rip = rr.get("resolvedAddress", "")
                    if rip and not cn_cdn_ip:
                        try:
                            cc = urllib.request.urlopen(f"https://ipinfo.io/{rip}/country", timeout=2.5).read().decode().strip()
                            if cc == "CN":
                                cn_cdn_ip = rip
                        except Exception:
                            pass
                if cn_cdn_ip:
                    cn_warn = f"中国大陆解析到境内 IP ({cn_cdn_ip})，存在国内 CDN，严禁用于 REALITY！"
                elif ok_cnt == 0:
                    cn_warn = f"中国大陆探针 0/{len(finished)} 可达，疑似已被 GFW 阻断或 SNI 封锁！"
                else:
                    cn_note = f"国内直连可达 {ok_cnt}/{len(finished)} | 无境内 CDN"
    except Exception:
        pass
    if is_cf:
        print(f"WARN|背后套了 Cloudflare CDN，易被扫作免费 CF 反代 IP ({ver}+{alpn}, {rtt:.1f} ms)")
    elif cn_warn:
        print(f"WARN|{cn_warn} ({ver}+{alpn}, {rtt:.1f} ms)")
    elif ver == "TLSv1.3" and alpn == "h2":
        print(f"OK|{ver} + {alpn} | 非 CF | {cn_note} ({rtt:.1f} ms)")
    else:
        print(f"WARN|{ver} / ALPN={alpn}")
except Exception as e:
    print(f"WARN|{e}")
CHKPY
)
    if [[ "$chk_out" == OK\|* ]]; then
        printf "  ${GREEN}-> [实时复检通过]${R} ${WHITE}%s${R}: ${GREEN}%s${R}\n" "$target_sni" "${chk_out#OK|}"
    else
        printf "  ${RED}-> [实时复检警告]${R} ${WHITE}%s${R}: ${ORANGE}%s${R}\n" "$target_sni" "${chk_out#WARN|}"
    fi
}

prompt_relay_target() {
    printf "\n  ${CYAN}─── 后端家宽中转对接方式 ───${R}\n"
    printf "  ${GREEN}[1]${R} ${WHITE}粘贴 ss:// 分享链接${R} ${DIM}(自动解析 IP/端口/密钥，也支持直接输入 IP 手填)${R}\n"
    printf "  ${GREEN}[2]${R} ${WHITE}全自动远程部署家宽机并对接${R} ${PINK}★ 终极懒人版 · 填 SSH 账密自动装好并拉回凭据${R}\n"
    read -rp "$(printf "  ${YELLOW}请选择对接方式 [1-2] (回车默认 1): ${R}")" RELAY_MODE
    RELAY_MODE="${RELAY_MODE:-1}"

    if [ "$RELAY_MODE" = "2" ]; then
        read -rp "$(printf "  ${SKY}-> 后端家宽机 SSH IP: ${R}")" RES_SSH_IP
        read -rp "$(printf "  ${SKY}-> 后端家宽机 SSH 端口 (回车默认 22): ${R}")" RES_SSH_PORT
        RES_SSH_PORT="${RES_SSH_PORT:-22}"
        read -rsp "$(printf "  ${SKY}-> 后端家宽机 root 密码 (输入不回显，仅内存生效不落盘): ${R}")" RES_SSH_PASS
        echo ""
        if [ -n "$RES_SSH_IP" ] && [ -n "$RES_SSH_PASS" ]; then
            if ! command -v sshpass >/dev/null 2>&1; then
                printf "  ${DIM}-> 正在安装 sshpass 以进行自动化对接...${R}\n"
                export DEBIAN_FRONTEND=noninteractive
                apt-get update -qq && apt-get install -y -qq sshpass >/dev/null 2>&1 || true
            fi
            printf "  ${CYAN}-> 正在连接家宽机 %s:%s 自动部署 SS-2022 落地并添加本机白名单 (%s)...${R}\n" "$RES_SSH_IP" "$RES_SSH_PORT" "$SERVER_IP"
            local remote_out=""
            if command -v sshpass >/dev/null 2>&1; then
                remote_out=$(SSHPASS="$RES_SSH_PASS" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -p "$RES_SSH_PORT" "root@${RES_SSH_IP}" \
                    "curl -fsSL https://raw.githubusercontent.com/CatEacc/vps-xray-runbook/main/setup.sh -o /tmp/_res_setup.sh && printf '3\n\n%s\n' '${SERVER_IP}' | bash /tmp/_res_setup.sh 1; rm -f /tmp/_res_setup.sh" 2>&1 || true)
            fi
            unset RES_SSH_PASS SSHPASS
            RES_IP=$(printf "%s\n" "$remote_out" | grep -oE 'SS_IP=[^[:space:]]+' | tail -n 1 | cut -d'=' -f2- || true)
            RES_PORT=$(printf "%s\n" "$remote_out" | grep -oE 'SS_PORT=[0-9]+' | tail -n 1 | cut -d'=' -f2- || true)
            RES_SS_PASS=$(printf "%s\n" "$remote_out" | grep -oE 'SS_PASS=[^[:space:]]+' | tail -n 1 | cut -d'=' -f2- || true)
            if [ -n "$RES_IP" ] && [ -n "$RES_PORT" ] && [ -n "$RES_SS_PASS" ]; then
                printf "  ${GREEN}-> [自动对接成功]${R} 家宽落地已就绪: ${CYAN}%s:%s${R} (已自动白名单放行本机 IP)\n" "$RES_IP" "$RES_PORT"
                return 0
            else
                printf "  ${ORANGE}-> [提示] 远程自动部署未能获取凭据（请检查密码/网络），自动切换为方式 1 手动粘贴：${R}\n"
            fi
        else
            unset RES_SSH_PASS SSHPASS
            printf "  ${ORANGE}-> [提示] IP 或密码为空，自动切换为方式 1：${R}\n"
        fi
    fi

    read -rp "$(printf "  ${YELLOW}-> 请粘贴家宽 ss:// 链接，或直接输入家宽机 IP: ${R}")" SS_OR_IP
    if [[ "$SS_OR_IP" == ss://* ]]; then
        local parsed
        parsed=$(SS_URI="$SS_OR_IP" python3 - << 'SSPY'
import os, base64, urllib.parse
u = os.environ.get("SS_URI", "").strip()
u = u[5:].split("#", 1)[0].split("?", 1)[0]
if "@" in u:
    cred, hp = u.rsplit("@", 1)
    cred = urllib.parse.unquote(cred)
    if ":" not in cred:
        pad = "=" * ((4 - len(cred) % 4) % 4)
        try:
            cred = base64.urlsafe_b64decode(cred + pad).decode("utf-8", "ignore")
        except Exception:
            cred = base64.b64decode(cred + pad).decode("utf-8", "ignore")
    pwd = cred.split(":", 1)[1] if ":" in cred else cred
    host, port = hp.rsplit(":", 1)
    print(f"{host.strip('[]')}|{port.strip()}|{pwd.strip()}")
SSPY
)
        if [ -n "$parsed" ]; then
            IFS='|' read -r RES_IP RES_PORT RES_SS_PASS <<< "$parsed"
            printf "  ${GREEN}-> [解析成功]${R} 目标家宽: ${CYAN}%s:%s${R} ${DIM}(密钥已自动提取)${R}\n" "$RES_IP" "$RES_PORT"
            return 0
        else
            printf "  ${ORANGE}-> [提示] ss:// 链接解析失败，请改为分步输入：${R}\n"
            read -rp "$(printf "  ${SKY}-> 请输入后端家宽机 IP: ${R}")" RES_IP
        fi
    else
        RES_IP="$SS_OR_IP"
    fi
    read -rp "$(printf "  ${SKY}-> 请输入后端家宽机 SS-2022 端口: ${R}")" RES_PORT
    read -rp "$(printf "  ${SKY}-> 请输入后端家宽机 SS-2022 密钥 (Base64): ${R}")" RES_SS_PASS
}

case "$MODE" in
    1)
        echo ""
        printf "  ${CYAN}─── 方案 1 子模式选择 ───${R}\n"
        printf "  ${GREEN}[1]${R} ${WHITE}VLESS + XHTTP + REALITY${R} ${DIM}（RPRX 最新 H2/XMUX，适合新版 v2rayN/v2rayNG）${R}\n"
        printf "  ${GREEN}[2]${R} ${WHITE}VLESS + raw + REALITY + Vision${R} ${CYAN}（全客户端通吃，极低延迟）${R}\n"
        printf "  ${GREEN}[3]${R} ${WHITE}设为【海外住宅家宽落地机】${R} ${PINK}（随机高位端口 SS-2022，供优化机一键中转）${R}\n"
        read -rp "$(printf "  ${YELLOW}请选择子模式 [1-3] (回车默认 1): ${R}")" REALITY_SUBMODE
        REALITY_SUBMODE="${REALITY_SUBMODE:-1}"

        if [ "$REALITY_SUBMODE" = "3" ]; then
            DEF_PORT=$((20000 + RANDOM % 30000))
            read -rp "$(printf "  ${YELLOW}请输入家宽落地 SS-2022 监听端口 (回车默认随机高位端口 ${CYAN}${DEF_PORT}${YELLOW}): ${R}")" LISTEN_PORT
            LISTEN_PORT="${LISTEN_PORT:-$DEF_PORT}"
            read -rp "$(printf "  ${YELLOW}请输入允许连入的前置优化机 IP（留空则不设白名单，多个用逗号分隔）: ${R}")" RES_WHITELIST_IP
        else
            read -rp "$(printf "  ${YELLOW}请输入 REALITY 监听端口 (回车默认 443，也可手动输入如 8443): ${R}")" LISTEN_PORT
            LISTEN_PORT="${LISTEN_PORT:-443}"
            printf "\n  ${CYAN}─── 请选择 REALITY 回落目标域名 (SNI) ───${R}\n"
            printf "  ${GREEN}[1]${R} ${WHITE}按机房地区自动测速优选${R} ${ORANGE}★ 推荐：本土 5 站 + 全球兜底池 + 选后自动实时复检${R}\n"
            printf "  ${GREEN}[2]${R} ${WHITE}addons.mozilla.org${R}     ${DIM}（免测默认：Firefox 扩展商店 · 纯海外无国内 CDN）${R}\n"
            printf "  ${GREEN}[3]${R} ${WHITE}www.gentoo.org${R}         ${DIM}（免测默认：Gentoo Linux 官网 · 非 CF 国内直连可达）${R}\n"
            printf "  ${GREEN}[4]${R} ${WHITE}手动输入自定义域名${R}     ${DIM}（自动四重体检 TLS 1.3+H2 / 非 CF / 国内 CDN / 是否被墙）${R}\n"
            read -rp "$(printf "  ${YELLOW}请输入选项 [1-4] (回车默认 1): ${R}")" SNI_OPT
            case "${SNI_OPT:-1}" in
                1)
                    if command -v python3 >/dev/null 2>&1; then
                        VPS_CC=$( (curl -fsSm 2 https://ipinfo.io/country 2>/dev/null || curl -fsSm 2 https://ifconfig.co/country-iso 2>/dev/null || true) | tr -dc 'A-Za-z' | tr '[:lower:]' '[:upper:]' | head -c 2 )
                        echo ""
                        printf "  ${YELLOW}[说明]${R} ${DIM}REALITY 选站铁律：纯海外、TLSv1.3+H2、非 CF、无国内 CDN、国内直连可达，同地区低延迟更自然。${R}\n"
                        printf "  ${SKY}-> 正在并发测速当前地区 (${CYAN}${VPS_CC:-GLOBAL}${SKY}) 本土站 + 全球通用兜底池...${R}\n"
                        SNI_LIST=$(VPS_CC="$VPS_CC" python3 - << 'SNIPY'
import os, ssl, socket, time
from concurrent.futures import ThreadPoolExecutor

GLOBAL_POOL = [
    ("www.gentoo.org",     "Gentoo Linux 官网"),
    ("www.openssl.org",    "OpenSSL 加密库官网"),
    ("www.debian.org",     "Debian Linux 官网"),
    ("www.kernel.org",     "Linux 内核官网"),
    ("addons.mozilla.org", "Firefox 扩展商店"),
]
REGIONAL = {
    "US": ("美国", [
        ("www.ebay.com",     "eBay 国际电商"),
        ("www.airbnb.com",   "Airbnb 国际民宿"),
        ("www.ups.com",      "UPS 国际物流"),
        ("www.stanford.edu", "斯坦福大学官网"),
        ("www.harvard.edu",  "哈佛大学官网"),
    ]),
    "CA": ("加拿大", [
        ("www.utoronto.ca", "多伦多大学官网"),
        ("www.ubc.ca",      "英属哥伦比亚大学"),
        ("www.ebay.com",    "eBay 国际电商"),
        ("www.airbnb.com",  "Airbnb 国际民宿"),
        ("www.ups.com",     "UPS 国际物流"),
    ]),
    "JP": ("日本", [
        ("www.sony.jp",           "索尼日本官网"),
        ("www.yahoo.co.jp",       "日本雅虎门户"),
        ("www.honda.co.jp",       "本田日本官网"),
        ("www.yamaha.com",        "雅马哈国际官网"),
        ("www.lovelive-anime.jp", "日本动漫官网"),
    ]),
    "HK": ("香港", [
        ("www.mandarinoriental.com", "香港文华东方酒店"),
        ("www.k11musea.com",         "香港 K11 MUSEA"),
        ("www.pacificplace.com.hk",  "香港太古广场"),
        ("www.cityu.edu.hk",         "香港城市大学"),
        ("www.hku.hk",               "香港大学官网"),
    ]),
    "SG": ("新加坡", [
        ("www.grab.com",          "Grab 东南亚出行"),
        ("www.changiairport.com", "新加坡樟宜机场"),
        ("nus.edu.sg",            "新加坡国立大学"),
        ("www.smu.edu.sg",        "新加坡管理大学"),
        ("www.sutd.edu.sg",       "新加坡科技设计大学"),
    ]),
    "TW": ("台湾", [
        ("www.asus.com",     "华硕国际官网"),
        ("www.msi.com",      "微星国际官网"),
        ("www.gigabyte.com", "技嘉国际官网"),
        ("www.evaair.com",   "台湾长荣航空"),
        ("www.gskill.com",   "台湾芝奇内存"),
    ]),
    "KR": ("韩国", [
        ("www.naver.com",     "韩国 Naver 门户"),
        ("www.samsung.com",   "三星国际官网"),
        ("www.koreanair.com", "大韩航空官网"),
        ("www.coupang.com",   "韩国 Coupang 电商"),
        ("www.cj.net",        "韩国 CJ 集团官网"),
    ]),
    "EU": ("欧洲", [
        ("www.adidas.com",        "德国阿迪达斯官网"),
        ("www.nokia.com",         "芬兰诺基亚官网"),
        ("www.mercedes-benz.com", "梅赛德斯-奔驰官网"),
        ("www.tudelft.nl",        "荷兰代尔夫特理工"),
        ("www.postgresql.org",    "PostgreSQL (奥地利)"),
    ]),
    "GB": ("英国", [
        ("www.virginatlantic.com",  "英国维珍航空"),
        ("www.marksandspencer.com", "英国玛莎百货"),
        ("www.unilever.com",        "英国联合利华"),
        ("www.arm.com",             "英国 Arm 架构官网"),
        ("www.cam.ac.uk",           "剑桥大学官网"),
    ]),
}
cc = os.environ.get("VPS_CC", "")
if cc in ("US", "CA", "JP", "HK", "SG", "TW", "KR", "GB"):
    rk = cc
elif cc in ("DE", "NL", "FR", "CH", "AT", "SE", "FI", "PL", "IT", "ES", "LU", "IE", "NO", "DK", "BE", "CZ"):
    rk = "EU"
else:
    rk = ""

r_name, r_pool = REGIONAL.get(rk, ("", []))
all_items = [("REG", h, d) for h, d in r_pool] + [("GLB", h, d) for h, d in GLOBAL_POOL]

def probe(item):
    grp, host, desc = item
    ctx = ssl.create_default_context()
    ctx.set_alpn_protocols(["h2", "http/1.1"])
    t0 = time.monotonic()
    try:
        with socket.create_connection((host, 443), timeout=2.5) as sock:
            with ctx.wrap_socket(sock, server_hostname=host) as ss:
                if ss.version() == "TLSv1.3" and ss.selected_alpn_protocol() == "h2":
                    return (grp, (time.monotonic() - t0) * 1000, host, desc)
    except Exception:
        pass
    return None

with ThreadPoolExecutor(max_workers=12) as ex:
    res = [r for r in ex.map(probe, all_items) if r]

reg_res = sorted([r for r in res if r[0] == "REG"], key=lambda x: x[1])
glb_res = sorted([r for r in res if r[0] == "GLB"], key=lambda x: x[1])
if r_name and reg_res:
    print(f"HDR|当前地区推荐 ({r_name}) · 按实测延迟排序")
    for _, rtt, host, desc in reg_res[:5]:
        print(f"ITEM|{host}|{rtt:.1f}|{desc}")
if glb_res:
    print("HDR|全球通用兜底池 · 跨区通用 · 按实测延迟排序")
    for _, rtt, host, desc in glb_res[:5]:
        print(f"ITEM|{host}|{rtt:.1f}|{desc}")
SNIPY
)
                        if [ -n "$SNI_LIST" ]; then
                            idx=1
                            SNI_ARR=()
                            while IFS='|' read -r tag f1 f2 f3; do
                                [ -z "$tag" ] && continue
                                if [ "$tag" = "HDR" ]; then
                                    echo ""
                                    printf "  ${SKY}【%s】${R}\n" "$f1"
                                elif [ "$tag" = "ITEM" ]; then
                                    SNI_ARR+=("$f1")
                                    printf "    ${GREEN}%2d)${R} ${WHITE}%-23s${R} ${DIM}(${YELLOW}%6s ms${DIM} | ${CYAN}%s${DIM})${R}\n" "$idx" "$f1" "$f2" "$f3"
                                    idx=$((idx + 1))
                                fi
                            done <<< "$SNI_LIST"
                            echo ""
                            read -rp "$(printf "  ${YELLOW}-> 请选择编号 [1-${#SNI_ARR[@]}] (回车默认 1): ${R}")" PICK_IDX
                            PICK_IDX="${PICK_IDX:-1}"
                            if [[ "$PICK_IDX" =~ ^[0-9]+$ ]] && [ "$PICK_IDX" -ge 1 ] && [ "$PICK_IDX" -le "${#SNI_ARR[@]}" ]; then
                                REALITY_SNI="${SNI_ARR[$((PICK_IDX - 1))]}"
                            else
                                REALITY_SNI="${SNI_ARR[0]}"
                            fi
                            printf "  ${ORANGE}-> 已选定目标 SNI: ${WHITE}%s${R}\n" "$REALITY_SNI"
                            verify_reality_sni "$REALITY_SNI"
                        else
                            printf "  ${ORANGE}-> [提示] 测速未命中可用站点，自动回退 addons.mozilla.org${R}\n"
                            REALITY_SNI="addons.mozilla.org"
                        fi
                    else
                        printf "  ${ORANGE}-> [提示] 当前环境尚未安装 python3，自动回退 addons.mozilla.org${R}\n"
                        REALITY_SNI="addons.mozilla.org"
                    fi
                    ;;
                2) REALITY_SNI="addons.mozilla.org" ;;
                3) REALITY_SNI="www.gentoo.org" ;;
                4)
                    read -rp "$(printf "  ${YELLOW}-> 请输入自定义目标域名 (如 www.example.com): ${R}")" SNI_CUSTOM
                    REALITY_SNI="${SNI_CUSTOM:-addons.mozilla.org}"
                    verify_reality_sni "$REALITY_SNI"
                    ;;
                *) REALITY_SNI="addons.mozilla.org" ;;
            esac
            read -rp "$(printf "  ${YELLOW}是否一键中转到后端海外家宽机？[y/N]: ${R}")" ENABLE_RELAY
            ENABLE_RELAY="${ENABLE_RELAY:-n}"
            if [[ "$ENABLE_RELAY" =~ ^[Yy]$ ]]; then
                prompt_relay_target
            fi
        fi
        ;;
    2)
        read -rp "$(printf "  ${YELLOW}请输入 Cloudflare 回源端口 (回车默认 2053，支持 443/2053/2083/8443): ${R}")" LISTEN_PORT
        LISTEN_PORT="${LISTEN_PORT:-2053}"
        read -rp "$(printf "  ${YELLOW}请输入 Cloudflare CDN 域名 (如 cf.example.com): ${R}")" CF_IN
        CF_DOMAIN="${CF_IN:-cf.example.com}"
        ;;
    3)
        read -rp "$(printf "  ${YELLOW}请输入 Hysteria 2 本地 UDP 监听端口 (回车默认 8443 以错开 TCP 443，也可填 443): ${R}")" LISTEN_PORT
        LISTEN_PORT="${LISTEN_PORT:-8443}"
        read -rp "$(printf "  ${YELLOW}是否为廉价高丢包线路开启 Brutal？(CN2/9929 精品线强烈选 n) [y/N]: ${R}")" HY2_BRUTAL
        HY2_BRUTAL="${HY2_BRUTAL:-n}"
        read -rp "$(printf "  ${YELLOW}是否一键中转到后端海外家宽机？[y/N]: ${R}")" ENABLE_RELAY
        ENABLE_RELAY="${ENABLE_RELAY:-n}"
        if [[ "$ENABLE_RELAY" =~ ^[Yy]$ ]]; then
            prompt_relay_target
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
    6|links)
        echo ""
        SSH_PORT_SHOW=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}' || true)
        SSH_PORT_SHOW="${SSH_PORT_SHOW:-22}"
        SERVER_IP="$SERVER_IP" SSH_PORT_SHOW="$SSH_PORT_SHOW" python3 - << 'EXPPY'
import sqlite3, json, os, subprocess, urllib.parse, base64, shutil

def print_qr(url):
    if shutil.which('qrencode') and url:
        try:
            subprocess.run(['qrencode', '-t', 'ANSIUTF8', '-m', '1', url], check=False)
        except Exception:
            pass

server_ip = os.environ.get('SERVER_IP', 'YOUR_SERVER_IP')
ssh_port = os.environ.get('SSH_PORT_SHOW', '22')
db_path = '/etc/x-ui/x-ui.db'

print("==================================================================")
print("  【节点分享链接一键导出】")
print("==================================================================")
found = 0
if os.path.exists(db_path):
    conn = sqlite3.connect(db_path)
    c = conn.cursor()
    for remark, port, proto, s_str, st_str, enable in c.execute(
        "SELECT remark, port, protocol, settings, stream_settings, enable FROM inbounds"
    ).fetchall():
        if not enable:
            continue
        s = json.loads(s_str or '{}')
        st = json.loads(st_str or '{}')
        if proto == 'vless':
            clients = s.get('clients', [])
            if not clients:
                continue
            u = clients[0].get('id', '')
            flow = clients[0].get('flow', '')
            net = st.get('network', 'tcp')
            sec = st.get('security', 'none')
            r_enc = urllib.parse.quote(remark or f'VLESS-{port}')
            if sec == 'reality':
                rs = st.get('realitySettings', {})
                pbk = rs.get('settings', {}).get('publicKey', '')
                sni = (rs.get('serverNames') or ['addons.mozilla.org'])[0]
                sid = (rs.get('shortIds') or [''])[0]
                if net == 'xhttp':
                    path = urllib.parse.quote(st.get('xhttpSettings', {}).get('path', '/vless-xhttp'), safe='')
                    link = f"vless://{u}@{server_ip}:{port}?type=xhttp&path={path}&mode=auto&security=reality&pbk={pbk}&fp=chrome&sni={sni}&sid={sid}&spx=%2F#{r_enc}"
                else:
                    fl = f"&flow={flow}" if flow else ""
                    link = f"vless://{u}@{server_ip}:{port}?type=tcp&security=reality&pbk={pbk}&fp=chrome&sni={sni}&sid={sid}&spx=%2F{fl}#{r_enc}"
                print(f"  [{remark}] {link}")
                print_qr(link)
                found += 1
            elif sec == 'tls':
                sni = st.get('tlsSettings', {}).get('serverName', server_ip)
                if net == 'xhttp':
                    path = urllib.parse.quote(st.get('xhttpSettings', {}).get('path', '/vless-xhttp'), safe='')
                    link = f"vless://{u}@{sni}:{port}?type=xhttp&path={path}&mode=auto&host={sni}&security=tls&sni={sni}#{r_enc}"
                else:
                    path = urllib.parse.quote(st.get('wsSettings', {}).get('path', '/'), safe='')
                    link = f"vless://{u}@{sni}:{port}?type={net}&path={path}&host={sni}&security=tls&sni={sni}#{r_enc}"
                print(f"  [{remark}] {link}")
                print_qr(link)
                found += 1
        elif proto == 'shadowsocks':
            method = s.get('method', '')
            pwd = s.get('password', '')
            if method and pwd:
                cred = base64.urlsafe_b64encode(f"{method}:{pwd}".encode()).decode().rstrip('=')
                print(f"  [{remark}] ss://{cred}@{server_ip}:{port}#{urllib.parse.quote(remark or f'SS-{port}')}")
                print(f"    (家宽中转参数: IP={server_ip} | PORT={port} | PASS={pwd})")
                found += 1

    kv = dict(c.execute("SELECT key, value FROM settings WHERE key IN ('webPort','webBasePath','webListen')").fetchall())
    conn.close()
else:
    kv = {}

if os.path.exists('/etc/hysteria/config.yaml'):
    hy_port = '8443'
    hy_pass = ''
    for line in open('/etc/hysteria/config.yaml'):
        ls = line.strip()
        if ls.startswith('listen:'):
            hy_port = ls.split(':')[-1].strip()
        elif ls.startswith('password:'):
            hy_pass = ls.split(':', 1)[1].strip().strip('"').strip("'")
    pin = ''
    if os.path.exists('/etc/hysteria/server.crt'):
        try:
            pin = subprocess.check_output(
                ['openssl', 'x509', '-in', '/etc/hysteria/server.crt', '-noout', '-sha256', '-fingerprint'],
                text=True
            ).split('=', 1)[1].strip()
        except Exception:
            pass
    if hy_pass:
        hy_url = f"hysteria2://{hy_pass}@{server_ip}:{hy_port}?insecure=1&sni=www.bing.com&pinSHA256={pin}&mport=20000-50000#Hysteria2-PortHopping"
        print(f"  [Hysteria2] {hy_url}")
        print_qr(hy_url)
        found += 1

if not found:
    print("  (当前未检测到已启用的节点)")

if kv:
    wport = kv.get('webPort', '2053')
    wbase = kv.get('webBasePath', '/')
    if not wbase.startswith('/'):
        wbase = '/' + wbase
    print("")
    print("==================================================================")
    print("  【3x-ui 面板安全访问指南（面板已锁死 127.0.0.1）】")
    print("==================================================================")
    print("  1) 在你本地电脑终端执行以下命令建立加密隧道（保持窗口不关）：")
    print(f"     ssh -N -L 20530:127.0.0.1:{wport} root@{server_ip} -p {ssh_port}")
    print("  2) 然后本地浏览器直接打开：")
    print(f"     https://127.0.0.1:20530{wbase}")
print("==================================================================")
EXPPY
        exit 0
        ;;
    *)
        echo "[错误] 无效的方案编号: ${MODE}，仅支持 1 / 2 / 3 / 4 / 5 / 6"
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
apt-get install -y curl wget unzip chrony iptables nftables iptables-persistent sqlite3 fail2ban python3 python3-systemd openssl qrencode || \
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
    bash <(curl -Ls https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh) "$XUI_VERSION" <<< "n"
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
XRAY_VER_OUT=$(/tmp/xray-install/xray version)
[[ "$XRAY_VER_OUT" == *"$XRAY_VER_NUM"* ]]
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
    and not (r.get('outboundTag') == 'blocked' and str(r.get('port', '')) == '25' and not r.get('ip') and not r.get('domain'))
    and not (inbound_tag_for_relay and r.get('inboundTag') == [inbound_tag_for_relay] and str(r.get('outboundTag', '')).startswith('out-res'))
]
if relay_tag and inbound_tag_for_relay:
    custom_rules.append({'type': 'field', 'inboundTag': [inbound_tag_for_relay], 'outboundTag': relay_tag})

cfg.setdefault('routing', {})['domainStrategy'] = 'IPOnDemand'
cfg['routing']['rules'] = [
    {'type': 'field', 'inboundTag': ['api'], 'outboundTag': 'api'},
    {'type': 'field', 'outboundTag': 'blocked', 'ip': ['geoip:private']},
    {'type': 'field', 'outboundTag': 'blocked', 'protocol': ['bittorrent']},
    {'type': 'field', 'outboundTag': 'blocked', 'port': '25'},
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
    chain output {
        type filter hook output priority filter; policy accept;
        tcp dport 25 reject with tcp reset
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
PANEL_SCHEME=$(python3 -c "import sqlite3; r=sqlite3.connect('/etc/x-ui/x-ui.db').execute(\"SELECT value FROM settings WHERE key='webCertFile' LIMIT 1\").fetchone(); print('https' if r and r[0] and r[0].strip() else 'http')" 2>/dev/null || echo "http")
SSH_PORT_NOW=$(sshd -T 2>/dev/null | awk '$1=="port"{print $2; exit}' || true)
SSH_PORT_NOW="${SSH_PORT_NOW:-22}"
SSH_P_FLAG=""
[ "$SSH_PORT_NOW" != "22" ] && SSH_P_FLAG="-p ${SSH_PORT_NOW} "

echo ""
echo "=================================================================="
echo "  部署完成！服务状态验收："
echo "  - x-ui          : $(systemctl is-active x-ui 2>/dev/null || true)"
[ "$MODE" = "3" ] && echo "  - hysteria      : $(systemctl is-active hysteria-server 2>/dev/null || true)"
echo "  - Xray 内核     : $($XRAY_BIN version | head -n 1)"
echo "------------------------------------------------------------------"
echo "  3x-ui 面板已锁定 127.0.0.1:${PANEL_PORT}，本地 SSH 隧道访问命令："
echo "  ssh ${SSH_P_FLAG}-L ${PANEL_PORT}:127.0.0.1:${PANEL_PORT} root@${SERVER_IP}"
echo "  本地浏览器打开: ${PANEL_SCHEME}://127.0.0.1:${PANEL_PORT}/${PANEL_PATH}"
if [ -f /tmp/setup_result.txt ]; then
    if grep -q "RESULT_TYPE=RESIDENTIAL_SS" /tmp/setup_result.txt; then
        echo "------------------------------------------------------------------"
        echo "  【家宽落地 SS-2022 中转凭据】（请复制到前置优化机脚本中）："
        grep -E "^SS_(IP|PORT|PASS)=" /tmp/setup_result.txt | sed 's/^/  /'
    elif grep -q "RESULT_TYPE=LINK" /tmp/setup_result.txt; then
        echo "------------------------------------------------------------------"
        echo "  【客户端导入链接】："
        SHARE_URL=$(grep "^SHARE_LINK=" /tmp/setup_result.txt | cut -d'=' -f2-)
        echo "  ${SHARE_URL}"
        if command -v qrencode >/dev/null 2>&1 && [ -n "$SHARE_URL" ]; then
            echo "  【手机扫码导入（Shadowrocket / v2rayNG / Stash）】："
            qrencode -t ANSIUTF8 -m 1 "$SHARE_URL" || true
        fi
    fi
    rm -f /tmp/setup_result.txt
fi
if [ "$MODE" = "2" ]; then
    echo "------------------------------------------------------------------"
    echo "  【Cloudflare 后台 4 步检查清单（小白照着点）】："
    echo "  1. DNS 添加 A 记录: ${CF_DOMAIN} -> ${SERVER_IP}（务必开启小黄云 Proxied）"
    echo "  2. SSL/TLS 加密模式设为: Full（自签证书勿选 Flexible 或 Full Strict，防 525/526）"
    echo "  3. 云厂商安全组放行: TCP ${LISTEN_PORT}（CF 支持 443/2053/2083/2087/2096/8443）"
    echo "  4. 客户端优选提速: 仅改「地址(Address)」为优选 IP/域名，Host 与 SNI 保持 ${CF_DOMAIN} 不变"
fi
if [ -n "$HY2_LINK" ]; then
    echo "------------------------------------------------------------------"
    echo "  【Hysteria 2 导入链接】："
    echo "  ${HY2_LINK}"
    if command -v qrencode >/dev/null 2>&1; then
        echo "  【手机扫码导入（Shadowrocket / v2rayNG / Stash）】："
        qrencode -t ANSIUTF8 -m 1 "$HY2_LINK" || true
    fi
fi
echo -e "${CYAN}══════════════════════════════════════════════════════════════════"
echo -e "  本脚本由 猫e/acc (CatEacc) 维护提供"
echo -e "  GitHub : https://github.com/CatEacc/vps-xray-runbook"
echo -e "  TG 频道: https://t.me/CatCryptoMaster"
echo -e "══════════════════════════════════════════════════════════════════${NC}"
