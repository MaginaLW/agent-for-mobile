"""复核只含合成应用的 AVD 采样。运行时判定不读取靶应用的 oracle.json。"""
import argparse
from copy import deepcopy
import json
from pathlib import Path
import re


PKG = "dev.magina.autofilltarget"
COMPONENT = PKG + "/" + PKG + ".TargetActivity"
WINDOW = r"Window\{([0-9a-f]+) u0 [^}\n]+\}"
ACTIVITY = r"ActivityRecord\{([^}\n]+)\}"
CLIENT = r"android\.os\.BinderProxy@([0-9a-f]+)"
PHASES = ("before-windows", "before-displays", "accessibility-before", "release", "callback",
          "session1", "during-windows", "during-displays", "session2", "accessibility",
          "after-windows", "after-displays", "close")


class Refused(ValueError):
    pass


def need(ok, reason):
    if not ok:
        raise Refused(reason)


def one(pattern, text, reason):
    rows = re.findall(pattern, text, re.MULTILINE)
    need(len(rows) == 1, reason)
    return rows[0]


def session(text, origin):
    # 只接受同一条活跃 session 记录内的请求；历史记录及其他会话不能补字段。
    blocks = re.split(r"(?m)^    #\d+\s*$", text)[1:]
    blocks = [b.split("mShowingSaveUi:", 1)[0] for b in blocks
              if re.search(rf"(?m)^      id: {origin['session']}$", b)]
    need(bool(blocks), "SESSION_ABSENT")
    need(len(blocks) == 1, "SESSION_NOT_UNIQUE")
    row = blocks[0]
    need("state: STATE_ACTIVE" in row and "mDestroyed: false" in row
         and f"mComponentName: ComponentInfo{{{COMPONENT}}}" in row, "SESSION_CONTEXT")
    requests = re.findall(r"(?m)^        #\d+: req=(\d+), log=", row)
    need(requests == [str(origin["request"])], "REQUEST_NOT_UNIQUE")
    need(f"mCurrentViewId: {origin['trigger_view']}@{origin['session']}\n" in row, "SESSION_FIELD")
    token, activity = one(r"mActivityToken: Token\{([0-9a-f]+) " + ACTIVITY + r"\}", row, "ACTIVITY_TOKEN")
    return token, activity, int(one(r"^      taskId: (\d+)$", row, "TASK"))


def window(windows, displays, activity, task):
    blocks = list(re.finditer(r"(?m)^  Window #\d+ " + WINDOW + ":$", windows))
    owned = []
    children = []
    for idx, match in enumerate(blocks):
        end = blocks[idx + 1].start() if idx + 1 < len(blocks) else len(windows)
        body = windows[match.end():end]
        children.extend(re.findall(r"mParentWindow=" + WINDOW, body))
        if f"mActivityRecord=ActivityRecord{{{activity}}}\n" in body:
            owned.append((match[1], body))
    need(len(owned) == 1 and owned[0][0] not in children, "ACTIVITY_WINDOW_AMBIGUOUS")
    wid, body = owned[0]
    need(" ty=BASE_APPLICATION " in body and "isVisible=true" in body
         and f" package={PKG} " in body and f"mDisplayId=0 taskId={task} " in body, "WINDOW_STATE")
    need(one(r"^  mCurrentFocus=" + WINDOW + "$", displays, "ACTIVE_FOCUS") == wid
         and one(r"^  imeInputTarget in display# 0 " + WINDOW + "$", windows, "IME_TARGET") == wid
         and one(r"^  mFocusedApp=" + ACTIVITY + "$", displays, "FOCUSED_ACTIVITY") == activity,
         "WRONG_WINDOW")
    frame = one(r" frame=\[(-?\d+),(-?\d+)\]\[(-?\d+),(-?\d+)\]", body, "WINDOW_FRAME")
    client = one(r" mClient=" + CLIENT + "$", body, "WINDOW_CLIENT")
    need(re.findall(r"(?m)^    mDisplayId=[^\n]+ mClient=" + CLIENT + "$", windows).count(client) == 1,
         "WINDOW_CLIENT_AMBIGUOUS")
    return wid, client, tuple(map(int, frame))


