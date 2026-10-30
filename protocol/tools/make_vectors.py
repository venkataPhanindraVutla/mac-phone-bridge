#!/usr/bin/env python3
"""Reference implementation and vector generator for the Android Mirroring protocol.

Run as:  python3 -I protocol/tools/make_vectors.py [--check]

Writes protocol/vectors/{framing,crypto,pairing_uri,filenames,scrcpy}.json. With --check it regenerates
in memory and exits 1 if any file on disk differs. Output is fully deterministic: all
"random" inputs are derived from fixed labels with SHA-256. Standard library only
(the test certificates are read from the committed .p12 files via the `openssl` CLI).
"""
import base64
import hashlib
import hmac
import json
import re
import shutil
import struct
import subprocess
import sys
import unicodedata
from pathlib import Path
from urllib.parse import quote

ROOT = Path(__file__).resolve().parent.parent  # protocol/
VECTORS = ROOT / "vectors"
IDENTITIES = ROOT / "testdata" / "identities"

MAX_FRAME = 1_048_576
PROTOCOL_VERSION = 1
PAIR_LABEL = b"anmirror-pair-v1"
SAS_LABEL = b"anmirror-sas-v1"
RID_LABEL = b"anmirror-rid-v1"
RID_EPOCH_SECONDS = 900
BLE_LABEL = b"anmirror-ble-v1"

CHANNELS = {"SYSTEM": 1, "PAIRING": 2, "STATUS": 3, "FIND": 4,
            "NOTIFY": 5, "CONTACTS": 6, "CALLS": 7, "CLIPBOARD": 8, "SHARE": 9, "FILES": 10,
            "SCREENSHOTS": 11, "PHOTOS": 12, "BROWSE": 13, "MEDIA": 14, "DND": 15, "PROXIMITY": 16,
            "INPUT": 17, "MIRROR": 18}


# ---------------------------------------------------------------- protobuf encoding
def varint(n: int) -> bytes:
    if n < 0:  # negative int32/int64 are sign-extended to 64 bits (10 bytes)
        n += 1 << 64
    out = bytearray()
    while True:
        b = n & 0x7F
        n >>= 7
        if n:
            out.append(b | 0x80)
        else:
            out.append(b)
            return bytes(out)


def f_varint(num: int, value: int) -> bytes:
    return b"" if value == 0 else varint(num << 3) + varint(value)


def f_bytes(num: int, value: bytes) -> bytes:
    return b"" if not value else varint(num << 3 | 2) + varint(len(value)) + value


def f_float(num: int, value: float) -> bytes:
    """proto3 float: fixed32, little endian; 0.0 is omitted."""
    return b"" if value == 0 else varint(num << 3 | 5) + struct.pack("<f", value)


def f_string(num: int, value: str) -> bytes:
    return f_bytes(num, value.encode("utf-8"))


def encode_envelope(channel: int, id_: int, reply_to: int, type_: str, payload: bytes) -> bytes:
    """proto3: fields equal to their default are omitted; fields in number order."""
    return (f_varint(1, channel) + f_varint(2, id_) + f_varint(3, reply_to)
            + f_string(4, type_) + f_bytes(5, payload))


def encode_frame(envelope: bytes) -> bytes:
    if len(envelope) == 0:
        raise ValueError("emptyFrame")
    if len(envelope) > MAX_FRAME:
        raise ValueError("frameTooLarge")
    return len(envelope).to_bytes(4, "big") + envelope


def decode_frame_header(frame: bytes) -> int:
    """Returns body length, or raises ValueError('emptyFrame' | 'frameTooLarge')."""
    n = int.from_bytes(frame[:4], "big")
    if n == 0:
        raise ValueError("emptyFrame")
    if n > MAX_FRAME:
        raise ValueError("frameTooLarge")
    return n


# ---------------------------------------------------------------- crypto definitions
def fingerprint(cert_der: bytes) -> bytes:
    return hashlib.sha256(cert_der).digest()


def secret_proof(secret: bytes, mac_fp: bytes, phone_fp: bytes) -> bytes:
    return hmac.new(secret, PAIR_LABEL + mac_fp + phone_fp, hashlib.sha256).digest()


def confirmation_code(mac_fp: bytes, phone_fp: bytes) -> str:
    h = hashlib.sha256(SAS_LABEL + mac_fp + phone_fp).digest()
    return "%06d" % (int.from_bytes(h[:4], "big") % 1_000_000)


def rotating_id(discovery_key: bytes, unix_seconds: int) -> str:
    epoch = unix_seconds // RID_EPOCH_SECONDS
    mac = hmac.new(discovery_key, RID_LABEL + epoch.to_bytes(8, "big"), hashlib.sha256).digest()
    return mac[:8].hex()


def ble_id(discovery_key: bytes, phone_fp: bytes, epoch: int) -> bytes:
    """8-byte BLE advertisement ID (SPEC section 22)."""
    return hmac.new(discovery_key, BLE_LABEL + phone_fp + epoch.to_bytes(8, "big"),
                    hashlib.sha256).digest()[:8]


def artwork_key(jpeg: bytes) -> str:
    """Lowercase hex of the first 8 bytes of SHA-256 over the JPEG; empty for no artwork."""
    return hashlib.sha256(jpeg).digest()[:8].hex() if jpeg else ""


def det(label: str, n: int = 32) -> bytes:
    """Deterministic stand-in for 'random' bytes."""
    out = b""
    i = 0
    while len(out) < n:
        out += hashlib.sha256(f"anmirror-vector-seed/{label}/{i}".encode()).digest()
        i += 1
    return out[:n]


# ---------------------------------------------------------------- pairing URI
class UriError(Exception):
    pass


def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).decode().rstrip("=")


def b64url_decode(s: str) -> bytes:
    allowed = set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
    if not s or any(c not in allowed for c in s) or len(s) % 4 == 1:
        raise UriError("malformed")
    data = base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))
    if b64url(data) != s:  # canonical only: unused trailing bits must be zero
        raise UriError("malformed")
    return data


