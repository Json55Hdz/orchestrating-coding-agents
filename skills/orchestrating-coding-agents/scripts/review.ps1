# Compact review of what an agent changed, plus the COMPLETE diff saved to a file.
# Claude reads this summary first and opens full.diff (or just specific files) only if something looks off.
#   review.ps1 -RunDir <RUN_DIR> [-Dir <repo>] [-Report <report file>]
param(
    [Parameter(Mandatory)][string]$RunDir,
    [string]$Dir = '',
    [string]$Report = ''
)
$ErrorActionPreference = 'Continue'
$tf = Join-Path $RunDir 'target-dir'; $bf = Join-Path $RunDir 'base-commit'
if (-not $Dir -and (Test-Path $tf)) { $Dir = (Get-Content $tf -Raw).Trim() }
if (-not $Dir) { throw 'give -Dir (repo path)' }
$base = if (Test-Path $bf) { (Get-Content $bf -Raw).Trim() } else { '' }
$full = Join-Path $RunDir 'full.diff'
function G { & git -c core.safecrlf=false -C $Dir @args 2>$null }   # stderr is only CRLF/locale warnings here

if (-not ((G rev-parse --is-inside-work-tree) -eq 'true')) { "Not a git repo: $Dir. Inspect files directly."; return }
if (-not $base) { $base = 'HEAD'; "(no base commit recorded for this run; comparing against current HEAD = uncommitted changes only)" }

"== Commits by the agent since dispatch ($base..HEAD)"
$c = G log --oneline "$base..HEAD"; if ($c) { $c } else { '(none)' }

"`n== Files changed (vs $($base.Substring(0,[Math]::Min(8,$base.Length))), incl. uncommitted)"
G diff --stat=100 $base
$untracked = @(G ls-files --others --exclude-standard)
if ($untracked) { "`nUntracked (new, not yet added):"; $untracked | ForEach-Object { "  ?? $_" } }

# full diff = tracked changes + new files, saved for on-demand reading
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine((G diff $base) -join "`n")
foreach ($u in $untracked) {
    $p = Join-Path $Dir $u
    if ((Test-Path $p -PathType Leaf) -and (Get-Item $p).Length -lt 200KB) {
        [void]$sb.AppendLine("diff --git a/$u b/$u`nnew file`n--- /dev/null`n+++ b/$u")
        foreach ($l in (Get-Content $p)) { [void]$sb.AppendLine("+$l") }
    } else { [void]$sb.AppendLine("# (skipped untracked: $u - directory, binary or >200KB)") }
}
[IO.File]::WriteAllText($full, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
$n = ($sb.ToString() -split "`n").Count
"`n== Full diff: $full  ($n lines). Read it (or `git -C `"$Dir`" diff $base -- <file>`) if anything above looks wrong."

# quick red flags
$flags = @()
$gs = G status --short
if ((G diff --name-only $base) -match '(^|/)(\.env|.*secret.*|.*credential.*)') { $flags += 'touches env/secret-looking files' }
if ((G log --format=%s "$base..HEAD") -match 'push') { $flags += 'a commit message mentions push' }
"`n== Red flags: " + $(if ($flags) { $flags -join '; ' } else { 'none found by the script (still read the diff for logic errors)' })

$rp = if ($Report) { $Report } else { $null }
if ($rp -and (Test-Path $rp)) { "`n== Agent report ($rp), first 40 lines"; Get-Content $rp -TotalCount 40 }
elseif (Test-Path (Join-Path $RunDir 'last-response.txt')) { "`n== Agent's last reply (first 40 lines)"; Get-Content (Join-Path $RunDir 'last-response.txt') -TotalCount 40 }
