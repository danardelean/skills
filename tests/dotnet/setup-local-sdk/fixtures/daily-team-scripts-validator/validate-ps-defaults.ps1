# Deterministic checks of the generated PowerShell team script, through the PowerShell parser:
#   1. it parses
#   2. it defaults the workload list to ios and android (the Workloads parameter default, or a constant
#      assignment to $Workloads), so that running it without arguments installs both
#   3. every native call whose failure must stop the script is followed by a $LASTEXITCODE check:
#      the downloaded dotnet-install script, workload config, workload install, build-server shutdown
#      ($ErrorActionPreference = 'Stop' does not make a native exit code terminating)
$ErrorActionPreference = 'Stop'
$candidate = Get-ChildItem -Path . -File | Where-Object { $_.Name -like 'install*.ps1' } | Select-Object -First 1
if (-not $candidate) { Write-Host 'FAIL  no install*.ps1 in the workspace'; exit 1 }
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($candidate.FullName, [ref]$tokens, [ref]$errors)
if ($errors) { $errors | ForEach-Object { Write-Host "FAIL  $($candidate.Name): $($_.Message)" }; exit 1 }
$failures = 0
function Get-ConstantValues($expr) {
    if (-not $expr) { return @() }
    try { return @($expr.SafeGetValue()) } catch { return @() }
}
function Test-HasBoth($values) {
    # only string constants count: with a boolean on the left, -contains would coerce 'ios' to $true
    $strings = @($values | Where-Object { $_ -is [string] })
    return (($strings -contains 'ios') -and ($strings -contains 'android'))
}
function Get-VariableName($expr) {
    while ($expr -is [System.Management.Automation.Language.ConvertExpressionAst] -or $expr -is [System.Management.Automation.Language.AttributedExpressionAst]) { $expr = $expr.Child }
    if ($expr -is [System.Management.Automation.Language.VariableExpressionAst]) { return $expr.VariablePath.UserPath }
    return ''
}
# 2. default workloads
$found = $false
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
if ($found) { Write-Host "ok    $($candidate.Name) defaults `$Workloads to ios and android" }
else { Write-Host "FAIL  $($candidate.Name): neither the Workloads parameter default nor an assignment to `$Workloads holds both ios and android"; $failures++ }
# 3. failure propagation: the statement right after each native call must look at $LASTEXITCODE, either
#    `if ($LASTEXITCODE ...) { throw/exit }` or `$x = $LASTEXITCODE` with a later `if (... $x ...) { throw/exit }`
function Get-NextStatementText($node) {
    $stmt = $node
    while ($stmt -and -not (($stmt.Parent -is [System.Management.Automation.Language.StatementBlockAst]) -or ($stmt.Parent -is [System.Management.Automation.Language.NamedBlockAst]))) { $stmt = $stmt.Parent }
    if (-not $stmt) { return '' }
    $siblings = @($stmt.Parent.Statements)
    for ($i = 0; $i -lt $siblings.Count; $i++) {
        if ([object]::ReferenceEquals($siblings[$i], $stmt)) { if ($i + 1 -lt $siblings.Count) { return $siblings[$i + 1].Extent.Text } else { return '' } }
    }
    return ''
}
$ifs = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.IfStatementAst] }, $true))
$commands = @($ast.FindAll({ $args[0] -is [System.Management.Automation.Language.CommandAst] }, $true))
$required = @(
    @{ name = 'dotnet-install script'; pattern = '@installArgs|-InstallDir' },
    @{ name = 'workload config';       pattern = 'workload\s+config' },
    @{ name = 'workload install';      pattern = 'workload\s+install' },
    @{ name = 'build-server shutdown'; pattern = 'build-server\s+shutdown' }
)
foreach ($r in $required) {
    $cmd = $commands | Where-Object { $_.Extent.Text -match $r.pattern } | Select-Object -First 1
    if (-not $cmd) { Write-Host "FAIL  no $($r.name) call found"; $failures++; continue }
    $next = Get-NextStatementText $cmd
    $ok = $false
    if ($next -match 'LASTEXITCODE') {
        if ($next -match '^\s*\$(\w+)\s*=\s*\$LASTEXITCODE\s*$') {
            $var = $Matches[1]
            # an IfStatementAst keeps its conditions in Clauses[i].Item1
            $ok = [bool]($ifs | Where-Object { (($_.Clauses | ForEach-Object { $_.Item1.Extent.Text }) -join ' ') -match ('\$' + $var + '\b') -and $_.Extent.Text -match '\b(throw|exit)\b' })
        } else {
            $ok = ($next -match '\b(throw|exit)\b')
        }
    }
    if ($ok) { Write-Host "ok    $($r.name): exit code checked" } else { Write-Host "FAIL  $($r.name): the next statement does not check `$LASTEXITCODE and stop ($next)"; $failures++ }
}
if ($failures -eq 0) { Write-Host 'all checks passed'; exit 0 }
Write-Host "$failures check(s) failed"; exit 1
