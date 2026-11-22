"""Check the assistant's structure, the contemporary connection and the independent target."""
import argparse
import json
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from count_focus_methods import SELECTED, summarize as trace_summary
from verify_right_first import evaluate, read, require


def inspect_sample(sample, ime, expected_stage="assist"):
    if not sample["shown"] or not sample["args_match"] or not sample["current_at_close"]:
        return "REQUEST_OR_CONNECTION_CHANGED"
    if (sample["ime_start"], sample["generation"]) != (ime["ime_started_ms"], ime["generation"]):
        return "DIFFERENT_GENERATION"
    if sample["show_flags"] & 2:
        return "SCREENSHOT_REQUESTED"
    if sample["target_trees_examined"] == 0:
        return "NO_STRUCTURE"
    if (sample["stage"] != expected_stage or not (sample["show_flags"] & 1) or not sample["current_on_receive"]
            or sample["target_trees_examined"] != 1 or sample["assist_callbacks"] != 1):
        return "UNEXPECTED_DELIVERY"
    if sample.get("assist_blocked"):
        return "ASSIST_BLOCKED"
    if sample.get("rejected"):
        return "REJECTED_STRUCTURE"
    if not all(type(sample[k]) is int for k in ("request", "acquired", "completed", "received", "sample_close")):
        return "UNKNOWN_ACQUISITION"
    if not (sample["ime_start"] < sample["request"] < sample["acquired"] <= sample["completed"]
            <= sample["received"] <= sample["sample_close"]):
        return "STALE_OR_UNORDERED_STRUCTURE"
    if not sample["geometry_valid"] or len(sample["editors"]) != 2 or sample["focus_count"] != 1:
        return "UNRESOLVED_GEOMETRY"
    return "CURRENT_ASSIST_STRUCTURE"


def _rects_disjoint(a, b):
    return a[2] <= b[0] or b[2] <= a[0] or a[3] <= b[1] or b[3] <= a[1]


def _rect_contains(outer, inner):
    return outer[0] <= inner[0] and outer[1] <= inner[1] and outer[2] >= inner[2] and outer[3] >= inner[3]


def evaluate_multiwin(sample, expected_stage, left_bounds, right_bounds):
    if not sample["shown"] or not sample["args_match"] or not sample["current_at_close"]:
        return {"decision": "REQUEST_OR_CONNECTION_CHANGED"}
    if sample["show_flags"] & 2:
        return {"decision": "SCREENSHOT_REQUESTED"}
    if not (sample["show_flags"] & 1) or sample["stage"] != expected_stage or not sample["current_on_receive"]:
        return {"decision": "UNEXPECTED_DELIVERY"}
    if sample.get("assist_blocked"):
        return {"decision": "ASSIST_BLOCKED"}
    if not all(type(sample[k]) is int for k in ("ime_start", "request", "acquired", "completed", "received", "sample_close")):
        return {"decision": "UNKNOWN_ACQUISITION"}
    if not (sample["ime_start"] < sample["request"] < sample["acquired"] <= sample["completed"]
            <= sample["received"] <= sample["sample_close"]):
        return {"decision": "STALE_OR_UNORDERED_STRUCTURE"}
    if not sample["geometry_valid"]:
        return {"decision": "INVALID_GEOMETRY"}

    target_acts = [a for a in sample.get("activities", []) if a.get("target_package") is True]
    all_windows = []
    for act in target_acts:
        for w in act.get("windows", []):
            all_windows.append((act, w))
    focused_wins = sample.get("focused_windows", [])
    if len(all_windows) < 2:
        return {"decision": "SINGLE_WINDOW_ONLY", "target_activities": len(target_acts), "target_windows": len(all_windows)}
    if len(focused_wins) == 0:
        return {"decision": "NO_FOCUSED_WINDOW", "target_activities": len(target_acts), "target_windows": len(all_windows)}
    if len(focused_wins) > 1:
        return {"decision": "AMBIGUOUS_FOCUSED_WINDOWS", "focused_window_count": len(focused_wins)}
    if len(target_acts) >= 2:
        if sample.get("focused_activity_count") != 1 or not focused_wins[0].get("state_focused"):
            return {"decision": "AMBIGUOUS_ACTIVITY_FOCUS",
                    "focused_activity_count": sample.get("focused_activity_count"),
                    "state_focused": focused_wins[0].get("state_focused")}

    fw = focused_wins[0]
    other_windows = [w for act, w in all_windows
                     if not (act["index"] == fw["activity_index"] and w["window_index"] == fw["window_index"])]
    left_found = any(any(e["bounds"] == left_bounds and not e["focused"] for e in w["editors"]) for w in other_windows)
    right_matches = fw["editor_bounds"] == right_bounds and _rect_contains(fw["window"], right_bounds)
    disjoint = all(_rects_disjoint(fw["window"], w["window"]) for w in other_windows)
    act_slots = {a.get("activity_id_slot") for a in target_acts if a.get("activity_id_slot", -1) >= 0}
    shared_id = bool(fw.get("id_matches_ime") or fw.get("resource_matches_ime"))
    decision = "MULTIWIN_RIGHT_DISTINGUISHED" if (right_matches and left_found) else "MULTIWIN_MISMATCH"
    return {
        "decision": decision,
        "target_activities": len(target_acts),
        "target_windows": len(all_windows),
        "focused_activity_count": sample.get("focused_activity_count"),
        "distinct_activity_ids": len(act_slots),
        "focused_component": fw.get("activity_component"),
        "focused_state_flag": fw.get("state_focused"),
        "focused_window_bounds": fw["window"],
        "focused_editor_bounds": fw["editor_bounds"],
        "window_bounds_disjoint": disjoint,
        "unfocused_left_seen": left_found,
        "common_native_id": bool(fw.get("id_matches_ime")),
        "common_resource_id": bool(fw.get("resource_matches_ime")),
        "strict_shared_id": shared_id,
    }


