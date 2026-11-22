"""Read the retained-session A2 journals, ART traces, and system state from one isolated run."""
import json
import re
import sys
from pathlib import Path

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import count_focus_methods
from verify_right_first import evaluate, read, require


def one_file(directory, pattern):
    matches = list(directory.glob(pattern))
    require(len(matches) == 1, f"expected exactly one {pattern}")
    return matches[0].read_text(encoding="utf-8-sig")


def activity_session(directory, phase):
    dump = one_file(directory, f"*-activity-{phase}.stdout.txt")
    matches = re.findall(r"AutofillManager:\s+sessionId: (\d+)\s+state: (\w+)", dump)
    require(len(matches) == 1, f"ambiguous {phase} activity")
    return matches[0]


def regular_service_state(directory, phase, session):
    dump = one_file(directory, f"*-system-{phase}.stdout.txt")
    sessions = re.findall(r" - id=(\d+) uid=\d+ a=\{dev\.magina\.autofilltarget/[^}]+\}"
                          r" s=dev\.magina\.autofillobserver\b", dump)
    blocks = [b for b in re.findall(r"^    #\d+\n((?:      [^\n]*\n)+)", dump, re.M)
              if b.startswith(f"      id: {session}\n")]
    require(len(blocks) == 1, f"{phase}: expected the client's one server session")
    block = blocks[0]
    require("state: STATE_ACTIVE" in block and "mDestroyed: false" in block
            and "mComponentName: ComponentInfo{dev.magina.autofilltarget/dev.magina.autofilltarget.TargetActivity}" in block,
            f"{phase}: target session is inactive or belongs to another Activity")
    requests = re.findall(r"^        #\d+: req=(\d+), [^\n]*PKG=dev\.magina\.autofilltarget, "
                          r"SERVICE=dev\.magina\.autofillobserver,", block, re.M)
    responses = re.findall(r"#\d+ FillResponse : \[mRequestId=(\d+), datasets=\[\], saveInfo="
                           r"SaveInfo: \[type=GENERIC, requiredIds=null,[^\n]*?flags=6\]", block)
    require(len(requests) == 1 and requests == responses and "      mSessionLogs: 1\n" in block
            and "      mResponses: 1\n" in block, f"{phase}: request history and retained response disagree")
    return sessions, int(responses[0])


