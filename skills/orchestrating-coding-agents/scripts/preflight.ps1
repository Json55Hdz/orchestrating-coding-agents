# Checks everything the skill needs on this machine and says what to fix. Safe to run any time.
. (Join-Path $PSScriptRoot 'common.ps1')
$ok = $true
function Check([string]$name, [bool]$pass, [string]$fix) {
    if ($pass) { Write-Host ("[ OK ] {0}" -f $name) -ForegroundColor Green }
    else { Write-Host ("[FAIL] {0}`n       -> {1}" -f $name, $fix) -ForegroundColor Red; $script:ok = $false }
}
if ($IsWin) {
    Check "Windows PowerShell 5.1+ (running $($PSVersionTable.PSVersion))" ($PSVersionTable.PSVersion.Major -ge 5) 'Use Windows 10/11 with Windows PowerShell.'
    Check 'Windows Terminal (wt.exe), used for the persistent viewer tabs' ([bool](Get-Command wt.exe -ErrorAction SilentlyContinue)) 'Install "Windows Terminal" from the Microsoft Store (included in Windows 11). Without it viewers fall back to plain console windows.'
} else {
    Check "PowerShell 7+ (running $($PSVersionTable.PSVersion))" ($PSVersionTable.PSVersion.Major -ge 7) 'Install PowerShell 7: brew install --cask powershell (macOS) or https://aka.ms/powershell (Linux).'
    Check 'git on PATH' ([bool](Get-Command git -ErrorAction SilentlyContinue)) 'Install git.'
    if ($IsMac) { Check 'osascript (opens the viewer in Terminal.app)' ([bool](Get-Command osascript -ErrorAction SilentlyContinue)) 'osascript ships with macOS. Without it use dispatch -NoWindow.' }
    else {
        $t = @('x-terminal-emulator','gnome-terminal','konsole','xfce4-terminal','kitty','alacritty','xterm') | Where-Object { Get-Command $_ -ErrorAction SilentlyContinue } | Select-Object -First 1
        Check 'A terminal emulator and a display ($DISPLAY / $WAYLAND_DISPLAY), used for the viewer window' ([bool]$t -and [bool]($env:DISPLAY -or $env:WAYLAND_DISPLAY)) 'Install a terminal (gnome-terminal, konsole, xterm...) or run headless: dispatch -NoWindow, then peek.ps1.'
    }
}
$oc = Resolve-OpenCode
Check 'OpenCode CLI (opencode on PATH)' ([bool]$oc) 'npm i -g opencode-ai   (or see opencode.ai), then run `opencode providers login`.'
if ($oc) {
    $m = & $oc models 2>&1 | Where-Object { $_ -match '/' }
    Check 'OpenCode has at least one model available' ([bool]$m) 'Authenticate a provider: opencode providers login'
}
$agy = $null; try { $agy = Resolve-Agy } catch {}
Check 'AGY / Antigravity CLI (agy)' ([bool]$agy) 'Install the Antigravity CLI, or set AGY_PATH to the agy binary. Only needed if you will use AGY.'
if ($agy) {
    $m = & $agy models 2>&1 | Where-Object { $_ -notmatch '^Fetching' -and $_.Trim() }
    Check 'AGY signed in and listing models' ([bool]$m -and "$m" -notmatch 'error|login|auth') 'Run `agy` once interactively and sign in.'
}
Write-Host ''
Write-Host 'Manual step (cannot be automated): unattended AGY needs this permission rule in Claude Code,' -ForegroundColor Yellow
Write-Host '  Bash(agy --dangerously-skip-permissions:*)    add it with /permissions or in settings.json yourself.' -ForegroundColor Yellow
Write-Host 'The Claude Code Bash tool also needs to be allowed to run the PowerShell scripts from this folder (powershell on Windows, pwsh on macOS/Linux).' -ForegroundColor Yellow
if ($ok) { Write-Host "`nAll required checks passed." -ForegroundColor Green } else { exit 1 }
