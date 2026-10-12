# Deterministic check of the generated PowerShell team script: it must parse, and it must default the
# workload list to ios and android, either as the parameter default or as a constant assignment, so that
# running it without arguments installs both.
$ErrorActionPreference = 'Stop'
$candidate = Get-ChildItem -Path . -File | Where-Object { $_.Name -like 'install*.ps1' } | Select-Object -First 1
if (-not $candidate) { Write-Host 'FAIL  no install*.ps1 in the workspace'; exit 1 }
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($candidate.FullName, [ref]$tokens, [ref]$errors)
if ($errors) { $errors | ForEach-Object { Write-Host "FAIL  $($candidate.Name): $($_.Message)" }; exit 1 }
function Get-ConstantValues($expr) {
    if (-not $expr) { return @() }
    try { return @($expr.SafeGetValue()) } catch { return @() }
}
function Test-HasBoth($values) {
    # only string constants count: with a boolean on the left, -contains would coerce 'ios' to $true
    $strings = @($values | Where-Object { $_ -is [string] })
    return (($strings -contains 'ios') -and ($strings -contains 'android'))
}
$found = $false
if ($ast.ParamBlock) {
    foreach ($p in $ast.ParamBlock.Parameters) {
        if ($p.DefaultValue -and (Test-HasBoth (Get-ConstantValues $p.DefaultValue))) { $found = $true }
    }
}
if (-not $found) {
    $assignments = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)
    foreach ($a in $assignments) {
        $right = $a.Right
        if ($right -is [System.Management.Automation.Language.CommandExpressionAst]) { $right = $right.Expression }
        if (Test-HasBoth (Get-ConstantValues $right)) { $found = $true; break }
    }
}
if ($found) { Write-Host "ok    $($candidate.Name) defaults the workloads to ios and android"; exit 0 }
Write-Host "FAIL  $($candidate.Name): no parameter default or constant assignment with both ios and android"; exit 1
