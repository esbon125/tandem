#!/usr/bin/env python3
"""Ed25519 release signatures for mpeg2fpga.

    sign.py genkey                 new project key, passphrase-protected
    sign.py sign FILE...           writes FILE.sig next to each FILE
    sign.py verify FILE...         checks FILE.sig against the public key

A .sig is the raw 64-byte Ed25519 signature of the whole file, so anything
with OpenSSL 3 checks it without this script (that is what the board does):

    openssl pkeyutl -verify -pubin -inkey mpeg2fpga-release.pub.pem \\
        -rawin -in FILE -sigfile FILE.sig

The private key never enters the repository: it lives in --key (default
~/.config/mpeg2fpga/release-key.pem, PKCS#8 encrypted with the passphrase).
The public key is release/keys/mpeg2fpga-release.pub.pem, committed; signing
refuses a private key that does not match it. The passphrase comes from
MPEG2FPGA_SIGNING_PASS or, failing that, from the terminal.

Needs the `cryptography` package (OpenSSL 1.1.1 on the build host cannot
sign Ed25519 from the command line).
"""
import argparse
import getpass
import os
import sys

from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_KEY = os.path.expanduser("~/.config/mpeg2fpga/release-key.pem")
DEFAULT_PUB = os.path.join(HERE, "keys", "mpeg2fpga-release.pub.pem")
PUBLIC = dict(encoding=serialization.Encoding.PEM,
              format=serialization.PublicFormat.SubjectPublicKeyInfo)


def passphrase(confirm=False):
    p = os.environ.get("MPEG2FPGA_SIGNING_PASS")
    if p:
        return p.encode()
    p = getpass.getpass("release key passphrase: ")
    if confirm and p != getpass.getpass("again: "):
        sys.exit("passphrases differ")
    if not p:
        sys.exit("empty passphrase")
    return p.encode()


def genkey(a):
    if os.path.exists(a.key):
        sys.exit(f"{a.key} exists; not overwriting a release key")
    key = Ed25519PrivateKey.generate()
    pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                            serialization.BestAvailableEncryption(passphrase(confirm=True)))
    os.makedirs(os.path.dirname(a.key), mode=0o700, exist_ok=True)
    fd = os.open(a.key, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "wb") as f:
        f.write(pem)
    os.makedirs(os.path.dirname(a.pub), exist_ok=True)
    with open(a.pub, "wb") as f:
        f.write(key.public_key().public_bytes(**PUBLIC))
    print(f"private key: {a.key} (keep a copy offline; losing it means boards\n"
          f"             can only be updated by reinstalling the trust anchor)")
    print(f"public key:  {a.pub} (commit it)")


def load_pub(path):
    with open(path, "rb") as f:
        return serialization.load_pem_public_key(f.read())


def sign(a):
    with open(a.key, "rb") as f:
        try:
            key = serialization.load_pem_private_key(f.read(), passphrase())
        except ValueError:
            sys.exit("cannot unlock the release key (wrong passphrase?)")
    if key.public_key().public_bytes(**PUBLIC) != load_pub(a.pub).public_bytes(**PUBLIC):
        sys.exit(f"{a.key} does not match {a.pub}")
    for name in a.files:
        with open(name, "rb") as f:
            sig = key.sign(f.read())
        with open(name + ".sig", "wb") as f:
            f.write(sig)
        print(f"signed {name}")


def verify(a):
    pub = load_pub(a.pub)
    bad = 0
    for name in a.files:
        with open(name, "rb") as f, open(name + ".sig", "rb") as s:
            try:
                pub.verify(s.read(), f.read())
                print(f"{name}: good signature")
            except InvalidSignature:
                print(f"{name}: BAD signature", file=sys.stderr)
                bad += 1
    sys.exit(1 if bad else 0)


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--key", default=os.environ.get("MPEG2FPGA_SIGNING_KEY", DEFAULT_KEY))
    p.add_argument("--pub", default=DEFAULT_PUB)
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("genkey").set_defaults(fn=genkey)
    for name, fn in (("sign", sign), ("verify", verify)):
        s = sub.add_parser(name)
        s.add_argument("files", nargs="+")
        s.set_defaults(fn=fn)
    a = p.parse_args()
    a.fn(a)


if __name__ == "__main__":
    main()
