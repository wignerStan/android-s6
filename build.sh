#!/usr/bin/env bash
# Build s6 + s6-rc for Android aarch64 (bionic) with the Android NDK.
#
#   Android NDK -> aarch64-linux-android -> skalibs -> execline -> s6 -> s6-rc
#
# Output layout (identical to the on-device layout):
#   $PREFIX/bin/      s6-svscan s6-supervise s6-svc s6-svstat s6-log s6-rc ...
#   $PREFIX/libexec/  s6-ftrigrd s6-rc-fdholder-filler s6-rc-oneshot-run
#   $PREFIX/lib/      static archives (skalibs / execline / s6 / s6-rc)
#
# PREFIX is BAKED INTO the binaries: s6 execs its helpers from $PREFIX/libexec at
# runtime, so PREFIX must be the final on-device path. A scratch prefix yields
#   execve(<scratch>/libexec/s6-ftrigrd) = ENOENT
# at runtime. To install elsewhere while keeping the baked prefix, use DESTDIR
# (files land in $DESTDIR$PREFIX; build-time -I/-L point at that stage).
set -euo pipefail

PREFIX="${PREFIX:-/data/adb/s6}"
DESTDIR="${DESTDIR:-}"
STAGE="$DESTDIR$PREFIX"

API="${API:-24}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"
HOST="${HOST:-aarch64-linux-android}"

SKALIBS_V="${SKALIBS_V:-2.15.1.0}"
EXECLINE_V="${EXECLINE_V:-2.9.9.2}"
S6_V="${S6_V:-2.15.1.0}"
S6RC_V="${S6RC_V:-0.7.0.0}"

# ---------------------------------------------------------------- NDK lookup
find_ndk() {
  [ -n "${NDK:-}" ] && [ -d "${NDK:-}" ] && { echo "$NDK"; return; }
  for c in "$HOME/Library/Android/sdk/ndk"/* "$HOME/android-ndk-r"* \
           /opt/homebrew/share/android-ndk* /usr/local/share/android-ndk* \
           "$PWD"/android-ndk-r* "$HOME/ndk"/*; do
    [ -d "$c/toolchains/llvm/prebuilt" ] && { echo "$c"; return; }
  done
  echo ""
}
NDK="$(find_ndk)"
[ -n "$NDK" ] || { echo "ERROR: no NDK found; set NDK=/path/to/android-ndk-rXX" >&2; exit 1; }
echo "NDK      : $NDK"

TC=""
for d in "$NDK"/toolchains/llvm/prebuilt/*; do [ -d "$d" ] && TC="$d"; done
[ -n "$TC" ] || { echo "ERROR: toolchain not found under $NDK/toolchains/llvm/prebuilt" >&2; exit 1; }
CC="$TC/bin/${HOST}${API}-clang"
[ -x "$CC" ] || { echo "ERROR: $CC missing (bad API level?)" >&2; exit 1; }
export PATH="$TC/bin:$PATH"
export CC AR="$TC/bin/llvm-ar" RANLIB="$TC/bin/llvm-ranlib" STRIP="$TC/bin/llvm-strip"
export CFLAGS="${CFLAGS:--Os}"

echo "toolchain: $TC"
echo "CC       : $CC"
"$CC" --version | head -1
echo "PREFIX   : $PREFIX   (baked in)"
echo "STAGE    : $STAGE"

# ---------------------------------------------------------------- sources
WORK="${WORK:-$PWD/.build}"
mkdir -p "$WORK"
cd "$WORK"

fetch() { [ -f "$2" ] || curl -fsSL -o "$2" "$1"; }
for spec in "skalibs/skalibs-$SKALIBS_V" "execline/execline-$EXECLINE_V" \
            "s6/s6-$S6_V" "s6-rc/s6-rc-$S6RC_V"; do
  base="$(basename "$spec")"
  fetch "https://skarnet.org/software/$spec.tar.gz" "$base.tar.gz"
  rm -rf "$base"
  tar xzf "$base.tar.gz"
done

D_SKALIBS="skalibs-$SKALIBS_V"
D_EXECLINE="execline-$EXECLINE_V"
D_S6="s6-$S6_V"
D_S6RC="s6-rc-$S6RC_V"
for d in "$D_SKALIBS" "$D_EXECLINE" "$D_S6" "$D_S6RC"; do
  [ -d "$d" ] || { echo "ERROR: expected source dir $d not found" >&2; exit 1; }
done

build() { # dir, extra-configure-args...
  local d="$1"; shift
  echo "=== $d ==="
  ( cd "$d" && ./configure --prefix="$PREFIX" --host="$HOST" \
      --enable-static --disable-shared "$@" \
    && make -j"$JOBS" \
    && make install DESTDIR="$DESTDIR" )
}

# skalibs cannot autodetect these while cross-compiling; all four are mandatory.
build "$D_SKALIBS" \
  --with-sysdep-devurandom=yes \
  --with-sysdep-posixspawnearlyreturn=no \
  --with-sysdep-procselfexe=/proc/self/exe \
  --with-sysdep-selectinfinite=yes

build "$D_EXECLINE" \
  --with-include="$STAGE/include" --with-lib="$STAGE/lib"

build "$D_S6" \
  --with-include="$STAGE/include" --with-lib="$STAGE/lib" \
  --with-sysdeps="$STAGE/lib/skalibs/sysdeps"

build "$D_S6RC" \
  --with-include="$STAGE/include" --with-lib="$STAGE/lib" \
  --with-sysdeps="$STAGE/lib/skalibs/sysdeps" --with-dynlib="$STAGE/lib"

# ---------------------------------------------------------------- verify
echo
echo "=== installed into $STAGE ==="
find "$STAGE/bin" -maxdepth 1 -type f | wc -l | sed 's/^/bin entries : /'
ls "$STAGE/libexec" 2>/dev/null | sed 's/^/libexec     : /' || true
ls "$STAGE/lib"/*.a 2>/dev/null | wc -l | sed 's/^/static libs : /'

echo "=== baked prefix (must be $PREFIX) ==="
grep -a -o "$PREFIX/libexec/[A-Za-z0-9_-]*" "$STAGE/bin/s6-rc-init" | sort -u | head -3
echo "=== stray build dir inside binaries (must be none) ==="
grep -a -l "$WORK" "$STAGE"/bin/* 2>/dev/null || echo "(none)"

echo "=== runtime deps (expect only libc.so / libdl.so) ==="
for b in s6-svscan s6-supervise s6-svc s6-svstat s6-log s6-rc s6-rc-init s6-rc-compile; do
  printf '%-16s ' "$b"
  "$TC/bin/llvm-readelf" -d "$STAGE/bin/$b" 2>/dev/null \
    | awk '/NEEDED/{gsub(/[][]/,"",$NF); printf "%s ", $NF} END{print ""}'
done
echo "DONE"
