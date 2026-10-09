#!/usr/bin/env bash
# Build a release of the mpeg2fpga Python client: test, package, verify.
#
# The same script runs locally and in .github/workflows/python-client.yml, so
# a release is never built by steps that only exist in CI. It never modifies
# the tree: the version is stamped into a copy of the sources.
#
#   ./build_release.sh [VERSION]
#
# VERSION defaults to the python-vX.Y.Z tag on HEAD, or, untagged,
# 0.0.0.devN+g<hash> (N = commits since the last such tag). Output in
# dist/: the wheel, the sdist and SHA256SUMS.
#
# Needs python3 >= 3.9 with venv; fetches `build` from PyPI into a throwaway
# venv. PYTHON overrides the interpreter.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="${PYTHON:-python3}"
DIST="$HERE/dist"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

"$PYTHON" -c 'import sys; assert sys.version_info >= (3, 9), sys.version' \
    || { echo "need Python >= 3.9 (set PYTHON=...)" >&2; exit 1; }

# -- version ---------------------------------------------------------------
VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    if TAG=$(git -C "$HERE" describe --tags --exact-match --match 'python-v*' 2>/dev/null); then
        VERSION="${TAG#python-v}"
    else
        LAST=$(git -C "$HERE" describe --tags --abbrev=0 --match 'python-v*' 2>/dev/null || true)
        if [ -n "$LAST" ]; then
            N=$(git -C "$HERE" rev-list --count "$LAST"..HEAD)
        else
            N=$(git -C "$HERE" rev-list --count HEAD -- .)
        fi
        VERSION="0.0.0.dev$N+g$(git -C "$HERE" rev-parse --short=7 HEAD)"
    fi
fi
echo "== mpeg2fpga client $VERSION"

# -- 1. tests against the sources -----------------------------------------
echo "== tests (source tree)"
(cd "$HERE" && "$PYTHON" -m unittest discover -s tests)

# -- 2. package a stamped copy ---------------------------------------------
cp -r "$HERE/src" "$HERE/pyproject.toml" "$HERE/README.md" "$WORK/"
printf '__version__ = "%s"\n' "$VERSION" > "$WORK/src/mpeg2fpga/_version.py"
"$PYTHON" -m venv "$WORK/venv-build"
"$WORK/venv-build/bin/python" -m pip install --quiet --disable-pip-version-check build
rm -rf "$DIST"
"$WORK/venv-build/bin/python" -m build --outdir "$DIST" "$WORK" >"$WORK/build.log" \
    || { cat "$WORK/build.log"; exit 1; }

# -- 3. the built wheel, installed clean, must pass the same tests ---------
echo "== tests (installed wheel)"
"$PYTHON" -m venv "$WORK/venv-test"
"$WORK/venv-test/bin/python" -m pip install --quiet --disable-pip-version-check "$DIST"/*.whl
# the tests add ../src to sys.path for source-tree runs; here there is no
# ../src next to them, so `import mpeg2fpga` can only find the wheel
mkdir -p "$WORK/isolated/tests" && cp "$HERE"/tests/*.py "$WORK/isolated/tests/"
(cd "$WORK/isolated/tests" && "$WORK/venv-test/bin/python" - <<EOF
import sys, unittest
suite = unittest.defaultTestLoader.discover(".")
import mpeg2fpga
assert mpeg2fpga.__version__ == "$VERSION", mpeg2fpga.__version__
assert "site-packages" in mpeg2fpga.__file__, mpeg2fpga.__file__
sys.exit(not unittest.TextTestRunner(verbosity=1).run(suite).wasSuccessful())
EOF
)

(cd "$DIST" && sha256sum -- * > SHA256SUMS)
echo "== built:"
ls -l "$DIST"
