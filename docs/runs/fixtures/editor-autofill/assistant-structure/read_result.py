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


def inspect_sample(sample, ime):
    if not sample["shown"] or not sample["args_match"] or not sample["current_at_close"]:
        return "REQUEST_OR_CONNECTION_CHANGED"
    if (sample["ime_start"], sample["generation"]) != (ime["ime_started_ms"], ime["generation"]):
        return "DIFFERENT_GENERATION"
    if sample["show_flags"] & 2:
        return "SCREENSHOT_REQUESTED"
    if sample["target_trees_examined"] == 0:
        return "NO_STRUCTURE"
    if (sample["stage"] != "assist" or not sample["show_flags"] & 1 or not sample["current_on_receive"]
            or sample["target_trees_examined"] != 1 or sample["assist_callbacks"] != 1):
        return "UNEXPECTED_DELIVERY"
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
                         "current_at_close": sample["current_at_close"], "rejected": sample.get("rejected")}
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
    require(state["initially_empty"] and state["hardware"] == "1" and state["api"] == "36"
            and state["disable_usb"] and state["disable_mdns"] and state["assistant_role_restored"]
            and state["assistant_role_during"] == "dev.magina.autofillobserver" and state["phase"] == "closed"
            and state["status"] == "observed" and not state["cleanup_errors"]
            and len(state["restored"]) == 13 and all(state["restored"].values()) and all(state["cleanup"].values()),
            "incomplete isolated run or role restoration")
    shared = shared_id or shared_resource
    return dict(channel="VoiceInteractionSession", generation=ime["generation"], ime_start=ime["ime_started_ms"],
                request=fresh["request"], acquired=fresh["acquired"], completed=fresh["completed"],
                received=fresh["received"], current_structure=True, common_native_id=bool(shared_id),
                common_resource_id=bool(shared_resource), focused_bounds=focused[0]["bounds"], target_witness="RIGHT",
                strict_selected_side="RIGHT" if shared else None, strict_selected_bounds=focused[0]["bounds"] if shared else None,
                negative="NO_STRUCTURE", offline_older_structure=stale, target_wire=wire, trace=traces)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--samples-only", action="store_true", help="describe raw deliveries without certifying the run")
    mode.add_argument("--setup-only", action="store_true", help="verify the observed role-selection failure and cleanup")
    args = parser.parse_args()
    verifier = verify_setup_stop if args.setup_only else observed_stages if args.samples_only else summarize
    print(json.dumps(verifier(args.directory), indent=2))
