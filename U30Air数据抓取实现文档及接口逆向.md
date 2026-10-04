# ZTE U30Air 数据抓取实现文档及接口逆向

> 目标设备：`http://192.168.0.1/#login`（ZTE U30Air 随身热点）· 动态抓包窗口 5 分钟（浏览器侧 + 传输侧双侧）
> 覆盖内容：接口契约、字段字典、鉴权条件、每秒轮询实测，以及迁移为 Windows 桌面小组件的完整实现

## 1. 背景与目标

ZTE U30Air（随身 5G/4G 热点，产品类型 UFI，带内置电池）的 Web 管理页在登录页
（`#login`）显示设备电量与充电状态。目标是把这一显示**迁移**到更方便的位置：

- Windows 任务栏（系统托盘图标 + 悬浮提示）
- 桌面小组件（Rainmeter 皮肤 / 独立小窗口）

为此需要先弄清：页面从哪个接口、用什么参数/鉴权、以什么频率获取电量与充电状态，
然后给出可直接落地的获取层实现。

## 2. 分析方法与工具

| 阶段 | 手段 | 工具 |
|---|---|---|
| 静态逆向 | 抓取 HTML/RequireJS 模块，追踪 `#login` 视图绑定与数据源 | PowerShell + 内置 Python |
| 动态抓包 | 从打开页面第一毫秒起记录全部请求/响应/控制台/DOM，持续 5 分钟 | **Playwright 1.63（驱动系统 Edge）+ mitmproxy 12.2（中间人代理交叉验证）** |
| 请求头标定 | 逐项变换请求头定位鉴权条件 | Python urllib 矩阵探测 |
| 独立验证 | 脱离浏览器复现接口并记录时间序列 | `capture/verify_battery.py` |

静态源文件保存于 `static/`，抓包产物保存于 `capture/`，分析脚本在 `tools/`。

## 3. 页面架构分析（静态逆向结论）

- 设备 Web UI 是 **RequireJS 单页应用**：`index.html` → `js/main.js`（require 配置）
  → `js/app.js` → `config/ufi/u30air/menu.js` 路由表。
- 路由表中 `#login` 的定义为
  `{hash:"#login", path:"login", requireLogin:!1, ...}` —— **登录页不要求会话**。
- 关键配置（`js/config/config.js`）：`DEVICE_MODEL:"U30Air"`、`PRODUCT_TYPE:"UFI"`、
  `HAS_BATTERY:!0`、`PASSWORD_ENCODE:!0`、`ACCESSIBLE_ID_SUPPORT:!0`。
- 登录页视图 `js/login.js` + 模板 `tmpl/login.html`：
  - `tmpl/login.html` 第 106–108 行即电量显示：
    ```html
    <label class="col-12 text-black-50" data-trans="battery"></label>
    <img data-bind="attr: {src: batteryPers}" style="width: 60px;">
    <label class="col-8" data-bind="text: batteryLevel" ...>
    ```
  - knockout observable：`batteryPers`（图标路径）、`batteryLevel`（百分比文本）。
- 顶栏状态条 `js/status/statusBar.js` 中的图标选择函数 `S(batteryPers, batteryCharging)`：
  ```js
  function S(e, t) {            // e = battery_pers, t = battery_charging
    return "0" == t             // 放电中
      ? ("1"==e?"battery_one" : "2"==e?"battery_two" : "3"==e?"battery_three"
         : "4"==e?"battery_full" : "battery_out") + ".png"
      : "2" == t                // 已充满（接电）
      ? "img/battery_full.png"
      : ("1"==e?"battery_charging1" : "2"==e?"battery_charging2"
         : "3"==e||"4"==e?"battery_charging3" : "battery_charging") + ".gif";
  }
  ```
  → **`battery_charging` 取值语义：`"0"`=放电、`"1"`=充电中、`"2"`=已充满**；
  `battery_pers` 是电量分档（1..4，用于图标粗粒度显示）。
- 数据总线 `js/service.js`：
  - 所有查询走 **`GET /goform/goform_get_cmd_process`**（ZTE goform 体系，
    写入走 `POST /goform/goform_set_cmd_process`）。
  - 核心轮询函数 `W()`：**每次响应后 `setTimeout(..., 1000)` —— 即 1 秒一轮**；
    请求参数由 `x()` 组装：`{multi_data:1, isTest:false, cmd: ko.join(",")}`。
  - 轮询命令组 `ko` 初始包含
    `mc_modem_main_state, battery_charging, battery_value, battery_vol_percent,
    network_signalbar, ppp_status, ...`；在 `#login` 下会剔除仅登录后需要的
    附加命令（`Lo`），但**电量字段保留**。
  - 响应解析（状态总线 `Co`）：
    ```js
    batteryLevel    = e.battery_vol_percent   // 字符串百分比，缺省按 100
    batteryStatus   = e.battery_charging      // 缺省 "0"
    battery_value   = e.battery_value         // 与百分比同值
    batteryPers     = e.battery_pers          // 电量分档 1..4（图标）
    batteryTime     = round(10800 * (1 - level/100))  // 剩余秒数估算（3 小时基准）
    ```

