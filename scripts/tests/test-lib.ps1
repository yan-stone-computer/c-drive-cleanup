#Requires -Version 5.1
<#
  安全测试：在临时目录里验证白名单、试运行、跳过近期/占用文件、删除行为。
  不触碰真实系统目录。
#>
$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $PSCommandPath
. (Join-Path $here '..\lib.ps1')

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
Check '不存在 VSS 删除命令' { $actionText -notmatch '(?i)vssadmin[^\r\n]*delete|Remove-ComputerRestorePoint' }
Check '不存在 Windows.old 权限接管删除' { $actionText -notmatch '(?i)takeown|icacls|Previous Installations' }

Write-Host 'Format-Size'
Check 'GB 格式' { (Format-Size 5GB) -match 'GB' }
Check 'MB 格式' { (Format-Size 5MB) -match 'MB' }
Check '0 字节' { (Format-Size 0) -eq '0 B' }

Write-Host ''
Write-Host ("通过 $pass 项，失败 $fail 项")
if ($fail -gt 0) { exit 1 } else { exit 0 }