def observed_stages(directory):
    a2 = directory / "A2"
    ime = evaluate(a2)
    result = {}
    for stage in ("assist", "noflag"):
        path = a2 / f"assist-{stage}.json"
        if not path.exists() or path.read_text(encoding="utf-8-sig").strip() == "ABSENT":
            result[stage] = {"decision": "NO_COMPLETE_RECEIPT"}
            continue
        sample = read(a2, path.name)
        result[stage] = {"decision": inspect_sample(sample, ime), "delivered": sample["target_trees_examined"],
                         "acquired": sample["acquired"], "completed": sample["completed"],
                         "received": sample["received"], "current_on_receive": sample["current_on_receive"],
                         "current_at_close": sample["current_at_close"], "rejected": sample.get("rejected"),
                         "assist_blocked": sample.get("assist_blocked")}
    return result


def verify_setup_stop(directory):
    """Verify the preserved first run, including the missing role-holder closeout read."""
    state = read(directory, "state.json")
    require(state["status"] == "failed" and state["phase"] == "closed"
            and state["initially_empty"] and state["disable_usb"] and state["disable_mdns"]
            and state["api"] == "36" and state["hardware"] == "1", "unexpected preparation outcome")
    require(state["cleanup_errors"] == ["native_exit_restore-assistant-role"] and not (directory / "A2").exists(),
            "unexpected scene or cleanup")
    for command in ("select-assistant", "restore-assistant-role"):
        errors = list(directory.glob(f"*-{command}.stderr.txt"))
        require(len(errors) == 1 and "Failed" in errors[0].read_text(encoding="utf-8-sig"),
                f"missing role command failure for {command}")
    holders = list(directory.glob("*-assistant-holder.stdout.txt"))
    require(len(holders) == 1 and holders[0].read_text(encoding="utf-8-sig").strip() == state["assistant_holder_before"]
            and "assistant_role_restored" not in state, "role holder readback differs")
    uninstalls = list(directory.glob("*-uninstall-readback.stdout.txt"))
    require(len(uninstalls) == 2 and all(not p.read_text(encoding="utf-8-sig").strip() for p in uninstalls)
            and len(state["restored"]) == 13 and all(state["restored"].values())
            and state["cleanup"] == {"ports_released": True, "emulator_stopped": True, "isolated_server_stopped": True},
            "package, settings or process cleanup differs")
    return dict(outcome="STOPPED_BEFORE_ASSISTANT_SELECTION", scene_executed=False, new_structure=None,
                connection_continuity=None, shared_field_id=None, elapsed_seconds=state["elapsed_seconds"],
                holder_at_close=None, restored_settings=len(state["restored"]), uninstalled=len(uninstalls),
                cleanup=state["cleanup"])


