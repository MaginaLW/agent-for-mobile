"""Count method entry records in an uncompressed ART v2 wall-clock trace."""
import argparse
import collections
import hashlib
import json
import struct
from pathlib import Path


SELECTED = {
    "android.view.View": (
        "onFocusChanged", "onWindowFocusChanged", "notifyEnterOrExitForAutoFillIfNeeded"),
    "android.view.autofill.AutofillManager": (
        "notifyViewEntered", "notifyViewExited", "notifyViewEnteredForFillDialog",
        "shouldIgnoreViewEnteredLocked"),
    "dev.magina.autofilltarget.TargetActivity$Editor": ("onCreateInputConnection",),
    "dev.magina.autofilltarget.TargetActivity": ("receiveProbe", "onWindowFocusChanged"),
}


def summarize(trace):
    data = trace.read_bytes()
    header, footer, binary = data.partition(b"*end\n")
    if not footer or not header.startswith(b"*version\n2\n"):
        raise ValueError("expected non-streaming ART trace version 2")
    lines = header.decode("utf-8").splitlines()
    meta = dict(s.split("=", 1) for s in lines[2:lines.index("*threads")] if "=" in s)
    if meta["clock"] != "wall" or meta["data-file-overflow"] != "false":
        raise ValueError("clock or overflow invalid for comparison")
    magic, version, offset = struct.unpack_from("<4sHH", binary)
    if magic != b"SLOW" or version != 2 or not 16 <= offset <= len(binary):
        raise ValueError("invalid ART binary header")
    rows = {}
    for line in lines[lines.index("*methods") + 1:]:
        method, owner, name, *_ = line.split("\t")
        rows[int(method, 16)] = (owner, name)
    counts = collections.Counter()
    total = 0
    for _, tagged, _ in struct.iter_unpack("<HII", memoryview(binary)[offset:]):
        key = rows[tagged & ~3]
        if tagged & 3 == 0:
            counts[key] += 1
        total += 1
    if total != int(meta["num-method-calls"]):
        raise ValueError("record count differs from ART header")
    return dict(trace=trace.name, sha256=hashlib.sha256(data).hexdigest(), overflow=False,
                records=total, elapsed_us=int(meta["elapsed-time-usec"]),
                entries={owner: {name: counts[owner, name] for name in methods}
                         for owner, methods in SELECTED.items()})


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", type=Path, nargs="+")
    print(json.dumps([summarize(f) for f in parser.parse_args().trace], indent=2))
