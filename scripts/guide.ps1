#Requires -Version 5.1
<#
  生成 C 盘清理行动清单：
  - 代理可直接执行的安全缓存
  - 需要管理员或显式风险确认的项
  - 最近一次清理未完成项及精确路径、原因、手动步骤
#>
[CmdletBinding()]
param(
    [string]$OutFile,
    [int]$TopApps = 5
)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $PSCommandPath
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

function Get-ManualGuidance([string]$Id) {
    $local = Get-LocalAppDataDir
    switch ($Id) {
        'user-temp' {
            return [pscustomobject]@{
                Path = (Join-Path $local 'Temp')
                Reason = '应用或代理进程仍在读写文件；删除正在使用的临时文件可能破坏未保存工作。'
                Action = '退出相关应用后重试；仍有锁定文件时注销或重启，再运行本 skill。不要强制结束未知进程。'
            }
        }
        'thumbnail-cache' {
            return [pscustomobject]@{
                Path = (Join-Path $local 'Microsoft\Windows\Explorer')
                Reason = 'Explorer 持有 thumbcache/iconcache 数据库，运行中通常无法删除。'
                Action = '关闭资源管理器窗口后重试；仍锁定可注销或重启。重启 Explorer 会短暂关闭桌面和任务栏。'
            }
        }
        'windows-temp' {
            return [pscustomobject]@{
                Path = (Join-Path (Get-WindowsDir) 'Temp')
                Reason = '系统 Temp 需要管理员权限。'
                Action = '在“以管理员身份运行”的 PowerShell 中使用下方 -AllSafe 命令。'
            }
        }
        'delivery-optimization' {
            return [pscustomobject]@{
                Path = (Join-Path (Get-WindowsDir) 'ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache')
                Reason = '传递优化缓存由系统服务持有，需要管理员权限。'
                Action = '使用下方 -AllSafe 管理员命令；脚本会跳过占用文件。'
            }
        }
        'wu-download' {
            return [pscustomobject]@{
                Path = (Join-Path (Get-WindowsDir) 'SoftwareDistribution\Download')
                Reason = '更新缓存需要管理员权限；更新安装中或 BITS 传输活跃时删除可能中断更新。'
                Action = '确认没有待重启更新后，使用 -AllSafe 管理员命令；脚本不会停止 BITS/WU 服务。'
            }
        }
        'wer-reports' {
            return [pscustomobject]@{
                Path = (Join-Path (Get-ProgramDataDir) 'Microsoft\Windows\WER')
                Reason = '错误报告是排障证据，不是普通缓存。'
                Action = '排障结束后如仍要删除，管理员运行 -IncludeDiagnostics。'
            }
        }
        'cbs-logs' {
            return [pscustomobject]@{
                Path = (Join-Path (Get-WindowsDir) 'Logs\CBS')
                Reason = 'CBS 日志用于诊断组件安装和系统修复失败。'
                Action = '排障结束后如仍要删除，管理员运行 -IncludeDiagnostics。'
            }
        }
        'memory-dumps' {
            return [pscustomobject]@{
                Path = "$(Join-Path (Get-WindowsDir) 'MEMORY.DMP'); $(Join-Path (Get-WindowsDir) 'Minidump'); $(Join-Path $local 'CrashDumps')"
                Reason = '蓝屏和崩溃转储是定位驱动/应用故障的关键证据。'
                Action = '确认不再分析故障后，管理员运行 -IncludeDiagnostics。'
            }
        }
        'recycle-bin' {
            return [pscustomobject]@{
                Path = 'C 盘回收站'
                Reason = '清空后不可恢复，可能包含误删文件。'
                Action = '打开回收站逐项确认，或明确同意后再使用 -IncludeRecycleBin。'
            }
        }
        'browser-cache' {
            return [pscustomobject]@{
                Path = (($byId['browser-cache'].Paths) -join '; ')
                Reason = '浏览器运行时会锁定缓存；清理后首次访问站点会变慢。'
                Action = '可先运行 -AllSafe；若仍有锁定项，关闭 Edge/Chrome 后重试。'
            }
        }
        'hibernate' {
            return [pscustomobject]@{
                Path = 'C:\hiberfil.sys'
                Reason = '关闭休眠会同时关闭快速启动，属于系统设置变更。'
                Action = '明确接受后，在管理员终端执行 powercfg -h off 或使用 -DisableHibernate。'
            }
        }
        'winsxs-dism' {
            return [pscustomobject]@{
                Path = 'C:\Windows\WinSxS'
                Reason = '不能手动删除组件；DISM 清理耗时长，并会失去部分旧更新的卸载能力。'
                Action = '管理员运行 Dism.exe /Online /Cleanup-Image /AnalyzeComponentStore 后再决定。'
            }
        }
        'windows-old' {
            return [pscustomobject]@{
                Path = 'C:\Windows.old'
                Reason = '删除后不能回退到上一版本 Windows，直接改 ACL/递归删除还有恢复风险。'
                Action = '设置 → 系统 → 存储 → 临时文件 → “以前的 Windows 安装”；或磁盘清理 → 清理系统文件。'
            }
        }
        'windows-upgrade-temp' {
            return [pscustomobject]@{
                Path = 'C:\$Windows.~BT; C:\$Windows.~WS'
                Reason = '升级安装或回滚可能仍在使用，自动递归删除不安全。'
                Action = '确认升级完成或已取消后，使用 Windows 设置/磁盘清理中的临时文件。'
            }
        }
        'restore-points' {
            return [pscustomobject]@{
                Path = 'System Volume Information（由系统管理）'
                Reason = 'VSS 卷影不等于系统还原点，vssadmin 删除 oldest 会误伤备份历史。'
                Action = '系统属性 → 系统保护 → 配置；只通过官方界面删除还原点。'
            }
        }
        'pagefile' {
            return [pscustomobject]@{
                Path = 'C:\pagefile.sys'
                Reason = '分页文件被系统锁定，迁移会影响虚拟内存设置。'
                Action = '高级系统设置 → 性能 → 虚拟内存，把分页文件迁到其他分区并重启。'
            }
        }
        default {
            return [pscustomobject]@{
                Path = ''
                Reason = '需要人工确认当前应用状态或该项目的业务含义。'
                Action = '查看 references/manual-steps.md。'
            }
        }
    }
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
Add-Line '## 一、代理可直接执行的安全清理'
Add-Line ''
Add-Line '| 项目 | 体积 | 权限 |'
Add-Line '| --- | ---: | --- |'
foreach ($c in $safeRows) {
    Add-Line ('| ' + $c.Name + ' | ' + (Format-Size $c.Bytes) + ' | ' + $(if ($c.RequiresAdmin) { '管理员' } else { '当前用户' }) + ' |')
}
Add-Line ''
Add-Line '`-AllSafe` 会额外处理可重建的浏览器缓存和更新下载缓存；不会处理回收站、诊断证据、休眠、还原点或 Windows.old。'
Add-Line ''
Add-Line '```powershell'
Add-Line ('powershell -NoProfile -ExecutionPolicy Bypass -File "' + $scanScript + '"')
Add-Line ('powershell -NoProfile -ExecutionPolicy Bypass -File "' + $cleanScript + '" -Level safe -AllSafe')
Add-Line ('powershell -NoProfile -ExecutionPolicy Bypass -File "' + $cleanScript + '" -Level safe -AllSafe -Apply -Yes')
Add-Line '```'
Add-Line ''

Add-Line '## 二、可执行但需要单独风险确认'
Add-Line ''
Add-Line '| 项目 | 体积 | 原因 | 操作 |'
Add-Line '| --- | ---: | --- | --- |'
foreach ($c in $optSafeRows) {
    if ($c.Id -eq 'browser-cache' -or $c.Id -eq 'wu-download') { continue }
    $g = Get-ManualGuidance $c.Id
    Add-Line ('| ' + $c.Name + ' | ' + (Format-Size $c.Bytes) + ' | ' + $g.Reason + ' | ' + $g.Action + ' |')
}
Add-Line ''

Add-Line '## 三、最近一次清理未完成'
Add-Line ''
$lastCleanPath = Join-Path (Join-Path $script:CleanupHome 'reports') 'latest-clean.json'
$manualNeeded = @()
if (Test-PathSafe $lastCleanPath) {
    try {
        $lastClean = Get-Content -Raw -Encoding UTF8 -LiteralPath $lastCleanPath | ConvertFrom-Json
        $manualNeeded = @($lastClean.Results | Where-Object { $_.Status -notin @('ok', 'dry-run') })
    } catch { }
}
if ($manualNeeded.Count -eq 0) {
    Add-Line '没有读取到未完成项，或上一次清理没有失败/跳过；仍需检查下方手动操作与迁移项。'
} else {
    foreach ($r in $manualNeeded) {
        $g = Get-ManualGuidance $r.Id
        Add-Line ('### ' + $r.Name)
        Add-Line ''
        Add-Line ('- 状态：`' + $r.Status + '`')
        Add-Line ('- 路径：`' + $g.Path + '`')
        Add-Line ('- 原因：' + $g.Reason)
        if ($r.Detail) { Add-Line ('- 本次结果：' + $r.Detail) }
        Add-Line ('- 手动操作：' + $g.Action)
        Add-Line ''
    }
}

Add-Line '## 四、管理员或长期维护项'
Add-Line ''
Add-Line '1. **Windows Temp / 传递优化 / 更新缓存**：需要管理员权限。普通终端无法提权，运行 `-AllSafe` 的管理员命令后由用户确认 UAC。'
Add-Line '2. **DISM / WinSxS**：先运行 `Dism.exe /Online /Cleanup-Image /AnalyzeComponentStore`，确认收益后再考虑 `/StartComponentCleanup`；不可中途强杀。'
Add-Line '3. **休眠**：`C:\hiberfil.sys` 由 `powercfg -h off` 管理；会关闭快速启动。'
Add-Line '4. **还原点**：系统属性 → 系统保护 → 配置；不要用 `vssadmin delete shadows`。'
Add-Line '5. **Windows.old / 升级残留**：设置 → 系统 → 存储 → 临时文件，或磁盘清理 → 清理系统文件。'
Add-Line ''

Add-Line '## 五、软件额外存储检测（仅在 C 盘时告警）'
Add-Line ''
$cStorage = @($audit.StorageOnC | Sort-Object Bytes -Descending)
if ($cStorage.Count -eq 0) {
    Add-Line '未检测到可验证的 C 盘软件安装目录、聊天数据或安装包。'
} else {
    Add-Line '| 软件 / 数据 | 体积 | 类型 | 路径 | 风险 | 修改方案 |'
    Add-Line '| --- | ---: | --- | --- | --- | --- |'
    foreach ($s in $cStorage) {
        Add-Line ('| ' + $s.Name + ' | ' + (Format-Size $s.Bytes) + ' | `' + $s.Kind + '` | `' + $s.Path + '` | ' + $s.Risk + ' | ' + $s.Action + ' |')
    }
    Add-Line ''
    Add-Line '> 注册表没有 `InstallLocation` 的软件无法可靠判断安装路径；这里只报告已验证存在的路径。安装包检测范围是下载和桌面目录，不会自动删除。'
}
Add-Line ''

Add-Line '## 六、只能迁移或人工确认'
Add-Line ''
Add-Line '1. **用户文件夹**：桌面/文档/下载/图片/视频/音乐 → 属性 → 位置 → 移动；不要删除唯一副本。'
Add-Line '2. **虚拟内存**：设置 → 系统 → 系统信息 → 高级系统设置 → 性能设置 → 高级 → 虚拟内存；迁移后重启。'
if ($audit.Pagefile -and @($audit.Pagefile.Entries).Count -gt 0) {
    foreach ($p in $audit.Pagefile.Entries) {
        Add-Line ('   - 当前分页文件：' + $p.Name + '，' + $p.AllocatedMB + ' MB')
    }
}
Add-Line '3. **开发者缓存**：npm/pnpm/pip/NuGet 可按需清理，离线环境或计量网络下不要清。'
if ($audit.StorageSense) {
    $ss = $audit.StorageSense
    Add-Line ('4. **存储感知**：当前' + $(if ($ss.Enabled) { '已开启' } else { '未开启' }) + '；设置 → 系统 → 存储 → 存储感知。')
}
Add-Line ''

Add-Line '## 七、体积参考'
Add-Line ''
Add-Line '| 项目 | 体积 | 安装位置 |'
Add-Line '| --- | ---: | --- |'
foreach ($u in @($audit.UserFolders)) {
    Add-Line ('| 用户文件夹 · ' + $u.Name + ' | ' + (Format-Size $u.Bytes) + ' | `' + $u.Path + '` |')
}
if ($audit.TopApps.Count -gt 0) {
    foreach ($a in $audit.TopApps) {
        Add-Line ('| 已安装 · ' + $a.Name + ' | ' + (Format-Size $a.Bytes) + ' | `' + $a.InstallLocation + '` |')
    }
}
Add-Line ''
Add-Line ('预计普通权限默认可释放：' + (Format-Size $t.SafeUserBytes) + '；管理员默认项：' + (Format-Size $t.SafeAdminBytes) + '；需显式开关：' + (Format-Size $t.RequiresOptInBytes))

$text = $sb.ToString()
$dir = Split-Path -Parent $OutFile
if ($dir -and -not (Test-PathSafe $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$enc = New-Object System.Text.UTF8Encoding -ArgumentList $false
[IO.File]::WriteAllText($OutFile, $text, $enc)

Write-Output $text
Write-Output ''
Write-Output ('清单已保存: ' + $OutFile)
exit 0
