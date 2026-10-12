---
name: setup-local-sdk
license: MIT
description: >
  Install a .NET SDK locally for safe preview testing, specific-version pinning, or
  reproducible team setups — without modifying the system-wide installation.
  USE FOR: trying .NET previews safely, testing specific SDK versions, installing MAUI
  or other workloads on a preview, trying a daily build (nightly) of an unreleased
  SDK such as the next release candidate or the next major and its workloads,
  choosing the daily channel for a lane, fixing "No workload update found" or
  "package not found in NuGet feeds" on a daily SDK, updating or replacing an
  existing local SDK, creating reproducible team/CI install scripts, configuring
  global.json paths.
  DO NOT USE FOR: system-wide SDK installs, .NET hosts older than 10, runtime-only
  installs, or projects not using SDK-style commands.
---

# setup-local-sdk

## Purpose

Guide the user through installing a .NET SDK into a project-local `.dotnet/`
directory and wiring it up via the `global.json` `paths` feature (.NET 10+).
The examples use .NET 11, but this works with any version — prerelease or stable.

The result is a fully isolated SDK that:
- Does **not** modify the system-wide .NET installation.
- Is picked up automatically by `dotnet` commands from the project root.
- Can be deleted to revert (`rm -rf .dotnet/` or `Remove-Item -Recurse -Force .\.dotnet`).

## When NOT to use

- User wants a **system-wide** install — direct to the official installer.
- Host `dotnet` is **older than v10** — `paths` doesn't exist; explain and stop.
- User needs a **runtime-only** install — `paths` applies to SDK resolution only.

## Inputs / Prerequisites

