#Requires -Version 5.1
<#
  c-drive-cleanup 执行器
  默认只做试运行（dry-run）。加 -Apply 才真正删除；加 -Yes 跳过交互确认。
  安全项在 -Level safe 下执行；深度项（DISM/休眠/还原点/Windows.old）只在 -Level deep 下且需对应开关。
  -FullCleanup 还要求 -AcceptRisk，并由用户自行确认 UAC。
#>
[CmdletBinding()]
param(
    [ValidateSet('safe', 'deep')][string]$Level = 'safe',
    [switch]$Apply,
    [switch]$DryRun,
    [switch]$Yes,
    [switch]$Auto,
    [string[]]$Ids = @(),
    [string[]]$SkipIds = @(),
    [switch]$IncludeRecycleBin,
    [switch]$IncludeBrowserCache,
    [switch]$IncludeDiagnostics,
    [switch]$ResetUpdateCache,
    [switch]$AllSafe,
    [switch]$FullCleanup,
    [switch]$AcceptRisk,
    [switch]$DisableHibernate,
    # 不可逆项仅在 -AcceptRisk 时允许。
    [switch]$RemoveAllShadowCopies,
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

if ($FullCleanup -and -not $AcceptRisk) {
    Write-Host '拒绝执行：-FullCleanup 必须同时带 -AcceptRisk，确认已知晓不可逆数据丢失风险。' -ForegroundColor Red
    exit 1
}
if ($FullCleanup) {
    $Level = 'deep'
    $AllSafe = $true
    $IncludeRecycleBin = $true
    $IncludeDiagnostics = $true
    $ResetUpdateCache = $true
    $DisableHibernate = $true
    $RemoveAllShadowCopies = $true
    $RemoveWindowsOld = $true
    $RemoveWindowsUpgradeTemp = $true
    $DismCleanup = $true
    $CreateRestorePoint = $false # VSS 全删会连同刚创建的还原点一起删除
    if (-not $PSBoundParameters.ContainsKey('SkipRecentHours')) { $SkipRecentHours = 0 }
}

if ($AllSafe) {
    # 只启用可在不破坏回退数据、不停止共享服务的前提下重建的缓存。
    $IncludeBrowserCache = $true
    $ResetUpdateCache = $true
}

$irreversibleAutomation = $RemoveAllShadowCopies -or $PruneRestorePoints -or $RemoveWindowsOld -or $RemoveWindowsUpgradeTemp
if ($irreversibleAutomation -and -not $AcceptRisk) {
    Write-Host '拒绝执行：还原点/卷影、Windows.old 或 Windows 升级残留需要 -AcceptRisk。' -ForegroundColor Red
    Write-Host '这些操作会丢失系统回退或备份数据。只有用户明确授权管理员权限并承担后果时才能继续。'
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
$Ids = @(ConvertTo-CleanupIdList -Values $Ids)
$SkipIds = @(ConvertTo-CleanupIdList -Values $SkipIds)
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
            'windows-old' { [bool]($AcceptRisk -and $RemoveWindowsOld) }
            'windows-upgrade-temp' { [bool]($AcceptRisk -and $RemoveWindowsUpgradeTemp) }
            'restore-points' { [bool]($AcceptRisk -and ($RemoveAllShadowCopies -or $PruneRestorePoints)) }
            default { $false }
        }
        if (-not $enabled) {
            $wanted.Add([pscustomobject]@{ Candidate = $c; SkipReason = 'needs-flag' })
            continue
        }
    }
    if ($c.Kind -eq 'manual' -and -not $AcceptRisk) {
        $wanted.Add([pscustomobject]@{ Candidate = $c; SkipReason = 'needs-manual' })
        continue
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
if ($FullCleanup) {
    Write-Human '风险模式：-FullCleanup + -AcceptRisk 已启用；将尝试不可逆系统清理，且 UAC 仍须由你确认。' 'Red'
    if ($PSBoundParameters.ContainsKey('CreateRestorePoint')) {
        Write-Human '  -CreateRestorePoint 已忽略：全清理会删除 C 盘全部 VSS 卷影。' 'Yellow'
    }
}

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

    $effectiveKind = if ($AcceptRisk -and $c.FullKind) { $c.FullKind } else { $c.Kind }
    try {
        switch ($effectiveKind) {
            'tree-contents' {
                $skippedTotal = 0
                $recentTotal = 0
                $lockedTotal = 0
                $deniedTotal = 0
                $failedTotal = 0
                $hadError = ''
                foreach ($path in @($c.Paths)) {
                    if (-not (Test-PathSafe $path)) { continue }
                    $r = Clear-FolderContents -Path $path -SkipRecentHours $SkipRecentHours -AllowedRoots @($path)
                    $filesDeleted += $r.FilesDeleted
                    $skippedTotal += $r.FilesSkipped
                    $recentTotal += $r.FilesRecent
                    $lockedTotal += $r.FilesLocked
                    $deniedTotal += $r.FilesDenied
                    $failedTotal += $r.FilesFailed
                    if ($r.Status -eq 'failed') { $hadError = $r.Error; $status = 'partial' }
                }
                $after = [long]0
                $stat = Get-PathStat -Paths @($c.Paths)
                if ($stat) { $after = $stat.Bytes }
                $freed = [Math]::Max([long]0, $before - $after)
                if ($freed -gt 0) {
                    $detail = "释放 $(Format-Size $freed)"
                    if ($skippedTotal -gt 0 -or $recentTotal -gt 0) {
                        $detail += "（跳过：占用 $lockedTotal，权限 $deniedTotal，其他 $failedTotal；近期保留 $recentTotal）"
                    }
                } elseif ($hadError) {
                    $status = 'partial'; $detail = "失败：$hadError"
                } elseif ($skippedTotal -gt 0) {
                    $status = 'partial'; $detail = "没有释放（占用 $lockedTotal，权限 $deniedTotal，其他 $failedTotal；近期保留 $recentTotal）"
                } else {
                    $detail = '目录为空，无需清理'
                }
            }
            'files' {
                $fileSkipped = 0
                $fileRecent = 0
                $fileLocked = 0
                $fileDenied = 0
                $fileFailed = 0
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
                                    if ($SkipRecentHours -gt 0 -and $f.LastWriteTime -gt (Get-Date).AddHours(-$SkipRecentHours)) { $fileRecent++; continue }
                                    $len = [long]$f.Length
                                    Remove-FileForCleanup -Path $f.FullName
                                    $freed += $len
                                    $filesDeleted++
                                } catch {
                                    $fileSkipped++
                                    switch (Get-CleanupFailureKind $_) {
                                        'locked' { $fileLocked++ }
                                        'denied' { $fileDenied++ }
                                        default { $fileFailed++ }
                                    }
                                }
                            }
                        }
                    } else {
                        try {
                            $len = [long]$item.Length
                            Remove-FileForCleanup -Path $item.FullName
                            $freed += $len
                            $filesDeleted++
                        } catch {
                            $fileSkipped++
                            switch (Get-CleanupFailureKind $_) {
                                'locked' { $fileLocked++ }
                                'denied' { $fileDenied++ }
                                default { $fileFailed++ }
                            }
                        }
                    }
                }
                $detail = "删除 $filesDeleted 个文件"
                if ($freed -eq 0 -and ($fileSkipped -gt 0 -or $fileRecent -gt 0)) {
                    $status = 'partial'
                    $detail = "没有释放（占用 $fileLocked，权限 $fileDenied，其他 $fileFailed；近期保留 $fileRecent）"
                }
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
            'tree-remove' {
                $r = Invoke-RemoveUpgradeTemp
                $freed += [long]$r.Bytes
                $detail = $r.Output
                if ($r.Status -ne 'ok') { $status = 'partial' }
            }
            'cleanmgr-old' {
                Write-Human '  正在调用 Windows 官方磁盘清理处理 Windows.old，请勿关闭窗口...' 'Yellow'
                $r = Invoke-CleanmgrPreviousInstallations
                $freed += [long]$r.Bytes
                $detail = $r.Output
                if ($r.Status -ne 'ok') { $status = 'partial' }
            }
            'vss-all' {
                Write-Human '  正在删除 C 盘全部 VSS 卷影；此操作已由用户明确承担风险...' 'Red'
                $r = Invoke-RemoveAllShadowCopies
                $detail = $r.Output
                if ($r.Status -ne 'ok') { $status = 'partial' }
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
    SafetyProfile = if ($FullCleanup) { 'safe-v2+full-risk' } elseif ($AllSafe) { 'safe-v2+allsafe' } else { 'safe-v2' }
    GeneratedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Level = $Level
    Applied = $doApply
    Elevated = $admin
    FullCleanup = [bool]$FullCleanup
    AcceptRisk = [bool]$AcceptRisk
    FreeBytesBefore = [long]$freeBefore
    FreeBytesAfter = [long]$freeAfter
    FreeSpaceDelta = $actualDelta
    TotalFreedBytes = $totalFreed
    SkipRecentHours = $SkipRecentHours
    Results = $results.ToArray()
    ElevationHint = if (-not $admin -and @($results | Where-Object { $_.Status -eq 'needs-admin' }).Count -gt 0) {
        $rerunArgs = "-Level $Level -Apply -Yes"
        if ($AllSafe) { $rerunArgs += ' -AllSafe' }
        if ($FullCleanup) { $rerunArgs += ' -FullCleanup -AcceptRisk' }
        if ($SkipRecentHours -ne 24) { $rerunArgs += " -SkipRecentHours $SkipRecentHours" }
        Get-ElevationCommand -ScriptPath (Join-Path $here 'clean.ps1') -ExtraArgs $rerunArgs
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
