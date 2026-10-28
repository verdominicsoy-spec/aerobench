#!/bin/bash
# Builds SU2 from source into <repo>/build/su2 (not committed) for Wing Lab's
# RANS runs. Once; takes 10 to 20 minutes on a Mac.
#
#   ./engine/scripts/install_su2.sh
#
# Needs git and a C++ compiler (Xcode's command line tools on a Mac:
# xcode-select --install). With Open MPI installed (brew install open-mpi)
# SU2 runs on several cores; without it, on one.
set -euo pipefail

VERSION="${SU2_VERSION:-v8.5.0}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC="$HERE/build/su2-src"
PREFIX="$HERE/build/su2"

say() { printf '\n\033[1m%s\033[0m\n' "$1"; }

if [ -x "$PREFIX/bin/SU2_CFD" ] && "$PREFIX/bin/SU2_CFD" --help 2>/dev/null | grep -q "${VERSION#v}"; then
  say "SU2 $VERSION is already installed in $PREFIX/bin"
  exit 0
fi

command -v git >/dev/null || { echo "git is needed (xcode-select --install)"; exit 1; }
command -v c++ >/dev/null || { echo "a C++ compiler is needed (xcode-select --install)"; exit 1; }
PY="$(command -v python3 || true)"
[ -n "$PY" ] || { echo "python3 is needed"; exit 1; }

say "Getting SU2 $VERSION"
if [ ! -d "$SRC/.git" ]; then
  rm -rf "$SRC"
  git clone --depth 1 --branch "$VERSION" https://github.com/su2code/SU2.git "$SRC"
fi
cd "$SRC"

MPI=disabled
if command -v mpicc >/dev/null && command -v mpicxx >/dev/null; then MPI=enabled; fi
say "Configuring (MPI $MPI)"
# meson.py fetches SU2's own copies of meson, ninja and its small libraries.
WIPE=""
[ -d build ] && WIPE="--wipe"  # a half-finished earlier attempt
"$PY" ./meson.py setup build $WIPE --prefix="$PREFIX" --buildtype=release \
  -Dwith-mpi="$MPI" -Denable-autodiff=false -Denable-directdiff=false -Denable-pywrapper=false \
  -Denable-tecio=false -Denable-cgns=false

JOBS="$( (sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4) )"
say "Building with $JOBS jobs (the long part)"
./ninja -C build -j "$JOBS" install

"$PREFIX/bin/SU2_CFD" --help | head -1
say "Done. AeroBench finds SU2 in $PREFIX/bin by itself."
