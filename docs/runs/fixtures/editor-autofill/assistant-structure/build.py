"""Build target and observer APKs for assistant-structure in a new output directory."""
import argparse
import hashlib
import json
import os
import secrets
import subprocess
import zipfile
from pathlib import Path

from prepare import prepare


def build(dest, sdk, jdk):
    if sdk is None:
        raise ValueError("missing --sdk (or ANDROID_HOME)")
    if jdk is None:
        raise ValueError("missing --jdk (or JAVA_HOME)")
    sdk = sdk.resolve()
    jdk = jdk.resolve()
    platform = sdk / "platforms/android-35/android.jar"
    tools = sdk / "build-tools/35.0.0"
    for required in (platform, tools / "aapt2.exe", tools / "zipalign.exe",
                     tools / "lib/d8.jar", tools / "lib/apksigner.jar",
                     jdk / "bin/javac.exe", jdk / "bin/java.exe", jdk / "bin/jar.exe", jdk / "bin/keytool.exe"):
        if not required.is_file():
            raise FileNotFoundError(f"missing required build tool: {required}")

    dest.mkdir(parents=True, exist_ok=False)
    fixture = dest / "source"
    prepare(fixture)

    home = dest / "build-home"
    home.mkdir()
    password_var = "ASSIST_FIXTURE_KEYSTORE_PASSWORD"
    env = dict(os.environ,
               JAVA_HOME=str(jdk),
               ANDROID_USER_HOME=str(home),
               USERPROFILE=str(home),
               TMP=str(home),
               TEMP=str(home),
               JAVA_TOOL_OPTIONS=f'-Duser.home="{home}" -Djava.io.tmpdir="{home}"')
    env["PATH"] = str(jdk / "bin") + os.pathsep + env.get("PATH", "")
    env[password_var] = secrets.token_urlsafe(32)

    def run(*args, cwd=dest):
        subprocess.run([str(a) for a in args], cwd=cwd, env=env, check=True, timeout=90)

    key = home / "disposable.p12"
    run(jdk / "bin/keytool.exe", "-genkeypair", "-alias", "fixture", "-keyalg", "RSA",
        "-validity", "3", "-dname", "CN=Synthetic Assist Fixture",
        "-keystore", key, "-storetype", "PKCS12",
        "-storepass:env", password_var, "-keypass:env", password_var, "-noprompt")

    hashes = {}
    for pkg in ("observer", "target"):
        src = fixture / pkg
        out = dest / (pkg + "-build")
        out.mkdir()
        classes = out / "classes"
        dex = out / "dex"
        classes.mkdir()
        dex.mkdir()
        res = []
        if (src / "res").is_dir():
            run(tools / "aapt2.exe", "compile", "--dir", src / "res", "-o", out / "res.zip", cwd=out)
            res = [out / "res.zip"]
        run(tools / "aapt2.exe", "link", "-I", platform, "--manifest", src / "AndroidManifest.xml",
            "-o", out / "unsigned.apk", *res, cwd=out)
        run(jdk / "bin/javac.exe", "--release", "8", "-encoding", "UTF-8", "-g:none",
            "-classpath", platform, "-d", classes, *sorted(src.glob("*.java")), cwd=out)
        run(jdk / "bin/jar.exe", "cf", out / "classes.jar", "-C", classes, ".", cwd=out)
        run(jdk / "bin/java.exe", "-cp", tools / "lib/d8.jar", "com.android.tools.r8.D8",
            "--min-api", "34", "--lib", platform, "--output", dex, out / "classes.jar", cwd=out)
        with zipfile.ZipFile(out / "unsigned.apk", "a") as archive:
            archive.write(dex / "classes.dex", "classes.dex")
        run(tools / "zipalign.exe", "-f", "4", out / "unsigned.apk", out / "aligned.apk", cwd=out)
        apk = dest / (pkg + ".apk")
        signer = (jdk / "bin/java.exe", "-jar", tools / "lib/apksigner.jar")
        run(*signer, "sign", "--ks", key, "--ks-pass", "env:" + password_var,
            "--out", apk, out / "aligned.apk", cwd=out)
        run(*signer, "verify", apk, cwd=out)
        hashes[pkg] = hashlib.sha256(apk.read_bytes()).hexdigest()
        for item in sorted(src.rglob("*")):
            if item.is_file():
                hashes[item.relative_to(fixture).as_posix()] = hashlib.sha256(item.read_bytes()).hexdigest()

    (dest / "hashes.json").write_text(json.dumps(hashes, indent=2) + "\n", encoding="utf-8")
    return {
        "destination": str(dest),
        "target_apk": str(dest / "target.apk"),
        "observer_apk": str(dest / "observer.apk"),
        "target_sha256": hashes["target"],
        "observer_sha256": hashes["observer"],
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path, help="new output directory")
    parser.add_argument("--sdk", type=Path, default=Path(os.environ["ANDROID_HOME"]) if os.environ.get("ANDROID_HOME") else None)
    parser.add_argument("--jdk", type=Path, default=Path(os.environ["JAVA_HOME"]) if os.environ.get("JAVA_HOME") else None)
    opts = parser.parse_args()
    print(json.dumps(build(opts.destination.resolve(), opts.sdk, opts.jdk), indent=2))
