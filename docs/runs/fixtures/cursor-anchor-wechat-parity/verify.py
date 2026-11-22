#!/usr/bin/env python3
"""Offline and live-receipt verifier for the WeChat-parity Pathway 4A + 4B fixture."""

from __future__ import annotations

import argparse
import copy
import json
import re
import sys
from pathlib import Path
from typing import Any

REQUIRED_SCENARIOS = (
    "disjoint_right_dead_end",
    "disjoint_right_valid_node",
    "disjoint_right_legacy_1arg",
    "disjoint_left_dead_end",
    "overlap_right",
    "type_null_decor",
)

EXPECTED_SETTINGS_KEYS = (
    "secure:default_input_method",
    "secure:enabled_input_methods",
    "secure:enabled_accessibility_services",
    "secure:accessibility_enabled",
    "system:accelerometer_rotation",
    "system:user_rotation",
)

HOST_PATH_RE = re.compile(r"(?:[A-Za-z]:\\(?:Users|Repos|Program Files)|/Users/|/home/)")
HEX32_RE = re.compile(r"(?<![0-9A-Za-z_])[0-9a-f]{32}(?![0-9A-Za-z_])")


def _require(cond: bool, msg: str, errors: list[str]) -> None:
    if not cond:
        errors.append(msg)


def _rect_close(bounds_obj: dict[str, Any], target_rect: list[int], tol: float = 1.0) -> bool:
    if not isinstance(bounds_obj, dict) or not isinstance(target_rect, list) or len(target_rect) != 4:
        return False
    return (
        abs(float(bounds_obj.get("left", -9999)) - target_rect[0]) <= tol
        and abs(float(bounds_obj.get("top", -9999)) - target_rect[1]) <= tol
        and abs(float(bounds_obj.get("right", -9999)) - target_rect[2]) <= tol
        and abs(float(bounds_obj.get("bottom", -9999)) - target_rect[3]) <= tol
    )


def _marker_in_rect(marker: dict[str, Any], rect: list[int], tol: float = 2.0) -> bool:
    if not isinstance(marker, dict) or len(rect) != 4:
        return False
    tx = float(marker.get("top_x", -9999))
    ty = float(marker.get("top_y", -9999))
    bx = float(marker.get("bottom_x", -9999))
    by = float(marker.get("bottom_y", -9999))
    return (
        rect[0] - tol <= min(tx, bx)
        and max(tx, bx) <= rect[2] + tol
        and rect[1] - tol <= min(ty, by)
        and max(ty, by) <= rect[3] + tol
    )