## 4. 动态抓包结果（5 分钟窗口）

抓包配置：Playwright 驱动系统 Edge（无头），整机流量经本地 mitmproxy（127.0.0.1:8080）
转发，浏览器侧事件与传输侧流量**双侧记录**；每 5 秒对页面做一次 DOM 采样；
时间轴 `t` 以页面导航为 0 点。

### 4.1 抓包概况

| 指标 | 数值 |
|---|---|
| 时间窗 | t = 0.157 s ~ 302.606 s（完整 5 分钟） |
| 浏览器侧事件 | 680 条（请求/响应含 body） |
| 传输侧流量（mitmproxy） | 354 条（原始 HTTP 报文，含请求头/响应体） |
| DOM 采样 | 60 份（每 5 秒） |
| 资源加载 | 首屏 index.html t=0.48s；CSS/JS/模板共 57 个资源，全部 200 |
| **鉴权失败次数** | **0**（整场没有出现过 `none secure connection`） |

启动时序：`t=0.48s` 取回 `index.html` → `t=0.68s` 批量加载 RequireJS 生态 →
`t=5.83s` 业务模块就绪并发出**第一笔 goform 状态查询** → 此后持续轮询到窗口结束。

唯一的错误是一个与本任务无关的资源 404：`img/icon_red.png`（页面自身引用缺失，
console 中仅 1 条 error）。

### 4.2 端点清单与轮询模式（双侧一致）

| 次数 | 方法 | 端点 |
|---|---|---|
| **290** | GET | `http://192.168.0.1/goform/goform_get_cmd_process`（浏览器侧 290 = 传输侧 290 ✓） |
| 4 + 3 | GET | `svg_img/battery_charging_3.svg`、`battery_charging_4.svg`（充电状态图标随状态切换） |
| 其余 | GET | 静态资源各 1 次（HTML/CSS/JS/模板/SVG/PNG） |

goform 查询按 `cmd` 精确分组共 5 组：

| 次数 | 轮询间隔 | cmd 内容 |
|---|---|---|
| **285** | **≈1.05 s/次**（300 s 内 0.95 次/秒；呈"每 ~5.05 s 一簇 4–5 个并发请求"的模式） | 主状态组：`mc_modem_main_state, battery_charging, battery_value, battery_vol_percent, network_signalbar, ppp_status, flux_realtime_tx_thrpt, flux_realtime_rx_thrpt, sim_slot, sim_pin_status, opms_wan_mode, opms_wan_auto_mode, loginfo, new_version_state, current_upgrade_state, is_mandatory, ppp_dial_conn_fail_counter, mwan_wanlan1_linkup_speed, mwan_wanlan1_linkdown_speed, mwan_wanlan1_link_mode, mwan_wanlan1_pppoe_status, mwan_wanlan1_dhcp_status, mwan_wanlan1_link_state, wifi_chip1_ssid1_ssid, wifi_chip2_ssid1_ssid, sim_spn_name_data, sim_spn_b1_flag, sim_spn_b2_flag, network_simcard_roam, network_provider_fullname, Z5g_rsrp, network_lte_rsrp, network_rscp, lte_rssi, network_type`（35 个字段） |
| 2 | 启动时 | 登录数据组：`mc_modem_main_state, puknumber, sim_pinnumber, opms_wan_mode, psw_fail_num_str, login_lock_time, SleepStatusForSingleChipCpe` |
| 1×3 | 启动时 | 一次性信息组：`electron_id,dual_sim_support,is_support_nfc_functions` / `Language,cr_version,wa_inner_version` / `web_wifi_password_init_flag,web_privacy_read_flag` |

> 与静态逆向一致：`service.js` 的 `W()` 每轮结束后 `setTimeout(...,1000)` 重新武装，
> UI 多个模块共享同一 cmd 总线，宏观表现为**约每秒 1 次状态刷新**。
> **电量字段就在主状态组里**，登录页专门的"电量接口"并不存在——
> 所有状态（含电量）都来自这一个 goform 查询。

### 4.3 原始请求/响应（传输侧第一笔 goform 报文）

```
GET /goform/goform_get_cmd_process?multi_data=1&isTest=false&cmd=mc_modem_main_state%2Cbattery_charging%2C...%2Clte_rssi%2Cnetwork_type&_=1791042098494
Host: 192.168.0.1
Referer: http://192.168.0.1/                 ← 关键头
X-Requested-With: XMLHttpRequest
Accept: application/json, text/javascript, */*; q=0.01
User-Agent: Mozilla/5.0 ... Edg/154.0.0.0
（首笔无 Cookie）
```

响应节选（200 OK，约 881 字节 JSON）：

```json
{"loginfo":"no","network_provider_fullname":"中国联通","network_type":"5G",
 "mc_modem_main_state":"modem_init_complete","network_signalbar":5,
 "battery_charging":"1","battery_value":"80","battery_vol_percent":"80",
 "flux_realtime_tx_thrpt":0, "...": "..."}
```

