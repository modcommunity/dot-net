#!/bin/bash
# Pack the native snapshot core built for ONE platform into dist/ for the release:
#   dist/dot_net_native-<version>-<platform>.zip   the debug and release libraries the cfg names
#   dist/SHA256SUMS                                (appended)
#   dist/natives.json                              {version, files:{platform:{file,sha256}}} (merged)
# Entries are addons/dot_net/native/bin/<library>, so the zip unpacks at a project root; that is
# what dot-bootstrap fetches for a "# bootstrap-natives: dot-net <tag> native/bin" pin.
# The library list comes from addons/dot_net/native/dot_net_native.cfg; macOS is one universal
# dylib, packed once as macos-arm64 and once as macos-x86_64.
#   ci/package.sh --version 0.1.29 --platform windows-x86_64
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
VERSION=""; PLATFORM=""
while [ $# -gt 0 ]; do
    case $1 in
        --version) VERSION="${2:?}"; shift 2 ;;
        --platform) PLATFORM="${2:?}"; shift 2 ;;
        *) echo "package.sh: unknown argument '$1'" >&2; exit 2 ;;
    esac
done
VERSION="${VERSION#v}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.-]+)?$ ]] || { echo "package.sh: --version must be semver" >&2; exit 2; }
[[ "$PLATFORM" =~ ^(linux|windows|macos)-(x86_64|arm64)$ ]] || { echo "package.sh: --platform must be <linux|windows|macos>-<x86_64|arm64>" >&2; exit 2; }
OS="${PLATFORM%-*}"; ARCH="${PLATFORM#*-}"
NATIVE=addons/dot_net/native
# "<os>.<debug|release>[.<arch>] = "bin/..."": an arch-less key (macOS universal) serves every arch.
mapfile -t LIBS < <(sed -nE "s/^$OS\.(debug|release)(\.$ARCH)?[[:space:]]*=[[:space:]]*\"([^\"]+)\".*/\3/p" "$NATIVE/dot_net_native.cfg")
[ "${#LIBS[@]}" -eq 2 ] || { echo "package.sh: dot_net_native.cfg names ${#LIBS[@]} libraries for $PLATFORM, expected debug + release" >&2; exit 1; }
for lib in "${LIBS[@]}"; do
    [ -s "$NATIVE/$lib" ] || { echo "package.sh: $NATIVE/$lib missing (run $NATIVE/build.sh first)" >&2; exit 1; }
done
mkdir -p dist
ZIP="dist/dot_net_native-$VERSION-$PLATFORM.zip"
rm -f "$ZIP"
python3 -I - "$ZIP" "${LIBS[@]/#/$NATIVE/}" <<'PY'
import sys, zipfile
zip_path, libs = sys.argv[1], sorted(sys.argv[2:])
with zipfile.ZipFile(zip_path, "w") as z:
    for path in libs:
        zi = zipfile.ZipInfo(path, (1980, 1, 1, 0, 0, 0))
        zi.external_attr = 0o755 << 16
        with open(path, "rb") as f:
            z.writestr(zi, f.read(), zipfile.ZIP_DEFLATED)
PY
SUM="$(sha256sum "$ZIP" | cut -d' ' -f1)"
echo "$SUM  $(basename "$ZIP")" >> dist/SHA256SUMS
python3 -I - "$VERSION" "$PLATFORM" "$(basename "$ZIP")" "$SUM" <<'PY'
import sys, json, os
v, plat, f, s = sys.argv[1:5]
p = "dist/natives.json"
m = json.load(open(p)) if os.path.exists(p) else {"version": v, "files": {}}
if m["version"] != v:
    sys.exit("natives.json is for " + m["version"] + ", not " + v)
m["files"][plat] = {"file": f, "sha256": s}
with open(p, "w") as out:
    json.dump(m, out, indent=2, sort_keys=True)
PY
echo "packed $ZIP"
