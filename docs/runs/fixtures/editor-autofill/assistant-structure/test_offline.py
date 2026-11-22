"""Offline self-tests for assistant-structure fixture, host script invariants, and verifier."""
import json
import re
import struct
import sys
import tempfile
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import prepare as prep_mod
import read_result as rr


def make_art_trace(path, entries):
    """Write a minimal valid uncompressed ART v2 wall-clock trace with exact entry counts."""
    methods = {}
    records = []
    next_id = 0x100
    for (owner, name), count in entries.items():
        mid = next_id
        next_id += 4
        methods[mid] = (owner, name)
        for i in range(count):
            records.append((1, mid | 0, 100 + i))  # action=0 (method entry)
    header_lines = [
        "*version", "2",
        "data-file-overflow=false",
        "clock=wall",
        "elapsed-time-usec=5000",
        f"num-method-calls={len(records)}",
        "*threads", "1\tmain",
        "*methods",
    ]
    for mid, (owner, name) in methods.items():
        header_lines.append(f"0x{mid:x}\t{owner}\t{name}\t()V\tSource.java\t1")
    header_lines.append("*end")
    header = ("\n".join(header_lines) + "\n").encode("utf-8")
    binary_hdr = struct.pack("<4sHH8x", b"SLOW", 2, 16)
    body = b"".join(struct.pack("<HII", tid, tagged, delta) for tid, tagged, delta in records)
    path.write_bytes(header + binary_hdr + body)


def test_prepare_outputs():
    with tempfile.TemporaryDirectory() as tmp:
        out = Path(tmp) / "prepared"
        prep_mod.prepare(out)
        obs_manifest = (out / "observer/AndroidManifest.xml").read_text(encoding="utf-8")
        assert "BIND_SPEECH_RECOGNITION_SERVICE" not in obs_manifest, "non-existent permission must be removed"
        assert "android.speech.RecognitionService" in obs_manifest
        assert "android.intent.category.DEFAULT" in obs_manifest
        assert ".AssistService" in obs_manifest and ".AssistSessionService" in obs_manifest
        assert "RECORD_AUDIO" not in obs_manifest

        tgt_manifest = (out / "target/AndroidManifest.xml").read_text(encoding="utf-8")
        for activity in (".TargetActivity", ".SplitWindowActivity", ".LeftPaneActivity", ".RightPaneActivity"):
            assert activity in tgt_manifest, f"missing {activity}"
        right_block = re.search(r'<activity[^>]*\.RightPaneActivity[^>]*/>', tgt_manifest, re.S)
        assert right_block and "screenOrientation" not in right_block.group(0), (
            "translucent RightPaneActivity must not declare screenOrientation (throws on API 26+)")
        for extra in ("SplitWindowActivity.java", "LeftPaneActivity.java", "RightPaneActivity.java"):
            assert (out / "target" / extra).is_file(), f"missing target-extra {extra}"


def test_host_script_invariants():
    ps1 = (HERE / "run_isolated.ps1").read_text(encoding="utf-8")
    assert "$AssistantRole = 'android.app.role.ASSISTANT'" in ps1
    assert not re.search(r'foreach\s*\(\s*\$AssistantRole\b', ps1, re.I), "role constant overwritten by foreach"
    assert not re.search(r'foreach\s*\(\s*\$role\b', ps1, re.I), "avoid ambiguous $role loop var"
    assert "refusing_default_adb_port_5037" in ps1
    assert "assistant_holder_before" in ps1 and "assistant_holder_after" in ps1
    assert not re.search(r'[A-Za-z]:\\(Users|Repos)\\', ps1), "no hardcoded machine paths in committed script"


def base_sample(**overrides):
    sample = {
        "stage": "assist",
        "generation": 1,
        "ime_start": 10000,
        "request": 11000,
        "acquired": 11010,
        "completed": 11015,
        "received": 11040,
        "sample_close": 14500,
        "shown": True,
        "args_match": True,
        "show_flags": 1,
        "show_id": 7,
        "assist_callbacks": 1,
        "target_trees_examined": 1,
        "current_on_receive": True,
        "current_at_close": True,
        "ime_has_native_id": True,
        "ime_has_resource_id": False,
        "ime_input_type": 1,
        "rejected": None,
        "assist_blocked": False,
        "geometry_valid": True,
        "focus_count": 1,
        "native_id_matches": 0,
        "state_focused": True,
        "activity_index": 0,
        "activity_count": 1,
        "window_count": 1,
        "focused_activity_count": 1,
        "display": 0,
        "window": [0, 0, 2340, 1080],
        "editors": [
            {"focused": False, "has_id": False, "id_matches_ime": False, "has_resource_id": False,
             "resource_matches_ime": False, "input_type": 1, "ime_input_type_matches": True,
             "important_for_autofill": 0, "autofill_type": 0, "assist_blocked": False, "bounds": [40, 32, 240, 102]},
            {"focused": True, "has_id": False, "id_matches_ime": False, "has_resource_id": False,
             "resource_matches_ime": False, "input_type": 1, "ime_input_type_matches": True,
             "important_for_autofill": 0, "autofill_type": 0, "assist_blocked": False, "bounds": [2100, 32, 2300, 102]},
        ],
        "focused_windows": [],
        "activities": [],
    }
    sample.update(overrides)
    return sample


