#!/usr/bin/env bash
# ==============================================================================
# CatEacc 生产级纯原生 Xray-core 无面板手搓 JSON 一键部署脚本 (pure.sh)
# 仓库: https://github.com/CatEacc/vps-xray-runbook
# 核心: Xray-core v26.11.9 (零面板 ~25MB 内存 | 标准 /usr/local/etc/xray/config.json)
# 规范: 100% 对齐 Project X / RPRX 官方文档 (XHTTP / Vision REALITY / mldsa65 / SS-2022)
# ==============================================================================
set -euo pipefail
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH"
trap 'rm -rf /tmp/pure_result.txt /tmp/xray-pure' EXIT

if [ "$(id -u)" -ne 0 ]; then
    echo "[错误] 请使用 root 权限运行本脚本 (sudo bash pure.sh)"
    exit 1
fi

XRAY_VERSION="v26.11.9"
XRAY_BIN="/usr/local/bin/xray"
XRAY_CFG="/usr/local/etc/xray/config.json"
XRAY_SHARE="/usr/local/share/xray"

ESC=$'\033'
R="${ESC}[0m"
B="${ESC}[1m"
DIM="${ESC}[2m"
WHITE="${ESC}[1;37m"
GREEN="${ESC}[1;32m"
CYAN="${ESC}[1;36m"
SKY="${ESC}[38;5;39m"
YELLOW="${ESC}[1;33m"
ORANGE="${ESC}[38;5;208m"
PINK="${ESC}[38;5;205m"

