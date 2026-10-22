# Shared helpers, dot-sourced by the other scripts. Runs on Windows PowerShell 5.1 and on PowerShell 7 (pwsh) on macOS/Linux.
$script:IsWin = ($PSVersionTable.PSVersion.Major -lt 6) -or [bool]$IsWindows
$script:IsMac = (-not $script:IsWin) -and [bool]$IsMacOS

# Executable used to launch the other scripts as child processes.
$script:PsExe = if ($script:IsWin) { 'powershell.exe' } else { (Get-Process -Id $PID).Path }
$script:PsArgs = @(if ($script:IsWin) { '-NoProfile','-ExecutionPolicy','Bypass' } else { '-NoProfile' })

function Get-RunsRoot {
    # %TEMP%\agent-runs on Windows. Elsewhere a per-user location, never the shared /tmp (another user could plant jobs):
    # $XDG_RUNTIME_DIR, else $TMPDIR (private on macOS), else ~/.cache. The band mod uses the same order.
    $t = if ($script:IsWin) { $env:TEMP } elseif ($env:XDG_RUNTIME_DIR) { $env:XDG_RUNTIME_DIR } elseif ($env:TMPDIR) { $env:TMPDIR } else { Join-Path $HOME '.cache' }
    $r = Join-Path $t.TrimEnd('/', '\') 'agent-runs'
    if (-not $script:IsWin) {
        if (-not (Test-Path $r)) { New-Item -ItemType Directory -Force $r | Out-Null }
        & chmod 700 $r 2>$null
    }
    $r
}

function Resolve-Agy {
    # AGY_PATH env override, then the default install location, then PATH.
    $names = if ($script:IsWin) { @('agy.exe') } else { @('agy') }
    $def = if ($script:IsWin) { Join-Path $env:LOCALAPPDATA 'agy\bin\agy.exe' } else { Join-Path $HOME '.local/bin/agy' }
    $c = @($env:AGY_PATH, $def) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $c) { $g = Get-Command $names[0] -ErrorAction SilentlyContinue; if ($g) { $c = $g.Source } }
    if (-not $c) { throw "$($names[0]) not found. Install the Antigravity CLI or set the AGY_PATH environment variable to its full path." }
    $c
}

# Command name of the OpenCode CLI ('opencode.cmd' is the npm shim on Windows); $null when it is not on PATH.
function Resolve-OpenCode {
    $n = if ($script:IsWin) { 'opencode.cmd' } else { 'opencode' }
    if (Get-Command $n -ErrorAction SilentlyContinue) { $n } else { $null }
}

# Kill a process and everything under it (shims and child CLIs included).
function Stop-Tree([int]$ProcId) {
    if ($script:IsWin) { & taskkill.exe /PID $ProcId /T /F 2>&1 | Out-Null; return }
    $kids = & pgrep -P $ProcId 2>$null
    foreach ($k in $kids) { if ($k) { Stop-Tree ([int]$k) } }
    Stop-Process -Id $ProcId -Force -ErrorAction SilentlyContinue
}

# True when a process whose command line contains all of the given fragments is running.
function Test-CommandLineRunning([string[]]$Fragments) {
    if ($script:IsWin) {
        $q = Get-CimInstance Win32_Process | Where-Object { $c = $_.CommandLine; $c -and -not (@($Fragments | Where-Object { $c -notlike "*$_*" })) }
        return [bool]$q
    }
    $q = & ps -axo args= 2>$null | Where-Object { $c = $_; -not (@($Fragments | Where-Object { $c -notlike "*$_*" })) }
    [bool]$q
}
