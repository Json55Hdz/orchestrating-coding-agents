# Runs ONE backend process with a watchdog. Internal: launched by dispatch.ps1 / viewer.ps1.
# Streams the child's output to this console (if visible) and to out.log.
#   opencode: `run --attach` one-shot; ends when the process ends.
#   agy:      ONE long-lived `--print` process in stream-json mode with stdin open. The first message is
#             the brief; later messages arrive via <RunDir>\inbox (say.ps1). After each turn it writes
#             done.json and waits idle (up to IdleMin, or until another job is queued) for follow-ups.
# done.json status: DONE | FAILED | STALLED | TIMEOUT  (AGY: rewritten at the end of every turn).
param(
    [Parameter(Mandatory)][string]$RunDir,
    [Parameter(Mandatory)][ValidateSet('opencode','agy')][string]$Backend,
    [Parameter(Mandatory)][string]$Dir,
    [Parameter(Mandatory)][string]$Prompt,
    [string]$Model = '',
    [string]$Url = '',
    [string]$SessionId = '',   # OpenCode: session pre-created by dispatch.ps1, so the viewer can attach immediately
    [string]$Title = 'task',
    [switch]$Resume,
    [double]$TimeoutMin = 30,   # per turn for AGY
    [double]$StallMin = 10,     # no output while a turn is running
    [double]$IdleMin = 15,      # AGY: stay alive this long after a turn, waiting for say.ps1 / Resume
    [string]$QueueDir = ''   # AGY under a viewer: a queued job ends the idle wait
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
$out   = Join-Path $RunDir 'out.log'
$done  = Join-Path $RunDir 'done.json'
$inbox = Join-Path $RunDir 'inbox'
$utf8  = New-Object System.Text.UTF8Encoding($false)
$isAgy = $Backend -eq 'agy'
function Q([string]$s) { '"' + ($s -replace '"','\"') + '"' }
try { $host.UI.RawUI.WindowTitle = "[$Backend] $Title" } catch {}
Set-Content -Path (Join-Path $RunDir 'worker.pid') -Value $PID

if (-not $isAgy) {
    $a = @('run','--attach',$Url,'--dir',$Dir,'--auto','--format','json','--title',$Title)
    if ($Model)  { $a += @('-m',$Model) }
    if ($SessionId) { $a += @('-s',$SessionId) } elseif ($Resume) { $a += '-c' }
    $a += $Prompt
    $oc = Resolve-OpenCode
    if (-not $oc) { throw 'opencode not found on PATH. Install it (npm i -g opencode-ai).' }
    if ($IsWin) { $exe = 'cmd.exe'; $argLine = '/c opencode.cmd ' + (($a | ForEach-Object { Q $_ }) -join ' ') }
    else { $exe = (Get-Command $oc).Source; $argLine = ($a | ForEach-Object { Q $_ }) -join ' ' }
} else {
    New-Item -ItemType Directory -Force $inbox | Out-Null
    $a = @('--dangerously-skip-permissions','--add-dir',$Dir,'--add-dir',$RunDir,'--project',$Title)
    if ($Resume) { $a = @('-c') + $a } else { $a += '--new-project' }
    if ($Model)  { $a += @('--model',$Model) }
    $a += @('--input-format','stream-json','--output-format','stream-json','--print','')
    $exe = Resolve-Agy
    $argLine = ($a | ForEach-Object { Q $_ }) -join ' '
}

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $exe; $psi.Arguments = $argLine; $psi.WorkingDirectory = $Dir
$psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
$psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
$psi.RedirectStandardInput = $isAgy
$psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8

$start = Get-Date
$script:turnStart = $start; $script:lastOut = $start; $script:idleSince = $null
$script:sent = 0; $script:results = 0; $script:turnTokens = 0; $script:convId = ''
$script:reply = New-Object System.Text.StringBuilder
$sw = $null

function Write-Done([string]$status, $code) {
    $o = [ordered]@{ status = $status; exitCode = $code; backend = $Backend; title = $Title
        seconds = [int]((Get-Date) - $start).TotalSeconds; log = $out; turn = $script:results
        tokens = $script:turnTokens; conversation = $script:convId
        lastResponse = (Join-Path $RunDir 'last-response.txt') }
    ($o | ConvertTo-Json) | Set-Content -Path $done -Encoding UTF8
}
function Send-User([string]$text) {
    $json = (@{ event = 'user'; message = @{ content = $text } } | ConvertTo-Json -Compress -Depth 5)
    $sw.WriteLine($json); $sw.Flush()
    $script:sent++
}
function Show-AgyLine([string]$line) {
    try { $j = $line | ConvertFrom-Json } catch { Write-Host $line; return }
    switch ($j.event) {
        'init' { $script:convId = $j.conversation_id
                 Write-Host ("> agy  model={0}  conversation={1}" -f $j.init.model, $j.conversation_id) -ForegroundColor Cyan }
        'step_update' {
            $s = $j.step_update
            if ($s.step_type -eq 'tool') {
                if ($s.state -eq 'ACTIVE') {
                    $ps = $s.tool_info.parameters; $sum = ''
                    if ($ps) { $sum = ($ps.PSObject.Properties | Select-Object -First 1).Value; if ("$sum".Length -gt 110) { $sum = "$sum".Substring(0,110) + '...' } }
                    Write-Host ("`n  > {0} {1}" -f $s.tool_name, $sum) -ForegroundColor Yellow
                } elseif ($s.state -eq 'DONE') {
                    Write-Host ("    done in {0:N1}s" -f $s.duration_seconds) -ForegroundColor DarkGray
                }
            } elseif ($s.step_type -eq 'agent_response' -and $s.text_delta) {
                Write-Host -NoNewline $s.text_delta
                [void]$script:reply.Append($s.text_delta)
            }
        }
        'result' {
            $r = $j.result; $script:results++; $script:turnTokens = $r.usage.total_tokens
            Set-Content -Path (Join-Path $RunDir 'last-response.txt') -Value $r.response -Encoding UTF8
            [void]$script:reply.Clear()
            $st = if ($r.status -eq 'SUCCESS') { 'DONE' } else { 'FAILED' }
            Write-Done $st $null
            if ($script:sent -le $script:results) { $script:idleSince = Get-Date }
            Write-Host ("`n=== turn {0}: {1}  ({2:N0} tokens, {3:N0}s) ===" -f $script:results, $r.status, $r.usage.total_tokens, $r.duration_seconds) -ForegroundColor Green
        }
        default { }
    }
}

Set-Content -Path (Join-Path $RunDir 'started') -Value (Get-Date -Format o)
$p = [Diagnostics.Process]::Start($psi)
Set-Content -Path (Join-Path $RunDir 'pid') -Value $p.Id
if ($isAgy) {
    $sw = New-Object IO.StreamWriter($p.StandardInput.BaseStream, $utf8)
    Send-User $Prompt
}
$tOut = $p.StandardOutput.ReadLineAsync(); $tErr = $p.StandardError.ReadLineAsync()
$status = $null
try {
    while ($true) {
        $got = $false
        foreach ($k in 'tOut','tErr') {
            $t = Get-Variable $k -ValueOnly
            if ($t -and $t.IsCompleted) {
                $line = $t.Result
                if ($null -eq $line) { Set-Variable $k $null; continue }
                [IO.File]::AppendAllText($out, $line + "`n", $utf8)
                if ($isAgy -and $k -eq 'tOut') { Show-AgyLine $line } else { Write-Host $line }
                $got = $true; $script:lastOut = Get-Date
                $s = if ($k -eq 'tOut') { $p.StandardOutput } else { $p.StandardError }
                Set-Variable $k $s.ReadLineAsync()
            }
        }
        if (-not $tOut -and -not $tErr) { break }

        if ($isAgy) {   # follow-up messages from say.ps1
            Get-ChildItem $inbox -Filter *.txt -ErrorAction SilentlyContinue | Sort-Object Name | ForEach-Object {
                $text = Get-Content $_.FullName -Raw; Remove-Item $_.FullName -Force
                Remove-Item $done -Force -ErrorAction SilentlyContinue
                Write-Host ("`n[you] {0}" -f $text) -ForegroundColor Magenta
                if ($script:sent -le $script:results) { $script:turnStart = Get-Date; $script:lastOut = Get-Date; $script:idleSince = $null }
                Send-User $text
            }
        }
        $now = Get-Date
        $busy = (-not $isAgy) -or ($script:sent -gt $script:results)
        if ($busy) {
            if (($now - $script:turnStart).TotalMinutes -gt $TimeoutMin) { $status = 'TIMEOUT'; break }
            if (($now - $script:lastOut).TotalMinutes  -gt $StallMin)   { $status = 'STALLED'; break }
        } else {
            if ($script:idleSince -and ($now - $script:idleSince).TotalMinutes -gt $IdleMin) { $status = 'IDLE_EXIT'; break }
            if ($QueueDir -and (Get-ChildItem $QueueDir -Filter *.json -ErrorAction SilentlyContinue)) { $status = 'IDLE_EXIT'; break }
        }
        if (-not $got) { Start-Sleep -Milliseconds 100 }
    }
} catch { $status = 'FAILED'; Write-Host "worker error: $_" }
finally {
    if ($sw) { try { $sw.Close() } catch {} }
    if (-not $p.WaitForExit(4000)) { Stop-Tree $p.Id }   # whole tree, shims included
}
$code = if ($p.HasExited) { $p.ExitCode } else { -1 }
if ($isAgy) {
    if ($status -in 'STALLED','TIMEOUT','FAILED' -or -not (Test-Path $done)) { Write-Done ($(if ($status) { $status } else { 'FAILED' })) $code }
} else {
    if (-not $status) { $status = if ($code -eq 0) { 'DONE' } else { 'FAILED' } }
    Write-Done $status $code
}
$final = if ($status -eq 'IDLE_EXIT') { 'session closed (idle)' } else { "$status (exit $code)" }
Write-Host "`n=== $final ===" -ForegroundColor Cyan
