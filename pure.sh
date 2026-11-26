#!/usr/bin/env bash
# ==============================================================================
# CatEacc 生产级纯原生 Xray-core 无面板手搓 JSON 一键部署脚本 (pure.sh)
# 仓库: https://github.com/CatEacc/vps-xray-runbook
# 核心: Xray-core v26.11.9 (零面板 ~25MB 内存 | 标准 /usr/local/etc/xray/config.json)
# 规范: 100% 对齐 Project X / RPRX 官方文档 (XHTTP / Vision REALITY / mldsa65 / SS-2022)
# ==============================================================================
set -euo pipefail

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
MEM_SHOW=$(free -m 2>/dev/null | awk '/Mem:/ {print $2}')
MEM_SHOW="${MEM_SHOW:-0}"
BBR_STAT=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "unknown")
MPTCP_STAT=$(sysctl -n net.mptcp.enabled 2>/dev/null || echo "n/a")
SERVER_IP=$(curl -4fsSm 4 https://api.ipify.org 2>/dev/null || curl -4fsSm 4 https://ifconfig.me/ip 2>/dev/null || echo "未知")

SCRIPT_VER=$(curl -fsSm 2 https://api.github.com/repos/CatEacc/vps-xray-runbook/releases/latest 2>/dev/null | grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n 1 | cut -d'"' -f4 || true)
SCRIPT_VER="${SCRIPT_VER:-v1.2.4}"

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
    elif systemctl list-unit-files 2>/dev/null | grep -q "^$1"; then
        printf "${YELLOW}● 已停止${R}"
    else
        printf "${DIM}○ 未安装${R}"
    fi
}

MODE="${1:-}"
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
    printf "  ${GREEN}[5]${R} ${WHITE}本机家宽 / 商宽 / 机房 IP 与环境快检${R} ${SKY}· 只读 · 不测流媒体${R}\n\n"
    read -rp "$(printf "${YELLOW}  请输入方案编号 [1-5] (回车默认 1): ${R}")" MODE
    MODE="${MODE:-1}"
fi

LISTEN_PORT=""
SUBMODE="1"          # 1=XHTTP+REALITY, 2=raw+Vision+REALITY, 3=家宽SS-2022落地
REALITY_SNI="addons.mozilla.org"
ENABLE_MLDSA65="n"
CF_DOMAIN="cf.example.com"
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
        payload = json.dumps({"type": "http", "target": h, "locations": [{"country": "CN", "limit": 3}], "measurementOptions": {"protocol": "HTTPS", "port": 443, "request": {"method": "HEAD", "path": "/"}}}).encode()
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
            if finished:
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
        OK\|*)   printf "  ${GREEN}[实时复检通过]${R} %s\n" "${chk_out#OK|}" ;;
        WARN\|*) printf "  ${YELLOW}[实时复检警告]${R} %s\n" "${chk_out#WARN|}" ;;
    esac
}