def verify_receipts(receipts: dict[str, Any]) -> list[str]:
    errors: list[str] = []

    raw_text = json.dumps(receipts, ensure_ascii=False)
    _require(HOST_PATH_RE.search(raw_text) is None, "host path leaked in receipts", errors)

    env = receipts.get("environment", {})
    _require(env.get("api") == "36", f"expected api=36, got {env.get('api')}", errors)
    _require(env.get("qemu") == "1", f"expected qemu=1, got {env.get('qemu')}", errors)
    _require(env.get("adb_usb_disabled") is True, "ADB_USB=0 not proven", errors)
    _require(env.get("adb_mdns_disabled") is True, "ADB_MDNS=0 not proven", errors)
    _require(env.get("adb_emu_enabled") is True, "ADB_EMU=1 not proven", errors)
    _require(env.get("initial_adb_devices_empty") is True, "initial adb devices must be empty", errors)
    _require(env.get("adb_port") != 5037, "must not use default adb port 5037", errors)
    _require(env.get("avd_identity_verified") is True, "AVD identity not verified", errors)

    apks = receipts.get("apks", {})
    gw_uid = apks.get("gateway_uid")
    fx_uid = apks.get("fixture_uid")
    _require(isinstance(gw_uid, int) and isinstance(fx_uid, int) and gw_uid != fx_uid,
             f"gateway/fixture UIDs must be distinct ints, got {gw_uid}/{fx_uid}", errors)
    _require(apks.get("gateway_hash_matched") is True, "gateway APK SHA-256 mismatch on device", errors)
    _require(apks.get("fixture_hash_matched") is True, "fixture APK SHA-256 mismatch on device", errors)

    scenarios = receipts.get("scenarios", {})
    for name in REQUIRED_SCENARIOS:
        _require(name in scenarios, f"missing scenario: {name}", errors)
    if errors:
        return errors

    for name in REQUIRED_SCENARIOS:
        sc = scenarios[name]
        oracle = sc.get("fixture_receipt", {})
        fg = sc.get("foreground_app", {})
        baseline = sc.get("keyboard_state_default", {})
        bounds_resp = sc.get("probe_editor_bounds", {})
        anchor_resp = sc.get("probe_cursor_anchor", {})

        _require(oracle.get("case") == name, f"{name}: fixture case mismatch", errors)
        _require(oracle.get("landscape") is True, f"{name}: expected landscape=true", errors)

        # Every scenario must be pure same-package 2-window (0 Launcher leak!)
        _require(fg.get("window_topology") == "same_app_multi",
                 f"{name}: expected window_topology=same_app_multi, got {fg.get('window_topology')}", errors)
        _require(fg.get("package") == "dev.magina.wechatparity",
                 f"{name}: expected foreground package dev.magina.wechatparity, got {fg.get('package')}", errors)
        app_wins = [w for w in fg.get("windows", []) if w.get("type") == "application"]
        _require(len(app_wins) == 2 and all(w.get("root_package") == "dev.magina.wechatparity" for w in app_wins),
                 f"{name}: expected exactly 2 dev.magina.wechatparity application windows (0 Launcher), got {app_wins}", errors)

        # Default keyboard_state must not emit probe payloads
        _require("ime_editor_bounds" not in baseline and "ime_cursor_anchor" not in baseline,
                 f"{name}: default keyboard_state leaked probe payload", errors)

        if name in ("disjoint_right_dead_end", "disjoint_right_valid_node", "disjoint_right_legacy_1arg", "disjoint_left_dead_end"):
            _require(oracle.get("windows_disjoint") is True, f"{name}: windows must be disjoint", errors)
            _require(oracle.get("layout_width") == -1, f"{name}: expected MATCH_PARENT (-1)", errors)
            _require(oracle.get("duplicate_id_view_count") == 2, f"{name}: expected 2 duplicate-ID views", errors)
            _require(oracle.get("target_a11y_view_id") is None, f"{name}: expected stripped viewId=null", errors)
            _require(oracle.get("target_a11y_focused") is False, f"{name}: expected stripped focused=false", errors)
            _require(oracle.get("target_a11y_visible") is False, f"{name}: expected stripped visible=false", errors)

            # 4B: probe_editor_bounds must fail closed (landscape 2-unnamed-node AnonymousEditorPair stops at
            # same_bounds / focus_conflict without calling IME) AND produce non-short-circuited 2-unnamed-node telemetry
            _require(bounds_resp.get("ime_editor_bounds") is None,
                     f"{name}: probe_editor_bounds should remain fail-closed", errors)
            expected_bounds_reason = "focus_conflict" if name == "disjoint_right_valid_node" else "same_bounds"
            _require(bounds_resp.get("ime_editor_bounds_reason") == expected_bounds_reason,
                     f"{name}: expected probe_editor_bounds {expected_bounds_reason}, got {bounds_resp.get('ime_editor_bounds_reason')}", errors)
            telemetry = bounds_resp.get("ime_editor_node_telemetry", {})
            summary = telemetry.get("field_matches_summary", {})
            _require(summary.get("total_matches") == 2 and summary.get("inspected_matches") == 2,
                     f"{name}: expected 4B inspected_matches=2/2, got {summary}", errors)
            _require(summary.get("unnamed_matches") == 2, f"{name}: expected unnamed_matches=2, got {summary}", errors)

            if name == "disjoint_right_valid_node":
                _require(summary.get("bounds_in_window_matches") == 1,
                         f"{name}: expected 4B bounds_in_window_matches=1, got {summary}", errors)
                _require(summary.get("input_type_matches") == 1,
                         f"{name}: expected 4B input_type_matches=1, got {summary}", errors)
                _require(summary.get("same_as_service_matches") == 1,
                         f"{name}: expected 4B same_as_service_matches=1, got {summary}", errors)
            else:
                _require(summary.get("empty_bounds_matches") == 2 and summary.get("bounds_in_window_matches") == 0,
                         f"{name}: expected 4B dead-end empty_bounds_matches=2/in_window=0, got {summary}", errors)
                _require(summary.get("input_type_matches") == 0,
                         f"{name}: expected 4B dead-end input_type_matches=0, got {summary}", errors)

            # 4A: probe_cursor_anchor must SUCCEED on disjoint pane!
            anchor = anchor_resp.get("ime_cursor_anchor")
            _require(isinstance(anchor, dict), f"{name}: expected non-null ime_cursor_anchor, got {anchor_resp}", errors)
            _require("ime_cursor_anchor_reason" not in anchor_resp, f"{name}: unexpected failure reason", errors)
            if isinstance(anchor, dict):
                expected_pane = "left" if name == "disjoint_left_dead_end" else "right"
                _require(anchor.get("pane") == expected_pane,
                         f"{name}: expected pane={expected_pane}, got {anchor.get('pane')}", errors)
                _require(anchor.get("window_id") == oracle.get("target_window_id"),
                         f"{name}: window_id mismatch {anchor.get('window_id')} vs {oracle.get('target_window_id')}", errors)
                _require(anchor.get("same_package_window_count") == 2 and anchor.get("total_app_window_count") == 2,
                         f"{name}: expected 2/2 app windows, got {anchor.get('same_package_window_count')}/{anchor.get('total_app_window_count')}", errors)

                target_rect = oracle.get("target_rect", [])
                if anchor.get("editor_bounds") is not None:
                    _require(_rect_close(anchor["editor_bounds"], target_rect),
                             f"{name}: editor_bounds {anchor['editor_bounds']} != oracle {target_rect}", errors)
                if anchor.get("insertion_marker") is not None:
                    _require(_marker_in_rect(anchor["insertion_marker"], target_rect),
                             f"{name}: insertion_marker {anchor['insertion_marker']} not inside {target_rect}", errors)
                _require(anchor.get("editor_bounds") is not None or anchor.get("insertion_marker") is not None,
                         f"{name}: must have editor_bounds or insertion_marker", errors)

                if name == "disjoint_right_legacy_1arg":
                    _require(anchor.get("request_mode") == "legacy_1arg",
                             f"{name}: expected request_mode=legacy_1arg, got {anchor.get('request_mode')}", errors)
                    _require(anchor.get("filtered_accepted") is False and anchor.get("legacy_accepted") is True,
                             f"{name}: expected filtered=false, legacy=true", errors)
                    _require(oracle.get("filtered_cursor_requests", 0) >= 1 and oracle.get("legacy_cursor_requests", 0) >= 1,
                             f"{name}: expected both filtered and legacy IC calls recorded", errors)
                else:
                    _require(anchor.get("request_mode") == "filtered_2arg",
                             f"{name}: expected request_mode=filtered_2arg, got {anchor.get('request_mode')}", errors)
                    _require(anchor.get("filtered_accepted") is True, f"{name}: expected filtered_accepted=true", errors)
                    _require(oracle.get("filtered_cursor_requests", 0) >= 1, f"{name}: expected filtered_cursor_requests >= 1", errors)

                if name == "disjoint_right_valid_node":
                    cc = anchor.get("a11y_cross_check", {})
                    _require(cc.get("exact_editor_bounds_matches") == 1 and cc.get("input_type_and_geometry_matches") == 1,
                             f"{name}: expected 4A+4B cross-check match=1, got {cc}", errors)

            if name == "disjoint_right_dead_end":
                origin_resp = sc.get("probe_editor_origin", {})
                _require(origin_resp.get("ime_editor_origin") is None
                         and origin_resp.get("ime_editor_origin_reason") == "no_verified_geometry",
                         f"{name}: expected requestTextBoundsInfo CODE_UNSUPPORTED -> no_verified_geometry, got {origin_resp}", errors)
                _require(oracle.get("text_bounds_requests", 0) >= 1,
                         f"{name}: expected text_bounds_requests >= 1", errors)

        elif name == "overlap_right":
            _require(oracle.get("windows_disjoint") is False, "overlap_right: windows must actually overlap", errors)
            _require(anchor_resp.get("ime_cursor_anchor") is None, "overlap_right: must fail closed", errors)
            _require(anchor_resp.get("ime_cursor_anchor_reason") == "ambiguous_window_overlap",
                     f"overlap_right: expected ambiguous_window_overlap, got {anchor_resp.get('ime_cursor_anchor_reason')}", errors)

        elif name == "type_null_decor":
            _require(bounds_resp.get("ime_editor_bounds") is None
                     and bounds_resp.get("ime_editor_bounds_reason") == "input_type_null",
                     f"type_null_decor: probe_editor_bounds expected input_type_null, got {bounds_resp}", errors)
            _require("ime_editor_missing_id_source" not in bounds_resp,
                     "type_null_decor: must NEVER misreport as missing_id/field_id_unresolved", errors)
            _require(bounds_resp.get("ime_editor_contract_diag", {}).get("input_type_is_null") is True,
                     "type_null_decor: bounds contract diag must report input_type_is_null=true", errors)
            _require(anchor_resp.get("ime_cursor_anchor") is None
                     and anchor_resp.get("ime_cursor_anchor_reason") == "input_type_null",
                     f"type_null_decor: probe_cursor_anchor expected input_type_null, got {anchor_resp}", errors)
            _require(anchor_resp.get("ime_editor_contract_diag", {}).get("input_type_is_null") is True,
                     "type_null_decor: anchor contract diag must report input_type_is_null=true", errors)
            _require(oracle.get("filtered_cursor_requests", 0) == 0 and oracle.get("legacy_cursor_requests", 0) == 0,
                     "type_null_decor: must issue zero requestCursorUpdates calls", errors)

    teardown = receipts.get("teardown", {})
    saved = teardown.get("saved_settings", {})
    restored = teardown.get("restored_settings", {})
    for key in EXPECTED_SETTINGS_KEYS:
        _require(key in saved and key in restored, f"teardown missing setting {key}", errors)
        _require(saved.get(key) == restored.get(key),
                 f"teardown setting mismatch for {key}: saved={saved.get(key)!r} restored={restored.get(key)!r}", errors)
    _require(teardown.get("gateway_uninstalled") is True, "gateway package not uninstalled", errors)
    _require(teardown.get("fixture_uninstalled") is True, "fixture package not uninstalled", errors)
    _require(teardown.get("emulator_stopped") is True, "emulator not stopped", errors)
    _require(teardown.get("isolated_adb_stopped") is True, "isolated adb server not stopped", errors)
    _require(teardown.get("ports_released") is True, "ports not released", errors)
    _require(teardown.get("avd_deleted") is True, "AVD not deleted", errors)
    _require(teardown.get("cleanup_errors") == [], f"cleanup_errors non-empty: {teardown.get('cleanup_errors')}", errors)

    # Ensure zero accidental 32-hex gateway tokens leaked anywhere in receipts (excluding known SHA-256 64-hex digests)
    scrubbed = re.sub(r"[0-9a-fA-F]{64}", "", raw_text)
    scrubbed = re.sub(r"ime\|[0-9a-f]{24}", "", scrubbed)
    _require(HEX32_RE.search(scrubbed) is None, "unexpected 32-hex token pattern found in receipts", errors)

    return errors


