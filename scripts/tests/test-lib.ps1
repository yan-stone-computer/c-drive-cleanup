#Requires -Version 5.1
<#
  安全测试：在临时目录里验证白名单、试运行、跳过近期/占用文件、删除行为。
  不触碰真实系统目录。
#>
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $PSCommandPath
. (Join-Path $here '..\lib.ps1')
. (Join-Path $here '..\lib-actions.ps1')

$pass = 0
$fail = 0
function Check([string]$Name, [scriptblock]$Test) {
    try {
        $ok = & $Test
        if ($ok) { Write-Host ("  PASS  " + $Name) -ForegroundColor Green; $script:pass++ }
        else { Write-Host ("  FAIL  " + $Name) -ForegroundColor Red; $script:fail++ }
    } catch {
        Write-Host ("  FAIL  " + $Name + " -> " + $_.Exception.Message) -ForegroundColor Red
        $script:fail++
    }
}
function Test-SamePath([string]$Left, [string]$Right) {
    try {
        return ([IO.Path]::GetFullPath($Left).TrimEnd('\') -ieq [IO.Path]::GetFullPath($Right).TrimEnd('\'))
    } catch { return $false }
}

$root = Join-Path $env:TEMP ('c-drive-cleanup-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$tree = Join-Path $root 'tree'
$nested = Join-Path $tree 'nested'
$lockedDir = Join-Path $tree 'locked'
New-Item -ItemType Directory -Path $nested -Force | Out-Null
New-Item -ItemType Directory -Path $lockedDir -Force | Out-Null
Set-Content -LiteralPath (Join-Path $tree 'a.txt') -Value ('x' * 1024) -NoNewline
Set-Content -LiteralPath (Join-Path $nested 'b.txt') -Value ('x' * 2048) -NoNewline
$recent = Join-Path $tree 'recent.txt'
Set-Content -LiteralPath $recent -Value ('x' * 4096) -NoNewline
$locked = Join-Path $lockedDir 'locked.txt'
Set-Content -LiteralPath $locked -Value ('x' * 8192) -NoNewline
# 把普通文件改为“旧文件”，验证 SkipRecentHours 只保留最近文件
(Get-Item -LiteralPath (Join-Path $tree 'a.txt')).LastWriteTime = (Get-Date).AddHours(-3)
(Get-Item -LiteralPath (Join-Path $nested 'b.txt')).LastWriteTime = (Get-Date).AddHours(-3)
(Get-Item -LiteralPath $locked).LastWriteTime = (Get-Date).AddHours(-3)

$lockStream = $null
try {
    $lockStream = [IO.File]::Open($locked, 'Open', 'Read', 'None')

    Write-Host 'safe delete path 白名单'
    Check '拒绝盘符根目录' { try { Assert-SafeDeletePath -Path 'C:\' -AllowedRoots @($env:TEMP); $false } catch { $true } }
    Check '拒绝 UNC 路径' { try { Assert-SafeDeletePath -Path '\\server\share\file' -AllowedRoots @('\\server\share'); $false } catch { $true } }
    Check '拒绝白名单外路径' { try { Assert-SafeDeletePath -Path 'C:\Windows\System32' -AllowedRoots @($env:TEMP); $false } catch { $true } }
    Check '拒绝通配符' { try { Assert-SafeDeletePath -Path (Join-Path $env:TEMP 'x*') -AllowedRoots @($env:TEMP); $false } catch { $true } }
    Check '拒绝删除根目录本身（默认）' { try { Assert-SafeDeletePath -Path $env:TEMP -AllowedRoots @($env:TEMP); $false } catch { $true } }
    Check '允许清空根目录内容（AllowRootItself）' { Test-SamePath (Assert-SafeDeletePath -Path $env:TEMP -AllowedRoots @($env:TEMP) -AllowRootItself) $env:TEMP }
    Check '拒绝系统关键目录（即使白名单给整棵 Windows）' {
        try { Assert-SafeDeletePath -Path 'C:\Windows\System32' -AllowedRoots @('C:\Windows') -AllowRootItself; $false } catch { $true }
    }
    Check '拒绝用户资料目录' {
        $documents = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)) 'Documents'
        try { Assert-SafeDeletePath -Path $documents -AllowedRoots @($documents) -AllowRootItself; $false } catch { $true }
    }
    Check '缺少精确白名单根时拒绝' { try { Assert-SafeDeletePath -Path $tree; $false } catch { $true } }
    Check 'TEMP/TMP 去重' { @(Get-UniquePaths @($env:TEMP, $env:TMP)).Count -eq 1 }
    Check '空清理项列表保持为空' { @(ConvertTo-CleanupIdList @()).Count -eq 0 }
    Check '逗号分隔清理项正确拆分' { (@(ConvertTo-CleanupIdList @('user-temp,thumbnail-cache')).Count -eq 2) }
    Check '盘符根路径不被 TrimEnd 破坏' { @(Get-UniquePaths @('C:\'))[0] -eq 'C:\' }
    Check '允许 TEMP 子目录' { Test-SamePath (Assert-SafeDeletePath -Path $tree -AllowedRoots @($env:TEMP)) $tree }

    Write-Host '受信任临时目录'
    $oldTempEnv = $env:TEMP
    try {
        $env:TEMP = (Join-Path $root 'not-a-temp-root')
        $safeTemp = @(Get-SafeUserTempPaths)
        $expectedTemp = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'Temp'
        Check 'TEMP 环境变量不能改写删除根' { $safeTemp.Count -eq 1 -and (Test-SamePath $safeTemp[0] $expectedTemp) }
    } finally {
        $env:TEMP = $oldTempEnv
    }

    Write-Host 'Get-DirStat 体积'
    $stat = Get-DirStat $tree
    Check '体积统计正确' { $stat -and $stat.Bytes -ge (1024 + 2048 + 4096 + 8192) }

    Write-Host '试运行不删除'
    $dr = Clear-FolderContents -Path $tree -DryRun -SkipRecentHours 1 -AllowedRoots @($tree)
    Check 'dry-run 统计文件数' { $dr.FilesDeleted -ge 3 }
    Check 'dry-run 不删除文件' { (Test-Path -LiteralPath (Join-Path $tree 'a.txt')) }
    Check '缺少白名单时不删除' {
        $guard = Join-Path $tree 'guard.txt'
        Set-Content -LiteralPath $guard -Value 'guard' -NoNewline
        $blocked = Clear-FolderContents -Path $tree -AllowedRoots @()
        $blocked.Status -eq 'failed' -and (Test-Path -LiteralPath $guard)
    }

    Write-Host '真实删除（跳过 1 小时内文件与占用文件）'
    $real = Clear-FolderContents -Path $tree -SkipRecentHours 1 -AllowedRoots @($tree)
    Check '最近文件被保留' { Test-Path -LiteralPath $recent }
    Check '占用文件被保留' { Test-Path -LiteralPath $locked }
    Check '近期文件单独计数' { $real.FilesRecent -ge 1 }
    Check '占用文件识别为 locked' { $real.FilesLocked -ge 1 }
    Check '普通旧文件被删除' { -not (Test-Path -LiteralPath (Join-Path $tree 'a.txt')) }
    Check '嵌套旧文件被删除' { -not (Test-Path -LiteralPath (Join-Path $nested 'b.txt')) }
} finally {
    if ($lockStream) { $lockStream.Dispose() }
    try { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

Write-Host 'Remove-TreeBestEffort'
$root2 = Join-Path $env:TEMP ('c-drive-cleanup-test2-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path (Join-Path $root2 'a\b') -Force | Out-Null
Set-Content -LiteralPath (Join-Path $root2 'a\b\c.txt') -Value 'hello' -NoNewline
$r = Remove-TreeBestEffort -Path (Join-Path $root2 'a') -SkipRecentHours 0 -AllowedRoots @($root2)
Check 'best-effort 删除文件' { $r.FilesDeleted -ge 1 }
Check 'best-effort 删除后没有残留文件' { @(Get-ChildItem -LiteralPath $root2 -Recurse -File -Force -ErrorAction SilentlyContinue).Count -eq 0 }
Remove-Item -LiteralPath $root2 -Recurse -Force -ErrorAction SilentlyContinue

Write-Host '只读缓存'
$rootReadOnly = Join-Path $env:TEMP ('c-drive-cleanup-readonly-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$readOnlyNested = Join-Path $rootReadOnly 'nested'
New-Item -ItemType Directory -Path $readOnlyNested -Force | Out-Null
$readOnlyTop = Join-Path $rootReadOnly 'top.cache'
$readOnlyDeep = Join-Path $readOnlyNested 'deep.cache'
Set-Content -LiteralPath $readOnlyTop -Value 'top' -NoNewline
Set-Content -LiteralPath $readOnlyDeep -Value 'deep' -NoNewline
[IO.File]::SetAttributes($readOnlyTop, [IO.FileAttributes]::Archive -bor [IO.FileAttributes]::ReadOnly)
[IO.File]::SetAttributes($readOnlyDeep, [IO.FileAttributes]::Archive -bor [IO.FileAttributes]::ReadOnly)
$rr = Clear-FolderContents -Path $rootReadOnly -SkipRecentHours 0 -AllowedRoots @($rootReadOnly)
Check '只读缓存文件可以安全删除' { $rr.FilesDeleted -ge 2 -and -not (Test-Path -LiteralPath $readOnlyTop) -and -not (Test-Path -LiteralPath $readOnlyDeep) }
Remove-Item -LiteralPath $rootReadOnly -Recurse -Force -ErrorAction SilentlyContinue

Write-Host '重解析点'
$linkRoot = Join-Path $env:TEMP ('c-drive-cleanup-link-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$linkTarget = Join-Path $linkRoot 'target'
$linkPath = Join-Path $linkRoot 'link'
New-Item -ItemType Directory -Path $linkTarget -Force | Out-Null
Set-Content -LiteralPath (Join-Path $linkTarget 'keep.txt') -Value 'keep' -NoNewline
try {
    New-Item -ItemType Junction -Path $linkPath -Target $linkTarget -ErrorAction Stop | Out-Null
    $lr = Clear-FolderContents -Path $linkPath -AllowedRoots @($linkRoot)
    Check '拒绝通过 junction 清理目标' { $lr.Status -eq 'failed' -and (Test-Path -LiteralPath (Join-Path $linkTarget 'keep.txt')) }
} catch {
    Check '创建测试 junction' { $false }
} finally {
    Remove-Item -LiteralPath $linkRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host '危险自动化默认关闭'
$candidates = @(Get-CleanupCandidates)
$byId = @{}
foreach ($c in $candidates) { $byId[$c.Id] = $c }
Check '诊断证据需显式开关' { $byId['wer-reports'].OptIn -and $byId['cbs-logs'].OptIn -and $byId['memory-dumps'].OptIn }
Check '更新缓存需显式开关' { $byId['wu-download'].OptIn }
Check '还原点仅手动' { $byId['restore-points'].Kind -eq 'manual' }
Check 'Windows.old 仅手动' { $byId['windows-old'].Kind -eq 'manual' }
Check '升级残留仅手动' { $byId['windows-upgrade-temp'].Kind -eq 'manual' }
$actionText = Get-Content -Raw -Encoding UTF8 -LiteralPath (Join-Path $here '..\lib-actions.ps1')
Check 'VSS 删除仅由 FullKind 控制' { $byId['restore-points'].FullKind -eq 'vss-all' -and $actionText -match '(?i)vssadmin[^\r\n]*delete' }
Check 'Windows.old 不使用 ACL 权限接管' { $actionText -notmatch '(?i)takeown|icacls' }

Write-Host 'Format-Size'
Check 'GB 格式' { (Format-Size 5GB) -match 'GB' }
Check 'MB 格式' { (Format-Size 5MB) -match 'MB' }
Check '0 字节' { (Format-Size 0) -eq '0 B' }

Write-Host '软件存储路径'
$storageTest = Join-Path $env:TEMP ('c-drive-storage-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $storageTest -Force | Out-Null
Set-Content -LiteralPath (Join-Path $storageTest 'data.bin') -Value ('x' * 32) -NoNewline
try {
    $storageRecord = New-StorageLocationRecord -Name '测试应用数据' -Kind 'app-data' -Path $storageTest -Risk 'high' -Action '移动到其他分区'
    Check 'C 盘路径识别' { Test-IsCPath $env:TEMP }
    Check 'D 盘路径不误判为 C 盘' { -not (Test-IsCPath 'D:\Apps') }
    Check '软件存储记录包含路径和迁移方案' {
        $storageRecord -and $storageRecord.OnC -and $storageRecord.Bytes -ge 32 -and $storageRecord.Action -eq '移动到其他分区'
    }
} finally {
    Remove-Item -LiteralPath $storageTest -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host '全清理授权闸'
$cleanScript = Join-Path $here '..\clean.ps1'
$fullWithoutRisk = & powershell -NoProfile -ExecutionPolicy Bypass -File $cleanScript -FullCleanup -DryRun 2>&1 | Out-String
$fullWithoutRiskExit = $LASTEXITCODE
Check 'FullCleanup 缺少 AcceptRisk 时拒绝' { $fullWithoutRiskExit -eq 1 -and $fullWithoutRisk -match 'AcceptRisk' }
$shadowWithoutRisk = & powershell -NoProfile -ExecutionPolicy Bypass -File $cleanScript -Level deep -RemoveAllShadowCopies -DryRun 2>&1 | Out-String
$shadowWithoutRiskExit = $LASTEXITCODE
Check '卷影删除缺少 AcceptRisk 时拒绝' { $shadowWithoutRiskExit -eq 1 -and $shadowWithoutRisk -match 'AcceptRisk' }
$fullPlanDir = Join-Path $env:TEMP ('c-drive-full-plan-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$fullPlanRaw = & powershell -NoProfile -ExecutionPolicy Bypass -File $cleanScript -FullCleanup -AcceptRisk -DryRun -Json -Ids user-temp -SkipRecentHours 24 -LogDir $fullPlanDir | Out-String
$fullPlanExit = $LASTEXITCODE
try {
    $fullPlan = $fullPlanRaw | ConvertFrom-Json
    Check 'FullCleanup 生成风险配置但不执行' { $fullPlanExit -eq 0 -and $fullPlan.SafetyProfile -eq 'safe-v2+full-risk' -and $fullPlan.Applied -eq $false }
} catch {
    Check 'FullCleanup 生成风险配置但不执行' { $false }
} finally {
    Remove-Item -LiteralPath $fullPlanDir -Recurse -Force -ErrorAction SilentlyContinue
}
Check 'DISM 输出 Access denied 判为失败' { Test-ServicingFailureOutput 'Error: 5 | Access is denied.' }
Check 'VSS 输出卷影数量可解析' { (Get-ShadowCopyCountFromText "Shadow Copy ID: {abc}`nShadow Copy ID: {def}") -eq 2 }
$fullCandidates = @(Get-CleanupCandidates)
$fullIds = @('windows-old', 'windows-upgrade-temp', 'restore-points')
$fullReady = $true
foreach ($id in $fullIds) {
    $candidate = $fullCandidates | Where-Object Id -eq $id | Select-Object -First 1
    if (-not $candidate -or -not $candidate.FullKind) { $fullReady = $false }
}
Check '全清理系统项具有受控 FullKind' { $fullReady }
$vssCandidate = $fullCandidates | Where-Object Id -eq 'restore-points' | Select-Object -First 1
$null = Update-CandidateSize $vssCandidate
Check 'VSS 全删能力不会因缺少路径被判 missing' { $vssCandidate.Exists -and $vssCandidate.FullKind -eq 'vss-all' }

Write-Host ''
Write-Host ("通过 $pass 项，失败 $fail 项")
if ($fail -gt 0) { exit 1 } else { exit 0 }