prompt_relay_ss() {
    read -rp "是否一键中转至海外住宅家宽 (Shadowsocks-2022 落地)? [y/N]: " ENABLE_RELAY
    ENABLE_RELAY="${ENABLE_RELAY:-n}"
    if [[ "$ENABLE_RELAY" =~ ^[Yy]$ ]]; then
        read -rp "请粘贴家宽 ss:// 链接（或直接输入家宽 IPv4）: " RES_INPUT
        if [[ "$RES_INPUT" == ss://* ]]; then
            local parsed
            parsed=$(SS_URL="$RES_INPUT" python3 - << 'SSPY'
import os, base64, urllib.parse
u = os.environ["SS_URL"].strip().split("#", 1)[0]
body = u[5:]
if "@" in body:
    b64, hp = body.rsplit("@", 1)
    b64 += "=" * (-len(b64) % 4)
    cred = base64.urlsafe_b64decode(b64).decode()
    pwd = cred.split(":", 1)[1] if ":" in cred else cred
    host, port = hp.rsplit(":", 1)
else:
    body += "=" * (-len(body) % 4)
    dec = base64.urlsafe_b64decode(body).decode()
    cred, hp = dec.rsplit("@", 1)
    pwd = cred.split(":", 1)[1] if ":" in cred else cred
    host, port = hp.rsplit(":", 1)
print(f"{host.strip('[]')}|{port.split('/')[0]}|{pwd}")
SSPY
            ) || true
            IFS='|' read -r RES_IP RES_PORT RES_SS_PASS <<< "$parsed"
            echo "  [解析成功] 落地=${RES_IP}:${RES_PORT}"
        else
            RES_IP="$RES_INPUT"
            read -rp "请输入后端家宽 SS-2022 端口: " RES_PORT
            read -rp "请输入后端家宽 SS-2022 密钥: " RES_SS_PASS
        fi
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
            LISTEN_PORT="${LISTEN_PORT:-$RAND_PORT}"
            read -rp "可选：输入允许连入的前置中转机公网 IP（直接回车跳过白名单）: " RES_WHITELIST_IP
        else
            read -rp "请输入 REALITY 监听端口 (回车默认 443，可自定义如 8443): " LISTEN_PORT
            LISTEN_PORT="${LISTEN_PORT:-443}"
            printf "\n  ${CYAN}─── 请选择 REALITY 目标域名 (SNI) ───${R}\n"
            printf "  ${GREEN}[1]${R} ${WHITE}按机房地区自动测速优选${R} ${ORANGE}★ 推荐：本土 5 站 + 全球兜底池 + 实时四重复检${R}\n"
            printf "  ${GREEN}[2]${R} ${WHITE}addons.mozilla.org${R}     ${DIM}（免测默认：Firefox 扩展商店 · 纯海外无国内 CDN）${R}\n"
            printf "  ${GREEN}[3]${R} ${WHITE}www.gentoo.org${R}         ${DIM}（免测默认：Gentoo Linux 官网 · 非 CF 国内直连可达）${R}\n"
            printf "  ${GREEN}[4]${R} ${WHITE}手动输入自定义域名${R}\n"
            read -rp "$(printf "  ${YELLOW}请选择 SNI 方式 [1-4] (回车默认 1): ${R}")" SNI_CHOICE
            SNI_CHOICE="${SNI_CHOICE:-1}"
            case "$SNI_CHOICE" in
                1)
                    if command -v python3 >/dev/null 2>&1; then
                        echo "  -> 正在探测机房地区并并发测速本地纯海外 X25519 站点..."
                        SNI_LIST=$(python3 - << 'SNIPY'
import ssl, socket, time, json, urllib.request, concurrent.futures
cc = "US"
try:
    cc = json.loads(urllib.request.urlopen("https://ipinfo.io/json", timeout=3).read().decode()).get("country", "US").upper()
except Exception:
    pass
POOLS = {
    "US": [("www.discoverlosangeles.com","洛杉矶旅游局"),("www.caltech.edu","加州理工"),("www.stanford.edu","斯坦福大学"),("www.kernel.org","Linux内核"),("www.debian.org","Debian官网")],
    "JP": [("www.kyoto-u.ac.jp","京都大学"),("www.u-tokyo.ac.jp","东京大学"),("www.nhk.or.jp","NHK官网"),("www.nintendo.co.jp","任天堂日本"),("www.sony.jp","索尼日本")],
    "SG": [("www.nus.edu.sg","新加坡国立大学"),("www.smu.edu.sg","新加坡管理大学"),("www.sutd.edu.sg","新科大"),("www.dbs.com.sg","星展银行"),("www.singaporeair.com","新加坡航空")],
    "HK": [("www.hku.hk","香港大学"),("www.cuhk.edu.hk","香港中文大学"),("www.ust.hk","香港科大"),("www.cityu.edu.hk","香港城大"),("www.polyu.edu.hk","香港理工")],
    "DE": [("www.tum.de","慕尼黑工大"),("www.mpg.de","马普学会"),("www.bmw.de","宝马德国"),("www.heise.de","Heise科技"),("www.suse.com","SUSE官网")],
    "GB": [("www.cam.ac.uk","剑桥大学"),("www.imperial.ac.uk","帝国理工"),("www.bbc.co.uk","BBC官网"),("www.ed.ac.uk","爱丁堡大学"),("www.manchester.ac.uk","曼大")],
}
GLOBAL = [("addons.mozilla.org","Firefox扩展商店"),("www.gentoo.org","Gentoo官网"),("www.openssl.org","OpenSSL官网"),("www.archlinux.org","ArchLinux官网"),("www.kernel.org","Linux内核")]
cands = [("REG", h, d) for h, d in POOLS.get(cc, POOLS["US"])] + [("GLB", h, d) for h, d in GLOBAL]
def probe(item):
    grp, host, desc = item
    ctx = ssl.create_default_context()
    ctx.set_alpn_protocols(["h2", "http/1.1"])
    t0 = time.monotonic()
    try:
        with socket.create_connection((host, 443), timeout=2.5) as s:
            with ctx.wrap_socket(s, server_hostname=host) as ss:
                if ss.version() == "TLSv1.3" and ss.selected_alpn_protocol() == "h2":
                    return (grp, (time.monotonic() - t0) * 1000, host, desc)
    except Exception:
        pass
    return None
with concurrent.futures.ThreadPoolExecutor(max_workers=10) as ex:
    res = [r for r in ex.map(probe, cands) if r]
seen, out = set(), []
for grp in ("REG", "GLB"):
    for _, ms, h, d in sorted([x for x in res if x[0] == grp], key=lambda x: x[1]):
        if h not in seen:
            seen.add(h); out.append(f"{h}|{ms:.0f}|{d}")
        if len(out) >= 6: break
print("\n".join(out))
SNIPY
                        ) || true
                        if [ -n "$SNI_LIST" ]; then
                            mapfile -t SNI_ARR <<< "$SNI_LIST"
                            for i in "${!SNI_ARR[@]}"; do
                                IFS='|' read -r s_host s_ms s_desc <<< "${SNI_ARR[$i]}"
                                printf "  [%d] %-28s %4sms  (%s)\n" "$((i+1))" "$s_host" "$s_ms" "$s_desc"
                            done
                            read -rp "  -> 请选择编号 [1-${#SNI_ARR[@]}] (回车默认 1): " PICK_IDX
                            PICK_IDX="${PICK_IDX:-1}"
                            IFS='|' read -r REALITY_SNI _ _ <<< "${SNI_ARR[$((PICK_IDX-1))]}"
                        fi
                    fi
                    verify_reality_sni "$REALITY_SNI"
                    ;;
                2) REALITY_SNI="addons.mozilla.org" ;;
                3) REALITY_SNI="www.gentoo.org" ;;
                4)
                    read -rp "请输入自定义 REALITY 域名: " REALITY_SNI
                    REALITY_SNI="${REALITY_SNI:-addons.mozilla.org}"
                    verify_reality_sni "$REALITY_SNI"
                    ;;
            esac
            read -rp "是否开启 RPRX 最新抗量子 REALITY 签名 (mldsa65，需新版 v2rayN/v2rayNG)? [y/N]: " ENABLE_MLDSA65
            ENABLE_MLDSA65="${ENABLE_MLDSA65:-n}"
            prompt_relay_ss
        fi
        ;;
    2)
        read -rp "请输入 Cloudflare CDN 回源端口 (回车默认 2053): " LISTEN_PORT
        LISTEN_PORT="${LISTEN_PORT:-2053}"
        read -rp "请输入已绑定并开启小黄云的 CF 域名 (如 cf.example.com): " CF_DOMAIN
        CF_DOMAIN="${CF_DOMAIN:-cf.example.com}"
        prompt_relay_ss
        ;;
    3)
        echo "  -> 将仅执行系统底层高并发内核调优 + 默认封禁出站 TCP 25（不安装 Xray）"
        ;;
    4)
        echo ""
        echo "=================================================================="
        echo "  本机纯原生 Xray-core 节点链接导出（纯只读）"
        echo "=================================================================="
        SERVER_IP="$SERVER_IP" XRAY_CFG="$XRAY_CFG" python3 - << 'EXPPY'
