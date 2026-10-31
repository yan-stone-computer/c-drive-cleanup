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
    if ($null -ne $r.ExitCode -and $r.ExitCode -ne 0 -and $r.ExitCode -ne 3010) { $status = 'failed' }
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

function Get-ElevationCommand {
    param([string]$ScriptPath, [string]$ExtraArgs = '')
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $ScriptPath + '"'
    if ($ExtraArgs) { $argLine += ' ' + $ExtraArgs }
    return "Start-Process powershell -Verb RunAs -ArgumentList '" + $argLine.Replace("'", "''") + "'"
}