def accessibility(text, client, task):
    matches = re.findall(r"(?m)^A11yWindow\[(.+)\]\nWindowInfo\[(.+)\]$", text)
    rows = [(a, w) for a, w in matches if f"token=android.os.BinderProxy@{client}," in w]
    need(len(rows) == 1, "ACCESSIBILITY_TOKEN")
    a, w = rows[0]
    need(f"taskId={task}, type=1," in w and f"taskId={task}, type=TYPE_APPLICATION," in a
         and "displayId=0," in a and "displayId=0," in w and "focused=true," in w
         and "focused=true, active=true," in a, "ACCESSIBILITY_FOCUS")
    return int(one(r", id=(\d+),", a, "ACCESSIBILITY_ID"))


def read_frame(path):
    sections = re.split(r"(?m)^## ([\w-]+)\n", (path / "snapshots.txt").read_text(encoding="utf8"))
    keys = sections[1::2]
    need(tuple(keys) == PHASES, "CAPTURE_ORDER")
    frame = dict(zip(keys, sections[2::2]))
    frame["origin"] = json.loads((path / "origin.json").read_text(encoding="utf8"))
    frame["result"] = json.loads((path / "result.json").read_text(encoding="utf8"))
    return frame


def decide(frame, expected_window=None):
    try:
        o, r = frame["origin"], frame["result"]
        need(o == json.loads(frame["callback"].splitlines()[1]), "CALLBACK_REPLACED")
        # /proc/uptime 的两位小数截断到 10 ms；这两场连续运行的模拟器期间没有休眠。
        times = {}
        for phase in PHASES:
            stamp = re.fullmatch(r"(\d+)\.(\d{2})\s+\d+\.\d{2}", frame[phase].splitlines()[0])
            need(stamp, "MISSING_TIMESTAMP")
            times[phase] = int(stamp[1]) * 1000 + int(stamp[2]) * 10
        need(list(times.values()) == sorted(times.values()), "CAPTURE_ORDER")
        need(times["release"] <= o["acquired"] <= o["received"] < times["callback"] + 10, "STALE_COLLECTION")
        need(o["windows"] == 1 and o["display"] == 0 and o["request"] == o["context"]
             and o["session"] == o["trigger_session"] != 0 and o["trigger_view"] == o["ime_view"]
             and 0 < o["started"] < o["acquired"] <= o["completed"] <= o["received"], "STALE_OR_CONFLICT")
        need(r["verdict"] == "MATCHED" and r["before_current"] is True and r["after_current"] is True
             and r["editor_count"] == 2 and r["match_count"] == r["focus_count"] == r["fill_focus_match_count"] == 1,
             "EDITOR_NOT_VERIFIED")
        matches = [n["bounds"] for n in r["candidates"] if n["native_matches_ime"] and n["native_matches_fill"]
                   and n["focused"] and n["id_in_session"]]
        need(matches == [r["selected_bounds"]] and r["selected_side"] in ("LEFT", "RIGHT")
             and r["selected_side"] == r["ime_match_side"] == r["fill_focus_side"], "EDITOR_CONFLICT")
        token, activity, task = session(frame["session1"], o)
        need((token, activity, task) == session(frame["session2"], o), "SESSION_CHANGED")
        checks = [window(frame[t + "-windows"], frame[t + "-displays"], activity, task)
                  for t in ("before", "during", "after")]
        need(checks[0] == checks[1] == checks[2], "WINDOW_CHANGED")
        wid, client, bounds = checks[0]
        aid = accessibility(frame["accessibility-before"], client, task)
        need(aid == accessibility(frame["accessibility"], client, task), "ACCESSIBILITY_CHANGED")
        active = [a["id"] for a in o["accessibility"] if a["display"] == 0 and a["active"] and a["focused"]]
        need(active == [aid] and (expected_window is None or aid == expected_window), "WRONG_WINDOW")
        left, top, right, bottom = r["selected_bounds"]
        need(bounds[0] <= left < right <= bounds[2] and bounds[1] <= top < bottom <= bounds[3], "BOUNDS")
        return {"reason": "MATCH", "window": aid, "side": r["selected_side"], "bounds": [left, top, right, bottom]}
    except (KeyError, IndexError, TypeError, ValueError) as error:
        return {"reason": str(error) if isinstance(error, Refused) else "MISSING_EVIDENCE",
                "window": None, "side": None, "bounds": None}