def summarize(directory):
    session, before = activity_session(directory, "before")
    after_session, after = activity_session(directory, "after")
    require(before == after == "ACTIVE" and after_session == session, "retained session not proven")
    regular = regular_service_state(directory, "before", session)
    require(regular == regular_service_state(directory, "after", session) and regular[0] == [session],
            "regular session or retained response changed")
    a2 = evaluate(directory / "A2")
    oracle = read(directory / "A2", "oracle.json")
    control = read(directory / "control", "oracle.json")
    require(control["instance"] != oracle["instance"] and control["settled"]
            and control["probeSide"] == "right" and control["manual_request_count"] == 0,
            "fresh Activity control missing")
    ledger = read(directory / "control", "natural-1.json")
    require(ledger["callback_count"] == ledger["terminal_count"] == len(ledger["samples"]) == 1,
            "natural control did not yield a single structure")
    positive = ledger["samples"][0]
    require(positive["manual"] is False, "control issued a manual request")
    require(positive["verdict"] == "MATCHED" and positive["reason"] == "MATCH"
            and positive["selected_side"] == "RIGHT" and positive["selected_bounds"] == control["rightBounds"]
            and positive["before_current"] and positive["after_current"]
            and isinstance(positive["ime_generation"], int) and positive["ime_generation"] > 0
            and positive["ime_generation"] == positive["ime_generation_after"]
            and positive["ime_started_uptime_ms"] < positive["acquisition_start_uptime_ms"]
            <= positive["acquisition_end_uptime_ms"] <= positive["callback_uptime_ms"],
            "positive control did not match the current generation and independent right geometry")

    editor = "dev.magina.autofilltarget.TargetActivity$Editor"
    count_focus_methods.SELECTED[editor] = ("onCreateInputConnection", "onProvideAutofillStructure")
    traces = {phase: count_focus_methods.summarize(directory / f"{phase}.trace")
              for phase in ("switch", "control")}
    require(traces["control"]["entries"][editor]["onProvideAutofillStructure"] > 0,
            "target structure trace has no positive control")
    log = one_file(directory, "framework-trace.log")
    initial, switch_mark, rest = log.partition("A2Bench : switch_now")
    switch, close_mark, later = rest.partition("A2Bench : switch_closed")
    require(switch_mark and close_mark, "switch interval not delimited")
    require("UNEXPECTED_SAVE" not in log, "unexpected save callback")
    system_pid = read(directory, "state.json")["system_pid"]
    system_lines = [s for s in switch.splitlines() if re.search(rf"\s{system_pid}\s+\d+\s+[A-Z]\s", s)]
    structural = [s for s in system_lines if "Requesting structure for request" in s]
    dispatches = [s for s in system_lines if "calling onFillRequest() for id=" in s]
    require(not structural and not dispatches and a2["callback_count"] == 0
            and traces["switch"]["entries"][editor]["onProvideAutofillStructure"] == 0
            and a2["reason"] == "NO_NEW_CALLBACK" and a2["verdict"] == "UNKNOWN",
            "switch did not reproduce zero requests, target writes, dispatches and callbacks")
    replies = [dict(stage=int(s), request_id=int(i), inline=inline == "true", flags=int(flags),
                    uptime_ms=int(t)) for s, i, inline, flags, t in re.findall(
        r"RetainedReply: reply stage=(\d+) request=(\d+) inline=(true|false) requestedFlags=(\d+) uptime=(\d+)", log)]
    require(len(replies) == 2 and replies[0]["request_id"] == regular[1]
            and replies[0]["request_id"] != replies[1]["request_id"], "response attribution missing")
    require(all(r["stage"] == 1 and r["flags"] == 6 for r in replies)
            and not replies[0]["inline"] and replies[1]["inline"]
            and "RetainedReply: ime_created_inline " not in switch
            and later.count("RetainedReply: ime_created_inline ") == 1, "inline control missing")
    for segment, reply in zip((initial, later), replies):
        request_id = reply["request_id"]
        require(f"requestId={request_id}," in segment and f"calling onFillRequest() for id={request_id}" in segment,
                "no corresponding framework structure request and service dispatch")
    # Closing the measured window and starting the fresh Activity are separate. A later event
    # on the original session can reveal the private flag, with its own timestamp and action.
    def expiry_updates(segment):
        return [dict(log_monotonic_seconds=t, action=action, expired=value == "true")
                for t, action, value in re.findall(rf"^\s*([\d.]+)\s+{system_pid}\s+\d+[^\n]+?"
                    rf"id={session}, action=(\w+),[^\n]+?mExpiredResponse=(true|false)", segment, re.M)]
    expiry_before, expiry_in_switch, expiry_after = map(expiry_updates, (initial, switch, later))
    require(any(e["action"] == "START_SESSION" and not e["expired"] for e in expiry_before)
            and expiry_after and expiry_after[0]["action"] == "VIEW_EXITED" and expiry_after[0]["expired"],
            "missing before/after response-expiry evidence for the retained session")
    return dict(session=session, client_before=before, client_after=after, A2=a2,
                retained_request_id=regular[1], structure_requests_in_switch=len(structural),
                service_dispatches_in_switch=len(dispatches), target_oracle_structure_writes=[
                    oracle["leftStructureWrites"], oracle["rightStructureWrites"]],
                target_trace_structure_writes={p: t["entries"][editor]["onProvideAutofillStructure"]
                                               for p, t in traces.items()},
                inline_requests_created_by_test_ime=log.count("RetainedReply: ime_created_inline "),
                responses=replies, expiry_before=expiry_before,
                expiry_in_switch=expiry_in_switch, expiry_after_window=expiry_after,
                control=dict(verdict=positive["verdict"], reason=positive["reason"],
                             side=positive["selected_side"], bounds=positive["selected_bounds"]),
                trace_sha256={p: t["sha256"] for p, t in traces.items()})


if __name__ == "__main__":
    print(json.dumps(summarize(Path(sys.argv[1])), indent=2))
