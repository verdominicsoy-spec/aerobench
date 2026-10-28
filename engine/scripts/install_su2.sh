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

# SU2's own meson.py wrapper clones every bundled library as a git
# submodule. Only two are needed with autodiff, CoolProp and Mutation++ off:
# MEL (GitHub) and Eigen (gitlab.com, which refuses anonymous clones from
# some networks, hence the fallbacks).
say "Getting MEL and Eigen"
git submodule update --init --depth 1 externals/mel || git submodule update --init externals/mel
if [ ! -f externals/eigen/Eigen/Dense ]; then
  rm -rf externals/eigen && mkdir -p externals/eigen
  if curl -fsSL "https://gitlab.com/libeigen/eigen/-/archive/3.4/eigen-3.4.tar.gz" | tar xz --strip-components=1 -C externals/eigen \
     && [ -f externals/eigen/Eigen/Dense ]; then
    echo "Eigen 3.4 from the GitLab archive"
  elif rm -rf externals/eigen && git submodule update --init externals/eigen && [ -f externals/eigen/Eigen/Dense ]; then
    echo "Eigen from its git repository"
  elif command -v brew >/dev/null && (brew install eigen@3 || brew install eigen) \
       && EIGEN="$( (brew --prefix eigen@3 || brew --prefix eigen) 2>/dev/null)/include/eigen3" && [ -f "$EIGEN/Eigen/Dense" ]; then
    rm -rf externals/eigen && ln -s "$EIGEN" externals/eigen
    echo "Eigen from Homebrew ($EIGEN)"
  else
    echo "Could not get Eigen (gitlab.com unreachable and no Homebrew)."; exit 1
  fi
fi
touch su2preconfig.timestamp  # what SU2's preconfigure.py leaves once its submodules are in

say "Getting the build tools (meson, ninja)"
TOOLS="$HERE/build/su2-tools"
[ -x "$TOOLS/bin/meson" ] || { "$PY" -m venv "$TOOLS" && "$TOOLS/bin/pip" install -q "meson>=1.8.2,<2" ninja; }
export PATH="$TOOLS/bin:$PATH"

say "Configuring (MPI $MPI)"
WIPE=""
[ -d build ] && WIPE="--wipe"  # a half-finished earlier attempt
meson setup build $WIPE --prefix="$PREFIX" --buildtype=release \
  -Dwith-mpi="$MPI" -Denable-autodiff=false -Denable-directdiff=false -Denable-pywrapper=false \
  -Denable-tecio=false -Denable-cgns=false

JOBS="$( (sysctl -n hw.ncpu 2>/dev/null || nproc 2>/dev/null || echo 4) )"
say "Building with $JOBS jobs (the long part)"
ninja -C build -j "$JOBS" install

"$PREFIX/bin/SU2_CFD" --help | head -1
say "Done. AeroBench finds SU2 in $PREFIX/bin by itself."
