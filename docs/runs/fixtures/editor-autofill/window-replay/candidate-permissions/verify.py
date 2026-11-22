"""核对本实验的脱敏、只读回执。仅在宿主上运行。"""

import argparse
import json
from pathlib import Path


CASES = ("named1", "named2", "anon1", "anon2")
PUBLIC = ("public1", "public2")
PACKAGE = "dev.magina.crossappfixture"
COORDS = ("left", "top", "right", "bottom")


def require(condition, reason):
    if not condition:
        raise ValueError(reason)


def read(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def collect(directory):
    """只读六份有名实验回执与收尾状态。保存前将 IME 本地会话号一致替换为序号。"""
    state = read(directory / "state.json")
    require(state["phase"] == "closed" and state["status"] == "observed", "incomplete capture")
    sessions = {}

    def rename(value):
        if isinstance(value, list):
            return [rename(item) for item in value]
        if isinstance(value, dict):
            return {key: sessions.setdefault(item, f"S{len(sessions) + 1}")
                    if key == "session_id" else rename(item) for key, item in value.items()}
        return value

    return {
        "environment": {key: state[key] for key in (
            "api", "hardware", "initially_empty", "disable_usb", "disable_mdns", "apk",
            "uids", "restored", "cleanup", "elapsed_seconds")},
        "candidate": {name: rename(read(directory / (name + ".json"))) for name in CASES},
        "public_api": {name: read(directory / (name + ".json")) for name in PUBLIC},
    }


def check_trial(name, row):
    before, after = row["oracle_before"], row["oracle_after"]
    require(row["foreground"] == [PACKAGE] * 3, f"{name}: foreground changed")
    for key in ("task", "window", "right_focused", "field", "connections", "bounds", "node_bounds"):
        require(before[key] == after[key], f"{name}: target changed {key}")
    require(after["right_focused"] is True and after["connections"] > 0 and after["window"] >= 0,
            f"{name}: target identity absent")
    require(after["bounds"] == after["node_bounds"], f"{name}: target geometry mismatch")
    a, b = (row[stage]["ime_editor_origin"] for stage in ("before", "after"))
    require(a == b and [a["x"], a["y"]] == after["bounds"][:2], f"{name}: unstable IME origin")
    diagnostic = row["diagnostic"]
    bounds = diagnostic["ime_editor_bounds"]
    if name.startswith("named"):
        require(before["requests"] == 0 and after["requests"] == 1 and after["last_request"] > 0,
                f"{name}: own connection did not receive exactly one geometry request")
        require(after["field"] > 0 and bounds["editable"] is True and bounds["window_id"] == after["window"]
                and bounds["session_id"] == a["session_id"] and
                [bounds[k] for k in COORDS] == after["bounds"], f"{name}: named control")
    else:
        require(before["requests"] == after["requests"] == 0 and after["last_request"] == 0,
                f"{name}: unexpected geometry query")
        require(after["field"] == -1 and bounds is None and
                [diagnostic[k] for k in ("ime_editor_bounds_reason", "ime_editor_missing_id_phase",
                                         "ime_editor_missing_id_source")]
                == ["missing_id", "before_sample", "service_node_unnamed"], f"{name}: anonymous control")


def check_public(trials):
    sides = []
    for key in PUBLIC:
        row = trials[key]
        sample, oracle = row["public"], row["oracle"]
        win = sample["a11y"]
        require(sample["started"] < sample["sampled"] < sample["after"], key + ": timing")
        require(win["window"] == win["node_window"] == win["root_window"] == oracle["window"],
                key + ": accessibility window mismatch")
        require(oracle["right_focused"] is True and win["bounds"] == oracle["node_bounds"] == oracle["bounds"],
                key + ": role mismatch")
        require(all(win[k] is False for k in ("unique_id_present", "root_unique_id_present",
                                              "resource_name_present", "anchor_present")), key + ": node metadata changed")
        sides.append(sample)
    a, b = sides
    require(a["after"] < b["started"] and a["generation"] < b["generation"] and
            a["a11y"]["window"] != b["a11y"]["window"], "distinct supplementary instances")
    require(trials["public1"]["oracle"]["task"] != trials["public2"]["oracle"]["task"]
            and a["a11y"]["bounds"] == b["a11y"]["bounds"] and a["a11y"]["display"] == b["a11y"]["display"],
            "supplementary control geometry")
    for key in ("uid", "pid", "binding_label", "native_id", "fill_session", "field"):
        require(a[key] == b[key], "input binding no longer indistinguishable: " + key)
    require(a["field"] == -1 and a["fill_session"] == 0 and a["native_id"] is not None,
            "unexpected anonymous editor metadata")
    return {key: [side[key] for side in sides] for key in (
        "uid", "pid", "binding_label", "native_id", "fill_session", "field", "generation")}


def geometry(row):
    bounds = row["diagnostic"]["ime_editor_bounds"]
    return tuple(bounds[key] for key in COORDS)


def comparison(receiver, ime_geometry):
    """冻结接收方的真实普通权限观察。变动量只有来源未标注的屏幕四边。"""
    bounds = receiver["diagnostic"]["ime_editor_bounds"]
    origins = [receiver[key]["ime_editor_origin"] for key in ("before", "after")]
    return (tuple(receiver["foreground"]), bounds["window_id"], bounds["session_id"], bounds["editable"],
            tuple((origin["session_id"], origin["x"], origin["y"]) for origin in origins),
            ime_geometry)


def matching_sources(receiver, source_geometries):
    observed = comparison(receiver, geometry(receiver))
    return [source for source, rect in source_geometries.items() if comparison(receiver, rect) == observed]


def named_field_control(first, second):
    # 数值来自两靶的 EditorInfo 回执。只用于检验同一资源条件，不向判读器提供靶内身份。
    return first == second and first > 0


def verify(data):
    env = data["environment"]
    require(str(env["api"]) == "36" and str(env["hardware"]) == "1" and env["initially_empty"]
            and env["disable_usb"] and env["disable_mdns"], "emulator admission")
    require(len(set(env["uids"].values())) == 3 and len(env["restored"]) == 10
            and all(env["restored"].values()) and all(env["cleanup"].values()), "closeout")
    require(env["apk"]["gateway"] == "0af7d9880f12992e8846ef32c3691cb97fc22bd3b35d1083f61008eb38f51dfc",
            "unrecognized candidate")
    rows = data["candidate"]
    for name in CASES:
        check_trial(name, rows[name])
    require(len({rows[n]["before"]["ime_editor_origin"]["session_id"] for n in CASES}) == 4,
            "IME generations reused")
    require(len({rows[n]["oracle_after"]["window"] for n in CASES}) == 4 and
            len({rows[n]["oracle_after"]["task"] for n in CASES}) == 4, "distinct target instances")
    require(len({tuple(rows[n]["oracle_after"]["bounds"]) for n in CASES}) == 1,
            "candidate controls do not share a layout")
    fields = [rows[n]["oracle_after"]["field"] for n in CASES[:2]]
    require(named_field_control(*fields), "target reported different named resources")
    require(all(data["public_api"][n]["public"]["uid"] == int(env["uids"]["target"]) for n in PUBLIC),
            "supplementary IME client UID mismatch")
    external = []
    for source in CASES[:2]:
        output_window = rows[source]["diagnostic"]["ime_editor_bounds"]["window_id"]
        for expected in CASES[:2]:
            expected_window = rows[expected]["oracle_after"]["window"]
            match = output_window == expected_window
            require(match == (source == expected), "whole-receipt lookup")
            external.append({"full_receipt": source, "expected_instance": expected, "host_matches_window": match})
    matrix = []
    for group in (CASES[:2], CASES[2:]):
        for receiver in group:
            row = rows[receiver]
            has_sample = row["oracle_after"]["requests"] > row["oracle_before"]["requests"]
            if has_sample:
                candidates = {n: geometry(rows[n]) for n in group}
                possible = matching_sources(row, candidates)
                require(len(possible) == 2, "one geometry distinguished the frozen source pair")
                status = "two_origins_observationally_equal"
            else:
                possible = []
                status = "stopped_before_geometry_request"
            # 只有一份来源在这组假设中存活才可能进一步验收；本次两份相同或没有测量。
            unique = possible[0] if len(possible) == 1 else None
            require(unique is None, "unexpected unique source requires new provenance review")
            for origin in group:
                matrix.append({"receiver": receiver, "origin_hypothesis": origin,
                               "observed_live": receiver == origin,
                               "receiver_raw_window": (row["diagnostic"]["ime_editor_bounds"] or {}).get("window_id"),
                               "evidence": status, "matching_source_count": len(possible) if has_sample else None,
                               "independent_source_window": unique, "deliverable_side": None,
                               "deliverable_bounds": None})
    first, second = CASES[:2]
    real = {n: geometry(rows[n]) for n in (first, second)}
    left, top, right, bottom = real[second]
    changed = {first: real[first], second: (left + 1, top, right, bottom)}
    changed_matches = matching_sources(rows[first], changed)
    changed_contract = named_field_control(fields[0], fields[1] + 1)
    require(changed_matches == [first], "one-edge mutation was ignored")
    require(not changed_contract, "one-field mutation was ignored")
    return {"source_window_acceptance": "BLOCKED", "host_compares_full_receipt": external,
            "ime_source_hypotheses": matrix,
            "host_only_mutations": {"named2_left_plus_one_remaining": changed_matches,
                                    "named2_field_plus_one_same_resource_control": changed_contract},
            "public": check_public(data["public_api"])}


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--capture", type=Path, help="从本轮专用测试台收尾目录提取六份回执")
    args = p.parse_args()
    if args.capture:
        bundle = collect(args.capture)
        verify(bundle)
        print(json.dumps(bundle, indent=2, ensure_ascii=False))
    else:
        result = verify(read(Path(__file__).with_name("receipts.json")))
        print(json.dumps(result, indent=2, ensure_ascii=False))