Cookie 情况：服务端在首个 goform 响应中下发
`JSESSIONID`（`path=/goform`、httpOnly），**其后 289/290 笔请求自动携带**；
但独立复现（不带任何 Cookie、只带 Referer）同样成功 —— 登录前该 Cookie 并非必需。

### 4.4 电量与充电状态时序（窗口内实测）

| 时刻 | 事件 |
|---|---|
| t = 5.83 s | 首次返回 `battery_vol_percent=80, battery_charging=1` |
| **t = 197.01 s** | **80% → 81%**（抓包窗口内实测充电跳变，`battery_charging` 恒为 `1`） |
| t = 297.6 s（DOM 采样） | 页面文本实时显示 `电量` + **`81%`** —— 与接口值一致 |

图标联动：登录页电池图标请求 `svg_img/battery_charging_3.svg`（4 次）与
`battery_charging_4.svg`（3 次），说明**图标按充电档位切换**，与 `battery_pers`
（电量分档 1..4）机制对应。

并行进行的独立验证（同窗口、浏览器之外）：33/33 成功，电量稳定在 81%、
`charging=1`，RTT 19–107 ms（均值 35 ms）——**两个客户端同时轮询互不干扰**。

### 4.5 结论

- 登录页电量显示 = 主状态轮询（约 1 次/秒）里 `battery_vol_percent` +
  `battery_charging` 两个字段 + 按档位切换的 SVG 图标；
- 全程 0 次鉴权失败，证明**Referer 是唯一门禁**；
- 接口极轻（单笔 <1 KB、毫秒级响应），外部以 15–60 秒间隔轮询毫无压力。

## 5. 接口规范（核心结论）

### 5.1 请求

```
GET http://192.168.0.1/goform/goform_get_cmd_process
    ?cmd=mc_modem_main_state,battery_charging,battery_value,battery_vol_percent,network_signalbar,loginfo
    &multi_data=1
    &isTest=false
    &_=<毫秒时间戳>
Host: 192.168.0.1
Referer: http://192.168.0.1/          ← 必需，缺了就返回 {"Error":"none secure connection"}
```

标定结果（请求头矩阵实测）：

| 变体 | 结果 |
|---|---|
| 无 Referer（HTTP） | `{"Error":"none secure connection"}` |
| 仅 `X-Requested-With: XMLHttpRequest` | `{"Error":"none secure connection"}` |
| **`Referer: http://192.168.0.1/`** | **成功，返回电量 JSON** |
| `Referer: https://192.168.0.1/` | `{"Error":"none secure connection"}`（Referer 必须是 http:// 形式） |
| `Referer: http://192.168.0.1/#login` | 成功 |

即：**免登录（`loginfo:"no"`）即可读取电量**，唯一的"鉴权"是 Referer 校验。

### 5.2 响应样例（实测）

```json
{"loginfo":"no","network_signalbar":5,"mc_modem_main_state":"modem_init_complete",
 "battery_charging":"1","battery_value":"79","battery_vol_percent":"79"}
```

### 5.3 字段字典（登录前可用性以 ★ 标注）

| 字段 | 类型/样例 | 含义 | 说明 |
|---|---|---|---|
| ★ `battery_vol_percent` | `"79"` | 电量百分比（字符串） | 页面 `batteryLevel` 直接显示它 |
| ★ `battery_value` | `"79"` | 电量值 | 实测与百分比同值 |
| ★ `battery_charging` | `"0"/"1"/"2"` | 充电状态 | 0=放电 1=充电中 2=已充满（图标函数 `S()` 语义） |
| `battery_pers` | `"1".."4"` | 电量分档（图标用） | 登录前查询返回 `{}`（该字段未下发） |
| `battery_temperature_level` | `"0"` | 电池温度档 | service.js 有解析，登录前未下发 |
| `is_charging_expired` | `"0"` | 充电异常/过期标志 | service.js 有解析，登录前未下发 |
| ★ `loginfo` | `"no"/"ok"` | 是否已登录 | 独立查询 `cmd=loginfo` |
| ★ `network_signalbar` | `1..5` | 信号格 | |
| ★ `mc_modem_main_state` | `"modem_init_complete"` | 模块状态 | 登录页据此判断 PIN/PUK |
| ★ `flux_realtime_rx_thrpt` | `"242407"` | **实时下行速率** | 单位**字节/秒**；×8÷1024^2 → `1.85 Mb/s`（与页面 `transUnit` 一致，118/118 实证） |
| ★ `flux_realtime_tx_thrpt` | `"11738"` | **实时上行速率** | 同上（×8÷1024 → `91.7 Kb/s`） |
| ★ `network_provider_fullname` | `"中国联通"` | 运营商 | 方案 B 直接显示 |
| ★ `network_type` | `"5G"` | 网络制式 | 与运营商拼接显示 |
| ★ `Z5g_rsrp` / `lte_rssi` / `network_rscp` | `-91` | 信号强度 dBm | 5G RSRP / LTE RSSI / 3G RSCP，按此顺序回退取第一个有效值 |

### 5.4 频率与开销

