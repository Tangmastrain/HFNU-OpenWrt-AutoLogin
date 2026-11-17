#!/bin/sh
# ============================================================================
#  合肥师范学院(HFNU) 校园网自动登录脚本  ——  v3.0 新版 ePortal 接口
#  门户: 华为 ePortal + ME60 AC (认证服务器 192.168.1.100:801)
#  2026-11-16 认证页改版适配: 旧 POST /eportal/?c=ACSetting&a=Login 已停用,
#  现走 GET /eportal/portal/login|logout (JSONP, dr1003/dr1004 回调), 密码明文直传。
#  适用: OpenWrt / busybox ash
# ----------------------------------------------------------------------------
#    sh campus-login.sh            检测 + 登录(日常调用)
#    sh campus-login.sh debug      详细诊断(第一次务必跑这个)
#    sh campus-login.sh logout     强制下线(账号卡在别处时用)
#    sh campus-login.sh status     查看是否已联网
#    sh campus-login.sh install    安装: 开机自启 + 定时任务
#    sh campus-login.sh uninstall  卸载
# ============================================================================

#####################  配置区(只需要改这里)  #####################
PORTAL="192.168.1.100"          # 认证门户 IP
EPORT="801"                     # eportal 端口
USERNAME="YOUR_STUDENT_ID"            # <<< 校园网账号(学号/校园卡号)
PASSWORD="YOUR_PASSWORD"               # <<< 校园网密码
ISP_SUFFIX="campus"             # 运营商后缀: campus/telecom/unicom/cmcc;账号自带@时留空即可
WLANACNAME="me60"               # AC 名称(探测不到劫持参数时的回退值)
WLANACIP="172.16.254.6"         # AC IP  (同上,回退值)
MAC="000000000000"              # 新版认证页抓包为全 0;探测到真实 MAC 时会自动透传
WAN_IP=""                       # 留空 = 自动探测 WAN 口 IP
CHECK_HOSTS="223.5.5.5 119.29.29.29 114.114.114.114"
CHECK_URL="http://connect.rom.miui.com/generate_204"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/157.0.0.0 Safari/537.36 Edg/157.0.0.0"
LOG_TAG="campus-login"
PORTAL_PROGRAM="201706081423"   # 认证页 Cookie program 固定值(抓包实证)
#####################  配置区结束  #####################

SELF="$0"
TMPB="/tmp/campus_login.body"
log() { logger -t "$LOG_TAG" "$*"; echo "[$(date '+%m-%d %H:%M:%S')] $*"; }

# 从 URL/文本里取查询参数(新旧两种命名都支持)
qget() { printf '%s' "$1" | sed -n "s/.*[?&]$2=\([^&\"']*\).*/\1/p" | head -n 1; }

# ---------------------------------------------------------------------------
# 取本机 WAN 口在校园网的 IP —— 探测不到劫持参数时的 wlanuserip 回退值
# ---------------------------------------------------------------------------
get_wan_ip() {
    if [ -n "$WAN_IP" ]; then echo "$WAN_IP"; return; fi
    ip=""
    if command -v jsonfilter >/dev/null 2>&1; then
        for i in wan wwan wan_6 wan6; do
            ip=$(ifstatus "$i" 2>/dev/null | jsonfilter -e '@["ipv4-address"][0]["address"]' 2>/dev/null)
            [ -n "$ip" ] && [ "$ip" != "0.0.0.0" ] && { echo "$ip"; return; }
        done
    fi
    if command -v ip >/dev/null 2>&1; then
        ip=$(ip route get "$PORTAL" 2>/dev/null | sed -n 's/.* src \([0-9][0-9.]*\).*/\1/p')
        [ -n "$ip" ] || ip=$(ip route get 223.5.5.5 2>/dev/null | sed -n 's/.* src \([0-9][0-9.]*\).*/\1/p')
        [ -n "$ip" ] && [ "$ip" != "127.0.0.1" ] && { echo "$ip"; return; }
    fi
    ip=$(ifconfig 2>/dev/null | sed -n 's/.*inet addr:\([0-9][0-9.]*\).*/\1/p' | grep -v '^192\.168\.' | head -n 1)
    echo "$ip"
}

is_online() {
    for h in $CHECK_HOSTS; do
        ping -c 1 -W 2 "$h" >/dev/null 2>&1 && return 0
    done
    code=$(curl -s -o /dev/null -m 6 -w '%{http_code}' "$CHECK_URL" 2>/dev/null)
    [ "$code" = "204" ] && return 0
    return 1
}

