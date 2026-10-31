#Requires -Version 5.1
<#
  c-drive-cleanup 执行器
  默认只做试运行（dry-run）。加 -Apply 才真正删除；加 -Yes 跳过交互确认。
  安全项在 -Level safe 下执行；深度项（DISM/休眠/还原点/Windows.old）只在 -Level deep 下且需对应开关。
#>
[CmdletBinding()]
param(
    [ValidateSet('safe', 'deep')][string]$Level = 'safe',
    [switch]$Apply,
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$Auto,
    [string[]]$Ids,
    [string[]]$SkipIds,
    [switch]$IncludeRecycleBin,
    [switch]$IncludeBrowserCache,
    [switch]$IncludeDiagnostics,
    [switch]$ResetUpdateCache,
    [switch]$DisableHibernate,
    # 为兼容旧命令保留；这些不可逆自动化操作会被明确拒绝。
    [switch]$PruneRestorePoints,
    [switch]$RemoveWindowsOld,
    [switch]$RemoveWindowsUpgradeTemp,
    [switch]$DismCleanup,
    [switch]$SkipWuCache,
    [switch]$CreateRestorePoint,
    [int]$SkipRecentHours = 24,
    [string]$LogDir,
    [switch]$Json
)

$ErrorActionPreference = 'Continue'
$script:JsonMode = $false
$here = Split-Path -Parent $PSCommandPath
. (Join-Path $here 'lib.ps1')
. (Join-Path $here 'lib-audit.ps1')
. (Join-Path $here 'lib-actions.ps1')

# ------------------------------------------------------------ 参数安全闸

$irreversibleAutomation = $PruneRestorePoints -or $RemoveWindowsOld -or $RemoveWindowsUpgradeTemp
if ($irreversibleAutomation) {
    Write-Host '拒绝执行：还原点、Windows.old 与 Windows 升级残留的自动删除已停用。' -ForegroundColor Red
    Write-Host '这些操作会丢失系统回退能力或误伤非还原点卷影；请使用 Windows 存储/系统保护界面手动确认。'
    exit 1
}