- 页面自身轮询（抓包实测）：**约 0.95–1.05 次/秒**（5 分钟 285 笔主状态查询，
  呈"每 ~5.05 秒一簇 4–5 个并发请求"的宏观形态）。
- 实测响应时延：**19–107 ms（均值约 35 ms）**，单笔响应 <1 KB，纯内存查询，
  设备负担很小；抓包窗口内页面轮询 + 独立脚本轮询并行互不干扰。
- 迁移后建议：桌面小组件/托盘 **15–60 秒一次**足够（电量变化以分钟计，
  实测约 3 分钟涨 1%），也避免与设备自身会话争抢。

## 6. 迁移实现方案

完整可运行代码已随报告提供（见附录 A 文件清单）：

| 文件 | 作用 |
|---|---|
| `widget/Get-U30AirBattery.ps1` | **获取层**：查询电量/充电状态，返回结构化对象或一行文本 |
| `widget/U30AirBattery-Tray.ps1` | **方案 A**：Windows 任务栏托盘程序（图标+悬浮提示） |
| `widget/Rainmeter/U30AirBattery.ini` + `rainmeter_run.ps1` + `battery_cmd.ps1` | **方案 B**：Rainmeter 桌面小组件 v7（电量/充电/运营商/信号/上下行速率，自诊断） |

### 6.1 获取层（两个方案共用）

核心是一次带 `Referer` 的 GET（已实测通过）：

```powershell
$cmd  = 'mc_modem_main_state,battery_charging,battery_value,battery_vol_percent,network_signalbar,loginfo'
$url  = "http://192.168.0.1/goform/goform_get_cmd_process?cmd=$cmd&multi_data=1&isTest=false&_=$(Get-Random)"
$j    = Invoke-WebRequest -Uri $url -Headers @{ Referer = 'http://192.168.0.1/' } -UseBasicParsing -TimeoutSec 3 |
         Select-Object -Expand Content | ConvertFrom-Json
"$($j.battery_vol_percent)%  charging=$($j.battery_charging)"   # 例如 80%  charging=1
```

`Get-U30AirBattery.ps1` 在此基础上封装：

```powershell
. .\widget\Get-U30AirBattery.ps1
$s = Get-U30AirBattery
$s.Percent        # 80
$s.Charging       # Charging | Full | Discharging
$s.ChargingText   # 充电中 / 已充满 / 放电中
$s.SignalBars     # 5
Get-U30AirBattery -AsString   # "80% 充电中"（一行文本，方便小组件直接显示）
```

实测输出（报告生成时）：`Ok=True, Percent=80, Charging=Charging, ChargingText=充电中,
SignalBars=5, LoggedIn=False` —— **全程不需要管理密码**。

其他语言的等价实现（要点完全相同：GET + Referer + JSON）：

```python
import urllib.request, json, time
url = ("http://192.168.0.1/goform/goform_get_cmd_process"
       "?cmd=battery_vol_percent,battery_charging&multi_data=1&isTest=false&_=%d" % int(time.time()*1000))
j = json.load(urllib.request.urlopen(urllib.request.Request(
        url, headers={"Referer": "http://192.168.0.1/"}), timeout=3))
print(j["battery_vol_percent"], j["battery_charging"])
```

```bash
curl -s -H 'Referer: http://192.168.0.1/' \
  'http://192.168.0.1/goform/goform_get_cmd_process?cmd=battery_vol_percent,battery_charging&multi_data=1&isTest=false'
```

### 6.2 方案 A：Windows 任务栏托盘（推荐，无第三方依赖）

`widget/U30AirBattery-Tray.ps1` 使用系统自带的 WinForms `NotifyIcon`：

**托盘图标 = 电量数字 + 状态底色**（GDI+ 现画 32×32 圆角块，白色粗体数字，
字号按位数自动缩放，两位数/三位数如 `81`/`100` 都清晰可读）：

| 图标 | 含义 |
|---|---|
| 橙色底 + 数字 | 充电中（`Charging`） |
| 绿色底 + 数字 | 已充满（`Full`，接电但已充满） |
| 蓝色底 + 数字 | 放电中正常（`Discharging`） |
| 红色底 + 数字 | 低电量（≤20%） |
| 灰色底 + `--` | 设备离线 / 查询失败 |

![托盘图标五种状态预览](tray-icon-preview.png)

- **悬浮提示**：`U30Air 电量 81%（充电中） · 信号 5/5`（悬停可见完整状态与信号格）；
- **默认 30 秒刷新一次**（脚本配置区 `$RefreshSec` 可调，建议 15–60 秒）；
- 右键菜单：立即刷新 / 打开设备管理页（`http://192.168.0.1`）/ 退出；双击图标直接打开管理页；
- 设备不可达时图标转灰色 `--` 并提示"U30Air 设备离线"，恢复后下一轮自动复原。

运行（无窗口后台）：

```powershell
powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File .\widget\U30AirBattery-Tray.ps1
```

> 只有首次运行若被执行策略拦截才需要 `-ExecutionPolicy Bypass`；
> 本机 PowerShell 需能访问局域网（HTTP 出站，无特殊要求）。