# ---------------------------------------------------------------------------
# 动态参数探测: 未认证时访问任意外网会被 AC 302 劫持到 Portal 页,
# 从 Location 里提取 wlan_user_ip / wlan_ac_ip / wlan_ac_name / mac。
# 劫持 Location 可能是旧命名(wlanuserip)或新命名(wlan_user_ip),两者都兼容。
# 绝不能写死。探测结果写入全局变量 D_IP / D_ACIP / D_ACNAME / D_MAC。
# ---------------------------------------------------------------------------
discover() {
    D_IP=""; D_ACIP=""; D_ACNAME=""; D_MAC=""
    for u in http://connect.rom.miui.com/generate_204 \
             http://www.msftconnecttest.com/connecttest.txt \
             http://www.baidu.com/; do
        loc=$(curl -s -o /dev/null -m 5 -w '%{redirect_url}' "$u" 2>/dev/null)
        case "$loc" in
            *wlan_user_ip=*|*wlanuserip=*)
                D_IP=$(qget "$loc" 'wlan_user_ip');  [ -z "$D_IP" ]    && D_IP=$(qget "$loc" 'wlanuserip')
                D_ACIP=$(qget "$loc" 'wlan_ac_ip');  [ -z "$D_ACIP" ]  && D_ACIP=$(qget "$loc" 'wlanacip')
                D_ACNAME=$(qget "$loc" 'wlan_ac_name'); [ -z "$D_ACNAME" ] && D_ACNAME=$(qget "$loc" 'wlanacname')
                D_MAC=$(qget "$loc" 'wlan_user_mac'); [ -z "$D_MAC" ]  && D_MAC=$(qget "$loc" 'mac')
                return 0 ;;
        esac
    done
    return 1
}

# 统一 MAC 形态: 去掉 - 与 : 分隔符
norm_mac() { printf '%s' "$1" | tr -d ':-'; }

# 组装新版接口的 user_account: 固定为「,0,账号@运营商」
build_account() {
    case "$USERNAME" in
        *@*) printf '%s' "$USERNAME" ;;
        *)   [ -n "$ISP_SUFFIX" ] && printf '%s@%s' "$USERNAME" "$ISP_SUFFIX" || printf '%s' "$USERNAME" ;;
    esac
}

