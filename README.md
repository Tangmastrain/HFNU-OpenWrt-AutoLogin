# 合肥师范学院 HFNU 路由器 OpenWrt 自动连接教程

给**合肥师范学院**（HFNU）校园网做一条"路由器自己登录"的自动化链路。

刷了 OpenWrt 的路由器接上校园网后，只要开机或掉线，脚本会自动向校园网门户（华为 ePortal，前端由 Dr.COM / 城市热点方案提供）提交认证请求，**不需要再打开浏览器点登录**。适合宿舍路由器、随身 Wi-Fi、树莓派软路由等场景。

> 已实测环境：小米路由器 4A 千兆版（MT7621AT + MT7603EN + MT7612EN），OpenWrt 25.12-SNAPSHOT，busybox ash。
> 理论上所有能跑 shell + curl 的 OpenWrt / LEDE 设备都能用。
>
> ⚠️ **2026-11-16 认证页改版**：登录/注销接口由旧 `?c=ACSetting&a=Login|Logout`（POST 表单）
> 切换为新 `eportal/portal/login|logout`（GET + JSONP）。本仓库脚本已全面适配新版接口，
> 旧版脚本请拉取历史提交（`git log --oneline` 找改版前的 commit）。

---

## 目录

- [1. 适用环境与前提](#1-适用环境与前提)
- [2. 原理：HFNU 校园网认证是怎么走的](#2-原理hfnu-校园网认证是怎么走的)
- [3. ⭐ 获取你自己的登录请求（F12 抓包）](#3--获取你自己的登录请求f12-抓包)
- [4. 快速开始（三步搞定）](#4-快速开始三步搞定)
- [5. 配置项详解](#5-配置项详解)
- [6. 命令行用法](#6-命令行用法)
- [7. 它会自己跑起来吗？](#7-它会自己跑起来吗)
- [8. 常见问题与排查](#8-常见问题与排查)
- [9. 附录：新版接口响应格式](#9-附录新版接口响应格式)
- [10. 免责声明](#10-免责声明)

---

## 1. 适用环境与前提

| 项目 | 要求 |
| --- | --- |
| 设备 | 已刷 OpenWrt / LEDE 的路由器或软路由（本教程基于小米路由器 4A 千兆版） |
| 系统 | OpenWrt 21.02 及以上（开发版快照亦可），`busybox ash` 环境 |
| 依赖 | `curl`（**必须**），可选 `jsonfilter`（OpenWrt 自带，用来更准确地探测 WAN IP） |
| 网络 | 路由器 WAN 口接校园网墙口，能访问 `192.168.1.100` 门户 |
| 账号 | 你的学号 / 教师校园卡号 + 密码（初始密码一般为身份证后六位） |

装 curl（包管理器可能是 `opkg` 或新版的 `apk`，两个都试一下）：

```sh
# 老版本 OpenWrt
opkg update && opkg install curl

# 25.12 等已迁移到 Alpine apk 的版本
apk update && apk add curl
```

把脚本传到路由器（**注意加 `-O`**，新版 scp 默认走 SFTP，而 dropbear 没有 sftp-server）：

```sh
scp -O campus-login.sh root@192.168.11.1:/tmp/
```

> 默认路由器地址请按你自己的改（常见 192.168.1.1 / 192.168.11.1 / 192.168.31.1）。

---

## 2. 原理：HFNU 校园网认证是怎么走的

### 2.1 网络结构

HFNU 校园网是典型的 **华为 ME60 宽带接入服务器（BRAS）+ ePortal Web Portal**（认证页前端由 Dr.COM / 城市热点方案提供）组合：

```
你的设备 ──► OpenWrt 路由器 ──► 校园网墙口
                                    │
                          ┌─────────┴──────────┐
                          ▼                    ▼
              eportal 门户 (认证页面)      华为 ME60 (AC)
              http://192.168.1.100:801     wlanacname=me60
                                          wlanacip=172.16.254.6
```

- 未认证时，任何上网流量都会被 AC **302 劫持**到 `http://192.168.1.100` 的登录页，劫持 URL 里就带着 `wlan_user_ip`、`wlan_ac_ip`、`wlan_ac_name` 等动态参数。
- 登录页是一段 JavaScript，最后由浏览器发一条 **GET 请求**到 `/eportal/portal/login`，响应是 JSONP。
- 门户把请求转发给 ME60，ME60 再做真正的账号校验。
- 所以：**我们只要复现这一次 GET，就等于手动点了登录按钮。**

### 2.2 登录请求长什么样（2026-11-16 新版）

用浏览器 F12（网络面板）抓包，把登录那一条复制成 `curl`，就能看到核心请求：

**请求地址**（GET + JSONP，`dr1003` 是回调函数名）：

```
http://192.168.1.100:801/eportal/portal/login
    ?callback=dr1003&login_method=1
    &user_account=%2C0%2C<账号>%40<运营商后缀>     ← 即 ",0,学号@telecom"
    &user_password=<密码明文>
    &wlan_user_ip=<本机在校园网的IP>&wlan_user_ipv6=
    &wlan_user_mac=000000000000
    &wlan_ac_ip=172.16.254.6&wlan_ac_name=me60
    &jsVersion=4.2.1&terminal_type=1&lang=zh-cn&v=<随机数>&lang=zh
```

**请求头**（认证页登录时带上的 Cookie，脚本已复现）：

```
Cookie: program=201706081423; vlan=0;
        md5_login2=<账号>%7C<密码>;   ← 字段名叫 md5_login2，实际是「账号|密码」明文拼接
        ip=<本机在校园网的IP>
Referer: http://192.168.1.100/
```

几个关键点：

- **账号格式是 `,0,学号@运营商`**，前面的 `,0,` 是固定前缀（JSONP 抓包实证），别漏。
- `user_password` 就是密码**原文**，无需任何加密。
- `wlan_user_ip` 必须是**路由器 WAN 口拿到的那个校园网 IP**，不是 LAN 侧地址。填错会认证失败。脚本会先尝试从未认证劫持跳转里动态提取，失败再回退到自动探测的 WAN IP。
- `wlan_user_mac` 新版认证页直接传全 0（`000000000000`），保持默认即可。
- `v` 是缓存穿透随机值，服务端不校验。
- 响应是 **UTF-8 JSONP**，形如：`dr1003({"result":1,"msg":"登录成功",...})`，详见[附录](#9-附录新版接口响应格式)。

### 2.3 失败原因怎么看？

新版接口的 JSONP 响应里直接带了 `msg` 字段，是服务端返回的真实原因（如「IP: x.x.x.x 已经在线！」「账号或密码错误」），比旧版「页面显示假原因、要去 RADIUS 查真因」友好得多。

脚本判定逻辑（见 `judge` 函数）：

1. `result=1` → 登录成功；
2. `msg` 含「已经在线」→ 视为成功（IP 本来就是自己的）；
3. `msg` 命中失败词表（密码错误 / 欠费 / 账号锁定等）→ 业务失败，**不重试**（防止账号被锁）；
4. 无法判定 → 以「能不能真的上网」作最终判据。

---

## 3. ⭐ 获取你自己的登录请求（F12 抓包）

> **这一步是整个教程里最关键的一步，一定要做。**
>
> 本仓库里**没有任何人的账号、密码或会话信息**——`campus-login.sh` 的 `USERNAME` / `PASSWORD` 是占位符，必须换成你自己的。
>
> 而"你自己的那条登录请求"**必须从浏览器里现抓**：门户参数（`wlan_ac_ip`、`wlan_ac_name`、运营商后缀等）会因楼栋、区域、办理的宽带而不同，直接用别人的值很可能登不上。

### 3.1 操作步骤（照着做就行）

1. **让设备处于"未登录"状态**：断开门户认证 / 重启路由器 WAN 口，或者直接用一台没认证过的电脑接墙口。
2. **打开认证门户**：浏览器访问 **`http://192.168.1.100`**
   - 如果打不开，随便访问一个 `http://` 网站（比如 `http://neverssl.com`），未认证时会被自动劫持到 `192.168.1.100` 登录页。
3. **按 `F12`** 打开开发者工具（或右键页面 → 「检查 / Inspect」）。
4. **切换到「网络 / Network」面板**。
   - 如果面板里空空如也，先按 **`F5` 刷新**登录页再继续。
5. **勾选「保留日志 / Preserve log」（在 Edge 里显示为 `Keep log`）**。
   - ⚠️ **这一步千万别跳过**。登录成功会触发页面跳转，不勾选的话请求列表会被自动清空，你什么都抓不到。
6. **在页面上输入账号和密码，点击登录**。
7. 在请求列表里找到名为 **`login`** 的那条请求（URL 以
   `/eportal/portal/login?callback=dr1003&...` 开头）。
   - 找不到就在筛选框里输入 `portal/login` 过滤一下。
8. **右键它 → 「复制」→「复制为 cURL (bash)」**
   （Copy → Copy as cURL (bash)）。

到这一步，你的登录请求就已经落到剪贴板里了。

### 3.2 从复制出来的内容里提取配置

复制到的命令大概长这样（**下面全是脱敏后的样子**）：

```bash
curl 'http://192.168.1.100:801/eportal/portal/login?callback=dr1003&login_method=1&user_account=%2C0%2C<你的账号>%40telecom&user_password=<你的密码>&wlan_user_ip=10.x.x.x&wlan_user_ipv6=&wlan_user_mac=000000000000&wlan_ac_ip=172.16.254.6&wlan_ac_name=me60&jsVersion=4.2.1&terminal_type=1&lang=zh-cn&v=3258&lang=zh' \
  -H 'Referer: http://192.168.1.100/' \
  -b 'program=201706081423; vlan=0; md5_login2=<你的账号>%7C<你的密码>; ip=10.x.x.x'
```

对着它填脚本配置区：

| 复制结果里的位置 | 填到脚本变量 | 说明 |
| --- | --- | --- |
| `--url` 里的 `192.168.1.100` | `PORTAL` | 门户 IP，HFNU 一般固定 |
| `--url` 里的 `:801` | `EPORT` | eportal 端口 |
| `--url` 里的 `user_account=%2C0%2C<账号>%40<后缀>` | `USERNAME` + `ISP_SUFFIX` | **你的账号**（去掉 `,0,` 前缀）和**运营商后缀**（`telecom` / `unicom` / `cmcc`） |
| `--url` 里的 `user_password=` | `PASSWORD` | **你的密码**（原文） |
| `--url` 里的 `wlan_ac_ip=` | `WLANACIP` | ME60 的 AC IP |
| `--url` 里的 `wlan_ac_name=` | `WLANACNAME` | ME60 的 AC 名称 |
| `--url` 里的 `wlan_user_ip=` / `-b` 里的 `ip=` | 不用填 | 那台抓包机器的 IP，脚本会自动探测路由器自己的 WAN IP |

> **重点提醒**：
> 1. 如果你抓到的 `wlan_ac_ip` / `wlan_ac_name` 和脚本默认值（`172.16.254.6` / `me60`）**不一致**，请以你抓到的为准改掉——这正是"必须自己抓一次"的原因。
> 2. 账号本身已带 `@`（如 `abc@xyz`）时，把完整账号填进 `USERNAME` 并把 `ISP_SUFFIX` 留空，脚本不会重复追加后缀。

### 3.3 安全提醒：别把你的登录信息贴出去

复制出来的命令里，这些内容是**你的凭据，不要发到任何公开的地方**（QQ 群、issue、贴吧、GitHub）：

- `user_account=...` / `user_password=...` —— 你的账号密码原文
- `-b '... md5_login2=...'` —— 你的账号密码（URL 编码后的拼接）
- `-b '... ip=...'` —— 你当时在校园网的 IP

**本脚本会自己生成这些 Cookie 和参数**，你只需要在配置区填账号、密码、运营商后缀三个值。发帖求助前记得把抓包内容打码。

---

## 4. 快速开始（三步搞定）

### 第一步：改账号密码

打开 `campus-login.sh`，只改配置区这两行：

```sh
USERNAME="YOUR_STUDENT_ID"      # 换成你的学号 / 校园卡号
PASSWORD="YOUR_PASSWORD"        # 换成你的密码
```

用的是电信/联通/移动校园宽带的话，确认 `ISP_SUFFIX`（默认 `telecom`，电信）。其他运营商改成 `unicom` / `cmcc`；普通校园网账号（不带运营商出口）留空。

如果第 3 步抓包里看到的 `wlan_ac_ip` / `wlan_ac_name` 和默认值不同，顺手一起改掉。

### 第二步：先跑一次诊断

第一次**务必**先跑诊断模式，它会打印全部中间结果，一眼看出问题出在哪：

```sh
sh /tmp/campus-login.sh debug
```

正常的话最后几行长这样：

```
5) 发送登录请求:
   账号: ,0,你的学号@telecom   密码: ******
   参数: wlan_user_ip=10.x.x.x wlan_ac_ip=172.16.254.6 wlan_ac_name=me60 mac=000000000000
   响应: dr1003({"result":1,"msg":"登录成功",...});
6) 判定    : ok|登录成功
7) 复查联网: 已联网
```

### 第三步：安装（开机自启 + 每 3 分钟自动重连）

```sh
sh /tmp/campus-login.sh install
```

安装脚本会做四件事：

1. 把自己复制到 `/etc/campus-login.sh` 并加可执行权限；
2. 写入 `/etc/hotplug.d/iface/99-campus-login`——**WAN 口一拨上号就立刻登录**；
3. 往 `/etc/crontabs/root` 加一条 `*/3 * * * *`——**每 3 分钟检测一次，掉线自动重登**；
4. 启动 cron 并立刻尝试登录一次。

卸载：

```sh
/etc/campus-login.sh uninstall
```

---

## 5. 配置项详解

配置区都在脚本开头，**只需要动这几行**：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `USERNAME` | `YOUR_STUDENT_ID` | **必改**。学号 / 校园卡号（账号自带 `@` 时填完整账号） |
| `PASSWORD` | `YOUR_PASSWORD` | **必改**。校园网密码（明文提交，接口要求如此） |
| `ISP_SUFFIX` | `telecom` | 运营商后缀，拼成 `账号@后缀`。HFNU 常见：校园出口 `campus` / 电信 `telecom` / 联通 `unicom` / 移动 `cmcc`（**以你 F12 抓包里 `user_account=%40` 后面为准**）；账号自带 `@` 或无运营商出口时留空 |
| `PORTAL` | `192.168.1.100` | 认证门户 IP，一般不用改 |
| `EPORT` | `801` | 门户 eportal 端口 |
| `WLANACNAME` | `me60` | ME60 的 AC 名称（探测不到劫持参数时的回退值） |
| `WLANACIP` | `172.16.254.6` | ME60 的 AC IP（同上，回退值） |
| `MAC` | `000000000000` | 新版认证页抓包就是全 0，保持默认即可 |
| `WAN_IP` | 空 | **留空 = 自动探测**。填了就用你指定的（多拨/VLAN 例外情况才需要） |
| `CHECK_HOSTS` | `223.5.5.5 119.29.29.29 114.114.114.114` | 联网检测用的 ping 目标 |
| `CHECK_URL` | `http://connect.rom.miui.com/generate_204` | 联网检测用的 HTTP 探测（返回 204 即通） |

**关于动态参数探测**：未认证时脚本会先访问探测地址（miui generate_204 / msftconnecttest / 百度），从 AC 的 302 劫持 Location 里提取 `wlan_user_ip`、`wlan_ac_ip`、`wlan_ac_name`、`mac`（新旧参数命名都兼容）。已联网时探不到劫持属正常，此时回退到 WAN IP 自动探测和配置区默认值。

**关于 WAN IP 自动探测**（探测不到劫持参数时的 `wlan_user_ip` 回退值）：

1. `jsonfilter` 读 `ifstatus wan / wwan / wan_6 / wan6` 的 IPv4 地址（OpenWrt 最准的方式）；
2. `ip route get <门户IP>` 拿到出口源地址；
3. `ifconfig` 里挑第一个非 `192.168.x.x` 的地址兜底。

---

## 6. 命令行用法

```sh
sh campus-login.sh             # 默认：检测，没联网就登录（给 cron / hotplug 调用）
sh campus-login.sh debug       # 详细诊断，第一次一定要跑
sh campus-login.sh status      # 只看当前是否已联网
sh campus-login.sh logout      # 强制下线（账号卡在别的设备上时用）
sh campus-login.sh install     # 安装：开机自启 + 定时检测
sh campus-login.sh uninstall   # 卸载
```

脚本还会把日志写进系统日志（`logread | grep campus-login` 可以查看）：

```sh
logread -e campus-login
```

---

## 7. 它会自己跑起来吗？

会。两套机制互为补充：

- **hotplug（事件触发）**：WAN 口 `ifup` 时立即执行一次。适合"路由器刚开机 / 重新拨号"的场景。
- **cron（轮询兜底）**：每 3 分钟检测一次，不通就重登。适合"被踢下线 / 门户会话过期"的场景。

判断逻辑是**以"能不能真的上网"为准**，而不是只看门户返回的结果码：

```
is_online?  ──是──►  什么都不做
     │
     否
     ▼
302 劫持探测动态参数 → GET portal/login → 等 2 秒 → 复查 is_online
     │
     否 ──►  打印门户判定结果 + JSONP msg（写日志）
```

这样即使门户返回了看不懂的结果码，只要网络恢复了就算成功，不会被误判。

---

## 8. 常见问题与排查

### Q1：登录失败，怎么知道真实原因？

先跑 `sh campus-login.sh debug`，看第 6 步判定和响应里的 `msg` 字段——新版接口会直接返回真实原因（密码错误 / 已欠费 / 账号锁定等），不用再像旧版那样去 RADIUS 查错误码。

常见失败原因与处理：

- `账号或密码错误` —— 确认 `USERNAME` / `PASSWORD` / `ISP_SUFFIX` 填对（尤其 `,0,` 前缀和 `@telecom` 后缀是脚本拼的，不要把整串 `,0,xxx@telecom` 都填进 `USERNAME`）；
- `IP 已经在线` —— 脚本视为成功，不用管；
- `已欠费` / `账号被锁定` —— 去学校自助服务页面处理。

### Q2：登录成功但一会儿又掉线

校园网门户通常有**心跳/在线时长限制**，或者检测到"一个账号多设备在线"会强制踢掉。默认每 3 分钟的 cron 会自动重登。
如果还是频繁掉，可以把 cron 间隔改成 1 分钟：

```sh
sed -i 's#\*/3 \* \* \* \*#*/1 * * * *#' /etc/crontabs/root && /etc/init.d/cron restart
```

### Q3：账号卡在别处登录不上

```sh
/etc/campus-login.sh logout
```

新版注销接口用固定占位账号（`drcom/123`）+ 你的 IP 定位会话，脚本已处理，直接跑就行。然后等 1~2 分钟再登录。或者去学校自助服务页面（HFNU 是 `http://192.168.12.67:8080/Self`）手动下线其他设备。

### Q4：`opkg: not found`

新版 OpenWrt（25.12 等）已经用 Alpine 的 `apk` 取代了 `opkg`：

```sh
apk update && apk add curl
```

### Q5：`scp` 报 `ash: /usr/libexec/sftp-server: not found`

系统 scp 太新，默认用 SFTP 协议，而 OpenWrt 的 dropbear 不带 sftp-server。加 `-O` 强制走老协议：

```sh
scp -O campus-login.sh root@192.168.11.1:/tmp/
```

（没有 scp 的话，也可以用 PuTTY：`plink -ssh root@路由器IP "cat > /tmp/campus-login.sh" < campus-login.sh`）

### Q6：F12 抓不到 `login` 请求

- 确认已经勾选 **「保留日志 / Keep log」**，否则登录跳转后列表会被清空。
- 先在 Network 面板打开的状态下**刷新一次登录页**，再输入账号密码。
- 筛选框输入 `portal/login`，找 `callback=dr1003` 那条。
- 用 Chrome / Edge 的"复制为 cURL (bash)"；Firefox 用"复制 → 复制为 cURL"。

### Q7：路由器 LAN 口协商只有 100 Mbps，无线却有 300+ Mbps

和本脚本无关，是硬件/链路层问题。排查顺序：

1. 看各口协商速率：`cat /sys/class/net/*/speed`
2. 看系统版本：`cat /etc/openwrt_release`
3. 把 WAN 口那根**已验证千兆**的网线插到 LAN 口交叉验证，区分"网线/对端问题"和"设备口故障"。

已知案例（小米路由器 4A 千兆版，OpenWrt 21.02.x）存在 mt7530 交换机链路自动协商异常的 bug（[FS#3681](https://bugs.openwrt.org/index.php?do=details&task_id=3681)），**22.03 及以后已修复**。如果你还在 21.02，升级即可。

### Q8：门户 IP 和路由器 LAN 网段冲突

如果路由器 LAN 是 `192.168.1.0/24`，而门户也是 `192.168.1.100`，会互相打架。
把路由器 LAN 改成别的网段即可（例如 `192.168.2.1`）。HFNU 环境下若路由器 LAN 为 `192.168.11.1`，则**不冲突，无需修改**。

---

## 9. 附录：新版接口响应格式

### 登录 `/eportal/portal/login`（JSONP，回调 `dr1003`）

响应为 UTF-8 JSONP，形如：

```
dr1003({"result":1,"msg":"登录成功","data":{...}});
```

| 字段 | 含义 |
| --- | --- |
| `result` | **1 = 成功**；0 = 失败，具体原因看 `msg` |
| `msg` | 服务端返回的原始消息（UTF-8 中文），如「登录成功」「IP: 10.x.x.x 已经在线！」「账号或密码错误」 |
| `ret_code` | 附加结果码（如 2 = IP 已在线） |

脚本特殊处理：「IP 已经在线」虽是 `result=0`，但 IP 本来就是自己的，**视为成功**。

### 注销 `/eportal/portal/logout`（JSONP，回调 `dr1004`）

- `user_account=drcom`、`user_password=123` 是认证页注销链接里的**固定占位值**，服务端靠 `wlan_user_ip` 定位会话，与登录账号无关——**绝不能传真实账号**。
- 判据与登录相同：注销后复测连通性，如实上报。

### 旧版结果码（已停用，仅供考古）

2026-11-16 改版前的 `?c=ACSetting&a=Login` POST 接口使用 `ACLogOut` / `ACLogIn` / `Msg` 结果码和 `Dr.COMWebLoginID_N.htm` 页面标记，并依赖 RADIUS `http://172.16.254.2/errcode` 查真实失败原因。该接口已停用，相关代码表可翻看本仓库改版前的历史提交（README 第 9 节旧版）。

---

## 10. 免责声明

- 本项目仅用于**个人设备在自有账号下**的自动化登录，方便路由器自动恢复上网。
- 本仓库不包含、也不接受任何人的真实账号密码或会话 Cookie。
- 请勿用于账号共享、蹭网、批量登录或任何违反学校网络管理规定与法律法规的行为。
- 脚本以明文保存账号密码（接口要求明文提交，面向嵌入式设备的简化实现）。**请给脚本设置合适权限**（`chmod 700 /etc/campus-login.sh`），不要把自己的版本上传到公开仓库。
- 门户接口、IP、参数格式可能随学校系统升级而变化，脚本不保证长期有效。使用前请先在 `debug` 模式下自行确认。