### 6.3 方案 B：桌面小组件（Rainmeter）—— 电量 + 网络状态

> 本节是 v2 → v10 的**演进过程记录**（含各次踩坑与源码级证据）；
> **最终交付形态（v11，守护进程 + WebParser）以第 8 章为准。**

`widget/Rainmeter/` 提供开箱即用皮肤 **v3（乱码修复版）**，深色半透明底板上显示五行信息：

![Rainmeter 组件修复后预期效果](rainmeter-widget-preview.png)

| 显示行（颜色） | 示例 | 数据字段 | 刷新周期 |
|---|---|---|---|
| 电量条 + 百分比 | `▓▓▓▓▓▓ 96%` | `battery_vol_percent` | 60 秒 |
| 充电状态（橙） | `充电中` | `battery_charging` | 60 秒 |
| 运营商 + 制式（灰） | `运营商：中国联通 · 5G` | `network_provider_fullname` + `network_type` | 60 秒 |
| 信号强度（浅蓝） | `信号：5/5 格 · -94 dBm` | `network_signalbar` + `Z5g_rsrp`/`lte_rssi`/`network_rscp` | 60 秒 |
| 实时速率（青绿） | `↓ 1.85 Mb/s   ↑ 91.7 Kb/s` | `flux_realtime_rx_thrpt`（下行）/ `flux_realtime_tx_thrpt`（上行） | **15 秒** |

**速率单位换算（关键结论，双证据交叉验证）**：

- 页面换算源码 `getDisplayVolume(e, t)` 中有 `t && (e *= 8)`，随后按
  1024 逐级取 `Kb/Mb/Gb` —— 即接口原始值单位是**字节/秒**，显示时 ×8 变 bps、再除以 1024/1048576；
- 用 5 分钟抓包做实证：把 60 个 DOM 采样里的显示速率（如 `1.85Mb/s`）与
  同时刻接口原始值对齐，三种假设里 **只有 ×8 + 1024 步进 100% 吻合**
  （118/118 条，中位误差 2.4%），"原始值即 bps"的假设仅 ~20% 吻合。

**刷新与开销策略（v9 秒级刷新）**（皮肤 `Update=1000`，用户要求每秒查询）：

- **全部 5 行每秒查询接口并更新显示**：每个 Measure `UpdateDivider=1` +
  `-PaceSec 1`（节拍 1 秒）+ `-CacheSec 1`（缓存 1 秒 = 每轮真实访问设备）；
- 实测节奏：60 秒窗口 **205 次入口调用**（每秒 4–5 次、单行约 1.1–1.5 秒
  一轮）、90 秒设备查询日志 291 条 —— **"每秒查询接口"实测达成**；
- 设备负担：单笔 <1 KB、毫秒级，页面自身本就 1 次/秒轮询，并行无干扰；
- 实测耗时基线：缓存命中 523 ms、冷启动 669 ms、设备离线 2.4 s 超时降级。

文件与安装（发布版最终为 **2 个文件**：`U30AirBattery.ini` + `rainmeter_daemon.ps1`，
装法见 `README.md`；下列早期版本的文件构成仅作演进记录）：

- `U30AirBattery.ini`：皮肤本体（5 个 RunCommand Measure + 5 个 Meter，
  **UTF-16 LE 编码 + 中文注释**，跟随参考套件做法）；
- `rainmeter_run.ps1`：**入口包装器（v7 新增）** —— Rainmeter 用最朴素的
  `-File` 启动它（与目标机器 v2 实测跑通的调用形态完全一致），内部用
  `$PSScriptRoot` 定位数据脚本，捕获一切错误以上屏 `ERR:` 显示；
- `battery_cmd.ps1`：数据源脚本，6 种输出模式
  `percent | status | carrier | signal | speeds | full`（中文标签也由脚本输出）；
  附 12 秒缓存与调用日志 `battery_cmd_invoked.log`；
- **乱码/空白根因（对照 Rainmeter 官方源码逐条确认）**：
  1. `Library/MeasureRunCommand.cpp`：`OutputType` 的**默认值是 `UTF16`**
     （Rainmeter 默认 `Program` 是 `cmd /U /C`，其输出就是 UTF-16LE），
     合法值仅 `UTF16 | ANSI | UTF8`。最初没写该选项、后来又误写非法值
     `Value` → 都按 UTF-16 解码 → GBK/UTF-8 字节被切成随机宽字符 → 乱码；
  2. 旧版脚本的报错走 **stderr**，而 RunCommand **只捕获 stdout** →
     脚本没跑起来时组件**空白、无任何提示**；
  3. `Common/FileUtil.cpp`：文件侧先严格 UTF-8、失败回退 ANSI 并识别 BOM，
     但另存丢 BOM、版本差异会让 ini 中的中文变乱码；
  4. **路径变量陷阱（"空白"的最终真相）**：`#@#` 并不是"皮肤根目录"，而是
     **`<皮肤根>\@Resources\`**（`ConfigParser.cpp` 216 行
     `ConsumeRest(L'@') → GetResourcesPath()`；`Skin.cpp` 2523 行
     `m_ResourcesPath = GetRootPath() + L"@Resources\\"`）。我们的
     `battery_cmd.ps1` 在皮肤根目录、没有 `@Resources\` → 路径落空 →
     PowerShell 报错进 stderr → **组件空白**。这精确解释了版本行为差异：
     v2（手动改绝对路径）能跑出（乱码的）值，v3 起换 `#@#` 后彻底空白。