# ---------------------------------------------------------------------------
# 发登录请求: GET /eportal/portal/login (JSONP, dr1003), 与新版认证页抓包逐字一致。
# user_password 为密码原文,无需加密; v 为缓存穿透随机值,服务端不校验。
# 响应体写进 $TMPB 并回显(UTF-8 JSONP: dr1003({"result":..,"msg":"..","ret_code":..}))
# ---------------------------------------------------------------------------
do_login() {
    _ip="$1"; _mac="$2"; _acip="$3"; _acname="$4"
    [ -z "$_ip" ] && _ip="0.0.0.0"
    [ -z "$_mac" ] && _mac="$MAC"
    [ -z "$_acip" ] && _acip="$WLANACIP"
    [ -z "$_acname" ] && _acname="$WLANACNAME"
    _ua=$(build_account)

    # Cookie 字段名叫 md5_login2,实际是「用户名|密码」明文拼接,| URL 编码为 %7C
    _md5login=$(printf '%s|%s' "$USERNAME" "$PASSWORD" | sed 's/|/%7C/g; s/@/%40/g')
    _v=$(($$ % 9000 + 1000))

    curl -s -m 15 \
        -A "$UA" \
        -H 'Accept: */*' \
        -H 'Accept-Language: zh-CN,zh;q=0.9,en;q=0.8' \
        -H "Referer: http://${PORTAL}/" \
        -H "Cookie: program=${PORTAL_PROGRAM}; vlan=0; md5_login2=${_md5login}; ip=${_ip}" \
        -G "http://${PORTAL}:${EPORT}/eportal/portal/login" \
        --data-urlencode "callback=dr1003" \
        --data-urlencode "login_method=1" \
        --data-urlencode "user_account=,0,${_ua}" \
        --data-urlencode "user_password=${PASSWORD}" \
        --data-urlencode "wlan_user_ip=${_ip}" \
        --data-urlencode "wlan_user_ipv6=" \
        --data-urlencode "wlan_user_mac=${_mac}" \
        --data-urlencode "wlan_ac_ip=${_acip}" \
        --data-urlencode "wlan_ac_name=${_acname}" \
        --data-urlencode "jsVersion=4.2.1" \
        --data-urlencode "terminal_type=1" \
        --data-urlencode "lang=zh-cn" \
        --data-urlencode "v=${_v}" \
        --data-urlencode "lang=zh" \
        -o "$TMPB" 2>/dev/null
    cat "$TMPB" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 注销(账号卡在别处时用): GET /eportal/portal/logout (JSONP, dr1004)。
# 关键: user_account/user_password 是认证页注销链接里的固定占位值(drcom/123),
# 服务端靠 wlan_user_ip 定位会话,与登录账号无关 —— 绝不能传真实账号。
# ---------------------------------------------------------------------------
do_logout() {
    discover 2>/dev/null
    _ip="$D_IP"; [ -z "$_ip" ] && _ip=$(get_wan_ip); [ -z "$_ip" ] && _ip="0.0.0.0"
    _acip="$D_ACIP";  [ -z "$_acip" ]  && _acip="$WLANACIP"
    _acname="$D_ACNAME"; [ -z "$_acname" ] && _acname="$WLANACNAME"
    _mac=$(norm_mac "$D_MAC"); [ -z "$_mac" ] && _mac="$MAC"
    _v=$(($$ % 9000 + 1000))

    log "注销: wlan_user_ip=$_ip"
    curl -s -m 15 \
        -A "$UA" \
        -H 'Accept: */*' \
        -H 'Accept-Language: zh-CN,zh;q=0.9,en;q=0.8' \
        -H "Referer: http://${PORTAL}/" \
        -G "http://${PORTAL}:${EPORT}/eportal/portal/logout" \
        --data-urlencode "callback=dr1004" \
        --data-urlencode "login_method=1" \
        --data-urlencode "user_account=drcom" \
        --data-urlencode "user_password=123" \
        --data-urlencode "ac_logout=0" \
        --data-urlencode "register_mode=0" \
        --data-urlencode "wlan_user_ip=${_ip}" \
        --data-urlencode "wlan_user_ipv6=" \
        --data-urlencode "wlan_vlan_id=0" \
        --data-urlencode "wlan_user_mac=${_mac}" \
        --data-urlencode "wlan_ac_ip=${_acip}" \
        --data-urlencode "wlan_ac_name=${_acname}" \
        --data-urlencode "jsVersion=4.2.1" \
        --data-urlencode "v=${_v}" \
        --data-urlencode "lang=zh" \
        -o "$TMPB" 2>/dev/null
    cat "$TMPB" 2>/dev/null
}

# ---------------------------------------------------------------------------
# 结果判定 <<< 新版 JSONP 响应 >>>
#   result=1 登录成功 / result=0 失败(具体原因看 msg,已在线时 ret_code=2)
#   !! 陷阱: msg 里同时可能出现「注销成功」等文案,绝不能只匹配「成功」二字
# 输出: "ok|消息" 或 "fail|消息" 或 "unknown|消息"
# ---------------------------------------------------------------------------
judge() {
    t="$1"
    case "$t" in
        *'"result":1'*|*"'result':1"*|*'"result":"1"'*) echo "ok|登录成功"; return ;;
    esac
    case "$t" in
        *"已经在线"*|*"已在线"*|*"IPalreadyonline"*) echo "ok|IP 已在线,视为成功"; return ;;
    esac

    _msg=$(printf '%s' "$t" | sed -n 's/.*"msg":"\([^"]*\)".*/\1/p' | head -n 1)

    # 失败词表(命中即业务失败,不再重试,防止账号锁定)
    case "$t" in
        *"认证失败"*|*"AC认证失败"*|*"密码错误"*|*"账号或密码"*|*"用户不存在"*|*"已欠费"*|*"用户被锁定"*|*"参数签名失败"*|*"Authentication failure"*|*"Login failed"*)
            echo "fail|${_msg:-认证失败}"; return ;;
    esac

    [ -n "$_msg" ] && echo "unknown|$_msg" || echo "unknown|无法判定(无已知结果码)"
}