def pct_encode(s: str) -> str:
    return quote(s, safe="-._~")  # RFC 3986 unreserved kept, UTF-8 bytes otherwise


def pct_decode(s: str) -> str:
    """An escape is '%' followed by exactly two ASCII hex digits; anything else is malformed."""
    out = bytearray()
    i = 0
    while i < len(s):
        c = s[i]
        if c == "%":
            h = s[i + 1:i + 3]
            if not re.fullmatch(r"[0-9A-Fa-f]{2}", h):
                raise UriError("malformed")
            out.append(int(h, 16))
            i += 3
        elif ord(c) < 0x80:
            out.append(ord(c))
            i += 1
        else:
            raise UriError("malformed")  # raw non-ASCII must be percent-encoded
    try:
        return out.decode("utf-8")
    except UnicodeDecodeError:
        raise UriError("malformed")


def canonical_uint(s: str):
    """Canonical ASCII decimal: '0' or no leading zeros. Returns int, or None if not canonical."""
    return int(s) if re.fullmatch(r"0|[1-9][0-9]*", s, re.ASCII) else None


def encode_pairing_uri(mac_fp: bytes, secret: bytes, hosts: list, port: int, mac_name: str) -> str:
    return ("anmirror://pair?v=1&fp=%s&s=%s&h=%s&p=%d&n=%s"
            % (b64url(mac_fp), b64url(secret), ",".join(hosts), port, pct_encode(mac_name)))


def parse_pairing_uri(uri: str) -> dict:
    """Returns the fields dict or raises UriError('unsupportedVersion' | 'malformed')."""
    prefix = "anmirror://pair?"
    if not uri.startswith(prefix):
        raise UriError("malformed")
    params = {}
    for part in uri[len(prefix):].split("&"):
        if not part:
            continue
        k, _, v = part.partition("=")
        if k in params:
            raise UriError("malformed")  # duplicate parameter
        params[k] = v
    version = canonical_uint(params.get("v", ""))
    if version is None:
        raise UriError("malformed")
    if version != 1:
        raise UriError("unsupportedVersion")
    try:
        fp = b64url_decode(params["fp"])
        secret = b64url_decode(params["s"])
        if len(fp) != 32 or len(secret) != 32:
            raise UriError("malformed")
        hosts = [h for h in params["h"].split(",")]
        if not hosts or any(h == "" for h in hosts):
            raise UriError("malformed")
        port = canonical_uint(params["p"])
        if port is None or not (1 <= port <= 65535):
            raise UriError("malformed")
        name = pct_decode(params.get("n", ""))
    except KeyError:
        raise UriError("malformed")
    return {"version": 1, "fp_hex": fp.hex(), "secret_hex": secret.hex(),
            "hosts": hosts, "port": port, "mac_name": name}


# ---------------------------------------------------------------- test identities
def load_identities() -> list:
    if shutil.which("openssl") is None:
        print("error: `openssl` not found on PATH (needed to read the test .p12 identities)",
              file=sys.stderr)
        sys.exit(2)
    out = []
    for name in ("mac", "phone", "stranger"):
        p12 = str(IDENTITIES / f"{name}.p12")
        pem = None
        for extra in ([], ["-legacy"]):
            r = subprocess.run(["openssl", "pkcs12", *extra, "-in", p12, "-passin", "pass:test",
                                "-nokeys", "-clcerts"], capture_output=True, text=True)
            if r.returncode == 0 and "BEGIN CERTIFICATE" in r.stdout:
                pem = r.stdout
                break
        if pem is None:
            print(f"error: cannot read {p12} with openssl", file=sys.stderr)
            sys.exit(2)
        b64 = pem.split("-----BEGIN CERTIFICATE-----")[1].split("-----END CERTIFICATE-----")[0]
        der = base64.b64decode("".join(b64.split()))
        out.append({"name": name, "der": der, "fp": fingerprint(der)})
    return out


