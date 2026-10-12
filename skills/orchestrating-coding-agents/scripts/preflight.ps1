# Checks everything the skill needs on this machine and says what to fix. Safe to run any time.
. (Join-Path $PSScriptRoot 'common.ps1')
$ok = $true
function Check([string]$name, [bool]$pass, [string]$fix) {
    if ($pass) { Write-Host ("[ OK ] {0}" -f $name) -ForegroundColor Green }
    else { Write-Host ("[FAIL] {0}`n       -> {1}" -f $name, $fix) -ForegroundColor Red; $script:ok = $false }
}
Check "Windows PowerShell 5.1+ (running $($PSVersionTable.PSVersion))" ($PSVersionTable.PSVersion.Major -ge 5) 'Use Windows 10/11 with Windows PowerShell.'
Check 'Windows Terminal (wt.exe), used for the persistent viewer tabs' ([bool](Get-Command wt.exe -ErrorAction SilentlyContinue)) 'Install "Windows Terminal" from the Microsoft Store (included in Windows 11). Without it viewers fall back to plain console windows.'
$oc = Get-Command opencode.cmd -ErrorAction SilentlyContinue
Check 'OpenCode CLI (opencode.cmd on PATH)' ([bool]$oc) 'npm i -g opencode-ai   (or see opencode.ai), then run `opencode providers login`.'
if ($oc) {
    $m = & opencode.cmd models 2>&1 | Where-Object { $_ -match '/' }
    Check 'OpenCode has at least one model available' ([bool]$m) 'Authenticate a provider: opencode providers login'
}
$agy = $null; try { $agy = Resolve-Agy } catch {}
Check 'AGY / Antigravity CLI (agy.exe)' ([bool]$agy) 'Install the Antigravity CLI, or set AGY_PATH to agy.exe. Only needed if you will use AGY.'
if ($agy) {
    $m = & $agy models 2>&1 | Where-Object { $_ -notmatch '^Fetching' -and $_.Trim() }
    Check 'AGY signed in and listing models' ([bool]$m -and "$m" -notmatch 'error|login|auth') 'Run `agy` once interactively and sign in.'
}
Write-Host ''
Write-Host 'Manual step (cannot be automated): unattended AGY needs this permission rule in Claude Code,' -ForegroundColor Yellow
Write-Host '  Bash(agy --dangerously-skip-permissions:*)    add it with /permissions or in settings.json yourself.' -ForegroundColor Yellow
Write-Host 'The Claude Code Bash tool also needs to be allowed to run powershell scripts from this folder.' -ForegroundColor Yellow
if ($ok) { Write-Host "`nAll required checks passed." -ForegroundColor Green } else { exit 1 }
