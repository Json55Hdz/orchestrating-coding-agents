# Lists the models both backends can actually use right now (authenticated), for the pre-dispatch question.
param([ValidateSet('both','opencode','agy')][string]$Backend = 'both')
. (Join-Path $PSScriptRoot 'common.ps1')
if ($Backend -ne 'agy') {
    '=== OPENCODE (pass as provider/model) ==='
    & (Resolve-OpenCode) models 2>&1 | Where-Object { $_ -match '/' }
}
if ($Backend -ne 'opencode') {
    if ($Backend -eq 'both') { '' }
    '=== AGY (pass the id on the left) ==='
    & (Resolve-Agy) models 2>&1 | Where-Object { $_ -notmatch '^Fetching' }
}
