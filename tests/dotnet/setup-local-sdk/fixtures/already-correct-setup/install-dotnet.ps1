param([string[]]$Workloads = @())
$ErrorActionPreference = 'Stop'
$installDir = '.dotnet'; $channel = '11.0'; $quality = 'preview'
$version = '11.0.100-rc.1.26425.128'; $rollForward = 'latestFeature'; $allowPrerelease = $true
$errorMessage = 'Required .NET SDK not found. Run ./install-dotnet.sh (or .ps1) to install it locally.'
$installScript = Join-Path $env:TEMP "dotnet-install-$([guid]::NewGuid()).ps1"
try {
    Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile $installScript
    $installArgs = @('-InstallDir', $installDir)
    if ($version) {
        $installArgs += @('-Version', $version)
        $rollForward = 'disable'
    } else {
        $installArgs += @('-Channel', $channel, '-Quality', $quality)
    }
    & $installScript @installArgs; if ($LASTEXITCODE) { throw "dotnet-install failed with exit code $LASTEXITCODE" }  # a child script's exit code is not terminating
}
finally {
    if (Test-Path -LiteralPath $installScript) {
        Remove-Item -LiteralPath $installScript -Force
    }
}
$sdkVersion = & "$installDir\dotnet.exe" --version
$globalJson = if (Test-Path 'global.json') {
    Copy-Item 'global.json' 'global.json.bak'
    Get-Content -Path 'global.json' -Raw | ConvertFrom-Json
} else {
    [pscustomobject]@{}
}
if (-not $globalJson.PSObject.Properties['sdk']) {
    $globalJson | Add-Member -MemberType NoteProperty -Name 'sdk' -Value ([pscustomobject]@{})
}
$updates = [ordered]@{
    version = $sdkVersion
    allowPrerelease = $allowPrerelease
    rollForward = $rollForward
    paths = @('.dotnet', '$host$')
    errorMessage = $errorMessage
}
foreach ($entry in $updates.GetEnumerator()) {
    $property = $globalJson.sdk.PSObject.Properties[$entry.Key]
    if ($property) {
        $property.Value = $entry.Value
    } else {
        $globalJson.sdk | Add-Member -MemberType NoteProperty -Name $entry.Key -Value $entry.Value
    }
}
$globalJson | ConvertTo-Json -Depth 10 | Set-Content -Path 'global.json' -Encoding UTF8
if (-not (Test-Path .gitignore) -or -not (Select-String -Path .gitignore -Pattern '^\.dotnet/$' -Quiet)) {
    Add-Content -Path .gitignore -Value '.dotnet/'
}
if ($quality -eq 'daily') {
    # a daily's runtime and reference packs are not on nuget.org: every restore needs the feed, workloads or not; the messages must stand alone in the team's repo
    $major = "$sdkVersion".Split('.')[0]
    $sources = & "$installDir\dotnet.exe" nuget list source --format Short  # the effective configuration: E enabled, D disabled
    if (-not ($sources | Where-Object { "$_".Trim() -eq "E https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet$major/nuget/v3/index.json" })) {
        throw "Daily SDK: no enabled dotnet$major feed in the effective NuGet configuration. Add https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet$major/nuget/v3/index.json to NuGet.config, plus the darc-pub-* feeds that dotnet/maui's NuGet.config lists for this band, then rerun."
    }
}
if ($Workloads.Count -gt 0) {
    if ($quality -eq 'daily') {
        & "$installDir\dotnet.exe" workload config --update-mode manifests  # a daily band has no manifests on nuget.org and no workload set
        if ($LASTEXITCODE -ne 0) { throw "workload config --update-mode manifests failed with exit code $LASTEXITCODE" }
    }
    & "$installDir\dotnet.exe" workload install @Workloads; $rc = $LASTEXITCODE
    if ($quality -eq 'daily') {
        & "$installDir\dotnet.exe" build-server shutdown | Out-Null; if ($LASTEXITCODE -ne 0) { throw "build-server shutdown failed with exit code $LASTEXITCODE" }  # even after a failed install
        if ($rc -ne 0) { throw "workload install failed with exit code $rc" }
        # the install also succeeds after falling back to bundled manifests of an older band, or to a build of
        # another lane publishing into the band (a main build in an rc band): check band and lane of every manifest
        $band = "$sdkVersion" -replace '^(\d+\.\d+\.\d)\d\d(-(preview|rc|alpha)\.\d+)?.*$', '${1}00$2'
        $lane = if ($band -match '-(rc|preview)\.(\d+)$') { "($($Matches[1])\.$($Matches[2])|-p$($Matches[2]))(\D|`$)" } else { '' }  # rc.2 or -p2 in the version; none for alpha or rtm
        $list = & "$installDir\dotnet.exe" workload list
        foreach ($w in $Workloads) {
            $ver = $list | Where-Object { ($_ -split '\s+')[0] -eq $w } | ForEach-Object { ($_ -split '\s+')[1] } | Select-Object -First 1  # <manifest version>/<band>
            if (-not ($ver -and $ver.EndsWith("/$band") -and (-not $lane -or $ver.Split('/')[0] -match $lane))) {
                $list | Write-Host; throw "workload ${w}: $(if ($ver) { $ver } else { 'missing' }) is not a $band build of the SDK's lane: the installer took a bundled or other-lane manifest. Extract the data\ folder of the right <id>.Manifest-$band package into $installDir\sdk-manifests\$band\<id>\<version>\, delete the other version folders of that id and $installDir\metadata\workloads\*\$band\InstallState\default.json, then rerun with workload install --skip-manifest-update."
            }
        }
    }
    if ($rc -ne 0) { throw "workload install failed with exit code $rc" }
}
Write-Host "Done. SDK: $sdkVersion"
