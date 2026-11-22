"""比较只读请求回调与独立无障碍尺寸。默认离线，不访问设备。"""

import argparse
import copy
import hashlib
import json
import math
from pathlib import Path


HERE = Path(__file__).resolve().parent
STAGES = ("west", "east", "scaled", "overlap")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def project(matrix, size):
    """本实验的正比例平移/缩放，尺寸必须为正的显式 LayoutParams 像素。"""
    if size is None or len(size) != 2 or min(size) <= 0 or len(matrix) != 9:
        return None
    a, b, x, c, d, y, p, q, w = matrix
    if not all(math.isfinite(v) for v in matrix) or (b, c, p, q, w) != (0, 0, 0, 0, 1) or min(a, d) <= 0:
        return None
    return [x, y, x + a * size[0], y + d * size[1]]


def candidates(matrix, windows):
    matched, unknown = [], []
    for window in windows:
        number = window["window"]
        if window["scope"] == "other":
            continue
        if window["scope"] == "unknown" or not window["editors"] or window["display"] != 0:
            unknown.append(number)
            continue
        for editor in window["editors"]:
            proposed = project(matrix, editor["layout_size"])
            if proposed is None:
                unknown.append(number)
            elif proposed == editor["screen_rect"]:
                matched.append(number)
    return {"matching_nodes_in_windows": matched, "unresolved_windows": unknown}


def result(matrix, windows):
    raw = candidates(matrix, windows)
    matches = raw["matching_nodes_in_windows"]
    if raw["unresolved_windows"]:
        decision = "incomplete"
    elif len(matches) == 1:
        decision = "unique_within_supplied_nodes"
    elif matches:
        decision = "ambiguous"
    else:
        decision = "different_geometry"
    return {**raw, "decision":decision, "compatible_window":matches[0] if decision == "unique_within_supplied_nodes" else None}


def model_check():
    def window(number, size, bounds):
        return {"scope": "target", "window": number, "display": 0,
                "editors": [{"layout_size": size, "screen_rect": bounds}]}
    identity = [1, 0, 1000, 0, 1, 40, 0, 0, 1]
    scale = [2, 0, 1000, 0, 1, 40, 0, 0, 1]
    bounds = [1000, 40, 1200, 110]
    plain, small = window(1, [200, 70], bounds), window(2, [100, 70], bounds)
    same = window(3, [200, 70], bounds)
    left_matrix = [1, 0, 40, 0, 1, 40, 0, 0, 1]
    left = window(4, [200,70], [40,40,240,110])
    distinct = [left, plain]
    require(result(left_matrix, distinct)["compatible_window"] == 4 and
            result(identity, distinct)["compatible_window"] == 1, "spatial control")
    require(candidates(identity, [plain, small])["matching_nodes_in_windows"] == [1], "plain scale model")
    require(candidates(scale, [plain, small])["matching_nodes_in_windows"] == [2], "double scale model")
    require(candidates(identity, [plain, same])["matching_nodes_in_windows"] == [1, 3], "collision model")
    require(candidates(identity, [plain, window(4, [-2, 70], bounds), {"scope":"unknown","window":5}])
            == {"matching_nodes_in_windows":[1],"unresolved_windows":[4,5]}, "incomplete input model")
    return {"separate_positions":[result(m,distinct) for m in (left_matrix,identity)],
            "same_bounds_different_layout":[result(m,[plain,small]) for m in (identity,scale)],
            "identical_layout":[result(identity,[plain,same]), result(identity,[same,plain])],
            "missing_size_or_unknown_root":result(identity,[plain,window(4,[-2,70],bounds),{"scope":"unknown","window":5}])}


