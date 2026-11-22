"""Compare each natural callback with the synthetic target and the experimental IME."""
import json
import re
import sys
from pathlib import Path


def read(directory, name):
    return json.loads((directory / name).read_text(encoding="utf-8-sig"))


def require(condition, message):
    if not condition:
        raise ValueError(message)


def evaluate(directory):
    oracle = read(directory, "oracle.json")
    ledger = read(directory, "ledger.json")
    raw = (directory / "journal-read.txt").read_text(encoding="utf-8-sig").strip()
    window = read(directory, "observation.json")
    opened, witnessed, closed = (window[k] for k in ("marker_readback_ms", "oracle_read_ms", "journal_read_ms"))
    require(opened <= witnessed and closed - witnessed >= 6000, "observation window incomplete")
    if raw == "ABSENT":
        require(ledger.get("host_observation") == "journal_absent_at_close" and ledger["samples"] == [],
                "empty result lacks a successful private-directory read")
    else:
        require(json.loads(raw) == ledger, "callback journal differs from private-directory read")
    stage = ledger["stage"]
    require(stage in (1, 2), "unexpected stage")
    require(oracle["scenario"] == ("automatic-right" if stage == 1 else "automatic-right-switch"),
            "scenario mismatch")
    require(oracle["settled"] and oracle["status"] == "probe_observed"
            and oracle["windowFocus"] and oracle["landscape"], "target did not settle")
    require(all(oracle[k] == "right" for k in ("focusSide", "connectionSide", "probeSide", "desiredSide")),
            "target focus, connection or delivered probe disagrees")
    require(oracle["rightProbeCount"] == 1 and oracle["rightConnections"] >= 1
            and all(oracle[k] == 0 for k in ("leftProbeCount", "leftConnections", "manual_request_count",
                                             "restartInputCalls", "touchDownCount", "touchUpCount")),
            "unexpected target action or connection")
    start, end = oracle["stageStartUptime"], oracle["stageEndUptime"]
    if stage == 2:
        ready = read(directory, "right-ready.json")
        require(ready["instance"] == oracle["instance"] and ready["rightViewInstance"] == oracle["rightViewInstance"]
                and ready["rightBounds"] == oracle["rightBounds"]
                and 0 < ready["rightConnections"] <= oracle["rightConnections"]
                and ready["rightProbeCount"] == ready["manual_request_count"] == 0
                and ready["focusSide"] == ready["connectionSide"] == "right" and start <= ready["uptime_ms"] < end,
                "right connection before switch unproven")
        start = ready["uptime_ms"]
    ime_log = (directory / "ime.txt").read_text(encoding="utf-8-sig")
    # Format from adb logcat -v threadtime. Uptime is logged by the IME itself.
    starts = [(int(pid), int(gen), int(tick)) for pid, gen, tick in
              re.findall(r"\s(\d+)\s+\d+\s+I\s+SyntheticProbeIme\s*:\s+generation=(\d+) started=(\d+)", ime_log)
              if start < int(tick) <= end]
    require(starts and all(a[2] < b[2] for a, b in zip(starts, starts[1:])),
            "missing or unordered experimental IME connections")
    pid, generation, tick = starts[-1]
    samples = ledger["samples"]
    require(ledger["callback_count"] == ledger["terminal_count"] == len(samples), "incomplete callback journal")
    result = dict(stage=stage, experimental_ime_pid=pid, generation=generation, ime_started_ms=tick,
                  observed_connections=[dict(pid=p, generation=g, started_ms=t) for p, g, t in starts],
                  probe_delivered_by_ms=end, target_right_bounds=oracle["rightBounds"], callback_count=len(samples),
                  observation_ms=closed - opened, observation_after_oracle_ms=closed - witnessed,
                  selected_side=None, selected_bounds=None, verdict="UNKNOWN")
    if stage == 2:
        prior = (directory / "pre-switch-journal.txt").read_text(encoding="utf-8-sig").strip()
        if prior != "ABSENT":
            journal = json.loads(prior)
            require(journal["stage"] == 1 and journal["callback_count"] == journal["terminal_count"]
                    == len(journal["samples"]), "incomplete pre-switch journal")
            for event in journal["samples"]:
                require(event["manual"] is False and event["callback_uptime_ms"] < tick,
                        "pre-switch callback has an inconsistent timestamp or origin")
            result["pre_switch_callbacks"] = [dict(acquired_ms=e["acquisition_start_uptime_ms"],
                                                   callback_ms=e["callback_uptime_ms"], reason=e["reason"])
                                              for e in journal["samples"]]
    if not samples:
        return dict(result, reason="NO_NEW_CALLBACK")
    if len(samples) != 1:
        return dict(result, reason="AMBIGUOUS_CALLBACKS")
    s = samples[0]
    require(s["manual"] is False, "unexpected manual sample")
    result.update(acquired_ms=s["acquisition_start_uptime_ms"], completed_ms=s["acquisition_end_uptime_ms"],
                  callback_ms=s["callback_uptime_ms"], observer_reason=s["reason"])
    if s["verdict"] != "MATCHED":
        require(s["selected_side"] is None and s["selected_bounds"] is None, "selection on rejected sample")
        return dict(result, reason=s["reason"])
    require((s["observer_pid"], s["ime_generation"], s["ime_started_uptime_ms"]) == starts[-1]
            and generation == s["ime_generation_after"] and s["before_current"] and s["after_current"],
            "callback belongs to another connection")
    require(tick < result["acquired_ms"] <= result["completed_ms"] <= result["callback_ms"],
            "acquisition order unresolved")
    require(s["reason"] == "MATCH" and s["editor_count"] == 2 and s["chosen_is_focused"]
            and s["view_id_match_count"] == s["fill_focus_match_count"] == s["focus_count"] == 1
            and s["selected_side"] == s["ime_match_side"] == s["fill_focus_side"] == "RIGHT"
            and s["selected_bounds"] == oracle["rightBounds"], "selection disagrees with target")
    return dict(result, reason="MATCH", verdict="MATCHED", selected_side="RIGHT", selected_bounds=s["selected_bounds"])


if __name__ == "__main__":
    print(json.dumps(evaluate(Path(sys.argv[1])), indent=2))