import os, json, base64, urllib.parse
cfg_path = os.environ["XRAY_CFG"]
ip = os.environ["SERVER_IP"]
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
        for cl in s.get("clients", []):
            uid = cl.get("id", "")
            flow = cl.get("flow", "")
            q = [f"type={net}", "encryption=none", f"security={sec}"]
            if sec == "reality":
                rs = st.get("realitySettings", {})
                sni = (rs.get("serverNames") or [""])[0]
                sid = (rs.get("shortIds") or [""])[0]
                m = meta.get(tag, {})
                pbk = m.get("pbk", "<请查看部署输出公钥>")
                q += [f"pbk={pbk}", "fp=chrome", f"sni={sni}", f"sid={sid}", "spx=%2F"]
                if m.get("pqv"):
                    q.append(f"pqv={m['pqv']}")
            elif sec == "tls":
                host = meta.get(tag, {}).get("host", "cf.example.com")
                q += [f"sni={host}", f"host={host}"]
            if net == "xhttp":
                xh = st.get("xhttpSettings", {})
                q += [f"path={urllib.parse.quote(xh.get('path', '/vless-xhttp'))}", f"mode={xh.get('mode', 'auto')}"]
            if flow:
                q.append(f"flow={flow}")
            print(f"  [{tag}] vless://{uid}@{ip}:{port}?{'&'.join(q)}#{urllib.parse.quote(tag)}")
            found += 1
    elif proto == "shadowsocks":
        method = s.get("method", "2022-blake3-aes-256-gcm")
        pwd = s.get("password", "")
        cred = base64.urlsafe_b64encode(f"{method}:{pwd}".encode()).decode().rstrip("=")
        print(f"  [{tag}] ss://{cred}@{ip}:{port}#{urllib.parse.quote(tag)}")
        found += 1
