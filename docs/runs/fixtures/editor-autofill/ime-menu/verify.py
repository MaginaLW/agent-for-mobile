"""Check independent target, IME and service records for the ime-menu A2 experiment suite."""
import argparse
import json
import re
from pathlib import Path


def parse_log(log):
    events, results = [], []
    for line in log.splitlines():
        match = re.search(r"(MenuOracle|MenuChoice|MenuFill)(?:\s*\(\s*\d+\))?:\s*(.*)$", line)
        if not match:
            continue
        source, body = match.groups()
        body = body.strip()
        if body.startswith("result="):
            results.append(json.loads(body[7:]))
        elif body.startswith("event="):
            events.append((source, dict(pair.split("=", 1) for pair in body.split() if "=" in pair)))
    return events, results


def _helpers(events):
    def group(tag, kind):
        return [row for source, row in events if source == tag and row.get("event") == kind]

    def only(rows, label):
        if len(rows) != 1:
            raise ValueError(f"{label}: observed {len(rows)}")
        return rows[0]

    def need(ok, label):
        if not ok:
            raise ValueError(label)

    def at(row):
        return int(row["ms"])

    def interval(rows, low, high):
        return [row for row in rows if low <= at(row) <= high]

    return group, only, need, at, interval


def _check_zero_ui_absence(group, need):
    for ui_event in ("button", "request_show", "create_input_view", "start_input_view", "window_shown"):
        need(not group("MenuChoice", ui_event), f"unexpected visible IME UI event in zero-ui mode: {ui_event}")


def verify_opted_in(log):
    events, results = parse_log(log)
    group, only, need, at, interval = _helpers(events)

    noop, expired, rejected, request, sent = [
        only(group("MenuChoice", event), event)
        for event in ("noop", "expired", "rejected", "request", "dispatched")
    ]
    need(at(noop) < at(expired) < at(rejected) < at(request) <= at(sent), "choice order")
    need(at(expired) - at(noop) > 1000 and at(request) - at(rejected) > 1000, "control observation window")
    need(at(rejected) - at(expired) > 200 and sent["submitted"] == "true", "expiry or transport")
    generation = request["gen"]
    need(all(row["gen"] == generation for row in (noop, expired, rejected, sent)), "choice connection changed")
    started = int(request["started"])
    need(at(noop) - started >= 1000, "IME not stable")

    for row in (noop, expired, rejected, request, sent):
        if "ui_shown" in row:
            need(row["ui_shown"] == "true", "visible menu choice recorded ui_shown!=true")

    buttons = [row for row in group("MenuChoice", "button") if row.get("gen") == generation]
    if buttons:
        seen_names = {row["name"] for row in buttons}
        need({"noop", "expired", "request"}.issubset(seen_names), f"missing visible button receipts: {seen_names}")
        for row in buttons:
            need(int(row["x"]) > 0 and int(row["y"]) > 0, "invalid button coordinates")

    entry = only(group("MenuOracle", "connection_menu"), "connection forwarding")
    if "closed" in entry:
        need(entry["closed"] == "false", "dispatched on closed input connection")
    view = only(group("MenuOracle", "view_menu"), "standard view menu")
    probe = only(interval(group("MenuOracle", "probe"), started, at(noop)), "right connection witness")
    manual = only([row for row in group("MenuFill", "callback") if row["manual"] == "true"], "manual callback")
    result = only(results, "terminal service result")
    end = int(result["settled_at"])
    need(at(request) <= at(entry) <= at(view) <= at(manual) <= end, "forwarding order")
    need(int(result["issued_at"]) < int(manual["start"]) <= int(manual["end"]) <= at(manual), "sample order")
    need(result["manual"] and result["request_id"] == int(manual["id"]) and result["ime_generation"] == int(generation),
         "request identity")
    need(result["before_current"] and result["after_current"] and result["selected_side"] == "RIGHT", "right identity")
    if "ui_shown" in result:
        need(result["ui_shown"] is True, "opted-in result expected ui_shown=true")
    need(not interval(group("MenuOracle", "focus"), started, end), "field focus changed")
    need(not interval(group("MenuOracle", "connect"), at(noop), end), "input connection recreated")
    need(not interval(group("MenuOracle", "structure"), at(noop), at(request) - 1), "control caused structure")
    need(not interval(group("MenuFill", "callback"), at(noop), at(request) - 1), "control caused callback")
    for surface in ("show_context_menu", "action_mode"):
        need(not interval(group("MenuOracle", surface), at(noop), end), "target opened native contextual UI")
    fresh = interval(group("MenuOracle", "structure"), at(view), at(manual))
    need(sorted(row["side"] for row in fresh) == ["left", "right"], "new target structure missing")
    right = only([row for row in fresh if row["side"] == "right"], "right structure")
    witnesses = (probe, entry, view, right)
    need(all(row["side"] == "right" and row["win"] == row["focus"] == "true" for row in witnesses), "target lost focus")
    need(len({(row["instance"], row["connection"]) for row in witnesses}) == 1, "target connection mismatch")
    bounds = list(map(int, right["bounds"].split(",")))
    need(bounds == result["selected_bounds"], "independent bounds mismatch")
    prior = [r for r in group("MenuFill", "callback") if at(r) < started and r["manual"] == "false"]
    need(bool(prior), "missing original IME baseline")

    live_conn = int(entry["connection"])
    latest_created = int(entry.get("latest_created", live_conn))
    return dict(
        scenario="opted-in",
        classification="EXPLICIT_IME_MENU",
        selected="RIGHT",
        bounds=bounds,
        gen=int(generation),
        live_connection=live_conn,
        latest_created_connection=latest_created,
        discarded_creations_tolerated=max(0, latest_created - live_conn),
        visible_buttons_logged=len(buttons),
        manual_flags=int(manual["flags"]),
        issued_ms=int(result["issued_at"]),
        ime_start_ms=started,
        connection_forward_ms=at(entry),
        view_forward_ms=at(view),
        sampled_ms=[int(manual["start"]), int(manual["end"])],
        callback_ms=at(manual),
        stable_after_ms=end,
        controls_ms=[at(noop), at(expired), at(rejected)],
        target_menu_or_action_mode_entries=0,
        new_target_structure_writes=len(fresh),
        original_ime_natural_callbacks=len(prior),
    )