def verify_pair(stages):
    frames = [stage["frame"] for stage in stages]
    rows = {}
    witnesses = []
    for name, stage in zip(("first", "second"), stages, strict=True):
        f = stage["frame"]
        result = decide(f)
        # 判定封口后，才读靶的独立参照。
        truth = stage["oracle"]
        need(truth["settled"] and truth["windowFocus"] and truth["manual_request_count"] == 1
             and truth["connectionSide"] == truth["probeSide"] == "right"
             and truth["leftProbeCount"] == 0 and truth["rightProbeCount"] == 1, "TARGET_REFERENCE")
        need(result == {"reason": "MATCH", "window": truth["oracleAccessibilityWindow"], "side": "RIGHT",
                        "bounds": truth["rightBounds"]}, f"{name}: {result}")
        rows[name] = result
        witnesses.append(truth)
    first, second = frames
    need(witnesses[0]["instance"] != witnesses[1]["instance"] and witnesses[0]["oracleTaskId"] != witnesses[1]["oracleTaskId"]
         and rows["first"]["window"] != rows["second"]["window"] and rows["first"]["bounds"] == rows["second"]["bounds"]
         and first["origin"]["trigger_view"] == second["origin"]["trigger_view"]
         and first["origin"]["session"] != second["origin"]["session"], "DISTINCT_SOURCES")
    rows["first-source-wrong-window"] = decide(first, expected_window=rows["second"]["window"])
    rows["second-source-wrong-window"] = decide(second, expected_window=rows["first"]["window"])
    need(all(rows[name]["reason"] == "WRONG_WINDOW" for name in
             ("first-source-wrong-window", "second-source-wrong-window")), "CROSS_WINDOW_NOT_DISTINGUISHED")
    def exchange_body(phase):
        return second[phase].split("\n", 1)[0] + "\n" + first[phase].split("\n", 1)[1]

    cases = {"old-callback": {"origin": first["origin"], "callback": exchange_body("callback")},
             "request-replaced": {"origin": first["origin"]}, "session-missing": {"session1": second["session1"].splitlines()[0]},
             "focus-changed": {"after-displays": exchange_body("after-displays")},
             "accessibility-replaced": {"accessibility": exchange_body("accessibility")}}
    for name, replacement in cases.items():
        rows[name] = decide({**second, **replacement})
    # 同一 Activity 若附加第二个窗口，保持其它输入原样，不能挑一个符合焦点的窗口冒充来源。
    ambiguous = deepcopy(second)
    body = one(r"(?ms)(^  Window #\d+ Window\{[^}]+\}:\n(?:(?!^  Window #).)*?"
               r"mActivityRecord=ActivityRecord\{" + re.escape(session(second["session1"], second["origin"])[1])
               + r"\}\n)", second["before-windows"], "COUNTEREXAMPLE_SOURCE")
    other_window = re.sub(r"Window #\d+ Window\{[0-9a-f]+ ", "Window #99 Window{fffa111 ", body, count=1)
    ambiguous["before-windows"] += "\n" + re.sub(CLIENT, "android.os.BinderProxy@fffa222", other_window, count=1)
    rows["multiple-windows-one-activity"] = decide(ambiguous)
    duplicate = deepcopy(second)
    client_line = one(r"(?m)^(    mDisplayId=[^\n]+ mClient=android\.os\.BinderProxy@[0-9a-f]+)$", body,
                      "COUNTEREXAMPLE_CLIENT")
    duplicate["before-windows"] += "\n  Window #99 Window{fffa111 u0 extra}:\n" + client_line + "\n"
    rows["duplicate-client"] = decide(duplicate)
    stale = deepcopy(second)
    stale["origin"]["acquired"] = stale["origin"]["started"] - 1
    stale["callback"] = stale["callback"].splitlines()[0] + "\n" + json.dumps(stale["origin"])
    rows["stale-time"] = decide(stale)
    for name, row in rows.items():
        if name not in ("first", "second"):
            need(row["window"] is None and row["side"] is None and row["bounds"] is None, name)
    return rows


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path, help="原始场次总目录，或仓库内的脱敏回放输入")
    source = parser.parse_args().input
    if source.is_dir():
        stages = [{"frame": read_frame(source / name),
                   "oracle": json.loads((source / name / "oracle.json").read_text(encoding="utf8"))}
                  for name in ("first", "second")]
    else:
        stages = json.loads(source.read_text(encoding="utf8"))
    print(json.dumps(verify_pair(stages), ensure_ascii=False, indent=2))
