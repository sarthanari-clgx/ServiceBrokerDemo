param(
    [string]$Server = '.',
    [switch]$Cleanup
)

$ErrorActionPreference = 'Stop'
$scripts = if ($Cleanup) { '04_cleanup.sql' } else { '01_setup.sql', '02_manual_flow.sql', '03_activation.sql' }

foreach ($script in $scripts) {
    Write-Host "=== $script ===" -ForegroundColor Cyan
    sqlcmd -S $Server -E -C -b -W -I -i (Join-Path $PSScriptRoot $script)
    if ($LASTEXITCODE -ne 0) { throw "$script failed" }
}
