"""Check independent target, IME and service records for one explicitly activated synthetic menu experiment."""
import argparse
import json
import re
from pathlib import Path


def verify(log):
    events, results = [], []
    for line in log.splitlines():
        match = re.search(r"(MenuOracle|MenuChoice|MenuFill)\s*\(\s*\d+\): (.*)$", line)
        if not match:
            continue
        source, body = match.groups()
        if body.startswith("result="):
            results.append(json.loads(body[7:]))
        elif body.startswith("event="):
            events.append((source, dict(pair.split("=", 1) for pair in body.split() if "=" in pair)))

    def group(tag, kind):
        return [row for source, row in events if source == tag and row["event"] == kind]

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

    noop, expired, rejected, request, sent = [only(group("MenuChoice", event), event)
        for event in ("noop", "expired", "rejected", "request", "dispatched")]
    need(at(noop) < at(expired) < at(rejected) < at(request) <= at(sent), "choice order")
    need(at(expired) - at(noop) > 1000 and at(request) - at(rejected) > 1000, "control observation window")
    need(at(rejected) - at(expired) > 200 and sent["submitted"] == "true", "expiry or transport")
    generation = request["gen"]
    need(all(row["gen"] == generation for row in (noop, expired, rejected, sent)), "choice connection changed")
    started = int(request["started"])
    need(at(noop) - started >= 1000, "IME not stable")

    entry = only(group("MenuOracle", "connection_menu"), "connection forwarding")
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
    return dict(classification="EXPLICIT_IME_MENU", selected="RIGHT", bounds=bounds, gen=int(generation),
                manual_flags=int(manual["flags"]), issued_ms=int(result["issued_at"]), ime_start_ms=started,
                connection_forward_ms=at(entry), view_forward_ms=at(view), sampled_ms=[int(manual["start"]), int(manual["end"])],
                callback_ms=at(manual), stable_after_ms=end, controls_ms=[at(noop), at(expired), at(rejected)],
                target_menu_or_action_mode_entries=0, new_target_structure_writes=len(fresh), original_ime_natural_callbacks=len(prior))


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


if __name__ == "__main__":
    args = argparse.ArgumentParser(description=__doc__)
    args.add_argument("--stopped-run", action="store_true", help="read directory of a completed readiness stop")
    args.add_argument("input", type=Path)
    options = args.parse_args()
    result = read_stop(options.input) if options.stopped_run else verify(options.input.read_text(encoding="utf-8-sig"))
    print(json.dumps(result, indent=2))
