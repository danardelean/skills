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
if [ ${#WORKLOADS[@]} -gt 0 ]; then
    if [ "$QUALITY" = "daily" ]; then
        # a daily band has no manifests on nuget.org and no workload set; the messages below must stand alone in the team's repo
        "$INSTALL_DIR/dotnet" nuget list source --format Short 2>/dev/null | grep -Eq "^E +[^ ]*_packaging/dotnet${SDK_VERSION%%.*}/" \
            || { echo "Daily SDK: no enabled dotnet${SDK_VERSION%%.*} feed in the effective NuGet configuration. Add https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet${SDK_VERSION%%.*}/nuget/v3/index.json to NuGet.config, plus the darc-pub-* feeds that dotnet/maui's NuGet.config lists for this band, then rerun." >&2; exit 1; }
        "$INSTALL_DIR/dotnet" workload config --update-mode manifests
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
                || { printf '%s\n' "$LIST" >&2; echo "workload ${w}: ${ver:-missing} is not a ${BAND} build of the SDK's lane: the installer took a bundled or other-lane manifest. Place the band's <id>.Manifest-${BAND} package under $INSTALL_DIR/sdk-manifests/${BAND}/ by hand and rerun with workload install --skip-manifest-update." >&2; exit 1; }
        done
    fi
    [ "$rc" -eq 0 ] || exit "$rc"
fi
echo "Done. SDK: $SDK_VERSION"
