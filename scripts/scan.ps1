#Requires -Version 5.1
<#
  C 盘只读体检：不删除任何文件。
  输出人类可读摘要，并把结构化 JSON 写到 %LOCALAPPDATA%\c-drive-cleanup\reports\。
  加 -Json 时 stdout 只输出 JSON，便于程序解析。
#>
[CmdletBinding()]
param(
    [switch]$Json,
    [string]$OutFile,
    [switch]$SkipSizes,
    [int]$TopApps = 8
)

$ErrorActionPreference = 'Continue'
$here = Split-Path -Parent $PSCommandPath
. (Join-Path $here 'lib.ps1')
. (Join-Path $here 'lib-audit.ps1')

$audit = Get-CleanupAudit -SkipSizes:$SkipSizes -TopApps $TopApps

if (-not $OutFile) {
    $OutFile = New-ReportPath -Kind 'scan'
}
Write-JsonText -Object $audit -Path $OutFile
$latest = Join-Path (Join-Path $script:CleanupHome 'reports') 'latest-scan.json'
Write-JsonText -Object $audit -Path $latest

if ($Json) {
    Write-Output ($audit | ConvertTo-Json -Depth 8)
} else {
    Write-Output (Format-AuditText -Audit $audit)
    Write-Output ''
    Write-Output ('JSON 报告: ' + $OutFile)
    Write-Output ('最新报告: ' + $latest)
}
exit 0
