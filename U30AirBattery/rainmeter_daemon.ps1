<#
    Rainmeter 数据守护进程（方案 B v11）—— v10 的 5 进程/秒方案在高负载机器上
    受 PowerShell 冷启动（实测恶化到 1.6~5.1 秒）拖累，节奏掉到 ~1.3/秒。
    v11 改为：本进程**常驻**，每秒真实查询一次设备 goform 接口（每秒查询 ✓），
    把 5 个字段拼成一行写入 live.txt（UTF-8 with BOM，临时文件+重试+清扫，
    绝不留垃圾）；Rainmeter 侧由 WebParser 每秒重读 live.txt 刷新显示。
      - 只有 1 个 PowerShell 进程（启动一次，之后不再有冷启动成本）；
      - 进程被杀/崩溃 -> 皮肤的 FinishAction 会自动重新拉起；
      - 行格式：电量|状态|运营商|信号|速率（| 分隔，5 组）。
#>
param(
    [string]$Device = 'http://192.168.0.1',
    [int]$IntervalMs = 1000,
    [int]$TimeoutSec = 3
)

$live = Join-Path $PSScriptRoot 'live.txt'

# 启动日志（每次启动记一笔）
try {
    $lg = Join-Path $PSScriptRoot 'daemon_invoked.log'
    if ((Test-Path $lg) -and (Get-Item $lg).Length -gt 32768) {
        Remove-Item $lg -Force -ErrorAction SilentlyContinue
    }
    [System.IO.File]::AppendAllText(
        $lg,
        ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + " start device=$Device interval=${IntervalMs}ms`r`n"),
        [System.Text.UTF8Encoding]::new($false))
}
catch { }

$cmd = 'mc_modem_main_state,battery_charging,battery_value,battery_vol_percent,network_signalbar,loginfo,' +
       'flux_realtime_tx_thrpt,flux_realtime_rx_thrpt,network_provider_fullname,network_type,' +
       'Z5g_rsrp,lte_rssi,network_rscp'

function Get-Line {
    try {
        $ts = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
        $url = "$Device/goform/goform_get_cmd_process?cmd=$cmd&multi_data=1&isTest=false&_=$ts"
        $req = [System.Net.WebRequest]::Create($url)
        $req.Method  = 'GET'
        $req.Timeout = $TimeoutSec * 1000
        $req.Proxy   = $null                    # 局域网设备不走系统代理
        $req.Referer = "$Device/"               # 关键头：唯一的“鉴权”
        $resp = $null; $sr = $null
        try {
            $resp = $req.GetResponse()
            $sr = New-Object System.IO.StreamReader($resp.GetResponseStream(), [System.Text.Encoding]::UTF8)
            $content = $sr.ReadToEnd()
        }
        finally {
            if ($sr) { $sr.Close() }
            if ($resp) { $resp.Close() }
        }
        $j = $content | ConvertFrom-Json
        if ($j.Error) { throw $j.Error }

        $pct = if ("$($j.battery_vol_percent)") { "$($j.battery_vol_percent)" } else { '0' }
        $st  = switch ("$($j.battery_charging)") { '1' { '充电中' } '2' { '已充满' } default { '放电中' } }

        $provider = "$($j.network_provider_fullname)"
        $ntype    = "$($j.network_type)"
        $car = if ($provider -and $ntype) { "运营商：$provider · $ntype" }
               elseif ($provider) { "运营商：$provider" }
               elseif ($ntype) { "运营商：$ntype" } else { '运营商：未知' }

        $bars = "$($j.network_signalbar)"
        $dbm  = $null
        foreach ($k in 'Z5g_rsrp', 'lte_rssi', 'network_rscp') {
            $v = "$($j.$k)"
            if ($v -and $v -ne '0') { $dbm = $v; break }
        }
        $sig = if ($dbm) { "信号：$bars/5 格 · $dbm dBm" } else { "信号：$bars/5 格" }

        $tx = 0.0; $rx = 0.0
        [double]::TryParse("$($j.flux_realtime_tx_thrpt)", [ref]$tx) | Out-Null
        [double]::TryParse("$($j.flux_realtime_rx_thrpt)", [ref]$rx) | Out-Null
        $inv = [System.Globalization.CultureInfo]::InvariantCulture
        $fmt = {
            param($b)
            $bits = $b * 8
            if ($bits -ge 1048576) { return ('{0} Mb/s' -f ($bits / 1048576).ToString('0.00', $inv)) }
            if ($bits -ge 1024)    { return ('{0} Kb/s' -f ($bits / 1024).ToString('0.00', $inv)) }
            return ('{0} b/s' -f [int]$bits)
        }
        $spd = "&opsv; $(& $fmt $rx)   &upsv; $(& $fmt $tx)"
        $spd = $spd.Replace('&opsv;', [string][char]0x2193).Replace('&upsv;', [string][char]0x2191)

        return "$pct|$st|$car|$sig|$spd"
    }
    catch {
        return '0|设备离线|设备离线|设备离线|设备离线'
    }
}

function Write-Live([string]$line) {
    $tmp = "$live.tmp.$PID"
    try {
        # UTF-8 无 BOM：WebParser 默认 CodePage=CP_UTF8 直接解码；
        # 带 BOM 会让正则第一组变成 "﻿100"，文字看着正常但
        # 电量条的数值解析会失败（实测教训）
        [System.IO.File]::WriteAllText($tmp, $line, [System.Text.UTF8Encoding]::new($false))
        $moved = $false
        for ($i = 0; $i -lt 5 -and -not $moved; $i++) {
            try {
                Move-Item -Path $tmp -Destination $live -Force -ErrorAction Stop
                $moved = $true
            }
            catch { Start-Sleep -Milliseconds 50 }   # 目标被读者短暂占用 -> 重试
        }
        if (-not $moved) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }
    catch {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}

# 启动时清扫历史孤儿 tmp（其他写入失败的遗留）
try {
    Get-ChildItem -Path $PSScriptRoot -Filter 'live.txt.tmp.*' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddSeconds(-5) } |
        Remove-Item -Force -ErrorAction SilentlyContinue
}
catch { }

# 主循环：每 IntervalMs 查询一次设备并刷新 live.txt（每秒查询 ✓）
while ($true) {
    $t0 = Get-Date
    Write-Live (Get-Line)
    $elapsed = [int]((Get-Date) - $t0).TotalMilliseconds
    $wait = $IntervalMs - $elapsed
    if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
}
