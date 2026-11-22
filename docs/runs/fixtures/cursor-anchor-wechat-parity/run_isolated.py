#!/usr/bin/env python3
"""Isolated Android 16 (API 36) AVD runner for WeChat-parity Pathway 4A + 4B verification.

Never touches default ADB port 5037 or physical USB devices (`ADB_USB=0`, `ADB_MDNS=0`, `ADB_EMU=1`,
empty pre-boot `adb devices`, private `-L tcp:<port>` server, `-H 127.0.0.1 -P <port>` clients).
Never writes gateway bearer token or host filesystem paths into receipts.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shlex
import shutil
import socket
import subprocess
import sys
import time
import urllib.request
import uuid
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any

from verify import EXPECTED_SETTINGS_KEYS, REQUIRED_SCENARIOS, verify_receipts

GATEWAY_PKG = "dev.magina.gateway"
FIXTURE_PKG = "dev.magina.wechatparity"
GATEWAY_A11Y = f"{GATEWAY_PKG}/dev.magina.gateway.a11y.GatewayA11yService"
GATEWAY_IME = f"{GATEWAY_PKG}/.ime.GatewayIme"
MCP_PROTOCOL_VERSION = "2025-03-26"


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest().lower()


def port_in_use(port: int) -> bool:
    for host in ("127.0.0.1", "::1"):
        family = socket.AF_INET6 if ":" in host else socket.AF_INET
        try:
            with socket.socket(family, socket.SOCK_STREAM) as s:
                s.settimeout(0.3)
                if s.connect_ex((host, port)) == 0:
                    return True
        except OSError:
            pass
    try:
        out = subprocess.check_output(["netstat", "-ano", "-p", "TCP"], text=True, stderr=subprocess.DEVNULL)
        pat = re.compile(rf":\b{port}\b\s+\S+\s+LISTENING")
        if pat.search(out):
            return True
    except Exception:
        pass
    return False


def build_isolated_env(testbench_sdk: Path, java_home: Path, work_dir: Path, adb_port: int) -> dict[str, str]:
    home_dir = work_dir / "home"
    avd_home = work_dir / "avd-home"
    tmp_dir = work_dir / "tmp"
    for d in (home_dir, avd_home, tmp_dir, home_dir / "AppData" / "Local", home_dir / "AppData" / "Roaming"):
        d.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    drive, tail = os.path.splitdrive(str(home_dir))
    env.update({
        "JAVA_HOME": str(java_home),
        "ANDROID_HOME": str(testbench_sdk),
        "ANDROID_SDK_ROOT": str(testbench_sdk),
        "ANDROID_USER_HOME": str(home_dir),
        "ANDROID_EMULATOR_HOME": str(home_dir),
        "ANDROID_AVD_HOME": str(avd_home),
        "HOME": str(home_dir),
        "USERPROFILE": str(home_dir),
        "HOMEDRIVE": drive or "C:",
        "HOMEPATH": tail or "\\",
        "LOCALAPPDATA": str(home_dir / "AppData" / "Local"),
        "APPDATA": str(home_dir / "AppData" / "Roaming"),
        "TEMP": str(tmp_dir),
        "TMP": str(tmp_dir),
        "JAVA_TOOL_OPTIONS": f'-Duser.home="{home_dir}" -Djava.io.tmpdir="{tmp_dir}"',
        "ANDROID_ADB_SERVER_PORT": str(adb_port),
        "ADB_SERVER_SOCKET": f"tcp:127.0.0.1:{adb_port}",
        "ADB_USB": "0",
        "ADB_MDNS": "0",
        "ADB_EMU": "1",
    })
    return env


def run_cmd(
    cmd: list[str],
    env: dict[str, str],
    timeout: float = 60.0,
    input_text: str | None = None,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(
        cmd,
        env=env,
        input=input_text,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=timeout,
    )
    if check and proc.returncode != 0:
        raise RuntimeError(f"command failed ({proc.returncode}): {cmd[0]} {cmd[1:4]} -> {proc.stderr.strip() or proc.stdout.strip()}")
    return proc


def parse_adb_devices(output: str) -> list[str]:
    rows: list[str] = []
    for line in output.splitlines():
        s = line.strip()
        if not s or s.startswith("List of devices") or s.startswith("* "):
            continue
        rows.append(s)
    return rows


def mcp_request(http_port: int, token: str, payload: dict[str, Any], timeout: float = 15.0) -> dict[str, Any]:
    body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    req = urllib.request.Request(
        f"http://127.0.0.1:{http_port}/mcp",
        data=body,
        method="POST",
        headers={
            "Authorization": f"Bearer {token}",
            "MCP-Protocol-Version": MCP_PROTOCOL_VERSION,
            "Content-Type": "application/json",
        },
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def mcp_call_tool_raw(http_port: int, token: str, req_id: int, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
    rpc = mcp_request(
        http_port,
        token,
        {
            "jsonrpc": "2.0",
            "id": req_id,
            "method": "tools/call",
            "params": {"name": name, "arguments": arguments},
        },
    )
    if "error" in rpc:
        raise RuntimeError(f"MCP RPC error for {name}: {rpc['error']}")
    content = rpc["result"]["content"]
    return json.loads(content[0]["text"])


def mcp_call_tool(http_port: int, token: str, req_id: int, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
    envelope = mcp_call_tool_raw(http_port, token, req_id, name, arguments)
    if not envelope.get("ok"):
        raise RuntimeError(f"Gateway tool {name} returned ok=false: {envelope}")
    return envelope["data"]


def sanitize_focused_meta(data: dict[str, Any]) -> dict[str, Any]:
    return {
        "focused_identity_source": data.get("focused_identity_source"),
        "focused_input_id": data.get("focused_input_id"),
        "focused_input_bounds": data.get("focused_input_bounds"),
        "focused_input_window_id": data.get("focused_input_window_id"),
        "focused_input_pane": data.get("focused_input_pane"),
    }


def sanitize_foreground(fg: dict[str, Any]) -> dict[str, Any]:
    wins = []
    for w in fg.get("windows", []):
        wins.append({
            "id": w.get("id"),
            "type": w.get("type"),
            "active": w.get("active"),
            "focused": w.get("focused"),
            "root_package": w.get("root_package"),
            "bounds": w.get("bounds"),
        })
    return {
        "package": fg.get("package"),
        "activity": fg.get("activity"),
        "foreground_known": fg.get("foreground_known"),
        "foreground_reason": fg.get("foreground_reason"),
        "window_topology": fg.get("window_topology"),
        "windows": wins,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--testbench-sdk", type=Path, required=True)
    parser.add_argument("--java-home", type=Path, required=True)
    parser.add_argument("--gateway-apk", type=Path, required=True)
    parser.add_argument("--fixture-apk", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--receipts-out", type=Path, required=True)
    parser.add_argument("--adb-port", type=int, default=5047)
    parser.add_argument("--console-port", type=int, default=5594)
    parser.add_argument("--http-port", type=int, default=18852)
    parser.add_argument("--source-sha", type=str, default="")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    if args.adb_port == 5037:
        raise SystemExit("Refusing to use default ADB port 5037")

    ports = [args.adb_port, args.console_port, args.console_port + 1, args.http_port]
    busy = [p for p in ports if port_in_use(p)]
    if busy:
        raise SystemExit(f"Declared isolated ports already in use: {busy}")

    adb_exe = args.testbench_sdk / "platform-tools" / "adb.exe"
    emu_exe = args.testbench_sdk / "emulator" / "emulator.exe"
    avdmanager = args.testbench_sdk / "cmdline-tools" / "latest" / "bin" / "avdmanager.bat"
    for p in (adb_exe, emu_exe, avdmanager, args.gateway_apk, args.fixture_apk):
        if not p.is_file():
            raise SystemExit(f"Missing required path: {p}")

    if args.dry_run:
        print(json.dumps({"dry_run": True, "ports_free": ports, "status": "ok"}))
        return 0

    started_at = time.monotonic()
    nonce = uuid.uuid4().hex[:10]
    avd_name = f"p4-cursor-{nonce}"
    serial = f"emulator-{args.console_port}"
    work_dir = args.output_dir.resolve()
    if work_dir.exists():
        shutil.rmtree(work_dir)
    work_dir.mkdir(parents=True, exist_ok=True)
    env = build_isolated_env(args.testbench_sdk.resolve(), args.java_home.resolve(), work_dir, args.adb_port)

    gw_sha = sha256_file(args.gateway_apk)
    fx_sha = sha256_file(args.fixture_apk)

    adb_proc: subprocess.Popen[str] | None = None
    emu_proc: subprocess.Popen[str] | None = None
    emu_log = None
    forward_added = False
    saved_settings: dict[str, str] = {}
    restored_settings: dict[str, str] = {}
    cleanup_errors: list[str] = []
    gateway_uninstalled = False
    fixture_uninstalled = False
    emulator_stopped = False
    isolated_adb_stopped = False
    ports_released = False
    avd_deleted = False

    def adb_base(extra: list[str], timeout: float = 30.0, check: bool = True) -> subprocess.CompletedProcess[str]:
        return run_cmd([str(adb_exe), "-H", "127.0.0.1", "-P", str(args.adb_port), *extra], env=env, timeout=timeout, check=check)

    def adb_dev(extra: list[str], timeout: float = 30.0, check: bool = True) -> subprocess.CompletedProcess[str]:
        return adb_base(["-s", serial, *extra], timeout=timeout, check=check)

    def get_setting(ns: str, key: str) -> str:
        return adb_dev(["shell", "settings", "get", ns, key], timeout=10.0).stdout.strip()

    def put_or_delete_setting(ns: str, key: str, val: str) -> None:
        if val in ("", "null"):
            adb_dev(["shell", f"settings delete {ns} {key}"], timeout=10.0, check=False)
        else:
            # Quote value for Android /system/bin/sh because enabled_input_methods contains ';'.
            adb_dev(["shell", f"settings put {ns} {key} {shlex.quote(val)}"], timeout=10.0, check=False)

    receipts: dict[str, Any] = {
        "schema_version": 2,
        "source_sha": args.source_sha,
        "environment": {
            "adb_port": args.adb_port,
            "console_port": args.console_port,
            "transport_port": args.console_port + 1,
            "http_port": args.http_port,
            "adb_usb_disabled": True,
            "adb_mdns_disabled": True,
            "adb_emu_enabled": True,
            "initial_adb_devices_empty": False,
            "avd_identity_verified": False,
            "api": "",
            "qemu": "",
        },
        "apks": {
            "gateway_sha256": gw_sha,
            "fixture_sha256": fx_sha,
            "gateway_hash_matched": False,
            "fixture_hash_matched": False,
            "gateway_uid": None,
            "fixture_uid": None,
        },
        "scenarios": {},
        "teardown": {},
    }

    run_error: str | None = None
    try:
        # 1. Create fresh API 36 AVD in isolated output dir
        avd_path = work_dir / "avd"
        run_cmd(
            [
                str(avdmanager), "create", "avd",
                "--name", avd_name,
                "--package", "system-images;android-36;google_apis;x86_64",
                "--device", "pixel_5",
                "--path", str(avd_path),
            ],
            env=env,
            timeout=120.0,
            input_text="no\n",
        )
        if not (avd_path / "config.ini").is_file():
            raise RuntimeError("AVD config.ini missing after avdmanager create")

        # 2. Start isolated private ADB server on tcp:<adb_port> (loopback only, USB/mDNS off)
        adb_proc = subprocess.Popen(
            [str(adb_exe), "-L", f"tcp:{args.adb_port}", "--one-device", f"p4-no-usb-{nonce}", "server", "nodaemon"],
            env=env,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            text=True,
        )
        deadline = time.monotonic() + 15.0
        while time.monotonic() < deadline:
            if adb_proc.poll() is not None:
                raise RuntimeError(f"private adb server exited early: {adb_proc.returncode}")
            if port_in_use(args.adb_port):
                break
            time.sleep(0.15)
        if not port_in_use(args.adb_port):
            raise RuntimeError("private adb server failed to listen")

        # 3. Verify empty pre-boot device list
        pre_devices = parse_adb_devices(adb_base(["devices"], timeout=10.0).stdout)
        if pre_devices:
            raise RuntimeError(f"isolated adb devices non-empty before boot: {pre_devices}")
        receipts["environment"]["initial_adb_devices_empty"] = True

        # 4. Boot isolated API 36 AVD
        emu_log = (work_dir / "emulator.log").open("w", encoding="utf-8")
        emu_proc = subprocess.Popen(
            [
                str(emu_exe),
                "-avd", avd_name,
                "-ports", f"{args.console_port},{args.console_port + 1}",
                "-no-window", "-no-audio", "-no-boot-anim", "-no-snapshot",
                "-memory", "2048", "-gpu", "software", "-no-metrics",
            ],
            env=env,
            stdout=emu_log,
            stderr=subprocess.STDOUT,
            text=True,
        )
        boot_deadline = time.monotonic() + 240.0
        booted = False
        while time.monotonic() < boot_deadline:
            if emu_proc.poll() is not None:
                raise RuntimeError(f"emulator exited before boot: {emu_proc.returncode}")
            rows = parse_adb_devices(adb_base(["devices"], timeout=10.0).stdout)
            for row in rows:
                if not row.startswith(serial + "\t") and not row.startswith(serial + " "):
                    raise RuntimeError(f"foreign device detected on isolated server: {rows}")
            if any(re.match(rf"^{re.escape(serial)}\s+device\b", r) for r in rows):
                bc = adb_dev(["shell", "getprop", "sys.boot_completed"], timeout=10.0, check=False).stdout.strip()
                if bc == "1":
                    booted = True
                    break
            time.sleep(2.0)
        if not booted:
            raise RuntimeError("emulator boot timeout")

        # 5. Verify AVD identity
        actual_avd = adb_dev(["emu", "avd", "name"], timeout=10.0).stdout.splitlines()[0].strip()
        actual_api = adb_dev(["shell", "getprop", "ro.build.version.sdk"], timeout=10.0).stdout.strip()
        actual_qemu = adb_dev(["shell", "getprop", "ro.kernel.qemu"], timeout=10.0).stdout.strip()
        if actual_avd != avd_name or actual_api != "36" or actual_qemu != "1":
            raise RuntimeError(f"AVD identity mismatch: avd={actual_avd}, api={actual_api}, qemu={actual_qemu}")
        receipts["environment"]["api"] = actual_api
        receipts["environment"]["qemu"] = actual_qemu
        receipts["environment"]["avd_identity_verified"] = True

        # 6. Wait for IMMS first-boot init settle before saving original settings
        imms_deadline = time.monotonic() + 30.0
        while time.monotonic() < imms_deadline:
            cur_def = get_setting("secure", "default_input_method")
            cur_ena = get_setting("secure", "enabled_input_methods")
            if cur_def not in ("", "null") and cur_ena not in ("", "null"):
                break
            time.sleep(1.0)
        for full_key in EXPECTED_SETTINGS_KEYS:
            ns, key = full_key.split(":", 1)
            saved_settings[full_key] = get_setting(ns, key)
        if saved_settings["secure:default_input_method"] in ("", "null"):
            raise RuntimeError(f"IMMS did not settle before save: {saved_settings}")

        # 7. Install both APKs, verify on-device SHA-256 and distinct UIDs
        for pkg, apk_path, expected_sha, key_prefix in (
            (GATEWAY_PKG, args.gateway_apk, gw_sha, "gateway"),
            (FIXTURE_PKG, args.fixture_apk, fx_sha, "fixture"),
        ):
            adb_dev(["install", "-g", str(apk_path)], timeout=90.0)
            pm_path = adb_dev(["shell", "pm", "path", pkg], timeout=15.0).stdout.strip()
            if not pm_path.startswith("package:"):
                raise RuntimeError(f"unexpected pm path for {pkg}: {pm_path}")
            remote_apk = pm_path.splitlines()[0][len("package:"):].strip()
            remote_sha = adb_dev(["shell", "sha256sum", remote_apk], timeout=20.0).stdout.strip().split()[0].lower()
            if remote_sha != expected_sha:
                raise RuntimeError(f"on-device SHA mismatch for {pkg}: {remote_sha} != {expected_sha}")
            receipts["apks"][f"{key_prefix}_hash_matched"] = True
            uid_out = adb_dev(["shell", "cmd", "package", "list", "packages", "-U", pkg], timeout=10.0).stdout
            m = re.search(rf"package:{re.escape(pkg)}\s+uid:(\d+)", uid_out)
            if not m:
                raise RuntimeError(f"could not read UID for {pkg}: {uid_out}")
            receipts["apks"][f"{key_prefix}_uid"] = int(m.group(1))
        if receipts["apks"]["gateway_uid"] == receipts["apks"]["fixture_uid"]:
            raise RuntimeError("gateway and fixture UIDs must be distinct")

        # 8. Lock landscape, enable GatewayA11yService + GatewayIme, start GatewayService + forward
        adb_dev(["shell", "settings", "put", "system", "accelerometer_rotation", "0"])
        adb_dev(["shell", "settings", "put", "system", "user_rotation", "1"])
        adb_dev(["shell", "settings", "put", "secure", "enabled_accessibility_services", GATEWAY_A11Y])
        adb_dev(["shell", "settings", "put", "secure", "accessibility_enabled", "1"])
        adb_dev(["shell", "ime", "enable", GATEWAY_IME])
        adb_dev(["shell", "ime", "set", GATEWAY_IME])
        adb_dev(["shell", "cmd", "appops", "set", GATEWAY_PKG, "SYSTEM_ALERT_WINDOW", "allow"])
        adb_dev(["shell", "am", "start", "-W", "-n", f"{GATEWAY_PKG}/.MainActivity"], timeout=20.0)
        adb_dev(["shell", "run-as", GATEWAY_PKG, "am", "start-foreground-service", "--user", "0", "-n", f"{GATEWAY_PKG}/.GatewayService"])
        adb_dev(["forward", "--no-rebind", f"tcp:{args.http_port}", "tcp:8848"])
        forward_added = True

        # Wait for /health == "ok" before reading bearer token once in memory
        health_deadline = time.monotonic() + 25.0
        healthy = False
        while time.monotonic() < health_deadline:
            try:
                with urllib.request.urlopen(f"http://127.0.0.1:{args.http_port}/health", timeout=2.0) as resp:
                    if resp.read().decode("utf-8").strip() == "ok":
                        healthy = True
                        break
            except Exception:
                time.sleep(0.5)
        if not healthy:
            raise RuntimeError("gateway /health did not become ready")

        # Read bearer token ONLY in memory; never log or persist it
        prefs_xml = adb_dev(["shell", "run-as", GATEWAY_PKG, "cat", "shared_prefs/gateway.xml"], timeout=15.0).stdout
        root_xml = ET.fromstring(prefs_xml)
        token_el = root_xml.find("./string[@name='token']")
        token = (token_el.text or "").strip() if token_el is not None else ""
        if not re.fullmatch(r"[0-9a-f]{32}", token):
            raise RuntimeError("gateway token missing or malformed")

        # Initialize MCP & wait for GatewayA11yService to bind
        req_id = 1
        mcp_request(args.http_port, token, {
            "jsonrpc": "2.0", "id": req_id, "method": "initialize",
            "params": {"protocolVersion": MCP_PROTOCOL_VERSION, "capabilities": {}, "clientInfo": {"name": "p4-runner", "version": "1.0"}},
        })
        req_id += 1
        a11y_deadline = time.monotonic() + 30.0
        a11y_bound = False
        rebound = False
        last_a11y_err = ""
        while time.monotonic() < a11y_deadline:
            try:
                mcp_call_tool(args.http_port, token, req_id, "foreground_app", {})
                req_id += 1
                a11y_bound = True
                break
            except Exception as err:
                last_a11y_err = str(err)
                req_id += 1
                if not rebound and (a11y_deadline - time.monotonic()) < 22.0:
                    rebound = True
                    print(f"[a11y-wait] retrying bind after: {last_a11y_err}", flush=True)
                    adb_dev(["shell", "settings", "delete", "secure", "enabled_accessibility_services"], check=False)
                    time.sleep(0.4)
                    adb_dev(["shell", "settings", "put", "secure", "enabled_accessibility_services", GATEWAY_A11Y], check=False)
                    adb_dev(["shell", "settings", "put", "secure", "accessibility_enabled", "1"], check=False)
                time.sleep(0.6)
        if not a11y_bound:
            dump = adb_dev(["shell", "dumpsys", "accessibility"], timeout=10.0, check=False).stdout
            excerpt = "\n".join(line for line in dump.splitlines() if any(k in line for k in ("Enabled services", "Bound services", "gateway", "Gateway")))[:600]
            raise RuntimeError(f"GatewayA11yService did not bind: last_err={last_a11y_err}; dumpsys={excerpt}")

        # 9. Execute all 6 WeChat-parity adversarial scenarios
        for case in REQUIRED_SCENARIOS:
            adb_dev(["shell", "am", "force-stop", FIXTURE_PKG], check=False)
            adb_dev(["shell", "run-as", FIXTURE_PKG, "rm", "-f", f"files/{case}.json"], check=False)
            time.sleep(0.3)

            adb_dev([
                "shell", "am", "start", "-W", "-f", "0x10008000",
                "-n", f"{FIXTURE_PKG}/.WeChatParityActivity",
                "--es", "lab_case", case,
            ], timeout=25.0)

            # Wait for fixture receipt to confirm focus + connection (or focus for type_null_decor)
            oracle: dict[str, Any] | None = None
            case_deadline = time.monotonic() + 18.0
            while time.monotonic() < case_deadline:
                cat = adb_dev(["shell", "run-as", FIXTURE_PKG, "cat", f"files/{case}.json"], timeout=10.0, check=False)
                if cat.returncode == 0 and cat.stdout.strip():
                    try:
                        parsed = json.loads(cat.stdout)
                        ready = (
                            parsed.get("case") == case
                            and parsed.get("landscape") is True
                            and parsed.get("focused") is True
                            and parsed.get("window_focused") is True
                            and (case == "type_null_decor" or parsed.get("connected") is True)
                        )
                        if ready:
                            oracle = parsed
                            break
                    except json.JSONDecodeError:
                        pass
                time.sleep(0.3)
            if oracle is None:
                # Read whatever is on disk for diagnostics
                last_cat = adb_dev(["shell", "run-as", FIXTURE_PKG, "cat", f"files/{case}.json"], timeout=10.0, check=False).stdout
                raise RuntimeError(f"{case}: fixture receipt not ready before timeout; last={last_cat[:400]}")

            # Wait briefly for GatewayA11yService window list to settle on same_app_multi
            fg_data: dict[str, Any] | None = None
            fg_deadline = time.monotonic() + 8.0
            while time.monotonic() < fg_deadline:
                cand_fg = mcp_call_tool(args.http_port, token, req_id, "foreground_app", {})
                req_id += 1
                fg_data = sanitize_foreground(cand_fg)
                app_wins = [w for w in fg_data["windows"] if w.get("type") == "application"]
                if fg_data.get("package") == FIXTURE_PKG and len(app_wins) == 2:
                    break
                time.sleep(0.3)
            assert fg_data is not None
            # Allow any initial window layout frame to finish settling before geometry probes
            time.sleep(0.5)
            fg_data = sanitize_foreground(mcp_call_tool(args.http_port, token, req_id, "foreground_app", {}))
            req_id += 1

            # Default keyboard_state (no probe flags)
            kb_default = mcp_call_tool(args.http_port, token, req_id, "keyboard_state", {})
            req_id += 1

            sc_entry: dict[str, Any] = {
                "foreground_app": fg_data,
                "keyboard_state_default": kb_default,
            }

            if case == "disjoint_right_dead_end":
                sc_entry["probe_editor_origin"] = mcp_call_tool(
                    args.http_port, token, req_id, "keyboard_state", {"probe_editor_origin": True},
                )
                req_id += 1

            sc_entry["probe_editor_bounds"] = mcp_call_tool(
                args.http_port, token, req_id, "keyboard_state", {"probe_editor_bounds": True},
            )
            req_id += 1

            sc_entry["probe_cursor_anchor"] = mcp_call_tool(
                args.http_port, token, req_id, "keyboard_state", {"probe_cursor_anchor": True},
            )
            req_id += 1

            # Production ui_find / ui_snapshot metadata + non-fabricated ui_find(role="input") checks
            pane_query = "LEFT PANE" if case in ("disjoint_left_dead_end", "type_null_decor") else "RIGHT PANE"
            ui_find_pane = mcp_call_tool(
                args.http_port, token, req_id, "ui_find", {"text": pane_query, "scroll_search": False},
            )
            req_id += 1
            sc_entry["ui_find_pane"] = {
                **sanitize_focused_meta(ui_find_pane),
                "matches_count": len(ui_find_pane.get("matches", [])),
            }

            ui_snap = mcp_call_tool(
                args.http_port, token, req_id, "ui_snapshot", {"scope": "interactive"},
            )
            req_id += 1
            snap_input_count = sum(
                1 for e in ui_snap.get("elements", [])
                if isinstance(e, dict) and e.get("role") == "input"
            )
            sc_entry["ui_snapshot"] = {
                **sanitize_focused_meta(ui_snap),
                "input_elements_count": snap_input_count,
            }

            # Gateway RetryGuard limits identical failing (tool, args_fingerprint) calls to 2 per process.
            # Use semantically identical empty/default parameter spellings across scenario pairs so every
            # scenario genuinely executes UiTools.uiFind(null, "input", null, false) and proves E_NOT_FOUND.
            find_input_args_by_case: dict[str, dict[str, Any]] = {
                "disjoint_right_dead_end": {"role": "input", "scroll_search": False},
                "disjoint_right_valid_node": {"role": "input", "scroll_search": False},
                "disjoint_right_legacy_1arg": {"role": "input"},
                "disjoint_left_dead_end": {"role": "input"},
                "overlap_right": {"role": "input", "text": "", "scroll_search": False},
                "type_null_decor": {"role": "input", "text": "", "scroll_search": False},
            }
            ui_find_input_env = mcp_call_tool_raw(
                args.http_port, token, req_id, "ui_find", find_input_args_by_case[case],
            )
            req_id += 1
            sc_entry["ui_find_input"] = {
                "ok": bool(ui_find_input_env.get("ok")),
                "error_code": (ui_find_input_env.get("error") or {}).get("code")
                if not ui_find_input_env.get("ok") else None,
                "matches_count": len((ui_find_input_env.get("data") or {}).get("matches", []))
                if ui_find_input_env.get("ok") else 0,
            }

            # Re-read fixture receipt AFTER probes to capture final IC call counters
            time.sleep(0.25)
            post_cat = adb_dev(["shell", "run-as", FIXTURE_PKG, "cat", f"files/{case}.json"], timeout=10.0)
            sc_entry["fixture_receipt"] = json.loads(post_cat.stdout)
            receipts["scenarios"][case] = sc_entry
            print(
                f"[scenario {case}] topology={fg_data['window_topology']} "
                f"bounds={sc_entry['probe_editor_bounds'].get('ime_editor_bounds_reason')} "
                f"anchor_ok={sc_entry['probe_cursor_anchor'].get('ime_cursor_anchor') is not None} "
                f"anchor_reason={sc_entry['probe_cursor_anchor'].get('ime_cursor_anchor_reason')} "
                f"ui_source={sc_entry['ui_find_pane'].get('focused_identity_source')} "
                f"ui_input_code={sc_entry['ui_find_input'].get('error_code')}",
                flush=True,
            )

    except Exception as exc:
        run_error = str(exc)
        print(f"RUN ERROR: {run_error}", file=sys.stderr, flush=True)
    finally:
        # Unconditional full teardown
        try:
            if adb_proc is not None and adb_proc.poll() is None:
                if emu_proc is not None and emu_proc.poll() is None:
                    adb_dev(["shell", "am", "force-stop", FIXTURE_PKG], check=False)
                    adb_dev(["shell", "am", "stopservice", f"{GATEWAY_PKG}/.GatewayService"], check=False)
                    adb_dev(["shell", "am", "force-stop", GATEWAY_PKG], check=False)
                    if forward_added:
                        adb_dev(["forward", "--remove", f"tcp:{args.http_port}"], check=False)
                    adb_dev(["shell", "ime", "disable", GATEWAY_IME], check=False)
                    if saved_settings:
                        for full_key in EXPECTED_SETTINGS_KEYS:
                            if full_key in saved_settings:
                                ns, key = full_key.split(":", 1)
                                put_or_delete_setting(ns, key, saved_settings[full_key])
                        # Bounded readback settle poll
                        settle_deadline = time.monotonic() + 6.0
                        while time.monotonic() < settle_deadline:
                            current = {}
                            for full_key in EXPECTED_SETTINGS_KEYS:
                                ns, key = full_key.split(":", 1)
                                current[full_key] = get_setting(ns, key)
                            restored_settings = current
                            if all(restored_settings.get(k) == saved_settings.get(k) for k in saved_settings):
                                break
                            time.sleep(0.5)
                        for k, v in saved_settings.items():
                            if restored_settings.get(k) != v:
                                cleanup_errors.append(f"setting_restore_mismatch:{k}")

                    for pkg in (FIXTURE_PKG, GATEWAY_PKG):
                        adb_dev(["uninstall", pkg], timeout=30.0, check=False)
                    pkgs_u = adb_dev(["shell", "pm", "list", "packages", "-u"], timeout=15.0, check=False).stdout
                    gateway_uninstalled = f"package:{GATEWAY_PKG}" not in pkgs_u
                    fixture_uninstalled = f"package:{FIXTURE_PKG}" not in pkgs_u
                    if not gateway_uninstalled:
                        cleanup_errors.append("gateway_still_present")
                    if not fixture_uninstalled:
                        cleanup_errors.append("fixture_still_present")

                    adb_dev(["emu", "kill"], timeout=15.0, check=False)
        except Exception as te:
            cleanup_errors.append(f"device_teardown_exception:{te}")

        if emu_proc is not None:
            try:
                emu_proc.wait(timeout=25.0)
            except subprocess.TimeoutExpired:
                emu_proc.terminate()
                try:
                    emu_proc.wait(timeout=10.0)
                except subprocess.TimeoutExpired:
                    emu_proc.kill()
                    emu_proc.wait(timeout=5.0)
            emulator_stopped = emu_proc.poll() is not None
            if not emulator_stopped:
                cleanup_errors.append("emulator_not_stopped")
        else:
            emulator_stopped = True
        if emu_log is not None:
            try:
                emu_log.close()
            except Exception:
                pass

        if adb_proc is not None:
            try:
                adb_base(["kill-server"], timeout=10.0, check=False)
            except Exception:
                pass
            try:
                adb_proc.wait(timeout=10.0)
            except subprocess.TimeoutExpired:
                adb_proc.terminate()
                try:
                    adb_proc.wait(timeout=5.0)
                except subprocess.TimeoutExpired:
                    adb_proc.kill()
                    adb_proc.wait(timeout=5.0)
            isolated_adb_stopped = adb_proc.poll() is not None
            if not isolated_adb_stopped:
                cleanup_errors.append("isolated_adb_not_stopped")
        else:
            isolated_adb_stopped = True

        # Wait briefly for Windows socket release on declared ports
        port_deadline = time.monotonic() + 10.0
        while time.monotonic() < port_deadline:
            if not any(port_in_use(p) for p in ports):
                break
            time.sleep(0.5)
        still_busy = [p for p in ports if port_in_use(p)]
        ports_released = len(still_busy) == 0
        if not ports_released:
            cleanup_errors.append(f"ports_still_listening:{still_busy}")

        # Delete temporary AVD directory (allow netsimd helper a few seconds to release log handles)
        try:
            if work_dir.exists():
                del_deadline = time.monotonic() + 20.0
                while work_dir.exists() and time.monotonic() < del_deadline:
                    try:
                        shutil.rmtree(work_dir)
                        break
                    except OSError:
                        time.sleep(0.75)
            avd_deleted = not work_dir.exists()
            if not avd_deleted:
                cleanup_errors.append("avd_dir_not_deleted")
        except Exception as de:
            cleanup_errors.append(f"avd_delete_failed:{de}")

        receipts["elapsed_seconds"] = round(time.monotonic() - started_at, 2)
        receipts["run_error"] = run_error
        receipts["teardown"] = {
            "saved_settings": saved_settings,
            "restored_settings": restored_settings,
            "gateway_uninstalled": gateway_uninstalled,
            "fixture_uninstalled": fixture_uninstalled,
            "emulator_stopped": emulator_stopped,
            "isolated_adb_stopped": isolated_adb_stopped,
            "ports_released": ports_released,
            "avd_deleted": avd_deleted,
            "cleanup_errors": cleanup_errors,
        }
        args.receipts_out.parent.mkdir(parents=True, exist_ok=True)
        args.receipts_out.write_text(json.dumps(receipts, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    verify_errors = verify_receipts(receipts, require_production_ui=True)
    if run_error or cleanup_errors or verify_errors:
        for e in verify_errors:
            print(f"VERIFY FAIL: {e}", file=sys.stderr)
        return 1

    print(json.dumps({
        "status": "PASS",
        "elapsed_seconds": receipts["elapsed_seconds"],
        "scenarios": len(receipts["scenarios"]),
        "teardown_clean": True,
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