OS_INFO=$(grep -m1 '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"' || echo "Linux")
KERNEL_INFO=$(uname -r | cut -d- -f1)
ARCH_INFO=$(uname -m)
MEM_SHOW=$(LC_ALL=C free -m 2>/dev/null | awk '/^Mem:/ {print $2}')
MEM_SHOW="${MEM_SHOW:-0}"
BBR_STAT=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
MPTCP_STAT=$(sysctl -n net.mptcp.enabled 2>/dev/null || echo "n/a")
SERVER_IP=$(curl -4fsSm 4 https://api.ipify.org 2>/dev/null || curl -4fsSm 4 https://ifconfig.me/ip 2>/dev/null || curl -6fsSm 4 https://api64.ipify.org 2>/dev/null || echo "YOUR_SERVER_IP")
SERVER_IP=$(printf "%s" "$SERVER_IP" | tr -d '[:space:]')
[[ "$SERVER_IP" =~ ^[0-9a-fA-F.:]+$ ]] || SERVER_IP="YOUR_SERVER_IP"

SCRIPT_VER=$(curl -fsSm 2 https://api.github.com/repos/CatEacc/vps-xray-runbook/releases/latest 2>/dev/null | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n 1 | cut -d'"' -f4 || true)
SCRIPT_VER="${SCRIPT_VER:-v1.2.7}"

print_cateacc_logo() {
    local G1="${ESC}[38;5;46m" G2="${ESC}[38;5;82m" G3="${ESC}[38;5;154m" G4="${ESC}[38;5;226m"
    local G5="${ESC}[38;5;220m" G6="${ESC}[38;5;208m" G7="${ESC}[38;5;199m"
    awk -v c1="$G1" -v c2="$G2" -v c3="$G3" -v c4="$G4" -v c5="$G5" -v c6="$G6" -v c7="$G7" -v rs="$R" -v bd="$B" '
    {
        line = $0
        while (length(line) < 42) line = line " "
        printf "  %s%s%s%s%s%s%s%s%s%s%s%s%s%s%s\n", \
            bd c1, substr(line, 1, 6), c2, substr(line, 7, 6), c3, substr(line, 13, 6), \
            c4, substr(line, 19, 6), c5, substr(line, 25, 6), c6, substr(line, 31, 6), c7, substr(line, 37, 6), rs
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

MODE="${1:-}"
SNI_QUERY_ARG="${2:-}"
if [ -z "$MODE" ]; then
    clear 2>/dev/null || true
    printf '\n'
    print_cateacc_logo
    printf '\n'
    printf "  ${CYAN}猫e/acc (CatEacc)${R} ${DIM}· 纯原生 Xray-core 无面板手搓 JSON 脚本 ${YELLOW}${SCRIPT_VER}${R}\n"
    printf "  ${GREEN}──────────────────────────────────────────────────────────${R}\n"
    printf "  ${SKY}OS:${R}       ${GREEN}${OS_INFO} (${ARCH_INFO})${R}\n"
    printf "  ${SKY}Kernel:${R}   ${GREEN}${KERNEL_INFO}${R}  ${DIM}|${R}  ${SKY}BBR:${R} ${GREEN}${BBR_STAT}${R}  ${DIM}|${R}  ${SKY}MPTCP:${R} ${GREEN}${MPTCP_STAT}${R}\n"
    printf "  ${SKY}Memory:${R}   ${GREEN}${MEM_SHOW} MB${R}  ${DIM}|${R}  ${SKY}IP:${R} ${CYAN}${SERVER_IP}${R}\n"
    printf "  ${SKY}Service:${R}  xray $(svc_badge xray)  ${DIM}|${R}  ${PINK}Xray ${XRAY_VERSION} (零面板 ~25MB RAM)${R}\n"
    printf "  ${SKY}Config:${R}   ${DIM}${XRAY_CFG}${R}\n"
    printf "  ${SKY}GitHub:${R}   ${CYAN}https://github.com/CatEacc/vps-xray-runbook${R}\n"
    printf "  ${GREEN}──────────────────────────────────────────────────────────${R}\n\n"
    printf "  ${WHITE}请选择部署方案（纯官方 Xray-core，无面板）：${R}\n"
    printf "  ${GREEN}[1]${R} ${WHITE}VLESS + REALITY${R} ${CYAN}★ 推荐 · XHTTP / Vision / mldsa65 / 家宽落地与中转${R}\n"
    printf "      ${DIM}100%% 原生手搓 JSON，回车默认 443，支持 9 大地区非 CF SNI 自动测速复检${R}\n"
    printf "  ${GREEN}[2]${R} ${WHITE}Cloudflare CDN 优选${R} ${YELLOW}· VLESS + XHTTP + TLS${R}\n"
    printf "      ${DIM}隐藏源站真实 IP、晚高峰兜底，回车默认 2053 可自选回源端口${R}\n"
    printf "  ${GREEN}[3]${R} ${WHITE}纯系统底层内核调优模式${R} ${ORANGE}· 零代理内核${R}\n"
    printf "      ${DIM}BBR+FQ / 按内存分档缓冲 / 1GB Swap / MPTCP 防护 / 默认封 TCP 25 / Fail2ban${R}\n"
    printf "  ${GREEN}[4]${R} ${WHITE}一键导出所有节点链接 & 二维码${R} ${CYAN}· 只读${R}\n"
    printf "  ${GREEN}[5]${R} ${WHITE}本机家宽 / 商宽 / 机房 IP 与环境快检${R} ${SKY}· 只读 · 不测流媒体${R}\n"
    printf "  ${GREEN}[6]${R} ${WHITE}REALITY 优选 SNI 测速与域名四重体检${R} ${CYAN}· 只读 · 零改动筛域名${R}\n\n"
    read -rp "$(printf "${YELLOW}  请输入方案编号 [1-6] (回车默认 1): ${R}")" MODE || MODE="1"
    MODE="${MODE:-1}"
fi

LISTEN_PORT=""
SUBMODE="1"          # 1=XHTTP+REALITY, 2=raw+Vision+REALITY, 3=家宽SS-2022落地
REALITY_SNI="addons.mozilla.org"
ENABLE_MLDSA65="n"
CF_DOMAIN="cf.example.com"
CF_OPT_HOST="www.visa.com.hk"
ENABLE_RELAY="n"
RES_IP=""
RES_PORT=""
RES_SS_PASS=""
RES_WHITELIST_IP=""

verify_reality_sni() {
    local target_sni="$1"
    command -v python3 >/dev/null 2>&1 || return 0
    printf "  ${SKY}-> 正在对 ${WHITE}%s${SKY} 执行实时四重复检 (TLS 1.3+H2 / 非 CF / 无国内 CDN / 大陆可达)...${R}\n" "$target_sni"
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
    cn_note, cn_warn = "国内探针暂跳过", ""
    try:
        payload = json.dumps({"type": "http", "target": h, "locations": [{"country": "CN"}], "limit": 2, "measurementOptions": {"protocol": "HTTPS", "port": 443, "request": {"method": "HEAD", "path": "/"}}}).encode()
        req = urllib.request.Request("https://api.globalping.io/v1/measurements", data=payload, headers={"Content-Type": "application/json", "User-Agent": "CatEacc-SNI-Check/1.0"})
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
                cn_warn = "中国大陆探针超时未响应(疑似被墙)"
            elif finished:
                ok_cnt, cn_cdn_ip = 0, ""
                for item in finished:
                    res = item.get("result", {})
                    if res.get("status") == "finished" and res.get("statusCode", 0) > 0:
                        ok_cnt += 1
                    rip = res.get("resolvedAddress", "")
                    if rip and not cn_cdn_ip:
                        try:
                            cc = urllib.request.urlopen(f"https://ipinfo.io/{rip}/country", timeout=2.5).read().decode().strip()
                            if cc == "CN":
                                cn_cdn_ip = rip
                        except Exception:
                            pass
                cn_note = f"大陆实测 {ok_cnt}/{len(finished)} 通"
                if cn_cdn_ip:
                    cn_warn = f"存在中国大陆 CDN 节点({cn_cdn_ip})"
                elif ok_cnt == 0:
                    cn_warn = "中国大陆节点全部不可达(疑似被墙)"
    except Exception:
        pass
    warns = []
    if ver != "TLSv1.3": warns.append(f"TLS={ver}")
    if alpn != "h2": warns.append(f"ALPN={alpn}")
    if is_cf: warns.append("套了 Cloudflare")
    if cn_warn: warns.append(cn_warn)
    if warns:
        print(f"WARN|{ver}/{alpn} {rtt:.0f}ms | {cn_note} | 风险: {'; '.join(warns)}")
    else:
        print(f"OK|{ver}/{alpn} {rtt:.0f}ms | 非 CF | 无国内 CDN | {cn_note}")
except Exception as e:
    print(f"WARN|443 握手失败 ({e})")
CHKPY
    ) || true
    case "$chk_out" in
        OK\|*)   printf "  ${GREEN}[实时复检通过]${R} %s\n" "${chk_out#OK|}"; return 0 ;;
        WARN\|*) printf "  ${YELLOW}[实时复检警告]${R} %s\n" "${chk_out#WARN|}"; return 1 ;;
    esac
    return 1
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

prompt_relay_ss() {
    read -rp "是否一键中转至海外住宅家宽 (Shadowsocks-2022 落地)? [y/N]: " ENABLE_RELAY
    ENABLE_RELAY="${ENABLE_RELAY:-n}"
    if [[ "$ENABLE_RELAY" =~ ^[Yy]$ ]]; then
        read -rp "请粘贴家宽 ss:// 链接（或直接输入家宽 IPv4）: " RES_INPUT
        if [[ "$RES_INPUT" == ss://* ]] && command -v python3 >/dev/null 2>&1; then
            local parsed
            parsed=$(SS_URI="$RES_INPUT" python3 - << 'SSPY'
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
                echo "  [解析成功] 落地=${RES_IP}:${RES_PORT}"
                return 0
            else
                echo "  [提示] ss:// 链接解析失败，请改为分步输入："
                read -rp "请输入后端家宽机 IP: " RES_IP
            fi
        else
            RES_IP=$(printf "%s" "$RES_INPUT" | tr -d '[:space:]')
        fi
        read -rp "请输入后端家宽 SS-2022 端口: " RES_PORT
        RES_PORT=$(validate_port "${RES_PORT:-30001}" 30001)
        read -rp "请输入后端家宽 SS-2022 密钥: " RES_SS_PASS
        RES_SS_PASS=$(printf "%s" "$RES_SS_PASS" | tr -d '[:space:]')
    fi
}

case "$MODE" in
    1)
        echo ""
        printf "  ${CYAN}─── 方案 1：纯原生 Xray-core 子模式 ───${R}\n"
        printf "  ${GREEN}[1]${R} ${WHITE}VLESS + XHTTP + REALITY${R} ${DIM}（RPRX 主推 H2/XMUX，适合新版 v2rayN/v2rayNG）${R}\n"
        printf "  ${GREEN}[2]${R} ${WHITE}VLESS + raw + REALITY + Vision${R} ${CYAN}（全客户端通吃，极低延迟）${R}\n"
        printf "  ${GREEN}[3]${R} ${WHITE}设为【海外住宅家宽落地机】${R} ${PINK}（高位端口 SS-2022，供前置机一键中转）${R}\n"
        read -rp "$(printf "  ${YELLOW}请选择子模式 [1-3] (回车默认 1): ${R}")" SUBMODE
        SUBMODE="${SUBMODE:-1}"

        if [ "$SUBMODE" = "3" ]; then
            RAND_PORT=$(shuf -i 20000-55000 -n 1 2>/dev/null || echo 38421)
            read -rp "请输入家宽落地监听高位端口 (回车随机 ${RAND_PORT}，勿用 80/443): " LISTEN_PORT
            LISTEN_PORT=$(validate_port "${LISTEN_PORT:-$RAND_PORT}" "$RAND_PORT")
            read -rp "可选：输入允许连入的前置中转机公网 IP（直接回车跳过白名单，多个用逗号分隔）: " RES_WHITELIST_IP
        else
            read -rp "请输入 REALITY 监听端口 (回车默认 443，可自定义如 8443): " LISTEN_PORT
            LISTEN_PORT=$(validate_port "${LISTEN_PORT:-443}" 443)
            printf "\n  ${CYAN}─── 请选择 REALITY 目标域名 (SNI) ───${R}\n"
            printf "  ${GREEN}[1]${R} ${WHITE}按机房地区自动测速优选${R} ${ORANGE}★ 推荐：本土 5 站 + 全球兜底池 + 实时四重复检${R}\n"
            printf "  ${GREEN}[2]${R} ${WHITE}addons.mozilla.org${R}     ${DIM}（免测默认：Firefox 扩展商店 · 纯海外无国内 CDN）${R}\n"
            printf "  ${GREEN}[3]${R} ${WHITE}www.gentoo.org${R}         ${DIM}（免测默认：Gentoo Linux 官网 · 非 CF 国内直连可达）${R}\n"
            printf "  ${GREEN}[4]${R} ${WHITE}手动输入自定义域名${R}\n"
            read -rp "$(printf "  ${YELLOW}请选择 SNI 方式 [1-4] (回车默认 1): ${R}")" SNI_CHOICE
            SNI_CHOICE="${SNI_CHOICE:-1}"
            case "$SNI_CHOICE" in
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
                        echo "  [提示] 测速未命中或尚未安装 python3，自动回退 addons.mozilla.org"
                        REALITY_SNI="addons.mozilla.org"
                    fi
                    ;;
                2) REALITY_SNI="addons.mozilla.org" ;;
                3) REALITY_SNI="www.gentoo.org" ;;
                4)
                    read -rp "请输入自定义 REALITY 域名: " SNI_CUSTOM
                    REALITY_SNI=$(clean_domain "${SNI_CUSTOM:-addons.mozilla.org}")
                    if [[ ! "$REALITY_SNI" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
                        echo "  [提示] 域名格式异常，自动回退 addons.mozilla.org"
                        REALITY_SNI="addons.mozilla.org"
                    fi
                    verify_reality_sni "$REALITY_SNI" || true
                    ;;
                *) REALITY_SNI="addons.mozilla.org" ;;
            esac
            read -rp "是否开启 RPRX 最新抗量子 REALITY 签名 (mldsa65，需新版 v2rayN/v2rayNG)? [y/N]: " ENABLE_MLDSA65
            ENABLE_MLDSA65="${ENABLE_MLDSA65:-n}"
            prompt_relay_ss
        fi
        ;;
    2)
        read -rp "请输入 Cloudflare CDN 回源端口 (回车默认 2053，支持 443/2053/2083/2087/2096/8443): " LISTEN_PORT
        LISTEN_PORT=$(validate_port "${LISTEN_PORT:-2053}" 2053)
        case "$LISTEN_PORT" in
            443|2053|2083|2087|2096|8443) ;;
            *) echo "  [警告] 端口 ${LISTEN_PORT} 不在 Cloudflare 免费版 HTTPS 列表 (443/2053/2083/2087/2096/8443) 内，开启小黄云将无法回源！" ;;
        esac
        read -rp "请输入已绑定并开启小黄云的 CF 域名 (如 cf.example.com): " CF_IN
        CF_DOMAIN=$(clean_domain "${CF_IN:-cf.example.com}")
        if [[ ! "$CF_DOMAIN" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]]; then
            echo "[错误] Cloudflare 域名格式非法: ${CF_DOMAIN}"
            exit 1
        fi
        printf "\n  ${CYAN}─── 请选择 Cloudflare 优选入口地址（生成免手动修改的加速链接） ───${R}\n"
        printf "  ${GREEN}[1]${R} ${WHITE}www.visa.com.hk${R}        ${CYAN}★ 推荐 · 104.18.21.* 企业级段（三网实测可用）${R}\n"
        printf "  ${GREEN}[2]${R} ${WHITE}www.visa.co.jp${R}         ${DIM}（104.18.10.* 企业级段）${R}\n"
        printf "  ${GREEN}[3]${R} ${WHITE}www.visa.com.sg${R}        ${DIM}（104.18.12.* 企业级段）${R}\n"
        printf "  ${GREEN}[4]${R} ${WHITE}www.visa.com${R}           ${DIM}（104.18.14.* 企业级段）${R}\n"
        printf "  ${GREEN}[5]${R} ${WHITE}www.udacity.com${R}        ${DIM}（172.64.145.* 独立企业段 · 备选分流）${R}\n"
        printf "  ${GREEN}[6]${R} ${WHITE}手动输入自定义优选域名 / 优选 IP${R} ${DIM}（支持填 CloudflareST 自测优选 IP）${R}\n"
        read -rp "$(printf "  ${YELLOW}请选择优选入口 [1-6] (回车默认 1): ${R}")" CF_OPT_PICK || CF_OPT_PICK="1"
        case "${CF_OPT_PICK:-1}" in
            1) CF_OPT_HOST="www.visa.com.hk" ;;
            2) CF_OPT_HOST="www.visa.co.jp" ;;
            3) CF_OPT_HOST="www.visa.com.sg" ;;
            4) CF_OPT_HOST="www.visa.com" ;;
            5) CF_OPT_HOST="www.udacity.com" ;;
            6)
                read -rp "$(printf "  ${YELLOW}-> 请输入自定义 CF 优选域名或 IP: ${R}")" CF_OPT_IN || CF_OPT_IN=""
                CF_OPT_IN=$(printf "%s" "$CF_OPT_IN" | sed -E 's#^https?://##; s#/.*$##' | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')
                if [[ "$CF_OPT_IN" == *:* && "$CF_OPT_IN" != \[* ]]; then
                    CF_OPT_IN="[${CF_OPT_IN}]"
                fi
                if [[ "$CF_OPT_IN" =~ ^[a-z0-9.\[\]:-]+$ ]] && [ -n "$CF_OPT_IN" ]; then
                    CF_OPT_HOST="$CF_OPT_IN"
                else
                    printf "  ${ORANGE}-> [提示] 输入格式无效，已回退默认优选入口 www.visa.com.hk${R}\n"
                    CF_OPT_HOST="www.visa.com.hk"
                fi
                ;;
            *) CF_OPT_HOST="www.visa.com.hk" ;;
        esac
        printf "  ${GREEN}-> 已选定 CF 优选入口:${R} ${WHITE}%s${R} ${DIM}(Host/SNI 保持 %s 不变)${R}\n" "$CF_OPT_HOST" "$CF_DOMAIN"
        prompt_relay_ss
        ;;
    3)
        echo "  -> 将仅执行系统底层高并发内核调优 + 默认封禁出站 TCP 25（不安装 Xray）"
        ;;
    4|links)
        echo ""
        command -v python3 >/dev/null 2>&1 || { echo "  [提示] 当前系统缺少 python3，请先执行 apt-get update && apt-get install -y python3"; exit 1; }
        echo "=================================================================="
        echo "  本机纯原生 Xray-core 节点链接导出（纯只读）"
        echo "=================================================================="
        SERVER_IP="$SERVER_IP" XRAY_CFG="$XRAY_CFG" XRAY_BIN="$XRAY_BIN" python3 - << 'EXPPY'
