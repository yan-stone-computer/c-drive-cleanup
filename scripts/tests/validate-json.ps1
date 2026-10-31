#Requires -Version 5.1
<#
  校验 scan/clean 的 JSON 报告可被解析。默认读取 latest-*.json。
#>
param(
    [string]$ScanJson,
    [string]$CleanJson
)
$reportHome = Join-Path $env:LOCALAPPDATA 'c-drive-cleanup\reports'
if (-not $ScanJson) { $ScanJson = Join-Path $reportHome 'latest-scan.json' }
if (-not $CleanJson) { $CleanJson = Join-Path $reportHome 'latest-clean.json' }
$ok = $true
if (Test-Path -LiteralPath $ScanJson) {
    try {
        $s = Get-Content -Raw -Encoding UTF8 -LiteralPath $ScanJson | ConvertFrom-Json
        Write-Host ("scan  schema={0} candidates={1} safeUser={2} optIn={3}" -f $s.Schema, $s.Candidates.Count, $s.Totals.SafeUserBytes, $s.Totals.RequiresOptInBytes)
    } catch {
        Write-Host ("scan  JSON parse failed: " + $_.Exception.Message); $ok = $false
    }
} else {
    Write-Host 'scan  JSON not found (run scan.ps1 first)'; $ok = $false
}
if (Test-Path -LiteralPath $CleanJson) {
    try {
        $c = Get-Content -Raw -Encoding UTF8 -LiteralPath $CleanJson | ConvertFrom-Json
        Write-Host ("clean schema={0} applied={1} results={2} delta={3}" -f $c.Schema, $c.Applied, $c.Results.Count, $c.FreeSpaceDelta)
    } catch {
        Write-Host ("clean JSON parse failed: " + $_.Exception.Message); $ok = $false
    }
} else {
    Write-Host 'clean JSON not found (run clean.ps1 dry-run first)'; $ok = $false
}
if ($ok) { Write-Host 'JSON OK' } else { exit 1 }