def test_inspect_and_controls():
    ime = {"ime_started_ms": 10000, "generation": 1}
    assert rr.inspect_sample(base_sample(), ime) == "CURRENT_ASSIST_STRUCTURE"
    assert rr.inspect_sample(base_sample(stage="noflag", show_flags=0, target_trees_examined=0, assist_callbacks=0), ime) == "NO_STRUCTURE"
    assert rr.inspect_sample(base_sample(show_flags=3), ime) == "SCREENSHOT_REQUESTED"
    assert rr.inspect_sample(base_sample(request=15000, sample_close=18500), ime) == "STALE_OR_UNORDERED_STRUCTURE"
    assert rr.inspect_sample(
        base_sample(stage="secure", assist_blocked=True, rejected="assist_blocked", geometry_valid=False, editors=[], focus_count=0),
        ime, expected_stage="secure") == "ASSIST_BLOCKED"

    # Multi-window 2-activity positive & fail-closed controls
    mw_good = base_sample(
        stage="multiwin2",
        assist_callbacks=2,
        target_trees_examined=2,
        focused_activity_count=1,
        focused_windows=[{
            "activity_index": 0, "activity_component": "dev.magina.autofilltarget/.RightPaneActivity",
            "state_focused": True, "activity_id_slot": 0, "window_index": 0, "display": 0,
            "window": [1300, 40, 2300, 520], "editor_bounds": [2060, 72, 2260, 142],
            "has_id": False, "id_matches_ime": False, "has_resource_id": False, "resource_matches_ime": False,
        }],
        activities=[
            {"index": 0, "count": 2, "state_focused": True, "activity_id_slot": 0, "target_package": True,
             "component": "dev.magina.autofilltarget/.RightPaneActivity", "window_count": 1,
             "windows": [{"window_index": 0, "display": 0, "window": [1300, 40, 2300, 520],
                          "editors": [{"focused": True, "bounds": [2060, 72, 2260, 142]}]}]},
            {"index": 1, "count": 2, "state_focused": False, "activity_id_slot": 1, "target_package": True,
             "component": "dev.magina.autofilltarget/.LeftPaneActivity", "window_count": 1,
             "windows": [{"window_index": 0, "display": 0, "window": [0, 0, 1100, 1080],
                          "editors": [{"focused": False, "bounds": [40, 32, 240, 102]}]}]},
        ],
    )
    res = rr.evaluate_multiwin(mw_good, "multiwin2", [40, 32, 240, 102], [2060, 72, 2260, 142], ime=ime)
    assert res["decision"] == "MULTIWIN_RIGHT_DISTINGUISHED"
    assert res["target_activities"] == 2 and res["distinct_activity_ids"] == 2
    assert res["window_bounds_disjoint"] is True and res["editor_bounds_disjoint"] is True and res["strict_shared_id"] is False

    # Overlapping fullscreen left window + floating right window: windows overlap, editors disjoint
    mw_overlap_win = dict(mw_good, activities=[
        mw_good["activities"][0],
        dict(mw_good["activities"][1], windows=[{"window_index": 0, "display": 0, "window": [0, 0, 2340, 1080],
                                                 "editors": [{"focused": False, "bounds": [40, 32, 240, 102]}]}]),
    ])
    res_ov = rr.evaluate_multiwin(mw_overlap_win, "multiwin2", [40, 32, 240, 102], [2060, 72, 2260, 142], ime=ime)
    assert res_ov["decision"] == "MULTIWIN_RIGHT_DISTINGUISHED"
    assert res_ov["window_bounds_disjoint"] is False and res_ov["editor_bounds_disjoint"] is True

    # Fail closed on IME generation mismatch
    assert rr.evaluate_multiwin(mw_good, "multiwin2", [40, 32, 240, 102], [2060, 72, 2260, 142],
                                ime={"generation": 9, "ime_started_ms": 10000})["decision"] == "DIFFERENT_GENERATION"

    # Fail closed if 2 windows claim focus
    mw_dup = dict(mw_good, focused_windows=mw_good["focused_windows"] * 2)
    assert rr.evaluate_multiwin(mw_dup, "multiwin2", [40, 32, 240, 102], [2060, 72, 2260, 142], ime=ime)["decision"] == "AMBIGUOUS_FOCUSED_WINDOWS"

    # Fail closed if focused_activity_count != 1
    mw_bad_act = dict(mw_good, focused_activity_count=2)
    assert rr.evaluate_multiwin(mw_bad_act, "multiwin2", [40, 32, 240, 102], [2060, 72, 2260, 142], ime=ime)["decision"] == "AMBIGUOUS_ACTIVITY_FOCUS"

    # Fail closed if only 1 window visible
    mw_single = dict(mw_good, activities=mw_good["activities"][:1])
    assert rr.evaluate_multiwin(mw_single, "multiwin2", [40, 32, 240, 102], [2060, 72, 2260, 142], ime=ime)["decision"] == "SINGLE_WINDOW_ONLY"