import os, json, base64, urllib.parse, subprocess, shutil

def print_qr(url):
    if shutil.which("qrencode") and url:
        try:
            subprocess.run(["qrencode", "-t", "ANSIUTF8", "-m", "1", url], check=False)
        except Exception:
            pass

cfg_path = os.environ["XRAY_CFG"]
xray_bin = os.environ.get("XRAY_BIN", "/usr/local/bin/xray")
ip = os.environ["SERVER_IP"]
uri_ip = f"[{ip}]" if ":" in ip and not ip.startswith("[") else ip
if not os.path.exists(cfg_path):
    print(f"  未找到 {cfg_path}")
    raise SystemExit(0)
cfg = json.load(open(cfg_path, encoding="utf-8"))
meta_path = "/usr/local/etc/xray/.client_meta.json"
meta = json.load(open(meta_path, encoding="utf-8")) if os.path.exists(meta_path) else {}
found = 0
for inb in cfg.get("inbounds", []):
    proto = inb.get("protocol", "")
    tag = inb.get("tag", f"in-{inb.get('port')}")
    port = inb.get("port")
    s = inb.get("settings", {})
    st = inb.get("streamSettings", {})
    net = st.get("network", "tcp")
    sec = st.get("security", "none")
    if proto == "vless":
        url_net = "tcp" if net in ("raw", "tcp") else net
        for cl in s.get("clients", []):
            uid = cl.get("id", "")
            flow = cl.get("flow", "")
            conn_host = uri_ip
            q = [f"type={url_net}", "encryption=none", f"security={sec}"]
            if sec == "reality":
                rs = st.get("realitySettings", {})
                sni = (rs.get("serverNames") or [""])[0]
                sid = (rs.get("shortIds") or [""])[0]
                m = meta.get(tag, {})
                pbk = m.get("pbk", "")
                if not pbk and rs.get("privateKey") and os.path.exists(xray_bin):
                    try:
                        out = subprocess.check_output([xray_bin, "x25519", "-i", rs["privateKey"]], text=True)
                        for ln in out.splitlines():
                            if "Public" in ln or "Password" in ln:
                                pbk = ln.split(":", 1)[1].strip()
                                break
                    except Exception:
                        pass
                pbk = pbk or "<请查看部署输出公钥>"
                pqv = m.get("pqv", "")
                if not pqv and rs.get("mldsa65Seed") and os.path.exists(xray_bin):
                    try:
                        out = subprocess.check_output([xray_bin, "mldsa65", "-i", rs["mldsa65Seed"]], text=True)
                        for ln in out.splitlines():
                            if "Verify" in ln:
                                pqv = ln.split(":", 1)[1].strip()
                                break
                    except Exception:
                        pass
                q += [f"pbk={pbk}", "fp=chrome", f"sni={sni}", f"sid={sid}", "spx=%2F"]
                if pqv:
                    q.append(f"pqv={urllib.parse.quote(pqv, safe='')}")
            elif sec == "tls":
                host = st.get("tlsSettings", {}).get("serverName") or meta.get(tag, {}).get("host", "cf.example.com")
                conn_host = host
                q += [f"sni={host}", f"host={host}", "fp=chrome"]
            if net == "xhttp":
                xh = st.get("xhttpSettings", {})
                q += [f"path={urllib.parse.quote(xh.get('path', '/vless-xhttp'), safe='')}", f"mode={xh.get('mode', 'auto')}"]
            if flow:
                q.append(f"flow={flow}")
            link = f"vless://{uid}@{conn_host}:{port}?{'&'.join(q)}#{urllib.parse.quote(tag)}"
            print(f"  [{tag}] {link}")
            print_qr(link)
            found += 1
    elif proto == "shadowsocks":
        method = s.get("method", "2022-blake3-aes-256-gcm")
        pwd = s.get("password", "")
        cred = base64.urlsafe_b64encode(f"{method}:{pwd}".encode()).decode().rstrip("=")
        link = f"ss://{cred}@{uri_ip}:{port}#{urllib.parse.quote(tag)}"
        print(f"  [{tag}] {link}")
        print(f"    (家宽中转参数: IP={ip} | PORT={port} | PASS={pwd})")
        found += 1