- **参考套件 QuantoFlx.System（其他开发者成品）的借鉴与教训**：
  - 所有皮肤文件用 **UTF-16 LE（FF FE）** —— Rainmeter 的"母语"，任何版本零歧义；
  - 全套**零 DLL、纯内置 Measure、不跑外部命令** —— 能不跑就不跑；
  - 资源放在名为 **`@\`** 的目录、用 `#@#Config\xxx` 引用 —— 结构与源码
    `#@# = @Resources\` 的语义**并不一致**（推测其安装器会重命名目录）。
    正是这个观察提醒我们：**不要依赖 `#@#`**。
- **终版设计（v10，全部按真机 Rainmeter 4.5.26 实际执行验证）**：
  - **调用形态回归实证**：Rainmeter 侧只用 `-File "#CURRENTPATH#rainmeter_run.ps1" <mode> -PaceSec 1 -CacheSec 1`
    —— 与目标机器 v2 实测**成功启动过**的调用形态逐字一致；
    `-Command` 长命令行（v5/v6 方案）弃用；路径变量只在这一处出现，
    **脚本内部全部 `$PSScriptRoot` 自定位**，零 Rainmeter 变量、零替换环节；
  - **标题版本水印**：`Text=U30Air v9` —— 截图标题即可确认加载的是哪版 ini，
    排除"没拷贝新文件"这一最常见的假象；
  - **诊断链（任何一环都能定位问题，全部上屏/落盘）**：
    1. 标题显示 `U30Air v9` → 加载的是新版 ini（版本水印，已实证生效）；
    2. 组件显示 `ERR: ...` → 入口包装器抓到具体错误（实测
       `ERR: battery_cmd.ps1 NOT FOUND at: ...`，灾难演练下也照常上屏）；
       （v7 曾加过"路径显示行"用于定位 `#@#` 问题，根因修复后于 v10 删除，
       窗口宽度恢复 480→239 px）；
    3. **双日志**：`rainmeter_run_invoked.log`（入口被启动）+
       `battery_cmd_invoked.log`（数据脚本被调用）→ 精确定位断在哪一环
       （注意两份日志各按 32 KB 轮转，长窗口对比计数会失真）；
  - **路径改用 `#CURRENTPATH#`**（`ConfigParser.cpp` 224 行 → 136 行
    `m_CurrentPath = GetFolderFromFilePath(当前 ini)` = **当前 ini 所在目录**；
    `PathUtil.cpp` 60-68 行 `substr(0, pos + 1)` 证实**带结尾反斜杠**）——
    因此 `-File "#CURRENTPATH#rainmeter_run.ps1"` 拼出的路径精确正确，
    与目录结构无关、不依赖 `@Resources\` 是否存在；
  - **直说 Rainmeter 母语**：入口脚本在输出被重定向时直接写 **UTF-16LE 原始字节**
    （`GetBytes` 不产 BOM，正对 `reinterpret_cast<LPCWSTR>` 直解）——
    **完全不依赖 `OutputType` 选项**，旧版本 Rainmeter 一样工作；
    5 种模式实测：`100`、`充电中`、`运营商：中国联通 · 5G`、
    `信号：5/5 格 · -94 dBm`、`↓ 0 b/s ↑ 0 b/s` ✓；
  - **入口包装器 `rainmeter_run.ps1`（-File 启动，v7）**：`try/catch` 捕获
    "数据脚本缺失/语法错误"，把 `ERR: ...` 以 UTF-16 写进 stdout →
    **错误直接显示在组件上**（实测 `ERR: battery_cmd.ps1 NOT FOUND at: ...`），
    彻底告别"组件空白、无从查起"；
  - **调用日志**：数据脚本每次被调用追加一行到 `battery_cmd_invoked.log`
    （时间/模式/`-Quiet`/目录）—— 第一现场证据（实测 5 条模式日志齐全）；
  - **ini 改用 UTF-16 LE + 中文注释**（BOM `FF FE`，跟随参考套件
    QuantoFlx.System 的做法）：UTF-16 LE 是 Windows/Rainmeter 的原生编码，
    任何版本的 Rainmeter 都能正确读出中文注释，比无 BOM 的 UTF-8 更稳；
    ps1 脚本保持 UTF-8 BOM（PowerShell 标准），注释全部中文；
  - 注释规则经源码确认：`Common/IniFile.cpp` 仅**行首** `;` 视为注释，
    值内的 `;` 原样保留。
  - **防闪烁（v10，用户实测反馈）**：Rainmeter 的 `Command("RUN")` 在每次
    启动时会把数值置 `0.0`（源码 `MeasureRunCommand.cpp`），秒级循环下电量条
    随运行周期绿/灰闪烁。修复：`FinishAction` 在**运行完成后**把数值写入变量
    `!SetVariable Pct "[MeasurePercent]"`，电量条改读只在完成时刻刷新的
    Calc 测量 `[MeasureBarSrc]` —— 连续 8 次（1.5 秒间隔）采样
    **8/8 全绿、零灰格，闪烁消除**。
- **真机 Rainmeter 测试战役（本机 4.5.26 全流程实测）**：
  1. 自行下载安装：官方 NSIS 包静默安装曾被沙箱 Temp 拒写卡住 →
     最终装到 `C:\Program Files\Rainmeter`（4.5.26.3894），设置 `Logging=1`；
  2. **关键发现：此版本 RunCommand 不会自动执行**（极简皮肤 `cmd /c echo`
     实测不触发；`!CommandMeasure ... "RUN"` 手动触发立即成功）→
     采用源码背书的 `OnRefreshAction` + 每个 Measure 的
     `OnUpdateAction=[!CommandMeasure 自己 "RUN"]` 自动循环；
  3. `OnUpdateAction` 跟随"值更新"而非 `UpdateDivider` → 会形成紧密循环 →
     用入口脚本 `-PaceSec` 节拍整形为稳定 1 秒周期；
  4. 终态验证：日志 205 次/60s、设备查询 291 次/90s、五行彩色渲染
     （像素级验证橙/灰/蓝/绿各 112–230 px）、窗口 239x129、电量条 8/8 稳定。
- 离线降级：`percent` 返回 `0`（电量条归零），其余返回 `设备离线`；
- 安装：把整个 `Rainmeter` 文件夹拷到 `文档\Rainmeter\Skins\U30AirBattery\`，
  Rainmeter 中**右键刷新**并载入（无需修改任何路径）。

实测输出（真机 Rainmeter 秒级循环 + 手动 `-File` 直跑，UTF-16LE 解码）：

```text
percent => 100
status  => 放电中                          （设备已拔电，状态实时翻转 ✓）
carrier => 运营商：CMCC · 5G
signal  => 信号：5/5 格 · -81 dBm
speeds  => ↓ 1.41 Mb/s   ↑ 220.40 Kb/s     （用户截图实拍）
ERR 例  => ERR: battery_cmd.ps1 NOT FOUND at: D:\...\orphan\battery_cmd.ps1
节奏     => 205 次入口调用 / 60s；291 次设备查询 / 90s（每秒查询 ✓）
稳定性   => 电量条 8/8 采样全绿（闪烁已消除）；窗口 239x129（诊断行已删）
```

不想装 Rainmeter 的替代：把方案 A 的悬浮提示当小组件用，或用
`Get-U30AirBattery -AsString` 输出喂给任何支持命令行取数的桌面组件
（GeekDesk、流量屏、OB 等）；速率等新字段同样可以按上面 6 种模式取。

### 6.4 开机自启（任务计划程序）

方案 A 托盘开机自启（对当前用户、登录时触发、普通权限）：

```powershell
schtasks /Create /TN "U30Air Battery Tray" /SC ONLOGON /RL LIMITED /F ^
  /TR "powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"D:\Workspace\U30AirBatteryInfo\widget\U30AirBattery-Tray.ps1\""
