#!/bin/sh
# Install the release key and mpeg2fpga-update. Run as root from an unpacked
# board package. The first time, this is what makes the board trust the key:
# do it from a package checked on a trusted machine (sign.py verify, or
# openssl pkeyutl -verify, against the key published with the source).
# Afterwards mpeg2fpga-update runs it, from packages it already verified,
# which is how a new key would reach the boards.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
install -d -m 0755 /etc/mpeg2fpga /usr/local/sbin
install -m 0644 "$HERE/release-key.pub.pem" /etc/mpeg2fpga/
install -m 0755 "$HERE/mpeg2fpga-update" /usr/local/sbin/
echo "release key and mpeg2fpga-update installed"
