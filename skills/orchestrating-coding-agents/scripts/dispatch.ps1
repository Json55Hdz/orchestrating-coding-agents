# One-call dispatch of a task to OpenCode or AGY with a REAL, PERSISTENT visible window.
#   OpenCode: shared headless `opencode serve` does the work; a persistent viewer tab shows the
#             real TUI (`opencode attach -s <session>`) and re-attaches itself for each new task.
#   AGY:      no server/attach exists, so a persistent viewer tab runs the worker inline
#             (the real process output, live) - not a tail of a file.
# The viewer tab is opened only if it is not already alive; later dispatches reuse it.
# Viewers are scoped per project dir (two projects never share a viewer).
# Use -Slot <name> for a second concurrent viewer within the same project (parallel tasks). Prints RUN_DIR=...;
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
. (Join-Path $PSScriptRoot 'common.ps1')
if (-not $Model) { throw "-Model is required. Run scripts/models.ps1, list the models to the user and ask which to use (see SKILL.md > Model selection). Never pick one yourself." }
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Dir = (Resolve-Path $Dir).Path
$BriefFile = (Resolve-Path $BriefFile).Path
$safe = ($Name -replace '[^\w\-]','_')
$runs = Get-RunsRoot
$run = Join-Path $runs ("{0}-{1}" -f $safe,(Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Force $run | Out-Null
Copy-Item $BriefFile (Join-Path $run 'brief.md')
$brief = Join-Path $run 'brief.md'
Set-Content (Join-Path $run 'target-dir') $Dir
$eap = $ErrorActionPreference; $ErrorActionPreference = 'Continue'   # a non-repo must not raise a PowerShell error
$bc = $null; $gitOk = $false
try { $bc = & git -C $Dir rev-parse HEAD 2>$null; $gitOk = ($LASTEXITCODE -eq 0) } catch {}
$ErrorActionPreference = $eap
if ($gitOk -and $bc) { Set-Content (Join-Path $run 'base-commit') $bc }   # lets review.ps1 diff against the pre-dispatch state
$prompt = "Your full task brief is in the file $brief . Read it first, then do exactly what it says. Report in the format it asks for."
$url = "http://127.0.0.1:$Port"
$slots = Join-Path $runs 'slots'
# Viewers are per project: the slot is scoped by the target dir so two projects never share (and hijack) a viewer.
$sha = [System.Security.Cryptography.SHA1]::Create()
$h6  = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Dir.ToLowerInvariant())) | Select-Object -First 3 | ForEach-Object { $_.ToString('x2') })
$Slot = "{0}-{1}-{2}" -f ((Split-Path $Dir -Leaf) -replace '[^\w\-]','_'),$h6,$Slot
$key = "$Backend-$Slot"
New-Item -ItemType Directory -Force $slots | Out-Null

