#!/usr/bin/env bash
# Build, qualify on the hardware and package one mpeg2fpga release.
#
#   release/qualify.sh 1.0.0
#
# The same script runs by hand and from .github/workflows/release.yml (on a
# self-hosted runner next to the board: only a machine on the board's network
# can reach it). Order matters and is the point of the script -- nothing is
# packaged unless the hardware passed first:
#
#   1. preflight    the board answers, runs the bitstream release/manifest.json
#                   names, and the kernel the driver is built for
#   2. build        driver module, C frame converter
#   3. deploy       driver, daemon, board-side regression tools
#   4. regression   tools/regress (hardware_development): conformance against
#                   baseline.json, determinism, robustness, decode rate
#   5. end to end   release/e2e_check.py through the daemon and the client
#                   library: frames byte-identical to the recorded baseline,
#                   median fps >= the floor
#   6. artifacts    then, and only then: Python library (tested wheel), user
#                   guide PDF, board bundle, the bitstream's .job, notes,
#                   SHA256SUMS -> release/dist/<version>/, the board bundle and
#                   SHA256SUMS signed with the release key (release/sign.py)
#
# The bitstream is not rebuilt (synthesis is ~40 min of Libero and needs its
# licence): the manifest pins a prebuilt one, exported once with EXPORT_FPE
# into $BITSTREAM_DIR, and the board must already run it (preflight checks).
# Nor is Linux: the release ships what runs on top of the board's image.
#
# Environment (defaults in brackets):
#   BOARD          ssh target [root@192.168.18.5]
#   HW_TREE        hardware_development checkout with tools/regress and the
#                  conformance streams [../../tandem]
#   STREAMS_DIR    where the conformance streams live, if HW_TREE lacks them
#   KERNEL_SRC     kernel tree the module builds against
#                  [~/kernel-src/linux4microchip-linux]
#   BITSTREAM_DIR  prebuilt bitstreams [~/mpeg2fpga-bitstreams]
#   FPS_FLOOR      end-to-end floor [manifest]
#   PYTHON         >= 3.9, for the client library and e2e [python3.11]
#   REGRESS_PYTHON with numpy, for tools/regress [python3]
#   MPEG2FPGA_SIGNING_KEY   the release private key
#                  [~/.config/mpeg2fpga/release-key.pem]
#   MPEG2FPGA_SIGNING_PASS  its passphrase; asked once at the start when unset
#                  and there is a terminal. Checked in the preflight, so a
#                  wrong one fails in seconds, not after the regression.

set -euo pipefail

VERSION="${1:?usage: qualify.sh X.Y.Z}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || { echo "bad version $VERSION" >&2; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FW="$(dirname "$HERE")"
BOARD="${BOARD:-root@192.168.18.5}"
BOARD_HOST="${BOARD#*@}"
HW_TREE="${HW_TREE:-$FW/../tandem}"
TOOLS="$HW_TREE/trunk/mpeg2fpga/tools"
KERNEL_SRC="${KERNEL_SRC:-$HOME/kernel-src/linux4microchip-linux}"
BITSTREAM_DIR="${BITSTREAM_DIR:-$HOME/mpeg2fpga-bitstreams}"
PYTHON="${PYTHON:-python3.11}"
REGRESS_PYTHON="${REGRESS_PYTHON:-python3}"
MANIFEST="$HERE/manifest.json"
m() { "$PYTHON" -c "import json,sys; d=json.load(open('$MANIFEST')); print(eval('d'+sys.argv[1]))" "$1"; }
BIT_BUILD="$(m "['bitstream']['build']")"
BIT_JOB="$BITSTREAM_DIR/$(m "['bitstream']['dir']")/$(m "['bitstream']['job']")"
BIT_SHA="$(m "['bitstream']['sha256']")"
KERNEL="$(m "['board']['kernel']")"
FPS_FLOOR="${FPS_FLOOR:-$(m "['fps_floor']")}"
DIST="$HERE/dist/$VERSION"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
on_board() { ssh -o BatchMode=yes -o ConnectTimeout=10 "$BOARD" "$@"; }
step() { printf '\n=== %s\n' "$*"; }

rm -rf "$DIST" && mkdir -p "$DIST"

