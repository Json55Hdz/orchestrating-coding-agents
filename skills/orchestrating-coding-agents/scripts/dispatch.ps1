# One-call dispatch of a task to OpenCode or AGY with a REAL, PERSISTENT visible window.
#   OpenCode: shared headless `opencode serve` does the work; a persistent viewer tab shows the
#             real TUI (`opencode attach -s <session>`) and re-attaches itself for each new task.
#   AGY:      no server/attach exists, so a persistent viewer tab runs the worker inline
#             (the real process output, live) - not a tail of a file.
# The viewer tab is opened only if it is not already alive; later dispatches reuse it.
# Use -Slot <name> for a second concurrent viewer (parallel tasks). Prints RUN_DIR=...;
# completion signal is <RUN_DIR>\done.json (see wait.ps1).
param(
    [Parameter(Mandatory)][ValidateSet('opencode','agy')][string]$Backend,
    [Parameter(Mandatory)][string]$Dir,
    [Parameter(Mandatory)][string]$BriefFile,
    [string]$Name = 'task',
    [string]$Slot = 'main',
    [string]$Model = '',
    [switch]$Resume,
    [switch]$NoWindow,
    [double]$TimeoutMin = 30,
    [double]$StallMin = 10,
    [double]$IdleMin = 15,     # AGY: how long the session stays open after a turn
    [int]$Port = 4096
)
$ErrorActionPreference = 'Stop'
if (-not $Model) { throw "-Model is required. Run scripts\models.ps1, list the models to the user and ask which to use (see SKILL.md > Model selection). Never pick one yourself." }
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Dir = (Resolve-Path $Dir).Path
$BriefFile = (Resolve-Path $BriefFile).Path
$safe = ($Name -replace '[^\w\-]','_')
$run = Join-Path $env:TEMP ("agent-runs\{0}-{1}" -f $safe,(Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force $run | Out-Null
Copy-Item $BriefFile (Join-Path $run 'brief.md')
$brief = Join-Path $run 'brief.md'
Set-Content (Join-Path $run 'target-dir') $Dir
$bc = cmd.exe /c "git -C `"$Dir`" rev-parse HEAD 2>nul"   # via cmd: a non-repo must not raise a PowerShell error
if ($LASTEXITCODE -eq 0 -and $bc) { Set-Content (Join-Path $run 'base-commit') $bc }   # lets review.ps1 diff against the pre-dispatch state
$prompt = "Your full task brief is in the file $brief . Read it first, then do exactly what it says. Report in the format it asks for."
$url = "http://127.0.0.1:$Port"
$slots = Join-Path $env:TEMP 'agent-runs\slots'
$key = "$Backend-$Slot"
New-Item -ItemType Directory -Force $slots | Out-Null

function QJ([string[]]$a) { ($a | ForEach-Object { '"' + ([string]$_ -replace '"','\"') + '"' }) -join ' ' }
function Test-Server { try { Invoke-WebRequest "$url/" -UseBasicParsing -TimeoutSec 2 | Out-Null; $true } catch { [bool]$_.Exception.Response } }
function Test-ViewerAlive {
    $f = Join-Path $slots "$key.alive"
    if (-not (Test-Path $f)) { return $false }
    $id = [int](Get-Content $f -Raw)
    $pr = Get-Process -Id $id -ErrorAction SilentlyContinue
    return [bool]($pr -and $pr.ProcessName -match 'powershell')
}
# Returns 'reused' | 'opened' | 'failed'
function Ensure-Viewer {
    if (Test-ViewerAlive) { return 'reused' }
    Remove-Item (Join-Path $slots "$key.alive") -ErrorAction SilentlyContinue
    $cmd = @('powershell.exe','-NoExit','-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $here 'viewer.ps1'),
             '-Backend',$Backend,'-Slot',$Slot,'-Url',$url)
    try { Start-Process wt.exe -ArgumentList (QJ (@('-w','agents','new-tab','--title',"$Backend`:$Slot",'--') + $cmd)) | Out-Null }
    catch { Start-Process powershell.exe -ArgumentList (QJ $cmd[1..($cmd.Count-1)]) | Out-Null }
    1..40 | ForEach-Object { if (-not (Test-ViewerAlive)) { Start-Sleep -Milliseconds 500 } }
    if (Test-ViewerAlive) { 'opened' } else { 'failed' }
}

$workerParams = [ordered]@{
    RunDir = $run; Backend = $Backend; Dir = $Dir; Prompt = $prompt; Title = $Name
    TimeoutMin = $TimeoutMin; StallMin = $StallMin; IdleMin = $IdleMin
}
if ($Model)  { $workerParams.Model = $Model }
if ($Resume) { $workerParams.Resume = $true }

if ($Backend -eq 'opencode') {
    if (-not (Test-Server)) {
        Start-Process cmd.exe -WindowStyle Hidden -ArgumentList "/c opencode.cmd serve --port $Port > `"$run\server.log`" 2>&1" | Out-Null
        1..30 | ForEach-Object { if (-not (Test-Server)) { Start-Sleep -Milliseconds 500 } }
        if (-not (Test-Server)) { throw "opencode serve did not come up on $url (see $run\server.log)" }
    }
    $workerParams.Url = $url
    $sid = $null
    if (-not $Resume) {   # create the session up front: the viewer knows its id from second zero (no race on the first JSON event)
        try {
            $qd = [uri]::EscapeDataString($Dir)
            $sid = (Invoke-RestMethod "$url/session?directory=$qd" -Method Post -ContentType 'application/json' `
                    -Body (@{ title = $Name } | ConvertTo-Json) -TimeoutSec 15).id
            if ($sid) { $workerParams.SessionId = $sid }
        } catch { $sid = $null }
    }
    $wargs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $here 'worker.ps1'))
    foreach ($k in $workerParams.Keys) {
        if ($workerParams[$k] -is [bool]) { $wargs += "-$k" } else { $wargs += @("-$k",[string]$workerParams[$k]) }
    }
    Start-Process powershell.exe -WindowStyle Hidden -ArgumentList (QJ $wargs) | Out-Null
    1..150 | ForEach-Object {
        if ($sid) { return }
        if (-not $sid -and (Test-Path "$run\out.log")) {
            $m = Select-String -Path "$run\out.log" -Pattern '"sessionID"\s*:\s*"(ses_[A-Za-z0-9]+)"' | Select-Object -First 1
            if ($m) { $sid = $m.Matches[0].Groups[1].Value }
        }
        if (-not $sid) { Start-Sleep -Milliseconds 500 }
    }
    if ($sid) { Set-Content "$run\session" $sid }
    if (-not $NoWindow) {
        if (-not $sid) { "VIEWER=SKIPPED (no session id yet; check $run\out.log)" }
        else {
            $v = Ensure-Viewer
            if ($v -eq 'failed') { "VIEWER=FAILED (viewer tab did not start; task still runs - see $run\out.log)" }
            else {
                $ptr = [ordered]@{ session = $sid; dir = $Dir; run = $run; stamp = (Get-Date -Format o) } | ConvertTo-Json
                $tmp = Join-Path $slots "$key.cur.tmp"; Set-Content $tmp $ptr; Move-Item $tmp (Join-Path $slots "$key.cur") -Force
                Start-Sleep -Seconds 4
                $att = Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match ' attach ' -and $_.CommandLine -match [regex]::Escape($sid) }
                if ($att) { "VIEWER=OK ($v)" } else { "VIEWER=NOT_ATTACHED ($v; check the 'agents' window)" }
            }
        }
    }
} else {
    if ($NoWindow) {
        $wargs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',(Join-Path $here 'worker.ps1'))
        foreach ($k in $workerParams.Keys) { if ($workerParams[$k] -is [bool]) { $wargs += "-$k" } else { $wargs += @("-$k",[string]$workerParams[$k]) } }
        Start-Process powershell.exe -WindowStyle Hidden -ArgumentList (QJ $wargs) | Out-Null
    } else {
        $v = Ensure-Viewer
        if ($v -eq 'failed') { "VIEWER=FAILED (viewer tab did not start; nothing was run - use -NoWindow or retry)" }
        else {
            $jq = Join-Path $slots "$key.queue"
            $workerParams.QueueDir = $jq
            $tmp = Join-Path $run 'job.tmp'
            ($workerParams | ConvertTo-Json) | Set-Content $tmp -Encoding UTF8
            Move-Item $tmp (Join-Path $jq ("{0}-{1}.json" -f (Get-Date -Format 'yyyyMMddHHmmssfff'),$safe)) -Force
            1..30 | ForEach-Object { if (-not (Test-Path "$run\started")) { Start-Sleep -Milliseconds 500 } }
            if (Test-Path "$run\started") { "VIEWER=OK ($v)" } else { "VIEWER=NOT_STARTED ($v; viewer busy with an earlier job? it will run when free - queue: $jq)" }
        }
    }
}
"RUN_DIR=$run"
