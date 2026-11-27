#!/bin/bash
# ==============================================================================
# 生产级 VPS 一键部署与调优脚本 (CatEacc/vps-xray-runbook)
# 适用系统: Debian 11/12/13, Ubuntu 20.04/22.04/24.04 (AMD64 / ARM64)
# 核心版本: 3x-ui v3.11.0 | Xray-core v26.11.9 | Hysteria 2 (Latest)
# 八大模式:
#   1) VLESS + REALITY (XHTTP / Vision，回车默认 443，内置一键家宽落地/一键中转)
#   2) Cloudflare CDN 优选 (VLESS + XHTTP + TLS，回车默认 2053)
#   3) Hysteria 2 + 20000-50000 端口跳跃 (错开端口防冲突，可选一键中转家宽)
#   4) 纯系统底层内核调优模式 (不装任何代理面板)
#   5) 一键回滚系统底层调优
#   6) 一键只读导出所有节点链接、二维码与 SSH 面板隧道命令
#   7) 本机家宽 / 商宽 / 机房 IP 与环境只读快检
#   8) REALITY 优选 SNI 测速与域名四重体检 (纯只读，零改动筛域名)
# ==============================================================================

set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
trap 'rm -rf /tmp/setup_result.txt /tmp/xray-install' EXIT

XUI_VERSION="v3.11.0"
XRAY_VERSION="v26.11.9"
XRAY_VER_NUM="26.11.9"

if [ "$(id -u)" != "0" ]; then
    echo "[错误] 必须以 root 用户运行此脚本！请先执行 sudo -i"
    exit 1
fi

SERVER_IP=$(curl -4fsSm 4 https://api.ipify.org 2>/dev/null || curl -4fsSm 4 https://ipv4.icanhazip.com 2>/dev/null || curl -6fsSm 4 https://api64.ipify.org 2>/dev/null || echo "YOUR_SERVER_IP")
SERVER_IP=$(printf "%s" "$SERVER_IP" | tr -d '[:space:]')
[[ "$SERVER_IP" =~ ^[0-9a-fA-F.:]+$ ]] || SERVER_IP="YOUR_SERVER_IP"
OS_INFO=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-Linux}" || uname -s)
KERNEL_INFO=$(uname -r | cut -d'-' -f1)
ARCH_INFO=$(uname -m)
MEM_SHOW=$(LC_ALL=C free -m 2>/dev/null | awk '/^Mem:/ {print $2}')
MEM_SHOW="${MEM_SHOW:-0}"
BBR_STAT=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
MPTCP_STAT=$(sysctl -n net.mptcp.enabled 2>/dev/null || echo "0")

# 256 色丝滑渐变配色
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
SCRIPT_VER="${SCRIPT_VER:-v1.2.6}"

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
    elif systemctl list-unit-files "${1}.service" 2>/dev/null | grep -q "^${1}\.service"; then
        printf "${YELLOW}● 已停止${R}"
    else
        printf "${DIM}○ 未安装${R}"
    fi
}

validate_port() {
    local p="$1" def="$2"
    if [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]; then
        echo "$p"
    else
        printf "  ${ORANGE}-> [提示] 端口 '%s' 非法，已自动使用默认端口 %s${R}\n" "$p" "$def" >&2
        echo "$def"
    fi
}

clean_domain() {
    printf "%s" "$1" | sed -E 's#^https?://##; s#/.*$##; s#:[0-9]+$##' | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]'
}

# ------------------------------------------------------------------------------
# 0. 交互菜单（也支持命令行传参: bash setup.sh [1-8|sni]）
# ------------------------------------------------------------------------------
MODE="${1:-}"
SNI_QUERY_ARG="${2:-}"
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
    printf "      ${DIM}仅部署 BBR / 按内存分档缓冲 / 1GB Swap / MPTCP 防护 / 默认封 TCP 25 / Fail2ban${R}\n"
    printf "  ${GREEN}[5]${R} ${WHITE}一键回滚系统底层调优${R} ${DIM}· 恢复原厂内核/日志/Swap 快照${R}\n"
    printf "  ${GREEN}[6]${R} ${WHITE}一键导出所有节点链接 & 面板访问命令${R} ${CYAN}· 只读${R}\n"
    printf "  ${GREEN}[7]${R} ${WHITE}本机家宽 / 商宽 / 机房 IP 与环境快检${R} ${SKY}· 只读 · 不测流媒体${R}\n"
    printf "  ${GREEN}[8]${R} ${WHITE}REALITY 优选 SNI 测速与域名四重体检${R} ${CYAN}· 只读 · 零改动筛域名${R}\n\n"
    read -rp "$(printf "${YELLOW}  请输入方案编号 [1-8] (回车默认 1): ${R}")" MODE || MODE="1"
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
            "measurementOptions": {"protocol": "HTTPS", "port": 443, "request": {"method": "HEAD", "path": "/"}}
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
    warns = []
    if ver != "TLSv1.3":
        warns.append(f"TLS={ver}(非TLSv1.3)")
    if alpn != "h2":
        warns.append(f"ALPN={alpn}(非h2)")
    if is_cf:
        warns.append("背后套了 Cloudflare CDN，易被扫作免费 CF 反代 IP")
    if cn_warn:
        warns.append(cn_warn)
    if warns:
        print(f"WARN|{'; '.join(warns)} ({ver}+{alpn}, {rtt:.1f} ms)")
    else:
        print(f"OK|{ver} + {alpn} | 非 CF | {cn_note} ({rtt:.1f} ms)")
except Exception as e:
    print(f"WARN|{e}")
CHKPY
) || true
    if [[ "$chk_out" == OK\|* ]]; then
        printf "  ${GREEN}-> [实时复检通过]${R} ${WHITE}%s${R}: ${GREEN}%s${R}\n" "$target_sni" "${chk_out#OK|}"
        return 0
    else
        printf "  ${RED}-> [实时复检警告]${R} ${WHITE}%s${R}: ${ORANGE}%s${R}\n" "$target_sni" "${chk_out#WARN|}"
        return 1
    fi
}