function Start-Hidden([string]$file, [string[]]$a, [string]$out, [string]$err) {   # detached, no window; unix needs the std streams redirected or the caller's pipe stays open
    if ($IsWin) { Start-Process $file -WindowStyle Hidden -ArgumentList (QJ $a) | Out-Null }
    else {   # a plain child dies with this script; nohup + background in a throwaway sh detaches it
        $sq = { param($x) "'" + ([string]$x -replace "'","'\''") + "'" }
        $line = 'nohup ' + ((@($file) + $a | ForEach-Object { & $sq $_ }) -join ' ') + " >$(& $sq $out) 2>$(& $sq $err) </dev/null &"
        Start-Process sh -ArgumentList (QJ @('-c',$line)) -Wait | Out-Null
    }
}
function QJ([string[]]$a) { ($a | ForEach-Object { '"' + ([string]$_ -replace '"','\"') + '"' }) -join ' ' }
function Test-Server { try { Invoke-WebRequest "$url/" -UseBasicParsing -TimeoutSec 2 | Out-Null; $true } catch { [bool]$_.Exception.Response } }
function Test-ViewerAlive {
    $f = Join-Path $slots "$key.alive"
    if (-not (Test-Path $f)) { return $false }
    $id = [int](Get-Content $f -Raw)
    $pr = Get-Process -Id $id -ErrorAction SilentlyContinue
    return [bool]($pr -and $pr.ProcessName -match 'powershell|pwsh')
}
# Returns 'reused' | 'opened' | 'failed'
function Ensure-Viewer {
    if (Test-ViewerAlive) { return 'reused' }
    Remove-Item (Join-Path $slots "$key.alive") -ErrorAction SilentlyContinue
    $cmd = @($PsExe,'-NoExit') + $PsArgs + @('-File',(Join-Path $here 'viewer.ps1'),'-Backend',$Backend,'-Slot',$Slot,'-Url',$url)
    $title = "$Backend`:$Slot"
    try {
        if ($IsWin) {
            try { Start-Process wt.exe -ArgumentList (QJ (@('-w','agents','new-tab','--title',$title,'--') + $cmd)) | Out-Null }
            catch { Start-Process powershell.exe -ArgumentList (QJ $cmd[1..($cmd.Count-1)]) | Out-Null }
        } elseif ($IsMac) {
            $sh = ($cmd | ForEach-Object { "'" + ($_ -replace "'","'\''") + "'" }) -join ' '
            $as = $sh -replace '\\','\\\\' -replace '"','\"'
            Start-Hidden 'osascript' @('-e','tell application "Terminal" to activate','-e',"tell application `"Terminal`" to do script `"$as`"") (Join-Path $slots "$key.osa.out") (Join-Path $slots "$key.osa.err")
        } else {
            $term = @('x-terminal-emulator','gnome-terminal','konsole','xfce4-terminal','kitty','alacritty','xterm') |
                Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
            if (-not $term -or -not ($env:DISPLAY -or $env:WAYLAND_DISPLAY)) { return 'failed' }
            $targs = switch ($term) {
                'gnome-terminal' { @("--title=$title",'--') + $cmd }
                'xfce4-terminal' { @('--title',$title,'-x') + $cmd }
                default          { @('-e') + $cmd }
            }
            Start-Hidden $term $targs (Join-Path $slots "$key.term.out") (Join-Path $slots "$key.term.err")
        }
    } catch { return 'failed' }
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
        if ($IsWin) { Start-Process cmd.exe -WindowStyle Hidden -ArgumentList "/c opencode.cmd serve --port $Port > `"$run/server.log`" 2>&1" | Out-Null }
        else { Start-Hidden 'opencode' @('serve','--port',"$Port") "$run/server.log" "$run/server.err" }
        1..30 | ForEach-Object { if (-not (Test-Server)) { Start-Sleep -Milliseconds 500 } }
        if (-not (Test-Server)) { throw "opencode serve did not come up on $url (see $run/server.log)" }
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
    $wargs = $PsArgs + @('-File',(Join-Path $here 'worker.ps1'))
    foreach ($k in $workerParams.Keys) {
        if ($workerParams[$k] -is [bool]) { $wargs += "-$k" } else { $wargs += @("-$k",[string]$workerParams[$k]) }
    }
    Start-Hidden $PsExe $wargs "$run/worker.stdout" "$run/worker.stderr"
    1..150 | ForEach-Object {
        if ($sid) { return }
        if (-not $sid -and (Test-Path "$run/out.log")) {
            $m = Select-String -Path "$run/out.log" -Pattern '"sessionID"\s*:\s*"(ses_[A-Za-z0-9]+)"' | Select-Object -First 1
            if ($m) { $sid = $m.Matches[0].Groups[1].Value }
        }
        if (-not $sid) { Start-Sleep -Milliseconds 500 }
    }
    if ($sid) { Set-Content "$run/session" $sid }
    if (-not $NoWindow) {
        if (-not $sid) { "VIEWER=SKIPPED (no session id yet; check $run/out.log)" }
        else {
            $v = Ensure-Viewer
            if ($v -eq 'failed') { "VIEWER=FAILED (viewer tab did not start; task still runs - see $run/out.log)" }
            else {
                $ptr = [ordered]@{ session = $sid; dir = $Dir; run = $run; stamp = (Get-Date -Format o) } | ConvertTo-Json
                $tmp = Join-Path $slots "$key.cur.tmp"; Set-Content $tmp $ptr; Move-Item $tmp (Join-Path $slots "$key.cur") -Force
                Start-Sleep -Seconds 4
                if (Test-CommandLineRunning @(' attach ',$sid)) { "VIEWER=OK ($v)" } else { "VIEWER=NOT_ATTACHED ($v; check the 'agents' window)" }
            }
        }
    }
} else {
    if ($NoWindow) {
        $wargs = $PsArgs + @('-File',(Join-Path $here 'worker.ps1'))
        foreach ($k in $workerParams.Keys) { if ($workerParams[$k] -is [bool]) { $wargs += "-$k" } else { $wargs += @("-$k",[string]$workerParams[$k]) } }
        Start-Hidden $PsExe $wargs "$run/worker.stdout" "$run/worker.stderr"
    } else {
        $v = Ensure-Viewer
        if ($v -eq 'failed') { "VIEWER=FAILED (viewer tab did not start; nothing was run - use -NoWindow or retry)" }
        else {
            $jq = Join-Path $slots "$key.queue"
            $workerParams.QueueDir = $jq
            $tmp = Join-Path $run 'job.tmp'
            ($workerParams | ConvertTo-Json) | Set-Content $tmp -Encoding UTF8
            Move-Item $tmp (Join-Path $jq ("{0}-{1}.json" -f (Get-Date -Format 'yyyyMMddHHmmssfff'),$safe)) -Force
            1..30 | ForEach-Object { if (-not (Test-Path "$run/started")) { Start-Sleep -Milliseconds 500 } }
            if (Test-Path "$run/started") { "VIEWER=OK ($v)" } else { "VIEWER=NOT_STARTED ($v; viewer busy with an earlier job? it will run when free - queue: $jq)" }
        }
    }
}
"RUN_DIR=$run"