if not found:
    print("  (当前未检测到业务入站)")
print("==================================================================")
EXPPY
        exit 0
        ;;
    5)
        echo ""
        echo "=================================================================="
        echo "  本机家宽 / 商宽 / 机房 IP 与环境快检（纯只读，不碰流媒体）"
        echo "=================================================================="
        SERVER_IP="$SERVER_IP" python3 - << 'ISPPY'
import os, json, socket, subprocess, urllib.request
ip = os.environ.get("SERVER_IP", "").strip()
if not ip or ip == "未知":
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
ptr_is_res = any(k in ptr_low for k in (".res.", "home", "dyn", "dhcp", "pool", "lightspeed", "fios", "cpe."))
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
dc_kw = ("cogent", "psinet", "hosting", "datacenter", "data center", "cloud", "server", "vps", "digitalocean", "amazon", "aws", "google", "oracle", "hetzner", "ovh", "vultr", "linode", "akamai", "choopa", "colocrossing", "multacom", "zenlayer", "dmit")
comb_org = f"{asn_str} {isp_str} {org_str} {rdap_net} {rdap_org}".lower()
looks_dc = any(k in comb_org for k in dc_kw)
asn_toks = {w for w in asn_str.lower().replace(",", " ").replace(".", " ").split() if len(w) >= 4 and not w.startswith("as")}
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
    *)
        echo "[错误] 无效编号: ${MODE}，仅支持 1 / 2 / 3 / 4 / 5"
        exit 1
        ;;
esac

# ------------------------------------------------------------------------------
# 阶段一：系统底层优化、1GB Swap、日志收敛、Fail2ban、高并发内核栈与默认封出站 TCP 25
# ------------------------------------------------------------------------------
echo "[1/4] 更新依赖并配置原子钟 / 1GB Swap / Journald 50M / 默认封禁出站 TCP 25..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y && apt-get install -y curl wget unzip chrony nftables fail2ban python3 python3-systemd openssl qrencode || \
  apt-get install -y curl wget unzip chrony nftables fail2ban python3 python3-systemd openssl

systemctl enable --now chrony
chronyc makestep || true
timedatectl set-timezone Asia/Shanghai 2>/dev/null || true

if [ ! -f /swapfile ]; then
    fallocate -l 1G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=1024
    chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile || true
fi
grep -q "/swapfile" /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab

cat << 'EOF' > /etc/systemd/journald.conf
[Journal]
SystemMaxUse=50M
SystemMaxFileSize=10M
RuntimeMaxUse=20M
MaxRetentionSec=7day
ForwardToSyslog=no
EOF
systemctl restart systemd-journald 2>/dev/null || true
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service 2>/dev/null || true

if [ -f /etc/gai.conf ]; then
    sed -i '/^precedence ::ffff:0:0\/96\s\+100/d' /etc/gai.conf
    echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
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
    systemctl daemon-reload && systemctl enable smtp-guard.service >/dev/null 2>&1 || true
fi

echo "[2/4] 写入按内存分档的高并发网络内核栈 (BBR + FQ + MPTCP=0)..."
mkdir -p /etc/modules-load.d
printf "tcp_bbr\nnf_conntrack\n" > /etc/modules-load.d/99-proxy.conf
modprobe tcp_bbr 2>/dev/null || true
modprobe nf_conntrack 2>/dev/null || true

