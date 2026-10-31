#Requires -Version 5.1
# c-drive-cleanup：可执行的深度动作（DISM / 休眠 / 更新下载缓存）

function Invoke-ProcessCapture {
    param(
        [string]$FilePath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSec = 0
    )
    $outFile = [IO.Path]::GetTempFileName()
    $errFile = [IO.Path]::GetTempFileName()
    $proc = $null
    $timedOut = $false
    try {
        $proc = Start-Process -FilePath $FilePath -ArgumentList $Arguments -NoNewWindow -PassThru `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile -ErrorAction Stop
        if ($TimeoutSec -gt 0) {
            if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
                $timedOut = $true
                try { $proc.Kill() } catch { }
                try { $proc.WaitForExit(10000) | Out-Null } catch { }
            }
        } else {
            $proc.WaitForExit()
        }
        $stdout = ''
        $stderr = ''
        if (Test-PathSafe $outFile) { try { $stdout = Get-Content -LiteralPath $outFile -Raw -Encoding Default -ErrorAction SilentlyContinue } catch { } }
        if (Test-PathSafe $errFile) { try { $stderr = Get-Content -LiteralPath $errFile -Raw -Encoding Default -ErrorAction SilentlyContinue } catch { } }
        $code = $null
        if ($proc -and $proc.HasExited) { $code = $proc.ExitCode }
        return [pscustomobject]@{
            ExitCode = $code
            Output   = (([string]$stdout + "`n" + [string]$stderr).Trim())
            TimedOut = $timedOut
        }
    } catch {
        return [pscustomobject]@{ ExitCode = $null; Output = $_.Exception.Message; TimedOut = $false }
    } finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Test-ServicingFailureOutput {
    param([string]$Text)
    if (-not $Text) { return $false }
    return ($Text -match '(?im)\bError:\s*\d+|Access is denied|HRESULT=80070005|0x80070005')
}

function Get-ShadowCopyCountFromText {
    param([string]$Text)
    if (-not $Text) { return 0 }
    return ([regex]::Matches($Text, '(?im)^\s*(Shadow Copy ID|卷影副本 ID)\s*:')).Count
}

function Test-ShadowCopyNoneFound {
    param([string]$Text)
    if (-not $Text) { return $false }
    return ($Text -match '(?im)No items found|No shadow copies|没有找到.*卷影|未找到.*卷影')
}

function Invoke-DismCleanup {
    $exe = Join-Path (Get-WindowsDir) 'System32\Dism.exe'
    if (-not (Test-PathSafe $exe)) {
        return [pscustomobject]@{ Status = 'failed'; Bytes = [long]0; Output = 'Dism.exe 不存在'; Seconds = 0 }
    }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    # 不设强制超时。中途终止组件服务可能损坏待处理的组件存储事务。
    $r = Invoke-ProcessCapture -FilePath $exe -Arguments @('/Online', '/Cleanup-Image', '/StartComponentCleanup')
    $sw.Stop()
    $tail = @()
    if ($r.Output) {
        $tail = @($r.Output -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 6)
    }
    $status = 'ok'
    if (Test-ServicingFailureOutput $r.Output) {
        $status = 'failed'
    } elseif ($null -ne $r.ExitCode -and $r.ExitCode -ne 0 -and $r.ExitCode -ne 3010) {
        $status = 'failed'
    }
    return [pscustomobject]@{
        Status  = $status
        Bytes   = [long]0
        Output  = ($tail -join ' | ')
        Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    }
}

function Invoke-HibernateOff {
    $file = 'C:\hiberfil.sys'
    $before = [long]0
    if (Test-PathSafe $file) { try { $before = [long](Get-Item -LiteralPath $file -Force -ErrorAction Stop).Length } catch { } }
    $exe = Join-Path (Get-WindowsDir) 'System32\powercfg.exe'
    $r = Invoke-ProcessCapture -FilePath $exe -Arguments @('-h', 'off')
    $after = if (Test-PathSafe $file) { 1 } else { 0 }
    $status = 'ok'
    if ($after -eq 1) { $status = 'failed' }
    elseif ($null -ne $r.ExitCode -and $r.ExitCode -ne 0) { $status = 'failed' }
    $freed = if ($after -eq 0) { $before } else { 0 }
    return [pscustomobject]@{
        Status = $status
        Bytes  = [long]$freed
        Output = if ($status -eq 'ok') { '已关闭休眠（hiberfil.sys 已删除，快速启动同时关闭）' } else { $r.Output }
    }
}