def _synthetic_valid_receipts() -> dict[str, Any]:
    def fg() -> dict[str, Any]:
        return {
            "package": "dev.magina.wechatparity",
            "window_topology": "same_app_multi",
            "windows": [
                {"id": 10, "type": "application", "root_package": "dev.magina.wechatparity", "bounds": [0, 108, 842, 972]},
                {"id": 20, "type": "application", "root_package": "dev.magina.wechatparity", "bounds": [858, 108, 2340, 972]},
            ],
        }

    def editor_scenario(name: str, valid_node: bool = False, legacy: bool = False, left: bool = False) -> dict[str, Any]:
        rect = [24, 220, 818, 320] if left else [882, 220, 2316, 320]
        win_id = 10 if left else 20
        pane = "left" if left else "right"
        summary = {
            "total_matches": 2,
            "inspected_matches": 2,
            "unnamed_matches": 2,
            "bounds_in_window_matches": 1 if valid_node else 0,
            "empty_bounds_matches": 1 if valid_node else 2,
            "input_type_matches": 1 if valid_node else 0,
            "same_as_service_matches": 1 if valid_node else 0,
        }
        res: dict[str, Any] = {
            "fixture_receipt": {
                "case": name,
                "landscape": True,
                "windows_disjoint": True,
                "layout_width": -1,
                "duplicate_id_view_count": 2,
                "target_window_id": win_id,
                "target_rect": rect,
                "target_a11y_view_id": None,
                "target_a11y_focused": False,
                "target_a11y_visible": False,
                "text_bounds_requests": 1 if name == "disjoint_right_dead_end" else 0,
                "filtered_cursor_requests": 1,
                "legacy_cursor_requests": 1 if legacy else 0,
            },
            "foreground_app": fg(),
            "keyboard_state_default": {"visible": False, "height": 0},
            "probe_editor_bounds": {
                "ime_editor_bounds": None,
                "ime_editor_bounds_reason": "focus_conflict" if valid_node else "same_bounds",
                "ime_editor_node_telemetry": {"field_matches_summary": summary},
            },
            "probe_cursor_anchor": {
                "ime_cursor_anchor": {
                    "window_id": win_id,
                    "pane": pane,
                    "request_mode": "legacy_1arg" if legacy else "filtered_2arg",
                    "filtered_accepted": False if legacy else True,
                    "legacy_accepted": True if legacy else None,
                    "same_package_window_count": 2,
                    "total_app_window_count": 2,
                    "editor_bounds": None if legacy else {"left": rect[0], "top": rect[1], "right": rect[2], "bottom": rect[3]},
                    "insertion_marker": {"top_x": rect[0] + 16, "top_y": rect[1] + 12, "bottom_x": rect[0] + 16, "bottom_y": rect[3] - 12},
                    "a11y_cross_check": {
                        "exact_editor_bounds_matches": 1 if valid_node else 0,
                        "input_type_and_geometry_matches": 1 if valid_node else 0,
                    },
                },
            },
        }
        if name == "disjoint_right_dead_end":
            res["probe_editor_origin"] = {
                "ime_editor_origin": None,
                "ime_editor_origin_reason": "no_verified_geometry",
            }
        return res

    saved = {k: f"orig_{i}" for i, k in enumerate(EXPECTED_SETTINGS_KEYS)}
    return {
        "environment": {
            "api": "36",
            "qemu": "1",
            "adb_usb_disabled": True,
            "adb_mdns_disabled": True,
            "adb_emu_enabled": True,
            "initial_adb_devices_empty": True,
            "adb_port": 5047,
            "avd_identity_verified": True,
        },
        "apks": {
            "gateway_uid": 10216,
            "fixture_uid": 10217,
            "gateway_hash_matched": True,
            "fixture_hash_matched": True,
        },
        "scenarios": {
            "disjoint_right_dead_end": editor_scenario("disjoint_right_dead_end"),
            "disjoint_right_valid_node": editor_scenario("disjoint_right_valid_node", valid_node=True),
            "disjoint_right_legacy_1arg": editor_scenario("disjoint_right_legacy_1arg", legacy=True),
            "disjoint_left_dead_end": editor_scenario("disjoint_left_dead_end", left=True),
            "overlap_right": {
                "fixture_receipt": {"case": "overlap_right", "landscape": True, "windows_disjoint": False},
                "foreground_app": fg(),
                "keyboard_state_default": {"visible": False, "height": 0},
                "probe_editor_bounds": {"ime_editor_bounds": None, "ime_editor_bounds_reason": "focus_unavailable"},
                "probe_cursor_anchor": {"ime_cursor_anchor": None, "ime_cursor_anchor_reason": "ambiguous_window_overlap"},
            },
            "type_null_decor": {
                "fixture_receipt": {"case": "type_null_decor", "landscape": True, "filtered_cursor_requests": 0, "legacy_cursor_requests": 0},
                "foreground_app": fg(),
                "keyboard_state_default": {"visible": False, "height": 0},
                "probe_editor_bounds": {
                    "ime_editor_bounds": None,
                    "ime_editor_bounds_reason": "input_type_null",
                    "ime_editor_contract_diag": {"input_type_is_null": True},
                },
                "probe_cursor_anchor": {
                    "ime_cursor_anchor": None,
                    "ime_cursor_anchor_reason": "input_type_null",
                    "ime_editor_contract_diag": {"input_type_is_null": True},
                },
            },
        },
        "teardown": {
            "saved_settings": saved,
            "restored_settings": dict(saved),
            "gateway_uninstalled": True,
            "fixture_uninstalled": True,
            "emulator_stopped": True,
            "isolated_adb_stopped": True,
            "ports_released": True,
            "avd_deleted": True,
            "cleanup_errors": [],
        },
    }