def summarize_controls(controls_dir):
    summary = {}
    for stage in ("secure", "ccoptout", "obfuscated"):
        sub = controls_dir / stage
        if not (sub / f"assist-{stage}.json").is_file():
            continue
        sample = read(sub, f"assist-{stage}.json")
        oracle = read(sub, "oracle.json")
        ime_stub = {"ime_started_ms": sample["ime_start"], "generation": sample["generation"]}
        decision = inspect_sample(sample, ime_stub, expected_stage=stage)
        if stage == "secure":
            require(oracle.get("windowSecure") is True, "secure oracle missing FLAG_SECURE")
            require(decision == "ASSIST_BLOCKED" and sample.get("assist_blocked") is True
                    and sample["editors"] == [] and sample["focus_count"] == 0,
                    f"FLAG_SECURE opt-out did not fail closed: {decision}")
            summary[stage] = {"decision": decision, "assist_blocked": True, "editors": 0, "focus_count": 0}
        elif stage == "ccoptout":
            require(oracle.get("ccOptOut") is True, "ccoptout oracle missing flag")
            focused = [e for e in sample["editors"] if e["focused"]]
            summary[stage] = {
                "decision": decision,
                "root_cc_importance": oracle.get("rootContentCaptureImportance"),
                "assist_blocked": bool(sample.get("assist_blocked")),
                "editors": len(sample["editors"]),
                "focused_matches_right": len(focused) == 1 and focused[0]["bounds"] == oracle["rightBounds"],
                "common_native_id": bool(sample["native_id_matches"] == 1 and sample["ime_has_native_id"]),
            }
        elif stage == "obfuscated":
            require(oracle.get("a11yObfuscated") is True, "obfuscated oracle missing flag")
            focused = [e for e in sample["editors"] if e["focused"]]
            require(decision == "CURRENT_ASSIST_STRUCTURE" and len(focused) == 1
                    and focused[0]["bounds"] == oracle["rightBounds"],
                    f"a11y-obfuscated control unexpected decision: {decision}")
            summary[stage] = {
                "decision": decision,
                "pierced_a11y_obfuscation": True,
                "focused_bounds": focused[0]["bounds"],
                "common_native_id": bool(sample["native_id_matches"] == 1 and sample["ime_has_native_id"]),
            }

    mw1 = controls_dir / "multiwin"
    if (mw1 / "assist-multiwin.json").is_file() and (mw1 / "multiwin-dialog.json").is_file():
        sample = read(mw1, "assist-multiwin.json")
        oracle = read(mw1, "multiwin-dialog.json")
        summary["multiwin_dialog"] = evaluate_multiwin(
            sample, "multiwin", oracle["leftBounds"], oracle["rightBounds"])

    mw2 = controls_dir / "multiwin2"
    if ((mw2 / "assist-multiwin2.json").is_file()
            and (mw2 / "pane-left.json").is_file() and (mw2 / "pane-right.json").is_file()):
        sample = read(mw2, "assist-multiwin2.json")
        left_o = read(mw2, "pane-left.json")
        right_o = read(mw2, "pane-right.json")
        summary["multiwin_tasks"] = evaluate_multiwin(
            sample, "multiwin2", left_o["editorBounds"], right_o["editorBounds"])

    return summary