# ---------------------------------------------------------------------------
# 诊断模式
# ---------------------------------------------------------------------------
do_debug() {
    echo "=============== 校园网登录诊断(新版 ePortal 接口) ==============="
    wanip=$(get_wan_ip)
    echo "1) 本机 WAN 口 IP(wlan_user_ip 回退值): ${wanip:-探测失败!}"
    echo -n "2) 门户是否可达: "
    pc=$(curl -s -o /dev/null -m 6 -w '%{http_code}' "http://${PORTAL}:${EPORT}/eportal/" 2>/dev/null)
    [ -n "$pc" ] && [ "$pc" != "000" ] && echo "可达(HTTP $pc)" || echo "不可达"
    echo -n "3) 当前联网状态: "
    if is_online; then echo "已联网"; else echo "未联网"; fi

    echo "4) 探测 AC 劫持参数(在线时通常探不到,属正常):"
    if discover; then
        echo "   wlan_user_ip=$D_IP  wlan_ac_ip=$D_ACIP  wlan_ac_name=$D_ACNAME  mac=$D_MAC"
    else
        echo "   未探测到劫持(已联网),将使用回退值"
    fi

    _ip="${D_IP:-$wanip}"; _acip="${D_ACIP:-$WLANACIP}"; _acname="${D_ACNAME:-$WLANACNAME}"; _mac=$(norm_mac "${D_MAC:-$MAC}")
    _ua=$(build_account)
    echo "5) 发送登录请求:"
    echo "   账号: ,0,${_ua}   密码: ${PASSWORD}"
    echo "   参数: wlan_user_ip=${_ip:-?} wlan_ac_ip=${_acip} wlan_ac_name=${_acname} mac=${_mac}"
    resp=$(do_login "$_ip" "$_mac" "$_acip" "$_acname")
    echo "   响应: ${resp:-<空>}"
    echo "6) 判定    : $(judge "$resp")"

    echo -n "7) 复查联网: "
    sleep 2
    if is_online; then echo "已联网"; else echo "仍然未联网"; fi
    echo "=============================================="
}

# ---------------------------------------------------------------------------
# 日常:检测 + 登录
# ---------------------------------------------------------------------------
run_once() {
    if is_online; then log "网络正常,无需登录"; return 0; fi
    log "未联网,开始登录..."
    discover 2>/dev/null
    _ip="$D_IP"; [ -z "$_ip" ] && _ip=$(get_wan_ip)
    _acip="${D_ACIP:-$WLANACIP}"; _acname="${D_ACNAME:-$WLANACNAME}"; _mac=$(norm_mac "${D_MAC:-$MAC}")
    log "  参数: ip=${_ip:-未知} ac_ip=$_acip ac_name=$_acname"
    resp=$(do_login "$_ip" "$_mac" "$_acip" "$_acname")
    r=$(judge "$resp")

    # 门户返回结果只作参考,最终以"能否真的上网"为准
    sleep 2
    if is_online; then
        log "登录成功,联网已恢复(${r#*|})"
        return 0
    fi
    log "登录未生效,联网检测仍然失败"
    log "  门户判定: ${r#*|}"
    [ -n "$resp" ] && log "  响应片段: $(printf '%s' "$resp" | head -c 160)"
}

# ---------------------------------------------------------------------------
# 安装 / 卸载
# ---------------------------------------------------------------------------
do_install() {
    if ! command -v curl >/dev/null 2>&1; then
        log "缺少 curl,请先执行: opkg update && opkg install curl"; return 1
    fi
    if [ "$(readlink -f "$SELF")" != "/etc/campus-login.sh" ]; then
        cp -f "$SELF" /etc/campus-login.sh
    fi
    chmod +x /etc/campus-login.sh
    mkdir -p /etc/hotplug.d/iface
    cat > /etc/hotplug.d/iface/99-campus-login <<'HOTPLUG_EOF'
#!/bin/sh
[ "$ACTION" = "ifup" ] && /etc/campus-login.sh >/dev/null 2>&1 &
HOTPLUG_EOF
    chmod +x /etc/hotplug.d/iface/99-campus-login
    touch /etc/crontabs/root
    sed -i '/campus-login/d' /etc/crontabs/root
    echo "*/3 * * * * /etc/campus-login.sh >/dev/null 2>&1" >> /etc/crontabs/root
    /etc/init.d/cron enable  >/dev/null 2>&1
    /etc/init.d/cron restart >/dev/null 2>&1
    log "安装完成: /etc/campus-login.sh + hotplug + cron(每3分钟)"
    run_once
}

do_uninstall() {
    sed -i '/campus-login/d' /etc/crontabs/root
    rm -f /etc/hotplug.d/iface/99-campus-login /etc/campus-login.sh
    /etc/init.d/cron restart >/dev/null 2>&1
    log "已卸载"
}

case "$1" in
    debug)     do_debug ;;
    logout)    do_logout ;;
    install)   do_install ;;
    uninstall) do_uninstall ;;
    status)    if is_online; then log "当前: 已联网"; else log "当前: 未联网"; fi ;;
    *)         run_once ;;
esac