if not found:
    print("  (当前未检测到业务入站)")
print("==================================================================")
EXPPY
        exit 0
        ;;
    5)
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
            if ip: break
        except Exception:
            pass
print(f"  公网 IPv4:   {ip or '获取失败'}")
ptr = "NONE"
if ip:
    try: ptr = socket.gethostbyaddr(ip)[0]
    except Exception: ptr = "NONE"
ptr_low = ptr.lower()
ptr_is_biz = any(k in ptr_low for k in (".biz.", "business", ".corp.", "-static-", "static."))
ptr_is_res = any(k in ptr_low for k in (".res.", "home", "dyn", "dhcp", "pool", "lightspeed", "fios", "cpe.", "cpe-", "hsd1", "cable"))
ptr_tag = "无反解（需结合下方属性判断）" if ptr == "NONE" else ("预警：疑似商宽前缀" if ptr_is_biz else ("住宅宽带特征" if ptr_is_res else "常规反解"))
print(f"  rDNS / PTR:  {ptr}  [{ptr_tag}]")
asn_str = org_str = isp_str = loc = ""
is_dc = is_proxy = is_mobile = None
try:
    req = urllib.request.Request(f"http://ip-api.com/json/{ip}?fields=status,countryCode,regionName,city,isp,org,as,hosting,proxy,mobile", headers={"User-Agent": "CatEacc-ISP-Check/1.0"})
    d = json.loads(urllib.request.urlopen(req, timeout=6).read().decode())
    if d.get("status") == "success":
        asn_str, isp_str, org_str = d.get("as") or "", d.get("isp") or "", d.get("org") or ""
        loc = f"{d.get('countryCode', '')} / {d.get('regionName', '')} / {d.get('city', '')}".strip(" /")
        is_dc, is_proxy, is_mobile = bool(d.get("hosting")), bool(d.get("proxy")), bool(d.get("mobile"))
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
if is_dc is not None:
    print(f"  属性标记:    hosting(机房)={is_dc} | proxy(代理)={is_proxy} | mobile(蜂窝)={is_mobile}")
