#!/usr/bin/env bash
# Behavioral check of the generated bash team script for a daily SDK. Runs the script against a
# stubbed network and a stubbed dotnet, and checks the outcomes, not the syntax:
#   1. manifests update mode is switched on before workload install, and build servers are shut down
#   2. a workload installed from an older band fails the script
#   3. a workload from another lane of the same rc band fails the script
#   4. without a NuGet config the script stops before workload install
#   5. when workload install fails, build servers are still shut down and the failure is propagated
#   6. workload install receives the requested ids (the fake dotnet rejects a call without ios and android)
#   7. the successful run leaves global.json with the SDK version and sdk.paths, and .dotnet/ in .gitignore
#   8. dotnet-install is called with --channel 12.0.1xx --quality daily --install-dir .dotnet
#   9. the workspace NuGet config is valid XML with active nuget.org, dotnet12, android and macios sources
#  10. a wrong-band or wrong-lane workload is caught in any position of the list, not only the first
#  11. run without arguments, the script installs ios and android by default
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
candidate="$(ls install*.sh 2>/dev/null | head -1)"
[ -n "$candidate" ] || { echo "no install*.sh in the workspace" >&2; exit 1; }
root="$(mktemp -d "${TMPDIR:-/tmp}/daily-scripts-check.XXXXXX")"; trap 'rm -rf "$root"' EXIT
stubs="$root/stubs"; mkdir -p "$stubs"
# fake dotnet: logs every call, answers --version and workload list from the scenario
cat > "$stubs/fake-dotnet" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_LOG"
case "${1:-}" in
  --version) echo "$FAKE_SDK_VERSION" ;;
  workload) case "${2:-}" in
    list) cat "$FAKE_LIST" ;;
    install) shift 2; case " $* " in *" ios "*) ;; *) echo "fake dotnet: workload install without ios: $*" >&2; exit 2 ;; esac
             case " $* " in *" android "*) ;; *) echo "fake dotnet: workload install without android: $*" >&2; exit 2 ;; esac
             exit "${FAKE_INSTALL_EXIT:-0}" ;;
  esac ;;
esac
exit 0
STUB
# fake dotnet-install: creates <install-dir>/dotnet from the fake dotnet
cat > "$stubs/fake-install.sh" <<'STUB'
#!/usr/bin/env bash
dir=""; channel=""; quality=""
while [ $# -gt 0 ]; do case "$1" in
  --install-dir|-i) dir="$2"; shift ;; --install-dir=*) dir="${1#*=}" ;;
  --channel|-c) channel="$2"; shift ;; --channel=*) channel="${1#*=}" ;;
  --quality|-q) quality="$2"; shift ;; --quality=*) quality="${1#*=}" ;;
esac; shift; done
d="${dir#./}"; d="${d%/}"
if [ "$channel" != "$EXPECT_CHANNEL" ] || [ "$quality" != daily ] || [ "$d" != .dotnet ]; then
  echo "fake dotnet-install: expected --channel $EXPECT_CHANNEL --quality daily --install-dir .dotnet, got channel='$channel' quality='$quality' install-dir='$dir'" >&2; exit 3
