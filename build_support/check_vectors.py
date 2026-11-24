#!/usr/bin/env python3
"""Verify MEX1/MEJ1 fixtures independently of the SDK under test."""
import hashlib
import json
from pathlib import Path
import struct

fixtures = Path(__file__).resolve().parents[1] / "core/med_core/test/fixtures/wire"
v = json.loads((fixtures / "reference_vectors.json").read_bytes())

def sha(data):
    return hashlib.sha256(data).hexdigest()

def canonical(obj):
    return json.dumps(obj, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()

m = v["mex1"]
payload = bytes.fromhex(m["payload_hex"])
header = struct.pack(">4sBBHIIIQQIII", b"MEX1", 1, 0, 48, m["stream_number"],
                     m["source_epoch"], 0xffffffff, int(m["sequence"]),
                     int(m["first_sample"]), m["sample_count"], len(payload), 0)
wire = header + payload
assert len(header) == 48 and (fixtures / m["file"]).read_bytes() == wire
assert sha(wire) == m["sha256"] and sha(payload) == m["payload_sha256"]
meta = canonical(v["mej1"]["input"])
assert (fixtures / v["mej1"]["file"]).read_bytes() == meta and sha(meta) == v["mej1"]["sha256"]
f = v["semantic_fingerprint"]
assert f["fields"]["payload_sha256"] == sha(payload)
assert sha(b"medex.frame.v1\0" + canonical(f["fields"])) == f["sha256"]
print("Verified independently generated MEX1, MEJ1 and semantic fingerprint bytes")