SNI_ARR=()
run_sni_speedtest_table() {
    SNI_ARR=()
    command -v python3 >/dev/null 2>&1 || return 1
    local vps_cc sni_list idx tag f1 f2 f3
    vps_cc=$( (curl -fsSm 2 https://ipinfo.io/country 2>/dev/null || curl -fsSm 2 https://ifconfig.co/country-iso 2>/dev/null || true) | tr -dc 'A-Za-z' | tr '[:lower:]' '[:upper:]' | head -c 2 )
    echo ""
    printf "  ${YELLOW}[说明]${R} ${DIM}REALITY 选站铁律：纯海外、TLSv1.3+H2、非 CF、无国内 CDN、国内直连可达，同地区低延迟更自然。${R}\n"
    printf "  ${SKY}-> 正在并发测速当前地区 (${CYAN}${vps_cc:-GLOBAL}${SKY}) 本土站 + 全球通用兜底池...${R}\n"
    sni_list=$(VPS_CC="$vps_cc" python3 - << 'SNIPY'
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
        ("www.nus.edu.sg",        "新加坡国立大学"),
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
) || true
    [ -n "$sni_list" ] || return 1
    idx=1
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
    done <<< "$sni_list"
    [ "${#SNI_ARR[@]}" -gt 0 ]
}

readonly_sni_menu() {
    local arg_dom="${1:-}" pick="" check_dom=""
    echo ""
    command -v python3 >/dev/null 2>&1 || { echo "  [提示] 当前系统缺少 python3，请先执行 apt-get update && apt-get install -y python3"; exit 1; }
    echo "=================================================================="
    echo "  REALITY 优选 SNI 测速与域名四重体检（纯只读，不修改本机任何配置）"
    echo "=================================================================="
    if [ -n "$arg_dom" ]; then
        check_dom=$(clean_domain "$arg_dom")
        if [[ ! "$check_dom" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
            echo "  [错误] 域名格式非法: ${check_dom}"
            exit 1
        fi
        if verify_reality_sni "$check_dom"; then
            printf "  ${GREEN}-> [可直接填入]${R} SNI: ${WHITE}%s${R}  |  Dest: ${WHITE}%s:443${R}\n" "$check_dom" "$check_dom"
        else
            printf "  ${ORANGE}-> [不建议选用]${R} %s 存在风险项，建议改用无警告的本土非 CF 域名\n" "$check_dom"
        fi
        echo "=================================================================="
        exit 0
    fi

    if run_sni_speedtest_table; then
        if [ ! -t 0 ]; then
            echo ""
            verify_reality_sni "${SNI_ARR[0]}" || true
            printf "  ${GREEN}-> [推荐参数]${R} SNI: ${WHITE}%s${R}  |  Dest: ${WHITE}%s:443${R} ${DIM}(纯只读未改配置)${R}\n" "${SNI_ARR[0]}" "${SNI_ARR[0]}"
            echo "=================================================================="
            exit 0
        fi
        echo ""
        read -rp "$(printf "  ${YELLOW}-> 输入编号 [1-${#SNI_ARR[@]}] 或自定义域名做四重体检 (回车默认测第 1 名，q 退出): ${R}")" pick || pick="q"
        if [[ "${pick:-}" =~ ^[Qq0]$ ]]; then
            echo "=================================================================="
            exit 0
        fi
        if [ -z "${pick:-}" ]; then
            check_dom="${SNI_ARR[0]}"
            if verify_reality_sni "$check_dom"; then
                printf "  ${GREEN}-> [推荐参数]${R} SNI: ${WHITE}%s${R}  |  Dest: ${WHITE}%s:443${R} ${DIM}(纯只读未改配置)${R}\n" "$check_dom" "$check_dom"
            else
                printf "  ${ORANGE}-> [提示]${R} %s 存在告警，建议从上方列表另选其它候选站\n" "$check_dom"
            fi
            echo "=================================================================="
            exit 0
        fi
        while [ -n "${pick:-}" ] && [[ ! "$pick" =~ ^[Qq0]$ ]]; do
            if [[ "$pick" =~ ^[0-9]+$ ]] && [ "$pick" -ge 1 ] && [ "$pick" -le "${#SNI_ARR[@]}" ]; then
                check_dom="${SNI_ARR[$((pick - 1))]}"
            else
                check_dom=$(clean_domain "$pick")
            fi
            if [[ "$check_dom" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
                if verify_reality_sni "$check_dom"; then
                    printf "  ${GREEN}-> [可直接填入]${R} SNI: ${WHITE}%s${R}  |  Dest: ${WHITE}%s:443${R}\n" "$check_dom" "$check_dom"
                else
                    printf "  ${ORANGE}-> [不建议选用]${R} %s 存在上述风险项，请换其它本土非 CF 域名\n" "$check_dom"
                fi
            else
                printf "  ${ORANGE}-> [提示] 域名或编号格式无效: %s${R}\n" "$pick"
            fi
            echo ""
            read -rp "$(printf "  ${YELLOW}-> 继续输入其他编号或自定义域名体检 (直接回车退出): ${R}")" pick || break
        done
    else
        printf "  ${ORANGE}-> [提示] 候选池测速未命中可用站点，可直接输入自定义域名体检：${R}\n"
        if [ -t 0 ]; then
            read -rp "$(printf "  ${YELLOW}-> 请输入要体检的域名 (直接回车退出): ${R}")" pick || pick=""
            if [ -n "${pick:-}" ]; then
                check_dom=$(clean_domain "$pick")
                if [[ "$check_dom" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
                    verify_reality_sni "$check_dom" || true
                else
                    printf "  ${ORANGE}-> [提示] 域名格式无效: %s${R}\n" "$pick"
                fi
            fi
        fi
    fi
    echo "=================================================================="
    exit 0
}

prompt_relay_target() {
    printf "\n  ${CYAN}─── 后端家宽中转对接方式 ───${R}\n"
    printf "  ${GREEN}[1]${R} ${WHITE}粘贴 ss:// 分享链接${R} ${DIM}(自动解析 IP/端口/密钥，也支持直接输入 IP 手填)${R}\n"
    printf "  ${GREEN}[2]${R} ${WHITE}全自动远程部署家宽机并对接${R} ${PINK}★ 终极懒人版 · 填 SSH 账密自动装好并拉回凭据${R}\n"
    read -rp "$(printf "  ${YELLOW}请选择对接方式 [1-2] (回车默认 1): ${R}")" RELAY_MODE
    RELAY_MODE="${RELAY_MODE:-1}"

    if [ "$RELAY_MODE" = "2" ]; then
        read -rp "$(printf "  ${SKY}-> 后端家宽机 SSH IP: ${R}")" RES_SSH_IP
        RES_SSH_IP=$(printf "%s" "$RES_SSH_IP" | tr -d '[:space:]')
        read -rp "$(printf "  ${SKY}-> 后端家宽机 SSH 端口 (回车默认 22): ${R}")" RES_SSH_PORT
        RES_SSH_PORT=$(validate_port "${RES_SSH_PORT:-22}" 22)
        read -rsp "$(printf "  ${SKY}-> 后端家宽机 root 密码 (输入不回显，仅内存生效不落盘): ${R}")" RES_SSH_PASS
        echo ""
        local safe_src_ip=""
        if [[ "$SERVER_IP" =~ ^[0-9a-fA-F.:]+$ ]]; then
            safe_src_ip="$SERVER_IP"
        fi
        if [[ "$RES_SSH_IP" =~ ^[a-zA-Z0-9.:-]+$ ]] && [ -n "$RES_SSH_PASS" ]; then
            if ! command -v sshpass >/dev/null 2>&1; then
                printf "  ${DIM}-> 正在安装 sshpass 以进行自动化对接...${R}\n"
                export DEBIAN_FRONTEND=noninteractive
                apt-get -o DPkg::Lock::Timeout=60 update -qq && apt-get -o DPkg::Lock::Timeout=60 install -y -qq sshpass >/dev/null 2>&1 || true
            fi
            printf "  ${CYAN}-> 正在连接家宽机 %s:%s 自动部署 SS-2022 落地并添加本机白名单 (%s)...${R}\n" "$RES_SSH_IP" "$RES_SSH_PORT" "${safe_src_ip:-无}"
            local remote_out=""
            if command -v sshpass >/dev/null 2>&1; then
                remote_out=$(SSHPASS="$RES_SSH_PASS" sshpass -e ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -p "$RES_SSH_PORT" "root@${RES_SSH_IP}" \
                    "curl -fsSL https://raw.githubusercontent.com/CatEacc/vps-xray-runbook/main/setup.sh -o /tmp/_res_setup.sh && printf '3\n\n%s\n' '${safe_src_ip}' | bash /tmp/_res_setup.sh 1; rm -f /tmp/_res_setup.sh" 2>&1 || true)
            fi
            unset RES_SSH_PASS SSHPASS
            RES_IP=$(printf "%s\n" "$remote_out" | grep -oE 'SS_IP=[^[:space:]]+' | tail -n 1 | cut -d'=' -f2- || true)
            RES_PORT=$(printf "%s\n" "$remote_out" | grep -oE 'SS_PORT=[0-9]+' | tail -n 1 | cut -d'=' -f2- || true)
            RES_SS_PASS=$(printf "%s\n" "$remote_out" | grep -oE 'SS_PASS=[^[:space:]]+' | tail -n 1 | cut -d'=' -f2- || true)
            if [ -z "$RES_IP" ] || [ "$RES_IP" = "YOUR_SERVER_IP" ] || [ "$RES_IP" = "未知" ]; then
                RES_IP="$RES_SSH_IP"
            fi
            if [ -n "$RES_IP" ] && [ -n "$RES_PORT" ] && [ -n "$RES_SS_PASS" ]; then
                printf "  ${GREEN}-> [自动对接成功]${R} 家宽落地已就绪: ${CYAN}%s:%s${R} (已自动白名单放行本机 IP)\n" "$RES_IP" "$RES_PORT"
                return 0
            else
                printf "  ${ORANGE}-> [提示] 远程自动部署未能获取凭据（请检查密码/网络），自动切换为方式 1 手动粘贴：${R}\n"
            fi
        else
            unset RES_SSH_PASS SSHPASS
            printf "  ${ORANGE}-> [提示] IP 格式非法或密码为空，自动切换为方式 1：${R}\n"
        fi
    fi

    read -rp "$(printf "  ${YELLOW}-> 请粘贴家宽 ss:// 链接，或直接输入家宽机 IP: ${R}")" SS_OR_IP
    if [[ "$SS_OR_IP" == ss://* ]] && command -v python3 >/dev/null 2>&1; then
        local parsed
        parsed=$(SS_URI="$SS_OR_IP" python3 - << 'SSPY'
import os, base64, urllib.parse
u = os.environ.get("SS_URI", "").strip()
body = u[5:].split("#", 1)[0].split("?", 1)[0].rstrip("/")
def b64dec(s):
    s = urllib.parse.unquote(s).strip()
    pad = "=" * (-len(s) % 4)
    for fn in (base64.urlsafe_b64decode, base64.b64decode):
        try:
            return fn(s + pad).decode("utf-8")
        except Exception:
            pass
    return s
if "@" not in body:
    body = b64dec(body)
if "@" in body:
    cred, hp = body.rsplit("@", 1)
    cred_dec = urllib.parse.unquote(cred)
    if ":" not in cred_dec:
        cred_dec = b64dec(cred_dec)
    pwd = cred_dec.split(":", 1)[1] if ":" in cred_dec else cred_dec
    if ":" in hp:
        host, port = hp.rsplit(":", 1)
        port = port.strip()
        if port.isdigit() and 1 <= int(port) <= 65535:
            print(f"{host.strip('[]')}|{port}|{pwd.strip()}")
SSPY
) || true
        if [ -n "$parsed" ]; then
            IFS='|' read -r RES_IP RES_PORT RES_SS_PASS <<< "$parsed"
            printf "  ${GREEN}-> [解析成功]${R} 目标家宽: ${CYAN}%s:%s${R} ${DIM}(密钥已自动提取)${R}\n" "$RES_IP" "$RES_PORT"
            return 0
        else
            printf "  ${ORANGE}-> [提示] ss:// 链接解析失败，请改为分步输入：${R}\n"
            read -rp "$(printf "  ${SKY}-> 请输入后端家宽机 IP: ${R}")" RES_IP
        fi
    else
        RES_IP=$(printf "%s" "$SS_OR_IP" | tr -d '[:space:]')
    fi
    read -rp "$(printf "  ${SKY}-> 请输入后端家宽机 SS-2022 端口: ${R}")" RES_PORT
    RES_PORT=$(validate_port "${RES_PORT:-30001}" 30001)
    read -rp "$(printf "  ${SKY}-> 请输入后端家宽机 SS-2022 密钥 (Base64): ${R}")" RES_SS_PASS
    RES_SS_PASS=$(printf "%s" "$RES_SS_PASS" | tr -d '[:space:]')
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
            LISTEN_PORT=$(validate_port "${LISTEN_PORT:-$DEF_PORT}" "$DEF_PORT")
            read -rp "$(printf "  ${YELLOW}请输入允许连入的前置优化机 IP（留空则不设白名单，多个用逗号分隔）: ${R}")" RES_WHITELIST_IP
        else
            read -rp "$(printf "  ${YELLOW}请输入 REALITY 监听端口 (回车默认 443，也可手动输入如 8443): ${R}")" LISTEN_PORT
            LISTEN_PORT=$(validate_port "${LISTEN_PORT:-443}" 443)
            printf "\n  ${CYAN}─── 请选择 REALITY 回落目标域名 (SNI) ───${R}\n"
            printf "  ${GREEN}[1]${R} ${WHITE}按机房地区自动测速优选${R} ${ORANGE}★ 推荐：本土 5 站 + 全球兜底池 + 选后自动实时复检${R}\n"
            printf "  ${GREEN}[2]${R} ${WHITE}addons.mozilla.org${R}     ${DIM}（免测默认：Firefox 扩展商店 · 纯海外无国内 CDN）${R}\n"
            printf "  ${GREEN}[3]${R} ${WHITE}www.gentoo.org${R}         ${DIM}（免测默认：Gentoo Linux 官网 · 非 CF 国内直连可达）${R}\n"
            printf "  ${GREEN}[4]${R} ${WHITE}手动输入自定义域名${R}     ${DIM}（自动四重体检 TLS 1.3+H2 / 非 CF / 国内 CDN / 是否被墙）${R}\n"
            read -rp "$(printf "  ${YELLOW}请输入选项 [1-4] (回车默认 1): ${R}")" SNI_OPT
            case "${SNI_OPT:-1}" in
                1)
                    if run_sni_speedtest_table; then
                        echo ""
                        read -rp "$(printf "  ${YELLOW}-> 请选择编号 [1-${#SNI_ARR[@]}] (回车默认 1): ${R}")" PICK_IDX
                        PICK_IDX="${PICK_IDX:-1}"
                        if [[ "$PICK_IDX" =~ ^[0-9]+$ ]] && [ "$PICK_IDX" -ge 1 ] && [ "$PICK_IDX" -le "${#SNI_ARR[@]}" ]; then
                            REALITY_SNI="${SNI_ARR[$((PICK_IDX - 1))]}"
                        else
                            REALITY_SNI="${SNI_ARR[0]}"
                        fi
                        printf "  ${ORANGE}-> 已选定目标 SNI: ${WHITE}%s${R}\n" "$REALITY_SNI"
                        verify_reality_sni "$REALITY_SNI" || true
                    else
                        printf "  ${ORANGE}-> [提示] 测速未命中或尚未安装 python3，自动回退 addons.mozilla.org${R}\n"
                        REALITY_SNI="addons.mozilla.org"
                    fi
                    ;;
                2) REALITY_SNI="addons.mozilla.org" ;;
                3) REALITY_SNI="www.gentoo.org" ;;
                4)
                    read -rp "$(printf "  ${YELLOW}-> 请输入自定义目标域名 (如 www.example.com): ${R}")" SNI_CUSTOM
                    REALITY_SNI=$(clean_domain "${SNI_CUSTOM:-addons.mozilla.org}")
                    if [[ ! "$REALITY_SNI" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
                        printf "  ${ORANGE}-> [提示] 域名格式异常，已回退 addons.mozilla.org${R}\n"
                        REALITY_SNI="addons.mozilla.org"
                    fi
                    verify_reality_sni "$REALITY_SNI" || true
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
        read -rp "$(printf "  ${YELLOW}请输入 Cloudflare 回源端口 (回车默认 2053，支持 443/2053/2083/2087/2096/8443): ${R}")" LISTEN_PORT
        LISTEN_PORT=$(validate_port "${LISTEN_PORT:-2053}" 2053)
        case "$LISTEN_PORT" in
            443|2053|2083|2087|2096|8443) ;;
            *) printf "  ${ORANGE}-> [警告] 端口 %s 不在 Cloudflare 免费版 HTTPS 端口列表 (443/2053/2083/2087/2096/8443) 中，开启小黄云将无法回源！${R}\n" "$LISTEN_PORT" ;;
        esac
        read -rp "$(printf "  ${YELLOW}请输入 Cloudflare CDN 域名 (如 cf.example.com): ${R}")" CF_IN
        CF_DOMAIN=$(clean_domain "${CF_IN:-cf.example.com}")
        if [[ ! "$CF_DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
            echo "[错误] Cloudflare 域名格式非法: ${CF_DOMAIN}"
            exit 1
        fi
        ;;
    3)
        read -rp "$(printf "  ${YELLOW}请输入 Hysteria 2 本地 UDP 监听端口 (回车默认 8443 以错开 TCP 443，也可填 443): ${R}")" LISTEN_PORT
        LISTEN_PORT=$(validate_port "${LISTEN_PORT:-8443}" 8443)
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
        elif [ -f /etc/systemd/journald.conf ] && [ -f "${BACKUP_DIR}/snapshot.done" ]; then
            rm -f /etc/systemd/journald.conf
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
        command -v python3 >/dev/null 2>&1 || { echo "  [提示] 当前系统缺少 python3，请先执行 apt-get update && apt-get install -y python3"; exit 1; }
        mkdir -p /run/sshd 2>/dev/null || true
        SSH_PORT_SHOW=$( (sshd -T 2>/dev/null || true) | awk '$1=="port"{print $2; exit}' )
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
uri_ip = f"[{server_ip}]" if ":" in server_ip and not server_ip.startswith("[") else server_ip
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
        if not enable or proto == 'socks':
            continue
        s = json.loads(s_str or '{}')
        st = json.loads(st_str or '{}')
        if proto == 'vless':
            clients = [cl for cl in s.get('clients', []) if cl.get('enable', True)]
            if not clients:
                continue
            net = st.get('network', 'tcp')
            sec = st.get('security', 'none')
            for idx_c, cl in enumerate(clients):
                u = cl.get('id', '')
                flow = cl.get('flow', '')
                label = remark if len(clients) == 1 else f"{remark}-{cl.get('email') or idx_c+1}"
                r_enc = urllib.parse.quote(label or f'VLESS-{port}')
                if sec == 'reality':
                    rs = st.get('realitySettings', {})
                    rs_set = rs.get('settings', {})
                    pbk = rs_set.get('publicKey', '')
                    pqv = rs_set.get('mldsa65Verify', '')
                    sni = (rs.get('serverNames') or ['addons.mozilla.org'])[0]
                    sid = (rs.get('shortIds') or [''])[0]
                    pq_str = f"&pqv={urllib.parse.quote(pqv, safe='')}" if pqv else ""
                    if net == 'xhttp':
                        xh = st.get('xhttpSettings', {})
                        path = urllib.parse.quote(xh.get('path', '/vless-xhttp'), safe='')
                        xmode = xh.get('mode', 'auto')
                        link = f"vless://{u}@{uri_ip}:{port}?type=xhttp&path={path}&mode={xmode}&security=reality&pbk={pbk}&fp=chrome&sni={sni}&sid={sid}&spx=%2F{pq_str}#{r_enc}"
                    else:
                        fl = f"&flow={flow}" if flow else ""
                        link = f"vless://{u}@{uri_ip}:{port}?type=tcp&security=reality&pbk={pbk}&fp=chrome&sni={sni}&sid={sid}&spx=%2F{fl}{pq_str}#{r_enc}"
                    print(f"  [{label}] {link}")
                    print_qr(link)
                    found += 1
                elif sec == 'tls':
                    sni = st.get('tlsSettings', {}).get('serverName', server_ip)
                    if net == 'xhttp':
                        xh = st.get('xhttpSettings', {})
                        path = urllib.parse.quote(xh.get('path', '/vless-xhttp'), safe='')
                        xmode = xh.get('mode', 'packet-up')
                        link = f"vless://{u}@{sni}:{port}?type=xhttp&path={path}&mode={xmode}&host={sni}&security=tls&sni={sni}&alpn=h2&fp=chrome#{r_enc}"
                    else:
                        path = urllib.parse.quote(st.get('wsSettings', {}).get('path', '/'), safe='')
                        link = f"vless://{u}@{sni}:{port}?type={net}&path={path}&host={sni}&security=tls&sni={sni}&fp=chrome#{r_enc}"
                    print(f"  [{label}] {link}")
                    print_qr(link)
                    found += 1
        elif proto == 'shadowsocks':
            method = s.get('method', '')
            pwd = s.get('password', '')
            if method and pwd:
                cred = base64.urlsafe_b64encode(f"{method}:{pwd}".encode()).decode().rstrip('=')
                print(f"  [{remark}] ss://{cred}@{uri_ip}:{port}#{urllib.parse.quote(remark or f'SS-{port}')}")
                print(f"    (家宽中转参数: IP={server_ip} | PORT={port} | PASS={pwd})")
                found += 1

    kv = dict(c.execute("SELECT key, value FROM settings WHERE key IN ('webPort','webBasePath','webListen','webCertFile')").fetchall())
    conn.close()
else:
    kv = {}

if os.path.exists('/etc/hysteria/config.yaml'):
    hy_port = '8443'
    hy_pass = ''
    for line in open('/etc/hysteria/config.yaml', encoding='utf-8', errors='ignore'):
        ls = line.strip()
        if ls.startswith('listen:'):
            hy_port = ls.split('#', 1)[0].rsplit(':', 1)[-1].strip().strip('"').strip("'")
        elif ls.startswith('password:'):
            hy_pass = ls.split('#', 1)[0].split(':', 1)[1].strip().strip('"').strip("'")
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
        hy_url = f"hysteria2://{urllib.parse.quote(hy_pass, safe='')}@{uri_ip}:{hy_port}?insecure=1&sni=www.bing.com&pinSHA256={pin}&mport=20000-50000#Hysteria2-PortHopping"
        print(f"  [Hysteria2] {hy_url}")
        print_qr(hy_url)
        found += 1

if not found:
    print("  (当前未检测到已启用的节点)")

if kv:
    wport = kv.get('webPort', '54321').strip()
    wbase = kv.get('webBasePath', '/').strip()
    if not wbase.startswith('/'):
        wbase = '/' + wbase
    scheme = 'https' if kv.get('webCertFile', '').strip() else 'http'
    p_flag = f"-p {ssh_port} " if ssh_port != '22' else ""
    Y, G, C, O, W, D, N = "\033[1;33m", "\033[1;32m", "\033[1;36m", "\033[38;5;208m", "\033[1;97m", "\033[38;5;245m", "\033[0m"
    print("")
    print(f"{Y}=================================================================={N}")
    print(f"  {Y}【3x-ui 面板安全访问指南】{N} {O}(已锁死 127.0.0.1:{wport}，公网直连会拒绝访问属正常！){N}")
    print(f"{Y}=================================================================={N}")
    print(f"  {W}第 1 步：{N}在{O}【自己电脑】{N}按 Win+R 输 cmd 回车（Mac 开终端，{O}千万别在 VPS 里敲！{N}），复制运行：")
    print("")
    print(f"  {G}ssh {p_flag}-L {wport}:127.0.0.1:{wport} root@{server_ip}{N}")
    print("")
    print(f"  {D}（提示：输入 VPS root 密码时屏幕不显示字符属正常，输完回车；登录成功后黑框窗口【不要关闭】！）{N}")
    print(f"  {W}第 2 步：{N}用自己电脑浏览器打开下方本地地址：")
    print(f"  {C}{scheme}://127.0.0.1:{wport}{wbase}{N}")
    print(f"  {W}第 3 步：{N}浏览器若提示“不是私密连接”，点{G}「高级」->「继续前往」{N}（本地自签证书正常现象）。")
    print(f"  {D}（忘记面板账密时，可在 VPS 终端里直接输入 x-ui 查看或重置）{N}")
print("\033[1;33m==================================================================\033[0m")
EXPPY
        exit 0
        ;;
    7)
        echo ""
        command -v python3 >/dev/null 2>&1 || { echo "  [提示] 当前系统缺少 python3，请先执行 apt-get update && apt-get install -y python3"; exit 1; }
        echo "=================================================================="
        echo "  本机家宽 / 商宽 / 机房 IP 与环境快检（纯只读，不碰流媒体）"
        echo "=================================================================="
        SERVER_IP="$SERVER_IP" python3 - << 'ISPPY'
import os, re, json, socket, subprocess, urllib.request

ip = os.environ.get("SERVER_IP", "").strip()
if not ip or ip in ("未知", "YOUR_SERVER_IP"):
    for u in ("https://api.ipify.org", "https://ifconfig.me/ip"):
        try:
            ip = urllib.request.urlopen(u, timeout=4).read().decode().strip()
            if ip:
                break
        except Exception:
            pass

print(f"  公网 IPv4:   {ip or '获取失败'}")

ptr = "NONE"
if ip:
    try:
        ptr = socket.gethostbyaddr(ip)[0]
    except Exception:
        ptr = "NONE"

ptr_low = ptr.lower()
ptr_is_biz = any(k in ptr_low for k in (".biz.", "business", ".corp.", "-static-", "static."))
ptr_is_res = any(k in ptr_low for k in (".res.", "home", "dyn", "dhcp", "pool", "lightspeed", "fios", "cpe.", "cpe-", "hsd1", "cable"))
if ptr == "NONE":
    ptr_tag = "无反解（需结合下方双类型判断）"
elif ptr_is_biz:
    ptr_tag = "预警：疑似商宽前缀（含 .biz / business / static）"
elif ptr_is_res:
    ptr_tag = "住宅宽带特征"
else:
    ptr_tag = "常规反解"
print(f"  rDNS / PTR:  {ptr}  [{ptr_tag}]")

asn_str = org_str = isp_str = loc = ""
is_dc = is_proxy = is_mobile = None
try:
    req = urllib.request.Request(
        f"http://ip-api.com/json/{ip}?fields=status,countryCode,regionName,city,isp,org,as,hosting,proxy,mobile",
        headers={"User-Agent": "CatEacc-ISP-Check/1.0"},
    )
    d = json.loads(urllib.request.urlopen(req, timeout=6).read().decode())
    if d.get("status") == "success":
        asn_str = d.get("as") or ""
        isp_str = d.get("isp") or ""
        org_str = d.get("org") or ""
        loc = f"{d.get('countryCode', '')} / {d.get('regionName', '')} / {d.get('city', '')}".strip(" /")
        is_dc = bool(d.get("hosting"))
        is_proxy = bool(d.get("proxy"))
        is_mobile = bool(d.get("mobile"))
except Exception:
    pass
if not asn_str and ip:
    try:
        d = json.loads(urllib.request.urlopen(f"https://ipinfo.io/{ip}/json", timeout=5).read().decode())
        asn_str = d.get("org", "")
        loc = loc or f"{d.get('country', '')} / {d.get('region', '')} / {d.get('city', '')}".strip(" /")
    except Exception:
        pass

print(f"  归属地区:    {loc or '未知'}")
print(f"  ASN / 组织:  {asn_str or org_str or '未知'}")
if isp_str or org_str:
    print(f"  ISP / Org:   ISP={isp_str or '-'} | Org={org_str or '-'}")
if is_dc is not None:
    print(f"  属性标记:    hosting(机房)={is_dc} | proxy(代理)={is_proxy} | mobile(蜂窝)={is_mobile}")

rdap_net = rdap_range = rdap_org = ""
if ip:
    try:
        req = urllib.request.Request(f"https://rdap.org/ip/{ip}", headers={"User-Agent": "CatEacc-ISP-Check/1.0", "Accept": "application/rdap+json"})
        rd = json.loads(urllib.request.urlopen(req, timeout=6).read().decode())
        rdap_net = rd.get("name") or ""
        s_ip, e_ip = rd.get("startAddress") or "", rd.get("endAddress") or ""
        if s_ip and e_ip:
            rdap_range = f"{s_ip} - {e_ip}"
        for ent in (rd.get("entities") or []):
            vcard = ent.get("vcardArray")
            if isinstance(vcard, list) and len(vcard) > 1:
                for item in vcard[1]:
                    if isinstance(item, list) and len(item) >= 4 and item[0] == "fn":
                        rdap_org = str(item[3])
                        break
            if rdap_org:
                break
    except Exception:
        pass
print(f"  RDAP 归属:   NetName={rdap_net or '查询超时'} | 组织={rdap_org or '-'} | 段={rdap_range or '-'}")

virt = "unknown"
try:
    virt = subprocess.check_output(["systemd-detect-virt"], text=True, stderr=subprocess.DEVNULL).strip() or "none"
except Exception:
    pass
hv_balloon = False
try:
    hv_balloon = "hv_balloon" in open("/proc/modules", encoding="utf-8", errors="ignore").read()
except Exception:
    pass
virt_note = f"{virt}"
if virt == "microsoft":
    virt_note += " (Hyper-V 母鸡，hv_balloon=" + ("已加载/建议屏蔽" if hv_balloon else "未加载") + ")"
print(f"  虚拟化环境:  {virt_note}")

smtp_stat = "已封禁/不可达（安全）"
try:
    with socket.create_connection(("gmail-smtp-in.l.google.com", 25), timeout=2.5):
        smtp_stat = "可连出（未封禁，建议跑本脚本封禁出站 TCP 25）"
except Exception:
    pass
print(f"  出站 TCP 25: {smtp_stat}")

print("------------------------------------------------------------------")
comb_org = f"{asn_str} {isp_str} {org_str} {rdap_net} {rdap_org}".lower()
is_gfiber = "google fiber" in comb_org or "as16591" in comb_org
dc_sub_kw = ("cogent", "psinet", "hosting", "datacenter", "data center", "digitalocean", "amazon", "google cloud", "google llc", "oracle", "hetzner", "vultr", "linode", "akamai", "choopa", "colocrossing", "multacom", "zenlayer", "dmit")
dc_word_kw = {"cloud", "server", "vps", "aws", "ovh", "gcp"}
org_words = set(re.findall(r"[a-z0-9]+", comb_org))
looks_dc_org = (not is_gfiber) and (any(k in comb_org for k in dc_sub_kw) or bool(org_words & dc_word_kw))
asn_tokens = {w for w in re.findall(r"[a-z0-9]+", asn_str.lower()) if len(w) >= 4 and not re.match(r"^as\d+$", w)}
rdap_low = f"{rdap_net} {rdap_org}".lower()
is_broadcast_mismatch = bool(asn_tokens and rdap_org and not any(t in rdap_low for t in asn_tokens))

if is_dc is True or looks_dc_org:
    verdict = "[机房商业 VPS / 骨干网段] 建议作为前置迎宾/中转机（443 REALITY / CF CDN / Hy2 端口跳跃）"
elif is_dc is False and ptr_is_biz:
    verdict = "[运营商商宽段] 注意：非机房段但 PTR 含商宽特征（.biz / business / static），买住宅家宽建议换段"
elif is_dc is False and not is_proxy and ptr_is_res and not is_broadcast_mismatch:
    verdict = "[原生住宅家宽] 建议作为后端纯净落地机（选方案 1 -> 子模式 3 高位 SS-2022 + 白名单）"
elif is_broadcast_mismatch:
    verdict = "[疑似广播 IP / 非原生池] 注意：广播 ASN 与 RDAP 原始注册商不一致且无住宅 PTR，请复核 IPinfo 双字段"
elif is_dc is False and not is_proxy:
    verdict = "[疑似住宅/ISP 段] 无明显机房标记，建议再用 IPinfo 复核 asn.type 与 company.type 是否同为 isp"
else:
    verdict = "[混合/未知类型] 请结合上方 PTR 与 RDAP 归属综合判断"
print(f"  综合建议:    {verdict}")
print("==================================================================")
ISPPY
        exit 0
        ;;
    8|sni)
        readonly_sni_menu "$SNI_QUERY_ARG"
        ;;
    *)
        echo "[错误] 无效的方案编号: ${MODE}，仅支持 1 / 2 / 3 / 4 / 5 / 6 / 7 / 8"
        exit 1
        ;;
esac

# ------------------------------------------------------------------------------
# 阶段一：改前自动原厂快照 + 系统底层优化、Swap 兜底、日志收敛、TCP 25 封禁与 Fail2ban
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
apt-get -o DPkg::Lock::Timeout=60 update -y && apt-get -o DPkg::Lock::Timeout=60 -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" upgrade -y
apt-get -o DPkg::Lock::Timeout=60 install -y curl wget unzip chrony cron iptables nftables iptables-persistent sqlite3 fail2ban python3 python3-systemd openssl qrencode || \
  apt-get -o DPkg::Lock::Timeout=60 install -y curl wget unzip chrony cron iptables nftables iptables-persistent sqlite3 fail2ban python3 openssl

echo "[2/5] 配置原子钟对时、1GB Swap 兜底、默认封禁出站 TCP 25、日志限额与 SSH/Fail2ban 加固..."
systemctl enable --now chrony 2>/dev/null || true
chronyc makestep 2>/dev/null || true
timedatectl set-timezone Asia/Shanghai 2>/dev/null || true
systemctl restart cron 2>/dev/null || true

if [ ! -f /swapfile ]; then
    if fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none; then
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null 2>&1 || true
        if swapon /swapfile 2>/dev/null; then
            touch "${BACKUP_DIR}/swap_created_by_script"
        else
            rm -f /swapfile
            dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none 2>/dev/null || true
            chmod 600 /swapfile
            mkswap /swapfile >/dev/null 2>&1 || true
            if swapon /swapfile 2>/dev/null; then
                touch "${BACKUP_DIR}/swap_created_by_script"
            else
                rm -f /swapfile
                echo "  [提示] 当前虚拟化/文件系统不支持挂载 Swap，已自动跳过。"
            fi
        fi
    fi
fi
if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "/swapfile"; then
    grep -q "/swapfile" /etc/fstab || echo "/swapfile none swap sw,nofail 0 0" >> /etc/fstab
    if [ -f /swap.img ] && [ "$(stat -c%s /swap.img 2>/dev/null || echo 1073741824)" -lt 943718400 ]; then
        swapoff /swap.img 2>/dev/null || true
        sed -i '\|/swap\.img|d' /etc/fstab
        rm -f /swap.img
    fi
fi

if command -v nft >/dev/null 2>&1; then
    mkdir -p /etc/nftables.d
    cat << 'EOF' > /etc/nftables.d/smtp-guard.nft
table inet smtp_guard
delete table inet smtp_guard
table inet smtp_guard {
    chain output {
        type filter hook output priority filter; policy accept;
        tcp dport 25 reject with tcp reset
    }
}
EOF
    nft -f /etc/nftables.d/smtp-guard.nft 2>/dev/null || true
    cat << 'EOF' > /etc/systemd/system/smtp-guard.service
[Unit]
Description=Block Outbound TCP 25 (SMTP Anti-Spam)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/nftables.d/smtp-guard.nft
ExecStop=/usr/sbin/nft delete table inet smtp_guard

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload && systemctl enable --now smtp-guard.service >/dev/null 2>&1 || true
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

# 开启 SSH 公钥登录；注意不盲目静默关闭密码登录（防止 AWS/Oracle cloud-init 占位符公钥把密码用户锁在门外）
mkdir -p /run/sshd
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config.d/*.conf 2>/dev/null || true
grep -q "^PubkeyAuthentication yes" /etc/ssh/sshd_config || echo "PubkeyAuthentication yes" >> /etc/ssh/sshd_config
if sshd -t 2>/dev/null; then
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
fi

SSH_PORTS=$( (sshd -T 2>/dev/null || true) | awk '$1=="port"{print $2}' | paste -sd, - )
SSH_PORTS="${SSH_PORTS:-22}"
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
systemctl enable --now fail2ban 2>/dev/null || true
systemctl restart fail2ban 2>/dev/null || true

echo "[3/5] 注入按内存分档的高并发内核栈 (BBR + MPTCP 防护)..."
mkdir -p /etc/modules-load.d
printf "tcp_bbr\nnf_conntrack\n" > /etc/modules-load.d/99-proxy.conf
modprobe tcp_bbr 2>/dev/null || true
modprobe nf_conntrack 2>/dev/null || true

MEM_MB=$(LC_ALL=C free -m 2>/dev/null | awk '/^Mem:/ {print $2}')
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
    echo "  拥塞控制   : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo N/A)"
    echo "  MPTCP      : $(sysctl -n net.mptcp.enabled 2>/dev/null || echo 0)"
    echo "  出站 TCP 25: 已通过 smtp-guard.service 默认封禁"
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

ARCH=$(uname -m)
case "$ARCH" in
    x86_64|amd64)   XRAY_ARCH="64"; XRAY_BIN="/usr/local/x-ui/bin/xray-linux-amd64" ;;
    aarch64|arm64)  XRAY_ARCH="arm64-v8a"; XRAY_BIN="/usr/local/x-ui/bin/xray-linux-arm64" ;;
    *) echo "[错误] 暂不支持的 CPU 架构: ${ARCH}"; exit 1 ;;
esac

if [ ! -x /usr/local/x-ui/x-ui ]; then
    printf "n\n" | bash <(curl -fsSL https://raw.githubusercontent.com/MHSanaei/3x-ui/master/install.sh) "$XUI_VERSION" || true
fi
if [ ! -x /usr/local/x-ui/x-ui ]; then
    echo "[错误] 3x-ui 安装失败，未检测到 /usr/local/x-ui/x-ui！"
    exit 1
fi

# 拔除 3x-ui 安装脚本可能生成的 6 天期裸 IP ACME 证书（防止公网 CT 日志暴露 IP）
rm -rf /root/cert/ip /root/.acme.sh/[0-9]*.[0-9]*.[0-9]*.[0-9]* /var/log/x-ui/access.log 2>/dev/null || true
if command -v crontab >/dev/null 2>&1; then
    (crontab -l 2>/dev/null | grep -v "/root/cert/ip" || true) | crontab - 2>/dev/null || true
fi

# 确保 x-ui.db 已完成首次建表迁移后立即停止服务，保证后续 SQLite 离线安全写入
if ! python3 -c "import sqlite3; c=sqlite3.connect('/etc/x-ui/x-ui.db'); assert c.execute(\"SELECT 1 FROM sqlite_master WHERE type='table' AND name='inbounds'\").fetchone()" 2>/dev/null; then
    systemctl start x-ui 2>/dev/null || true
    for _ in $(seq 1 20); do
        if python3 -c "import sqlite3; c=sqlite3.connect('/etc/x-ui/x-ui.db'); assert c.execute(\"SELECT 1 FROM sqlite_master WHERE type='table' AND name='inbounds'\").fetchone()" 2>/dev/null; then
            break
        fi
        sleep 0.5
    done
fi
systemctl stop x-ui 2>/dev/null || true

rm -f /usr/local/x-ui/bin/*.bak
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

mkdir -p /etc/x-ui
if [ ! -f /etc/x-ui/panel_local.key ] || [ ! -f /etc/x-ui/panel_local.crt ]; then
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 -nodes \
      -keyout /etc/x-ui/panel_local.key -out /etc/x-ui/panel_local.crt \
      -subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1" 2>/dev/null
fi
chmod 700 /etc/x-ui && chmod 600 /etc/x-ui/panel_local.key && chmod 644 /etc/x-ui/panel_local.crt

# ------------------------------------------------------------------------------
# 阶段三：按用户所选方案离线写入入站、中转出站与安全路由（x-ui 已停止，零锁竞争）
# ------------------------------------------------------------------------------
echo "[5/5] 写入 Xray 安全路由并按所选方案创建节点..."

if [ "$MODE" = "2" ]; then
    NEED_CF_CERT="0"
    if [ ! -f /etc/x-ui/cf.crt ] || [ ! -f /etc/x-ui/cf.key ]; then
        NEED_CF_CERT="1"
    elif ! openssl x509 -in /etc/x-ui/cf.crt -noout -subject 2>/dev/null | grep -Fq "CN = ${CF_DOMAIN}" && \
         ! openssl x509 -in /etc/x-ui/cf.crt -noout -subject 2>/dev/null | grep -Fq "CN=${CF_DOMAIN}"; then
        NEED_CF_CERT="1"
    fi
    if [ "$NEED_CF_CERT" = "1" ]; then
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 -nodes \
          -keyout /etc/x-ui/cf.key -out /etc/x-ui/cf.crt \
          -subj "/CN=${CF_DOMAIN}" -addext "subjectAltName=DNS:${CF_DOMAIN}" 2>/dev/null
    fi
    chmod 644 /etc/x-ui/cf.crt && chmod 600 /etc/x-ui/cf.key
fi

if [ "$MODE" = "3" ]; then
    mkdir -p /etc/hysteria
    if [ ! -f /etc/hysteria/server.crt ] || [ ! -f /etc/hysteria/server.key ]; then
        openssl ecparam -genkey -name prime256v1 -out /etc/hysteria/server.key
        openssl req -new -x509 -days 3650 -key /etc/hysteria/server.key -out /etc/hysteria/server.crt \
          -subj "/CN=www.bing.com" -addext "subjectAltName=DNS:www.bing.com" 2>/dev/null
    fi
    chmod 644 /etc/hysteria/server.crt
    chmod 640 /etc/hysteria/server.key
fi

[ -s /etc/x-ui/x-ui.db ] && cp -a /etc/x-ui/x-ui.db /etc/x-ui/x-ui.db.bak
install -m 600 /dev/null /tmp/setup_result.txt
XRAY_BUF=$([ "${MEM_MB:-1000}" -le 700 ] && echo 32 || echo 64) \
MODE="$MODE" REALITY_SUBMODE="$REALITY_SUBMODE" LISTEN_PORT="$LISTEN_PORT" \
REALITY_SNI="$REALITY_SNI" CF_DOMAIN="$CF_DOMAIN" SERVER_IP="$SERVER_IP" \
ENABLE_RELAY="$ENABLE_RELAY" RES_IP="$RES_IP" RES_PORT="$RES_PORT" RES_SS_PASS="$RES_SS_PASS" \
XRAY_BIN="$XRAY_BIN" \
python3 - << 'PYEOF' > /tmp/setup_result.txt
import sqlite3, json, os, uuid, secrets, subprocess, base64, time, urllib.parse
os.umask(0o077)

mode = os.environ['MODE']
submode = os.environ['REALITY_SUBMODE']
port = int(os.environ['LISTEN_PORT'] or '443')
sni = os.environ['REALITY_SNI']
cf_domain = os.environ['CF_DOMAIN']
server_ip = os.environ['SERVER_IP']
enable_relay = os.environ['ENABLE_RELAY'].lower() == 'y'
res_ip = os.environ['RES_IP'].strip()
res_port = os.environ['RES_PORT'].strip()
res_ss_pass = os.environ['RES_SS_PASS'].strip()
xray_bin = os.environ['XRAY_BIN']

if port == 62789:
    raise SystemExit("端口 62789 为 Xray 内部 API 端口，请更换业务监听端口！")

conn = sqlite3.connect('/etc/x-ui/x-ui.db')
c = conn.cursor()

# 若业务 TCP 入站端口与面板 webPort 撞车，自动将面板迁至 54321 防止 bind 冲突
if mode in ('1', '2'):
    wp_row = c.execute("SELECT value FROM settings WHERE key='webPort'").fetchone()
    if wp_row and wp_row[0] and wp_row[0].strip() == str(port):
        new_wp = '54321' if port != 54321 else '54322'
        c.execute("UPDATE settings SET value=? WHERE key='webPort'", (new_wp,))

# 1. 基础模板与安全路由
row = c.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'").fetchone()
cfg = json.loads(row[0]) if (row and row[0]) else {}
cfg['api'] = {"tag": "api", "services": ["HandlerService", "LoggerService", "StatsService"]}
cfg['stats'] = {}
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

tables = [r[0] for r in c.execute("SELECT name FROM sqlite_master WHERE type='table'").fetchall()]
has_clients_tbl = 'clients' in tables and 'client_inbounds' in tables

def sync_v3_client(inb_id, email, client_uuid, client_flow, sub_id):
    if not (has_clients_tbl and email and client_uuid):
        return
    now_ms = int(time.time() * 1000)
    col_info = c.execute("PRAGMA table_info(clients)").fetchall()
    col_names = [r[1] for r in col_info]
    if 'uuid' not in col_names:
        return
    defaults = {
        'email': email, 'uuid': client_uuid, 'password': '', 'flow': client_flow or '',
        'method': '', 'comment': '', 'sub_id': sub_id, 'tg_id': 0, 'total_gb': 0,
        'limit_ip': 0, 'expiry_time': 0, 'enable': 1, 'reset': 0, 'security': 'auto',
        'created_at': now_ms, 'updated_at': now_ms
    }
    ins_cols, ins_vals = [], []
    for _, name, ctype, notnull, dflt, pk in col_info:
        if pk:
            continue
        if name in defaults:
            val = defaults[name]
            if name == 'tg_id' and 'TEXT' in (ctype or '').upper():
                val = ''
            ins_cols.append(name)
            ins_vals.append(val)
        elif notnull and dflt is None:
            ins_cols.append(name)
            ins_vals.append(0 if 'INT' in (ctype or '').upper() else '')
    q = f"INSERT OR IGNORE INTO clients ({','.join(ins_cols)}) VALUES ({','.join(['?']*len(ins_cols))})"
    c.execute(q, ins_vals)
    row_cid = c.execute("SELECT id FROM clients WHERE email=?", (email,)).fetchone()
    if row_cid:
        cid = row_cid[0]
        ci_cols = [r[1] for r in c.execute("PRAGMA table_info(client_inbounds)").fetchall()]
        if 'flow_override' in ci_cols:
            c.execute("INSERT OR IGNORE INTO client_inbounds (client_id, inbound_id, flow_override) VALUES (?, ?, ?)", (cid, inb_id, client_flow or ''))
        else:
            c.execute("INSERT OR IGNORE INTO client_inbounds (client_id, inbound_id) VALUES (?, ?)", (cid, inb_id))

def unique_email(base_email):
    cand = base_email
    while True:
        hit = c.execute("SELECT 1 FROM client_traffics WHERE email=? LIMIT 1", (cand,)).fetchone()
        if not hit and has_clients_tbl:
            hit = c.execute("SELECT 1 FROM clients WHERE email=? LIMIT 1", (cand,)).fetchone()
        if not hit:
            return cand
        cand = f"{base_email}-{secrets.token_hex(2)}"

def upsert_or_reuse_inbound(remark, listen, in_port, proto, settings_obj, stream_obj, tag, client_email=None, client_uuid=None, client_flow="", sub_id=""):
    ex = c.execute("SELECT id, remark, protocol, settings, stream_settings, tag FROM inbounds WHERE port=?", (in_port,)).fetchone()
    if ex:
        if ex[2] != proto:
            raise SystemExit(f"端口 {in_port} 已被 {ex[2]} 协议占用，请更换监听端口或在面板删除旧入站！")
        ex_st = json.loads(ex[4] or '{}')
        want_st = stream_obj or {}
        ex_net = 'tcp' if ex_st.get('network', 'tcp') in ('tcp', 'raw') else ex_st.get('network')
        want_net = 'tcp' if want_st.get('network', 'tcp') in ('tcp', 'raw') else want_st.get('network')
        if (ex_net, ex_st.get('security', 'none')) != (want_net, want_st.get('security', 'none')):
            raise SystemExit(f"端口 {in_port} 已存在不同传输/安全模式的节点 ({ex_net}+{ex_st.get('security', 'none')})，请更换监听端口或在 3x-ui 面板删除旧入站后重跑！")
        actual_tag = ex[5] or tag
        c.execute("UPDATE inbounds SET enable=1, tag=? WHERE id=?", (actual_tag, ex[0]))
        return (ex[0], ex[1], ex[2], ex[3], ex[4], actual_tag), True
    if client_email:
        client_email = unique_email(client_email)
        if isinstance(settings_obj, dict) and settings_obj.get("clients"):
            settings_obj["clients"][0]["email"] = client_email
    sniff = {"enabled": True, "destOverride": ["http", "tls", "quic", "fakedns"], "metadataOnly": False, "routeOnly": True}
    c.execute("""
        INSERT INTO inbounds (user_id, up, down, total, remark, enable, expiry_time, listen, port, protocol, settings, stream_settings, tag, sniffing)
        VALUES (1, 0, 0, 0, ?, 1, 0, ?, ?, ?, ?, ?, ?, ?)
    """, (remark, listen, in_port, proto, json.dumps(settings_obj, indent=2), json.dumps(stream_obj, indent=2), tag, json.dumps(sniff)))
    inb_id = c.lastrowid
    if client_email:
        c.execute("INSERT INTO client_traffics (inbound_id, enable, email, up, down, expiry_time, total, reset) VALUES (?, 1, ?, 0, 0, 0, 0, 0)", (inb_id, client_email))
        sync_v3_client(inb_id, client_email, client_uuid, client_flow, sub_id or secrets.token_hex(8))
    return (inb_id, remark, proto, json.dumps(settings_obj), json.dumps(stream_obj), tag), False

def build_link_from_row(rem, in_port, proto, s_str, st_str):
    s = json.loads(s_str or '{}')
    st = json.loads(st_str or '{}')
    if proto == 'shadowsocks':
        return 'RESIDENTIAL_SS', s.get('password', '')
    if proto == 'vless':
        cl = (s.get('clients') or [{}])[0]
        u = cl.get('id', '')
        fl = cl.get('flow', '')
        net = st.get('network', 'tcp')
        sec = st.get('security', 'none')
        r_enc = urllib.parse.quote(rem or f'VLESS-{in_port}')
        uri_ip = f"[{server_ip}]" if ":" in server_ip and not server_ip.startswith("[") else server_ip
        if sec == 'reality':
            rs = st.get('realitySettings', {})
            rs_set = rs.get('settings', {})
            pbk = rs_set.get('publicKey', '')
            pqv = rs_set.get('mldsa65Verify', '')
            pq_q = f"&pqv={urllib.parse.quote(pqv, safe='')}" if pqv else ""
            sni_v = (rs.get('serverNames') or ['addons.mozilla.org'])[0]
            sid_v = (rs.get('shortIds') or [''])[0]
            if net == 'xhttp':
                xh = st.get('xhttpSettings', {})
                p_enc = urllib.parse.quote(xh.get('path', '/vless-xhttp'), safe='')
                xm = xh.get('mode', 'auto')
                return 'LINK', f"vless://{u}@{uri_ip}:{in_port}?type=xhttp&path={p_enc}&mode={xm}&security=reality&pbk={pbk}&fp=chrome&sni={sni_v}&sid={sid_v}&spx=%2F{pq_q}#{r_enc}"
            fl_q = f"&flow={fl}" if fl else ""
            return 'LINK', f"vless://{u}@{uri_ip}:{in_port}?type=tcp&security=reality&pbk={pbk}&fp=chrome&sni={sni_v}&sid={sid_v}&spx=%2F{fl_q}{pq_q}#{r_enc}"
        if sec == 'tls':
            host_v = st.get('tlsSettings', {}).get('serverName', cf_domain)
            if net == 'xhttp':
                xh = st.get('xhttpSettings', {})
                p_enc = urllib.parse.quote(xh.get('path', '/vless-xhttp'), safe='')
                xm = xh.get('mode', 'packet-up')
                return 'LINK', f"vless://{u}@{host_v}:{in_port}?type=xhttp&path={p_enc}&mode={xm}&host={host_v}&security=tls&sni={host_v}&alpn=h2&fp=chrome#{r_enc}"
            p_enc = urllib.parse.quote(st.get('wsSettings', {}).get('path', '/'), safe='')
            return 'LINK', f"vless://{u}@{host_v}:{in_port}?type={net}&path={p_enc}&host={host_v}&security=tls&sni={host_v}&fp=chrome#{r_enc}"
    return '', ''

inbound_tag_for_relay = None

if mode == '1' and submode == '3':
    ss_pass = base64.b64encode(os.urandom(32)).decode()
    tag = f"in-ss-{port}"
    settings_obj = {"method": "2022-blake3-aes-256-gcm", "password": ss_pass, "network": "tcp,udp", "clients": []}
    stream_obj = {"network": "tcp", "security": "none", "sockopt": {"tcpKeepAliveIdle": 120, "tcpKeepAliveInterval": 20}}
    row_inb, reused = upsert_or_reuse_inbound("Residential-SS2022", "", port, "shadowsocks", settings_obj, stream_obj, tag)
    _, _, _, s_raw, _, _ = row_inb
    real_pass = json.loads(s_raw or '{}').get('password', ss_pass)
    if reused:
        print("REUSED_EXISTING=1")
    print("RESULT_TYPE=RESIDENTIAL_SS")
    print(f"SS_IP={server_ip}")
    print(f"SS_PORT={port}")
    print(f"SS_PASS={real_pass}")

elif mode == '1':
    out = subprocess.check_output([xray_bin, 'x25519'], text=True)
    priv = pub = ''
    for line in out.splitlines():
        if 'Private' in line: priv = line.split(':', 1)[1].strip()
        elif 'Public' in line or 'Password' in line: pub = line.split(':', 1)[1].strip()
    sid = secrets.token_hex(4)
    u = str(uuid.uuid4())
    sub_id = secrets.token_hex(8)
    email = f"reality-{port}"
    tag = f"inbound-{port}"
    flow = "" if submode == '1' else "xtls-rprx-vision"
    net = "xhttp" if submode == '1' else "tcp"
    settings_obj = {
        "clients": [{"id": u, "flow": flow, "email": email, "limitIp": 0, "totalGB": 0, "expiryTime": 0, "enable": True, "subId": sub_id, "reset": 0}],
        "decryption": "none", "fallbacks": []
    }
    # 显式指定 minClientVer: "1.0.0"，防止 Xray v26.7.11+ 空值默认 >=26.3.27 拒连 Clash/sing-box/旧版小火箭
    stream_obj = {
        "network": net, "security": "reality", "externalProxy": [],
        "realitySettings": {
            "show": False, "xver": 0, "target": f"{sni}:443", "serverNames": [sni],
            "privateKey": priv, "minClientVer": "1.0.0", "maxClientVer": "", "maxTimeDiff": 0,
            "shortIds": [sid],
            "settings": {"publicKey": pub, "fingerprint": "chrome", "serverName": "", "spiderX": "/"}
        },
        "sockopt": {"tcpKeepAliveIdle": 120, "tcpKeepAliveInterval": 20}
    }
    if submode == '1':
        stream_obj["xhttpSettings"] = {"path": "/vless-xhttp", "host": "", "mode": "auto"}
        remark = "VLESS-XHTTP-REALITY"
    else:
        remark = "VLESS-Vision-REALITY"
    row_inb, reused = upsert_or_reuse_inbound(remark, "", port, "vless", settings_obj, stream_obj, tag, email, u, flow, sub_id)
    _, rem_actual, proto_actual, s_raw, st_raw, tag_actual = row_inb
    inbound_tag_for_relay = tag_actual or tag
    _, real_link = build_link_from_row(rem_actual, port, proto_actual, s_raw, st_raw)
    if reused:
        print("REUSED_EXISTING=1")
    print("RESULT_TYPE=LINK")
    print(f"SHARE_LINK={real_link}")

elif mode == '2':
    u = str(uuid.uuid4())
    sub_id = secrets.token_hex(8)
    email = f"cf-xhttp-{port}"
    tag = f"inbound-{port}"
    settings_obj = {
        "clients": [{"id": u, "flow": "", "email": email, "limitIp": 0, "totalGB": 0, "expiryTime": 0, "enable": True, "subId": sub_id, "reset": 0}],
        "decryption": "none", "fallbacks": []
    }
    stream_obj = {
        "network": "xhttp", "security": "tls", "externalProxy": [],
        "tlsSettings": {
            "serverName": cf_domain, "minVersion": "1.2", "maxVersion": "1.3",
            "certificates": [{"certificateFile": "/etc/x-ui/cf.crt", "keyFile": "/etc/x-ui/cf.key", "ocspStapling": 0}],
            "alpn": ["h2", "http/1.1"]
        },
        "xhttpSettings": {"path": "/vless-xhttp", "mode": "packet-up"},
        "sockopt": {"tcpKeepAliveIdle": 120, "tcpKeepAliveInterval": 20, "trustedXForwardedFor": ["CF-Connecting-IP", "X-Forwarded-For"]}
    }
    row_inb, reused = upsert_or_reuse_inbound("CF-VLESS-XHTTP-TLS", "", port, "vless", settings_obj, stream_obj, tag, email, u, "", sub_id)
    _, rem_actual, proto_actual, s_raw, st_raw, tag_actual = row_inb
    inbound_tag_for_relay = tag_actual or tag
    _, real_link = build_link_from_row(rem_actual, port, proto_actual, s_raw, st_raw)
    if reused:
        print("REUSED_EXISTING=1")
    print("RESULT_TYPE=LINK")
    print(f"SHARE_LINK={real_link}")

elif mode == '3':
    inbound_tag_for_relay = "socks-in-10855"
    if enable_relay and res_ip and res_port and res_ss_pass:
        settings_obj = {"auth": "noauth", "udp": True, "ip": "127.0.0.1"}
        stream_obj = {"network": "tcp", "security": "none"}
        upsert_or_reuse_inbound("Hy2-SOCKS5-Bridge", "127.0.0.1", 10855, "socks", settings_obj, stream_obj, inbound_tag_for_relay)
    else:
        c.execute("DELETE FROM inbounds WHERE tag='socks-in-10855'")

# 为存量 REALITY 节点自动补齐 minClientVer="1.0.0" 与 sniffing/keepalive
for inb_id, sniff_raw, stream_raw in c.execute("SELECT id, sniffing, stream_settings FROM inbounds").fetchall():
    sn = json.loads(sniff_raw or '{}')
    sn.update({'enabled': True, 'destOverride': ['http', 'tls', 'quic', 'fakedns'], 'metadataOnly': False, 'routeOnly': True})
    st = json.loads(stream_raw or '{}')
    so = st.setdefault('sockopt', {})
    so.setdefault('tcpKeepAliveIdle', 120)
    so.setdefault('tcpKeepAliveInterval', 20)
    if st.get('security') == 'reality':
        rs = st.setdefault('realitySettings', {})
        if not rs.get('minClientVer'):
            rs['minClientVer'] = '1.0.0'
    c.execute("UPDATE inbounds SET sniffing=?, stream_settings=? WHERE id=?", (json.dumps(sn), json.dumps(st, indent=2), inb_id))

# 处理按入站隔离的专属家宽中转出站 (out-res-<tag>)，并清理已关闭中转的孤儿出站/规则
relay_tag = None
if inbound_tag_for_relay:
    cand_relay_tag = f"out-res-{inbound_tag_for_relay}"
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
valid_out_tags = {ob.get('tag') for ob in outbounds if ob.get('tag')}

old_rules = cfg.setdefault('routing', {}).setdefault('rules', [])
custom_rules = [
    r for r in old_rules
    if not (r.get('outboundTag') == 'api' and r.get('inboundTag') == ['api'])
    and not (r.get('outboundTag') == 'blocked' and bool(r.get('ip')) and set(r['ip']) <= {'geoip:private', 'geoip:cn'} and not r.get('domain') and not r.get('port') and not r.get('network') and not r.get('protocol') and not r.get('inboundTag') and not r.get('user'))
    and not (r.get('outboundTag') == 'blocked' and r.get('protocol') == ['bittorrent'] and not r.get('ip') and not r.get('domain') and not r.get('port'))
    and not (r.get('outboundTag') == 'blocked' and str(r.get('port', '')) == '25' and not r.get('ip') and not r.get('domain') and not r.get('protocol'))
    and not (r.get('outboundTag') == 'direct' and r.get('domain') == ['geosite:google'] and not r.get('ip') and not r.get('inboundTag') and not r.get('user'))
    and not (inbound_tag_for_relay and r.get('inboundTag') == [inbound_tag_for_relay] and str(r.get('outboundTag', '')).startswith('out-res'))
    and not (str(r.get('outboundTag', '')).startswith('out-res') and r.get('outboundTag') not in valid_out_tags)
]
if relay_tag and inbound_tag_for_relay:
    custom_rules.append({'type': 'field', 'inboundTag': [inbound_tag_for_relay], 'outboundTag': relay_tag})

has_relay_rule = any(str(r.get('outboundTag', '')).startswith('out-res') for r in custom_rules)
base_rules = [
    {'type': 'field', 'inboundTag': ['api'], 'outboundTag': 'api'},
    {'type': 'field', 'outboundTag': 'blocked', 'ip': ['geoip:private']},
    {'type': 'field', 'outboundTag': 'blocked', 'protocol': ['bittorrent']},
    {'type': 'field', 'outboundTag': 'blocked', 'port': '25'},
]
if not has_relay_rule:
    base_rules.append({'type': 'field', 'domain': ['geosite:google'], 'outboundTag': 'direct'})
base_rules.append({'type': 'field', 'outboundTag': 'blocked', 'ip': ['geoip:cn']})

cfg.setdefault('routing', {})['domainStrategy'] = 'IPOnDemand'
cfg['routing']['rules'] = base_rules + custom_rules

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

# 若为家宽落地机且填写了前置白名单 IP，经 Python ipaddress 强校验后自动部署 nftables 保护端口
if [ "$MODE" = "1" ] && [ "$REALITY_SUBMODE" = "3" ] && [ -n "$RES_WHITELIST_IP" ]; then
    mkdir -p /etc/nftables.d
    if LISTEN_PORT="$LISTEN_PORT" RES_WHITELIST_IP="$RES_WHITELIST_IP" python3 - << 'NFTPY'
import os, re, ipaddress
port = int(os.environ["LISTEN_PORT"])
raw = os.environ.get("RES_WHITELIST_IP", "")
tokens = [t.strip() for t in re.split(r"[,，\s]+", raw) if t.strip()]
v4_nets = [ipaddress.ip_network("127.0.0.0/8")]
v6_nets = [ipaddress.ip_network("::1/128")]
user_cnt = 0
for t in tokens:
    net = ipaddress.ip_network(t, strict=False)
    user_cnt += 1
    if net.version == 4:
        v4_nets.append(net)
    else:
        v6_nets.append(net)
if user_cnt == 0:
    raise SystemExit(1)
v4 = [str(n) for n in ipaddress.collapse_addresses(v4_nets)]
v6 = [str(n) for n in ipaddress.collapse_addresses(v6_nets)]
lines = [
    "table inet res_guard",
    "delete table inet res_guard",
    "table inet res_guard {",
    f"    set trusted_relays_v4 {{ type ipv4_addr; flags interval; elements = {{ {', '.join(v4)} }}; }}",
    f"    set trusted_relays_v6 {{ type ipv6_addr; flags interval; elements = {{ {', '.join(v6)} }}; }}",
    "    chain input {",
    "        type filter hook input priority filter; policy accept;",
    '        iifname "lo" accept',
    "        ct state established,related accept",
    f"        tcp dport {port} ip saddr @trusted_relays_v4 accept",
    f"        udp dport {port} ip saddr @trusted_relays_v4 accept",
    f"        tcp dport {port} ip6 saddr @trusted_relays_v6 accept",
    f"        udp dport {port} ip6 saddr @trusted_relays_v6 accept",
    f"        tcp dport {port} drop",
    f"        udp dport {port} drop",
    "    }",
    "    chain output {",
    "        type filter hook output priority filter; policy accept;",
    "        tcp dport 25 reject with tcp reset",
    "    }",
    "}",
]
open("/etc/nftables.d/res-guard.nft", "w", encoding="utf-8").write("\n".join(lines) + "\n")
NFTPY
    then
        if nft -f /etc/nftables.d/res-guard.nft; then
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
            systemctl daemon-reload && systemctl enable --now res-guard.service >/dev/null 2>&1 || true
            echo "  [OK] 家宽端口 ${LISTEN_PORT} 白名单已生效并配置开机自启 (res-guard.service)"
        else
            echo "  [警告] nftables 家宽白名单加载失败！请检查内核 nftables 支持！" >&2
        fi
    else
        echo "  [警告] 白名单 IP (${RES_WHITELIST_IP}) 含非法地址，已跳过防火墙白名单以免断联！" >&2
    fi
elif [ "$MODE" = "1" ] && [ "$REALITY_SUBMODE" = "3" ]; then
    systemctl disable --now res-guard.service >/dev/null 2>&1 || true
    nft delete table inet res_guard >/dev/null 2>&1 || true
    rm -f /etc/nftables.d/res-guard.nft /etc/systemd/system/res-guard.service
    systemctl daemon-reload >/dev/null 2>&1 || true
fi

# 方案 3：部署 Hysteria 2 + 20000-50000 端口跳跃
HY2_LINK=""
if [ "$MODE" = "3" ]; then
    HY2_PASS=""
    if [ -f /etc/hysteria/config.yaml ]; then
        HY2_PASS=$(awk '/^[[:space:]]*password:[[:space:]]*/ {sub(/^[[:space:]]*password:[[:space:]]*/, ""); sub(/[[:space:]]+#.*$/, ""); print; exit}' /etc/hysteria/config.yaml | tr -d '\r\n' | sed 's/^["'\'']//; s/["'\'']$//' || true)
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

    if [[ "$ENABLE_RELAY" =~ ^[Yy]$ ]] && [ -n "$RES_IP" ] && [ -n "$RES_PORT" ] && [ -n "$RES_SS_PASS" ]; then
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
  password: "$(printf '%s' "$HY2_PASS" | sed 's/\\/\\\\/g; s/"/\\"/g')"
acl:
${ACL_GEOIP_LINE}
  inline:
    - reject(all, tcp/25)
    - reject(all, udp/25)
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

    # 覆盖端口跳跃服务前先停止旧实例，确保修改监听端口时旧 PREROUTING 转发规则被干净卸载
    systemctl stop hy2-port-hopping.service 2>/dev/null || true
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
    systemctl enable --now hysteria-server && systemctl restart hysteria-server
    HY2_PASS_ENC=$(HY2_PASS="$HY2_PASS" python3 -c "import os, urllib.parse; print(urllib.parse.quote(os.environ['HY2_PASS'], safe=''))")
    URI_HOST="$SERVER_IP"
    [[ "$URI_HOST" == *:* && "$URI_HOST" != \[* ]] && URI_HOST="[${URI_HOST}]"
    HY2_LINK="hysteria2://${HY2_PASS_ENC}@${URI_HOST}:${LISTEN_PORT}?insecure=1&sni=www.bing.com&pinSHA256=${HY2_PIN}&mport=20000-50000#Hy2-PortHopping"
fi

# 每周日 04:00 平滑重启 x-ui 释放内存缓存
if command -v crontab >/dev/null 2>&1; then
    ( (crontab -l 2>/dev/null | grep -v "systemctl restart x-ui") || true; echo "0 4 * * 0 systemctl restart x-ui" ) | crontab - 2>/dev/null || true
fi
systemctl enable --now x-ui
systemctl restart x-ui

PANEL_PORT=$(python3 -c "import sqlite3; r=sqlite3.connect('/etc/x-ui/x-ui.db').execute(\"SELECT value FROM settings WHERE key='webPort' LIMIT 1\").fetchone(); print(r[0].strip() if r and r[0] else '54321')" 2>/dev/null | tr -dc '0-9' || true)
PANEL_PORT="${PANEL_PORT:-54321}"
PANEL_PATH=$(python3 -c "import sqlite3; r=sqlite3.connect('/etc/x-ui/x-ui.db').execute(\"SELECT value FROM settings WHERE key='webBasePath' LIMIT 1\").fetchone(); print(r[0].strip().strip('/') if r and r[0] else '')" 2>/dev/null || true)
PANEL_SCHEME=$(python3 -c "import sqlite3; r=sqlite3.connect('/etc/x-ui/x-ui.db').execute(\"SELECT value FROM settings WHERE key='webCertFile' LIMIT 1\").fetchone(); print('https' if r and r[0] and r[0].strip() else 'http')" 2>/dev/null || echo "http")
SSH_PORT_NOW=$( (sshd -T 2>/dev/null || true) | awk '$1=="port"{print $2; exit}' )
SSH_PORT_NOW="${SSH_PORT_NOW:-22}"
SSH_P_FLAG=""
[ "$SSH_PORT_NOW" != "22" ] && SSH_P_FLAG="-p ${SSH_PORT_NOW} "

echo ""
printf "${GREEN}==================================================================${R}\n"
printf "  ${GREEN}部署完成！服务状态验收：${R}\n"
printf "  ${SKY}- x-ui          :${R} ${GREEN}%s${R}\n" "$(systemctl is-active x-ui 2>/dev/null || true)"
[ "$MODE" = "3" ] && printf "  ${SKY}- hysteria      :${R} ${GREEN}%s${R}\n" "$(systemctl is-active hysteria-server 2>/dev/null || true)"
printf "  ${SKY}- Xray 内核     :${R} ${PINK}%s${R}\n" "$($XRAY_BIN version | head -n 1 || true)"
printf "${YELLOW}==================================================================${R}\n"
printf "  ${YELLOW}【3x-ui 面板安全访问指南】${R} ${ORANGE}(已锁死 127.0.0.1:%s，公网直连会拒绝访问属正常！)${R}\n" "${PANEL_PORT}"
printf "${YELLOW}==================================================================${R}\n"
printf "  ${WHITE}第 1 步：${R}在${ORANGE}【自己电脑】${R}按 Win+R 输 cmd 回车（Mac 开终端，${ORANGE}千万别在 FinalShell/VPS 里敲！${R}），复制运行：\n\n"
printf "  ${GREEN}ssh %s-L %s:127.0.0.1:%s root@%s${R}\n\n" "${SSH_P_FLAG}" "${PANEL_PORT}" "${PANEL_PORT}" "${SERVER_IP}"
printf "  ${DIM}（提示：输入 VPS root 密码时屏幕不显示字符属正常，输完回车；登录成功后黑框窗口【不要关闭】！）${R}\n"
printf "  ${WHITE}第 2 步：${R}打开自己电脑浏览器访问下方本地地址：\n"
printf "  ${CYAN}%s://127.0.0.1:%s/%s${R}\n" "${PANEL_SCHEME}" "${PANEL_PORT}" "${PANEL_PATH}"
printf "  ${WHITE}第 3 步：${R}浏览器若提示“不是私密连接”，点${GREEN}「高级」->「继续前往」${R}（本地自签证书正常现象）。\n"
printf "  ${DIM}（忘记面板账密时，可在 VPS 终端里直接输入 x-ui 查看或重置）${R}\n"
if [ -f /tmp/setup_result.txt ]; then
    if grep -q "^REUSED_EXISTING=1" /tmp/setup_result.txt; then
        printf "${DIM}------------------------------------------------------------------${R}\n"
        printf "  ${ORANGE}[提示] 检测到端口 %s 已存在入站节点，已复用原节点凭据并同步更新路由规则。${R}\n" "${LISTEN_PORT}"
    fi
    if grep -q "RESULT_TYPE=RESIDENTIAL_SS" /tmp/setup_result.txt; then
        printf "${DIM}------------------------------------------------------------------${R}\n"
        printf "  ${PINK}【家宽落地 SS-2022 中转凭据】${R}${DIM}（请复制到前置优化机脚本中）：${R}\n"
        grep -E "^SS_(IP|PORT|PASS)=" /tmp/setup_result.txt | sed 's/^/  /'
    elif grep -q "RESULT_TYPE=LINK" /tmp/setup_result.txt; then
        printf "${DIM}------------------------------------------------------------------${R}\n"
        printf "  ${GREEN}【客户端导入链接】${R}${DIM}（请先关掉客户端顶部总开关再测速！）：${R}\n"
        SHARE_URL=$(grep "^SHARE_LINK=" /tmp/setup_result.txt | cut -d'=' -f2- || true)
        printf "  ${WHITE}%s${R}\n" "${SHARE_URL}"
        if command -v qrencode >/dev/null 2>&1 && [ -n "$SHARE_URL" ]; then
            printf "  ${CYAN}【手机扫码导入（Shadowrocket / v2rayNG / Stash）】：${R}\n"
            qrencode -t ANSIUTF8 -m 1 "$SHARE_URL" || true
        fi
    fi
    rm -f /tmp/setup_result.txt
fi
if [ "$MODE" = "2" ]; then
    printf "${YELLOW}------------------------------------------------------------------${R}\n"
    printf "  ${YELLOW}【Cloudflare 后台 4 步检查清单 & 防坑必看】：${R}\n"
    printf "  ${GREEN}1.${R} DNS 添加 A 记录: ${CYAN}%s${R} -> ${CYAN}%s${R}（${ORANGE}务必开启小黄云 Proxied${R}）\n" "${CF_DOMAIN}" "${SERVER_IP}"
    printf "  ${GREEN}2.${R} SSL/TLS 加密模式必须选: ${GREEN}Full（完全）${R}（勿选 Flexible 或 Full Strict，防 525/526）\n"
    printf "  ${GREEN}3.${R} 云厂商安全组放行: ${CYAN}TCP %s${R}（CF 免费 HTTPS 端口仅支持 443/2053/2083/2087/2096/8443）\n" "${LISTEN_PORT}"
    printf "  ${GREEN}4.${R} ${ORANGE}国内防超时优选技巧：${R}若直连自己域名超时（CF 免费段 IP 国内常丢包），在客户端编辑节点，\n"
    printf "     ${WHITE}仅把「地址(Address)」改为 CF 优选域名（如 www.visa.com.hk）或优选 IP${R}，\n"
    printf "     ${WHITE}Host 与 SNI 保持 %s 不变${R}；测试前请${ORANGE}先关掉客户端总开关并用 4G/5G 测速${R}！\n" "${CF_DOMAIN}"
fi
if [ -n "$HY2_LINK" ]; then
    printf "${DIM}------------------------------------------------------------------${R}\n"
    printf "  ${PINK}【Hysteria 2 导入链接】：${R}\n"
    printf "  ${WHITE}%s${R}\n" "${HY2_LINK}"
    if command -v qrencode >/dev/null 2>&1; then
        printf "  ${CYAN}【手机扫码导入（Shadowrocket / v2rayNG / Stash）】：${R}\n"
        qrencode -t ANSIUTF8 -m 1 "$HY2_LINK" || true
    fi
fi
echo -e "${CYAN}══════════════════════════════════════════════════════════════════"
echo -e "  本脚本由 猫e/acc (CatEacc) 维护提供"
echo -e "  GitHub : https://github.com/CatEacc/vps-xray-runbook"
echo -e "  TG 频道: https://t.me/CatCryptoMaster"
echo -e "══════════════════════════════════════════════════════════════════${NC}"