rdap_net = rdap_range = rdap_org = ""
if ip:
    try:
        req = urllib.request.Request(f"https://rdap.org/ip/{ip}", headers={"User-Agent": "CatEacc-ISP-Check/1.0", "Accept": "application/rdap+json"})
        rd = json.loads(urllib.request.urlopen(req, timeout=6).read().decode())
        rdap_net = rd.get("name") or ""
        if rd.get("startAddress") and rd.get("endAddress"):
            rdap_range = f"{rd['startAddress']} - {rd['endAddress']}"
        for ent in (rd.get("entities") or []):
            vc = ent.get("vcardArray")
            if isinstance(vc, list) and len(vc) > 1:
                for it in vc[1]:
                    if isinstance(it, list) and len(it) >= 4 and it[0] == "fn":
                        rdap_org = str(it[3]); break
            if rdap_org: break
    except Exception:
        pass
print(f"  RDAP 归属:   NetName={rdap_net or '查询超时'} | 组织={rdap_org or '-'} | 段={rdap_range or '-'}")
virt = "unknown"
try: virt = subprocess.check_output(["systemd-detect-virt"], text=True, stderr=subprocess.DEVNULL).strip() or "none"
except Exception: pass
hv_b = False
try: hv_b = "hv_balloon" in open("/proc/modules", encoding="utf-8", errors="ignore").read()
except Exception: pass
print(f"  虚拟化环境:  {virt}" + (f" (Hyper-V，hv_balloon={'已加载/建议屏蔽' if hv_b else '未加载'})" if virt == "microsoft" else ""))
smtp_stat = "已封禁/不可达（安全）"
try:
    with socket.create_connection(("gmail-smtp-in.l.google.com", 25), timeout=2.5):
        smtp_stat = "可连出（未封禁，建议封禁出站 TCP 25）"
except Exception:
    pass
print(f"  出站 TCP 25: {smtp_stat}")
print("------------------------------------------------------------------")
comb_org = f"{asn_str} {isp_str} {org_str} {rdap_net} {rdap_org}".lower()
is_gfiber = "google fiber" in comb_org or "as16591" in comb_org
dc_sub_kw = ("cogent", "psinet", "hosting", "datacenter", "data center", "digitalocean", "amazon", "google cloud", "google llc", "oracle", "hetzner", "vultr", "linode", "akamai", "choopa", "colocrossing", "multacom", "zenlayer", "dmit")
dc_word_kw = {"cloud", "server", "vps", "aws", "ovh", "gcp"}
org_words = set(re.findall(r"[a-z0-9]+", comb_org))
looks_dc = (not is_gfiber) and (any(k in comb_org for k in dc_sub_kw) or bool(org_words & dc_word_kw))
asn_toks = {w for w in re.findall(r"[a-z0-9]+", asn_str.lower()) if len(w) >= 4 and not re.match(r"^as\d+$", w)}
is_mismatch = bool(asn_toks and rdap_org and not any(t in f"{rdap_net} {rdap_org}".lower() for t in asn_toks))
if is_dc is True or looks_dc:
    v = "[机房商业 VPS / 骨干网段] 建议作为前置迎宾/中转机（443 REALITY / CF CDN）"
elif is_dc is False and ptr_is_biz:
    v = "[运营商商宽段] 注意：PTR 含商宽特征（.biz / business / static），非纯住宅池"
elif is_dc is False and not is_proxy and ptr_is_res and not is_mismatch:
    v = "[原生住宅家宽] 建议作为后端纯净落地机（方案 1 -> 子模式 3 高位 SS-2022 + 白名单）"
elif is_mismatch:
    v = "[疑似广播 IP / 非原生池] 广播 ASN 与 RDAP 原始注册商不一致且无住宅 PTR"
else:
    v = "[疑似住宅/混合类型] 请结合 RDAP 与 IPinfo 双字段复核"
print(f"  综合建议:    {v}")
print("==================================================================")
ISPPY
        exit 0
        ;;
    6|sni)
        readonly_sni_menu "$SNI_QUERY_ARG"
        ;;
    *)
        echo "[错误] 无效编号: ${MODE}，仅支持 1 / 2 / 3 / 4 / 5 / 6"
        exit 1
        ;;
esac

# ------------------------------------------------------------------------------
# 阶段一：系统底层优化、1GB Swap、日志收敛、Fail2ban、高并发内核栈与默认封出站 TCP 25
# ------------------------------------------------------------------------------
echo "[1/4] 更新依赖并配置原子钟 / 1GB Swap / Journald 50M / 默认封禁出站 TCP 25 / Fail2ban..."
export DEBIAN_FRONTEND=noninteractive
apt-get -o DPkg::Lock::Timeout=60 update -y && (apt-get -o DPkg::Lock::Timeout=60 install -y curl wget unzip chrony nftables fail2ban python3 python3-systemd openssl qrencode || \
  apt-get -o DPkg::Lock::Timeout=60 install -y curl wget unzip chrony nftables fail2ban python3 openssl)

systemctl enable --now chrony 2>/dev/null || true
chronyc makestep 2>/dev/null || true
timedatectl set-timezone Asia/Shanghai 2>/dev/null || true

if [ ! -f /swapfile ]; then
    if fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none; then
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null 2>&1 || true
        if ! swapon /swapfile 2>/dev/null; then
            rm -f /swapfile
            dd if=/dev/zero of=/swapfile bs=1M count=1024 status=none 2>/dev/null || true
            chmod 600 /swapfile
            mkswap /swapfile >/dev/null 2>&1 || true
            swapon /swapfile 2>/dev/null || rm -f /swapfile
        fi
    fi
fi
if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "/swapfile"; then
    grep -q "/swapfile" /etc/fstab || echo "/swapfile none swap sw,nofail 0 0" >> /etc/fstab
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

if [ -f /etc/gai.conf ]; then
    sed -i '/^precedence ::ffff:0:0\/96\s\+100/d' /etc/gai.conf
    echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
fi

mkdir -p /run/sshd
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

echo "[2/4] 写入按内存分档的高并发网络内核栈 (BBR + FQ + MPTCP=0)..."
mkdir -p /etc/modules-load.d
printf "tcp_bbr\nnf_conntrack\n" > /etc/modules-load.d/99-proxy.conf
modprobe tcp_bbr 2>/dev/null || true
modprobe nf_conntrack 2>/dev/null || true