$autoDestructive = $IncludeRecycleBin -or $IncludeBrowserCache -or $IncludeDiagnostics -or `
    $ResetUpdateCache -or $DisableHibernate -or $DismCleanup
if ($Auto) {
    if ($Level -eq 'deep' -or $autoDestructive) {
        Write-Host '拒绝执行：-Auto 只允许安全、无需显式开关的项；不可逆/深清项请显式 -Apply -Yes 加开关。' -ForegroundColor Red
        exit 1
    }
    $Apply = $true
    $Yes = $true
}
$doApply = $Apply -and -not $DryRun
if ($doApply -and -not $Yes) {
    Write-Host '拒绝执行：真实删除必须同时带 -Yes（或使用 -Auto -Level safe）。' -ForegroundColor Red
    Write-Host '建议流程：先运行 scan.ps1 体检，确认清单后再执行清理。'
    exit 1
}
if ($Json) {
    # JSON 模式下所有提示走 stderr，保证 stdout 只有 JSON
    $script:JsonMode = $true
}
function Write-Human {
    param([string]$Text, [string]$Color = 'Gray')
    if ($script:JsonMode) { return }
    Write-Host $Text -ForegroundColor $Color
}

$admin = Test-IsAdmin
$freeBefore = 0
$vol0 = Get-CDriveInfo
if ($vol0) { $freeBefore = $vol0.FreeBytes }

$candidates = Get-CleanupCandidates
if ($Ids) {
    $Ids = @($Ids | ForEach-Object { ([string]$_).Split(',') } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
if ($SkipIds) {
    $SkipIds = @($SkipIds | ForEach-Object { ([string]$_).Split(',') } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
$knownIds = @($candidates | ForEach-Object { $_.Id })
$unknownIds = @($Ids | Where-Object { $_ -notin $knownIds })
if ($unknownIds.Count -gt 0) {
    Write-Host ('拒绝执行：未知清理项 ' + ($unknownIds -join ', ')) -ForegroundColor Red
    exit 1
}
$wanted = New-Object System.Collections.Generic.List[object]

foreach ($c in $candidates) {
    if ($Ids -and $Ids.Count -gt 0 -and ($Ids -notcontains $c.Id)) { continue }
    if ($SkipIds -and ($SkipIds -contains $c.Id)) { continue }
    if ($c.Kind -in @('pagefile')) { continue } # 只做检测，清理留给手动步骤
    if ($c.Level -eq 'deep' -and $Level -ne 'deep') { continue }
    if ($c.Level -eq 'info') { continue }
    if ($c.Kind -eq 'manual') {
        $wanted.Add([pscustomobject]@{ Candidate = $c; SkipReason = 'needs-manual' })
        continue
    }

    # 可选项目必须显式开启
    if ($c.OptIn) {
        $enabled = switch ($c.Id) {
            'recycle-bin' { [bool]$IncludeRecycleBin }
            'browser-cache' { [bool]$IncludeBrowserCache }
            'wer-reports' { [bool]$IncludeDiagnostics }
            'cbs-logs' { [bool]$IncludeDiagnostics }
            'memory-dumps' { [bool]$IncludeDiagnostics }
            'wu-download' { [bool]$ResetUpdateCache }
            'hibernate' { [bool]$DisableHibernate }
            'winsxs-dism' { [bool]$DismCleanup }
            default { $false }
        }
        if (-not $enabled) {
            $wanted.Add([pscustomobject]@{ Candidate = $c; SkipReason = 'needs-flag' })
            continue
        }
    }
    if ($c.Id -eq 'wu-download' -and $SkipWuCache) {
        $wanted.Add([pscustomobject]@{ Candidate = $c; SkipReason = 'needs-flag' })
        continue
    }
    if ($c.RequiresAdmin -and -not $admin) {
        $wanted.Add([pscustomobject]@{ Candidate = $c; SkipReason = 'needs-admin' })
        continue
    }
    $wanted.Add([pscustomobject]@{ Candidate = $c; SkipReason = '' })
}

# ------------------------------------------------------------ 统计目标体积

Write-Human ''
Write-Human ("清理计划（{0}）" -f $(if ($doApply) { '真实执行' } else { '试运行，不删除' })) 'Cyan'
Write-Human ("模式: Level {0} | 管理员: {1} | 跳过近期文件: {2} 小时" -f $Level, $(if ($admin) { '是' } else { '否' }), $SkipRecentHours)
Write-Human ''

$plan = New-Object System.Collections.Generic.List[object]
foreach ($w in $wanted) {
    $c = $w.Candidate
    Update-CandidateSize $c | Out-Null
    if ($w.SkipReason) {
        $plan.Add([pscustomobject]@{ Candidate = $c; SkipReason = $w.SkipReason; BytesBefore = $c.Bytes })
        continue
    }
    if (-not $c.Exists -and $c.Kind -notin @('dism', 'vss')) {
        $plan.Add([pscustomobject]@{ Candidate = $c; SkipReason = 'missing'; BytesBefore = $c.Bytes })
        continue
    }
    $plan.Add([pscustomobject]@{ Candidate = $c; SkipReason = ''; BytesBefore = $c.Bytes })
}

function Get-EligibleDryRunBytes {
    param([object]$Candidate, [int]$RecentHours)
    if ($Candidate.Kind -eq 'tree-contents') {
        $total = [long]0
        foreach ($path in @($Candidate.Paths)) {
            if (-not (Test-PathSafe $path)) { continue }
            $r = Clear-FolderContents -Path $path -SkipRecentHours $RecentHours -DryRun -AllowedRoots @($path)
            if ($r.Status -in @('ok', 'partial')) { $total += [long]$r.Bytes }
        }
        return $total
    }
    if ($Candidate.Kind -eq 'files') {
        $cutoff = if ($RecentHours -gt 0) { (Get-Date).AddHours(-$RecentHours) } else { $null }
        $total = [long]0
        foreach ($path in @($Candidate.Paths)) {
            if (-not (Test-PathSafe $path)) { continue }
            $item = Get-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            if (-not $item) { continue }
            if (-not $item.PSIsContainer) {
                if (-not $cutoff -or $item.LastWriteTime -le $cutoff) { $total += [long]$item.Length }
                continue
            }
            foreach ($pattern in @($Candidate.Patterns)) {
                foreach ($f in @(Get-ChildItem -LiteralPath $path -Filter $pattern -File -Force -ErrorAction SilentlyContinue)) {
                    if (-not $cutoff -or $f.LastWriteTime -le $cutoff) { $total += [long]$f.Length }
                }
            }
        }
        return $total
    }
    return [long]$Candidate.Bytes
}

$plannedBytes = [long]0
foreach ($p in $plan) {
    if (-not $p.SkipReason) {
        $plannedBytes += if ($doApply) { [long]$p.BytesBefore } else { Get-EligibleDryRunBytes -Candidate $p.Candidate -RecentHours $SkipRecentHours }
    }
}
Write-Human ("预计可释放：约 {0}（{1} 项）" -f (Format-Size $plannedBytes), @($plan | Where-Object { -not $_.SkipReason }).Count) 'Green'

# ------------------------------------------------------------ 深度前创建还原点

if ($doApply -and $Level -eq 'deep' -and $admin -and $CreateRestorePoint) {
    Write-Human ''
    Write-Human '正在创建系统还原点（深度清理前保护）...' 'Yellow'
    try {
        Checkpoint-Computer -Description 'c-drive-cleanup 深度清理前' -RestorePointType 'MODIFY_SETTINGS' -ErrorAction Stop
        Write-Human '  还原点已创建' 'Green'
    } catch {
        Write-Human ('  创建失败（系统保护可能未开启）：' + $_.Exception.Message) 'Yellow'
    }
}

# ------------------------------------------------------------ 执行

$results = New-Object System.Collections.Generic.List[object]
$index = 0
foreach ($p in $plan) {
    $c = $p.Candidate
    $index++
    $name = $c.Name
    if ($p.SkipReason) {
        $results.Add([pscustomobject]@{
                Id = $c.Id; Name = $name; Level = $c.Level; Status = $p.SkipReason
                BytesBefore = [long]$p.BytesBefore; BytesFreed = [long]0; FilesDeleted = 0
                Detail = $c.Note; Error = ''
            })
        continue
    }

    Write-Human ("[{0}/{1}] {2} ..." -f $index, $plan.Count, $name)
    $before = [long]$p.BytesBefore
    $status = 'ok'
    $detail = ''
    $err = ''
    $freed = [long]0
    $filesDeleted = 0

    if (-not $doApply) {
        $status = 'dry-run'
        $detail = '试运行，未执行'
        $eligible = Get-EligibleDryRunBytes -Candidate $c -RecentHours $SkipRecentHours
        $results.Add([pscustomobject]@{
                Id = $c.Id; Name = $name; Level = $c.Level; Status = $status
                BytesBefore = $before; BytesFreed = $eligible; FilesDeleted = 0
                Detail = $detail; Error = ''
            })
        continue
    }

    try {
        switch ($c.Kind) {
            'tree-contents' {
                $skippedTotal = 0
                $hadError = ''
                foreach ($path in @($c.Paths)) {
                    if (-not (Test-PathSafe $path)) { continue }
                    $r = Clear-FolderContents -Path $path -SkipRecentHours $SkipRecentHours -AllowedRoots @($path)
                    $filesDeleted += $r.FilesDeleted
                    $skippedTotal += $r.FilesSkipped
                    if ($r.Status -eq 'failed') { $hadError = $r.Error; $status = 'partial' }
                }
                $after = [long]0
                $stat = Get-PathStat -Paths @($c.Paths)
                if ($stat) { $after = $stat.Bytes }
                $freed = [Math]::Max([long]0, $before - $after)
                if ($freed -gt 0) {
                    $detail = "释放 $(Format-Size $freed)"
                    if ($skippedTotal -gt 0) { $detail += "（跳过 $skippedTotal 个占用文件）" }
                } elseif ($hadError) {
                    $status = 'partial'; $detail = "失败：$hadError"
                } elseif ($skippedTotal -gt 0) {
                    $status = 'partial'; $detail = "没有释放，$skippedTotal 个文件被占用"
                } else {
                    $detail = '目录为空，无需清理'
                }
            }
            'files' {
                $fileSkipped = 0
                foreach ($path in @($c.Paths)) {
                    if (-not (Test-PathSafe $path)) { continue }
                    $null = Assert-SafeDeletePath -Path $path -AllowedRoots @($path) -AllowRootItself
                    $item = $null
                    try { $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop } catch { continue }
                    if ($item.PSIsContainer) {
                        foreach ($pat in @($c.Patterns)) {
                            $files = @()
                            try { $files = @(Get-ChildItem -LiteralPath $path -Filter $pat -File -Force -ErrorAction SilentlyContinue) } catch { }
                            foreach ($f in $files) {
                                try {
                                    if ($SkipRecentHours -gt 0 -and $f.LastWriteTime -gt (Get-Date).AddHours(-$SkipRecentHours)) { $fileSkipped++; continue }
                                    $len = [long]$f.Length
                                    [IO.File]::Delete($f.FullName)
                                    $freed += $len
                                    $filesDeleted++
                                } catch { $fileSkipped++ }
                            }
                        }
                    } else {
                        try {
                            $len = [long]$item.Length
                            [IO.File]::Delete($item.FullName)
                            $freed += $len
                            $filesDeleted++
                        } catch { $fileSkipped++ }
                    }
                }
                $detail = "删除 $filesDeleted 个文件"
                if ($freed -eq 0 -and $fileSkipped -gt 0) { $status = 'partial'; $detail = "没有释放，$fileSkipped 个文件被占用" }
                elseif ($freed -eq 0) { $detail = '没有匹配文件，无需清理' }
            }
            'recycle' {
                $r = Clear-RecycleBinSafe
                $freed += [long]$r.Bytes
                $detail = '回收站已清空'
                if ($r.Status -ne 'ok') { $status = 'partial'; $err = $r.Error }
            }
            'wu-cache' {
                $r = Invoke-ResetUpdateCache
                $freed += [long]$r.Bytes
                $detail = $r.Output
                if ($r.Status -ne 'ok') { $status = 'partial' }
            }
            'hibernate' {
                $r = Invoke-HibernateOff
                $freed += [long]$r.Bytes
                $detail = $r.Output
                if ($r.Status -ne 'ok') { $status = 'partial'; $err = $r.Output }
            }
            'dism' {
                Write-Human '  组件清理可能需要 5-20 分钟，请勿关闭窗口...' 'Yellow'
                $r = Invoke-DismCleanup
                $detail = $r.Output
                $status = if ($r.Status -eq 'ok') { 'ok' } else { 'partial' }
            }
            default {
                $status = 'skipped'
                $detail = '不支持的清理类型'
            }
        }
    } catch {
        $status = 'failed'
        $err = $_.Exception.Message
    }

    Write-Human ("      {0}  {1}" -f (Get-StatusText $status), $detail) $(if ($status -eq 'ok') { 'Green' } else { 'Yellow' })
    $results.Add([pscustomobject]@{
            Id = $c.Id; Name = $name; Level = $c.Level; Status = $status
            BytesBefore = $before; BytesFreed = [long]$freed; FilesDeleted = $filesDeleted
            Detail = $detail; Error = $err
        })
}

# ------------------------------------------------------------ 汇总

$totalFreed = [long]0
foreach ($r in $results) { if ($r.Status -in @('ok', 'partial', 'dry-run')) { $totalFreed += [long]$r.BytesFreed } }
$freeAfter = $freeBefore
if ($doApply) {
    $info = Get-CDriveInfo
    if ($info) { $freeAfter = $info.FreeBytes }
}
$actualDelta = [long]($freeAfter - $freeBefore)

$summary = [pscustomobject]@{
    Schema = 'c-drive-cleanup-clean/1'
    SafetyProfile = 'safe-v2'
    GeneratedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Level = $Level
    Applied = $doApply
    Elevated = $admin
    FreeBytesBefore = [long]$freeBefore
    FreeBytesAfter = [long]$freeAfter
    FreeSpaceDelta = $actualDelta
    TotalFreedBytes = $totalFreed
    SkipRecentHours = $SkipRecentHours
    Results = $results.ToArray()
    ElevationHint = if (-not $admin -and @($results | Where-Object { $_.Status -eq 'needs-admin' }).Count -gt 0) {
        # 只提权重跑“同等范围”；深清项默认不执行，需要用户按需追加开关
        Get-ElevationCommand -ScriptPath (Join-Path $here 'clean.ps1') -ExtraArgs ('-Level ' + $Level + ' -Apply -Yes')
    } else { '' }
}

$reportDir = if ($LogDir) { $LogDir } else { Join-Path $script:CleanupHome 'reports' }
if (-not (Test-PathSafe $reportDir)) { New-Item -ItemType Directory -Path $reportDir -Force | Out-Null }
$reportPath = Join-Path $reportDir ("clean-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
Write-JsonText -Object $summary -Path $reportPath
Write-JsonText -Object $summary -Path (Join-Path $reportDir 'latest-clean.json')

if ($Json) {
    Write-Output ($summary | ConvertTo-Json -Depth 8)
} else {
    Write-Human ''
    Write-Human ("== 清理结果（{0}）==" -f $(if ($doApply) { '已执行' } else { '试运行' })) 'Cyan'
    foreach ($r in ($results | Where-Object { $_.Status -in @('ok', 'partial', 'dry-run') })) {
        Write-Human ("  {0,10}  {1}" -f (Format-Size $r.BytesFreed), $r.Name) 'Gray'
    }
    $skipped = @($results | Where-Object { $_.Status -notin @('ok', 'partial', 'dry-run') })
    if ($skipped.Count -gt 0) {
        Write-Human ''
        Write-Human '跳过/未执行：' 'Yellow'
        foreach ($r in $skipped) {
            $reason = Get-StatusText $r.Status
            $hint = ''
            if ($r.Status -eq 'needs-admin') { $hint = '（用管理员终端重跑）' }
            if ($r.Status -eq 'needs-flag' -and $r.Id -eq 'hibernate') { $hint = '（加 -DisableHibernate）' }
            if ($r.Status -eq 'needs-flag' -and $r.Id -eq 'recycle-bin') { $hint = '（加 -IncludeRecycleBin）' }
            if ($r.Status -eq 'needs-flag' -and $r.Id -eq 'browser-cache') { $hint = '（加 -IncludeBrowserCache）' }
            if ($r.Status -eq 'needs-flag' -and $r.Id -in @('wer-reports', 'cbs-logs', 'memory-dumps')) { $hint = '（加 -IncludeDiagnostics）' }
            if ($r.Status -eq 'needs-flag' -and $r.Id -eq 'wu-download') { $hint = '（加 -ResetUpdateCache）' }
            if ($r.Status -eq 'needs-flag' -and $r.Id -eq 'winsxs-dism') { $hint = '（加 -DismCleanup）' }
            if ($r.Status -eq 'needs-manual') { $hint = '（自动删除已停用，请按手动清单操作）' }
            Write-Human ("  {0}：{1}{2}" -f $r.Name, $reason, $hint) 'Yellow'
        }
    }
    Write-Human ''
    if ($doApply) {
        Write-Human ("C: 可用 {0} -> {1}（实际增加 {2}）" -f (Format-Size $freeBefore), (Format-Size $freeAfter), (Format-Size ([Math]::Max([long]0, $actualDelta)))) 'Green'
    } else {
        Write-Human ("试运行完成，预计可释放 {0}。确认后加 -Apply -Yes 执行。" -f (Format-Size $totalFreed)) 'Green'
    }
    if ($summary.ElevationHint) {
        Write-Human ''
        Write-Human '需要管理员才能执行的项，可以这样重跑（会弹 UAC）：' 'Yellow'
        Write-Human ('  ' + $summary.ElevationHint)
    }
    Write-Human ''
    Write-Human ('报告: ' + $reportPath)
}

# 退出码：0 全部执行且无异常；1 参数/致命错误；2 有跳过/部分完成/失败
$problem = @($results | Where-Object { $_.Status -in @('partial', 'failed', 'needs-admin', 'needs-flag', 'needs-manual', 'missing', 'skipped') }).Count
if ($problem -gt 0) { exit 2 } else { exit 0 }
