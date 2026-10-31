#Requires -Version 5.1
# c-drive-cleanup：体检数据组装与文本格式化（依赖 lib.ps1）

function Get-CleanupAudit {
    param(
        [switch]$SkipSizes,
        [int]$TopApps = 8
    )
    $start = Get-Date
    $candidates = Get-CleanupCandidates
    foreach ($c in $candidates) {
        if (-not $SkipSizes) { Update-CandidateSize $c | Out-Null }
    }

    $volume = Get-CDriveInfo
    $os = Get-OsInfo
    $admin = Test-IsAdmin
    $hibernate = Get-HibernateInfo
    $pagefile = Get-PagefileInfo
    $recycle = Get-RecycleBinStat
    $storageSense = Get-StorageSenseInfo
    $restore = Get-RestorePointInfo
    $userFolders = @(Get-UserFolderInfo)
    $appCaches = @(Get-AppCacheInfo)
    $appsTop = @(Get-TopApps -Top $TopApps)

    $manualBytes = [long]0
    foreach ($u in $userFolders) { $manualBytes += [long]$u.Bytes }

    $safeUser = [long]0
    $safeAdmin = [long]0
    $safeOptIn = [long]0
    $diagnostics = [long]0
    $deepAuto = [long]0
    $deepOptIn = [long]0
    $diagnosticIds = @('wer-reports', 'cbs-logs', 'memory-dumps')
    foreach ($c in $candidates) {
        if (-not $c.Exists) { continue }
        if ($c.Level -eq 'safe') {
            if ($c.OptIn) {
                $safeOptIn += $c.Bytes
                if ($c.Id -in $diagnosticIds) { $diagnostics += $c.Bytes }
            }
            elseif ($c.RequiresAdmin) { $safeAdmin += $c.Bytes }
            else { $safeUser += $c.Bytes }
        } elseif ($c.Level -eq 'deep') {
            if ($c.OptIn) { $deepOptIn += $c.Bytes } else { $deepAuto += $c.Bytes }
        }
    }

    $totals = [pscustomobject]@{
        SafeUserBytes     = $safeUser
        SafeAdminBytes    = $safeAdmin
        SafeOptInBytes    = $safeOptIn
        DiagnosticsBytes  = $diagnostics
        DeepAutoBytes     = $deepAuto
        DeepOptInBytes    = $deepOptIn
        ManualInfoBytes   = $manualBytes
        UserReclaimBytes  = $safeUser
        RequiresOptInBytes = $safeOptIn
        AdminReclaimBytes = $safeAdmin + $deepAuto
    }

    return [pscustomobject]@{
        Schema           = 'c-drive-cleanup/1'
        GeneratedAt      = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        ElapsedSeconds   = [math]::Round(((Get-Date) - $start).TotalSeconds, 1)
        Elevated         = $admin
        Os               = $os
        Volume           = $volume
        Candidates       = @($candidates)
        Totals           = $totals
        Hibernate        = $hibernate
        Pagefile         = $pagefile
        RecycleBin       = $recycle
        StorageSense     = $storageSense
        RestorePoints    = $restore
        UserFolders      = @($userFolders)
        AppCaches        = @($appCaches)
        TopApps          = @($appsTop)
    }
}

