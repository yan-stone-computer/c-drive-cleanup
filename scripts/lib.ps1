#Requires -Version 5.1
<#
  c-drive-cleanup 公共库
  只读体检、安全删除、报告输出。所有删除路径都必须在候选清单白名单内，
  不会接受调用方传入的任意路径：所有删除必须落在候选表给出的精确白名单根内。
#>

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'

# 控制台使用 UTF-8，避免中文输出乱码
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding -ArgumentList $false } catch { }
try { $OutputEncoding = New-Object System.Text.UTF8Encoding -ArgumentList $false } catch { }

$script:AdminCache = $null

# 路径根使用 Windows Known Folder，不使用可被当前进程改写的 TEMP/TMP。
function Get-LocalAppDataDir {
    $p = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if (-not $p) { throw '无法解析 Windows LocalAppData 已知文件夹' }
    return [IO.Path]::GetFullPath($p).TrimEnd('\')
}

function Get-UserProfileDir {
    $p = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    if (-not $p) { throw '无法解析 Windows 用户配置文件夹' }
    return [IO.Path]::GetFullPath($p).TrimEnd('\')
}

function Get-ProgramDataDir {
    $p = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    if (-not $p) { throw '无法解析 Windows ProgramData 已知文件夹' }
    return [IO.Path]::GetFullPath($p).TrimEnd('\')
}

function Get-SafeUserTempPaths {
    # 只处理 LocalAppData\Temp。自定义 TEMP 可能指向文档、项目或同步盘，
    # 即使调用者显式设置也不作为删除候选。
    $canonical = Join-Path (Get-LocalAppDataDir) 'Temp'
    return @([IO.Path]::GetFullPath($canonical).TrimEnd('\'))
}

$localAppData = Get-LocalAppDataDir
$script:CleanupHome = Join-Path $localAppData 'c-drive-cleanup'

# ---------------------------------------------------------------- 基础工具

function Test-IsAdmin {
    if ($null -eq $script:AdminCache) {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal $id
        $script:AdminCache = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    return $script:AdminCache
}

function Test-PathSafe {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try { return (Test-Path -LiteralPath $Path -ErrorAction Stop) } catch { return $false }
}

function Format-Size {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ("$Bytes B")
}

# Windows 目录从 Win32 取，避免用户级环境变量重定向
function Get-WindowsDir {
    $w = ''
    try { $w = [Environment]::GetFolderPath([Environment+SpecialFolder]::Windows) } catch { }
    if (-not $w -or -not (Test-PathSafe $w)) { $w = $env:SystemRoot }
    return $w
}

# 去重路径（TEMP/TMP 常指向同一目录，避免体积双计）
function Get-UniquePaths {
    param([string[]]$Paths)
    $seen = @{}
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($p in $Paths) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        try { $full = [IO.Path]::GetFullPath($p.Trim()) } catch { continue }
        $trimmed = $full.TrimEnd('\')
        if ($full -match '^[A-Za-z]:\\$') { $trimmed = $full.Substring(0, 2) + '\' }
        if (-not $trimmed) { continue }
        $k = $trimmed.ToLowerInvariant()
        if ($seen.ContainsKey($k)) { continue }
        $seen[$k] = $true
        $list.Add($trimmed)
    }
    return $list.ToArray()
}

function ConvertTo-CleanupIdList {
    param([string[]]$Values = @())
    if (-not $Values -or $Values.Count -eq 0) { return @() }
    return @($Values | ForEach-Object { ([string]$_).Split(',') } |
        ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-CDriveInfo {
    $d = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='C:'" -ErrorAction SilentlyContinue
    if (-not $d) { return $null }
    $total = [long]$d.Size
    $free = [long]$d.FreeSpace
    return [pscustomobject]@{
        Drive       = 'C:'
        TotalBytes  = $total
        FreeBytes   = $free
        UsedBytes   = $total - $free
        FreePercent = if ($total -gt 0) { [math]::Round($free * 100.0 / $total, 1) } else { 0 }
    }
}

function Write-Section {
    param([string]$Title)
    Write-Host ''
    Write-Host "== $Title ==" -ForegroundColor Cyan
}

function Write-Item {
    param([string]$Text, [string]$Color = 'Gray')
    Write-Host "  $Text" -ForegroundColor $Color
}

function Write-JsonText {
    param([object]$Object, [string]$Path)
    $json = $Object | ConvertTo-Json -Depth 8
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-PathSafe $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $enc = New-Object System.Text.UTF8Encoding -ArgumentList $false
    [IO.File]::WriteAllText($Path, $json, $enc)
}

function New-ReportPath {
    param([string]$Kind)
    $dir = Join-Path $script:CleanupHome 'reports'
    if (-not (Test-PathSafe $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    return (Join-Path $dir ("{0}-{1}.json" -f $Kind, $stamp))
}

# ---------------------------------------------------------------- 体积统计

# robocopy /L 只统计不复制：比 Get-ChildItem 快一个数量级，且能跳过无权限目录
function Get-DirStat {
    param([string]$Path)
    if (-not (Test-PathSafe $Path)) { return $null }
    try {
        $raw = & robocopy $Path NULL /L /S /BYTES /XJ /R:0 /W:0 /NJH /NFL /NDL /NC 2>&1
    } catch { return $null }
    $bytes = $null
    $files = $null
    foreach ($line in $raw) {
        $s = [string]$line
        if ($s -match '^\s*(?i:Bytes|字节|バイト|바이트)\s*:\s*(\d+)') { $bytes = [long]$matches[1] }
        elseif ($s -match '^\s*(?i:Files|文件|檔案|ファイル|파일)\s*:\s*(\d+)') { $files = [int]$matches[1] }
    }
    if ($null -eq $bytes) { return $null }
    return [pscustomobject]@{ Bytes = $bytes; Files = $files }
}

function Get-PathStat {
    param([string[]]$Paths)
    $bytes = [long]0
    $files = 0
    $found = $false
    foreach ($p in (Get-UniquePaths $Paths)) {
        if (-not $p) { continue }
        if (-not (Test-PathSafe $p)) { continue }
        $item = $null
        try { $item = Get-Item -LiteralPath $p -Force -ErrorAction Stop } catch { }
        if (-not $item) { continue }
        if ($item.PSIsContainer) {
            $st = Get-DirStat $p
            if ($st) { $bytes += $st.Bytes; if ($st.Files) { $files += $st.Files }; $found = $true }
        } else {
            $bytes += [long]$item.Length
            $files += 1
            $found = $true
        }
    }
    if (-not $found) { return $null }
    return [pscustomobject]@{ Bytes = $bytes; Files = $files }
}

# ---------------------------------------------------------------- 清理候选

function Get-CleanupCandidates {
    $local = Get-LocalAppDataDir
    $programData = Get-ProgramDataDir
    $userProfile = Get-UserProfileDir
    $win = Get-WindowsDir
    $tempPaths = @(Get-SafeUserTempPaths)

    $browserPaths = New-Object System.Collections.Generic.List[string]
    foreach ($base in @("$local\Microsoft\Edge\User Data", "$local\Google\Chrome\User Data")) {
        if (-not (Test-PathSafe $base)) { continue }
        $profiles = @()
        try {
            $profiles = @(Get-ChildItem -LiteralPath $base -Directory -Force -ErrorAction SilentlyContinue | Where-Object {
                    $_.Name -eq 'Default' -or $_.Name -like 'Profile *'
                })
        } catch { }
        foreach ($profile in $profiles) {
            foreach ($relative in @('Cache', 'Code Cache', 'GPUCache', 'Service Worker\CacheStorage')) {
                $browserPaths.Add((Join-Path $profile.FullName $relative))
            }
        }
    }

    # 注意：Kind = tree-contents / files / recycle / hibernate / dism / wu-cache / manual
    $defs = @(
        @{ Id = 'user-temp'; Name = '用户临时文件 (LocalAppData\Temp)'; Level = 'safe'; RequiresAdmin = $false; Kind = 'tree-contents'; Paths = $tempPaths; Note = '仅清理 Windows 已知临时目录；默认保留最近 24 小时文件' }
        @{ Id = 'windows-temp'; Name = 'Windows 临时文件'; Level = 'safe'; RequiresAdmin = $true; Kind = 'tree-contents'; Paths = @("$win\Temp"); Note = '系统级临时目录，需管理员' }
        @{ Id = 'delivery-optimization'; Name = '传递优化缓存 (更新 P2P)'; Level = 'safe'; RequiresAdmin = $true; Kind = 'tree-contents'; Paths = @("$win\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache"); Note = 'Windows 更新分发缓存，可安全清理' }
        @{ Id = 'wu-download'; Name = 'Windows 更新下载缓存'; Level = 'safe'; RequiresAdmin = $true; Kind = 'wu-cache'; Paths = @("$win\SoftwareDistribution\Download"); OptIn = $true; Note = '仅显式 -ResetUpdateCache；不停止服务，活动更新/传输时跳过' }
        @{ Id = 'wer-reports'; Name = 'Windows 错误报告'; Level = 'safe'; RequiresAdmin = $true; Kind = 'tree-contents'; Paths = @("$programData\Microsoft\Windows\WER\ReportQueue", "$programData\Microsoft\Windows\WER\ReportArchive"); OptIn = $true; Note = '诊断证据，需 -IncludeDiagnostics 显式开启' }
        @{ Id = 'cbs-logs'; Name = 'CBS 组件安装日志'; Level = 'safe'; RequiresAdmin = $true; Kind = 'files'; Paths = @("$win\Logs\CBS"); Patterns = @('*.log', '*.cab', '*.etl'); OptIn = $true; Note = '排障证据，需 -IncludeDiagnostics 显式开启；正在写入的文件跳过' }
        @{ Id = 'memory-dumps'; Name = '崩溃转储文件'; Level = 'safe'; RequiresAdmin = $true; Kind = 'files'; Paths = @("$win\MEMORY.DMP", "$win\Minidump", "$local\CrashDumps"); Patterns = @('*.dmp'); OptIn = $true; Note = '排障证据，需 -IncludeDiagnostics 显式开启' }
        @{ Id = 'thumbnail-cache'; Name = '缩略图 / 图标缓存'; Level = 'safe'; RequiresAdmin = $false; Kind = 'files'; Paths = @("$local\Microsoft\Windows\Explorer"); Patterns = @('thumbcache_*.db', 'iconcache_*.db'); Note = '资源管理器会重建，首次打开文件夹略慢' }
        @{ Id = 'recycle-bin'; Name = '回收站（C 盘）'; Level = 'safe'; RequiresAdmin = $false; Kind = 'recycle'; Paths = @(); OptIn = $true; Note = '不可恢复，需 -IncludeRecycleBin 显式开启' }
        @{ Id = 'browser-cache'; Name = '浏览器缓存 (Edge / Chrome)'; Level = 'safe'; RequiresAdmin = $false; Kind = 'tree-contents'; Paths = $browserPaths.ToArray(); OptIn = $true; Note = '覆盖 Default/Profile *；不清 Cookie/密码/历史，需 -IncludeBrowserCache' }
        @{ Id = 'windows-upgrade-temp'; Name = 'Windows 升级临时文件 ($Windows.~BT / ~WS)'; Level = 'deep'; RequiresAdmin = $true; Kind = 'manual'; FullKind = 'tree-remove'; Paths = @("C:\`$Windows.~BT", "C:\`$Windows.~WS"); OptIn = $true; Note = '普通模式仅手动；FullCleanup + AcceptRisk 且升级空闲时可由管理员清理' }
        @{ Id = 'windows-old'; Name = '旧系统备份 (Windows.old)'; Level = 'deep'; RequiresAdmin = $true; Kind = 'manual'; FullKind = 'cleanmgr-old'; Paths = @("C:\Windows.old"); OptIn = $true; Note = '普通模式仅手动；FullCleanup + AcceptRisk 使用 Windows 官方磁盘清理通道' }
        @{ Id = 'hibernate'; Name = '休眠文件 (hiberfil.sys)'; Level = 'deep'; RequiresAdmin = $true; Kind = 'hibernate'; Paths = @("C:\hiberfil.sys"); OptIn = $true; Note = '关闭休眠可释放约等于内存大小的空间，会同时关闭快速启动' }
        @{ Id = 'winsxs-dism'; Name = '组件存储清理 (WinSxS / DISM)'; Level = 'deep'; RequiresAdmin = $true; Kind = 'dism'; Paths = @(); OptIn = $true; Note = '清理被取代的更新组件，通常 1-5 GB，耗时 5-20 分钟，需 -DismCleanup' }
        @{ Id = 'restore-points'; Name = '系统还原点与卷影副本'; Level = 'deep'; RequiresAdmin = $true; Kind = 'manual'; FullKind = 'vss-all'; Paths = @(); OptIn = $true; Note = '普通模式仅手动；FullCleanup + AcceptRisk 会删除 C 盘全部 VSS 卷影，含备份/文件历史风险' }
        @{ Id = 'pagefile'; Name = '虚拟内存（分页文件）'; Level = 'deep'; RequiresAdmin = $true; Kind = 'pagefile'; Paths = @(); OptIn = $false; Note = '迁移到其他分区需重启，脚本只检测并给出手动步骤' }
    )

    $list = New-Object System.Collections.Generic.List[object]
    foreach ($d in $defs) {
        $patterns = @()
        if ($d.ContainsKey('Patterns') -and $d.Patterns) { $patterns = @($d.Patterns) }
        $optIn = $false
        if ($d.ContainsKey('OptIn')) { $optIn = [bool]$d.OptIn }
        $obj = [pscustomobject]@{
            Id            = $d.Id
            Name          = $d.Name
            Level         = $d.Level
            RequiresAdmin = [bool]$d.RequiresAdmin
            Kind          = $d.Kind
            Paths         = @(Get-UniquePaths $d.Paths)
            Patterns      = $patterns
            OptIn         = $optIn
            FullKind      = if ($d.ContainsKey('FullKind')) { $d.FullKind } else { '' }
            Note          = $d.Note
            Exists        = $false
            Bytes         = [long]0
            Files         = 0
            Measured      = $false
        }
        $list.Add($obj)
    }
    return $list
}

function Update-CandidateSize {
    param([object]$Candidate)
    if ($Candidate.Kind -eq 'dism') {
        # 属于系统能力，始终“存在”，体积无法预先统计
        $Candidate.Exists = $true
        $Candidate.Measured = $false
        return $Candidate
    }
    if ($Candidate.Kind -eq 'manual') {
        $paths = @(Get-UniquePaths $Candidate.Paths)
        $stat = Get-PathStat -Paths $paths
        if ($stat) {
            $Candidate.Exists = $true
            $Candidate.Bytes = $stat.Bytes
            $Candidate.Files = $stat.Files
        }
        $Candidate.Measured = $true
        return $Candidate
    }
    if ($Candidate.Kind -eq 'pagefile') { return $Candidate }
    if ($Candidate.Kind -eq 'hibernate') {
        $f = $Candidate.Paths[0]
        if (Test-PathSafe $f) {
            try {
                $fi = Get-Item -LiteralPath $f -Force -ErrorAction Stop
                $Candidate.Bytes = [long]$fi.Length
                $Candidate.Exists = $true
                $Candidate.Measured = $true
            } catch { }
        }
        return $Candidate
    }
    if ($Candidate.Kind -eq 'recycle') {
        $stat = Get-RecycleBinStat
        if ($stat) {
            $Candidate.Exists = $true
            $Candidate.Bytes = $stat.Bytes
            $Candidate.Files = $stat.Items
            $Candidate.Measured = $true
        }
        return $Candidate
    }
    $paths = @(Get-UniquePaths $Candidate.Paths)
    if ($Candidate.Kind -eq 'files') {
        foreach ($p in $paths) {
            if (-not (Test-PathSafe $p)) { continue }
            $item = $null
            try { $item = Get-Item -LiteralPath $p -Force -ErrorAction Stop } catch { continue }
            if ($item.PSIsContainer) {
                $files = @()
                foreach ($pat in @($Candidate.Patterns)) {
                    try { $files += Get-ChildItem -LiteralPath $p -Filter $pat -File -Force -ErrorAction SilentlyContinue } catch { }
                }
                foreach ($f in $files) {
                    $Candidate.Bytes += [long]$f.Length
                    $Candidate.Files += 1
                    $Candidate.Exists = $true
                }
            } else {
                $Candidate.Bytes += [long]$item.Length
                $Candidate.Files += 1
                $Candidate.Exists = $true
            }
        }
        $Candidate.Measured = $true
        return $Candidate
    }
    $stat = Get-PathStat -Paths $paths
    if ($stat) {
        $Candidate.Exists = $true
        $Candidate.Bytes = $stat.Bytes
        $Candidate.Files = $stat.Files
    }
    $Candidate.Measured = $true
    return $Candidate
}

# ---------------------------------------------------------------- 信息采集

function Get-RecycleBinStat {
    # 只统计 C 盘的回收站（Namespace(10) 是跨盘聚合，不能代表 C 盘可释放量）
    try {
        $shell = New-Object -ComObject Shell.Application
        $bin = $shell.Namespace(10)
        if (-not $bin) { return $null }
        $bytes = [long]0
        $count = 0
        foreach ($it in @($bin.Items())) {
            $p = ''
            try { $p = [string]$it.Path } catch { }
            if ($p -notmatch '^C:\\') { continue }
            $count++
            try { $bytes += [long]$it.ExtendedProperty('Size') } catch { }
        }
        return [pscustomobject]@{ Items = $count; Bytes = $bytes }
    } catch { return $null }
}

function Get-HibernateInfo {
    $f = [IO.Path]::GetFullPath((Join-Path (Get-WindowsDir) '..\hiberfil.sys'))
    $enabled = Test-PathSafe $f
    $bytes = [long]0
    if ($enabled) { try { $bytes = [long](Get-Item -LiteralPath $f -Force -ErrorAction Stop).Length } catch { } }
    $fastStartup = $false
    try {
        $v = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name HiberbootEnabled -ErrorAction Stop
        $fastStartup = ([int]$v.HiberbootEnabled -eq 1)
    } catch { }
    return [pscustomobject]@{ Enabled = $enabled; Bytes = $bytes; File = $f; FastStartup = $fastStartup }
}

function Get-PagefileInfo {
    $result = New-Object System.Collections.Generic.List[object]
    try {
        $usage = Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue
        foreach ($u in @($usage)) {
            if (-not $u) { continue }
            $result.Add([pscustomobject]@{
                    Name = $u.Name
                    AllocatedMB = [int]$u.AllocatedBaseSize
                    CurrentMB = [int]$u.CurrentUsage
                    PeakMB = [int]$u.PeakUsage
                })
        }
    } catch { }
    $managed = $false
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
        $managed = [bool]$cs.AutomaticManagedPagefile
    } catch { }
    return [pscustomobject]@{ Entries = $result.ToArray(); AutomaticManaged = $managed }
}

function Get-StorageSenseInfo {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'
    $info = [ordered]@{
        Enabled = $false
        DeleteTempFiles = $false
        EmptyRecycleBin = $false
        DeleteDownloads = $false
        Configured = $false
    }
    try {
        if (Test-PathSafe $key) {
            $v = Get-ItemProperty -Path $key -ErrorAction Stop
            $info.Configured = $true
            if ($v.PSObject.Properties['01']) { $info.Enabled = ([int]$v.'01' -eq 1) }
            if ($v.PSObject.Properties['2048']) { $info.DeleteTempFiles = ([int]$v.'2048' -eq 1) }
            if ($v.PSObject.Properties['32']) { $info.EmptyRecycleBin = ([int]$v.'32' -eq 1) }
            if ($v.PSObject.Properties['08']) { $info.DeleteDownloads = ([int]$v.'08' -eq 1) }
        }
    } catch { }
    return [pscustomobject]$info
}

function Get-UserFolderInfo {
    $folders = @('Desktop', 'Downloads', 'Documents', 'Pictures', 'Videos', 'Music')
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($name in $folders) {
        $p = Join-Path (Get-UserProfileDir) $name
        if (-not (Test-PathSafe $p)) { continue }
        $st = Get-DirStat $p
        $bytes = if ($st) { $st.Bytes } else { 0 }
        $files = if ($st) { $st.Files } else { 0 }
        $result.Add([pscustomobject]@{ Name = $name; Path = $p; Bytes = [long]$bytes; Files = [int]$files })
    }
    return $result.ToArray()
}

function Get-AppCacheInfo {
    $local = Get-LocalAppDataDir
    $roaming = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
    $profile = Get-UserProfileDir
    $candidates = @(
        @{ Name = '微信（旧版）聊天文件'; Kind = 'chat-data'; Risk = 'high'; Optional = $false; Paths = @("$profile\Documents\WeChat Files"); Action = '微信设置 → 文件管理 → 更改存储位置到其他分区；迁移完成后再处理旧目录。' }
        @{ Name = '微信 4.x 聊天文件'; Kind = 'chat-data'; Risk = 'high'; Optional = $false; Paths = @("$profile\Documents\xwechat_files"); Action = '微信设置 → 文件管理 → 更改存储位置到其他分区；不要直接删除聊天目录。' }
        @{ Name = 'QQ 聊天文件'; Kind = 'chat-data'; Risk = 'high'; Optional = $false; Paths = @("$profile\Documents\Tencent Files", "$local\Tencent\QQ"); Action = 'QQ 设置 → 基本设置 → 文件管理 → 更改目录到其他分区。' }
        @{ Name = '企业微信聊天文件'; Kind = 'chat-data'; Risk = 'high'; Optional = $false; Paths = @("$profile\Documents\WXWork"); Action = '企业微信设置 → 通用 → 文件存储位置 → 更改到其他分区。' }
        @{ Name = '钉钉聊天文件'; Kind = 'chat-data'; Risk = 'high'; Optional = $false; Paths = @("$profile\Documents\DingTalk"); Action = '钉钉设置 → 通用 → 文件存储位置 → 更改到其他分区。' }
        @{ Name = '飞书 / Lark 数据'; Kind = 'chat-data'; Risk = 'high'; Optional = $false; Paths = @("$local\Feishu", "$roaming\Feishu", "$local\Lark", "$roaming\Lark"); Action = '飞书设置 → 通用 → 文件存储位置 → 更改目录；验证历史文件后再处理旧目录。' }
        @{ Name = 'Telegram Desktop 数据'; Kind = 'chat-data'; Risk = 'high'; Optional = $false; Paths = @("$roaming\Telegram Desktop"); Action = 'Telegram Desktop 设置中更改下载/数据目录；不支持时按应用官方迁移方式处理 tdata。' }
        @{ Name = 'Discord 应用数据'; Kind = 'app-data'; Risk = 'medium'; Optional = $false; Paths = @("$roaming\discord", "$local\Discord"); Action = '在应用内清理缓存；不要整体删除账号数据，必要时卸载后重装到其他分区。' }
        @{ Name = 'Slack 应用数据'; Kind = 'app-data'; Risk = 'medium'; Optional = $false; Paths = @("$roaming\Slack"); Action = 'Slack 设置中清理缓存；不要直接删除工作区状态目录。' }
        @{ Name = 'Microsoft Teams 数据'; Kind = 'app-data'; Risk = 'medium'; Optional = $false; Paths = @("$roaming\Microsoft\Teams", "$local\Packages\MSTeams_8wekyb3d8bbwe"); Action = 'Teams 设置中清理缓存；重装时可选择其他安装位置。' }
        @{ Name = 'Zoom 录制与数据'; Kind = 'app-data'; Risk = 'high'; Optional = $false; Paths = @("$roaming\Zoom", "$profile\Documents\Zoom"); Action = 'Zoom 设置 → 录制 → 更改录制文件位置到其他分区。' }
        @{ Name = 'Outlook 本地数据'; Kind = 'app-data'; Risk = 'high'; Optional = $false; Paths = @("$local\Microsoft\Outlook"); Action = 'Outlook 帐户设置 → 数据文件 → 更改 OST/PST 所在位置；不要直接移动正在使用的文件。' }
        @{ Name = 'Adobe 媒体缓存'; Kind = 'app-cache'; Risk = 'medium'; Optional = $true; Paths = @("$roaming\Adobe\Common\Media Cache", "$roaming\Adobe\Common\Media Cache Files"); Action = '在 Adobe 应用首选项 → 媒体缓存中更改目录并清理。' }
        @{ Name = '网易云音乐下载与缓存'; Kind = 'app-data'; Risk = 'medium'; Optional = $false; Paths = @("$local\Netease\CloudMusic", "$profile\Music\CloudMusic"); Action = '网易云音乐设置 → 下载设置 → 更改下载/缓存目录到其他分区。' }
    )
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($c in $candidates) {
        $existing = @($c.Paths | Where-Object { Test-PathSafe $_ })
        if ($existing.Count -eq 0) { continue }
        $stat = Get-PathStat -Paths $existing
        $bytes = [long]0
        if ($stat) { $bytes = [long]$stat.Bytes }
        $result.Add([pscustomobject]@{
                Name = $c.Name
                Paths = @($existing)
                Bytes = $bytes
                Kind = $c.Kind
                Risk = $c.Risk
                Optional = [bool]$c.Optional
                Action = $c.Action
            })
    }
    return $result.ToArray()
}

function Test-IsCPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        $full = [IO.Path]::GetFullPath($Path)
        return ([IO.Path]::GetPathRoot($full) -ieq 'C:\')
    } catch {
        return $false
    }
}

function New-StorageLocationRecord {
    param(
        [string]$Name,
        [string]$Kind,
        [string]$Path,
        [long]$Bytes = -1,
        [string]$Risk = 'medium',
        [string]$Action = '',
        [switch]$SkipSizes
    )
    if (-not (Test-PathSafe $Path)) { return $null }
    $full = [IO.Path]::GetFullPath($Path)
    if ($Bytes -lt 0 -and -not $SkipSizes) {
        $stat = Get-PathStat -Paths @($full)
        $Bytes = if ($stat) { [long]$stat.Bytes } else { [long]0 }
    } elseif ($Bytes -lt 0) {
        $Bytes = [long]0
    }
    return [pscustomobject]@{
        Name    = $Name
        Kind    = $Kind
        Path    = $full
        Bytes   = [long]$Bytes
        OnC     = Test-IsCPath $full
        Risk    = $Risk
        Action  = $Action
    }
}

function Get-InstalledApps {
    param([long]$MinKB = 0)
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    $byKey = @{}
    foreach ($k in $keys) {
        $props = @()
        try { $props = @(Get-ItemProperty -Path $k -ErrorAction SilentlyContinue) } catch { $props = @() }
        foreach ($p in $props) {
            if (-not $p.PSObject.Properties['DisplayName']) { continue }
            $name = ([string]$p.DisplayName).Trim()
            if (-not $name) { continue }
            $kb = [long]0
            if ($p.PSObject.Properties['EstimatedSize']) {
                try { $kb = [long]$p.EstimatedSize } catch { $kb = 0 }
            }
            if ($kb -gt 524288000) { $kb = 0 }
            if ($MinKB -gt 0 -and $kb -lt $MinKB) { continue }
            $location = ''
            if ($p.PSObject.Properties['InstallLocation']) {
                $location = ([string]$p.InstallLocation).Trim().Trim('"')
            }
        $key = ($name + '|' + $location).ToLowerInvariant()
            $record = [pscustomobject]@{
                Name            = $name
                KB              = $kb
                Bytes           = [long]($kb * 1KB)
                InstallLocation = $location
                Publisher       = if ($p.PSObject.Properties['Publisher']) { [string]$p.Publisher } else { '' }
            }
            if (-not $byKey.ContainsKey($key) -or $record.Bytes -gt $byKey[$key].Bytes) {
                $byKey[$key] = $record
            }
        }
    }
    return @($byKey.Values | Sort-Object Bytes -Descending)
}

function Get-SoftwareStorageInfo {
    param([switch]$SkipSizes)
    $records = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    function Add-StorageRecord([string]$Name, [string]$Kind, [string]$Path, [long]$Bytes = -1, [string]$Risk = 'medium', [string]$Action = '', [switch]$SkipSizes) {
        $record = New-StorageLocationRecord -Name $Name -Kind $Kind -Path $Path -Bytes $Bytes -Risk $Risk -Action $Action -SkipSizes:$SkipSizes
        if (-not $record) { return }
        $key = $record.Path.ToLowerInvariant() + '|' + $record.Kind
        if ($seen.ContainsKey($key)) { return }
        $seen[$key] = $true
        $records.Add($record)
    }

    foreach ($app in @(Get-AppCacheInfo)) {
        foreach ($path in @($app.Paths)) {
            Add-StorageRecord -Name $app.Name -Kind $app.Kind -Path $path -Risk $app.Risk -Action $app.Action -SkipSizes:$SkipSizes
        }
    }

    foreach ($app in @(Get-InstalledApps)) {
        if (-not $app.InstallLocation) { continue }
        Add-StorageRecord -Name $app.Name -Kind 'installed-app' -Path $app.InstallLocation -Bytes $app.Bytes -Risk 'medium' -Action '不要直接移动应用安装目录。不需要时通过系统卸载；支持选择安装位置的应用，卸载后重装到其他分区。'
    }

    $profile = Get-UserProfileDir
    $installerExtensions = @('.exe', '.msi', '.msix', '.msixbundle', '.appx', '.appxbundle', '.iso', '.img')
    $installerRoots = @(
        @{ Path = (Join-Path $profile 'Downloads'); Recurse = $true }
        @{ Path = (Join-Path $profile 'Desktop'); Recurse = $false }
    )
    foreach ($root in $installerRoots) {
        $dir = $root.Path
        if (-not (Test-PathSafe $dir)) { continue }
        $files = if ($root.Recurse) {
            @(Get-ChildItem -LiteralPath $dir -Recurse -File -Force -ErrorAction SilentlyContinue)
        } else {
            @(Get-ChildItem -LiteralPath $dir -File -Force -ErrorAction SilentlyContinue)
        }
        foreach ($file in $files) {
            if ($file.Extension.ToLowerInvariant() -notin $installerExtensions) { continue }
            Add-StorageRecord -Name ('可能的安装包或便携程序：' + $file.Name) -Kind 'installer-file' -Path $file.FullName -Bytes ([long]$file.Length) -Risk 'low' -Action '确认是安装包或已不需要的便携程序后，把文件移动到其他分区或删除；本工具不会自动删除。'
        }
    }

    $win = Get-WindowsDir
    $programData = Get-ProgramDataDir
    Add-StorageRecord -Name 'Windows Installer 缓存' -Kind 'protected-installer-cache' -Path (Join-Path $win 'Installer') -Risk 'critical' -Action '不要删除。它用于 MSI 修复、更新和卸载；删除可能导致软件无法修复。' -SkipSizes:$SkipSizes
    Add-StorageRecord -Name 'Visual Studio / 系统安装包缓存' -Kind 'protected-installer-cache' -Path (Join-Path $programData 'Package Cache') -Risk 'critical' -Action '不要手动删除。使用对应安装器的修复/清理功能；集成开发环境数据可在安装器中迁移。' -SkipSizes:$SkipSizes
    Add-StorageRecord -Name 'Windows 组件存储' -Kind 'protected-system-store' -Path (Join-Path $win 'WinSxS') -Risk 'critical' -Action '禁止手删；使用管理员 DISM 分析后再清理。' -SkipSizes:$SkipSizes

    $local = Get-LocalAppDataDir
    Add-StorageRecord -Name 'Ollama 模型' -Kind 'model-data' -Path (Join-Path $profile '.ollama\models') -Risk 'medium' -Action '通过设置 OLLAMA_MODELS 指向其他分区并迁移模型目录。' -SkipSizes:$SkipSizes
    Add-StorageRecord -Name 'Docker Desktop WSL 数据' -Kind 'vm-data' -Path (Join-Path $local 'Docker\wsl') -Risk 'high' -Action '先停止 Docker，使用 Docker Desktop/WSL 官方搬迁或导出导入；不要直接移动 VHDX。' -SkipSizes:$SkipSizes
    Add-StorageRecord -Name 'DirectX 着色器缓存' -Kind 'rebuildable-cache' -Path (Join-Path $local 'D3DSCache') -Risk 'low' -Action '可重建但游戏可能短暂卡顿；不作为常规自动删除项。' -SkipSizes:$SkipSizes
    Add-StorageRecord -Name 'NVIDIA DirectX 缓存' -Kind 'rebuildable-cache' -Path (Join-Path $local 'NVIDIA\DXCache') -Risk 'low' -Action '通过 NVIDIA 控制面板或驱动工具清理；可重建。' -SkipSizes:$SkipSizes
    Add-StorageRecord -Name 'AMD DirectX 缓存' -Kind 'rebuildable-cache' -Path (Join-Path $local 'AMD\DxCache') -Risk 'low' -Action '通过 AMD 软件清理；可重建。' -SkipSizes:$SkipSizes

    try {
        $steam = Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name SteamPath -ErrorAction Stop
        $steamRoot = [string]$steam.SteamPath
        if ($steamRoot) {
            $vdf = Join-Path $steamRoot 'steamapps\libraryfolders.vdf'
            if (Test-PathSafe $vdf) {
                $text = Get-Content -Raw -LiteralPath $vdf -ErrorAction SilentlyContinue
                foreach ($m in [regex]::Matches($text, '(?im)^\s*"path"\s+"([^"]+)"')) {
                    $library = $m.Groups[1].Value.Replace('\\', '\')
                    Add-StorageRecord -Name 'Steam 游戏库' -Kind 'game-library' -Path $library -Risk 'medium' -Action 'Steam → 设置 → 存储 → 将游戏移动到其他库；不要直接移动 steamapps。' -SkipSizes:$SkipSizes
                }
            }
        }
    } catch { }

    $epicManifest = Join-Path $programData 'Epic\EpicGamesLauncher\Data\Manifests'
    if (Test-PathSafe $epicManifest) {
        foreach ($manifest in @(Get-ChildItem -LiteralPath $epicManifest -Filter *.item -File -ErrorAction SilentlyContinue)) {
            try {
                $item = Get-Content -Raw -LiteralPath $manifest.FullName | ConvertFrom-Json
                if ($item.InstallLocation) {
                    Add-StorageRecord -Name ('Epic 游戏：' + $item.DisplayName) -Kind 'game-install' -Path $item.InstallLocation -Risk 'medium' -Action 'Epic Games Launcher → 设置 → 管理游戏；使用官方移动功能迁到其他分区。' -SkipSizes:$SkipSizes
                }
            } catch { }
        }
    }

    try {
        $wslRoot = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
        if (Test-PathSafe $wslRoot) {
            foreach ($key in @(Get-ChildItem -Path $wslRoot -ErrorAction SilentlyContinue)) {
                $props = Get-ItemProperty -Path $key.PSPath -ErrorAction SilentlyContinue
                if ($props.BasePath) {
                    Add-StorageRecord -Name ('WSL：' + $(if ($props.DistributionName) { $props.DistributionName } else { $key.PSChildName })) -Kind 'vm-data' -Path $props.BasePath -Risk 'high' -Action '使用 wsl --export / --import 迁到其他分区；先备份并停止该发行版。' -SkipSizes:$SkipSizes
                }
            }
        }
    } catch { }

    return @($records | Sort-Object -Property @{ Expression = 'OnC'; Descending = $true }, @{ Expression = 'Bytes'; Descending = $true })
}

function Get-TopApps {
    param([int]$Top = 8)
    $apps = @(Get-InstalledApps -MinKB 10240)
    if ($apps.Count -eq 0) { return @() }
    $seen = @{}
    $result = New-Object System.Collections.Generic.List[object]
    foreach ($a in ($apps | Sort-Object -Property KB -Descending)) {
        if ($seen.ContainsKey($a.Name)) { continue }
        $seen[$a.Name] = $true
        $result.Add([pscustomobject]@{
                Name = $a.Name
                Bytes = [long]($a.KB * 1KB)
                InstallLocation = $a.InstallLocation
            })
        if ($result.Count -ge $Top) { break }
    }
    return $result.ToArray()
}

function Get-RestorePointInfo {
    $count = 0
    $latest = $null
    try {
        $points = @(Get-ComputerRestorePoint -ErrorAction Stop)
        $count = $points.Count
        if ($count -gt 0) { $latest = $points | Sort-Object CreationTime -Descending | Select-Object -First 1 }
    } catch { }
    return [pscustomobject]@{ Count = $count; LatestCreationTime = if ($latest) { $latest.CreationTime } else { $null } }
}

function Get-OsInfo {
    $os = $null
    try { $os = Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue } catch { }
    return [pscustomobject]@{
        Caption = if ($os) { $os.Caption } else { [Environment]::OSVersion.VersionString }
        Build   = [Environment]::OSVersion.Version.Build
        PSVersion = $PSVersionTable.PSVersion.ToString()
        User    = $env:USERNAME
    }
}

# ---------------------------------------------------------------- 安全删除

function Assert-SafeDeletePath {
    param(
        [string]$Path,
        [string[]]$AllowedRoots,
        [switch]$AllowRootItself
    )
    if ([string]::IsNullOrWhiteSpace($Path)) { throw "空路径" }
    if ($Path -match '[*?]') { throw "路径包含通配符: $Path" }
    if (-not [IO.Path]::IsPathRooted($Path)) { throw "拒绝相对路径: $Path" }
    $full = [IO.Path]::GetFullPath($Path)
    if ($full.StartsWith('\\')) { throw "拒绝 UNC/网络路径: $full" }
    if ($full -match '^[A-Za-z]:\\?$') { throw "拒绝删除盘符根目录: $full" }
    if ($full.TrimEnd('\').Length -le 3) { throw "拒绝删除过短路径: $full" }

    # 系统关键目录永远拒绝（即使白名单给到整棵 Windows）
    $win = Get-WindowsDir
    $deny = @("$win\System32", "$win\SysWOW64", "$win\WinSxS", "$win\Installer", "$win\Boot", "$win\Fonts")
    foreach ($d in $deny) {
        $df = [IO.Path]::GetFullPath($d).TrimEnd('\')
        if ($full -ieq $df -or $full.StartsWith($df + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "拒绝删除系统关键目录: $full"
        }
    }
    $profile = Get-UserProfileDir
    foreach ($d in @('Desktop', 'Downloads', 'Documents', 'Pictures', 'Videos', 'Music')) {
        $root = [IO.Path]::GetFullPath((Join-Path $profile $d)).TrimEnd('\')
        if ($full -ieq $root -or $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "拒绝删除用户资料目录: $full"
        }
    }

    $roots = @($AllowedRoots | Where-Object { $_ })
    if ($roots.Count -eq 0) { throw "没有白名单根，拒绝删除: $full" }
    $ok = $false
    foreach ($r in $roots) {
        $rf = [IO.Path]::GetFullPath($r).TrimEnd('\')
        if ($full -ieq $rf) {
            # 清空目录内容时允许根本身（只删内容，保留目录）
            if ($AllowRootItself) { $ok = $true; break }
            continue
        }
        if ($full.StartsWith($rf + '\', [StringComparison]::OrdinalIgnoreCase)) { $ok = $true; break }
    }
    if (-not $ok) { throw "路径不在白名单内: $full" }
    return $full
}

function Test-ReparsePointInPath {
    param([string]$Path)
    try {
        $current = [IO.DirectoryInfo]([IO.Path]::GetFullPath($Path))
    } catch {
        return $true
    }
    while ($current) {
        try {
            if (($current.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
        } catch {
            return $true
        }
        $current = $current.Parent
    }
    return $false
}

function Get-CleanupFailureKind {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)
    $ex = $ErrorRecord.Exception
    while ($ex) {
        switch ($ex.HResult) {
            -2147024864 { return 'locked' }  # ERROR_SHARING_VIOLATION
            -2147024863 { return 'locked' }  # ERROR_LOCK_VIOLATION
            -2147024891 { return 'denied' }  # ERROR_ACCESS_DENIED
        }
        $ex = $ex.InnerException
    }
    return 'failed'
}

function Remove-FileForCleanup {
    param([string]$Path)
    $attrs = [IO.File]::GetAttributes($Path)
    $wasReadOnly = (($attrs -band [IO.FileAttributes]::ReadOnly) -ne 0)
    if ($wasReadOnly) {
        [IO.File]::SetAttributes($Path, ($attrs -bxor [IO.FileAttributes]::ReadOnly))
    }
    try {
        [IO.File]::Delete($Path)
    } catch {
        if ($wasReadOnly) {
            try { [IO.File]::SetAttributes($Path, $attrs) } catch { }
        }
        throw
    }
}

function Remove-TreeBestEffort {
    param(
        [string]$Path,
        [int]$SkipRecentHours,
        [switch]$DryRun,
        [string[]]$AllowedRoots = @()
    )
    if (-not $AllowedRoots -or @($AllowedRoots).Count -eq 0) { throw "Remove-TreeBestEffort 缺少精确白名单根" }
    $fullPath = Assert-SafeDeletePath -Path $Path -AllowedRoots $AllowedRoots -AllowRootItself
    $stats = [ordered]@{
        FilesDeleted = 0; FilesSkipped = 0; FilesRecent = 0; FilesLocked = 0
        FilesDenied = 0; FilesFailed = 0; DirectoryErrors = 0
        DirsDeleted = 0; Bytes = [long]0
    }
    if (Test-ReparsePointInPath $fullPath) {
        $stats.FilesSkipped++
        return [pscustomobject]$stats
    }
    $cutoff = if ($SkipRecentHours -gt 0) { (Get-Date).AddHours(-$SkipRecentHours) } else { $null }
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($fullPath)
    $dirs = New-Object System.Collections.Generic.List[string]
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        $dirs.Add($d)
        try {
            foreach ($f in [IO.Directory]::EnumerateFiles($d)) {
                try {
                    $fi = New-Object IO.FileInfo -ArgumentList $f
                    if ($cutoff -and $fi.LastWriteTime -gt $cutoff) { $stats.FilesRecent++; continue }
                    if ($DryRun) {
                        $stats.FilesDeleted++
                        $stats.Bytes += $fi.Length
                    } else {
                        Remove-FileForCleanup -Path $f
                        $stats.FilesDeleted++
                        $stats.Bytes += $fi.Length
                    }
                } catch {
                    $stats.FilesSkipped++
                    switch (Get-CleanupFailureKind $_) {
                        'locked' { $stats.FilesLocked++ }
                        'denied' { $stats.FilesDenied++ }
                        default { $stats.FilesFailed++ }
                    }
                }
            }
        } catch { $stats.DirectoryErrors++ }
        try {
            foreach ($sd in [IO.Directory]::EnumerateDirectories($d)) {
                try {
                    $attr = [IO.File]::GetAttributes($sd)
                    if (($attr -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $stats.FilesSkipped++; continue }
                    $stack.Push($sd)
                } catch { $stats.DirectoryErrors++ }
            }
        } catch { $stats.DirectoryErrors++ }
    }
    if (-not $DryRun) {
        for ($i = $dirs.Count - 1; $i -ge 0; $i--) {
            if ($dirs[$i] -ieq $fullPath) { continue }
            try {
                $remaining = @([IO.Directory]::EnumerateFileSystemEntries($dirs[$i])).Count
                if ($remaining -eq 0) {
                    [IO.Directory]::Delete($dirs[$i])
                    $stats.DirsDeleted++
                }
            } catch { }
        }
    }
    return [pscustomobject]$stats
}

# 清空目录内容（保留目录本身）
# AllowedRoots 由调用方传入精确根（通常就是候选路径本身），避免白名单过粗
function Clear-FolderContents {
    param(
        [string]$Path,
        [int]$SkipRecentHours = 24,
        [switch]$DryRun,
        [string[]]$AllowedRoots = @()
    )
    $stats = [ordered]@{
        Path = $Path; FilesDeleted = 0; FilesSkipped = 0; FilesRecent = 0
        FilesLocked = 0; FilesDenied = 0; FilesFailed = 0; DirectoryErrors = 0; DirsRemoved = 0
        Bytes = [long]0; Status = 'ok'; Error = ''
    }
    $roots = @(Get-UniquePaths $AllowedRoots)
    if ($roots.Count -eq 0) {
        $stats.Status = 'failed'; $stats.Error = '缺少精确白名单根，拒绝清理'
        return [pscustomobject]$stats
    }
    $full = Assert-SafeDeletePath -Path $Path -AllowedRoots $roots -AllowRootItself
    if (-not (Test-PathSafe $full)) { $stats.Status = 'missing'; return [pscustomobject]$stats }
    if (Test-ReparsePointInPath $full) {
        $stats.Status = 'failed'; $stats.Error = '路径含 junction/symlink 等重解析点，拒绝清理'
        return [pscustomobject]$stats
    }
    $cutoff = if ($SkipRecentHours -gt 0) { (Get-Date).AddHours(-$SkipRecentHours) } else { $null }
    $dirs = @()
    try { $dirs = @([IO.Directory]::EnumerateDirectories($full)) } catch { }
    $files = @()
    try { $files = @([IO.Directory]::EnumerateFiles($full)) } catch { }
    # 顶层文件
    foreach ($f in $files) {
        try {
            $fi = New-Object IO.FileInfo -ArgumentList $f
            if ($cutoff -and $fi.LastWriteTime -gt $cutoff) { $stats.FilesRecent++; continue }
            if ($DryRun) {
                $stats.FilesDeleted++; $stats.Bytes += $fi.Length
            } else {
                Remove-FileForCleanup -Path $f
                $stats.FilesDeleted++; $stats.Bytes += $fi.Length
            }
        } catch {
            $stats.FilesSkipped++
            switch (Get-CleanupFailureKind $_) {
                'locked' { $stats.FilesLocked++ }
                'denied' { $stats.FilesDenied++ }
                default { $stats.FilesFailed++ }
            }
        }
    }
    # 顶层目录
    foreach ($d in $dirs) {
        try {
            $attr = [IO.File]::GetAttributes($d)
            if (($attr -band [IO.FileAttributes]::ReparsePoint) -ne 0) { $stats.FilesSkipped++; continue }
        } catch { continue }
        if ($DryRun) {
            $st = Get-DirStat $d
            if ($st) { $stats.Bytes += $st.Bytes; $stats.FilesDeleted += [int]$st.Files }
            $stats.DirsRemoved++
            continue
        }
        # 始终逐项删除，绝不使用递归 Directory.Delete 穿过未检查的子路径。
        $r = Remove-TreeBestEffort -Path $d -SkipRecentHours $SkipRecentHours -AllowedRoots $roots
        $stats.FilesDeleted += $r.FilesDeleted
        $stats.FilesSkipped += $r.FilesSkipped
        $stats.FilesRecent += $r.FilesRecent
        $stats.FilesLocked += $r.FilesLocked
        $stats.FilesDenied += $r.FilesDenied
        $stats.FilesFailed += $r.FilesFailed
        $stats.DirectoryErrors += $r.DirectoryErrors
        $stats.DirsRemoved += $r.DirsDeleted
        $stats.Bytes += $r.Bytes
    }
    return [pscustomobject]$stats
}

function Clear-RecycleBinSafe {
    param([switch]$DryRun)
    $stat = Get-RecycleBinStat
    $before = if ($stat) { $stat.Bytes } else { 0 }
    if ($DryRun) {
        return [pscustomobject]@{ Bytes = [long]$before; Status = 'dry-run'; Error = '' }
    }
    try {
        Clear-RecycleBin -DriveLetter C -Force -ErrorAction Stop
        $after = Get-RecycleBinStat
        $afterBytes = if ($after) { $after.Bytes } else { 0 }
        return [pscustomobject]@{ Bytes = [long]($before - $afterBytes); Status = 'ok'; Error = '' }
    } catch {
        return [pscustomobject]@{ Bytes = [long]0; Status = 'failed'; Error = $_.Exception.Message }
    }
}

function Get-StatusText {
    param([string]$Status)
    switch ($Status) {
        'ok' { return '完成' }
        'cleaned' { return '已清理' }
        'dry-run' { return '试运行' }
        'skipped' { return '跳过' }
        'partial' { return '部分完成' }
        'failed' { return '失败' }
        'missing' { return '不存在' }
        'needs-admin' { return '需管理员' }
        'needs-flag' { return '需显式开关' }
        'needs-manual' { return '需手动确认' }
        'manual' { return '需手动' }
        default { return $Status }
    }
}
