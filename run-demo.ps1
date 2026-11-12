param(
    [string]$Server = '.',
    [switch]$TwoDb,     # sender and receiver in separate databases (05, 06)
    [switch]$Endpoint,  # loopback endpoint and routes (07); run -TwoDb first
    [switch]$Cleanup
)

$ErrorActionPreference = 'Stop'
$scripts =
    if ($Cleanup)       { '04_cleanup.sql' }
    elseif ($Endpoint)  { '07_endpoint_demo.sql' }
    elseif ($TwoDb)     { '05_twodb_setup.sql', '06_twodb_run.sql' }
    else                { '01_setup.sql', '02_manual_flow.sql', '03_activation.sql' }

foreach ($script in $scripts) {
    Write-Host "=== $script ===" -ForegroundColor Cyan
    sqlcmd -S $Server -E -C -b -W -I -i (Join-Path $PSScriptRoot $script)
    if ($LASTEXITCODE -ne 0) { throw "$script failed" }
}