# ---------------------------------------------------------------- vector builders
def build_framing() -> dict:
    def hello_payload():
        return (f_varint(1, 1) + f_string(2, "0.1.0") + f_string(3, "status.v1")
                + f_string(3, "find.v1") + f_varint(4, 1) + f_string(5, "Pixel 8")
                + f_string(6, "Google Pixel 8"))

    cases = [
        ("ping_minimal", CHANNELS["SYSTEM"], 1, 0, "system.ping", b""),
        ("pong_reply", CHANNELS["SYSTEM"], 1, 1, "system.pong", b""),
        ("hello_full", CHANNELS["SYSTEM"], 2, 0, "system.hello", hello_payload()),
        ("error_not_paired", CHANNELS["SYSTEM"], 3, 0, "system.error",
         f_varint(1, 2) + f_string(2, "not paired")),
        ("pair_request", CHANNELS["PAIRING"], 1, 0, "pairing.request",
         f_varint(1, 1) + f_bytes(2, det("proof-payload")) + f_string(3, "Pixel 8")
         + f_string(4, "Google Pixel 8")),
        ("pair_confirm_accepted", CHANNELS["PAIRING"], 2, 0, "pairing.confirm", f_varint(1, 1)),
        ("pair_confirm_declined_empty_payload", CHANNELS["PAIRING"], 3, 0, "pairing.confirm", b""),
        ("status_update_signal_unknown", CHANNELS["STATUS"], 4, 0, "status.update",
         f_varint(1, 87) + f_varint(2, 1) + f_varint(3, -1) + f_varint(4, 2)),
        ("status_update_signal_zero_omitted", CHANNELS["STATUS"], 5, 0, "status.update",
         f_varint(1, 5) + f_varint(4, 3)),
        ("ping_from_mac", CHANNELS["SYSTEM"], 4, 0, "system.ping", b""),
        # network 2 = NETWORK_KIND_WIFI; background_restricted is field 5 (bool)
        ("status_update_background_restricted", CHANNELS["STATUS"], 6, 0, "status.update",
         f_varint(1, 40) + f_varint(3, 2) + f_varint(4, 2) + f_varint(5, 1)),
        ("find_ring", CHANNELS["FIND"], 6, 0, "find.ring", b""),
        ("find_state_reply", CHANNELS["FIND"], 7, 6, "find.state",
         f_varint(1, 1) + f_varint(2, 1)),
        ("notify_posted_minimal", CHANNELS["NOTIFY"], 1, 0, "notify.posted",
         f_string(1, "0|com.whatsapp|1|null|10123") + f_string(2, "com.whatsapp")
         + f_string(4, "Ana") + f_string(5, "hi \U0001F44B") + f_varint(10, 1)),
        # size is above 2**32 on purpose (uint64 field); kind 1 = TRANSFER_KIND_FILE
        ("files_offer_minimal", CHANNELS["FILES"], 1, 0, "files.offer",
         f_string(1, "t1") + f_string(2, "photo.jpg") + f_varint(3, 5_000_000_000)
         + f_string(4, "image/jpeg") + f_varint(5, 1)),
        # role 1 = BULK_ROLE_PHONE_SENDS
        ("bulk_hello", CHANNELS["FILES"], 1, 0, "bulk.hello",
         f_bytes(1, det("bulk-token")) + f_varint(2, 1)),
        # duration is above 2**32 on purpose (int64 field)
        ("media_state_minimal", CHANNELS["MEDIA"], 1, 0, "media.state",
         f_varint(1, 1) + f_string(2, "s1") + f_string(4, "Song") + f_varint(7, 5_000_000_000)
         + f_varint(9, 1) + f_float(10, 1.0) + f_varint(12, 1)),
        ("input_move", CHANNELS["INPUT"], 7, 0, "input.move",
         f_float(1, 1.5) + f_float(2, -2.25)),
        # tokens{video, control} (no audio); video_codec 1 = VIDEO_CODEC_H264; audio false is omitted
        ("mirror_start_minimal", CHANNELS["MIRROR"], 3, 0, "mirror.start",
         f_varint(1, 1) + f_bytes(2, f_bytes(1, det("tok-v", 32)) + f_bytes(3, det("tok-c", 32)))
         + f_varint(3, 50123) + f_varint(4, 1920) + f_varint(5, 8_000_000) + f_varint(6, 60)
         + f_varint(7, 1)),
        ("large_ids_multibyte_varint", CHANNELS["STATUS"], 300, 16384, "status.update",
         f_varint(1, 100)),
        ("unicode_type_and_payload_bytes", CHANNELS["SYSTEM"], 1, 0, "system.pongé",
         bytes(range(256))),
    ]
    vecs = []
    for name, ch, id_, reply, typ, payload in cases:
        env = encode_envelope(ch, id_, reply, typ, payload)
        vecs.append({"name": name,
                     "envelope": {"channel": ch, "id": id_, "reply_to": reply,
                                  "type": typ, "payload_hex": payload.hex()},
                     "frame_hex": encode_frame(env).hex()})
    invalid = [
        {"name": "length_zero", "frame_hex": "00000000", "error": "emptyFrame"},
        {"name": "length_one_over_limit", "frame_hex": (MAX_FRAME + 1).to_bytes(4, "big").hex(),
         "error": "frameTooLarge"},
        {"name": "length_max_uint32", "frame_hex": "ffffffff", "error": "frameTooLarge"},
    ]
    for v in invalid:  # self-check against the reference decoder
        try:
            decode_frame_header(bytes.fromhex(v["frame_hex"]))
        except ValueError as e:
            assert str(e) == v["error"], v
        else:
            raise AssertionError(v)
    return {"max_frame_bytes": MAX_FRAME, "vectors": vecs, "invalid": invalid}


def find_leading_zero_pair() -> tuple:
    """Deterministic search over seeded fingerprint pairs for a code < 100000."""
    i = 0
    while True:
        mac_fp, phone_fp = det(f"sas-search/{i}/mac"), det(f"sas-search/{i}/phone")
        if int(confirmation_code(mac_fp, phone_fp)) < 100000:
            return mac_fp, phone_fp
        i += 1


def build_crypto(ids: list) -> dict:
    by = {i["name"]: i for i in ids}
    mac, phone, stranger = by["mac"]["fp"], by["phone"]["fp"], by["stranger"]["fp"]
    fingerprints = [{"name": i["name"], "cert_der_hex": i["der"].hex(), "fp_hex": i["fp"].hex()}
                    for i in ids]

    proof_inputs = [
        (det("secret/1"), mac, phone),
        (det("secret/2"), mac, stranger),
        (bytes(32), mac, phone),  # all-zero secret edge case
        (det("secret/1"), phone, mac),  # fingerprint order matters
    ]
    proofs = [{"secret_hex": s.hex(), "mac_fp_hex": m.hex(), "phone_fp_hex": p.hex(),
               "proof_hex": secret_proof(s, m, p).hex()} for s, m, p in proof_inputs]

    lz_mac, lz_phone = find_leading_zero_pair()
    code_inputs = [(mac, phone), (mac, stranger), (phone, mac), (lz_mac, lz_phone)]
    codes = [{"mac_fp_hex": m.hex(), "phone_fp_hex": p.hex(), "code": confirmation_code(m, p)}
             for m, p in code_inputs]
    assert codes[-1]["code"].startswith("0")

    key = det("discovery-key/1")
    times = [0, 899, 900, 1_700_000_000, 1_700_000_000 + 899, 1_700_000_000 + 900]
    rids = [{"key_hex": key.hex(), "unix_seconds": t, "epoch": t // RID_EPOCH_SECONDS,
             "rid": rotating_id(key, t)} for t in times]
    rids.append({"key_hex": det("discovery-key/2").hex(), "unix_seconds": 1_700_000_000,
                 "epoch": 1_700_000_000 // RID_EPOCH_SECONDS,
                 "rid": rotating_id(det("discovery-key/2"), 1_700_000_000)})

    ble_times = [0, 899, 900, 1_700_000_000, 1_700_000_100 - 1, 1_700_000_100]
    ble_ids = []
    for fp_name, fp in (("phone", phone), ("stranger", stranger)):
        for t in ble_times:
            e = t // RID_EPOCH_SECONDS
            ble_ids.append({"key_hex": key.hex(), "phone_fp_hex": fp.hex(), "unix_seconds": t,
                            "epoch": e, "ble_id_hex": ble_id(key, fp, e).hex()})
    # lengths around SHA-256's 55/56 and 64/65 byte block boundaries
    artwork_inputs = [b"", b"jpeg"] + [det("artwork", n) for n in (55, 56, 64, 65)]
    artwork_keys = [{"jpeg_hex": j.hex(), "key": artwork_key(j)} for j in artwork_inputs]
    return {"notes": "code is a zero-padded 6-digit string",
            "fingerprints": fingerprints, "proofs": proofs, "codes": codes, "rotating_ids": rids,
            "ble_ids": ble_ids, "artwork_keys": artwork_keys}


