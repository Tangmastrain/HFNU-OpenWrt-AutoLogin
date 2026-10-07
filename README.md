# 合肥师范学院 HFNU 路由器 OpenWrt 自动连接教程

给**合肥师范学院**（HFNU）校园网做一条"路由器自己登录"的自动化链路。

刷了 OpenWrt 的路由器接上校园网后，只要开机或掉线，脚本会自动向校园网门户（Dr.COM / 城市热点 eportal）提交认证请求，**不需要再打开浏览器点登录**。适合宿舍路由器、随身 Wi-Fi、树莓派软路由等场景。

> 已实测环境：小米路由器 4A 千兆版（MT7621AT + MT7603EN + MT7612EN），OpenWrt 25.12-SNAPSHOT，busybox ash。
> 理论上所有能跑 shell + curl 的 OpenWrt / LEDE 设备都能用。

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
- [9. 附录：门户结果码对照表](#9-附录门户结果码对照表)
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

HFNU 校园网是典型的 **Dr.COM / 城市热点 eportal 门户 + 华为 ME60 宽带接入服务器（BRAS）** 组合：

```
你的设备 ──► OpenWrt 路由器 ──► 校园网墙口
                                    │
                          ┌─────────┴──────────┐
                          ▼                    ▼
              eportal 门户 (认证页面)      华为 ME60 (AC)
              http://192.168.1.100:801     wlanacname=me60
                                          wlanacip=172.16.254.6
                                          RADIUS=172.16.254.2
```

- 未认证时，任何上网流量都会被劫持到 `http://192.168.1.100` 的登录页。
- 登录页本质上是一段 JavaScript，最后由浏览器 **POST 一个表单** 到门户的 `/eportal/` 接口。
- 门户把请求转发给 ME60，ME60 再通过 RADIUS 做真正的账号校验。
- 所以：**我们只要复现这一次 POST，就等于手动点了登录按钮。**

### 2.2 登录请求长什么样

用浏览器 F12（网络面板）抓包，把登录那一条复制成 `curl`，就能看到核心请求：

**请求地址**（GET 参数携带认证上下文）：

```
http://192.168.1.100:801/eportal/?c=ACSetting&a=Login
    &protocol=http:&hostname=192.168.1.100&iTermType=1
    &wlanuserip=<本机在校园网的IP>&wlanacip=172.16.254.6&wlanacname=me60
    &mac=00-00-00-00-00-00&ip=<本机在校园网的IP>
    &enAdvert=0&queryACIP=0&loginMethod=1
```

**请求体**（账号密码在这里）：

```
DDDDD=<账号>&upass=<密码>&R1=0&R2=0&R6=0&para=00&0MKKey=123456
&buttonClicked=&redirect_url=&err_flag=&username=&password=&user=&cmd=&Login=
```

几个关键点：

- `DDDDD` 是账号、`upass` 是密码（Dr.COM 的固定字段名，很反直觉，别改）。
- `wlanuserip` / `ip` 必须是**路由器 WAN 口拿到的那个校园网 IP**，不是 LAN 侧地址。填错会直接认证失败。
- `wlanacname`、`wlanacip` 是 ME60 的标识，脚本里已经按 HFNU 的值写好了。
- 登录成功会返回 **302 跳转**，跟随重定向后页面里会出现 `<!--Dr.COMWebLoginID_3.htm-->` 标记。

### 2.3 失败原因到底在哪？

这是最容易踩的坑：**门户页面上显示的"账号或密码不正确"经常是假的。**

真实原因要看两个地方：

1. **跳转 URL 上的结果码**：`ACLogOut=` / `ACLogIn=`，以及页面里的 `Msg=`。
2. **RADIUS 错误码**：门户调用的 `http://172.16.254.2/errcode`，返回类似
   `Rpost=2;ret='Authentication Fail ErrCode=05'`，其中的 `ErrCode` 才是真正的失败原因（比如欠费、已在线、账号停用……）。

抓包里那次 `/errcode` 请求是被阻断的（status 0），所以门户只能显示兜底文案。脚本里带了完整的 `RadiusErrorAry` 翻译表，会把 `ErrCode=05` 翻成"账号已停机/欠费"这类人话。

---

## 3. ⭐ 获取你自己的登录请求（F12 抓包）

> **这一步是整个教程里最关键的一步，一定要做。**
>
> 本仓库里**没有任何人的账号、密码或会话信息**——`campus-login.sh` 的 `USERNAME` / `PASSWORD` 是占位符，必须换成你自己的。
>
> 而"你自己的那条登录请求"**必须从浏览器里现抓**：门户参数（`wlanacip`、`wlanacname`、`program`、`vlan` 等）会因楼栋、区域、时段而不同，直接用别人的值很可能登不上。

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
7. 在请求列表里找到名为 **`locales`** 的那一条请求（它和登录请求几乎同时发出，通常紧挨着）。
   - 找不到就在筛选框里输入 `locales` 过滤一下。
   - 也可以改为右键那条 **`?c=ACSetting&a=Login`** 的请求，效果完全一样。
8. **右键 `locales` → 「复制」→「复制为 cURL (bash)」**
   （Copy → Copy as cURL (bash)）。

到这一步，你的登录请求就已经落到剪贴板里了。

### 3.2 从复制出来的内容里提取配置

复制到的命令大概长这样（**下面全是脱敏后的样子**）：

```bash
curl --url 'http://192.168.1.100:801/eportal/?c=ACSetting&a=Login&protocol=http:&hostname=192.168.1.100&iTermType=1&mac=00-00-00-00-00-00&ip=10.x.x.x&enAdvert=0&queryACIP=0&loginMethod=1' \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -b 'program=201706081423; vlan=0; ip=10.x.x.x; md5_login2=<你的账号>%7C<你的密码>' \
  --data-raw 'DDDDD=<你的账号>&upass=<你的密码>&R1=0&R2=0&R6=0&para=00&0MKKey=123456&buttonClicked=&redirect_url=&err_flag=&username=&password=&user=&cmd=&Login=' \
  --insecure
```

对着它填脚本配置区：

| 复制结果里的位置 | 填到脚本变量 | 说明 |
| --- | --- | --- |
| `--url` 里的 `192.168.1.100` | `PORTAL` | 门户 IP，HFNU 一般固定 |
| `--url` 里的 `:801` | `EPORT` | eportal 端口 |
| `--url` 里的 `wlanacip=` | `WLANACIP` | ME60 的 AC IP |
| `--url` 里的 `wlanacname=` | `WLANACNAME` | ME60 的 AC 名称 |
| `--data-raw` 里的 `DDDDD=` | `USERNAME` | **你的账号**（学号/校园卡号） |
| `--data-raw` 里的 `upass=` | `PASSWORD` | **你的密码** |
| `--url` 里的 `ip=` / `-b` 里的 `ip=` | 不用填 | 那台抓包机器的 IP，脚本会自动探测路由器自己的 WAN IP |

> **重点提醒**：如果你抓到的 `wlanacip` / `wlanacname` 和脚本默认值（`172.16.254.6` / `me60`）**不一致**，请以你抓到的为准改掉——这正是"必须自己抓一次"的原因。

### 3.3 安全提醒：别把你的登录信息贴出去

复制出来的命令里，这些内容是**你的凭据，不要发到任何公开的地方**（QQ 群、issue、贴吧、GitHub）：

- `md5_login2=<账号>%7C<密码>` —— 你的账号密码原文
- `-b '... PHPSESSID=...'` —— 你的会话 Cookie，等同于临时登录凭据
- `DDDDD=` / `upass=` —— 账号密码

**本脚本不需要 Cookie，也不需要 `md5_login2`**，只要 `DDDDD` 和 `upass` 两个值就够了。发帖求助前记得把这几段打码。

---

## 4. 快速开始（三步搞定）

### 第一步：改账号密码

打开 `campus-login.sh`，只改配置区这两行：

```sh
USERNAME="YOUR_STUDENT_ID"      # 换成你的学号 / 校园卡号
PASSWORD="YOUR_PASSWORD"        # 换成你的密码
```

如果第 3 步抓包里看到的 `wlanacip` / `wlanacname` 和默认值不同，顺手一起改掉。

### 第二步：先跑一次诊断

第一次**务必**先跑诊断模式，它会打印全部中间结果，一眼看出问题出在哪：

```sh
sh /tmp/campus-login.sh debug
```

正常的话最后几行长这样：

```
4) 发送登录请求...
   最终URL: http://192.168.1.100/.../Dr.COMWebLoginID_3.htm
   页面标记 : Dr.COMWebLoginID_3.htm
5) 判定    : ok|登录成功(Msg=15)
7) 复查联网: 已恢复联网
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
| `USERNAME` | `YOUR_STUDENT_ID` | **必改**。学号 / 校园卡号 |
| `PASSWORD` | `YOUR_PASSWORD` | **必改**。校园网密码 |
| `PORTAL` | `192.168.1.100` | 认证门户 IP，一般不用改 |
| `EPORT` | `801` | 门户 eportal 端口 |
| `ISP_SUFFIX` | 空 | 运营商后缀。有校园宽带/电信移动联通的填 `@电信` 之类，普通校园网留空 |
| `WLANACNAME` | `me60` | ME60 的 AC 名称 |
| `WLANACIP` | `172.16.254.6` | ME60 的 AC IP |
| `RADIUS_IP` | `172.16.254.2` | RADIUS 服务器，用来查真实失败原因 |
| `MAC` | `00-00-00-00-00-00` | 抓包中就是全 0，保持默认即可 |
| `WAN_IP` | 空 | **留空 = 自动探测**。填了就用你指定的（多拨/VLAN 例外情况才需要） |
| `CHECK_HOSTS` | `223.5.5.5 119.29.29.29 114.114.114.114` | 联网检测用的 ping 目标 |
| `CHECK_URL` | `http://connect.rom.miui.com/generate_204` | 联网检测用的 HTTP 探测（返回 204 即通） |

**关于 WAN IP 自动探测**：脚本会按这个顺序找"路由器在校园网的 IP"：

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
探测 WAN IP → POST 登录 → 等 2 秒 → 复查 is_online
     │
     否 ──►  打印门户结果码 + 查 RADIUS 真实原因（写日志）
```

这样即使门户返回了看不懂的结果码，只要网络恢复了就算成功，不会被误判。

---

## 8. 常见问题与排查

### Q1：门户提示"账号或密码不正确"，但密码明明是对的

先跑 `sh campus-login.sh debug`，看第 6 步的 RADIUS 输出。
HFNU 的真实失败原因在 `http://172.16.254.2/errcode`，常见的是：

- `ErrCode=05` 账号已停机/欠费
- `ErrCode=85` 账号已在线上（重复登录冲突）——先 `logout` 再登
- `auth error199` 用户名或密码错误——这才是真的密码错

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

然后等 1~2 分钟再登录。或者去学校自助服务页面（HFNU 是 `http://192.168.12.67:8080/Self`）手动下线其他设备。

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

### Q6：F12 抓不到 `locales` 请求

- 确认已经勾选 **「保留日志 / Keep log」**，否则登录跳转后列表会被清空。
- 先在 Network 面板打开的状态下**刷新一次登录页**，再输入账号密码。
- 筛选框输入 `locales`，或直接看 `?c=ACSetting&a=Login` 那条。
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

## 9. 附录：门户结果码对照表

以下映射由门户自身的 `a41.js`（`errorMsgObj`）提取并交叉验证。

### 页面标记

| 标记 | 含义 |
| --- | --- |
| `Dr.COMWebLoginID_0.htm` | 未登录（登录页） |
| `Dr.COMWebLoginID_1.htm` | 已登录（注销页） |
| `Dr.COMWebLoginID_2.htm` | 登录失败 |
| `Dr.COMWebLoginID_3.htm` | **登录成功** |

### `ACLogOut`（`errorMsgObj.acLogout()`）

| 值 | 含义 |
| --- | --- |
| 0 | BS 注册失败 |
| 1 | 注册成功 |
| 2 | 该 IP 禁止登录 |
| 3 | 手机已下线 |
| 4 | 该 IP 未加入白名单 |
| 5 | 门户自定义 ErrorMsg |
| 6 | 账号或密码不正确 |
| 其他 | 转去查 RADIUS |

### `Msg`（`errorMsgObj.defaultAuth()`）

| 值 | 含义 |
| --- | --- |
| 0 / 1 | 失败，具体看 `msga`（`error0` IP 不许 Web 登录 / `error1` 账号不许 Web 登录 / `error2` 不许改密码） |
| 2 | 账号正在使用中（很可能已在别处登录） |
| 3 | 账号只能在指定地址使用 |
| 4 | 已超支或时长用完 |
| 5 | 账号已暂停使用 |
| 6 | 系统缓存太多，稍后重试 |
| 7 | 账号在线 |
| 8 | 正在使用中，不能修改 |
| 9 | 新密码与确认密码不匹配 |
| 10 | 密码修改成功 |
| **14** | **注销成功** |
| **15** | **登录成功** |

### `ACLogIn`（`errorMsgObj.acLogin()`）

| 值 | 含义 |
| --- | --- |
| 0 | 成功 |
| 1 | 账号或密码不对 |
| 2 | IP 已经在线 |
| 3 | 系统忙 |
| 4 | 未知错误 |
| 5 | REQ_CHALLENGE 失败 |
| 6 | REQ_CHALLENGE 超时 |
| 7 | 认证失败 |
| 8 | 认证超时 |
| 9 | 注销失败 |
| 10 | 注销超时 |
| 11 | 其他错误 |

### RADIUS `ErrCode`（`RadiusErrorAry`，节选）

| ErrCode | 含义 |
| --- | --- |
| 04 | 在线时长/流量已达上限 |
| 05 | 账号已停机/欠费 |
| 09 | 账号费用超支，禁止使用 |
| 11 | 不允许 RADIUS 登录 |
| 80 | 接入服务器不存在 |
| 81 | LDAP 认证失败 |
| 85 | 账号已在线上（重复登录冲突） |
| 86 | IP 或 MAC 绑定失败 |
| 88 | IP 地址冲突 |
| 94 | 并发访问超限 |

---

## 10. 免责声明

- 本项目仅用于**个人设备在自有账号下**的自动化登录，方便路由器自动恢复上网。
- 本仓库不包含、也不接受任何人的真实账号密码或会话 Cookie。
- 请勿用于账号共享、蹭网、批量登录或任何违反学校网络管理规定与法律法规的行为。
- 脚本以明文保存账号密码（面向嵌入式设备的简化实现）。**请给脚本设置合适权限**（`chmod 700 /etc/campus-login.sh`），不要把自己的版本上传到公开仓库。
- 门户接口、IP、结果码可能随学校系统升级而变化，脚本不保证长期有效。使用前请先在 `debug` 模式下自行确认。