def self_test() -> int:
    valid = _synthetic_valid_receipts()
    errs = verify_receipts(valid)
    if errs:
        print(f"SELF-TEST FAIL (valid rejected): {errs}", file=sys.stderr)
        return 1

    mutations = [
        ("launcher_leak", lambda d: d["scenarios"]["disjoint_right_dead_end"]["foreground_app"]["windows"].append(
            {"id": 99, "type": "application", "root_package": "com.google.android.apps.nexuslauncher"})),
        ("overlap_false_pass", lambda d: d["scenarios"]["overlap_right"]["probe_cursor_anchor"].update(
            {"ime_cursor_anchor": {"window_id": 20}, "ime_cursor_anchor_reason": None})),
        ("type_null_misclassified", lambda d: d["scenarios"]["type_null_decor"]["probe_editor_bounds"].update(
            {"ime_editor_bounds_reason": "missing_id", "ime_editor_missing_id_source": "field_id_unresolved"})),
        ("teardown_restore_drift", lambda d: d["teardown"]["restored_settings"].update(
            {"secure:default_input_method": "wrong"})),
        ("port_5037", lambda d: d["environment"].update({"adb_port": 5037})),
        ("token_leak", lambda d: d["environment"].update({"debug": "0123456789abcdef" * 2})),
    ]
    for label, mutate in mutations:
        mutated = copy.deepcopy(valid)
        mutate(mutated)
        m_errs = verify_receipts(mutated)
        if not m_errs:
            print(f"SELF-TEST FAIL (mutation {label} was not caught)", file=sys.stderr)
            return 1

    print(f"SELF-TEST PASS: 1 positive / {len(mutations)} negative mutations caught")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--receipts", type=Path)
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()

    if args.self_test:
        return self_test()
    if not args.receipts:
        parser.error("specify --receipts <path> or --self-test")
    data = json.loads(args.receipts.read_text(encoding="utf-8"))
    errs = verify_receipts(data)
    if errs:
        for e in errs:
            print(f"FAIL: {e}", file=sys.stderr)
        return 1
    print(json.dumps({"verified": True, "scenarios": len(REQUIRED_SCENARIOS)}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
