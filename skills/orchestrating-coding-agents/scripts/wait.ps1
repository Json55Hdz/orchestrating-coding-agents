# Blocks until <RunDir>\done.json exists, then prints it. Use with run_in_background.
param([Parameter(Mandatory)][string]$RunDir, [int]$MaxMin = 60)
$deadline = (Get-Date).AddMinutes($MaxMin)
$doneFile = Join-Path $RunDir 'done.json'
while (-not (Test-Path $doneFile)) {
    if ((Get-Date) -gt $deadline) { '{"status":"WAIT_EXPIRED"}'; exit 2 }
    Start-Sleep -Seconds 3
}
Get-Content $doneFile -Raw