def verify_plain_auto(log):
    events, results = parse_log(log)
    group, only, need, at, interval = _helpers(events)

    sc = only(group("MenuOracle", "scenario"), "scenario header")
    need(sc["name"] == "plain-auto", f"unexpected scenario: {sc['name']}")
    need(sc["left_view_id"] == "-1" and sc["right_view_id"] == "-1", "plain-auto must use anonymous NO_ID editors")
    need(sc["left_class"] == "EditText" and sc["right_class"] == "EditText",
         "plain-auto must use unmodified stock EditText")

    _check_zero_ui_absence(group, need)

    noop, expired, rejected, request, sent = [
        only(group("MenuChoice", event), event)
        for event in ("noop", "expired", "rejected", "request", "dispatched")
    ]
    need(at(noop) < at(expired) < at(rejected) < at(request) <= at(sent), "choice order")
    need(at(expired) - at(noop) > 1000 and at(request) - at(rejected) > 1000, "control observation window")
    need(at(rejected) - at(expired) > 200 and sent["submitted"] == "true", "expiry or transport")
    generation = request["gen"]
    need(all(row["gen"] == generation for row in (noop, expired, rejected, sent)), "choice connection changed")
    need(all(row.get("ui_shown") == "false" for row in (noop, expired, rejected, request, sent)),
         "zero-ui mode reported ui_shown!=false")
    started = int(request["started"])
    need(at(noop) - started >= 1000, "IME not stable")

    starts = [r for r in group("MenuChoice", "start_input") if r.get("gen") == generation]
    start_row = only(starts, "start_input for active gen")
    need(start_row["mode"] == "zero-ui-uncooperative" and start_row["usable"] == "true"
         and start_row["ui_shown"] == "false", "zero-ui start_input mismatch")
    ready = only([r for r in group("MenuChoice", "zero_ui_ready") if r.get("gen") == generation], "zero_ui_ready")
    need(ready["ui_shown"] == "false", "zero_ui_ready reported ui_shown!=false")

    manual = only([row for row in group("MenuFill", "callback") if row["manual"] == "true"], "manual callback")
    result = only(results, "terminal service result")
    end = int(result["settled_at"])
    need(at(request) <= at(manual) <= end, "dispatch/callback order")
    need(int(result["issued_at"]) < int(manual["start"]) <= int(manual["end"]) <= at(manual), "sample order")
    need(result["manual"] and result["request_id"] == int(manual["id"]) and result["ime_generation"] == int(generation),
         "request identity")
    need(result["before_current"] and result["after_current"] and result["selected_side"] == "RIGHT", "right identity")
    need(result.get("ui_shown") is False and result.get("mode") == "zero-ui-uncooperative", "result zero-ui mismatch")
    need(not interval(group("MenuOracle", "focus"), started, end), "field focus changed")
    need(not interval(group("MenuOracle", "action_mode"), at(noop), end), "target opened action mode")
    need(not interval(group("MenuFill", "callback"), at(noop), at(request) - 1), "control caused callback")

    right_layouts = [r for r in interval(group("MenuOracle", "layout"), started, end) if r["side"] == "right"]
    need(not right_layouts, f"zero-ui mode shifted right editor layout: {len(right_layouts)}")

    right_snaps = [r for r in group("MenuOracle", "snapshot") if r["side"] == "right"]
    pre_snaps = [r for r in right_snaps if at(r) < at(request)]
    post_snaps = [r for r in right_snaps if at(r) >= at(manual)]
    need(bool(pre_snaps) and bool(post_snaps), "missing pre- or post-dispatch right snapshots")
    all_snaps = pre_snaps + post_snaps
    need(all(r["focus"] == "true" and r["win"] == "true" for r in all_snaps), "right snapshot lost focus")
    need(len({(r["instance"], r["bounds"]) for r in all_snaps}) == 1, "right instance or bounds shifted")
    bounds = list(map(int, post_snaps[-1]["bounds"].split(",")))
    need(bounds == result["selected_bounds"], "independent snapshot bounds mismatch")

    prior = [r for r in group("MenuFill", "callback") if at(r) < started and r["manual"] == "false"]
    need(bool(prior), "missing original IME baseline")
    return dict(
        scenario="plain-auto",
        classification="ZERO_UI_UNCOOPERATIVE_EDITTEXT",
        selected="RIGHT",
        bounds=bounds,
        gen=int(generation),
        ui_shown=False,
        sig_match=(start_row.get("sig_match") == "true"),
        right_important_for_autofill=int(sc["right_imp"]),
        layout_shifts_during_zero_ui=0,
        manual_flags=int(manual["flags"]),
        issued_ms=int(result["issued_at"]),
        ime_start_ms=started,
        sampled_ms=[int(manual["start"]), int(manual["end"])],
        callback_ms=at(manual),
        stable_after_ms=end,
        controls_ms=[at(noop), at(expired), at(rejected)],
        target_action_mode_entries=0,
        original_ime_natural_callbacks=len(prior),
    )