def test_full_summarize_and_role_readback_gate():
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        a2 = root / "A2"
        a2.mkdir()
        oracle = {
            "scenario": "automatic-right-switch", "status": "probe_observed", "settled": True,
            "windowFocus": True, "landscape": True, "instance": "inst-1",
            "leftViewInstance": 111, "rightViewInstance": 222,
            "focusSide": "right", "connectionSide": "right", "probeSide": "right", "desiredSide": "right",
            "rightProbeCount": 1, "rightConnections": 2, "leftProbeCount": 0, "leftConnections": 0,
            "manual_request_count": 0, "restartInputCalls": 0, "touchDownCount": 0, "touchUpCount": 0,
            "stageStartUptime": 8000, "stageEndUptime": 10050,
            "leftBounds": [40, 32, 240, 102], "rightBounds": [2100, 32, 2300, 102],
        }
        ready = {
            "instance": "inst-1", "rightViewInstance": 222, "rightBounds": [2100, 32, 2300, 102],
            "uptime_ms": 9000, "focusSide": "right", "connectionSide": "right",
            "rightConnections": 1, "rightProbeCount": 0, "manual_request_count": 0,
        }
        (a2 / "oracle.json").write_text(json.dumps(oracle), encoding="utf-8")
        (a2 / "right-ready.json").write_text(json.dumps(ready), encoding="utf-8")
        (a2 / "observation.json").write_text(json.dumps(
            {"marker_readback_ms": 100, "oracle_read_ms": 500, "journal_read_ms": 7000}), encoding="utf-8")
        (a2 / "journal-read.txt").write_text("ABSENT", encoding="utf-8")
        (a2 / "ledger.json").write_text(json.dumps(
            {"stage": 2, "callback_count": 0, "terminal_count": 0, "samples": [],
             "host_observation": "journal_absent_at_close"}), encoding="utf-8")
        (a2 / "pre-switch-journal.txt").write_text(json.dumps(
            {"stage": 1, "callback_count": 1, "terminal_count": 1,
             "samples": [{"manual": False, "acquisition_start_uptime_ms": 9010,
                          "callback_uptime_ms": 9100, "reason": "NO_CURRENT_IME"}]}), encoding="utf-8")
        (a2 / "ime.txt").write_text("11-22 12:00:00.000  4000  4000 I SyntheticProbeIme: generation=1 started=10000\n", encoding="utf-8")

        fresh = base_sample()
        empty = base_sample(stage="noflag", show_flags=0, request=16000, sample_close=19500,
                            acquired=None, completed=None, received=None,
                            target_trees_examined=0, assist_callbacks=0, editors=[], focus_count=0)
        (a2 / "assist-assist.json").write_text(json.dumps(fresh), encoding="utf-8")
        (a2 / "assist-noflag.json").write_text(json.dumps(empty), encoding="utf-8")
        (a2 / "assist.log").write_text("\n".join([
            "10005 AssistTarget: wire=2 probe=-3 side=right instance=inst-1 view=222 tick=10005",
            "11011 AssistTarget: assist_write side=left focus=false window_focus=true instance=inst-1 view=111 tick=11011",
            "11012 AssistTarget: assist_write side=right focus=true window_focus=true instance=inst-1 view=222 tick=11012",
            "14510 AssistTarget: wire=2 probe=-4 side=right instance=inst-1 view=222 tick=14510",
            "14520 SyntheticAssist: session_destroyed assist tick=14520",
            "19510 AssistTarget: wire=2 probe=-4 side=right instance=inst-1 view=222 tick=19510",
            "19520 SyntheticAssist: session_destroyed noflag tick=19520",
        ]) + "\n", encoding="utf-8")
        editor_cls = "dev.magina.autofilltarget.TargetActivity$Editor"
        make_art_trace(a2 / "assist.trace", {(editor_cls, "onProvideStructure"): 2})
        make_art_trace(a2 / "noflag.trace", {})

        restored_13 = {f"k{i}": True for i in range(13)}
        state = {
            "initially_empty": True, "hardware": "1", "api": "36",
            "disable_usb": True, "disable_mdns": True,
            "assistant_holder_before": "com.google.android.googlequicksearchbox",
            "assistant_role_during": "dev.magina.autofillobserver",
            "assistant_holder_after": "com.google.android.googlequicksearchbox",
            "assistant_role_restored": True,
            "autofill_after_assist": "ABSENT",
            "phase": "closed", "status": "observed", "cleanup_errors": [],
            "restored": restored_13,
            "cleanup": {"ports_released": True, "emulator_stopped": True,
                        "isolated_server_stopped": True, "avd_cleaned": True},
        }
        (root / "state.json").write_text(json.dumps(state), encoding="utf-8")

        # Add secure control (assist_blocked branch + real ime.txt anchor)
        sec = root / "controls/secure"
        sec.mkdir(parents=True)
        (sec / "oracle.json").write_text(json.dumps(dict(oracle, windowSecure=True)), encoding="utf-8")
        (sec / "ime.txt").write_text("11-22 12:00:00.000  4000  4000 I SyntheticProbeIme: generation=1 started=10000\n", encoding="utf-8")
        (sec / "assist-secure.json").write_text(json.dumps(
            base_sample(stage="secure", assist_blocked=True, rejected="assist_blocked",
                        geometry_valid=False, editors=[], focus_count=0)), encoding="utf-8")

        summary = rr.summarize(root)
        assert summary["current_structure"] is True
        assert summary["common_native_id"] is False and summary["common_resource_id"] is False
        assert summary["strict_selected_side"] is None
        assert summary["focused_bounds"] == [2100, 32, 2300, 102]
        assert summary["assistant_holder_before"] == summary["assistant_holder_after"]
        assert summary["controls"]["secure"]["decision"] == "ASSIST_BLOCKED"
        assert summary["controls"]["secure"]["mechanism"] == "assist_blocked"

        # Verify FLAG_SECURE structure_null branch also passes fail-closed
        (sec / "assist-secure.json").write_text(json.dumps(
            base_sample(stage="secure", target_trees_examined=0, assist_callbacks=1, assist_blocked=False,
                        acquired=None, completed=None, received=None, editors=[], focus_count=0,
                        activities=[{"index": 0, "count": 1, "state_focused": True, "structure_null": True}])),
            encoding="utf-8")
        summary_null = rr.summarize(root)
        assert summary_null["controls"]["secure"]["decision"] == "NO_STRUCTURE"
        assert summary_null["controls"]["secure"]["mechanism"] == "structure_null"

        # Verify mismatched ime.txt anchor in control fails closed!
        (sec / "ime.txt").write_text("11-22 12:00:00.000  4000  4000 I SyntheticProbeIme: generation=99 started=99999\n", encoding="utf-8")
        try:
            rr.summarize(root)
            raise AssertionError("summarize must reject control ime.txt anchor mismatch")
        except ValueError as err:
            assert "DIFFERENT_GENERATION" in str(err)
        (sec / "ime.txt").write_text("11-22 12:00:00.000  4000  4000 I SyntheticProbeIme: generation=1 started=10000\n", encoding="utf-8")

        # Missing final role holder readback MUST fail closed!
        bad_state = dict(state, assistant_holder_after=None)
        (root / "state.json").write_text(json.dumps(bad_state), encoding="utf-8")
        try:
            rr.summarize(root)
            raise AssertionError("summarize must reject missing assistant_holder_after")
        except ValueError as err:
            assert "role holder readback" in str(err)


if __name__ == "__main__":
    test_prepare_outputs()
    test_host_script_invariants()
    test_inspect_and_controls()
    test_full_summarize_and_role_readback_gate()
    print(json.dumps({"offline_tests": "PASS", "checks": 4}, indent=2))