```

Rainmeter 本身勾选"随 Windows 启动"即可，无需额外任务。

## 7. 风险与注意事项

1. **网络前提**：必须与设备同网（连接它的 Wi-Fi）；设备地址若不是 `192.168.0.1`
   需同步修改；热点休眠/断电时接口不可达，获取层要超时（建议 ≤3 s）并显示离线态。
2. **Referer 陷阱**：缺 Referer 或使用 https 形式的 Referer 都会返回
   `none secure connection`，这是最常见的踩坑点。
3. **字段差异**：`battery_pers`、`battery_temperature_level`、`is_charging_expired`
   登录前不下发；迁移显示只需 `battery_vol_percent` + `battery_charging` 即可。
4. **固件升级**：goform 字段名随固件可能变化；报告附带的验证脚本可在升级后复测。
5. **频率**：设备自身已 1 秒一轮，外部再以 1 秒轮询意义不大且徒增负载。
6. **凭据**：本方案完全不需要管理密码；若未来需要更多字段（如电池温度），
   需先登录（`goformId=LOGIN`），密码按 `Base64(md5+盐)` 编码（`PASSWORD_ENCODE:!0`）。

## 8. 终版架构（v11）与项目结构

前文第 6 章记录了方案 A（任务栏托盘）与方案 B（Rainmeter 皮肤）从 v2 到 v10 的
演进过程；本章是**最终交付形态**的权威描述。

### 8.1 数据链路

```text
设备 goform 接口  ──每秒真实查询 1 次──►  rainmeter_daemon.ps1（常驻守护进程，只启动一次）
                                              │ 原子写：临时文件 + 重试 + 孤儿清扫
                                              ▼
                                          live.txt（UTF-8 无 BOM，5 字段以 | 分隔）
                                              │ WebParser UpdateRate=1（每秒重读本地文件）
                                              ▼
                                U30AirBattery.ini 的 5 个 Measure → 桌面组件实时刷新