def verify_optout_no(log):
    events, results = parse_log(log)
    group, only, need, at, interval = _helpers(events)

    sc = only(group("MenuOracle", "scenario"), "scenario header")
    need(sc["name"] == "optout-no", f"unexpected scenario: {sc['name']}")
    need(sc["left_imp"] == "2" and sc["right_imp"] == "2", "optout-no must set IMPORTANT_FOR_AUTOFILL_NO (2)")
    need(sc["left_class"] == "EditText" and sc["right_class"] == "EditText",
         "optout-no must use unmodified stock EditText")

    _check_zero_ui_absence(group, need)

    request = only(group("MenuChoice", "request"), "request")
    sent = only(group("MenuChoice", "dispatched"), "dispatched")
    generation = request["gen"]
    started = int(request["started"])
    need(sent["gen"] == generation and at(request) <= at(sent) and sent["submitted"] == "true", "dispatch integrity")
    need(at(request) - started >= 1000, "IME not stable")
    need(request.get("ui_shown") == "false" and sent.get("ui_shown") == "false", "zero-ui expected")

    start_row = only([r for r in group("MenuChoice", "start_input") if r.get("gen") == generation],
                     "start_input for active gen")
    need(start_row["mode"] == "zero-ui-uncooperative" and start_row["ui_shown"] == "false", "mode mismatch")

    manual_cbs = [row for row in group("MenuFill", "callback") if row["manual"] == "true"]
    right_snaps = [r for r in group("MenuOracle", "snapshot") if r["side"] == "right"]
    post_snaps = [r for r in right_snaps if at(r) > at(sent)]
    need(bool(post_snaps), "missing post-dispatch snapshot")
    end_ms = max([at(post_snaps[-1])] + [int(r["settled_at"]) for r in results])

    need(not interval(group("MenuOracle", "focus"), started, end_ms), "field focus changed")
    need(not interval(group("MenuOracle", "action_mode"), started, end_ms), "target opened action mode")
    need(all(r["focus"] == "true" and r["win"] == "true" and r["imp"] == "2" for r in post_snaps),
         "post snapshot invalid")

    if not manual_cbs:
        need(not results, "result without manual callback")
        classification = "OPTOUT_NO_CALLBACK_SUPPRESSED"
        excluded_nodes = 0
    else:
        need(len(results) == len(manual_cbs), "manual callback/result count mismatch")
        for res in results:
            need(res["verdict"] == "UNKNOWN", f"optout-no must fail closed: {res['verdict']}")
            need(res["reason"] == "TARGET_OPTED_OUT", f"expected TARGET_OPTED_OUT, got {res['reason']}")
            need(res["editor_count"] == 0, f"optout-no leaked editors: {res['editor_count']}")
            need(res.get("excluded_text_nodes", 0) >= 1, "expected excluded_text_nodes >= 1")
            need(res["selected_side"] is None and res["selected_bounds"] is None, "optout-no selected a target")
            need(res.get("ui_shown") is False, "expected ui_shown=false")
        classification = "OPTOUT_NO_OBSERVER_REFUSED"
        excluded_nodes = results[-1]["excluded_text_nodes"]

    return dict(
        scenario="optout-no",
        classification=classification,
        selected=None,
        bounds=None,
        gen=int(generation),
        ui_shown=False,
        sig_match=(start_row.get("sig_match") == "true"),
        manual_callbacks=len(manual_cbs),
        excluded_text_nodes=excluded_nodes,
        target_action_mode_entries=0,
    )