fi
mkdir -p "$dir" && cp "$FAKE_DOTNET_SRC" "$dir/dotnet" && chmod +x "$dir/dotnet"
STUB
# curl / wget stubs: serve the fake installer to -o/-O <file> or to stdout
cat > "$stubs/curl" <<'STUB'
#!/usr/bin/env bash
out=""; while [ $# -gt 0 ]; do case "$1" in -o|--output) out="$2"; shift ;; -[a-zA-Z]*o) out="$2"; shift ;; --output=*) out="${1#*=}" ;; esac; shift; done
if [ -n "$out" ]; then cp "$FAKE_INSTALL_SRC" "$out"; else cat "$FAKE_INSTALL_SRC"; fi
STUB
cat > "$stubs/wget" <<'STUB'
#!/usr/bin/env bash
out=""; while [ $# -gt 0 ]; do case "$1" in -O|--output-document) out="$2"; shift ;; -*O) out="$2"; shift ;; --output-document=*) out="${1#*=}" ;; esac; shift; done
if [ -n "$out" ] && [ "$out" != "-" ]; then cp "$FAKE_INSTALL_SRC" "$out"; else cat "$FAKE_INSTALL_SRC"; fi
STUB
chmod +x "$stubs"/*
export FAKE_DOTNET_SRC="$stubs/fake-dotnet" FAKE_INSTALL_SRC="$stubs/fake-install.sh" FAKE_INSTALL_EXIT=0 EXPECT_CHANNEL="12.0.1xx"
RUN_ARGS="ios android"  # arguments passed to the candidate; empty for the no-argument default case
failures=0
# the NuGet config next to the scripts: valid XML, with the four sources active
cfg=""; for f in NuGet.Config NuGet.config nuget.config; do if [ -f "$f" ]; then cfg="$f"; break; fi; done
py="$(command -v python3 || command -v python || true)"
if [ -z "$cfg" ]; then echo "FAIL  no NuGet config in the workspace"; failures=$((failures+1))
elif [ -z "$py" ]; then echo "FAIL  python is needed to parse $cfg"; failures=$((failures+1))
elif "$py" - "$cfg" <<'PY'
import sys, xml.etree.ElementTree as ET
try:
    root = ET.parse(sys.argv[1]).getroot()
except ET.ParseError as exc:
    print("not valid XML: %s" % exc); sys.exit(1)
adds = {a.get("key", ""): a.get("value", "") for a in root.findall("./packageSources/add")}
disabled = {d.get("key", "") for d in root.findall("./disabledPackageSources/add")}
active = [v for k, v in adds.items() if k not in disabled]
need = {"nuget.org": "api.nuget.org/v3/index.json", "dotnet12": "_packaging/dotnet12/", "android": "darc-pub-dotnet-android-", "macios": "darc-pub-dotnet-macios-"}
missing = [name for name, frag in need.items() if not any(frag in v for v in active)]
if missing:
    print("no active source for: %s" % ", ".join(missing)); sys.exit(1)
PY
then echo "ok    $cfg has active nuget.org, dotnet12, android and macios sources"
else echo "FAIL  $cfg: see above"; failures=$((failures+1)); fi
run() { # name, sdk version, expected exit (0 or nonzero), config (yes/no), list lines...
  local name="$1" version="$2" expect="$3" config="$4"; shift 4
  local box="$root/$name"; mkdir -p "$box"; cp "$candidate" "$box/install.sh"
  export FAKE_LOG="$box/calls.log" FAKE_SDK_VERSION="$version" FAKE_LIST="$box/list.txt"
  : > "$FAKE_LOG"; { printf 'Installed Workload Id   Manifest Versions   Installation Source\n---\n'; printf '%s\n' "$@"; } > "$FAKE_LIST"
  [ "$config" = yes ] && printf '<configuration><packageSources><add key="dotnet11" value="https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet11/nuget/v3/index.json" /><add key="dotnet12" value="https://pkgs.dev.azure.com/dnceng/public/_packaging/dotnet12/nuget/v3/index.json" /></packageSources></configuration>' > "$box/NuGet.config"
  # shellcheck disable=SC2086
  local rc=0; ( cd "$box" && PATH="$stubs:$PATH" bash ./install.sh $RUN_ARGS ) > "$box/out.txt" 2>&1 || rc=$?
  if [ "$expect" = 0 ] && [ "$rc" -ne 0 ]; then echo "FAIL  $name: exited $rc, expected success"; sed 's/^/      /' "$box/out.txt" | tail -5; failures=$((failures+1)); return; fi
  if [ "$expect" != 0 ] && [ "$rc" -eq 0 ]; then echo "FAIL  $name: exited 0, expected a failure"; failures=$((failures+1)); return; fi
  echo "ok    $name (exit $rc)"
}
V12="12.0.100-alpha.1.26509.101"; V11="11.0.100-rc.2.26509.113"
run alpha-right-band "$V12" 0 yes "ios     27.0.12277-net12-p1/12.0.100-alpha.1   SDK 12.0.100-alpha.1" "android 37.99.0-preview.1.145/12.0.100-alpha.1   SDK 12.0.100-alpha.1"
# the successful run must switch to manifests mode before installing, and shut down build servers
if [ -f "$root/alpha-right-band/calls.log" ]; then
  cfg=$(grep -n '^workload config --update-mode manifests' "$root/alpha-right-band/calls.log" | head -1 | cut -d: -f1)
  ins=$(grep -n '^workload install' "$root/alpha-right-band/calls.log" | head -1 | cut -d: -f1)
  if [ -z "$cfg" ] || [ -z "$ins" ] || [ "$cfg" -gt "$ins" ]; then echo "FAIL  manifests update mode is not switched on before workload install"; failures=$((failures+1)); else echo "ok    manifests update mode before workload install"; fi
  grep -q '^build-server shutdown' "$root/alpha-right-band/calls.log" && echo "ok    build-server shutdown" || { echo "FAIL  build-server shutdown not called"; failures=$((failures+1)); }
  gj="$root/alpha-right-band/global.json"
  if [ -f "$gj" ] && grep -q '"paths"' "$gj" && grep -qF '.dotnet' "$gj" && grep -qF '$host$' "$gj" && grep -qF "$V12" "$gj"; then echo "ok    global.json pins $V12 with sdk.paths"; else echo "FAIL  global.json missing, or without the SDK version, \"paths\", .dotnet and \$host\$"; failures=$((failures+1)); fi
  if [ -f "$root/alpha-right-band/.gitignore" ] && grep -qx '\.dotnet/' "$root/alpha-right-band/.gitignore"; then echo "ok    .gitignore excludes .dotnet/"; else echo "FAIL  .gitignore does not exclude .dotnet/"; failures=$((failures+1)); fi
fi
run alpha-stale-band "$V12" 1 yes "ios     26.5.12193-net11-rc.1/11.0.100-rc.1   SDK 12.0.100-alpha.1" "android 37.99.0-preview.1.145/12.0.100-alpha.1   SDK 12.0.100-alpha.1"
run alpha-stale-second "$V12" 1 yes "ios     27.0.12277-net12-p1/12.0.100-alpha.1   SDK 12.0.100-alpha.1" "android 37.0.0-rc.1.2257/11.0.100-rc.1   SDK 12.0.100-alpha.1"
run rc2-right-lane "$V11" 0 yes "ios     27.0.12212-net11-rc.2/11.0.100-rc.2   SDK 11.0.100-rc.2" "android 37.2.0-rc.2.5/11.0.100-rc.2   SDK 11.0.100-rc.2"
run rc2-main-lane "$V11" 1 yes "ios     27.1.11007-xcode27.1-net11.0/11.0.100-rc.2   SDK 11.0.100-rc.2" "android 37.99.0-preview.1.4/11.0.100-rc.2   SDK 11.0.100-rc.2"
run rc2-main-lane-second "$V11" 1 yes "ios     27.0.12212-net11-rc.2/11.0.100-rc.2   SDK 11.0.100-rc.2" "android 37.99.0-preview.1.4/11.0.100-rc.2   SDK 11.0.100-rc.2"
run no-config "$V12" 1 no "ios     27.0.12277-net12-p1/12.0.100-alpha.1   SDK 12.0.100-alpha.1"
if [ -f "$root/no-config/calls.log" ] && grep -q '^workload install' "$root/no-config/calls.log"; then echo "FAIL  workload install ran without a NuGet config"; failures=$((failures+1)); else echo "ok    no workload install without a NuGet config"; fi
RUN_ARGS="" run alpha-no-args "$V12" 0 yes "ios     27.0.12277-net12-p1/12.0.100-alpha.1   SDK 12.0.100-alpha.1" "android 37.99.0-preview.1.145/12.0.100-alpha.1   SDK 12.0.100-alpha.1"
if [ -f "$root/alpha-no-args/calls.log" ] && grep -q '^workload install' "$root/alpha-no-args/calls.log"; then echo "ok    no arguments: workload install ran with the default ids"; else echo "FAIL  no arguments: workload install did not run (no default workloads)"; failures=$((failures+1)); fi
FAKE_INSTALL_EXIT=1 run install-fails "$V12" 1 yes "ios     27.0.12277-net12-p1/12.0.100-alpha.1   SDK 12.0.100-alpha.1" "android 37.99.0-preview.1.145/12.0.100-alpha.1   SDK 12.0.100-alpha.1"
if [ -f "$root/install-fails/calls.log" ] && grep -q '^build-server shutdown' "$root/install-fails/calls.log"; then echo "ok    build-server shutdown after a failed install"; else echo "FAIL  build-server shutdown not called after a failed install"; failures=$((failures+1)); fi
[ "$failures" -eq 0 ] && echo "all checks passed" || { echo "$failures check(s) failed"; exit 1; }