# --------------------------------------------------------------- 1. preflight
step "1/6 preflight"
on_board true || { echo "board $BOARD not reachable" >&2; exit 1; }
# a previous run that failed mid-deploy can leave the driver unloaded: bring
# it back before asking which bitstream runs, so "none" means no driver at all
on_board 'ls /sys/bus/platform/drivers/mpeg2fpga/*/build >/dev/null 2>&1 || systemctl restart mpeg2fpga-overlay' || true
running="$(on_board 'cat /sys/bus/platform/drivers/mpeg2fpga/*/build 2>/dev/null || echo none')"
[ "$running" != none ] || { echo "mpeg2fpga driver not bound on the board (overlay/module)" >&2; exit 1; }
if [ "$running" != "$BIT_BUILD" ]; then
    echo "board runs bitstream '$running', the manifest wants '$BIT_BUILD'." >&2
    echo "Program $BIT_JOB with FlashPro Express first (JTAG), then re-run." >&2
    exit 1
fi
echo "bitstream $running"
echo "$BIT_SHA  $BIT_JOB" | sha256sum -c --quiet - || { echo "bitstream file checksum mismatch" >&2; exit 1; }
kernel="$(on_board uname -r)"
[ "$kernel" = "$KERNEL" ] || { echo "board kernel $kernel, module built for $KERNEL" >&2; exit 1; }
echo "kernel $kernel"
if [ -z "${MPEG2FPGA_SIGNING_PASS:-}" ] && [ -t 0 ]; then
    read -r -s -p "release key passphrase: " MPEG2FPGA_SIGNING_PASS && echo
fi
[ -n "${MPEG2FPGA_SIGNING_PASS:-}" ] || { echo "MPEG2FPGA_SIGNING_PASS unset: releases are signed (release/sign.py)" >&2; exit 1; }
export MPEG2FPGA_SIGNING_PASS
"$PYTHON" -m venv "$WORK/venv-sign"
"$WORK/venv-sign/bin/pip" install --quiet --disable-pip-version-check cryptography
sign() { "$WORK/venv-sign/bin/python" "$HERE/sign.py" "$@"; }
echo probe > "$WORK/probe" && sign sign "$WORK/probe" >/dev/null && sign verify "$WORK/probe" >/dev/null
echo "release key unlocked, matches release/keys/mpeg2fpga-release.pub.pem"
[ -d "$TOOLS/regress" ] || { echo "no tools/regress under HW_TREE=$HW_TREE" >&2; exit 1; }
if [ ! -d "$TOOLS/streams/tek" ] && [ -n "${STREAMS_DIR:-}" ]; then
    rm -rf "$TOOLS/streams" && ln -s "$STREAMS_DIR" "$TOOLS/streams"
fi
if [ ! -d "$TOOLS/streams/tek" ]; then
    echo "conformance streams missing under $TOOLS/streams." >&2
    if [ -z "${STREAMS_DIR:-}" ]; then
        echo "STREAMS_DIR is empty. From the Release workflow it comes from the repository" >&2
        echo "*variable* MPEG2FPGA_STREAMS_DIR (Settings -> Secrets and variables -> Actions ->" >&2
        echo "Variables tab; a secret of that name is not visible to vars.*)." >&2
    else
        echo "STREAMS_DIR=$STREAMS_DIR does not contain tek/ (wrong path, or not readable by $(id -un))." >&2
    fi
    exit 1
fi

# --------------------------------------------------------------- 2. build
step "2/6 build board software"
make -s -C "$KERNEL_SRC" ARCH=riscv CROSS_COMPILE=riscv64-linux-gnu- M="$FW/driver/mpeg2fpga" modules
make -s -C "$FW/daemon/native"
make -s -C "$TOOLS/mpeg2dec" >/dev/null 2>&1 || true      # reference decoder for regress

