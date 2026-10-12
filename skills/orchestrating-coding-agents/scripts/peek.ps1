# Compact progress of a run, so Claude never reads the raw out.log (JSON, can be hundreds of KB).
#   peek.ps1 -RunDir <RUN_DIR> [-Lines 15]
param([Parameter(Mandatory)][string]$RunDir, [int]$Lines = 15)
$log  = Join-Path $RunDir 'out.log'
$done = Join-Path $RunDir 'done.json'
$isAgy = Test-Path (Join-Path $RunDir 'inbox')
function T([object]$s, [int]$n = 140) { $s = ("$s" -replace '\s+',' ').Trim(); $s = $s -replace '[A-Za-z]:\\(?:[^\\ "]+\\)+([^\\ "]+\\[^\\ "]+)','...\$1'; if ($s.Length -gt $n) { $s.Substring(0,$n) + '...' } else { $s } }

$head = 'RUNNING'
if (Test-Path $done) { $d = Get-Content $done -Raw | ConvertFrom-Json; $head = "{0} (turn {1}, {2}s, tokens {3})" -f $d.status, $d.turn, $d.seconds, $d.tokens }
elseif (-not (Test-Path $log)) { $head = 'NOT STARTED (no output yet)' }
else { $age = [int]((Get-Date) - (Get-Item $log).LastWriteTime).TotalSeconds; $head = "RUNNING (last output ${age}s ago)" }
"[{0}] {1}  {2}" -f $(if ($isAgy) { 'agy' } else { 'opencode' }), (Split-Path $RunDir -Leaf), $head
if (-not (Test-Path $log)) { return }

$items = New-Object System.Collections.Generic.List[string]
$say = New-Object System.Text.StringBuilder
function Flush-Say { if ($say.Length -gt 0) { $items.Add('say: ' + (T $say.ToString() 220)); [void]$say.Clear() } }
foreach ($line in (Get-Content $log -Tail 600)) {
    try { $j = $line | ConvertFrom-Json } catch { continue }
    if ($isAgy) {
        if ($j.event -eq 'step_update') {
            $s = $j.step_update
            if ($s.step_type -eq 'tool' -and $s.state -eq 'ACTIVE') {
                Flush-Say
                $sum = ''; if ($s.tool_info.parameters) { $sum = ($s.tool_info.parameters.PSObject.Properties | Select-Object -First 1).Value }
                $items.Add("> $($s.tool_name) $(T $sum 110)")
            } elseif ($s.step_type -eq 'agent_response' -and $s.text_delta) { [void]$say.Append($s.text_delta) }
        } elseif ($j.event -eq 'result') {
            Flush-Say; $items.Add(("= turn {0} {1} ({2} tokens)" -f $j.result.num_turns, $j.result.status, $j.result.usage.total_tokens))
        }
    } else {
        switch ($j.type) {
            'tool_use' { Flush-Say
                $in = ''; if ($j.part.state.input) { $in = ($j.part.state.input.PSObject.Properties | Select-Object -First 1).Value }
                $items.Add(("> {0} {1} [{2}]" -f $j.part.tool, (T $in 110), $j.part.state.status)) }
            'text'     { $items.Add('say: ' + (T $j.part.text 220)) }
            'error'    { $items.Add('ERROR: ' + (T ($j.error | ConvertTo-Json -Compress -Depth 4) 200)) }
        }
    }
}
Flush-Say
$items | Select-Object -Last $Lines