function Format-AuditText {
    param([object]$Audit)
    $lines = New-Object System.Collections.Generic.List[string]
    $v = $Audit.Volume
    $lines.Add("")
    $lines.Add("C 盘体检 - " + $Audit.GeneratedAt)
    if ($v) {
        $lines.Add(("C: 总 {0} / 可用 {1} ({2}%) / 已用 {3}" -f (Format-Size $v.TotalBytes), (Format-Size $v.FreeBytes), $v.FreePercent, (Format-Size $v.UsedBytes)))
    }
    $adminText = if ($Audit.Elevated) { '是' } else { '否（深度项不可用）' }
    $lines.Add(("管理员权限: {0}   系统: {1} (build {2})" -f $adminText, $Audit.Os.Caption, $Audit.Os.Build))
    $lines.Add("")

    $safeRows = @($Audit.Candidates | Where-Object { $_.Level -eq 'safe' -and -not $_.OptIn -and $_.Exists } | Sort-Object Bytes -Descending)
    $lines.Add("【可安全清理】")
    if ($safeRows.Count -eq 0) {
        $lines.Add("  （没有检测到可清理项）")
    } else {
        foreach ($c in $safeRows) {
            $tag = if ($c.RequiresAdmin) { ' [需管理员]' } else { '' }
            $lines.Add(("  {0,10}  {1}{2}  ({3} 项)" -f (Format-Size $c.Bytes), $c.Name, $tag, $c.Files))
        }
    }
    $lines.Add("")

    # 安全但不可逆的项（回收站 / 浏览器缓存）
    $optInSafe = @($Audit.Candidates | Where-Object { $_.OptIn -and $_.Level -eq 'safe' -and $_.Exists } | Sort-Object Bytes -Descending)
    if ($optInSafe.Count -gt 0) {
        $lines.Add("【需显式开关的可选项】")
        foreach ($c in $optInSafe) {
            $lines.Add(("  {0,10}  {1}  - {2}" -f (Format-Size $c.Bytes), $c.Name, $c.Note))
        }
        $lines.Add("  （诊断日志/转储默认保留；仅在排障结束后用 -IncludeDiagnostics）")
        $lines.Add("")
    }

    # 深度项：按 Id 取，体积未知的给出预期说明
    $deepIds = @('winsxs-dism', 'hibernate', 'windows-upgrade-temp', 'windows-old', 'restore-points')
    $byId = @{}
    foreach ($c in $Audit.Candidates) { $byId[$c.Id] = $c }
    $lines.Add("【深度释放（需管理员，逐项开关）】")
    $deepListed = $false
    foreach ($id in $deepIds) {
        if (-not $byId.ContainsKey($id)) { continue }
        $c = $byId[$id]
        if ($id -eq 'winsxs-dism') {
            $lines.Add("         -   组件存储清理 (DISM)  - 通常 1-5 GB，需 -DismCleanup")
            $deepListed = $true
            continue
        }
        if ($id -eq 'restore-points') {
            $rp = $Audit.RestorePoints
            if ($rp -and $rp.Count -gt 0) {
                $lines.Add(("  {0,10}  系统还原点  - 当前 {1} 个；删除请使用系统保护界面" -f '-', $rp.Count))
            } else {
                $lines.Add("         -   系统还原点  - 未检测到可读取的还原点；删除请使用系统保护界面")
            }
            $deepListed = $true
            continue
        }
        if (-not $c.Exists) { continue }
        $lines.Add(("  {0,10}  {1}  - {2}" -f (Format-Size $c.Bytes), $c.Name, $c.Note))
        $deepListed = $true
    }
    if (-not $Audit.Elevated) {
        $lines.Add("  （当前非管理员：深度项会被跳过；请用管理员终端重跑）")
    }
    if (-not $deepListed) { $lines.Add("  （没有检测到深度清理项）") }
    $lines.Add("")

    $lines.Add("【需要手动处理】")
    $lines.Add(("  用户文件夹合计 {0}：可迁移到其他分区（文档/下载/图片/桌面）" -f (Format-Size ($Audit.Totals.ManualInfoBytes))))
    if ($Audit.Pagefile -and @($Audit.Pagefile.Entries).Count -gt 0) {
        foreach ($p in $Audit.Pagefile.Entries) {
            $lines.Add(("  分页文件 {0}：{1} MB，建议迁到其他分区" -f $p.Name, $p.AllocatedMB))
        }
    }
    if ($Audit.AppCaches.Count -gt 0) {
        foreach ($a in $Audit.AppCaches) {
            $lines.Add(("  {0} 缓存 {1}：应用内改存储路径到其他分区" -f $a.Name, (Format-Size $a.Bytes)))
        }
    }
    if ($Audit.StorageSense -and -not $Audit.StorageSense.Enabled) {
        $lines.Add("  存储感知未开启：设置 → 系统 → 存储 → 打开存储感知")
    }
    $lines.Add("")

    $t = $Audit.Totals
    $lines.Add("合计")
    $lines.Add(("  普通权限默认可释放: {0}" -f (Format-Size $t.SafeUserBytes)))
    $lines.Add(("  需显式开关的安全项: {0}（回收站/浏览器缓存）" -f (Format-Size $t.RequiresOptInBytes)))
    $lines.Add(("  诊断证据（默认保留）: {0}（错误报告/CBS/崩溃转储）" -f (Format-Size $t.DiagnosticsBytes)))
    $lines.Add(("  管理员可再释放: {0}（不含 DISM 组件清理，通常再 1-5 GB）" -f (Format-Size ([long]$t.SafeAdminBytes + [long]$t.DeepAutoBytes))))
    $lines.Add(("  深度可选项（含仅手动项，不会自动删除）: {0}" -f (Format-Size $t.DeepOptInBytes)))
    $lines.Add(("  用户文件夹（建议迁移，不是垃圾）: {0}" -f (Format-Size $t.ManualInfoBytes)))
    $lines.Add(("  体检耗时 {0} 秒" -f $Audit.ElapsedSeconds))
    return ($lines -join [Environment]::NewLine)
}