def build_pairing_uri(ids: list) -> dict:
    by = {i["name"]: i for i in ids}
    mac_fp = by["mac"]["fp"]
    secret = det("uri-secret/1")

    def valid(hosts, port, name, secret=secret, uri=None):
        u = uri or encode_pairing_uri(mac_fp, secret, hosts, port, name)
        fields = parse_pairing_uri(u)
        assert fields["hosts"] == hosts and fields["mac_name"] == name
        return {"uri": u, "fields": fields}

    valid_vecs = [
        valid(["192.168.1.20"], 49152, "Office Mac"),
        valid(["192.168.1.20", "10.0.0.7"], 51234, "Ada’s MacBook Pro \U0001F34E"),
        valid(["macbook.local", "192.168.1.20"], 1, ""),
    ]
    base = encode_pairing_uri(mac_fp, secret, ["192.168.1.20"], 49152, "Office Mac")
    extra = valid(["192.168.1.20"], 49152, "Office Mac", uri=base + "&future=abc%20def&x=1")
    valid_vecs.append(extra)
    # NUL is valid UTF-8, so an escaped %00 inside a name is accepted.
    valid_vecs.append(valid(["192.168.1.20"], 49152, "a\x00b"))

    fp_b64, s_b64 = b64url(mac_fp), b64url(secret)
    short = b64url(mac_fp[:31])
    alpha = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    assert len(fp_b64) % 4 == 3  # 32 bytes -> last char carries 2 unused bits
    noncanon = alpha[alpha.index(fp_b64[-1]) | 1]  # same bytes, non-zero trailing bit
    assert noncanon != fp_b64[-1]
    long_ = b64url(secret + b"\x00")
    q = f"fp={fp_b64}&s={s_b64}&h=192.168.1.20&p=49152&n=Mac"
    invalid_vecs = [
        ("version_2", f"anmirror://pair?v=2&{q}", "unsupportedVersion"),
        ("version_0", f"anmirror://pair?v=0&{q}", "unsupportedVersion"),
        ("version_2_other_fields_bad", "anmirror://pair?v=2&fp=AAAA&s=BBBB&h=x&p=1",
         "unsupportedVersion"),
        ("version_missing", f"anmirror://pair?{q}", "malformed"),
        ("version_not_numeric", f"anmirror://pair?v=one&{q}", "malformed"),
        ("fp_31_bytes", f"anmirror://pair?v=1&fp={short}&s={s_b64}&h=192.168.1.20&p=49152", "malformed"),
        ("secret_33_bytes", f"anmirror://pair?v=1&fp={fp_b64}&s={long_}&h=192.168.1.20&p=49152", "malformed"),
        ("fp_missing", f"anmirror://pair?v=1&s={s_b64}&h=192.168.1.20&p=49152", "malformed"),
        ("secret_missing", f"anmirror://pair?v=1&fp={fp_b64}&h=192.168.1.20&p=49152", "malformed"),
        ("fp_padded_base64", f"anmirror://pair?v=1&fp={fp_b64}=&s={s_b64}&h=192.168.1.20&p=49152", "malformed"),
        ("fp_standard_alphabet", "anmirror://pair?v=1&fp=" + base64.b64encode(b"\xfb" * 32).decode().rstrip("=")
         + f"&s={s_b64}&h=192.168.1.20&p=49152", "malformed"),
        ("host_missing", f"anmirror://pair?v=1&fp={fp_b64}&s={s_b64}&p=49152", "malformed"),
        ("host_empty_entry", f"anmirror://pair?v=1&fp={fp_b64}&s={s_b64}&h=192.168.1.20,&p=49152", "malformed"),
        ("port_missing", f"anmirror://pair?v=1&fp={fp_b64}&s={s_b64}&h=192.168.1.20", "malformed"),
        ("port_zero", f"anmirror://pair?v=1&fp={fp_b64}&s={s_b64}&h=192.168.1.20&p=0", "malformed"),
        ("port_too_large", f"anmirror://pair?v=1&fp={fp_b64}&s={s_b64}&h=192.168.1.20&p=65536", "malformed"),
        ("name_bad_utf8", f"anmirror://pair?v=1&fp={fp_b64}&s={s_b64}&h=192.168.1.20&p=49152&n=%FF", "malformed"),
        ("name_nul_then_bad_utf8", f"anmirror://pair?v=1&fp={fp_b64}&s={s_b64}&h=192.168.1.20&p=49152&n=%00%FF", "malformed"),
        ("name_plus_after_percent", f"anmirror://pair?v=1&fp={fp_b64}&s={s_b64}&h=192.168.1.20&p=49152&n=%+1", "malformed"),
        ("name_space_after_percent", f"anmirror://pair?v=1&fp={fp_b64}&s={s_b64}&h=192.168.1.20&p=49152&n=% 1", "malformed"),
        ("name_non_hex_escape", f"anmirror://pair?v=1&fp={fp_b64}&s={s_b64}&h=192.168.1.20&p=49152&n=%G1", "malformed"),
        ("version_leading_zero", f"anmirror://pair?v=01&{q}", "malformed"),
        ("port_leading_zero", f"anmirror://pair?v=1&fp={fp_b64}&s={s_b64}&h=192.168.1.20&p=049152", "malformed"),
        ("port_non_ascii_digit", f"anmirror://pair?v=1&fp={fp_b64}&s={s_b64}&h=192.168.1.20&p=\u00b2", "malformed"),
        ("version_non_ascii_digit", f"anmirror://pair?v=\u00b2&{q}", "malformed"),
        ("fp_non_canonical_trailing_bits", f"anmirror://pair?v=1&fp={fp_b64[:-1]}{noncanon}&s={s_b64}&h=192.168.1.20&p=49152", "malformed"),
        ("name_truncated_escape", f"anmirror://pair?v=1&fp={fp_b64}&s={s_b64}&h=192.168.1.20&p=49152&n=%4", "malformed"),
        ("duplicate_param", f"anmirror://pair?v=1&v=1&{q}", "malformed"),
        ("wrong_scheme", f"https://pair?v=1&{q}", "malformed"),
        ("wrong_host", f"anmirror://other?v=1&{q}", "malformed"),
    ]
    out_invalid = []
    for name, u, err in invalid_vecs:
        try:
            parse_pairing_uri(u)
        except UriError as e:
            assert str(e) == err, (name, str(e))
        else:
            raise AssertionError(name)
        out_invalid.append({"name": name, "uri": u, "error": err})
    return {"valid": valid_vecs, "invalid": out_invalid}


