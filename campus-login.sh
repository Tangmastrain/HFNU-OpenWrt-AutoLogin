#!/bin/sh
# ============================================================================
#  合肥师范学院(HFNU) 校园网自动登录脚本
#  门户: Dr.COM / 城市热点 eportal + 华为 ME60 AC
#  适用: OpenWrt / LEDE / busybox ash
# ----------------------------------------------------------------------------
#    sh campus-login.sh            检测 + 登录(日常调用)
#    sh campus-login.sh debug      详细诊断(第一次务必跑这个)
#    sh campus-login.sh logout     强制下线(账号卡在别处时用)
#    sh campus-login.sh status     查看是否已联网
#    sh campus-login.sh install    安装: 开机自启 + 定时任务
#    sh campus-login.sh uninstall  卸载
# ----------------------------------------------------------------------------
#   本文件不含任何真实账号密码(全部是占位符)。
#   怎么拿到你自己的登录信息:
#     浏览器打开 http://192.168.1.100 -> F12 -> 网络(Network)
#     -> 勾选"保留日志/Keep log" -> 输入账号密码点登录
#     -> 在请求里右键 locales -> 复制 -> 复制为 cURL (bash)
#     详细步骤见 README 第 3 节。
# ============================================================================

#####################  配置区(只需要改这里)  #####################
PORTAL="192.168.1.100"          # 认证门户 IP
EPORT="801"                     # eportal 端口
USERNAME="YOUR_STUDENT_ID"      # <<< 校园网账号(学号/校园卡号),请改成你自己的
PASSWORD="YOUR_PASSWORD"        # <<< 校园网密码,请改成你自己的
ISP_SUFFIX=""                   # 运营商后缀,一般留空;填了会拼成 账号@后缀
WLANACNAME="me60"               # AC 名称
WLANACIP="172.16.254.6"         # AC IP
RADIUS_IP="172.16.254.2"        # RADIUS 服务器(用于查真实错误原因)
MAC="00-00-00-00-00-00"         # 抓包中为全 0
WAN_IP=""                       # 留空 = 自动探测 WAN 口 IP
CHECK_HOSTS="223.5.5.5 119.29.29.29 114.114.114.114"
CHECK_URL="http://connect.rom.miui.com/generate_204"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/154.0.0.0 Safari/537.36 Edg/154.0.0.0"
LOG_TAG="campus-login"
#####################  配置区结束  #####################

SELF="$0"
TMPB="/tmp/campus_login.body"
log() { logger -t "$LOG_TAG" "$*"; echo "[$(date '+%m-%d %H:%M:%S')] $*"; }

# 去掉数字前导零(busybox 下 $((08)) 会报错)
nz() { _v=$(printf '%s' "$1" | sed 's/^0*//'); [ -z "$_v" ] && _v=0; printf '%s' "$_v"; }

# 从 URL 里取查询参数
qget() { printf '%s' "$1" | sed -n "s/.*[?&]$2=\([^&]*\).*/\1/p"; }

# ---------------------------------------------------------------------------
# 取本机 WAN 口在校园网的 IP —— 也就是 AC 看到的 wlanuserip
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
# 发登录请求,响应体写进 $TMPB,并回显"最终 URL"
# ---------------------------------------------------------------------------
do_login() {
    _ip="$1"; [ -z "$_ip" ] && _ip="0.0.0.0"
    _user="${USERNAME}${ISP_SUFFIX}"

    _url="http://${PORTAL}:${EPORT}/eportal/?c=ACSetting&a=Login&protocol=http:&hostname=${PORTAL}"
    _url="${_url}&iTermType=1&wlanuserip=${_ip}&wlanacip=${WLANACIP}&wlanacname=${WLANACNAME}"
    _url="${_url}&mac=${MAC}&ip=${_ip}&enAdvert=0&queryACIP=0&loginMethod=1"

    _body="DDDDD=${_user}&upass=${PASSWORD}&R1=0&R2=0&R6=0&para=00&0MKKey=123456"
    _body="${_body}&buttonClicked=&redirect_url=&err_flag=&username=&password=&user=&cmd=&Login="

    curl -s -L -m 15 --insecure \
        -A "$UA" \
        -H 'Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8' \
        -H 'Accept-Language: zh-CN,zh;q=0.9,en;q=0.8' \
        -H 'Content-Type: application/x-www-form-urlencoded' \
        -H "Origin: http://${PORTAL}" \
        -H "Referer: http://${PORTAL}/" \
        --data "$_body" \
        -o "$TMPB" -w '%{url_effective}' "$_url" 2>/dev/null
}