MEM_MB=$(free -m | awk '/Mem:/ {print $2}')
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
    x86_64)  XRAY_ARCH="64" ;;
    aarch64) XRAY_ARCH="arm64-v8a" ;;
    *) echo "[错误] 暂不支持架构: ${ARCH_INFO}"; exit 1 ;;
esac

mkdir -p /tmp/xray-pure "$XRAY_SHARE" /usr/local/etc/xray
curl -fsSL -o /tmp/xray-pure/xray.zip "https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-${XRAY_ARCH}.zip"
python3 -m zipfile -e /tmp/xray-pure/xray.zip /tmp/xray-pure/
install -m 755 /tmp/xray-pure/xray "$XRAY_BIN"
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
if [ "$MODE" = "2" ] && { [ ! -f /usr/local/etc/xray/cf.crt ] || [ ! -f /usr/local/etc/xray/cf.key ]; }; then
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -days 3650 -nodes \
      -keyout /usr/local/etc/xray/cf.key -out /usr/local/etc/xray/cf.crt \
      -subj "/CN=${CF_DOMAIN}" -addext "subjectAltName=DNS:${CF_DOMAIN}" 2>/dev/null
    chmod 600 /usr/local/etc/xray/cf.key
fi

MODE="$MODE" SUBMODE="$SUBMODE" LISTEN_PORT="$LISTEN_PORT" REALITY_SNI="$REALITY_SNI" \
ENABLE_MLDSA65="$ENABLE_MLDSA65" CF_DOMAIN="$CF_DOMAIN" ENABLE_RELAY="$ENABLE_RELAY" \
RES_IP="$RES_IP" RES_PORT="$RES_PORT" RES_SS_PASS="$RES_SS_PASS" XRAY_BUF="$XRAY_BUF" \
SERVER_IP="$SERVER_IP" XRAY_BIN="$XRAY_BIN" XRAY_CFG="$XRAY_CFG" python3 - << 'GENPY'
import os, json, uuid, secrets, subprocess, urllib.parse, base64

mode = os.environ["MODE"]
submode = os.environ["SUBMODE"]
port = int(os.environ["LISTEN_PORT"])
sni = os.environ["REALITY_SNI"]
use_pq = os.environ.get("ENABLE_MLDSA65", "n").lower() == "y"
cf_domain = os.environ["CF_DOMAIN"]
relay_on = os.environ.get("ENABLE_RELAY", "n").lower() == "y"
res_ip, res_port, res_pass = os.environ["RES_IP"], os.environ["RES_PORT"], os.environ["RES_SS_PASS"]
buf_kb = int(os.environ.get("XRAY_BUF", "64"))
server_ip = os.environ["SERVER_IP"]
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
        set(r.get("ip", [])) <= {"geoip:private", "geoip:cn"}
        or r.get("protocol") == ["bittorrent"]
        or str(r.get("port", "")) == "25"
    ):
        continue
    custom_rules.append(r)

share_link = ""
tag = f"in-{port}"

if mode == "1" and submode == "3":
    tag = f"ss-res-{port}"
    ss_pass = base64.b64encode(secrets.token_bytes(32)).decode()
    inbounds.append({
        "tag": tag, "listen": "0.0.0.0", "port": port, "protocol": "shadowsocks",
        "settings": {"method": "2022-blake3-aes-256-gcm", "password": ss_pass, "network": "tcp,udp"},
        "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic", "fakedns"], "routeOnly": True},
    })
    cred = base64.urlsafe_b64encode(f"2022-blake3-aes-256-gcm:{ss_pass}".encode()).decode().rstrip("=")
    share_link = f"ss://{cred}@{server_ip}:{port}#{urllib.parse.quote(tag)}"
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
        "tag": tag, "listen": "0.0.0.0", "port": port, "protocol": "vless",
        "settings": {"clients": [client_obj], "decryption": "none"},
        "streamSettings": st,
        "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic", "fakedns"], "routeOnly": True},
    })
    meta[tag] = {"pbk": pub, "pqv": pq_verify}
    q = [f"type={'xhttp' if is_xhttp else 'tcp'}", "encryption=none", "security=reality", f"pbk={pub}", "fp=chrome", f"sni={sni}", f"sid={sid}", "spx=%2F"]
    if is_xhttp: q += ["path=%2Fvless-xhttp", "mode=auto"]
    else: q.append("flow=xtls-rprx-vision")
    if pq_verify: q.append(f"pqv={pq_verify}")
    share_link = f"vless://{uid}@{server_ip}:{port}?{'&'.join(q)}#{urllib.parse.quote(tag)}"
