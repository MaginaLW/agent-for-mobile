"""Strictly isolated API 36 AVD runner for the 4-scenario ime-menu A2 experiment suite.

Safety invariants (matching docs/runbooks/本地测试台.md):
- Never uses default ADB port 5037 or touches any physical USB device (PA2553).
- Launches a private nodaemon ADB server with ADB_USB=0, ADB_MDNS=0, ADB_EMU=1 and a random nonexistent --one-device.
- Verifies an empty initial device list before starting a fresh disposable pixel_5 API 36 AVD.
- Restores all 8 settings with exact readback, uninstalls both packages, stops emulator & private ADB,
  deletes the disposable AVD, and verifies all 3 ports are released in finally.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import socket
import subprocess
import time

import verify as verifier

TARGET_PKG = "dev.magina.autofilltarget"
OBSERVER_PKG = "dev.magina.autofillobserver"
MENU_IME = f"{OBSERVER_PKG}/.MenuIme"
AUTOFILL_SVC = f"{OBSERVER_PKG}/.ProbeAutofillService"
AVD_PACKAGE = "system-images;android-36;google_apis;x86_64"

SETTINGS_KEYS = [
    ("secure", "default_input_method"),
    ("secure", "enabled_input_methods"),
    ("secure", "autofill_service"),
    ("secure", "immersive_mode_confirmations"),
    ("global", "airplane_mode_on"),
    ("global", "wifi_on"),
    ("system", "accelerometer_rotation"),
    ("system", "user_rotation"),
]


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest().lower()


def port_bindable(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 0)
        try:
            sock.bind(("127.0.0.1", port))
            return True
        except OSError:
            return False


def port_has_listener(port: int) -> bool:
    res = subprocess.run(["netstat", "-ano", "-p", "TCP"], capture_output=True, text=True, check=False)
    pattern = re.compile(rf"^\s*TCP\s+\S+:{port}\s+\S+\s+LISTENING\s+\d+\s*$", re.IGNORECASE)
    for line in res.stdout.splitlines():
        if pattern.match(line):
            return True
    return False


def parse_device_rows(output: str):
    rows = []
    for line in output.splitlines():
        line = line.strip()
        if not line or line.startswith("List of devices") or line.startswith("*"):
            continue
        parts = line.split()
        if len(parts) >= 2:
            rows.append((parts[0], parts[1]))
    return rows


def sh_single_quote(value: str) -> str:
    return "'" + value.replace("'", "'\"'\"'") + "'"


def validate_inputs(opts):
    if opts.adb_port == 5037:
        raise ValueError("refusing to use default ADB port 5037")
    if opts.console_port % 2 != 0 or not (5554 <= opts.console_port <= 5680):
        raise ValueError("console_port must be an even integer in [5554, 5680]")
    ports = [opts.adb_port, opts.console_port, opts.console_port + 1]
    if len(set(ports)) != 3 or 5037 in ports:
        raise ValueError(f"invalid isolated port set: {ports}")

    emu_sdk = opts.emu_sdk.resolve()
    jdk = opts.jdk.resolve()
    build_dir = opts.build_dir.resolve()
    required_files = {
        "adb": emu_sdk / "platform-tools/adb.exe",
        "emulator": emu_sdk / "emulator/emulator.exe",
        "avdmanager": emu_sdk / "cmdline-tools/latest/bin/avdmanager.bat",
        "system_image": emu_sdk / "system-images/android-36/google_apis/x86_64/package.xml",
        "java": jdk / "bin/java.exe",
        "target_apk": build_dir / "target.apk",
        "observer_apk": build_dir / "observer.apk",
        "target_diffsig_apk": build_dir / "target-diffsig.apk",
        "build_json": build_dir / "build.json",
    }
    missing = {k: str(v) for k, v in required_files.items() if not v.is_file()}
    if missing:
        raise FileNotFoundError(f"missing required files: {json.dumps(missing)}")

    manifest = json.loads(required_files["build_json"].read_text(encoding="utf-8"))
    for key, path_key in (
        ("target.apk", "target_apk"),
        ("observer.apk", "observer_apk"),
        ("target-diffsig.apk", "target_diffsig_apk"),
    ):
        actual = sha256_file(required_files[path_key])
        expected = manifest["sha256"][key].lower()
        if actual != expected:
            raise ValueError(f"APK hash mismatch for {key}: {actual} != {expected}")

    free_status = {p: (port_bindable(p) and not port_has_listener(p)) for p in ports}
    return required_files, manifest, ports, free_status


class IsolatedRunner:
    def __init__(self, opts, files, manifest, ports):
        self.opts = opts
        self.files = files
        self.manifest = manifest
        self.ports = ports
        self.adb_port = opts.adb_port
        self.console_port = opts.console_port
        self.serial = f"emulator-{self.console_port}"
        self.out = opts.output.resolve()
        self.nonce = secrets.token_hex(6)
        self.avd_name = f"ime-menu-{self.nonce}"
        self.server_proc = None
        self.emu_proc = None
        self.started_monotonic = time.monotonic()
        self.saved_settings = {}
        self.state = {
            "phase": "init",
            "status": "running",
            "avd_name": self.avd_name,
            "ports": {"adb": self.adb_port, "console": self.console_port, "transport": self.console_port + 1},
            "initially_empty": False,
            "api": None,
            "hardware": None,
            "uids": {},
            "installed_sha256": {},
            "saved_settings": {},
            "restored": {},
            "scenarios": {},
            "cleanup": {
                "packages_uninstalled": False,
                "emulator_stopped": False,
                "isolated_server_stopped": False,
                "avd_deleted": False,
                "ports_released": False,
            },
            "cleanup_errors": [],
        }

        self.out.mkdir(parents=True, exist_ok=False)
        for sub in ("home", "tmp", "avd-home", "home/AppData/Local", "home/AppData/Roaming", "logs"):
            (self.out / sub).mkdir(parents=True, exist_ok=True)
        child_home = str(self.out / "home")
        home_drive = os.path.splitdrive(child_home)[0]
        self.env = {
            **os.environ,
            "JAVA_HOME": str(opts.jdk.resolve()),
            "ANDROID_HOME": str(opts.emu_sdk.resolve()),
            "ANDROID_SDK_ROOT": str(opts.emu_sdk.resolve()),
            "ANDROID_USER_HOME": child_home,
            "ANDROID_EMULATOR_HOME": child_home,
            "ANDROID_AVD_HOME": str(self.out / "avd-home"),
            "HOME": child_home,
            "USERPROFILE": child_home,
            "HOMEDRIVE": home_drive,
            "HOMEPATH": child_home[len(home_drive):],
            "LOCALAPPDATA": str(self.out / "home/AppData/Local"),
            "APPDATA": str(self.out / "home/AppData/Roaming"),
            "TEMP": str(self.out / "tmp"),
            "TMP": str(self.out / "tmp"),
            "JAVA_TOOL_OPTIONS": f'-Duser.home="{child_home}" -Djava.io.tmpdir="{self.out / "tmp"}"',
            "ANDROID_ADB_SERVER_PORT": str(self.adb_port),
            "ADB_SERVER_SOCKET": f"tcp:127.0.0.1:{self.adb_port}",
            "ADB_USB": "0",
            "ADB_MDNS": "0",
            "ADB_EMU": "1",
        }

    def save_state(self):
        self.state["elapsed_seconds"] = round(time.monotonic() - self.started_monotonic, 2)
        (self.out / "state.json").write_text(json.dumps(self.state, indent=2) + "\n", encoding="utf-8")

    def adb(self, *args, use_serial=True, timeout=30, check=True, input_text=None):
        if self.server_proc is None or self.server_proc.poll() is not None:
            raise RuntimeError("isolated ADB server is not running")
        cmd = [str(self.files["adb"]), "-H", "127.0.0.1", "-P", str(self.adb_port)]
        if use_serial:
            cmd += ["-s", self.serial]
        cmd += [str(a) for a in args]
        res = subprocess.run(cmd, env=self.env, input=input_text, capture_output=True, text=True,
                             encoding="utf-8", errors="replace", timeout=timeout)
        if check and res.returncode != 0:
            raise RuntimeError(
                f"adb {' '.join(map(str, args))} failed ({res.returncode}): "
                f"{res.stderr.strip()} {res.stdout.strip()}"
            )
        return res

    def shell(self, command: str, timeout=30, check=True, input_text=None):
        return self.adb("shell", command, timeout=timeout, check=check, input_text=input_text)

    def read_setting(self, ns: str, key: str) -> str:
        return self.shell(f"settings get {ns} {key}").stdout.strip()

    def write_setting(self, ns: str, key: str, value: str):
        if ns == "global" and key == "airplane_mode_on":
            if value == "0":
                self.shell("cmd connectivity airplane-mode disable", check=False)
            elif value == "1":
                self.shell("cmd connectivity airplane-mode enable", check=False)
        elif ns == "global" and key == "wifi_on":
            if value == "1":
                self.shell("svc wifi enable", check=False)
            elif value == "0":
                self.shell("svc wifi disable", check=False)
        if value == "null":
            self.shell(f"settings delete {ns} {key}", check=False)
        else:
            self.shell(f"settings put {ns} {key} {sh_single_quote(value)}")

    def read_logcat(self) -> str:
        return self.shell(
            "logcat -d -v brief -s MenuOracle:I MenuChoice:I MenuFill:I "
            "SyntheticProbeIme:I AutofillObserver:W"
        ).stdout

    def wait_log(self, pattern: str, timeout_s: float = 20.0, label: str = ""):
        deadline = time.monotonic() + timeout_s
        last = ""
        while time.monotonic() < deadline:
            last = self.read_logcat()
            if re.search(pattern, last, re.MULTILINE):
                return last
            time.sleep(0.25)
        raise TimeoutError(f"timed out waiting for {label or pattern}; tail:\n{last[-1500:]}")

    def write_observer_file(self, rel: str, content):
        if not re.fullmatch(r"[a-zA-Z0-9._-]+", rel):
            raise ValueError(f"unsafe file name: {rel}")
        if content is None:
            self.shell(f"run-as {OBSERVER_PKG} rm -f files/{rel}", check=False)
        else:
            self.shell(
                f"run-as {OBSERVER_PKG} sh -c 'mkdir -p files && cat > files/{rel}'",
                input_text=content,
            )

    def request_target_snapshot(self):
        self.shell(f"run-as {TARGET_PKG} sh -c 'mkdir -p files && touch files/snapshot'")

    def verify_installed_apk(self, pkg: str, expected_sha: str):
        pm_path = self.shell(f"pm path {pkg}").stdout.strip()
        match = re.search(r"package:(\S+)", pm_path)
        if not match:
            raise RuntimeError(f"could not locate installed path for {pkg}: {pm_path}")
        apk_path = match.group(1)
        device_sha = self.shell(f"sha256sum {sh_single_quote(apk_path)}").stdout.strip().split()[0].lower()
        if device_sha != expected_sha.lower():
            raise RuntimeError(f"on-device SHA-256 mismatch for {pkg}: {device_sha} != {expected_sha}")
        uid_out = self.shell(f"dumpsys package {pkg}").stdout
        uid_match = re.search(r"\b(?:userId|appId)=(\d+)", uid_out)
        if not uid_match:
            raise RuntimeError(f"could not parse UID for {pkg}")
        return device_sha, int(uid_match.group(1))

    def start_isolated_env(self):
        self.state["phase"] = "create_avd"
        self.save_state()
        for p in self.ports:
            if not port_bindable(p) or port_has_listener(p):
                raise RuntimeError(f"port {p} is already in use")

        avd_dir = self.out / "avd"
        res = subprocess.run(
            [str(self.files["avdmanager"]), "create", "avd",
             "--name", self.avd_name, "--package", AVD_PACKAGE,
             "--device", "pixel_5", "--path", str(avd_dir)],
            env=self.env, input="no\n", capture_output=True, text=True, timeout=120, check=True,
        )
        (self.out / "logs/avdmanager.txt").write_text(res.stdout + "\n" + res.stderr, encoding="utf-8")
        if not (avd_dir / "config.ini").is_file():
            raise RuntimeError("AVD config.ini was not created")

        self.state["phase"] = "start_isolated_adb"
        self.save_state()
        with open(self.out / "logs/adb-server.log", "w", encoding="utf-8") as adb_log:
            self.server_proc = subprocess.Popen(
                [str(self.files["adb"]), "-L", f"tcp:{self.adb_port}",
                 "--one-device", f"ime-menu-no-usb-{self.nonce}", "server", "nodaemon"],
                env=self.env, stdout=adb_log, stderr=subprocess.STDOUT,
            )
        for _ in range(40):
            if self.server_proc.poll() is not None:
                raise RuntimeError("isolated ADB server exited prematurely")
            if port_has_listener(self.adb_port):
                break
            time.sleep(0.1)
        else:
            raise RuntimeError("isolated ADB server did not bind port")

        devices_out = self.adb("devices", use_serial=False).stdout
        rows = parse_device_rows(devices_out)
        if rows:
            raise RuntimeError(f"isolated ADB device table NOT empty before emulator: {rows}")
        self.state["initially_empty"] = True

        self.state["phase"] = "boot_emulator"
        self.save_state()
        with open(self.out / "logs/emulator.log", "w", encoding="utf-8") as emu_log:
            self.emu_proc = subprocess.Popen(
                [str(self.files["emulator"]), "-avd", self.avd_name,
                 "-ports", f"{self.console_port},{self.console_port + 1}",
                 "-no-window", "-no-audio", "-no-boot-anim", "-no-snapshot",
                 "-memory", "2048", "-gpu", "software", "-no-metrics"],
                env=self.env, stdout=emu_log, stderr=subprocess.STDOUT,
            )

        deadline = time.monotonic() + self.opts.boot_timeout
        online = False
        while time.monotonic() < deadline:
            if self.emu_proc.poll() is not None:
                raise RuntimeError(f"emulator exited early with code {self.emu_proc.returncode}")
            rows = parse_device_rows(self.adb("devices", use_serial=False).stdout)
            foreign = [r for r in rows if r[0] != self.serial]
            if foreign:
                raise RuntimeError(f"foreign device detected in isolated ADB: {foreign}")
            if (self.serial, "device") in rows:
                boot = self.shell("getprop sys.boot_completed", check=False).stdout.strip()
                anim = self.shell("getprop init.svc.bootanim", check=False).stdout.strip()
                if boot == "1" and anim in ("stopped", ""):
                    online = True
                    break
            time.sleep(2.0)
        if not online:
            raise TimeoutError("emulator boot timed out")

        avd_check = self.adb("emu", "avd", "name").stdout.splitlines()[0].strip()
        if avd_check != self.avd_name:
            raise RuntimeError(f"AVD name mismatch: {avd_check} != {self.avd_name}")
        api = self.shell("getprop ro.build.version.sdk").stdout.strip()
        qemu = self.shell("getprop ro.kernel.qemu").stdout.strip()
        self.state["api"] = api
        self.state["hardware"] = qemu
        if api != "36" or qemu != "1":
            raise RuntimeError(f"unexpected emulator identity: api={api}, qemu={qemu}")

    def prepare_device(self):
        self.state["phase"] = "save_settings_and_install"
        self.save_state()
        for ns, key in SETTINGS_KEYS:
            self.saved_settings[f"{ns}:{key}"] = self.read_setting(ns, key)
        self.state["saved_settings"] = dict(self.saved_settings)

        self.shell("cmd connectivity airplane-mode enable", check=False)
        self.shell("svc wifi disable", check=False)
        self.write_setting("secure", "immersive_mode_confirmations", "confirmed")
        self.write_setting("system", "accelerometer_rotation", "0")
        self.write_setting("system", "user_rotation", "1")
        self.shell("input keyevent KEYCODE_WAKEUP", check=False)
        self.shell("wm dismiss-keyguard", check=False)

        self.adb("install", "-r", str(self.files["observer_apk"]), timeout=60)
        self.adb("install", "-r", str(self.files["target_apk"]), timeout=60)
        obs_sha, obs_uid = self.verify_installed_apk(OBSERVER_PKG, self.manifest["sha256"]["observer.apk"])
        tgt_sha, tgt_uid = self.verify_installed_apk(TARGET_PKG, self.manifest["sha256"]["target.apk"])
        if obs_uid == tgt_uid:
            raise RuntimeError(f"observer and target share UID {obs_uid}")
        self.state["uids"] = {"observer": obs_uid, "target": tgt_uid}
        self.state["installed_sha256"] = {"observer.apk": obs_sha, "target.apk": tgt_sha}

        self.shell(f"ime enable {MENU_IME}")
        self.write_setting("secure", "autofill_service", AUTOFILL_SVC)
        time.sleep(1.0)

    def reset_between_scenarios(self):
        orig_ime = self.saved_settings["secure:default_input_method"]
        if orig_ime and orig_ime != "null":
            self.shell(f"ime set {sh_single_quote(orig_ime)}", check=False)
        self.shell(f"am force-stop {TARGET_PKG}", check=False)
        self.shell(f"am force-stop {OBSERVER_PKG}", check=False)
        time.sleep(0.6)
        self.shell("logcat -c")

    def switch_to_menu_ime(self):
        self.shell(f"ime set {MENU_IME}")
        current = self.read_setting("secure", "default_input_method")
        if current != MENU_IME:
            raise RuntimeError(f"failed to select {MENU_IME}; got {current}")

    def run_opted_in(self):
        self.state["phase"] = "scenario_opted_in"
        self.save_state()
        self.reset_between_scenarios()
        self.write_observer_file("mode", "visible-opted-in")
        self.write_observer_file("trigger", None)

        self.shell(f"am start -S -W -n {TARGET_PKG}/.TargetActivity --es scenario opted-in")
        self.wait_log(r"MenuFill.*event=callback .*manual=false", timeout_s=20.0, label="opted-in baseline callback")
        self.switch_to_menu_ime()

        self.wait_log(r"MenuOracle.*event=probe .*side=right", timeout_s=15.0, label="opted-in right probe")
        self.wait_log(r"MenuChoice.*event=button name=request\b", timeout_s=20.0, label="opted-in request button")
        self.wait_log(r"MenuChoice.*event=button name=noop\b", timeout_s=10.0, label="opted-in noop button")
        self.wait_log(r"MenuChoice.*event=button name=expired\b", timeout_s=10.0, label="opted-in expired button")
        # Allow IME slide-in animation & 1000ms stability window to settle before tapping.
        time.sleep(1.3)

        log_now = self.read_logcat()
        events, _ = verifier.parse_log(log_now)
        starts = [r for s, r in events if s == "MenuChoice" and r.get("event") == "start_input" and r.get("usable") == "true"]
        if not starts:
            raise RuntimeError("no usable start_input in opted-in")
        active_gen = starts[-1]["gen"]
        coords = {}
        for s, r in events:
            if s == "MenuChoice" and r.get("event") == "button" and r.get("gen") == active_gen:
                coords[r["name"]] = (int(r["x"]), int(r["y"]))
        for btn in ("noop", "expired", "request"):
            if btn not in coords:
                raise RuntimeError(f"missing settled coords for button {btn} at gen={active_gen}")

        self.shell(f"input tap {coords['noop'][0]} {coords['noop'][1]}")
        self.wait_log(r"MenuChoice.*event=noop\b", timeout_s=10.0, label="opted-in noop")
        time.sleep(1.3)

        self.shell(f"input tap {coords['expired'][0]} {coords['expired'][1]}")
        self.wait_log(r"MenuChoice.*event=rejected\b", timeout_s=10.0, label="opted-in expired rejected")
        time.sleep(1.3)

        self.shell(f"input tap {coords['request'][0]} {coords['request'][1]}")
        self.wait_log(r"MenuFill.*result=\{", timeout_s=15.0, label="opted-in manual result")
        time.sleep(0.5)

        final_log = self.read_logcat()
        (self.out / "logs/opted-in.log").write_text(final_log, encoding="utf-8")
        verdict = verifier.verify(final_log, "opted-in")
        self.state["scenarios"]["opted-in"] = verdict
        self.save_state()

    def install_diffsig_target(self):
        self.state["phase"] = "install_diffsig_target"
        self.save_state()
        self.reset_between_scenarios()
        self.adb("uninstall", TARGET_PKG, check=False)
        self.adb("install", str(self.files["target_diffsig_apk"]), timeout=60)
        sha, uid = self.verify_installed_apk(TARGET_PKG, self.manifest["sha256"]["target-diffsig.apk"])
        if uid == self.state["uids"]["observer"]:
            raise RuntimeError("diffsig target shares UID with observer")
        self.state["uids"]["target_diffsig"] = uid
        self.state["installed_sha256"]["target-diffsig.apk"] = sha
        self.save_state()

    def run_plain_auto(self):
        self.state["phase"] = "scenario_plain_auto"
        self.save_state()
        self.reset_between_scenarios()
        self.write_observer_file("mode", "zero-ui-uncooperative")
        self.write_observer_file("trigger", None)

        self.shell(f"am start -S -W -n {TARGET_PKG}/.TargetActivity --es scenario plain-auto")
        self.wait_log(r"MenuFill.*event=callback .*manual=false", timeout_s=20.0, label="plain-auto baseline callback")
        self.wait_log(r"MenuOracle.*event=snapshot .*side=right .*tag=initial", timeout_s=10.0, label="plain-auto initial snapshot")

        self.switch_to_menu_ime()
        self.wait_log(r"MenuChoice.*event=zero_ui_ready\b", timeout_s=15.0, label="plain-auto zero_ui_ready")
        time.sleep(1.3)

        self.write_observer_file("trigger", "noop 1")
        self.wait_log(r"MenuChoice.*event=noop\b", timeout_s=10.0, label="plain-auto noop")
        time.sleep(1.3)

        self.write_observer_file("trigger", "expired 2")
        self.wait_log(r"MenuChoice.*event=rejected\b", timeout_s=10.0, label="plain-auto rejected")
        time.sleep(1.3)

        self.write_observer_file("trigger", "request 3")
        self.wait_log(r"MenuFill.*result=\{", timeout_s=15.0, label="plain-auto manual result")
        time.sleep(0.3)
        self.request_target_snapshot()
        self.wait_log(r"MenuOracle.*event=snapshot .*side=right .*tag=requested", timeout_s=10.0, label="plain-auto post snapshot")

        final_log = self.read_logcat()
        (self.out / "logs/plain-auto.log").write_text(final_log, encoding="utf-8")
        verdict = verifier.verify(final_log, "plain-auto")
        self.state["scenarios"]["plain-auto"] = verdict
        self.save_state()

    def run_optout_no(self):
        self.state["phase"] = "scenario_optout_no"
        self.save_state()
        self.reset_between_scenarios()
        self.write_observer_file("mode", "zero-ui-uncooperative")
        self.write_observer_file("trigger", None)

        self.shell(f"am start -S -W -n {TARGET_PKG}/.TargetActivity --es scenario optout-no")
        self.wait_log(r"MenuOracle.*event=snapshot .*side=right .*tag=initial", timeout_s=15.0, label="optout-no initial snapshot")
        time.sleep(1.5)

        self.switch_to_menu_ime()
        self.wait_log(r"MenuChoice.*event=zero_ui_ready\b", timeout_s=15.0, label="optout-no zero_ui_ready")
        time.sleep(1.3)

        self.write_observer_file("trigger", "request 1")
        self.wait_log(r"MenuChoice.*event=dispatched\b", timeout_s=10.0, label="optout-no dispatched")
        time.sleep(2.5)
        self.request_target_snapshot()
        self.wait_log(r"MenuOracle.*event=snapshot .*side=right .*tag=requested", timeout_s=10.0, label="optout-no post snapshot")

        final_log = self.read_logcat()
        (self.out / "logs/optout-no.log").write_text(final_log, encoding="utf-8")
        verdict = verifier.verify(final_log, "optout-no")
        self.state["scenarios"]["optout-no"] = verdict
        self.save_state()

    def run_swallow_ic(self):
        self.state["phase"] = "scenario_swallow_ic"
        self.save_state()
        self.reset_between_scenarios()
        self.write_observer_file("mode", "zero-ui-uncooperative")
        self.write_observer_file("trigger", None)

        self.shell(f"am start -S -W -n {TARGET_PKG}/.TargetActivity --es scenario swallow-ic")
        self.wait_log(r"MenuFill.*event=callback .*manual=false", timeout_s=20.0, label="swallow-ic baseline callback")

        self.switch_to_menu_ime()
        self.wait_log(r"MenuChoice.*event=zero_ui_ready\b", timeout_s=15.0, label="swallow-ic zero_ui_ready")
        self.wait_log(r"MenuOracle.*event=probe .*side=right", timeout_s=10.0, label="swallow-ic probe")
        time.sleep(1.3)

        self.write_observer_file("trigger", "request 1")
        self.wait_log(r"MenuChoice.*event=dispatched\b", timeout_s=10.0, label="swallow-ic dispatched")
        self.wait_log(r"MenuOracle.*event=swallowed_menu\b", timeout_s=10.0, label="swallow-ic swallowed_menu")
        time.sleep(2.0)
        self.request_target_snapshot()
        self.wait_log(r"MenuOracle.*event=snapshot .*side=right .*tag=requested", timeout_s=10.0, label="swallow-ic post snapshot")

        final_log = self.read_logcat()
        (self.out / "logs/swallow-ic.log").write_text(final_log, encoding="utf-8")
        verdict = verifier.verify(final_log, "swallow-ic")
        self.state["scenarios"]["swallow-ic"] = verdict
        self.save_state()

    def cleanup(self):
        self.state["phase"] = "cleanup"
        if self.server_proc and self.server_proc.poll() is None and self.emu_proc and self.emu_proc.poll() is None:
            try:
                if self.saved_settings:
                    orig_ime = self.saved_settings.get("secure:default_input_method", "null")
                    if orig_ime != "null":
                        self.shell(f"ime set {sh_single_quote(orig_ime)}", check=False)
                    self.shell(f"am force-stop {TARGET_PKG}", check=False)
                    self.shell(f"am force-stop {OBSERVER_PKG}", check=False)
                    self.adb("uninstall", TARGET_PKG, check=False)
                    self.adb("uninstall", OBSERVER_PKG, check=False)
                    for ns, key in SETTINGS_KEYS:
                        orig = self.saved_settings[f"{ns}:{key}"]
                        self.write_setting(ns, key, orig)
                    time.sleep(0.5)
                    for ns, key in SETTINGS_KEYS:
                        orig = self.saved_settings[f"{ns}:{key}"]
                        actual = self.read_setting(ns, key)
                        self.state["restored"][f"{ns}:{key}"] = (actual == orig)
                    pkgs = self.shell("pm list packages", check=False).stdout
                    self.state["cleanup"]["packages_uninstalled"] = (
                        TARGET_PKG not in pkgs and OBSERVER_PKG not in pkgs
                    )
            except Exception as err:
                self.state["cleanup_errors"].append(f"restore_or_uninstall: {err}")

            try:
                self.adb("emu", "kill", timeout=10, check=False)
            except Exception as err:
                self.state["cleanup_errors"].append(f"emu_kill: {err}")

        if self.emu_proc is not None:
            try:
                self.emu_proc.wait(timeout=25)
            except subprocess.TimeoutExpired:
                self.emu_proc.terminate()
                try:
                    self.emu_proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    self.emu_proc.kill()
                    self.emu_proc.wait(timeout=5)
            self.state["cleanup"]["emulator_stopped"] = (self.emu_proc.poll() is not None)
        else:
            self.state["cleanup"]["emulator_stopped"] = True

        if self.server_proc is not None:
            if self.server_proc.poll() is None:
                try:
                    self.adb("kill-server", use_serial=False, timeout=10, check=False)
                except Exception:
                    pass
                try:
                    self.server_proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    self.server_proc.terminate()
                    try:
                        self.server_proc.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        self.server_proc.kill()
                        self.server_proc.wait(timeout=5)
            self.state["cleanup"]["isolated_server_stopped"] = (self.server_proc.poll() is not None)
        else:
            self.state["cleanup"]["isolated_server_stopped"] = True

        try:
            for d in (self.out / "avd", self.out / "avd-home"):
                if d.exists():
                    shutil.rmtree(d)
            self.state["cleanup"]["avd_deleted"] = (
                not (self.out / "avd").exists() and not (self.out / "avd-home").exists()
            )
        except Exception as err:
            self.state["cleanup_errors"].append(f"avd_delete: {err}")

        deadline = time.monotonic() + 10.0
        while time.monotonic() < deadline:
            if all(not port_has_listener(p) for p in self.ports):
                break
            time.sleep(0.5)
        self.state["cleanup"]["ports_released"] = all(not port_has_listener(p) for p in self.ports)
        self.state["phase"] = "closed"
        self.save_state()

    def run_all(self):
        try:
            self.start_isolated_env()
            self.prepare_device()
            self.run_opted_in()
            self.install_diffsig_target()
            self.run_plain_auto()
            self.run_optout_no()
            self.run_swallow_ic()
            self.state["status"] = "passed"
        except Exception as err:
            self.state["status"] = "failed"
            self.state["error"] = f"{type(err).__name__}: {err}"
            try:
                if self.server_proc and self.server_proc.poll() is None:
                    (self.out / "logs/failure-logcat.log").write_text(self.read_logcat(), encoding="utf-8")
            except Exception:
                pass
            raise
        finally:
            self.cleanup()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, required=True, help="directory produced by build.py")
    parser.add_argument("--emu-sdk", type=Path, required=True, help="testbench SDK with emulator & API 36 image")
    parser.add_argument("--jdk", type=Path, required=True, help="JDK 21 directory")
    parser.add_argument("--output", type=Path, required=True, help="new isolated output directory")
    parser.add_argument("--adb-port", type=int, default=5043, help="private ADB server port (never 5037)")
    parser.add_argument("--console-port", type=int, default=5590, help="even emulator console port")
    parser.add_argument("--boot-timeout", type=int, default=300)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--dry-run", action="store_true", help="validate inputs and ports offline without starting ADB/AVD")
    mode.add_argument("--run", action="store_true", help="execute the isolated API 36 AVD run")
    opts = parser.parse_args()

    files, manifest, ports, free_status = validate_inputs(opts)
    if opts.dry_run:
        plan = {
            "mode": "dry_run",
            "validated_files": {k: str(v) for k, v in files.items()},
            "apk_sha256": manifest["sha256"],
            "cert_sha256": manifest["cert_sha256"],
            "ports": {"adb": ports[0], "console": ports[1], "transport": ports[2]},
            "ports_free": free_status,
            "scenarios": [
                {"name": "opted-in", "target_apk": "target.apk", "ime_mode": "visible-opted-in"},
                {"name": "plain-auto", "target_apk": "target-diffsig.apk", "ime_mode": "zero-ui-uncooperative"},
                {"name": "optout-no", "target_apk": "target-diffsig.apk", "ime_mode": "zero-ui-uncooperative"},
                {"name": "swallow-ic", "target_apk": "target-diffsig.apk", "ime_mode": "zero-ui-uncooperative"},
            ],
        }
        if not all(free_status.values()):
            raise RuntimeError(f"one or more isolated ports are in use: {free_status}")
        print(json.dumps(plan, indent=2))
        return

    runner = IsolatedRunner(opts, files, manifest, ports)
    runner.run_all()
    print(json.dumps(runner.state, indent=2))


if __name__ == "__main__":
    main()
