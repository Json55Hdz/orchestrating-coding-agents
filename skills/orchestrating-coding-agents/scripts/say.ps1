# Talk to a running (or recently finished) agent, like SendMessage to a subagent. The viewer tab shows it live.
#   say.ps1 -RunDir <RUN_DIR> -Text "also add a test for X"     send, return immediately
#   say.ps1 -RunDir <RUN_DIR> -Text "..." -Wait [-WaitSec 300]  send, wait for the reply, print it
#   say.ps1 -RunDir <RUN_DIR> -Last                              print the last assistant message
#   say.ps1 -RunDir <RUN_DIR> -Abort                             interrupt (OpenCode: current turn; AGY: ends the session)
# OpenCode: through the shared server (works even on finished sessions).
# AGY: through the worker's inbox -> stdin of the live stream-json process. Works while the worker is alive
#      (running a turn or idle after one, up to -IdleMin 15). If it already exited, say.ps1 tells you; then
#      re-dispatch with -Resume. AGY queues a message sent mid-turn and answers it after the current turn.
param(
    [Parameter(Mandatory)][string]$RunDir,
    [string]$Text = '',
    [string]$Model = '',
    [switch]$Wait, [int]$WaitSec = 300,
    [switch]$Last, [switch]$Abort,
    [int]$Port = 4096
)
$ErrorActionPreference = 'Stop'
$isAgy = Test-Path (Join-Path $RunDir 'inbox')

if ($isAgy) {
    $lastFile = Join-Path $RunDir 'last-response.txt'
    $done = Join-Path $RunDir 'done.json'
    $wp = Join-Path $RunDir 'worker.pid'
    $alive = (Test-Path $wp) -and (Get-Process -Id ([int](Get-Content $wp -Raw)) -ErrorAction SilentlyContinue)
    if ($Last) { if (Test-Path $lastFile) { Get-Content $lastFile -Raw } else { '(no completed turn yet)' }; return }
    if ($Abort) {
        $pidf = Join-Path $RunDir 'pid'
        if (Test-Path $pidf) { & taskkill.exe /PID ([int](Get-Content $pidf -Raw)) /T /F | Out-Null }
        'ABORTED (AGY session ended; continue later with dispatch -Resume)'; return
    }
    if (-not $Text) { throw 'give -Text, -Last or -Abort' }
    if (-not $alive) { 'SESSION_ENDED: the AGY worker already exited (idle timeout/closed). Re-dispatch with -Resume and your message in the brief.'; exit 3 }
    Remove-Item $done -Force -ErrorAction SilentlyContinue      # so a waiter sees THIS turn's result, not the old one
    $f = Join-Path $RunDir ("inbox\{0}.txt" -f (Get-Date -Format 'yyyyMMddHHmmssfff'))
    [IO.File]::WriteAllText("$f.tmp", $Text, (New-Object Text.UTF8Encoding($false))); Move-Item "$f.tmp" $f
    'SENT'
    if ($Wait) {
        $deadline = (Get-Date).AddSeconds($WaitSec)
        while ((Get-Date) -lt $deadline) {
            Start-Sleep -Seconds 2
            if (Test-Path $done) { (Get-Content $done -Raw | ConvertFrom-Json).status; if (Test-Path $lastFile) { Get-Content $lastFile -Raw }; return }
        }
        'WAIT_EXPIRED (still working; use -Last later or -Abort)'
    }
    return
}

$sid = (Get-Content (Join-Path $RunDir 'session') -Raw).Trim()
$base = "http://127.0.0.1:$Port/session/$sid"

function Get-Msgs { Invoke-RestMethod "$base/message" -TimeoutSec 20 }
function Get-LastAssistant($msgs) {
    $a = @($msgs | Where-Object { $_.info.role -eq 'assistant' }) | Select-Object -Last 1
    if (-not $a) { return $null }
    [pscustomobject]@{ id = $a.info.id; done = [bool]$a.info.time.completed
                       text = (($a.parts | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join "`n") }
}

if ($Abort) { Invoke-RestMethod "$base/abort" -Method Post | Out-Null; 'ABORTED'; return }
if ($Last)  { $l = Get-LastAssistant (Get-Msgs); if ($l) { $l.text } else { '(no assistant message yet)' }; return }
if (-not $Text) { throw 'give -Text, -Last or -Abort' }

$before = Get-LastAssistant (Get-Msgs)
$body = @{ parts = @(@{ type = 'text'; text = $Text }) }
if ($Model) { $p,$m = $Model -split '/',2; $body.model = @{ providerID = $p; modelID = $m } }
Invoke-RestMethod "$base/prompt_async" -Method Post -ContentType 'application/json' `
    -Body ($body | ConvertTo-Json -Depth 6) | Out-Null
'SENT'
if ($Wait) {
    $deadline = (Get-Date).AddSeconds($WaitSec)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 2
        $l = Get-LastAssistant (Get-Msgs)
        if ($l -and $l.done -and (-not $before -or $l.id -ne $before.id)) { $l.text; return }
    }
    'WAIT_EXPIRED (still working; use -Last later or -Abort)'
}