# ---------------------------------------------------------------- file names (SPEC section 16)
NAME_MAX_BYTES = 255
EXT_MAX_BYTES = 16
BIDI_CONTROLS = set(range(0x202A, 0x202F)) | set(range(0x2066, 0x206A))


def _split_ext(name: str) -> tuple:
    """(stem, ext) where ext includes the dot and is at most EXT_MAX_BYTES; else (name, '')."""
    i = name.rfind(".")
    if i > 0 and len(name[i:].encode("utf-8")) <= EXT_MAX_BYTES:
        return name[:i], name[i:]
    return name, ""


def _cut(text: str, max_bytes: int) -> str:
    """Longest prefix of text, cut at a Unicode scalar boundary, of at most max_bytes UTF-8 bytes."""
    out, used = [], 0
    for ch in text:
        n = len(ch.encode("utf-8"))
        if used + n > max_bytes:
            break
        out.append(ch)
        used += n
    return "".join(out)


def sanitize_name(raw: str) -> str:
    name = re.split(r"[/\\]", raw)[-1]
    name = "".join(c for c in name if ord(c) > 0x1F and ord(c) != 0x7F and ord(c) not in BIDI_CONTROLS)
    name = name.lstrip(". ").rstrip(" ")
    if not name:
        return "file"
    if len(name.encode("utf-8")) > NAME_MAX_BYTES:
        stem, ext = _split_ext(name)
        name = _cut(stem, NAME_MAX_BYTES - len(ext.encode("utf-8"))).rstrip(". ") + ext
    return name


def name_key(name: str) -> str:
    """Collision key: lowercase(NFC(name)), locale-independent (SPEC section 16 step 6)."""
    return unicodedata.normalize("NFC", name).lower()


def unique_name(name: str, taken: set) -> str:
    """name if free, else 'stem (n).ext' with the smallest free n >= 1, within NAME_MAX_BYTES.
    Names collide when their name_key is equal."""
    keys = {name_key(t) for t in taken}
    if name_key(name) not in keys:
        return name
    stem, ext = _split_ext(name)
    n = 1
    while True:
        suffix = f" ({n})" + ext
        cand = _cut(stem, NAME_MAX_BYTES - len(suffix.encode("utf-8"))).rstrip(". ") + f" ({n})" + ext
        if name_key(cand) not in keys:
            return cand
        n += 1


def build_filenames() -> dict:
    sanitize_cases = [
        "../../etc/passwd", "a/b/c.txt", "..\\..\\x.exe", ".hidden", "....", "",
        "tab\tname\u0007.txt", "\u202Egnp.exe", "日本語 \U0001F4F7.jpg", "name.txt  ",
        "a" * 296 + ".jpg", "é" * 150 + ".pdf",
        "/", "dir/", "  . hidden.txt", "del\u007f.txt", "\u2066x\u2069.txt",
        "report.tar.gz", "noext", "a" * 300, "b" * 10 + "." + "c" * 20,
        "a" * 254 + " x", "a" * 300 + "." + "c" * 20, "a" * 253 + "..x",
    ]
    sanitize = []
    for raw in sanitize_cases:
        out = sanitize_name(raw)
        assert out == sanitize_name(out) and len(out.encode("utf-8")) <= NAME_MAX_BYTES, raw
        assert out == out.lstrip(". ").rstrip(" "), raw
        sanitize.append({"in": raw, "out": out})
    long_name = "a" * 251 + ".jpg"
    unique_cases = [
        ("photo.jpg", [], None),
        ("photo.jpg", ["photo.jpg"], None),
        ("photo.jpg", ["photo.jpg", "photo (1).jpg"], None),
        ("photo.jpg", ["photo.jpg", "photo (2).jpg"], None),
        ("noext", ["noext"], None),
        (long_name, [long_name], None),
        ("é" * 125 + ".pdf", ["é" * 125 + ".pdf"], None),
        ("Photo.JPG", ["photo.jpg"], None),
        ("É.pdf", ["é.pdf"], None),
        ("e\u0301.txt", ["\u00e9.txt"], None),  # NFD name, NFC taken
        ("\u00e9.txt", ["e\u0301.txt"], None),  # NFC name, NFD taken
        ("Photo.jpg", ["photo.jpg", "photo (1).jpg"], None),
        ("a" * 250 + " .jpg", ["a" * 250 + " .jpg"], None),
    ]
    unique = []
    for name, taken, _ in unique_cases:
        out = unique_name(name, set(taken))
        assert name_key(out) not in {name_key(t) for t in taken}, name
        assert len(out.encode("utf-8")) <= NAME_MAX_BYTES, name
        unique.append({"name": name, "taken": taken, "out": out})
    assert unique[2]["out"] == "photo (2).jpg" and unique[5]["out"] == "a" * 247 + " (1).jpg"
    assert unique[7]["out"] == "Photo (1).JPG" and unique[8]["out"] == "É (1).pdf"
    assert unique[11]["out"] == "Photo (2).jpg"
    return {"notes": "sanitize_name then unique_name, see SPEC section 16; sizes are UTF-8 bytes",
            "sanitize": sanitize, "unique": unique}