```

### 8.2 真机 Rainmeter 4.5.26 实测得出的关键结论（均已落进最终代码）

1. **RunCommand 不会自动执行**：极简皮肤 `cmd /c echo` 实测不触发；
   `!CommandMeasure ... "RUN"` 手动触发立即成功 → 最终用 `OnRefreshAction` +
   每个 Measure 的 `OnUpdateAction=[!CommandMeasure 自己 "RUN"]` 建立自循环
   （源码亦证实 `L"RUN"` 只出现在 `Command()` 内）。
2. `OnUpdateAction` 跟随"值更新"而非 `UpdateDivider` → 会形成紧密循环 →
   需要节拍整形（v9 用入口脚本 `-PaceSec`；v11 由守护进程的 1 秒循环天然定频）。
3. **高负载下 PowerShell 冷启动可恶化到 1.6~5.1 秒**（本机有虚拟机等重负载），
   "每 Measure 一个进程"（5 进程/秒）的节奏被拖到约 1.3 次/秒 →
   v11 改为**单守护进程常驻**，启动成本只付一次。
4. **WebParser 读本地文件必须带 `file://` 前缀**（`MeasureWebParser.cpp`：
   `localFile = _wcsnicmp(m_Url, L"file://", 7) == 0`），裸路径会被当作 HTTP 解析
   而失败；`CodePage` 默认 0 → CP_UTF8，正合守护进程写出的 UTF-8。
5. **live.txt 不能带 BOM**：BOM 会进入正则第一组（`"\uFEFF100"`），文字看着正常，
   但电量条的数值解析失败、条恒为空 —— 实测踩坑并修复。
6. 旧结论同样保留在最终实现中：`OutputType` 默认 UTF16（直接写 UTF-16LE 母语字节）；
   `#@#` 指向 `@Resources\`（改用 `#CURRENTPATH#`）；`Command("RUN")` 会把
   `m_Value` 置 0 造成闪烁（v10 用"完成后写变量 + Calc 条"消除，
   v11 数值来自 WebParser，天然无此问题）。

### 8.3 终态实测数据

- `live.txt` 的 mtime **每 1.00 秒前移**（守护进程 `interval=1000ms`）＝ 真·每秒查询；
- 像素级验证：电量条填充 **2520 px**、状态橙 112、运营商灰 224、信号蓝 231、速率绿 164
  → 五要素全部正常渲染（判定 `ALL OK - BAR FILLED`）；
- 无 `u30air_cache.json.tmp` / `live.txt.tmp` 残留（重试 + 清扫逻辑生效）；
- 守护进程唯一（父进程 = `Rainmeter.exe`），进程退出后由 `FinishAction` 自动拉起。

### 8.4 发布结构（精简后仅 4 项）

| 路径 | 说明 |
|---|---|
| `U30AirBattery/` | Rainmeter 皮肤文件夹（最终产物：`U30AirBattery.ini` + `rainmeter_daemon.ps1`） |
| `U30Air数据抓取实现文档及接口逆向.md` | 本文档：抓取方法、接口契约、字段字典、终版架构 |
| `README.md` | 项目介绍、项目截图、实现细节、安装方式、开源协议 |
| `LICENSE` | MIT 开源协议 |

开发阶段的抓包原始数据、设备静态源码、分析脚本等未纳入发布；
其关键结论已内联到本文档第 3~5 章与本章。

## 附录 A：文件清单

| 路径 | 说明 |
|---|---|
| `U30AirBattery/U30AirBattery.ini` | 皮肤本体（UTF-16 LE + 中文注释，5 个 WebParser Measure + 6 个 Meter） |
| `U30AirBattery/rainmeter_daemon.ps1` | 常驻守护进程：每秒查询设备 goform 接口并原子写 `live.txt` |
| `U30Air数据抓取实现文档及接口逆向.md` | 本文档（抓取方法 + 接口契约 + 字段字典 + 终版架构） |
| `README.md` | 项目介绍、项目截图、实现细节、安装方式、开源协议 |
| `LICENSE` | MIT 开源协议 |
| `screenshot.png` | README 引用的项目截图 |

> 开发阶段的抓包原始数据（`capture/*.jsonl`）、设备静态源码（`static/`）、
> 抓包与分析脚本（`tools/`、`capture/*.py`）等在发布版中已移除；
> 其全部关键结论已内联到本文档第 3~5 章与第 8 章。

## 附录 B：实测时间序列（独立验证）

`capture/verify_battery.py` 脱离浏览器复现接口（仅 Referer，无 Cookie、无密码）：

- 100 秒窗口：**33/33 成功**，电量稳定 **81%**、`charging=1`、信号 5 格、`loginfo=no`；
- RTT：**min 19 ms / avg 35 ms / max 107 ms**；
- 全过程电量演进（会话期间实测）：**79% → 80% → 81%**（设备持续充电，
  与 `battery_charging=1` 互相印证）；
- 原始记录：`capture/verify-series.jsonl`。
