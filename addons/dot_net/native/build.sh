#!/usr/bin/env bash
# Builds the optional native snapshot core into bin/. Usage: ./build.sh [debug|release|all] [extra scons args]
# Needs git, python3 and a C++17 compiler. DOT_NET_NATIVE_CACHE (default ~/.cache/dot-net-native) holds godot-cpp and objects.
set -euo pipefail
GODOT_CPP_COMMIT=8070599885b6df675fcad033dd032ce44be2b850
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cache="${DOT_NET_NATIVE_CACHE:-$HOME/.cache/dot-net-native}"
which="${1:-all}"; shift || true
mkdir -p "$cache"
if [ ! -d "$cache/godot-cpp/.git" ]; then
	git clone --filter=blob:none https://github.com/godotengine/godot-cpp "$cache/godot-cpp"
fi
if [ "$(git -C "$cache/godot-cpp" rev-parse HEAD)" != "$GODOT_CPP_COMMIT" ]; then
	git -C "$cache/godot-cpp" fetch --quiet origin "$GODOT_CPP_COMMIT" || true
	git -C "$cache/godot-cpp" checkout --quiet "$GODOT_CPP_COMMIT"
fi
scons_bin="$(command -v scons || true)"
if [ -z "$scons_bin" ]; then
	[ -x "$cache/venv/bin/scons" ] || { python3 -m venv "$cache/venv" && "$cache/venv/bin/pip" install --quiet scons; }
	scons_bin="$cache/venv/bin/scons"
fi
targets=(template_debug template_release)
case "$which" in
	debug) targets=(template_debug) ;;
	release) targets=(template_release) ;;
	all) ;;
	*) echo "usage: $0 [debug|release|all] [scons args]" >&2; exit 2 ;;
esac
jobs="${DOT_NET_NATIVE_JOBS:-$(nproc 2>/dev/null || echo 2)}"
for target in "${targets[@]}"; do
	"$scons_bin" -C "$here" -j"$jobs" target="$target" godot_cpp="$cache/godot-cpp" build_dir="$cache/obj" \
		build_profile="$here/build_profile.json" "$@"
done
find "$here/bin" -name '*.so' -exec strip --strip-unneeded {} + 2>/dev/null || true
ls -l "$here/bin"