elif mode == "2":
    uid = str(uuid.uuid4())
    tag = f"vless-cf-xhttp-{port}"
    inbounds.append({
        "tag": tag, "listen": "0.0.0.0", "port": port, "protocol": "vless",
        "settings": {"clients": [{"id": uid, "email": f"cf-{port}"}], "decryption": "none"},
        "streamSettings": {
            "network": "xhttp", "security": "tls",
            "xhttpSettings": {"path": "/vless-xhttp", "mode": "auto"},
            "tlsSettings": {"certificates": [{"certificateFile": "/usr/local/etc/xray/cf.crt", "keyFile": "/usr/local/etc/xray/cf.key"}]},
            "sockopt": {"trustedXForwardedFor": ["CF-Connecting-IP", "X-Forwarded-For"], "tcpKeepAliveIdle": 120, "tcpKeepAliveInterval": 20},
        },
        "sniffing": {"enabled": True, "destOverride": ["http", "tls", "quic", "fakedns"], "routeOnly": True},
    })
    meta[tag] = {"host": cf_domain}
    share_link = f"vless://{uid}@{cf_domain}:{port}?type=xhttp&path=%2Fvless-xhttp&mode=auto&encryption=none&security=tls&sni={cf_domain}&host={cf_domain}#{urllib.parse.quote(tag)}"

if relay_on and res_ip and res_port and res_pass:
    ob_tag = f"out-res-{tag}"
    outbounds = [x for x in outbounds if x.get("tag") != ob_tag]
    outbounds.append({
        "tag": ob_tag, "protocol": "shadowsocks",
        "settings": {"servers": [{"address": res_ip, "port": int(res_port), "method": "2022-blake3-aes-256-gcm", "password": res_pass}]},
    })
    custom_rules = [r for r in custom_rules if r.get("inboundTag") != [tag]]
    custom_rules.append({"type": "field", "inboundTag": [tag], "outboundTag": ob_tag})

cfg["inbounds"] = inbounds
cfg["outbounds"] = outbounds
cfg["routing"] = {
    "domainStrategy": "IPOnDemand",
    "rules": [
        {"type": "field", "outboundTag": "blocked", "ip": ["geoip:private"]},
        {"type": "field", "outboundTag": "blocked", "protocol": ["bittorrent"]},
        {"type": "field", "outboundTag": "blocked", "port": "25"},
        {"type": "field", "outboundTag": "blocked", "ip": ["geoip:cn"]},
    ] + custom_rules,
}

tmp_cfg = cfg_path + ".new"
with open(tmp_cfg, "w", encoding="utf-8") as f:
    json.dump(cfg, f, indent=2, ensure_ascii=False)
subprocess.check_call([xray_bin, "run", "-test", "-config", tmp_cfg])
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
    cat << EOF > /etc/nftables.d/res-whitelist.nft
table inet res_guard
delete table inet res_guard
table inet res_guard {
    chain input {
        type filter hook input priority filter; policy accept;
        iifname "lo" accept
        ct state established,related accept
        tcp dport ${LISTEN_PORT} ip saddr ${RES_WHITELIST_IP} accept
        udp dport ${LISTEN_PORT} ip saddr ${RES_WHITELIST_IP} accept
        tcp dport ${LISTEN_PORT} drop
        udp dport ${LISTEN_PORT} drop
    }
}
EOF
    nft -f /etc/nftables.d/res-whitelist.nft
    echo "  [白名单] 端口 ${LISTEN_PORT} 已锁定仅放行前置机 ${RES_WHITELIST_IP}"
fi

systemctl enable --now xray
systemctl restart xray
sleep 1
systemctl is-active --quiet xray && echo "[成功] 纯原生 Xray-core 已通过 xray run -test 并正常运行！"
echo "  配置文件路径: ${XRAY_CFG}（随时可直接手改 JSON）"
echo "  只读查看节点: bash <(curl -fsSL https://raw.githubusercontent.com/CatEacc/vps-xray-runbook/main/pure.sh) 4"