# 注销(账号卡在别处时用)
do_logout() {
    _ip=$(get_wan_ip); [ -z "$_ip" ] && _ip="0.0.0.0"
    _url="http://${PORTAL}:${EPORT}/eportal/?c=ACSetting&a=Logout&wlanuserip=${_ip}"
    _url="${_url}&wlanacip=${WLANACIP}&wlanacname=${WLANACNAME}&port=80&hostname=${PORTAL}"
    _url="${_url}&iTermType=1&session=&queryACIP=0&mac=${MAC}"
    log "注销: $_url"
    curl -s -L -m 15 --insecure -A "$UA" -o "$TMPB" -w '最终URL: %{url_effective}\n' "$_url" 2>/dev/null
}

# ---------------------------------------------------------------------------
# RADIUS 真实原因(RadiusErrorAry 表,从门户 a78.js 提取)
# ---------------------------------------------------------------------------
radius_msg() {
    case "$1" in
        *"ErrCode=04"*) echo "在线时长/流量已达上限" ;;
        *"ErrCode=05"*) echo "账号已停机/欠费" ;;
        *"ErrCode=09"*) echo "账号费用超支,禁止使用" ;;
        *"ErrCode=11"*) echo "不允许 Radius 登录" ;;
        *"ErrCode=80"*) echo "接入服务器不存在" ;;
        *"ErrCode=81"*) echo "LDAP 认证失败" ;;
        *"ErrCode=85"*) echo "账号已在线上(重复登录冲突)" ;;
        *"ErrCode=86"*) echo "IP 或 MAC 绑定失败" ;;
        *"ErrCode=88"*) echo "IP 地址冲突" ;;
        *"ErrCode=94"*) echo "并发访问超限" ;;
        *"err(2)"*)     echo "请在指定的登录源地址范围内登录" ;;
        *"err(3)"*)     echo "请在指定的 IP 登录" ;;
        *"err(7)"*)     echo "请在指定的登录源 VLAN 范围内登录" ;;
        *"err(10)"*)    echo "请在指定的 VLAN 登录" ;;
        *"err(11)"*)    echo "请在指定的 MAC 登录" ;;
        *"err(17)"*)    echo "请在指定的设备端口登录" ;;
        *"userid error1"*) echo "账号不存在" ;;
        *"userid error2"*) echo "密码错误" ;;
        *"userid error3"*) echo "密码错误" ;;
        *"auth error4"*)   echo "用户使用数量超限" ;;
        *"auth error5"*)   echo "账号被停用" ;;
        *"auth error9"*)   echo "时长或流量超出" ;;
        *"auth error80"*)  echo "该时段禁止上网" ;;
        *"auth error99"*)  echo "用户名或密码错误" ;;
        *"auth error198"*) echo "用户名或密码错误" ;;
        *"auth error199"*) echo "用户名或密码错误" ;;
        *"auth error258"*) echo "账号只能在指定区域使用" ;;
        *"In use"*)        echo "登录数量超限" ;;
        *"set_onlinet error"*) echo "用户数超限" ;;
        *"Limit Users Err"*)   echo "账号已在线" ;;
        *"can not use static ip"*) echo "不能使用静态 IP" ;;
        *"Oppp error"*)    echo "运营商账号问题(密码错误/已在线/欠费)" ;;
        *) echo "" ;;
    esac
}

# 查询 RADIUS 拿真实原因
query_radius() {
    _txt=$(curl -s -m 6 --insecure "http://${RADIUS_IP}/errcode" 2>/dev/null | tr -d '\r\n')
    if [ -z "$_txt" ]; then
        echo "  RADIUS(${RADIUS_IP}) 无返回 —— 抓包里这个请求也是被阻断的,"
        echo "  所以门户页面只能显示兜底文案「账号或密码不正确」,不一定是真实原因"
        return
    fi
    echo "  RADIUS 原始返回: $_txt"
    _m=$(radius_msg "$_txt")
    [ -n "$_m" ] && echo "  真实原因: $_m" || echo "  未匹配到已知错误码"
}

