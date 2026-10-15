#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Check an RSA signature (PKCS #1 v1.5, SHA-256) of a file.

    tsx-verify-sig.py PUBKEY.pem FILE FILE.sig

PUBKEY.pem is a PEM "PUBLIC KEY" (SubjectPublicKeyInfo), for example the apk
key of the project in /etc/apk/keys. FILE.sig is the raw signature, as
"openssl dgst -sha256 -sign KEY -out FILE.sig FILE" writes it. The script
uses only the Python standard library, because the kiosk has no openssl
command (installer/steps/tsx-netinstall). It prints "signature ok" and exits 0
for a good signature. It exits 1 for a bad signature and 2 for a bad key or
bad arguments.
"""
import base64
import hashlib
import sys

# DER of DigestInfo for SHA-256 (RFC 8017, section 9.2, note 1)
SHA256_PREFIX = bytes.fromhex("3031300d060960864801650304020105000420")


def der(data, pos, tag):
    """Read one DER element with TAG at POS. Return (body start, body end)."""
    if pos + 2 > len(data) or data[pos] != tag:
        raise ValueError("unexpected DER tag")
    n = data[pos + 1]
    pos += 2
    if n & 0x80:
        k = n & 0x7F
        if k == 0 or k > 4 or pos + k > len(data):
            raise ValueError("bad DER length")
        n = int.from_bytes(data[pos:pos + k], "big")
        pos += k
    if pos + n > len(data):
        raise ValueError("DER element runs past the end")
    return pos, pos + n


def public_key(pem):
    lines = [l.strip() for l in pem.decode("ascii", "replace").splitlines()]
    try:
        a = lines.index("-----BEGIN PUBLIC KEY-----")
        b = lines.index("-----END PUBLIC KEY-----")
    except ValueError:
        raise ValueError("no PEM PUBLIC KEY block")
    d = base64.b64decode("".join(lines[a + 1:b]), validate=True)
    s, _ = der(d, 0, 0x30)                    # SubjectPublicKeyInfo
    alg_s, alg_e = der(d, s, 0x30)            # AlgorithmIdentifier
    if bytes.fromhex("2a864886f70d010101") not in d[alg_s:alg_e]:
        raise ValueError("not an RSA key")
    bs, be = der(d, alg_e, 0x03)              # BIT STRING
    if d[bs] != 0:
        raise ValueError("bad BIT STRING")
    k, _ = der(d, bs + 1, 0x30)               # RSAPublicKey
    ns, ne = der(d, k, 0x02)
    es, ee = der(d, ne, 0x02)
    return int.from_bytes(d[ns:ne], "big"), int.from_bytes(d[es:ee], "big")


def main(argv):
    if len(argv) != 4:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2
    try:
        n, e = public_key(open(argv[1], "rb").read())
    except (OSError, ValueError) as err:
        print("tsx-verify-sig: %s: %s" % (argv[1], err), file=sys.stderr)
        return 2
    k = (n.bit_length() + 7) // 8
    if k < 256:
        print("tsx-verify-sig: the key has less than 2048 bits", file=sys.stderr)
        return 2
    sig = open(argv[3], "rb").read()
    digest = hashlib.sha256(open(argv[2], "rb").read()).digest()
    want = b"\x00\x01" + b"\xff" * (k - 3 - len(SHA256_PREFIX) - 32) + b"\x00" + SHA256_PREFIX + digest
    if len(sig) != k or pow(int.from_bytes(sig, "big"), e, n).to_bytes(k, "big") != want:
        print("tsx-verify-sig: BAD signature of %s (key %s)" % (argv[2], argv[1]), file=sys.stderr)
        return 1
    print("signature ok")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