# ---------------------------------------------------------------- scrcpy v5.0.1 streams (section 24)
# A reference encoder for the helper's three sockets, read from upstream scrcpy at tag v5.0.1
# (app/src/control_msg.c, app/src/device_msg.c, server/.../control/*). Everything is big endian.
#
# VERIFIED (Task 2 of 0.5): every entry and the limits are checked against the vendored v5.0.1
# server by android/helper/src/test/java/com/genymobile/scrcpy/anmirror/ScrcpyFixturesTest.java:
# the real ControlMessageReader parses each control entry (and consumes exactly its bytes), the real
# DeviceMessageWriter writes each device entry, and the stream entries match the server's codec IDs,
# packet flags and 64-byte device-name field. No entry needed a correction. "source" still says where
# the layout first came from: "spike" = the 0.1 spike used it against the real v5.0.1 server;
# "memory" = written from memory before the check; "vendored" = written from the vendored source.
# Scroll: upstream's C client (control_msg.c, sc_float_to_i16fp) converts float to int, so the
# wire value is truncated toward zero, not rounded or floored: 0.1 -> 204 and -0.1 -> -204.
SC_INJECT_KEYCODE, SC_INJECT_TEXT, SC_INJECT_TOUCH, SC_INJECT_SCROLL, SC_BACK_OR_SCREEN_ON = 0, 1, 2, 3, 4
SC_GET_CLIPBOARD, SC_SET_CLIPBOARD, SC_SET_DISPLAY_POWER, SC_ROTATE_DEVICE = 8, 9, 10, 11
SC_RESET_VIDEO = 17
SC_DEVICE_CLIPBOARD, SC_DEVICE_ACK_CLIPBOARD, SC_DEVICE_UHID_OUTPUT = 0, 1, 2
SC_INJECT_TEXT_MAX = 300
SC_CLIPBOARD_TEXT_MAX = 262_130          # 1 << 18 (the control message limit) minus 14
SC_DEVICE_CLIPBOARD_TEXT_MAX = 262_139   # helper -> Mac CLIPBOARD: 1 << 18 minus 5 (DeviceMessageWriter)
SC_DEVICE_NAME_BYTES = 64
SC_POINTER_GENERIC_FINGER = -2
SC_CODEC_IDS = {"h264": 0x68323634, "h265": 0x68323635, "opus": 0x6F707573, "aac": 0x00616163}
SC_AUDIO_DISABLED, SC_AUDIO_ERROR = 0, 1
SC_FLAG_SESSION = 1 << 63
SC_FLAG_CONFIG = 1 << 62
SC_FLAG_KEY_FRAME = 1 << 61
SC_META_CTRL = 0x1000 | 0x2000           # META_CTRL_ON | META_CTRL_LEFT_ON
SC_TEXT_300 = ("The quick brown fox jumps over the lazy dog. " * 7)[:SC_INJECT_TEXT_MAX]


def sc_string(text: str, limit: int) -> bytes:
    raw = text.encode("utf-8")
    assert len(raw) <= limit, (len(raw), limit)
    return struct.pack(">I", len(raw)) + raw


def sc_scroll_i16(v: float) -> int:
    """scrcpy's sc_float_to_i16fp(clamp(v / 16, -1, 1)): times 2^15, truncated toward zero, 1.0 -> 32767."""
    n = max(-1.0, min(1.0, v / 16))
    return max(-32768, min(32767, int(n * 32768)))


def sc_control(f: dict) -> bytes:
    t = f["type"]
    head = bytes([t])
    if t == SC_INJECT_KEYCODE:
        return head + struct.pack(">BIII", f["action"], f["keycode"], f["repeat"], f["meta_state"])
    if t == SC_INJECT_TEXT:
        return head + sc_string(f["text"], SC_INJECT_TEXT_MAX)
    if t == SC_INJECT_TOUCH:
        return head + struct.pack(">BqiiHHHII", f["action"], f["pointer_id"], f["x"], f["y"], f["width"],
                                  f["height"], f["pressure"], f["action_button"], f["buttons"])
    if t == SC_INJECT_SCROLL:
        assert f["hscroll_i16"] == sc_scroll_i16(f["hscroll"]) and f["vscroll_i16"] == sc_scroll_i16(f["vscroll"])
        return head + struct.pack(">iiHHhhI", f["x"], f["y"], f["width"], f["height"],
                                  f["hscroll_i16"], f["vscroll_i16"], f["buttons"])
    if t == SC_BACK_OR_SCREEN_ON:
        return head + bytes([f["action"]])
    if t == SC_GET_CLIPBOARD:
        return head + bytes([f["copy_key"]])
    if t == SC_SET_CLIPBOARD:
        return head + struct.pack(">QB", f["sequence"], int(f["paste"])) + sc_string(f["text"], SC_CLIPBOARD_TEXT_MAX)
    if t == SC_SET_DISPLAY_POWER:
        return head + bytes([int(f["on"])])
    if t in (SC_ROTATE_DEVICE, SC_RESET_VIDEO):
        return head
    raise AssertionError(f)