def closed_evidence():
    runs = read(HERE / "setup-attempt.json")
    for key, error in (("first","no_target_west.json"), ("second","no_target_east.json")):
        row = runs[key]
        require(row["phase"] == "closed" and row["status"] == "failed" and row["error"] == error
                and row["accepted_request_pairs"] == 0 and len(row["restored"]) == 10
                and all(row["restored"].values()) and all(row["cleanup"].values()), key + ": closeout")
    west = runs["second"]["west_target_oracle"]
    require(west["connections"] > 0 and west["requests"] == 0 and west["callbacks"] == []
            and len(west["matrix"]) == 9 and runs["second"]["observer_exception"] ==
            "UnsupportedOperationException: ArrayMap is immutable", "second stage failure evidence")
    return {"first_stop":runs["first"]["error"],"second_stop":runs["second"]["error"],
            "west_target_window":west["window"],"west_target_bounds":west["bounds"],
            "accepted_live_request_pairs":0,"matrix_and_layout_device_comparison":"NOT_OBSERVED",
            "independently_deliverable_source_window":None}


def check_java(digests):
    for path in sorted(HERE.glob("*/*.java")):
        digest = digests[path.relative_to(HERE).as_posix()]
        lf = path.read_bytes().replace(b"\r\n", b"\n")
        # Android 构建指纹保留原值；复核允许 git 的 CRLF 与 LF 检出差异。
        require(digest in {hashlib.sha256(value).hexdigest() for value in (lf, lf.replace(b"\n", b"\r\n"))},
                "source changed: " + path.name)


def prepared():
    item = read(HERE / "prepared.json")
    check_java(item["input_sha256"])
    require(item["compile_sdk"] == 35 and item["runtime_target_api"] == 36 and
            not item["installed_in_this_attempt"] and not item["sampled_in_this_attempt"], "prepared APK scope")
    return {"compile_sdk":35, "actual_device_samples":0}


def legacy_origins():
    old = read(HERE.parent / "candidate-permissions" / "receipts.json")["candidate"]
    origins = []
    for stage in ("anon1", "anon2"):
        row = old[stage]
        origin = row["before"]["ime_editor_origin"]
        require(origin == row["after"]["ime_editor_origin"], "old anonymous request changed")
        origins.append([origin["x"], origin["y"]])
    require(origins[0] == origins[1], "old original projection changed")
    return origins


def capture(directory):
    state = read(directory / "state.json")
    require(state["phase"] == "closed" and state["status"] == "observed", "open emulator run")
    manifest = read(directory.parent / "hashes.json")
    require(state["apk"] == {name:manifest[name] for name in ("target","observer")}, "build/install mismatch")
    return {"environment": {k: state[k] for k in ("api", "hardware", "initially_empty", "disable_usb",
            "disable_mdns", "apk", "uids", "restored", "cleanup", "elapsed_seconds")},
            "compiled_java_sha256": {name:sha for name,sha in manifest.items() if name.endswith(".java")},
            "stages": {stage: read(directory / (stage + ".json")) for stage in STAGES}}


def check_stage(name, row):
    require(row["matched"], name + ": missing request-correlated receipt")
    obs, oracle = row["observer"], row["oracle"]
    require(obs["before"] == obs["after"] and len(obs["replies"]) == 2
            and oracle["requests"] == len(oracle["callbacks"]) >= 2 and oracle["connections"] > 0
            and oracle["display_size"][0] > oracle["display_size"][1], name + ": inconsistent sampling")
    last = -1
    previous_target_request = None
    for i, reply in enumerate(obs["replies"]):
        received = [r for r in oracle["callbacks"]
                    if reply["issued"] <= r["received"] <= r["replied"] <= reply["answered"]]
        require(reply["query"] == (-7, -11)[i] and len(received) == 1
                and last < reply["issued"] <= reply["answered"] < obs["closed"], name + ": wrong callback/time")
        request = received[0]["request"]
        require(previous_target_request is None or previous_target_request + 1 == request, name + ": target order")
        previous_target_request = request
        last = reply["answered"]
    first, second = obs["replies"]
    require(first["sequence"] + 1 == second["sequence"] and first["matrix"] == second["matrix"],
            name + ": changed matrix or request")
    active = [w for w in obs["after"] if w["scope"] == "target" and w["active"] and w["focused"]]
    require(len(active) == 1 and active[0]["window"] == oracle["window"], name + ": oracle mismatch")
    focused = [e for e in active[0]["editors"] if e["focused"]]
    require(len(focused) == 1 and not focused[0]["named"] and focused[0]["screen_rect"] == oracle["bounds"],
            name + ": truth/visible node mismatch")
    require(first["matrix"] == oracle["matrix"], name + ": target transform mismatch")
    return active[0], first["matrix"]