MEM_MB=$(LC_ALL=C free -m 2>/dev/null | awk '/^Mem:/ {print $2}')
if [ "${MEM_MB:-1000}" -le 700 ]; then
    RMEM_MAX=16777216; TCP_MAX=8388608; DEF_BUF=262144; CONN_MAX=65536; XRAY_BUF=32
elif [ "${MEM_MB:-1000}" -lt 1500 ]; then
    RMEM_MAX=33554432; TCP_MAX=16777216; DEF_BUF=524288; CONN_MAX=65536; XRAY_BUF=64
else
    RMEM_MAX=67108864; TCP_MAX=33554432; DEF_BUF=1048576; CONN_MAX=131072; XRAY_BUF=64
fi

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

if [ "$MODE" = "3" ]; then
    echo "=================================================================="
    echo "  纯系统底层内核调优完成（未安装代理内核）！"
    echo "=================================================================="
    exit 0
fi

# ------------------------------------------------------------------------------
# 阶段二：安装官方 Xray-core v26.11.9（纯无面板 systemd 服务）
# ------------------------------------------------------------------------------
echo "[3/4] 安装官方 Xray-core ${XRAY_VERSION} (${ARCH_INFO}) 与 systemd 守护进程..."
case "$ARCH_INFO" in
    x86_64|amd64)   XRAY_ARCH="64" ;;
    aarch64|arm64)  XRAY_ARCH="arm64-v8a" ;;
    *) echo "[错误] 暂不支持架构: ${ARCH_INFO}"; exit 1 ;;
esac

mkdir -p /tmp/xray-pure "$XRAY_SHARE" /usr/local/etc/xray
curl -fsSL -o /tmp/xray-pure/xray.zip "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-${XRAY_ARCH}.zip"
python3 -m zipfile -e /tmp/xray-pure/xray.zip /tmp/xray-pure/
install -m 755 /tmp/xray-pure/xray "${XRAY_BIN}.new" && mv -f "${XRAY_BIN}.new" "$XRAY_BIN"
install -m 644 /tmp/xray-pure/geoip.dat "${XRAY_SHARE}/geoip.dat"
install -m 644 /tmp/xray-pure/geosite.dat "${XRAY_SHARE}/geosite.dat"
rm -rf /tmp/xray-pure

cat << 'EOF' > /etc/systemd/system/xray.service
[Unit]
Description=Xray-core Service (Pure JSON, Zero Panel)
Documentation=https://xtls.github.io/
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
Environment="XRAY_LOCATION_ASSET=/usr/local/share/xray"
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=always
RestartSec=3s
LimitNOFILE=1048576
OOMScoreAdjust=-500

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload

# ------------------------------------------------------------------------------
# 阶段三：生成标准手搓 /usr/local/etc/xray/config.json 并执行 xray run -test 强校验
# ------------------------------------------------------------------------------
echo "[4/4] 生成标准手搓 JSON 并执行 xray run -test 强校验..."
if [ "$MODE" = "2" ]; then
    NEED_CF="0"
    if [ ! -f /usr/local/etc/xray/cf.crt ] || [ ! -f /usr/local/etc/xray/cf.key ]; then
        NEED_CF="1"
    elif ! openssl x509 -in /usr/local/etc/xray/cf.crt -noout -subject 2>/dev/null | grep -Fq "CN = ${CF_DOMAIN}" && \
         ! openssl x509 -in /usr/local/etc/xray/cf.crt -noout -subject 2>/dev/null | grep -Fq "CN=${CF_DOMAIN}"; then
        NEED_CF="1"
    fi
    if [ "$NEED_CF" = "1" ]; then
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 -nodes \
          -keyout /usr/local/etc/xray/cf.key -out /usr/local/etc/xray/cf.crt \
          -subj "/CN=${CF_DOMAIN}" -addext "subjectAltName=DNS:${CF_DOMAIN}" 2>/dev/null
    fi
    chmod 644 /usr/local/etc/xray/cf.crt && chmod 600 /usr/local/etc/xray/cf.key
fi

install -m 600 /dev/null /tmp/pure_result.txt
MODE="$MODE" SUBMODE="$SUBMODE" LISTEN_PORT="$LISTEN_PORT" REALITY_SNI="$REALITY_SNI" \
ENABLE_MLDSA65="$ENABLE_MLDSA65" CF_DOMAIN="$CF_DOMAIN" ENABLE_RELAY="$ENABLE_RELAY" \
RES_IP="$RES_IP" RES_PORT="$RES_PORT" RES_SS_PASS="$RES_SS_PASS" XRAY_BUF="$XRAY_BUF" \
SERVER_IP="$SERVER_IP" XRAY_BIN="$XRAY_BIN" XRAY_CFG="$XRAY_CFG" python3 - << 'GENPY' > /tmp/pure_result.txt
import os, json, uuid, secrets, subprocess, urllib.parse, base64
os.umask(0o077)

mode = os.environ["MODE"]
submode = os.environ["SUBMODE"]
port = int(os.environ["LISTEN_PORT"])
sni = os.environ["REALITY_SNI"]
use_pq = os.environ.get("ENABLE_MLDSA65", "n").lower() == "y"
cf_domain = os.environ["CF_DOMAIN"]
relay_on = os.environ.get("ENABLE_RELAY", "n").lower() == "y"
res_ip = os.environ["RES_IP"].strip()
res_port = os.environ["RES_PORT"].strip()
res_pass = os.environ["RES_SS_PASS"].strip()
buf_kb = int(os.environ.get("XRAY_BUF", "64"))
server_ip = os.environ["SERVER_IP"]
uri_ip = f"[{server_ip}]" if ":" in server_ip and not server_ip.startswith("[") else server_ip
xray_bin = os.environ["XRAY_BIN"]
cfg_path = os.environ["XRAY_CFG"]
meta_path = "/usr/local/etc/xray/.client_meta.json"

cfg = json.load(open(cfg_path, encoding="utf-8")) if os.path.exists(cfg_path) else {}
meta = json.load(open(meta_path, encoding="utf-8")) if os.path.exists(meta_path) else {}

cfg["log"] = {"access": "none", "error": "", "loglevel": "warning", "dnsLog": False}
cfg["policy"] = {
    "levels": {
        "0": {"handshake": 4, "connIdle": 120, "uplinkOnly": 2, "downlinkOnly": 5, "bufferSize": buf_kb}
    }
}

removed_tags = {x.get("tag") for x in cfg.get("inbounds", []) if x.get("port") == port and x.get("tag")}
for rt in removed_tags:
    meta.pop(rt, None)