def sc_device(f: dict) -> bytes:
    t = f["type"]
    if t == SC_DEVICE_CLIPBOARD:
        return bytes([t]) + sc_string(f["text"], SC_DEVICE_CLIPBOARD_TEXT_MAX)
    if t == SC_DEVICE_ACK_CLIPBOARD:
        return bytes([t]) + struct.pack(">Q", f["sequence"])
    if t == SC_DEVICE_UHID_OUTPUT:
        data = bytes.fromhex(f["data_hex"])
        return bytes([t]) + struct.pack(">HH", f["id"], len(data)) + data
    raise AssertionError(f)


def sc_video_prelude(device_name: str, codec: str, dummy_byte: bool = True) -> bytes:
    """The video socket's start: [dummy 0x00] + 64-byte NUL-padded UTF-8 name + codec ID."""
    name = device_name.encode("utf-8")
    assert len(name) < SC_DEVICE_NAME_BYTES
    return (b"\x00" if dummy_byte else b"") + name.ljust(SC_DEVICE_NAME_BYTES, b"\x00") \
        + struct.pack(">I", SC_CODEC_IDS[codec])


def sc_session_packet(width: int, height: int) -> bytes:
    return struct.pack(">QI", SC_FLAG_SESSION | width, height)


def sc_media_header(config: bool, key_frame: bool, pts_us: int, size: int) -> bytes:
    assert 0 <= pts_us < SC_FLAG_KEY_FRAME
    flags = (SC_FLAG_CONFIG if config else 0) | (SC_FLAG_KEY_FRAME if key_frame else 0)
    return struct.pack(">QI", flags | pts_us, size)