def verify(bundle):
    env = bundle["environment"]
    require(env["api"] == "36" and env["hardware"] == "1" and env["initially_empty"]
            and env["disable_usb"] and env["disable_mdns"] and len(env["uids"]) == 2
            and len(set(env["uids"].values())) == 2 and len(env["restored"]) == 10
            and all(env["restored"].values()) and all(env["cleanup"].values()), "admission or closeout")
    check_java(bundle["compiled_java_sha256"])
    stages = bundle["stages"]
    active, matrices, live = {}, {}, {}
    for name in STAGES:
        active[name], matrices[name] = check_stage(name, stages[name])
        windows = stages[name]["observer"]["after"]
        live[name] = {"windows": [(w["window"], len(w["editors"])) for w in windows if w["scope"] == "target"],
                      **result(matrices[name], windows)}
    require(len({active[n]["window"] for n in STAGES}) == len(STAGES), "window IDs reused")
    results = {}
    for a, b in (("west","east"), ("east","scaled"), ("east","overlap")):
        refs = [active[a], active[b]]
        results[a + "_" + b] = {name: result(matrices[name], refs) for name in (a,b)}
    sides = {name: stages[name]["oracle"] for name in STAGES}
    require(sides["west"]["bounds"] != sides["east"]["bounds"], "separation control failed")
    require(sides["east"]["bounds"] == sides["scaled"]["bounds"] == sides["overlap"]["bounds"],
            "outer rectangle control failed")
    require(matrices["east"] == matrices["overlap"] and matrices["east"] != matrices["scaled"]
            and [matrices["east"][i] for i in (2,5)] == [matrices["scaled"][i] for i in (2,5)],
            "same-origin transform controls failed")
    for name in STAGES:
        edit = next(e for e in active[name]["editors"] if e["focused"])
        require(edit["layout_size"] == sides[name]["local_size"], name + ": layout/measured size differ")
    for a,b in (("west","east"),("east","scaled")):
        for name in (a,b):
            require(results[a+"_"+b][name]["compatible_window"] == active[name]["window"],
                    name + ": did not uniquely match normal source within frozen pair")
    for name in ("east","overlap"):
        require(results["east_overlap"][name]["decision"] == "ambiguous",
                name + ": identical geometry was accepted")
    incomplete = copy.deepcopy([active["east"],active["scaled"]])
    for editor in incomplete[1]["editors"]:
        editor["layout_size"] = None
    absent = result(matrices["east"],incomplete)
    unknown = result(matrices["east"],[active["east"],{"scope":"unknown","window":-1}])
    require(all(x["decision"] == "incomplete" and x["compatible_window"] is None for x in (absent,unknown)),
            "unknown peer accepted")
    return {"candidate_previous_origins":legacy_origins(), "same_snapshot":live,
            "frozen_two_window_controls":results, "host_removed_layout_size":absent,"host_unknown_root":unknown}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-only", action="store_true")
    parser.add_argument("--capture", type=Path)
    parser.add_argument("--receipts", type=Path, help="核对另行提供的完整脱敏矩阵回执")
    args = parser.parse_args()
    model = model_check()
    if args.model_only:
        print(json.dumps({"synthetic_model":model, "original_candidate_anon_origins":legacy_origins()}, indent=2))
    elif args.capture:
        data = capture(args.capture)
        verify(data)
        print(json.dumps(data, indent=2))
    elif args.receipts:
        print(json.dumps(verify(read(args.receipts)), indent=2))
    else:
        print(json.dumps({"recorded_android":closed_evidence(), "prepared":prepared(),
                          "original_candidate_anon_origins":legacy_origins(),
                          "synthetic_model":model}, indent=2))