inbounds = [x for x in cfg.get("inbounds", []) if x.get("port") != port]
outbounds = [x for x in cfg.get("outbounds", []) if x.get("tag") not in ("direct", "blocked")]
outbounds = [
    {"tag": "direct", "protocol": "freedom", "settings": {"domainStrategy": "UseIPv4"}},
    {"tag": "blocked", "protocol": "blackhole", "settings": {}},
] + outbounds

old_rules = cfg.get("routing", {}).get("rules", [])
custom_rules = []
for r in old_rules:
    if r.get("outboundTag") == "blocked" and (
        (bool(r.get("ip")) and set(r["ip"]) <= {"geoip:private", "geoip:cn"} and not r.get("domain") and not r.get("port") and not r.get("network") and not r.get("protocol") and not r.get("inboundTag") and not r.get("user"))
        or (r.get("protocol") == ["bittorrent"] and not r.get("ip") and not r.get("domain") and not r.get("port"))
        or (str(r.get("port", "")) == "25" and not r.get("ip") and not r.get("domain") and not r.get("protocol"))
    ):
        continue
    if r.get("outboundTag") == "direct" and r.get("domain") == ["geosite:google"] and not r.get("ip") and not r.get("inboundTag"):
        continue
    custom_rules.append(r)

share_link = ""
tag = f"in-{port}"

if mode == "1" and submode == "3":
    tag = f"ss-res-{port}"
    ss_pass = base64.b64encode(secrets.token_bytes(32)).decode()
    inbounds.append({
        "tag": tag, "listen": "::", "port": port, "protocol": "shadowsocks",
        "settings": {"method": "2022-blake3-aes-256-gcm", "password": ss_pass, "network": "tcp,udp"},
        "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic", "fakedns"], "routeOnly": True},
    })
    cred = base64.urlsafe_b64encode(f"2022-blake3-aes-256-gcm:{ss_pass}".encode()).decode().rstrip("=")
    share_link = f"ss://{cred}@{uri_ip}:{port}#{urllib.parse.quote(tag)}"
    print("RESULT_TYPE=RESIDENTIAL_SS")
    print(f"SS_IP={server_ip}")
    print(f"SS_PORT={port}")
    print(f"SS_PASS={ss_pass}")
elif mode == "1":
    uid = str(uuid.uuid4())
    sid = secrets.token_hex(4)
    out = subprocess.check_output([xray_bin, "x25519"], text=True)
    priv = pub = ""
    for line in out.splitlines():
        if "Private" in line: priv = line.split(":", 1)[1].strip()
        elif "Public" in line or "Password" in line: pub = line.split(":", 1)[1].strip()
    pq_seed = pq_verify = ""
    if use_pq:
        try:
            pq_out = subprocess.check_output([xray_bin, "mldsa65"], text=True, stderr=subprocess.DEVNULL)
            for line in pq_out.splitlines():
                if "Seed" in line: pq_seed = line.split(":", 1)[1].strip()
                elif "Verify" in line: pq_verify = line.split(":", 1)[1].strip()
        except Exception:
            pass
    is_xhttp = (submode == "1")
    tag = f"vless-{'xhttp' if is_xhttp else 'vision'}-reality-{port}"
    reality_cfg = {
        "show": False, "target": f"{sni}:443", "xver": 0, "serverNames": [sni],
        "privateKey": priv, "minClientVer": "1.0.0", "shortIds": [sid],
    }
    if pq_seed:
        reality_cfg["mldsa65Seed"] = pq_seed
    st = {
        "network": "xhttp" if is_xhttp else "raw",
        "security": "reality",
        "realitySettings": reality_cfg,
        "sockopt": {"tcpKeepAliveIdle": 120, "tcpKeepAliveInterval": 20},
    }
    if is_xhttp:
        st["xhttpSettings"] = {"path": "/vless-xhttp", "mode": "auto"}
    client_obj = {"id": uid, "email": f"user-{port}"}
    if not is_xhttp:
        client_obj["flow"] = "xtls-rprx-vision"
    inbounds.append({
        "tag": tag, "listen": "::", "port": port, "protocol": "vless",
        "settings": {"clients": [client_obj], "decryption": "none"},
        "streamSettings": st,
        "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic", "fakedns"], "routeOnly": True},
    })
    meta[tag] = {"pbk": pub, "pqv": pq_verify}
    q = [f"type={'xhttp' if is_xhttp else 'tcp'}", "encryption=none", "security=reality", f"pbk={pub}", "fp=chrome", f"sni={sni}", f"sid={sid}", "spx=%2F"]
    if is_xhttp: q += ["path=%2Fvless-xhttp", "mode=auto"]
    else: q.append("flow=xtls-rprx-vision")
    if pq_verify: q.append(f"pqv={urllib.parse.quote(pq_verify, safe='')}")
    share_link = f"vless://{uid}@{uri_ip}:{port}?{'&'.join(q)}#{urllib.parse.quote(tag)}"
    print("RESULT_TYPE=LINK")
elif mode == "2":
    uid = str(uuid.uuid4())
    tag = f"vless-cf-xhttp-{port}"
    inbounds.append({
        "tag": tag, "listen": "::", "port": port, "protocol": "vless",
        "settings": {"clients": [{"id": uid, "email": f"cf-{port}"}], "decryption": "none"},
        "streamSettings": {
            "network": "xhttp", "security": "tls",
            "xhttpSettings": {"path": "/vless-xhttp", "mode": "packet-up"},
            "tlsSettings": {"serverName": cf_domain, "certificates": [{"certificateFile": "/usr/local/etc/xray/cf.crt", "keyFile": "/usr/local/etc/xray/cf.key"}], "alpn": ["h2", "http/1.1"]},
            "sockopt": {"trustedXForwardedFor": ["CF-Connecting-IP", "X-Forwarded-For"], "tcpKeepAliveIdle": 120, "tcpKeepAliveInterval": 20},
        },
        "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic", "fakedns"], "routeOnly": True},
    })
    meta[tag] = {"host": cf_domain}
    share_link = f"vless://{uid}@{cf_domain}:{port}?type=xhttp&path=%2Fvless-xhttp&mode=packet-up&encryption=none&security=tls&sni={cf_domain}&host={cf_domain}&alpn=h2&fp=chrome#{urllib.parse.quote(tag)}"
    print("RESULT_TYPE=LINK")

stale_in_tags = removed_tags | {tag}
stale_ob_tags = {f"out-res-{t}" for t in stale_in_tags}
outbounds = [x for x in outbounds if x.get("tag") not in stale_ob_tags]
custom_rules = [
    r for r in custom_rules
    if not (set(r.get("inboundTag", [])) & stale_in_tags)
    and r.get("outboundTag") not in stale_ob_tags
]