function Invoke-ResetUpdateCache {
    $download = Join-Path (Get-WindowsDir) 'SoftwareDistribution\Download'
    $status = 'failed'
    $freed = [long]0

    # 不停止 wuauserv/BITS：BITS 同时服务用户下载，Global 状态切换会产生额外后果。
    $rebootPending = Test-PathSafe 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    $tiWorker = @(Get-Process -Name TiWorker -ErrorAction SilentlyContinue).Count -gt 0
    if ($rebootPending -or $tiWorker) {
        return [pscustomobject]@{
            Status = 'skipped'
            Bytes  = [long]0
            Output = '检测到更新正在安装或等待重启，已跳过更新缓存清理'
        }
    }
    $bits = Get-Command Get-BitsTransfer -ErrorAction SilentlyContinue
    if (-not $bits) {
        return [pscustomobject]@{ Status = 'skipped'; Bytes = [long]0; Output = '无法核验 BITS 活动任务，安全跳过' }
    }
    try {
        $active = @(Get-BitsTransfer -AllUsers -ErrorAction Stop | Where-Object {
                $_.JobState -notin @('Transferred', 'Error', 'Cancelled')
            })
        if ($active.Count -gt 0) {
            return [pscustomobject]@{ Status = 'skipped'; Bytes = [long]0; Output = '检测到活动 BITS 任务，安全跳过' }
        }
    } catch {
        return [pscustomobject]@{ Status = 'skipped'; Bytes = [long]0; Output = '无法核验 BITS 任务，安全跳过' }
    }
    try {
        if (Test-PathSafe $download) {
            $before = [long]0
            $st = Get-DirStat $download
            if ($st) { $before = $st.Bytes }
            $null = Clear-FolderContents -Path $download -SkipRecentHours 24 -AllowedRoots @($download)
            $after = [long]0
            $st2 = Get-DirStat $download
            if ($st2) { $after = $st2.Bytes }
            $freed = [Math]::Max([long]0, $before - $after)
            $status = if ($after -lt $before) { 'ok' } else { 'partial' }
        } else {
            $status = 'missing'
        }
    } catch {
        $status = 'failed'
    }
    return [pscustomobject]@{
        Status = $status
        Bytes  = $freed
        Output = if ($status -eq 'ok') { '已清理 24 小时前的更新缓存；服务未被停止' } else { '更新缓存清理未完成' }
    }
}

function Test-WindowsSetupBusy {
    $pendingPaths = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired',
        'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\PendingFileRenameOperations'
    )
    foreach ($path in $pendingPaths) {
        if (Test-PathSafe $path) { return $true }
    }
    foreach ($name in @('TiWorker', 'SetupHost', 'SetupPlatform')) {
        if (@(Get-Process -Name $name -ErrorAction SilentlyContinue).Count -gt 0) { return $true }
    }
    return $false
}

function Invoke-RemoveUpgradeTemp {
    if (-not (Test-IsAdmin)) {
        return [pscustomobject]@{ Status = 'needs-admin'; Bytes = [long]0; Output = '需要管理员权限' }
    }
    if (Test-WindowsSetupBusy) {
        return [pscustomobject]@{ Status = 'skipped'; Bytes = [long]0; Output = '检测到 Windows 安装、更新或待重启任务，已跳过升级临时目录' }
    }
    $targets = @('C:\$Windows.~BT', 'C:\$Windows.~WS')
    $before = [long]0
    $after = [long]0
    foreach ($target in $targets) {
        if (-not (Test-PathSafe $target)) { continue }
        $st = Get-DirStat $target
        if ($st) { $before += $st.Bytes }
        try {
            $null = Remove-TreeBestEffort -Path $target -SkipRecentHours 0 -AllowedRoots @($target)
        } catch { }
        if (Test-PathSafe $target) {
            $st2 = Get-DirStat $target
            if ($st2) { $after += $st2.Bytes }
        }
    }
    $freed = [Math]::Max([long]0, $before - $after)
    return [pscustomobject]@{
        Status = if ($after -eq 0) { 'ok' } else { 'partial' }
        Bytes  = $freed
        Output = if ($after -eq 0) { "已清理升级临时文件，释放 $(Format-Size $freed)" } else { '部分升级临时文件仍被占用' }
    }
}