# ---------------------------------------------------------------------------
# 结果判定 <<< 结果码来自门户自身的 a41.js >>>
#   ACLogOut: 0 BS注册失败 / 1 注册成功 / 2 该IP禁止登陆 / 3 手机已下线
#             4 该IP未加白名单 / 5 自定义ErrorMsg / 6 账号或密码不正确
#   Msg     : 2 账号正在使用中 / 3 只能在指定地址使用 / 5 账号暂停使用
#             7 正常 / 14 注销成功 / 15 >>> 登录成功 <<<
#   ACLogIn : 0 成功 / 1 账号或密码不对 / 2 IP已经在线 / 3 系统忙 ...
# 输出: "ok|消息" 或 "fail|消息" 或 "unknown|消息"
# ---------------------------------------------------------------------------
judge() {
    # 空字符串 = 该参数不存在,不能当成 0 处理
    ao=""; [ -n "$1" ] && ao=$(nz "$1")
    ai=""; [ -n "$2" ] && ai=$(nz "$2")
    mg=""; [ -n "$3" ] && mg=$(nz "$3")
    ma="$4"; em="$5"

    # ---- 成功信号(优先级最高)----
    [ "$mg" = "15" ] && { echo "ok|登录成功(Msg=15)"; return; }
    [ "$mg" = "14" ] && { echo "ok|已注销成功"; return; }
    [ "$ao" = "15" ] && { echo "ok|登录成功(ACLogOut=15)"; return; }
    [ "$ao" = "14" ] && { echo "ok|已注销成功"; return; }

    # ---- ACLogIn 优先于 ACLogOut(与门户 DispTFM 的判断顺序一致)----
    case "$ai" in
        0)  echo "ok|登录成功(ACLogIn=0)"; return ;;
        1)  echo "fail|账号或密码不对"; return ;;
        2)  echo "ok|IP 已经在线,视为成功"; return ;;
        3)  echo "fail|系统忙,请稍后重试"; return ;;
        4)  echo "fail|未知错误"; return ;;
        5)  echo "fail|REQ_CHALLENGE 失败"; return ;;
        6)  echo "fail|REQ_CHALLENGE 超时"; return ;;
        7)  echo "fail|认证失败"; return ;;
        8)  echo "fail|认证超时"; return ;;
        9)  echo "fail|注销失败"; return ;;
        10) echo "fail|注销超时"; return ;;
        11) echo "fail|其他错误"; return ;;
        "") : ;;
        *)  echo "fail|未知 ACLogIn=$ai"; return ;;
    esac

    # ---- ACLogOut ----
    case "$ao" in
        "") : ;;
        0) echo "fail|BS 注册失败"; return ;;
        1) echo "ok|注册成功"; return ;;
        2) echo "fail|该 IP 禁止登录"; return ;;
        3) echo "fail|手机已下线"; return ;;
        4) echo "fail|该 IP 未加入白名单"; return ;;
        5) echo "fail|${em:-门户自定义错误}"; return ;;
        6) echo "fail|账号或密码不正确"; return ;;
        *) echo "fail|未知 ACLogOut=$ao"; return ;;
    esac

    # ---- Msg ----
    case "$mg" in
        0|1)
            case "$ma" in
                "")     echo "fail|账号或密码不正确"; return ;;
                error0) echo "fail|该 IP 不允许 Web 方式登录"; return ;;
                error1) echo "fail|该账号不允许 Web 方式登录"; return ;;
                error2) echo "fail|该账号不允许修改密码"; return ;;
                *)      echo "fail|${ma}"; return ;;
            esac ;;
        2)  echo "fail|该账号正在使用中(很可能已在别处登录)"; return ;;
        3)  echo "fail|该账号只能在指定地址使用"; return ;;
        4)  echo "fail|该账号已超支或时长用完"; return ;;
        5)  echo "fail|该账号已暂停使用"; return ;;
        6)  echo "fail|系统缓存太多,稍后重试"; return ;;
        7)  echo "ok|账号在线"; return ;;
        8)  echo "fail|该账号正在使用中,不能修改"; return ;;
        9)  echo "fail|新密码与确认密码不匹配"; return ;;
        10) echo "ok|密码修改成功"; return ;;
        11) echo "fail|该账号只能在指定地址使用"; return ;;
        "") : ;;
        *)  echo "fail|账号或密码不正确"; return ;;
    esac

    echo "unknown|无法判定(门户未返回已知结果码)"
}