if relay_on and res_ip and res_port and res_pass:
    ob_tag = f"out-res-{tag}"
    outbounds.append({
        "tag": ob_tag, "protocol": "shadowsocks",
        "settings": {"servers": [{"address": res_ip, "port": int(res_port), "method": "2022-blake3-aes-256-gcm", "password": res_pass}]},
    })
    custom_rules.append({"type": "field", "inboundTag": [tag], "outboundTag": ob_tag})

valid_ob_tags = {x.get("tag") for x in outbounds if x.get("tag")}
custom_rules = [r for r in custom_rules if not (str(r.get("outboundTag", "")).startswith("out-res-") and r.get("outboundTag") not in valid_ob_tags)]

cfg["inbounds"] = inbounds
cfg["outbounds"] = outbounds
has_relay_rule = any(str(r.get("outboundTag", "")).startswith("out-res-") for r in custom_rules)
base_rules = [
    {"type": "field", "outboundTag": "blocked", "ip": ["geoip:private"]},
    {"type": "field", "outboundTag": "blocked", "protocol": ["bittorrent"]},
    {"type": "field", "outboundTag": "blocked", "port": "25"},
]
if not has_relay_rule:
    base_rules.append({"type": "field", "domain": ["geosite:google"], "outboundTag": "direct"})
base_rules.append({"type": "field", "outboundTag": "blocked", "ip": ["geoip:cn"]})
cfg["routing"] = {
    "domainStrategy": "IPOnDemand",
    "rules": base_rules + custom_rules,
}

tmp_cfg = cfg_path + ".new"
with open(tmp_cfg, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
os.chmod(tmp_cfg, 0o600)
import sys
subprocess.check_call([xray_bin, "run", "-test", "-config", tmp_cfg], stdout=sys.stderr)
if os.path.exists(cfg_path):
    os.replace(cfg_path, cfg_path + ".bak")
os.replace(tmp_cfg, cfg_path)
with open(meta_path, "w", encoding="utf-8") as f:
    json.dump(meta, f, indent=2, ensure_ascii=False)
os.chmod(meta_path, 0o600)
print("SHARE_LINK=" + share_link)
GENPY

if [ "$MODE" = "1" ] && [ "$SUBMODE" = "3" ] && [ -n "$RES_WHITELIST_IP" ] && command -v nft >/dev/null 2>&1; then
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
    "}",
]
open("/etc/nftables.d/res-whitelist.nft", "w", encoding="utf-8").write("\n".join(lines) + "\n")
NFTPY
    then
        if nft -f /etc/nftables.d/res-whitelist.nft; then
            cat << 'EOF' > /etc/systemd/system/res-guard.service
[Unit]
Description=Xray Residential Landing Port Whitelist
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/nftables.d/res-whitelist.nft
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
elif [ "$MODE" = "1" ] && [ "$SUBMODE" = "3" ]; then
    systemctl disable --now res-guard.service >/dev/null 2>&1 || true
    nft delete table inet res_guard >/dev/null 2>&1 || true
    rm -f /etc/nftables.d/res-whitelist.nft /etc/systemd/system/res-guard.service
    systemctl daemon-reload >/dev/null 2>&1 || true
fi

systemctl enable --now xray
systemctl restart xray
sleep 1
echo ""
echo "=================================================================="
if systemctl is-active --quiet xray; then
    echo "  [成功] 纯原生 Xray-core (${XRAY_VERSION}) 已通过 xray run -test 并正常运行！"
else
    echo "  [警告] xray 服务未正常启动，请执行 journalctl -u xray -n 30 排查"
fi
echo "  配置文件路径: ${XRAY_CFG}（随时可直接手改 JSON）"
if [ -f /tmp/pure_result.txt ]; then
    SHARE_URL=$(grep "^SHARE_LINK=" /tmp/pure_result.txt | cut -d'=' -f2- || true)
    if grep -q "^RESULT_TYPE=RESIDENTIAL_SS" /tmp/pure_result.txt; then
        echo "------------------------------------------------------------------"
        echo "  【家宽落地 SS-2022 中转凭据】（请复制到前置优化机脚本中）："
        grep -E "^SS_(IP|PORT|PASS)=" /tmp/pure_result.txt | sed 's/^/  /'
        [ -n "$SHARE_URL" ] && echo "  分享链接: ${SHARE_URL}"
    elif [ -n "$SHARE_URL" ]; then
        echo "------------------------------------------------------------------"
        printf "  ${GREEN}【客户端导入链接】${R}${DIM}（请先关掉客户端顶部总开关再测速！）：${R}\n"
        printf "  ${WHITE}%s${R}\n" "${SHARE_URL}"
        if command -v qrencode >/dev/null 2>&1; then
            printf "  ${CYAN}【手机扫码导入（Shadowrocket / v2rayNG / Stash）】：${R}\n"
            qrencode -t ANSIUTF8 -m 1 "$SHARE_URL" || true
        fi
        if [ "$MODE" = "2" ]; then
            CF_OPT_URL="$(printf '%s' "$SHARE_URL" | sed -E "s|@[^:]+:|@${CF_OPT_HOST}:|")-CF%E4%BC%98%E9%80%89"
            printf "\n  ${YELLOW}【CF 优选加速链接（入口: %s，防国内默认免费段超时，直接扫这个更快更稳）】：${R}\n" "${CF_OPT_HOST}"
            printf "  ${GREEN}%s${R}\n" "${CF_OPT_URL}"
            if command -v qrencode >/dev/null 2>&1; then
                qrencode -t ANSIUTF8 -m 1 "$CF_OPT_URL" || true
            fi
        fi
    fi
    rm -f /tmp/pure_result.txt
fi
if [ "$MODE" = "2" ]; then
    echo "------------------------------------------------------------------"
    echo "  【Cloudflare 后台 4 步检查清单（小白照着点）】："
    echo "  1. DNS 添加 A 记录: ${CF_DOMAIN} -> ${SERVER_IP}（务必开启小黄云 Proxied）"
    echo "  2. SSL/TLS 设为: Full（自签证书勿选 Flexible 或 Full Strict，防 525/526）"
    echo "  3. 云厂商安全组放行: TCP ${LISTEN_PORT}（CF 支持 443/2053/2083/2087/2096/8443）"
    echo "  4. 客户端优选提速: 仅改「地址(Address)」为优选 IP/域名，Host 与 SNI 保持 ${CF_DOMAIN} 不变"
fi
echo "------------------------------------------------------------------"
echo "  只读查看全部节点: bash <(curl -fsSL https://raw.githubusercontent.com/CatEacc/vps-xray-runbook/main/pure.sh) 4"
echo "=================================================================="
