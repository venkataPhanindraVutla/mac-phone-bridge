#!/usr/bin/env python3
"""Reference implementation and vector generator for the Android Mirroring protocol.

Run as:  python3 -I protocol/tools/make_vectors.py [--check]

Writes protocol/vectors/{framing,crypto,pairing_uri}.json. With --check it regenerates
in memory and exits 1 if any file on disk differs. Output is fully deterministic: all
"random" inputs are derived from fixed labels with SHA-256. Standard library only
(the test certificates are read from the committed .p12 files via the `openssl` CLI).
"""
import base64
import hashlib
import hmac
import json
import subprocess
import sys
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

CHANNELS = {"SYSTEM": 1, "PAIRING": 2, "STATUS": 3, "FIND": 4}


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
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def pct_encode(s: str) -> str:
    return quote(s, safe="-._~")  # RFC 3986 unreserved kept, UTF-8 bytes otherwise


def pct_decode(s: str) -> str:
    out = bytearray()
    i = 0
    b = s.encode("ascii", "strict")
    while i < len(b):
        if b[i] == 0x25:
            try:
                out.append(int(b[i + 1:i + 3].decode(), 16))
                if len(b[i + 1:i + 3]) != 2:
                    raise ValueError
            except ValueError:
                raise UriError("malformed")
            i += 3
        else:
            out.append(b[i])
            i += 1
    try:
        return out.decode("utf-8")
    except UnicodeDecodeError:
        raise UriError("malformed")


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
    if params.get("v") is None or not params["v"].isdigit():
        raise UriError("malformed")
    if int(params["v"]) != 1:
        raise UriError("unsupportedVersion")
    try:
        fp = b64url_decode(params["fp"])
        secret = b64url_decode(params["s"])
        if len(fp) != 32 or len(secret) != 32:
            raise UriError("malformed")
        hosts = [h for h in params["h"].split(",")]
        if not hosts or any(h == "" for h in hosts):
            raise UriError("malformed")
        if not params["p"].isdigit() or not (1 <= int(params["p"]) <= 65535):
            raise UriError("malformed")
        name = pct_decode(params.get("n", ""))
    except KeyError:
        raise UriError("malformed")
    return {"version": 1, "fp_hex": fp.hex(), "secret_hex": secret.hex(),
            "hosts": hosts, "port": int(params["p"]), "mac_name": name}


# ---------------------------------------------------------------- test identities
def load_identities() -> list:
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
            sys.exit(f"cannot read {p12}")
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
        ("find_ring", CHANNELS["FIND"], 6, 0, "find.ring", b""),
        ("find_state_reply", CHANNELS["FIND"], 7, 6, "find.state",
         f_varint(1, 1) + f_varint(2, 1)),
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
    return {"notes": "code is a zero-padded 6-digit string",
            "fingerprints": fingerprints, "proofs": proofs, "codes": codes, "rotating_ids": rids}


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

    fp_b64, s_b64 = b64url(mac_fp), b64url(secret)
    short = b64url(mac_fp[:31])
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


def build_all() -> dict:
    ids = load_identities()
    return {"framing.json": build_framing(),
            "crypto.json": build_crypto(ids),
            "pairing_uri.json": build_pairing_uri(ids)}


def main() -> int:
    check = "--check" in sys.argv[1:]
    bad = False
    for fname, data in build_all().items():
        text = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
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