def summarize(directory):
    a2 = directory / "A2"
    ime = evaluate(a2)
    require(ime["stage"] == 2 and ime["callback_count"] == 0 and ime["reason"] == "NO_NEW_CALLBACK"
            and len(ime["pre_switch_callbacks"]) == 1, "initial natural callback or switch control differs")
    oracle = read(a2, "oracle.json")
    fresh, empty = (read(a2, f"assist-{s}.json") for s in ("assist", "noflag"))
    require(empty["stage"] == "noflag" and empty["args_match"] and empty["show_flags"] & 3 == 0
            and empty["request"] > fresh["sample_close"] and inspect_sample(empty, ime) == "NO_STRUCTURE",
            "no-flag control did not independently reject")
    require(inspect_sample(fresh, ime) == "CURRENT_ASSIST_STRUCTURE", "fresh assistant sample not proven")
    replay = dict(fresh, request=empty["request"], sample_close=empty["sample_close"])
    stale = inspect_sample(replay, ime)
    require(stale == "STALE_OR_UNORDERED_STRUCTURE", "older acquisition accepted in later request window")
    focused = [e for e in fresh["editors"] if e["focused"]]
    require(len(focused) == 1 and focused[0]["bounds"] == oracle["rightBounds"]
            and sorted(e["bounds"] for e in fresh["editors"]) == sorted([oracle["rightBounds"], oracle["leftBounds"]]),
            "assist rectangles differ from independent target")
    shared_id = (fresh["ime_has_native_id"] and focused[0]["has_id"] and focused[0]["id_matches_ime"]
                 and sum(e["id_matches_ime"] for e in fresh["editors"]) == fresh["native_id_matches"] == 1)
    shared_resource = (fresh["ime_has_resource_id"] and focused[0]["resource_matches_ime"]
                       and sum(e["resource_matches_ime"] for e in fresh["editors"]) == 1)
    log = (a2 / "assist.log").read_text(encoding="utf-8-sig")
    require(all(bad not in log for bad in ("unexpected_ui", "unexpected_recognition",
                                           "unexpected_screenshot", "command_rejected")),
            "unexpected assistant action")
    probes = [(int(w), int(probe), int(t)) for w, probe, instance, view, t in re.findall(
        r"wire=(\d+) probe=(-[34]) side=right instance=([\w-]+) view=(\d+) tick=(\d+)", log)
        if instance == oracle["instance"] and int(view) == oracle["rightViewInstance"]]
    initial = [(wire, t) for wire, tag, t in probes if tag == -3 and ime["ime_started_ms"] <= t < fresh["request"]]
    require(len(initial) == 1, "no unique pre-assist target connection")
    wire = initial[0][0]
    writes = [(side, focus, win, instance, int(view), int(t)) for side, focus, win, instance, view, t in re.findall(
        r"assist_write side=(left|right) focus=(true|false) window_focus=(true|false) "
        r"instance=([\w-]+) view=(\d+) tick=(\d+)", log)]
    for s in ("left", "right"):
        require(len([t for side, focus, win, instance, view, t in writes if side == s and win == "true"
                     and focus == ("true" if s == "right" else "false") and instance == oracle["instance"]
                     and view == oracle[s + "ViewInstance"] and fresh["acquired"] <= t <= fresh["completed"]]) == 1,
                f"missing independent {s} Assist write within acquisition")
    editor = "dev.magina.autofilltarget.TargetActivity$Editor"
    SELECTED[editor] = ("onCreateInputConnection", "onProvideStructure", "onProvideAutofillStructure")
    traces = {}
    for sample in (fresh, empty):
        s = sample["stage"]
        destroyed = re.findall(rf"session_destroyed {s} tick=(\d+)", log)
        require(len(destroyed) == 1 and len([t for w, tag, t in probes if w == wire and tag == -4
                and sample["sample_close"] <= t <= int(destroyed[0]) + 1000]) == 1, f"{s} post-probe not delivered")
        trace = trace_summary(a2 / f"{s}.trace")
        counts = trace["entries"]
        require(counts[editor]["onProvideStructure"] == (2 if s == "assist" else 0)
                and counts[editor]["onProvideAutofillStructure"] == counts[editor]["onCreateInputConnection"] == 0
                and counts["android.view.View"]["onFocusChanged"] == counts["android.view.View"]["onWindowFocusChanged"] == 0,
                f"{s}: target writes, focus or input connection changed unexpectedly")
        traces[s] = dict(records=trace["records"], elapsed_us=trace["elapsed_us"], target=counts[editor])
    state = read(directory, "state.json")
    require(state["autofill_after_assist"] == "ABSENT", "unexpected autofill callback")
    require(isinstance(state.get("assistant_holder_before"), str)
            and isinstance(state.get("assistant_holder_after"), str)
            and state["assistant_holder_after"] == state["assistant_holder_before"],
            "assistant role holder readback missing or mismatched at closeout")
    require(state["initially_empty"] and state["hardware"] == "1" and state["api"] == "36"
            and state["disable_usb"] and state["disable_mdns"] and state["assistant_role_restored"]
            and state["assistant_role_during"] == "dev.magina.autofillobserver" and state["phase"] == "closed"
            and state["status"] == "observed" and not state["cleanup_errors"]
            and len(state["restored"]) == 13 and all(state["restored"].values()) and all(state["cleanup"].values()),
            "incomplete isolated run or role restoration")
    shared = shared_id or shared_resource
    out = dict(channel="VoiceInteractionSession", generation=ime["generation"], ime_start=ime["ime_started_ms"],
               request=fresh["request"], acquired=fresh["acquired"], completed=fresh["completed"],
               received=fresh["received"], current_structure=True, common_native_id=bool(shared_id),
               common_resource_id=bool(shared_resource), focused_bounds=focused[0]["bounds"], target_witness="RIGHT",
               strict_selected_side="RIGHT" if shared else None,
               strict_selected_bounds=focused[0]["bounds"] if shared else None,
               negative="NO_STRUCTURE", offline_older_structure=stale, target_wire=wire, trace=traces,
               assistant_holder_before=state["assistant_holder_before"],
               assistant_holder_after=state["assistant_holder_after"])
    controls_dir = directory / "controls"
    if controls_dir.is_dir():
        out["controls"] = summarize_controls(controls_dir)
    return out


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--samples-only", action="store_true", help="describe raw deliveries without certifying the run")
    mode.add_argument("--setup-only", action="store_true", help="verify the observed role-selection failure and cleanup")
    args = parser.parse_args()
    verifier = verify_setup_stop if args.setup_only else observed_stages if args.samples_only else summarize
    print(json.dumps(verifier(args.directory), indent=2))