def verify_swallow_ic(log):
    events, results = parse_log(log)
    group, only, need, at, interval = _helpers(events)

    sc = only(group("MenuOracle", "scenario"), "scenario header")
    need(sc["name"] == "swallow-ic", f"unexpected scenario: {sc['name']}")
    _check_zero_ui_absence(group, need)

    request = only(group("MenuChoice", "request"), "request")
    sent = only(group("MenuChoice", "dispatched"), "dispatched")
    generation = request["gen"]
    started = int(request["started"])
    need(sent["gen"] == generation and at(request) <= at(sent) and sent["submitted"] == "true",
         "oneway IPC submit expected true")
    need(at(request) - started >= 1000, "IME not stable")
    need(request.get("ui_shown") == "false" and sent.get("ui_shown") == "false", "zero-ui expected")

    start_row = only([r for r in group("MenuChoice", "start_input") if r.get("gen") == generation],
                     "start_input for active gen")
    need(start_row["mode"] == "zero-ui-uncooperative" and start_row["ui_shown"] == "false", "mode mismatch")

    probe = only(interval(group("MenuOracle", "probe"), started, at(request)), "right probe witness")
    swallowed = only(group("MenuOracle", "swallowed_menu"), "swallowed_menu witness")
    need(at(request) <= at(swallowed), "swallowed_menu before request")
    need(swallowed["side"] == "right" and swallowed["focus"] == "true" and swallowed["win"] == "true",
         "swallowed_menu focus mismatch")
    need(swallowed.get("closed") == "false", "swallowed_menu on closed connection")
    need((probe["instance"], probe["connection"]) == (swallowed["instance"], swallowed["connection"]),
         "probe/swallowed connection mismatch")

    right_snaps = [r for r in group("MenuOracle", "snapshot") if r["side"] == "right"]
    post_snaps = [r for r in right_snaps if at(r) > at(swallowed)]
    need(bool(post_snaps), "missing post-swallow snapshot")
    end_ms = at(post_snaps[-1])

    need(not group("MenuOracle", "view_menu"), "swallowed menu reached TextView")
    need(not interval(group("MenuOracle", "structure"), at(request), end_ms), "swallowed menu triggered structure")
    manual_cbs = [row for row in group("MenuFill", "callback") if row["manual"] == "true"]
    need(not manual_cbs and not results, "swallowed menu produced manual callback or result")
    need(not interval(group("MenuOracle", "focus"), started, end_ms), "field focus changed")
    need(not interval(group("MenuOracle", "action_mode"), started, end_ms), "target opened action mode")
    need(not interval(group("MenuOracle", "show_context_menu"), started, end_ms), "target opened context menu")

    prior = [r for r in group("MenuFill", "callback") if at(r) < started and r["manual"] == "false"]
    need(bool(prior), "missing original IME baseline")
    return dict(
        scenario="swallow-ic",
        classification="SWALLOWED_MENU_FAIL_CLOSED",
        selected=None,
        bounds=None,
        gen=int(generation),
        live_connection=int(swallowed["connection"]),
        latest_created_connection=int(swallowed.get("latest_created", swallowed["connection"])),
        ipc_submitted_true_despite_swallow=True,
        swallowed_menu_ms=at(swallowed),
        manual_callbacks=0,
        view_menu_entries=0,
        original_ime_natural_callbacks=len(prior),
    )


