# Deterministic check of the generated PowerShell team script: it must parse, and it must default the
# workload list to ios and android, either as the default of the Workloads parameter or as a constant
# assignment to $Workloads, so that running it without arguments installs both.
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
function Get-VariableName($expr) {
    while ($expr -is [System.Management.Automation.Language.ConvertExpressionAst] -or $expr -is [System.Management.Automation.Language.AttributedExpressionAst]) { $expr = $expr.Child }
    if ($expr -is [System.Management.Automation.Language.VariableExpressionAst]) { return $expr.VariablePath.UserPath }
    return ''
}
if ($ast.ParamBlock) {
    foreach ($p in $ast.ParamBlock.Parameters) {
        if ($p.Name.VariablePath.UserPath -eq 'Workloads' -and $p.DefaultValue -and (Test-HasBoth (Get-ConstantValues $p.DefaultValue))) { $found = $true }
    }
}
if (-not $found) {
    # fallback: a constant assignment to $Workloads itself, not to any other variable
    $assignments = $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.AssignmentStatementAst] }, $true)
    foreach ($a in $assignments) {
        if ((Get-VariableName $a.Left) -ne 'Workloads') { continue }
        $right = $a.Right
        if ($right -is [System.Management.Automation.Language.CommandExpressionAst]) { $right = $right.Expression }
        if (Test-HasBoth (Get-ConstantValues $right)) { $found = $true; break }
    }
}
if ($found) { Write-Host "ok    $($candidate.Name) defaults `$Workloads to ios and android"; exit 0 }
Write-Host "FAIL  $($candidate.Name): neither the Workloads parameter default nor an assignment to `$Workloads holds both ios and android"; exit 1
