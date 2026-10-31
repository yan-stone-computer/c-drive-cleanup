#Requires -Version 5.1
<#
  生成 C 盘清理行动清单（Markdown）：
  - 脚本可自动完成的项
  - 需显式开关的可选项与深度项
  - 只能手动做的迁移/设置（对齐视频里的 12 步）
#>
[CmdletBinding()]
param(
    [string]$OutFile,
    [int]$TopApps = 5
)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $PSCommandPath
$skillRoot = Split-Path -Parent $here
. (Join-Path $here 'lib.ps1')
. (Join-Path $here 'lib-audit.ps1')

$audit = Get-CleanupAudit -TopApps $TopApps
if (-not $OutFile) {
    $outDir = Join-Path $script:CleanupHome 'reports'
    if (-not (Test-PathSafe $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $OutFile = Join-Path $outDir 'cleanup-checklist.md'
}

$scanScript = Join-Path $here 'scan.ps1'
$cleanScript = Join-Path $here 'clean.ps1'

$v = $audit.Volume
$t = $audit.Totals
$safeRows = @($audit.Candidates | Where-Object { $_.Level -eq 'safe' -and -not $_.OptIn -and $_.Exists } | Sort-Object Bytes -Descending)
$optSafeRows = @($audit.Candidates | Where-Object { $_.Level -eq 'safe' -and $_.OptIn -and $_.Exists } | Sort-Object Bytes -Descending)
$byId = @{}
foreach ($c in $audit.Candidates) { $byId[$c.Id] = $c }
$deepRows = @()
foreach ($id in @('winsxs-dism', 'hibernate', 'windows-upgrade-temp', 'windows-old', 'restore-points')) {
    if ($byId.ContainsKey($id)) { $deepRows += $byId[$id] }
}

$sb = New-Object System.Text.StringBuilder
function Add-Line([string]$s = '') { [void]$sb.AppendLine($s) }

Add-Line '# C 盘清理清单'
Add-Line ''
Add-Line ('生成时间：' + $audit.GeneratedAt)
Add-Line ('系统：' + $audit.Os.Caption + '（build ' + $audit.Os.Build + '）  管理员权限：' + $(if ($audit.Elevated) { '是' } else { '否' }))
if ($v) {
    Add-Line ('C: 总 ' + (Format-Size $v.TotalBytes) + ' / 可用 ' + (Format-Size $v.FreeBytes) + '（' + $v.FreePercent + '%）')
}
Add-Line ''
Add-Line '## 一、脚本可自动清理（无需逐项开关）'
Add-Line ''
Add-Line '| 项目 | 体积 | 需要管理员 | 说明 |'
Add-Line '| --- | ---: | --- | --- |'
foreach ($c in $safeRows) {
    Add-Line ('| ' + $c.Name + ' | ' + (Format-Size $c.Bytes) + ' | ' + $(if ($c.RequiresAdmin) { '是' } else { '否' }) + ' | ' + $c.Note + ' |')
}
Add-Line ''
Add-Line '```powershell'
Add-Line ('powershell -NoProfile -ExecutionPolicy Bypass -File "' + $scanScript + '"                # 只读体检')
Add-Line ('powershell -NoProfile -ExecutionPolicy Bypass -File "' + $cleanScript + '" -Level safe            # 试运行')
Add-Line ('powershell -NoProfile -ExecutionPolicy Bypass -File "' + $cleanScript + '" -Level safe -Apply -Yes # 真正清理')
Add-Line '```'
Add-Line ''
Add-Line '## 二、需显式开关的可选项'
Add-Line ''
Add-Line '| 项目 | 体积 | 开关 |'
Add-Line '| --- | ---: | --- |'
foreach ($c in $optSafeRows) {
    $flag = switch ($c.Id) {
        'recycle-bin' { '-IncludeRecycleBin' }
        'browser-cache' { '-IncludeBrowserCache' }
        'wer-reports' { '-IncludeDiagnostics' }
        'cbs-logs' { '-IncludeDiagnostics' }
        'memory-dumps' { '-IncludeDiagnostics' }
        'wu-download' { '-ResetUpdateCache' }
        default { '-' }
    }
    Add-Line ('| ' + $c.Name + ' | ' + (Format-Size $c.Bytes) + ' | ' + $flag + ' |')
}
Add-Line ''
Add-Line '## 三、深度释放（需要管理员 + 逐项开关）'
Add-Line ''
Add-Line '| 项目 | 体积 | 开关 | 说明 |'
Add-Line '| --- | ---: | --- | --- |'
foreach ($c in $deepRows) {
    $flag = switch ($c.Id) {
        'winsxs-dism' { '-DismCleanup' }
        'hibernate' { '-DisableHibernate' }
        'windows-upgrade-temp' { '手动：存储/磁盘清理' }
        'windows-old' { '手动：存储/磁盘清理' }
        'restore-points' { '手动：系统保护' }
        default { '-' }
    }
    $size = if ($c.Id -eq 'winsxs-dism') { '1-5 GB' } elseif ($c.Id -eq 'restore-points') { '未知' } elseif ($c.Exists) { Format-Size $c.Bytes } else { '未检测到' }
    Add-Line ('| ' + $c.Name + ' | ' + $size + ' | ' + $flag + ' | ' + $c.Note + ' |')
}
Add-Line ''
Add-Line '管理员终端执行（会弹 UAC；只对可逆或经系统服务的项加开关）：'
Add-Line ''
Add-Line '```powershell'
Add-Line ('powershell -NoProfile -ExecutionPolicy Bypass -File "' + $cleanScript + '" -Level deep -Apply -Yes `')
Add-Line '  -DismCleanup -DisableHibernate'
Add-Line '```'
Add-Line ''
Add-Line '> 安全边界：`-DisableHibernate` 会关闭休眠和快速启动；DISM 不可在运行中强制终止。还原点、Windows.old 和升级残留只能从 Windows 官方界面手动删除。'
Add-Line ''
Add-Line '## 四、只能手动做的设置（视频里的长期预防）'
Add-Line ''
Add-Line '1. **迁移用户文件夹**（文档 / 下载 / 图片 / 桌面）：右键文件夹 → 属性 → 位置 → 移动 → 选 D 盘目录。'
Add-Line '2. **虚拟内存迁到其他分区**：设置 → 系统 → 系统信息 → 高级系统设置 → 性能设置 → 高级 → 更改虚拟内存；取消自动管理，C 盘设为“无分页文件”，目标盘设为“系统托管”，重启生效。'
if ($audit.Pagefile -and @($audit.Pagefile.Entries).Count -gt 0) {
    foreach ($p in $audit.Pagefile.Entries) {
        Add-Line ('   - 当前分页文件：' + $p.Name + '，' + $p.AllocatedMB + ' MB')
    }
}
Add-Line '3. **应用缓存搬家**：微信 / QQ / 网易云音乐等在各自设置里把存储路径改到 D 盘。'
foreach ($a in @($audit.AppCaches)) {
    Add-Line ('   - 检测到 ' + $a.Name + ' 数据目录 ' + (Format-Size $a.Bytes) + '：' + ($a.Paths -join '；'))
}
Add-Line '4. **安装软件不要一路下一步**：安装向导里把路径从 C:\Program Files 改成 D:\Apps。'
if ($audit.StorageSense) {
    $ss = $audit.StorageSense
    $state = if ($ss.Enabled) { '已开启' } else { '未开启' }
    Add-Line ('5. **存储感知**：当前' + $state + '。设置 → 系统 → 存储 → 存储感知；建议开启并设置每月清理临时文件、回收站。')
}
Add-Line ''
Add-Line '## 五、体积参考'
Add-Line ''
Add-Line '| 项目 | 体积 |'
Add-Line '| --- | ---: |'
foreach ($u in @($audit.UserFolders)) {
    Add-Line ('| 用户文件夹 · ' + $u.Name + ' | ' + (Format-Size $u.Bytes) + ' |')
}
if ($audit.TopApps.Count -gt 0) {
    foreach ($a in $audit.TopApps) {
        Add-Line ('| 已安装 · ' + $a.Name + ' | ' + (Format-Size $a.Bytes) + ' |')
    }
}
Add-Line ''
Add-Line '## 六、确认清单'
Add-Line ''
Add-Line '- [ ] 已备份重要文件（清理前）'
Add-Line '- [ ] 已运行 `scan.ps1` 并确认清单'
Add-Line '- [ ] 安全项已用 `clean.ps1 -Level safe -Apply -Yes` 清理'
Add-Line '- [ ] 深度项已在管理员终端逐项确认执行'
Add-Line '- [ ] 已设置存储感知 / 迁移缓存 / 迁移下载目录'
Add-Line ''
Add-Line ('预计普通权限默认可释放：' + (Format-Size $t.SafeUserBytes) + '；需开关的安全项：' + (Format-Size $t.RequiresOptInBytes) + '；管理员可再释放：' + (Format-Size ([long]$t.SafeAdminBytes + [long]$t.DeepAutoBytes)))

$text = $sb.ToString()
$dir = Split-Path -Parent $OutFile
if ($dir -and -not (Test-PathSafe $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$enc = New-Object System.Text.UTF8Encoding -ArgumentList $false
[IO.File]::WriteAllText($OutFile, $text, $enc)

Write-Output $text
Write-Output ''
Write-Output ('清单已保存: ' + $OutFile)
exit 0