def verify(log, scenario="opted-in"):
    dispatch = {
        "opted-in": verify_opted_in,
        "plain-auto": verify_plain_auto,
        "optout-no": verify_optout_no,
        "swallow-ic": verify_swallow_ic,
    }
    if scenario not in dispatch:
        raise ValueError(f"unknown scenario: {scenario}")
    return dispatch[scenario](log)


def read_stop(directory):
    """Read the host terminal state and final synthetic event poll. No Android access."""
    state = json.loads((directory / "state.json").read_text(encoding="utf-8-sig"))
    logs = sorted(directory.glob("*-fixture-events.stdout.txt"))
    if not logs:
        raise ValueError("missing scoped event poll")
    lines = logs[-1].read_text(encoding="utf-8-sig")
    error = "no_menu_event_event=button name=request"
    if state.get("phase") != "closed" or state.get("status") != "failed" or state.get("error") != error:
        raise ValueError("unexpected host terminal state")
    if not (state["initially_empty"] and state["api"] == "36" and state["hardware"] == "1"
            and len(state["restored"]) == 8 and all(state["restored"].values())
            and all(state["cleanup"].get(k) is True for k in ("ports_released", "emulator_stopped", "isolated_server_stopped"))
            and state["cleanup_errors"] == [] and state["uids"]["observer"] != state["uids"]["target"]):
        raise ValueError("isolation or cleanup incomplete")
    def one(pattern):
        matches = re.findall(pattern, lines)
        if len(matches) != 1:
            raise ValueError(f"expected one match for {pattern!r}, saw {len(matches)}")
        return matches[0]
    received, start, end = map(int, one(r"event=callback id=\d+ manual=false flags=0 ms=(\d+) start=(\d+) end=(\d+)"))
    generation, connected = map(int, one(r"generation=(\d+) started=(\d+)"))
    probed, instance, delivered = map(int, one(r"event=probe ms=(\d+) side=right instance=(\d+) connection=(\d+) focus=true win=true"))
    creations = [(int(t), int(n)) for t, n in re.findall(rf"event=connect ms=(\d+) side=right instance={instance} connection=(\d+) ", lines)]
    before_probe = [n for t, n in creations if end < t <= probed]
    if not (start <= end <= received < connected <= probed and delivered in before_probe
            and delivered != before_probe[-1]):
        raise ValueError("connection or acquisition order changed")
    if re.search(r"event=(?:button|noop|expired|request|dispatched|connection_menu|view_menu)\b|manual=true|result=\{", lines):
        raise ValueError("observed menu path differs from recorded stop")
    if list(directory.glob("*-press-fixture-*.stdout.txt")):
        raise ValueError("unexpected host selection")
    return dict(status="STOPPED_BEFORE_CHOICES", error=error, baseline_sample_ms=[start, end],
                baseline_callback_ms=received, generation=generation, connection_started_ms=connected,
                right_probe_ms=probed, recreated=before_probe, delivered_connection=delivered,
                final_geometry=None, choices_pressed=0, manual_callbacks=0, closed_seconds=state["elapsed_seconds"])