| Input | Required | Default | Notes |
|---|---|---|---|
| Channel or version | No | `11.0` | e.g. `11.0`, `STS`, `LTS`, or an exact version like `11.0.100-preview.2.26159.112`; a daily build is named by its lane, e.g. `11.0.1xx-rc2`, `12.0.1xx` (see [Daily builds](#daily-builds-nightlies)) |
| Quality | No | `preview` | One of: `daily`, `preview`, `ga` |
| jq | No | — | Optional for bash team scripts when patching an existing `global.json`; without it, do not overwrite the file |

### Prerequisites

1. **A .NET 10+ SDK is installed globally** — run `dotnet --version`; major ≥ 10.
2. **curl** (macOS/Linux) or **PowerShell** (Windows) is available.

## Workflow

### Step 1 — Clarify what to install

If the user didn't specify, ask what .NET SDK version they want (e.g., "latest
.NET 11 preview" or an exact version like `11.0.100-preview.2.26159.112`).
Map the answer to `--channel`/`--quality` or `--version` flags. "The RC 2 bits
before RC 2 ships" or "the next major" means a daily build of a lane, not
`--channel 11.0 --quality preview` (that is the newest *released* preview):
see [Daily builds](#daily-builds-nightlies) for the channel name and what
changes afterwards.

### Step 2 — Verify .NET 10+ host

If the user already provided `dotnet --version` output, treat that as the
authoritative version for their machine. Do not override it with the agent
workspace's version; if the two differ, explain that the workspace differs and
continue advising for the user's machine.

```bash
dotnet --version
```

If major version < 10, stop before downloading anything: the `paths` feature
requires a .NET 10+ host SDK. Tell the user to install .NET 10 or later
system-wide first, then return to the local SDK setup.

### Step 3 — Detect operating system

Run `uname -s 2>/dev/null`. If it succeeds (including `MINGW*`, `MSYS*`, `CYGWIN*` —
these are bash-capable environments like Git Bash) → use bash/`dotnet-install.sh`.
If it fails (native Windows without Git Bash) → use PowerShell/`dotnet-install.ps1`.

### Step 4 — Check for existing local SDK

**macOS / Linux:**

```bash
test -d .dotnet && echo "exists" || echo "not found"
```

**Windows (PowerShell):**

```powershell
if (Test-Path -LiteralPath .\.dotnet) { "exists" } else { "not found" }
```

If `.dotnet/` exists, ask: update with the new version, or skip and keep it?

### Step 5 — Download and run the install script

**macOS / Linux:**

```bash
INSTALL_SCRIPT="$(mktemp "${TMPDIR:-/tmp}/dotnet-install.XXXXXX")"
trap 'rm -f "$INSTALL_SCRIPT"' EXIT
curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$INSTALL_SCRIPT"
bash "$INSTALL_SCRIPT" --channel <CHANNEL> --quality <QUALITY> --install-dir .dotnet
```

**Windows (PowerShell):**

```powershell
$installScript = Join-Path $env:TEMP "dotnet-install-$([guid]::NewGuid()).ps1"
try {
    Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile $installScript
    & $installScript -Channel <CHANNEL> -Quality <QUALITY> -InstallDir .dotnet
}
finally {
    if (Test-Path -LiteralPath $installScript) {
        Remove-Item -LiteralPath $installScript -Force
    }
}
```

For exact versions: use `--version <VERSION>` (bash) or `-Version <VERSION>` (PowerShell)
instead of channel/quality flags. The install scripts are from Microsoft's official
URLs: `https://dot.net/v1/dotnet-install.sh` and `https://dot.net/v1/dotnet-install.ps1`.

### Step 6 — Identify the installed version

```bash
./.dotnet/dotnet --version          # macOS/Linux
.\.dotnet\dotnet.exe --version      # Windows
```

Record the exact version string (e.g., `11.0.100-preview.2.26159.112`) for `global.json`.

### Step 7 — Create or update global.json

```json
{
  "sdk": {
    "version": "<INSTALLED_VERSION>",
    "allowPrerelease": true,
    "rollForward": "latestFeature",
    "paths": [".dotnet", "$host$"],
    "errorMessage": "Required .NET SDK not found. Run ./install-dotnet.sh (or .ps1) to install it locally."
  }
}
```

- `paths`: `.dotnet` first (local priority), `$host$` = system-wide fallback.
- `rollForward: "latestFeature"`: use for latest-preview or floating feature-band installs.
- Exact version requests: use `rollForward: "disable"` so SDK resolution doesn't move to a different feature band.
- `allowPrerelease`: set to `true` only when installing a prerelease SDK. Omit for stable versions.
- `errorMessage`: include only when team install scripts are created (Step 10). Otherwise omit.

If `global.json` already exists, **merge** carefully: preserve existing properties (`msbuild-sdks`,
`tools`, etc.) and only add/update the `sdk` section. Read the existing file first, update/add
the `sdk` object, then write it back. This ensures cross-project config (e.g., MSBuild settings)
isn't lost. Always back up the original file (e.g., `global.json.bak`) before modifying.

**Minimal config** (when version pinning isn't needed):
`{"sdk":{"paths":[".dotnet","$host$"]}}`

### Step 8 — Update .gitignore

**macOS / Linux (or Git Bash):**

```bash
grep -qxF '.dotnet/' .gitignore 2>/dev/null || printf '\n.dotnet/\n' >> .gitignore
```

**Windows (PowerShell):**

```powershell
if (-not (Test-Path .gitignore) -or -not (Select-String -Path .gitignore -Pattern '^\.dotnet/$' -Quiet)) {
    Add-Content -Path .gitignore -Value '.dotnet/'
}
```

### Step 9 — Install workloads (if requested)

Only do this after `global.json` and `.gitignore` are complete, so a slow or
platform-limited workload install does not prevent the base local SDK setup from
being usable.

If the user mentioned MAUI, mobile, workload, Blazor WASM, or cross-platform,
install using the **local** binary (no sudo needed):

```bash
./.dotnet/dotnet workload install <workload>       # macOS/Linux
.\.dotnet\dotnet.exe workload install <workload>   # Windows
```

Verify: `./.dotnet/dotnet workload list` (or `.\.dotnet\dotnet.exe workload list`).

For MAUI, pick a workload supported by the current OS and target platform. On
Linux, the full `maui` meta-workload is not available; use a supported workload
such as `maui-android` when Android is the target, or explain the platform
limitation and ask which target to configure.

> **Always use the local dotnet binary for workload commands.** Workload metadata
> is stored relative to the host process's dotnet root. The system `dotnet` puts
> metadata in the wrong location. (See [dotnet/sdk#49825](https://github.com/dotnet/sdk/issues/49825).)

On an SDK installed with `--quality daily`, this plain command keeps the SDK's
months-old bundled manifests or fails on a package nuget.org does not have. Read
[references/daily-builds.md](references/daily-builds.md) and follow its procedure
(feeds in `NuGet.config`, manifests update mode, band check) before installing
workloads on a daily, and verify the band in `workload list`, not just the
"Successfully installed" line.

### Step 10 — Create team install scripts

Create if user mentioned "team", "share", "CI", "scripts", etc. Otherwise offer.
These examples back up `global.json` and preserve existing settings. The bash script
uses `jq` when an existing `global.json` must be patched; if `jq` is unavailable,
it refuses to overwrite the file and prints the settings to merge manually.
Adapt script variables to the install choice from Step 1: exact versions should
use `--version` / `-Version` and `rollForward: "disable"`; channel installs should
use channel/quality and only set `allowPrerelease: true` for prerelease SDKs.
For a daily build set the quality to `daily`: the templates then switch the
installer to manifests update mode and refuse to install workloads unless
`NuGet.config` lists the `dotnet<major>` daily feed (see
[references/daily-builds.md](references/daily-builds.md)), instead of running
the plain install that fails on a daily.
If `global.json` already pins `sdk.version` and the user mainly needs team
scripts, reuse that version in the scripts and update `global.json` first; do
not start a long SDK download just to discover the version. When the user asks
for both setup and scripts, create the scripts/config before any long install so
the reproducible setup exists even if download or workload installation is slow.

**install-dotnet.sh:**

```bash
#!/usr/bin/env bash
set -euo pipefail
INSTALL_DIR=".dotnet"
CHANNEL="11.0"
QUALITY="preview"
VERSION=""
ROLL_FORWARD="latestFeature"
ALLOW_PRERELEASE="true"
WORKLOADS=(); [ $# -eq 0 ] || WORKLOADS=("$@")  # "$@" alone is unbound under set -u in bash 3.2 (macOS)
ERROR_MESSAGE="Required .NET SDK not found. Run ./install-dotnet.sh (or .ps1) to install it locally."
INSTALL_SCRIPT="$(mktemp "${TMPDIR:-/tmp}/dotnet-install.XXXXXX")"
GLOBAL_JSON_TMP=""
cleanup() {
    rm -f "$INSTALL_SCRIPT"
    [ -z "$GLOBAL_JSON_TMP" ] || rm -f "$GLOBAL_JSON_TMP"  # a failing && list in the EXIT trap would turn a successful run into exit 1 under set -e
}
trap cleanup EXIT
curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$INSTALL_SCRIPT"
INSTALL_ARGS=(--install-dir "$INSTALL_DIR")
if [ -n "$VERSION" ]; then
    INSTALL_ARGS+=(--version "$VERSION")
    ROLL_FORWARD="disable"
else
    INSTALL_ARGS+=(--channel "$CHANNEL" --quality "$QUALITY")
fi
bash "$INSTALL_SCRIPT" "${INSTALL_ARGS[@]}"
SDK_VERSION=$("$INSTALL_DIR/dotnet" --version)
write_global_json() {
    if [ -f global.json ]; then
        cp global.json global.json.bak
        if ! command -v jq >/dev/null 2>&1; then
            echo "global.json exists; install succeeded, but this script will not overwrite it without jq." >&2
            echo "Merge these sdk settings manually so existing global.json properties are preserved:" >&2
            cat >&2 <<EOF
{
  "sdk": {
    "version": "$SDK_VERSION",
    "allowPrerelease": $ALLOW_PRERELEASE,
    "rollForward": "$ROLL_FORWARD",
    "paths": [".dotnet", "\$host\$"],
    "errorMessage": "$ERROR_MESSAGE"
  }
}
EOF
            exit 1
        fi
        GLOBAL_JSON_TMP="$(mktemp "${TMPDIR:-/tmp}/global-json.XXXXXX")"
        jq --arg version "$SDK_VERSION" --arg rollForward "$ROLL_FORWARD" --argjson allowPrerelease "$ALLOW_PRERELEASE" --arg errorMessage "$ERROR_MESSAGE" '
          .sdk = ((.sdk // {}) + {
            version: $version,
            allowPrerelease: $allowPrerelease,
            rollForward: $rollForward,
            paths: [".dotnet", "$host$"],
            errorMessage: $errorMessage
          })
        ' global.json > "$GLOBAL_JSON_TMP"
        mv "$GLOBAL_JSON_TMP" global.json
        GLOBAL_JSON_TMP=""
    else
        cat > global.json <<EOF
{
  "sdk": {
    "version": "$SDK_VERSION",
    "allowPrerelease": $ALLOW_PRERELEASE,
    "rollForward": "$ROLL_FORWARD",
    "paths": [".dotnet", "\$host\$"],
    "errorMessage": "$ERROR_MESSAGE"
  }
}
EOF
    fi
}
write_global_json
grep -qxF '.dotnet/' .gitignore 2>/dev/null || printf '\n.dotnet/\n' >> .gitignore
if [ "$QUALITY" = "daily" ]; then
    # a daily's runtime and reference packs are not on nuget.org: every restore needs the feed, workloads or not; the messages must stand alone in the team's repo
    "$INSTALL_DIR/dotnet" nuget list source --format Short 2>/dev/null | grep -Eq "^E +[^ ]*_packaging/dotnet${SDK_VERSION%%.*}/" \
        || { echo "Daily SDK: no enabled dotnet${SDK_VERSION%%.*} feed in the effective NuGet configuration. Add https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet${SDK_VERSION%%.*}/nuget/v3/index.json to NuGet.config, plus the darc-pub-* feeds that dotnet/maui's NuGet.config lists for this band, then rerun." >&2; exit 1; }
fi
if [ ${#WORKLOADS[@]} -gt 0 ]; then
    if [ "$QUALITY" = "daily" ]; then
        "$INSTALL_DIR/dotnet" workload config --update-mode manifests  # a daily band has no manifests on nuget.org and no workload set
    fi
    rc=0; "$INSTALL_DIR/dotnet" workload install "${WORKLOADS[@]}" || rc=$?
    if [ "$QUALITY" = "daily" ]; then
        "$INSTALL_DIR/dotnet" build-server shutdown >/dev/null  # even after a failed install: nodes keep the manifests they loaded
        [ "$rc" -eq 0 ] || exit "$rc"
        # the install also succeeds after falling back to bundled manifests of an older band, or to a build of
        # another lane publishing into the band (a main build in an rc band): check band and lane of every manifest
        BAND="$(echo "$SDK_VERSION" | sed -E 's/^([0-9]+\.[0-9]+\.[0-9])[0-9][0-9](-(preview|rc|alpha)\.[0-9]+)?.*$/\100\2/')"
        LANE="$(echo "$BAND" | sed -nE 's/^.*-(rc|preview)\.([0-9]+)$/(\1\\.\2|-p\2)([^0-9]|$)/p')"  # rc.2 or -p2 in the version; none for alpha or rtm
        LIST="$("$INSTALL_DIR/dotnet" workload list)"
        for w in "${WORKLOADS[@]}"; do
            ver="$(printf '%s\n' "$LIST" | awk -v w="$w" '$1 == w { print $2 }')"  # <manifest version>/<band>
            case "$ver" in */"$BAND") [ -z "$LANE" ] || echo "${ver%%/*}" | grep -Eq "$LANE" ;; *) false ;; esac \
                || { printf '%s\n' "$LIST" >&2; echo "workload ${w}: ${ver:-missing} is not a ${BAND} build of the SDK's lane: the installer took a bundled or other-lane manifest. Extract the data/ folder of the right <id>.Manifest-${BAND} package into $INSTALL_DIR/sdk-manifests/${BAND}/<id>/<version>/, delete the other version folders of that id and $INSTALL_DIR/metadata/workloads/*/${BAND}/InstallState/default.json, then rerun with workload install --skip-manifest-update." >&2; exit 1; }
        done
    fi
    [ "$rc" -eq 0 ] || exit "$rc"
fi
echo "Done. SDK: $SDK_VERSION"
```

```bash
chmod +x install-dotnet.sh
```

**install-dotnet.ps1:**

```powershell
param([string[]]$Workloads = @())
$ErrorActionPreference = 'Stop'
$installDir = '.dotnet'; $channel = '11.0'; $quality = 'preview'
$version = ''; $rollForward = 'latestFeature'; $allowPrerelease = $true
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
    if (-not ($sources | Select-String -Pattern "^E +\S*_packaging/dotnet$major/" -Quiet)) {
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
```

Commit these scripts to the repo so teammates can run them.

### Step 11 — Verify SDK resolution

```bash
dotnet --version
```

Output should match the locally installed version. If not, check: global.json
location, `paths` array contents, host dotnet version ≥ 10.

### Step 12 — Summarize and explain cleanup

Tell the user: SDK installed, global.json configured, .dotnet/ gitignored, system
install untouched. Cleanup: delete `.dotnet/`, remove `paths`/`errorMessage` from
global.json, optionally delete install scripts. Include the final `global.json`
`sdk` values (or a short snippet) so the user can see the configured version,
`paths`, and any `errorMessage`. If workloads were requested, include the local
`dotnet workload install ...` command used and the workload verification result
or the exact blocker if the workload could not be installed.

## Daily builds (nightlies)

`--quality daily` installs the newest build of a *channel*, which is the name of a
build lane of [dotnet/dotnet](https://github.com/dotnet/dotnet): `11.0.1xx-rc2`
is the RC 2 release branch, `11.0.1xx` the RTM release branch, `12.0.1xx` is
`main`, already branded for the next major. The
[builds table](https://github.com/dotnet/dotnet/blob/main/docs/builds-table.md)
lists them but lags behind branding changes, so resolve a channel by the version
it currently serves, without downloading: the install script's `--dry-run`
(`-DryRun`) prints the payload URL, which carries the version.

```bash
bash dotnet-install.sh --channel 11.0.1xx-rc2 --quality daily --dry-run
# dotnet-install: URL #0 - aka.ms: .../Sdk/11.0.100-rc.2.26509.113/dotnet-sdk-11.0.100-rc.2.26509.113-osx-arm64.tar.gz
```

The URL must contain `/Sdk/<version>/`. An unknown channel is not a 404: its
aka.ms link lands on a search page, so no such URL means no such channel.

Tell the user what the version means before installing: `rc.2` is the release
candidate lane, `rtm` the release branch, `alpha.1` the next major. Steps 5 to 8
are unchanged for a daily. Workloads are not: a daily band has no manifests on
nuget.org and no workload set at all, and its compat packs can reference a
previous-major servicing runtime that is not public yet, so Step 9 needs the
procedure in [references/daily-builds.md](references/daily-builds.md). A
workload that no manifest of the band defines (no `maui` on a `12.0.1xx` alpha
while dotnet/maui still targets the previous major) cannot be installed from
that lane: say so, install the rest, and note that the SDK is usable without it.

## Common pitfalls

| Pitfall | Cause | Fix |
|---|---|---|
| `paths` ignored | Host `dotnet` < v10 | Install .NET 10+ system-wide |
| Daily SDK: `No workload update found`, packs of an older preview installed | nuget.org has no manifests for a daily band; .NET 10+ looks for workload sets, which dailies do not publish, and falls back to the SDK's bundled manifests | Feeds in `NuGet.config` and `workload config --update-mode manifests`, see [references/daily-builds.md](references/daily-builds.md) |
| Daily SDK: `Version <previous>.0.x of package … is not found in NuGet feeds` | Compat manifests reference the previous major's servicing runtime before Patch Tuesday | Wait, or point the two `.net<previous>` manifests at the newest public version and install with `--skip-manifest-update` |
| `workload list` shows a band older than the SDK (`…/11.0.100-rc.1` on a `12.0.100-alpha.1` SDK) | The install "succeeded" with the bundled manifests | Not done: fix the feeds and update mode, reinstall, check the band again |
| Build after a manifest refresh imports a `WorkloadManifest.targets` that no longer exists | MSBuild nodes and the compiler server keep the manifests they loaded | `./.dotnet/dotnet build-server shutdown` |
| Wrong SDK resolves | `global.json` in parent directory | Check for global.json up the tree |
| Teammates get "SDK not found" | `.dotnet/` gitignored, no install script run | Use `errorMessage` in global.json |
| Workloads missing | Used system `dotnet` instead of local | Use `./.dotnet/dotnet workload install` |
| `dotnet app.dll` wrong runtime | `paths` is SDK-only, not apphost | Use `dotnet run` or set `DOTNET_ROOT` |
