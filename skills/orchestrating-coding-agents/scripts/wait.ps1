# Blocks until <RunDir>\done.json exists, then prints it. Use with run_in_background.
param([Parameter(Mandatory)][string]$RunDir, [int]$MaxMin = 60)
$deadline = (Get-Date).AddMinutes($MaxMin)
while (-not (Test-Path "$RunDir\done.json")) {
    if ((Get-Date) -gt $deadline) { '{"status":"WAIT_EXPIRED"}'; exit 2 }
    Start-Sleep -Seconds 3
}
Get-Content "$RunDir\done.json" -Raw
