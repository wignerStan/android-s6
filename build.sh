#!/usr/bin/env bash
# Build s6 + s6-rc for Android aarch64 (bionic) with the Android NDK.
#
#   Android NDK -> aarch64-linux-android -> skalibs -> execline -> s6 -> s6-rc
#
# Output layout (this is also the on-device layout):
#   $PREFIX/bin/      s6-svscan s6-supervise s6-svc s6-svstat s6-log s6-rc ...
#   $PREFIX/libexec/  s6-ftrigrd s6-rc-fdhoder-filler s6-rc-oneshot-run
#   $PREFIX/lib/      static archives (skalibs/execline/s6/s6-rc)
#
# IMPORTANT: PREFIX is baked into the binaries. s6 tools exec helpers from
# $PREFIX/libexec at runtime, so PREFIX MUST be the final on-device path.
# Building with a scratch prefix fails at runtime with:
#   execve(<scratch>/libexec/s6-ftrigrd) = ENOENT
set -euo pipefail

PREFIX="${PREFIX:-/data/adb/s6}"
API="${API:-24}"
ABI="${ABI:-arm64-v8a}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

SKALIBS_V="${SKALIBS_V:-2.15.1.0}"
EXECLINE_V="${EXECLINE_V:-2.9.9.2}"
S6_V="${S6_V:-2.15.1.0}"
S6RC_V="${S6RC_V:-0.7.0.0}"

# ---------------------------------------------------------------- NDK lookup
find_ndk() {
  if [ -n "${NDK:-}" ] && [ -d "$NDK" ]; then echo "$NDK"; return; fi
  for c in "$HOME/Library/Android/sdk/ndk"/* "$HOME/android-ndk-r"* \
           /opt/homebrew/share/android-ndk* /usr/local/share/android-ndk* \
           "$HOME/ndk"/*; do
    [ -d "$c/toolchains/llvm/prebuilt" ] && { echo "$c"; return; }
  done
  echo ""
}
NDK="$(find_ndk)"
[ -n "$NDK" ] || { echo "ERROR: no NDK found. Set NDK=/path/to/android-ndk-rXX" >&2; exit 1; }
echo "NDK      : $NDK"

# the prebuilt dir is named darwin-x86_64 even on Apple Silicon (universal clang)
TC=""
for d in "$NDK"/toolchains/llvm/prebuilt/*; do [ -d "$d" ] && TC="$d"; done
[ -n "$TC" ] || { echo "ERROR: NDK toolchain not found under $NDK/toolchains/llvm/prebuilt" >&2; exit 1; }
CC="$TC/bin/aarch64-linux-android${API}-clang"
[ -x "$CC" ] || { echo "ERROR: $CC missing (wrong API level?)" >&2; exit 1; }
export PATH="$TC/bin:$PATH"
echo "toolchain: $TC"
echo "CC       : $CC ($($CC --version | head -1))"

HOST=aarch64-linux-android
# static libraries, dynamic libc (bionic libc.so exists on every Android device,
# so the binaries need no extra runtime libs and work pre-unlock on /data)
export CC
export CFLAGS="${CFLAGS:--Os}"
export AR="$TC/bin/llvm-ar"
export RANLIB="$TC/bin/llvm-ranlib"
export STRIP="$TC/bin/llvm-strip"

WORK="${WORK:-$PWD/.build}"
mkdir -p "$WORK"
cd "$WORK"

fetch() { # url file
  [ -f "$2" ] || curl -fsSL -o "$2" "$1"
}
for spec in \
  "skalibs/skalibs-$SKALIBS_V.tar.gz" \
  "execline/execline-$EXECLINE_V.tar.gz" \
  "s6/s6-$S6_V.tar.gz" \
  "s6-rc/s6-rc-$S6RC_V.tar.gz" ; do
  name="$(basename "$spec")"
  fetch "https://skarnet.org/software/$spec" "$name"
  rm -rf "${name%.tar.gz}"
  tar xzf "$name"
done

# skalibs cannot autodetect these while cross-compiling; all four are mandatory.
./skalibs-*/configure --prefix="$PREFIX" --host="$HOST" \
  --enable-static --disable-shared \
  --with-sysdep-devurandom=yes \
  --with-sysdep-posixspawnearlyreturn=no \
  --with-sysdep-procselfexe=/proc/self/exe \
  --with-sysdep-selectinfinite=yes
make -C skalibs-* -j"$JOBS" && make -C skalibs-* install

./execline-*/configure --prefix="$PREFIX" --host="$HOST" \
  --enable-static --disable-shared \
  --with-include="$PREFIX/include" --with-lib="$PREFIX/lib"
make -C execline-* -j"$JOBS" && make -C execline-* install

./s6-*/configure --prefix="$PREFIX" --host="$HOST" \
  --enable-static --disable-shared \
  --with-include="$PREFIX/include" --with-lib="$PREFIX/lib" \
  --with-sysdeps="$PREFIX/lib/skalibs/sysdeps"
make -C s6-*/ -j"$JOBS" && make -C s6-*/ install

./s6-rc-*/configure --prefix="$PREFIX" --host="$HOST" \
  --enable-static --disable-shared \
  --with-include="$PREFIX/include" --with-lib="$PREFIX/lib" \
  --with-sysdeps="$PREFIX/lib/skalibs/sysdeps" --with-dynlib="$PREFIX/lib"
make -C s6-rc-*/ -j"$JOBS" && make -C s6-rc-*/ install

echo
echo "=== installed ==="
ls "$PREFIX/bin" | wc -l | sed 's/^/bin entries: /'
ls "$PREFIX/libexec" 2>/dev/null | sed 's/^/libexec: /'
echo "=== sanity: prefix baked in (must point at $PREFIX) ==="
grep -a -o "$PREFIX/libexec/[a-z0-9-]*" "$PREFIX/bin/s6-rc-init" | sort -u | head -3
echo "=== runtime deps (expect only libc.so / libdl.so) ==="
for b in s6-svscan s6-supervise s6-svc s6-rc s6-rc-init s6-log; do
  printf '%-16s ' "$b"; "$TC/bin/llvm-readelf" -d "$PREFIX/bin/$b" 2>/dev/null \
    | awk '/NEEDED/{printf "%s ", $NF} END{print ""}'
done
echo "DONE"