# --------------------------------------------------------------- 3. deploy
step "3/6 deploy"
on_board 'rm -rf /tmp/m2f-release && mkdir -p /tmp/m2f-release /root/webserver'
scp -q -r "$FW/driver/mpeg2fpga/tools" "$BOARD:/tmp/m2f-release/driver-tools"
scp -q "$FW/driver/mpeg2fpga/mpeg2fpga.ko" "$BOARD:/tmp/m2f-release/driver-tools/"
scp -q -r "$FW/daemon" "$FW/api/PROTOCOL-v1.md" "$BOARD:/tmp/m2f-release/"
scp -q "$FW"/webserver/*.py "$BOARD:/root/webserver/"
# The overlay unit is a oneshot that is normally already active: installing
# it with `enable --now` does not run it again, so after rmmod the new module
# would never load. Restart it explicitly.
on_board 'systemctl stop mpeg2fpgad 2>/dev/null; rmmod mpeg2fpga 2>/dev/null
          sh /tmp/m2f-release/driver-tools/install-on-board.sh >/dev/null 2>&1
          systemctl restart mpeg2fpga-overlay
          test -e /dev/mpeg2fpga || { echo "driver did not come up" >&2; exit 1; }
          sh /tmp/m2f-release/daemon/install-on-board.sh >/dev/null 2>&1'
on_board 'systemctl is-active mpeg2fpgad' >/dev/null
on_board cat /etc/mpeg2fpgad/token > "$WORK/token"
echo "driver $(on_board cat /sys/module/mpeg2fpga/version), daemon up"

# --------------------------------------------------------------- 4. regression
step "4/6 regression (tools/regress)"
# tools/regress drives the decoder itself: the daemon must not hold it meanwhile
on_board systemctl stop mpeg2fpgad
set +e
(cd "$TOOLS/regress" && REGRESS_BOARD="$BOARD" "$REGRESS_PYTHON" -u regress.py all) | tee "$WORK/regress.log"
regress_rc=${PIPESTATUS[0]}
set -e
on_board systemctl start mpeg2fpgad
sleep 2
report="$(sed -n 's/^wrote //p' "$WORK/regress.log" | tail -1)"
[ -n "$report" ] && cp "$report" "$DIST/regression-report.md"
[ "$regress_rc" = 0 ] || { echo "REGRESSION: not releasing (report: $report)" >&2; exit 1; }

# --------------------------------------------------------------- 5. end to end
step "5/6 end to end through the daemon (floor $FPS_FLOOR fps)"
"$PYTHON" "$HERE/e2e_check.py" --host "$BOARD_HOST" --token-file "$WORK/token" \
    --streams-root "$TOOLS" --fps-floor "$FPS_FLOOR" --json "$DIST/e2e.json"

# --------------------------------------------------------------- 6. artifacts
step "6/6 artifacts"
PYTHON="$PYTHON" "$FW/api/python/build_release.sh" "$VERSION" > "$WORK/python.log" 2>&1 \
    || { cat "$WORK/python.log"; exit 1; }
cp "$FW"/api/python/dist/*.whl "$FW"/api/python/dist/*.tar.gz "$DIST/"
make -s -C "$FW/user-guide" VERSION="$VERSION" > "$WORK/guide.log" 2>&1 \
    || { tail -30 "$WORK/guide.log"; exit 1; }
cp "$FW/user-guide/build/mpeg2fpga-user-guide.pdf" "$DIST/mpeg2fpga-user-guide-$VERSION.pdf"
cp "$FW/user-guide/build/mpeg2fpga-user-guide-en.pdf" "$DIST/mpeg2fpga-user-guide-$VERSION-en.pdf"
{ make -s -C "$FW/doxygen" clean && make -s -C "$FW/doxygen" tarball VERSION="$VERSION"; } > "$WORK/refman.log" 2>&1 \
    || { tail -30 "$WORK/refman.log"; exit 1; }
cp "$FW/doxygen/build/mpeg2fpga-reference-manual-$VERSION.tar.gz" "$DIST/"
cp "$BIT_JOB" "$DIST/mpeg2fpga-bitstream-$BIT_BUILD.job"
cp "$FW/api/PROTOCOL-v1.md" "$DIST/"
cp "$FW/LICENSE" "$FW/LICENSES.md" "$FW/THIRD_PARTY_NOTICES.md" "$DIST/"

B="$WORK/mpeg2fpga-board-$VERSION"
mkdir -p "$B/driver" "$B/daemon" "$B/update"
cp "$HERE/board/mpeg2fpga-update" "$HERE/board/install-on-board.sh" "$HERE/keys/mpeg2fpga-release.pub.pem" "$B/update/"
mv "$B/update/mpeg2fpga-release.pub.pem" "$B/update/release-key.pub.pem"
cp -r "$FW/driver/mpeg2fpga/tools/." "$B/driver/"
cp "$FW/driver/mpeg2fpga/mpeg2fpga.ko" "$B/driver/"
cp -r "$FW/daemon/mpeg2fpgad" "$FW/daemon/systemd" "$FW/daemon/install-on-board.sh" "$B/daemon/"
mkdir -p "$B/daemon/native/riscv64" && cp "$FW/daemon/native/riscv64/libm2fconv.so" "$B/daemon/native/riscv64/"
cp "$FW/api/PROTOCOL-v1.md" "$FW/LICENSE" "$FW/THIRD_PARTY_NOTICES.md" "$B/"
find "$B" -name __pycache__ -prune -exec rm -rf {} +
cat > "$B/INSTALL" <<EOF
mpeg2fpga $VERSION -- board software (driver + mpeg2fpgad)
Needs: bitstream $BIT_BUILD programmed, kernel $KERNEL.

Updating a board that already has mpeg2fpga-update: copy this package and its
.sig to the board, then as root
    mpeg2fpga-update mpeg2fpga-board-$VERSION.tar.gz
It checks the signature against the release key already on the board and
installs nothing if it does not match.

First installation, on a board without it: check the package on a trusted
machine first (release-notes.md, "Checking the files"), then on the board, as
root, from this directory:
    sh update/install-on-board.sh            # release key + mpeg2fpga-update
    sh driver/install-on-board.sh
    sh daemon/install-on-board.sh            # --tls for HTTPS
Then: cat /etc/mpeg2fpgad/token
EOF
tar -C "$WORK" -czf "$DIST/mpeg2fpga-board-$VERSION.tar.gz" "mpeg2fpga-board-$VERSION"

"$PYTHON" - "$DIST" "$VERSION" "$BIT_BUILD" "$KERNEL" "$FPS_FLOOR" <<'EOF'
import json, os, sys
dist, version, bit, kernel, floor = sys.argv[1:]
e2e = json.load(open(os.path.join(dist, "e2e.json")))
rows = "\n".join("| %s | %d | %.2f | %s |" % (k, v["frames"], v["fps_median"], ", ".join(map(str, v["fps_runs"])))
                 for k, v in e2e["streams"].items())
notes = f"""# mpeg2fpga {version}

Qualified on the hardware before publishing: conformance regression,
determinism, robustness and decode rate (`regression-report.md`), then end to
end through `mpeg2fpgad` and the client library, every frame byte-identical
to the recorded baseline and the median at or above {floor} fps.

| | |
|---|---|
| bitstream | `{bit}` (`mpeg2fpga-bitstream-{bit}.job`, program with FlashPro Express) |
| board kernel | `{kernel}` |
| daemon / driver | {e2e["device"]["daemon"]} / {e2e["device"]["driver"]} |

## End to end (client library, no TLS)

| stream | frames | median fps | runs |
|---|---|---|---|
{rows}

## Files

- `mpeg2fpga-board-{version}.tar.gz` -- driver and daemon, see its INSTALL
- `mpeg2fpga-{version}-py3-none-any.whl` -- Python client (`pip install`)
- `mpeg2fpga-user-guide-{version}.pdf` (Spanish), `mpeg2fpga-user-guide-{version}-en.pdf` (English)
- `mpeg2fpga-reference-manual-{version}.tar.gz` -- Reference Manual (HTML, open index.html)
- `PROTOCOL-v1.md` -- network protocol
- `LICENSE`, `LICENSES.md`, `THIRD_PARTY_NOTICES.md` -- licences of each file and
  where its source is
- `SHA256SUMS`, `SHA256SUMS.sig` -- checksums of every file, signed
- `mpeg2fpga-board-{version}.tar.gz.sig` -- what `mpeg2fpga-update` checks on the board

## Checking the files

`mpeg2fpga-release.pub.pem` is the project's Ed25519 public key; take it from
the source repository (`release/keys/`), not from the same place as the
files. With OpenSSL 3:

    openssl pkeyutl -verify -pubin -inkey mpeg2fpga-release.pub.pem \\
        -rawin -in SHA256SUMS -sigfile SHA256SUMS.sig
    sha256sum -c SHA256SUMS

The first proves the checksums come from the project, the second that every
file matches them.
"""
open(os.path.join(dist, "release-notes.md"), "w").write(notes)
EOF
sign sign "$DIST/mpeg2fpga-board-$VERSION.tar.gz" >/dev/null
(cd "$DIST" && sha256sum -- *.whl *.tar.gz *.sig *.pdf *.job *.md LICENSE e2e.json > SHA256SUMS)
sign sign "$DIST/SHA256SUMS" >/dev/null
sign verify "$DIST/SHA256SUMS" "$DIST/mpeg2fpga-board-$VERSION.tar.gz"
step "release $VERSION qualified"
ls -l "$DIST"