def _self_test():
    def expect_fail(fn, *args, match=None):
        try:
            fn(*args)
        except ValueError as err:
            if match and match not in str(err):
                raise AssertionError(f"expected {match!r} in {err!r}")
            return
        raise AssertionError(f"expected ValueError ({match}) but passed")

    # 1. opted-in PASS including Android 16 #3/#4/#5 BOUND_TO_IMMS discarded-connection churn
    opted_ok = "\n".join([
        "I/MenuFill(10): event=callback id=1 manual=false flags=0 ms=10500 start=10100 end=10102",
        "I/MenuOracle(11): event=connect ms=15000 side=right instance=99 connection=3 latest_created=3 focus=true win=true bounds=2100,32,2300,102",
        "I/MenuOracle(11): event=close ms=15005 side=right instance=99 connection=3 latest_created=3 focus=true win=true bounds=2100,32,2300,102",
        "I/MenuOracle(11): event=connect ms=15010 side=right instance=99 connection=4 latest_created=4 focus=true win=true bounds=2100,32,2300,102",
        "I/MenuOracle(11): event=connect ms=15012 side=right instance=99 connection=5 latest_created=5 focus=true win=true bounds=2100,32,2300,102",
        "I/MenuOracle(11): event=probe ms=15020 side=right instance=99 connection=4 latest_created=5 focus=true win=true bounds=2100,32,2300,102 closed=false",
        "I/MenuChoice(10): event=button name=noop gen=1 x=700 y=1010 w=180 h=96 why=window_shown_250",
        "I/MenuChoice(10): event=button name=expired gen=1 x=1050 y=1010 w=220 h=96 why=window_shown_250",
        "I/MenuChoice(10): event=button name=request gen=1 x=1500 y=1010 w=420 h=96 why=window_shown_250",
        "I/MenuChoice(10): event=noop ms=16200 gen=1 started=15015 ui_shown=true",
        "I/MenuChoice(10): event=expired ms=17400 gen=1 started=15015 ui_shown=true",
        "I/MenuChoice(10): event=rejected ms=17750 gen=1 expired=true ui_shown=true",
        "I/MenuChoice(10): event=request ms=18900 gen=1 started=15015 ui_shown=true",
        "I/MenuChoice(10): event=dispatched ms=18902 gen=1 submitted=true ui_shown=true",
        "I/MenuOracle(11): event=connection_menu ms=18904 side=right instance=99 connection=4 latest_created=5 focus=true win=true bounds=2100,32,2300,102 closed=false",
        "I/MenuOracle(11): event=view_menu ms=18905 side=right instance=99 connection=4 latest_created=5 focus=true win=true bounds=2100,32,2300,102",
        "I/MenuOracle(11): event=structure ms=18920 side=left instance=88 connection=0 latest_created=0 focus=false win=true bounds=40,32,240,102",
        "I/MenuOracle(11): event=structure ms=18921 side=right instance=99 connection=4 latest_created=5 focus=true win=true bounds=2100,32,2300,102",
        "I/MenuFill(10): event=callback id=2 manual=true flags=1 ms=18940 start=18918 end=18922",
        'I/MenuFill(10): result={"verdict":"MATCHED","reason":"MATCH","before_current":true,"after_current":true,"selected_side":"RIGHT","selected_bounds":[2100,32,2300,102],"ime_generation":1,"request_id":2,"issued_at":18901,"manual":true,"settled_at":19042,"excluded_text_nodes":0,"mode":"visible-opted-in","ui_shown":true}',
    ])
    res_opted = verify(opted_ok, "opted-in")
    assert res_opted["live_connection"] == 4 and res_opted["latest_created_connection"] == 5
    assert res_opted["discarded_creations_tolerated"] == 1 and res_opted["bounds"] == [2100, 32, 2300, 102]

    # Negative tests for opted-in
    expect_fail(verify, opted_ok.replace("start=18918", "start=18901"), "opted-in", match="sample order")
    expect_fail(verify, opted_ok.replace("connection=4 latest_created=5 focus=true win=true bounds=2100,32,2300,102 closed=false\nI/MenuOracle(11): event=view_menu",
                "connection=5 latest_created=5 focus=true win=true bounds=2100,32,2300,102 closed=false\nI/MenuOracle(11): event=view_menu"),
                "opted-in", match="target connection mismatch")
    expect_fail(verify, opted_ok + "\nI/MenuOracle(11): event=action_mode ms=18910 side=right instance=99 connection=4 latest_created=5 focus=true win=true bounds=2100,32,2300,102",
                "opted-in", match="native contextual UI")
    expect_fail(verify, opted_ok + "\nI/MenuOracle(11): event=focus ms=18000 side=right instance=99 connection=4 latest_created=5 focus=true win=true bounds=2100,32,2300,102",
                "opted-in", match="field focus changed")
    expect_fail(verify, opted_ok.replace("[2100,32,2300,102]", "[2101,32,2300,102]"), "opted-in", match="bounds mismatch")

    # 2. plain-auto PASS (zero opt-in, stock EditText, zero-UI IME, different signing key)
    plain_ok = "\n".join([
        "I/MenuOracle(21): event=scenario ms=10000 name=plain-auto left_imp=1 right_imp=1 left_view_id=-1 right_view_id=-1 left_class=EditText right_class=EditText",
        "I/MenuFill(20): event=callback id=1 manual=false flags=0 ms=10400 start=10100 end=10102",
        "I/MenuOracle(21): event=snapshot ms=10500 side=right instance=77 connection=0 latest_created=0 focus=true win=true bounds=2100,32,2300,102 tag=initial imp=1",
        "I/MenuChoice(20): event=start_input ms=15015 gen=1 restarting=false mode=zero-ui-uncooperative usable=true ui_shown=false sig_match=false",
        "I/MenuChoice(20): event=zero_ui_ready ms=15016 gen=1 started=15015 ui_shown=false sig_match=false",
        "I/MenuChoice(20): event=noop ms=16200 gen=1 started=15015 ui_shown=false",
        "I/MenuChoice(20): event=expired ms=17400 gen=1 started=15015 ui_shown=false",
        "I/MenuChoice(20): event=rejected ms=17750 gen=1 expired=true ui_shown=false",
        "I/MenuChoice(20): event=request ms=18900 gen=1 started=15015 ui_shown=false",
        "I/MenuChoice(20): event=dispatched ms=18902 gen=1 submitted=true ui_shown=false",
        "I/MenuFill(20): event=callback id=2 manual=true flags=1 ms=18940 start=18918 end=18922",
        'I/MenuFill(20): result={"verdict":"MATCHED","reason":"MATCH","before_current":true,"after_current":true,"selected_side":"RIGHT","selected_bounds":[2100,32,2300,102],"ime_generation":1,"request_id":2,"issued_at":18901,"manual":true,"settled_at":19042,"excluded_text_nodes":0,"mode":"zero-ui-uncooperative","ui_shown":false}',
        "I/MenuOracle(21): event=snapshot ms=19200 side=right instance=77 connection=0 latest_created=0 focus=true win=true bounds=2100,32,2300,102 tag=requested imp=1",
    ])
    res_plain = verify(plain_ok, "plain-auto")
    assert res_plain["ui_shown"] is False and res_plain["sig_match"] is False and res_plain["bounds"] == [2100, 32, 2300, 102]
    expect_fail(verify, plain_ok + "\nI/MenuChoice(20): event=window_shown ms=15100 gen=1 ui_shown=true",
                "plain-auto", match="unexpected visible IME UI")
    expect_fail(verify, plain_ok + "\nI/MenuOracle(21): event=layout ms=16000 side=right instance=77 connection=0 latest_created=0 focus=true win=true bounds=2100,40,2300,110",
                "plain-auto", match="shifted right editor layout")

    # 3. optout-no PASS (observer refuses even if FLAG_MANUAL_REQUEST delivers excluded nodes)
    optout_ok = "\n".join([
        "I/MenuOracle(31): event=scenario ms=10000 name=optout-no left_imp=2 right_imp=2 left_view_id=-1 right_view_id=-1 left_class=EditText right_class=EditText",
        "I/MenuOracle(31): event=snapshot ms=10500 side=right instance=66 connection=0 latest_created=0 focus=true win=true bounds=2100,32,2300,102 tag=initial imp=2",
        "I/MenuChoice(30): event=start_input ms=15015 gen=1 restarting=false mode=zero-ui-uncooperative usable=true ui_shown=false sig_match=false",
        "I/MenuChoice(30): event=request ms=16500 gen=1 started=15015 ui_shown=false",
        "I/MenuChoice(30): event=dispatched ms=16502 gen=1 submitted=true ui_shown=false",
        "I/MenuFill(30): event=callback id=1 manual=true flags=1 ms=16540 start=16518 end=16522",
        'I/MenuFill(30): result={"verdict":"UNKNOWN","reason":"TARGET_OPTED_OUT","editor_count":0,"before_current":true,"after_current":true,"selected_side":null,"selected_bounds":null,"ime_generation":1,"request_id":1,"issued_at":16501,"manual":true,"settled_at":16642,"excluded_text_nodes":2,"mode":"zero-ui-uncooperative","ui_shown":false}',
        "I/MenuOracle(31): event=snapshot ms=16900 side=right instance=66 connection=0 latest_created=0 focus=true win=true bounds=2100,32,2300,102 tag=requested imp=2",
    ])
    res_optout = verify(optout_ok, "optout-no")
    assert res_optout["classification"] == "OPTOUT_NO_OBSERVER_REFUSED" and res_optout["selected"] is None
    expect_fail(verify, optout_ok.replace('"verdict":"UNKNOWN","reason":"TARGET_OPTED_OUT","editor_count":0',
                '"verdict":"MATCHED","reason":"MATCH","editor_count":2').replace('"selected_side":null', '"selected_side":"RIGHT"'),
                "optout-no", match="must fail closed")

    # 4. swallow-ic PASS (oneway IPC returns submitted=true, target swallows, 0 manual callbacks)
    swallow_ok = "\n".join([
        "I/MenuOracle(41): event=scenario ms=10000 name=swallow-ic left_imp=1 right_imp=1 left_view_id=-1 right_view_id=-1 left_class=TrackedEditor right_class=TrackedEditor",
        "I/MenuFill(40): event=callback id=1 manual=false flags=0 ms=10400 start=10100 end=10102",
        "I/MenuChoice(40): event=start_input ms=15015 gen=1 restarting=false mode=zero-ui-uncooperative usable=true ui_shown=false sig_match=false",
        "I/MenuOracle(41): event=probe ms=15020 side=right instance=55 connection=4 latest_created=5 focus=true win=true bounds=2100,32,2300,102 closed=false",
        "I/MenuChoice(40): event=request ms=16500 gen=1 started=15015 ui_shown=false",
        "I/MenuChoice(40): event=dispatched ms=16502 gen=1 submitted=true ui_shown=false",
        "I/MenuOracle(41): event=swallowed_menu ms=16505 side=right instance=55 connection=4 latest_created=5 focus=true win=true bounds=2100,32,2300,102 closed=false",
        "I/MenuOracle(41): event=snapshot ms=18500 side=right instance=55 connection=4 latest_created=5 focus=true win=true bounds=2100,32,2300,102 tag=requested imp=1",
    ])
    res_swallow = verify(swallow_ok, "swallow-ic")
    assert res_swallow["classification"] == "SWALLOWED_MENU_FAIL_CLOSED" and res_swallow["manual_callbacks"] == 0
    expect_fail(verify, swallow_ok + "\nI/MenuOracle(41): event=view_menu ms=16506 side=right instance=55 connection=4 latest_created=5 focus=true win=true bounds=2100,32,2300,102",
                "swallow-ic", match="reached TextView")
    expect_fail(verify, swallow_ok + "\nI/MenuFill(40): event=callback id=2 manual=true flags=1 ms=16540 start=16518 end=16522",
                "swallow-ic", match="produced manual callback")

    return {
        "self_test": "PASSED",
        "positive_scenarios": 4,
        "negative_assertions": 10,
        "samples": {
            "opted-in": res_opted["classification"],
            "plain-auto": res_plain["classification"],
            "optout-no": res_optout["classification"],
            "swallow-ic": res_swallow["classification"],
        },
    }


if __name__ == "__main__":
    args = argparse.ArgumentParser(description=__doc__)
    args.add_argument("--stopped-run", action="store_true", help="read directory of a completed readiness stop")
    args.add_argument("--self-test", action="store_true", help="run offline verifier unit tests")
    args.add_argument("--scenario", default="opted-in",
                      choices=("opted-in", "plain-auto", "optout-no", "swallow-ic"))
    args.add_argument("input", type=Path, nargs="?")
    options = args.parse_args()
    if options.self_test:
        result = _self_test()
    else:
        if options.input is None:
            args.error("input path is required unless --self-test is given")
        result = (read_stop(options.input) if options.stopped_run
                  else verify(options.input.read_text(encoding="utf-8-sig"), scenario=options.scenario))
    print(json.dumps(result, indent=2))