# 从响应体和最终URL里提取所有结果码
collect_codes() {
    _u="$1"
    AO=$(qget "$_u" 'ACLogOut'); AI=$(qget "$_u" 'ACLogIn'); EM=$(qget "$_u" 'ErrorMsg')
    MG=$(grep -o 'Msg=[0-9]*' "$TMPB" 2>/dev/null | head -n 1 | cut -d= -f2)
    MA=$(sed -n "s/.*msga='\([^']*\)'.*/\1/p" "$TMPB" 2>/dev/null | head -n 1)
    MK=$(grep -o 'Dr\.COMWebLoginID_[0-9]*\.htm' "$TMPB" 2>/dev/null | head -n 1)
    [ -z "$MG" ] && MG=0
}

# ---------------------------------------------------------------------------
# 诊断模式
# ---------------------------------------------------------------------------
do_debug() {
    echo "=============== 校园网登录诊断 ==============="
    ip=$(get_wan_ip)
    echo "1) 本机 WAN 口 IP(wlanuserip): ${ip:-探测失败!}"
    echo -n "2) 门户是否可达: "
    pc=$(curl -s -o /dev/null -m 6 -w '%{http_code}' "http://${PORTAL}:${EPORT}/eportal/" 2>/dev/null)
    [ -n "$pc" ] && [ "$pc" != "000" ] && echo "可达(HTTP $pc)" || echo "不可达"
    echo -n "3) 当前联网状态: "
    if is_online; then echo "已联网"; else echo "未联网"; fi

    echo "4) 发送登录请求..."
    echo "   账号: ${USERNAME}${ISP_SUFFIX}   密码: ********(已隐藏)"
    u=$(do_login "$ip")
    echo "   最终URL: $u"

    collect_codes "$u"
    echo "   页面标记 : ${MK:-无}"
    echo "   ACLogOut=${AO:-无}  ACLogIn=${AI:-无}  Msg=${MG:-无}  msga='${MA}'  ErrorMsg=${EM:-无}"
    echo "5) 判定    : $(judge "$AO" "$AI" "$MG" "$MA" "$EM")"
    echo "6) 查 RADIUS 真实原因:"
    query_radius

    echo -n "7) 复查联网: "
    sleep 2
    if is_online; then echo "已恢复联网"; else echo "仍然未联网"; fi
    echo "=============================================="
}

# ---------------------------------------------------------------------------
# 日常:检测 + 登录
# ---------------------------------------------------------------------------
run_once() {
    if is_online; then log "网络正常,无需登录"; return 0; fi
    ip=$(get_wan_ip)
    log "未联网,本机 WAN IP = ${ip:-未知},开始登录..."
    u=$(do_login "$ip")
    collect_codes "$u"
    r=$(judge "$AO" "$AI" "$MG" "$MA" "$EM")

    # 门户返回的结果码只作参考,最终以"能否真的上网"为准
    sleep 2
    if is_online; then
        log "登录成功,联网已恢复(门户判定: ${r#*|})"
        return 0
    fi

    log "登录未生效,联网检测仍然失败"
    log "  页面标记 ${MK:-无} | ACLogOut=${AO:-无} ACLogIn=${AI:-无} Msg=${MG:-无} msga='${MA}'"
    log "  门户结果码解读: ${r#*|}"
    _rx=$(radius_msg "$(curl -s -m 6 --insecure "http://${RADIUS_IP}/errcode" 2>/dev/null | tr -d '\r\n')")
    if [ -n "$_rx" ]; then
        log "  RADIUS 实际原因: $_rx"
    else
        log "  RADIUS(${RADIUS_IP}) 查不到原因,门户页面只能显示兜底文案,不一定是真的密码错"
    fi
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
[ "$ACTION" = "ifup" ] && [ "$INTERFACE" = "wan" ] && /etc/campus-login.sh >/dev/null 2>&1 &
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