def build_scrcpy() -> dict:
    touch = {"type": SC_INJECT_TOUCH, "pointer_id": SC_POINTER_GENERIC_FINGER, "width": 1080,
             "height": 2400, "action_button": 0, "buttons": 0}
    scroll = {"type": SC_INJECT_SCROLL, "x": 540, "y": 1200, "width": 1080, "height": 2400, "buttons": 0}
    control = [
        ("inject_keycode_home_down", "memory", {"type": SC_INJECT_KEYCODE, "action": 0, "keycode": 3,
                                                "repeat": 0, "meta_state": 0}),
        ("inject_keycode_home_up", "memory", {"type": SC_INJECT_KEYCODE, "action": 1, "keycode": 3,
                                              "repeat": 0, "meta_state": 0}),
        ("inject_keycode_ctrl_a_down", "memory", {"type": SC_INJECT_KEYCODE, "action": 0, "keycode": 29,
                                                  "repeat": 0, "meta_state": SC_META_CTRL}),
        ("inject_text_ascii", "memory", {"type": SC_INJECT_TEXT, "text": "hello"}),
        ("inject_text_300_bytes", "memory", {"type": SC_INJECT_TEXT, "text": SC_TEXT_300}),
        ("inject_touch_down", "spike", {**touch, "action": 0, "x": 540, "y": 1200, "pressure": 0xFFFF}),
        ("inject_touch_move", "spike", {**touch, "action": 2, "x": 560, "y": 1300, "pressure": 0xFFFF}),
        ("inject_touch_up", "spike", {**touch, "action": 1, "x": 560, "y": 1300, "pressure": 0}),
        # v / 16 x 32768 is a whole number for these, so truncating and rounding agree
        ("inject_scroll_down_one", "memory", {**scroll, "hscroll": 0.0, "vscroll": -1.0,
                                              "hscroll_i16": 0, "vscroll_i16": sc_scroll_i16(-1.0)}),
        ("inject_scroll_clamped", "memory", {**scroll, "hscroll": 32.0, "vscroll": -16.0,
                                             "hscroll_i16": sc_scroll_i16(32.0), "vscroll_i16": sc_scroll_i16(-16.0)}),
        # not whole: v / 16 x 32768 = -204.8 and 204.8, truncated toward zero (rounding would give -205 / 205)
        ("inject_scroll_fractional", "vendored", {**scroll, "hscroll": -0.1, "vscroll": 0.1,
                                                  "hscroll_i16": sc_scroll_i16(-0.1), "vscroll_i16": sc_scroll_i16(0.1)}),
        ("back_or_screen_on_down", "memory", {"type": SC_BACK_OR_SCREEN_ON, "action": 0}),
        ("back_or_screen_on_up", "memory", {"type": SC_BACK_OR_SCREEN_ON, "action": 1}),
        ("get_clipboard_copy", "memory", {"type": SC_GET_CLIPBOARD, "copy_key": 1}),
        # sequence is above 2**32 on purpose (u64)
        ("set_clipboard_ascii", "memory", {"type": SC_SET_CLIPBOARD, "sequence": 4_294_967_298, "paste": False,
                                           "text": "plain text"}),
        ("set_clipboard_paste_emoji", "memory", {"type": SC_SET_CLIPBOARD, "sequence": 7, "paste": True,
                                                 "text": "Hi \U0001F44B\U0001F3FD from the Mac \U0001F1EE\U0001F1F3"}),
        ("set_display_power_off", "memory", {"type": SC_SET_DISPLAY_POWER, "on": False}),
        ("set_display_power_on", "memory", {"type": SC_SET_DISPLAY_POWER, "on": True}),
        ("rotate_device", "memory", {"type": SC_ROTATE_DEVICE}),
        ("reset_video", "memory", {"type": SC_RESET_VIDEO}),
    ]
    device = [
        ("clipboard_ascii", "memory", {"type": SC_DEVICE_CLIPBOARD, "text": "copied on the phone"}),
        ("clipboard_emoji", "memory", {"type": SC_DEVICE_CLIPBOARD, "text": "\u00e9t\u00e9 \U0001F4CB\u2728"}),
        ("ack_clipboard", "memory", {"type": SC_DEVICE_ACK_CLIPBOARD, "sequence": 4_294_967_298}),
        ("uhid_output", "memory", {"type": SC_DEVICE_UHID_OUTPUT, "id": 1, "data_hex": "0102ff"}),
    ]
    stream = [
        ("video_prelude_h264", "spike", {"dummy_byte": True, "device_name": "phone-sim", "codec": "h264",
                                         "codec_id": SC_CODEC_IDS["h264"]},
         lambda f: sc_video_prelude(f["device_name"], f["codec"])),
        ("video_prelude_h265_utf8_name", "memory", {"dummy_byte": True, "device_name": "Ana\u2019s phone \U0001F4F1",
                                                    "codec": "h265", "codec_id": SC_CODEC_IDS["h265"]},
         lambda f: sc_video_prelude(f["device_name"], f["codec"])),
        ("session_packet", "spike", {"session": True, "width": 1080, "height": 2400},
         lambda f: sc_session_packet(f["width"], f["height"])),
        ("config_packet_header", "spike", {"config": True, "key_frame": False, "pts_us": 0, "size": 27},
         lambda f: sc_media_header(f["config"], f["key_frame"], f["pts_us"], f["size"])),
        ("key_frame_packet_header", "spike", {"config": False, "key_frame": True, "pts_us": 16_667, "size": 1500},
         lambda f: sc_media_header(f["config"], f["key_frame"], f["pts_us"], f["size"])),
        # pts is above 2**32 on purpose (61-bit field)
        ("plain_packet_header", "spike", {"config": False, "key_frame": False, "pts_us": 5_000_000_000, "size": 300},
         lambda f: sc_media_header(f["config"], f["key_frame"], f["pts_us"], f["size"])),
        ("audio_prelude_opus", "memory", {"codec": "opus", "codec_id": SC_CODEC_IDS["opus"]},
         lambda f: struct.pack(">I", f["codec_id"])),
        ("audio_prelude_aac", "memory", {"codec": "aac", "codec_id": SC_CODEC_IDS["aac"]},
         lambda f: struct.pack(">I", f["codec_id"])),
        ("audio_prelude_disabled", "memory", {"codec": "disabled", "codec_id": SC_AUDIO_DISABLED},
         lambda f: struct.pack(">I", f["codec_id"])),
        ("audio_prelude_error", "memory", {"codec": "error", "codec_id": SC_AUDIO_ERROR},
         lambda f: struct.pack(">I", f["codec_id"])),
    ]

    def entry(name, source, fields, raw):
        return {"name": name, "verified": True, "source": source, "fields": fields, "hex": raw.hex()}

    return {
        "upstream": "scrcpy v5.0.1: app/src/control_msg.c, app/src/device_msg.c, "
                    "server/src/main/java/com/genymobile/scrcpy/control/*",
        "notes": [
            "All integers are big endian. Each control and device entry starts with its type byte.",
            "verified = true: checked against the vendored scrcpy-server v5.0.1 by "
            "android/helper/src/test/java/com/genymobile/scrcpy/anmirror/ScrcpyFixturesTest.java. "
            "source says where the layout first came from: spike = the 0.1 spike used it against the real "
            "v5.0.1 server; memory = written from memory before the check; vendored = from the vendored source.",
            "Touch: pointer_id -2 is the generic finger; width and height are the current video size; "
            "pressure is u16 fixed point (65535 = 1.0).",
            "Scroll: hscroll and vscroll are the encoder's input; on the wire they are "
            "i16 = clamp(v / 16, -1, 1) x 32768, truncated toward zero (not rounded), clamped to -32768..32767. "
            "The server reads i16 / 32768 x 16 (32767 = 16.0), so 0.1 arrives as 204 / 2048 = 0.099609375.",
            "Touch pressure is read as u16 / 65536 (65535 = 1.0); the server's ControlMessage holds both as floats.",
            "Text and clipboard strings: u32 byte length, then UTF-8.",
            "Video stream entries include the dummy byte when dummy_byte is true. A media packet header is "
            "u64 (bit 62 config, bit 61 key frame, low 61 bits PTS in microseconds) and u32 payload size; "
            "a session packet sets bit 63 and carries the width and height.",
            "Session packets: bit 0 of the first u32 (bit 32 of the u64) is the server's client-resize flag, set only "
            "with new_display, which we never pass. A parser tells session packets apart by bit 63 alone.",
            "Device CLIPBOARD text from the helper is at most device_clipboard_text_max_bytes; the server truncates "
            "longer clips at a UTF-8 boundary (DeviceMessageWriter).",
        ],
        "limits": {"verified": True, "inject_text_max_bytes": SC_INJECT_TEXT_MAX,
                   "set_clipboard_text_max_bytes": SC_CLIPBOARD_TEXT_MAX,
                   "device_clipboard_text_max_bytes": SC_DEVICE_CLIPBOARD_TEXT_MAX,
                   "device_name_bytes": SC_DEVICE_NAME_BYTES},
        "control": [entry(n, src, f, sc_control(f)) for n, src, f in control],
        "device": [entry(n, src, f, sc_device(f)) for n, src, f in device],
        "stream": [entry(n, src, f, enc(f)) for n, src, f, enc in stream],
    }


def build_all() -> dict:
    ids = load_identities()
    return {"framing.json": build_framing(),
            "crypto.json": build_crypto(ids),
            "pairing_uri.json": build_pairing_uri(ids),
            "filenames.json": build_filenames(),
            "scrcpy.json": build_scrcpy()}


def main() -> int:
    check = "--check" in sys.argv[1:]
    bad = False
    for fname, data in build_all().items():
        text = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
        # keep invisible bidi controls / DEL reviewable: write them as JSON escapes
        text = re.sub("[\u202a-\u202e\u2066-\u2069\u007f]", lambda m: "\\u%04x" % ord(m.group()), text)
        path = VECTORS / fname
        if check:
            if not path.exists() or path.read_text(encoding="utf-8") != text:
                print(f"DIFF: {path}", file=sys.stderr)
                bad = True
        else:
            VECTORS.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
            print(f"wrote {path}")
    if check:
        print("vectors differ" if bad else "vectors up to date")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
