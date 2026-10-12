# Shared helpers, dot-sourced by the other scripts.
function Resolve-Agy {
    # AGY_PATH env override, then the default install location, then PATH.
    $c = @($env:AGY_PATH, (Join-Path $env:LOCALAPPDATA 'agy\bin\agy.exe')) |
        Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    if (-not $c) { $g = Get-Command agy.exe -ErrorAction SilentlyContinue; if ($g) { $c = $g.Source } }
    if (-not $c) { throw 'agy.exe not found. Install the Antigravity CLI or set the AGY_PATH environment variable to its full path.' }
    $c
}