function Invoke-CleanmgrPreviousInstallations {
    param([int]$TimeoutMin = 60)
    $target = 'C:\Windows.old'
    if (-not (Test-IsAdmin)) {
        return [pscustomobject]@{ Status = 'needs-admin'; Bytes = [long]0; Output = '需要管理员权限' }
    }
    if (-not (Test-PathSafe $target)) {
        return [pscustomobject]@{ Status = 'missing'; Bytes = [long]0; Output = 'Windows.old 不存在' }
    }
    if (Test-WindowsSetupBusy) {
        return [pscustomobject]@{ Status = 'skipped'; Bytes = [long]0; Output = '检测到 Windows 安装/回滚任务，已跳过 Windows.old' }
    }
    $before = [long]0
    $st = Get-DirStat $target
    if ($st) { $before = $st.Bytes }
    $cleanmgr = Join-Path (Get-WindowsDir) 'System32\cleanmgr.exe'
    $stateKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\VolumeCaches\Previous Installations'
    if (-not (Test-PathSafe $cleanmgr) -or -not (Test-PathSafe $stateKey)) {
        return [pscustomobject]@{ Status = 'failed'; Bytes = [long]0; Output = 'Windows 磁盘清理组件不可用' }
    }
    $hadState = $false
    $oldState = $null
    try {
        $prop = Get-ItemProperty -Path $stateKey -Name 'StateFlags0099' -ErrorAction SilentlyContinue
        if ($null -ne $prop) { $hadState = $true; $oldState = $prop.StateFlags0099 }
        New-ItemProperty -Path $stateKey -Name 'StateFlags0099' -Value 2 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        $process = Start-Process -FilePath $cleanmgr -ArgumentList '/sagerun:99' -PassThru -WindowStyle Hidden -ErrorAction Stop
        $exited = $process.WaitForExit($TimeoutMin * 60 * 1000)
        if (-not $exited) {
            return [pscustomobject]@{ Status = 'partial'; Bytes = [long]0; Output = "磁盘清理仍在运行（超过 $TimeoutMin 分钟）；未执行任何并发兜底删除" }
        }
        if (-not (Test-PathSafe $target)) {
            return [pscustomobject]@{ Status = 'ok'; Bytes = $before; Output = 'Windows.old 已通过官方磁盘清理删除' }
        }
        return [pscustomobject]@{ Status = 'partial'; Bytes = [long]0; Output = '磁盘清理结束但 Windows.old 仍存在；请稍后通过系统存储设置重试' }
    } catch {
        return [pscustomobject]@{ Status = 'failed'; Bytes = [long]0; Output = $_.Exception.Message }
    } finally {
        try {
            if ($hadState) {
                New-ItemProperty -Path $stateKey -Name 'StateFlags0099' -Value $oldState -PropertyType DWord -Force | Out-Null
            } else {
                Remove-ItemProperty -Path $stateKey -Name 'StateFlags0099' -Force -ErrorAction SilentlyContinue
            }
        } catch { }
    }
}

function Invoke-RemoveAllShadowCopies {
    if (-not (Test-IsAdmin)) {
        return [pscustomobject]@{ Status = 'needs-admin'; Bytes = [long]0; Output = '需要管理员权限' }
    }
    $vssadmin = Join-Path (Get-WindowsDir) 'System32\vssadmin.exe'
    $listBefore = Invoke-ProcessCapture -FilePath $vssadmin -Arguments @('list', 'shadows', '/for=C:')
    $countBefore = Get-ShadowCopyCountFromText $listBefore.Output
    if ($countBefore -eq 0 -and -not (Test-ServicingFailureOutput $listBefore.Output)) {
        return [pscustomobject]@{ Status = 'ok'; Bytes = [long]0; Output = '未检测到 C 盘 VSS 卷影，无需删除' }
    }
    $r = Invoke-ProcessCapture -FilePath $vssadmin -Arguments @('delete', 'shadows', '/for=C:', '/all', '/quiet')
    $listAfter = Invoke-ProcessCapture -FilePath $vssadmin -Arguments @('list', 'shadows', '/for=C:')
    $countAfter = Get-ShadowCopyCountFromText $listAfter.Output
    $ok = ($null -ne $r.ExitCode -and $r.ExitCode -eq 0 -and $countAfter -eq 0)
    return [pscustomobject]@{
        Status = if ($ok) { 'ok' } elseif ($countAfter -lt $countBefore) { 'partial' } else { 'failed' }
        Bytes  = [long]0
        Output = if ($ok) { "已删除 C 盘全部 VSS 卷影（$countBefore -> 0，AcceptRisk 已确认）" } else { "卷影数量 $countBefore -> $countAfter；$($r.Output)" }
    }
}

function Get-ElevationCommand {
    param([string]$ScriptPath, [string]$ExtraArgs = '')
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $ScriptPath + '"'
    if ($ExtraArgs) { $argLine += ' ' + $ExtraArgs }
    return "Start-Process powershell -Verb RunAs -ArgumentList '" + $argLine.Replace("'", "''") + "'"
}
