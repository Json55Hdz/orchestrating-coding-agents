# Persistent viewer tab. Stays open between tasks; dispatch.ps1 feeds it instead of opening new windows.
#   opencode: re-attaches the REAL TUI (`opencode attach -s <session>`) whenever a new task is pointed at it.
#   agy:      runs queued workers inline, so the window shows the REAL agy process output.
param(
    [Parameter(Mandatory)][ValidateSet('opencode','agy')][string]$Backend,
    [string]$Slot = 'main',
    [string]$Url = 'http://127.0.0.1:4096'
)
$here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$slots = Join-Path $env:TEMP 'agent-runs\slots'
$key   = "$Backend-$Slot"
$alive = Join-Path $slots "$key.alive"
$cur   = Join-Path $slots "$key.cur"
$queue = Join-Path $slots "$key.queue"
New-Item -ItemType Directory -Force $queue | Out-Null
$host.UI.RawUI.WindowTitle = "[$Backend] $Slot  (persistent viewer)"
Set-Content -Path $alive -Value $PID

if ($Backend -eq 'opencode') {
    $seen = if (Test-Path $cur) { Get-Content $cur -Raw } else { '' }   # ignore a stale pointer from a dead viewer
    $child = $null; $announced = $false
    Write-Host "Viewer ready ($key). Waiting for the next task..." -ForegroundColor Cyan
    while ($true) {
        if (Test-Path $cur) {
            $raw = Get-Content $cur -Raw
            if ($raw -and $raw -ne $seen) {
                $seen = $raw
                if ($child -and -not $child.HasExited) { & taskkill.exe /PID $child.Id /T /F | Out-Null }
                $t = $raw | ConvertFrom-Json
                Clear-Host
                $child = Start-Process cmd.exe -NoNewWindow -PassThru -ArgumentList "/c opencode.cmd attach $Url --dir `"$($t.dir)`" -s $($t.session)"
                $announced = $false
            }
        }
        if ($child -and $child.HasExited -and -not $announced) {
            Clear-Host; Write-Host "TUI closed. Waiting for the next task..." -ForegroundColor Cyan; $announced = $true
        }
        Start-Sleep -Milliseconds 700
    }
} else {
    Write-Host "Viewer ready ($key). Waiting for the next task..." -ForegroundColor Cyan
    while ($true) {
        $job = Get-ChildItem $queue -Filter *.json -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -First 1
        if (-not $job) { Start-Sleep -Milliseconds 700; continue }
        $p = Get-Content $job.FullName -Raw | ConvertFrom-Json
        Remove-Item $job.FullName -Force
        $h = @{}; $p.PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value }
        Clear-Host
        try { & (Join-Path $here 'worker.ps1') @h } catch { Write-Host "worker crashed: $_" -ForegroundColor Red }
        Write-Host "`nWaiting for the next task..." -ForegroundColor Cyan
    }
}
