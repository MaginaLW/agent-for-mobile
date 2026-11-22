"""在新建目录编译并独立签名 target.apk 与 observer.apk，输出 hashes.json。"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import secrets
import subprocess

from prepare import prepare


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    return sha256_bytes(path.read_bytes())


def sha256_text_lf(path):
    return sha256_bytes(path.read_bytes().replace(b"\r\n", b"\n"))


def build(dest, sdk, jdk):
    prepare(dest)
    platform = sdk / "platforms/android-35/android.jar"
    tools = sdk / "build-tools/35.0.0"
    for req in (platform, tools / "aapt2.exe", tools / "zipalign.exe",
                tools / "lib/d8.jar", tools / "lib/apksigner.jar",
                jdk / "bin/javac.exe", jdk / "bin/jar.exe", jdk / "bin/java.exe", jdk / "bin/keytool.exe"):
        if not req.is_file():
            raise FileNotFoundError(f"missing required build tool: {req}")

    env = {**os.environ, "JAVA_HOME": str(jdk)}
    env["PATH"] = str(jdk / "bin") + os.pathsep + env["PATH"]

    def run(*args, cwd=dest):
        subprocess.run([str(arg) for arg in args], cwd=cwd, env=env, check=True)

    hashes = {}
    input_sha256 = {}
    for pkg in ("target", "observer"):
        src = dest / pkg
        for item in sorted(src.rglob("*")):
            if item.is_file():
                rel = item.relative_to(dest).as_posix()
                digest = sha256_text_lf(item)
                input_sha256[rel] = digest
                hashes[rel] = digest

        out = dest / (pkg + "-build")
        out.mkdir()
        (out / "classes").mkdir()
        (out / "dex").mkdir()

        # 两包使用各自独立的一次性实验签名密钥，避免任何同签特权。
        password_var = f"REQUEST_MATRIX_KS_PASS_{pkg.upper()}"
        env[password_var] = secrets.token_urlsafe(32)
        key = out / (pkg + ".p12")
        run(jdk / "bin/keytool.exe", "-genkeypair", "-keystore", key, "-alias", pkg,
            "-storepass:env", password_var, "-keypass:env", password_var,
            "-dname", f"CN=RequestMatrix {pkg}", "-keyalg", "RSA", "-validity", "3", cwd=out)

        res = []
        if (src / "res").is_dir():
            run(tools / "aapt2.exe", "compile", "--dir", src / "res", "-o", "res.zip", cwd=out)
            res = ["res.zip"]
        run(tools / "aapt2.exe", "link", "-I", platform, "--manifest", src / "AndroidManifest.xml",
            "-o", "unsigned.apk", *res, cwd=out)
        run(jdk / "bin/javac.exe", "--release", "8", "-encoding", "UTF-8", "-g:none",
            "-classpath", platform, "-d", "classes", *sorted(src.glob("*.java")), cwd=out)
        run(jdk / "bin/jar.exe", "cf", "classes.jar", "-C", "classes", ".", cwd=out)
        run(jdk / "bin/java.exe", "-cp", tools / "lib/d8.jar", "com.android.tools.r8.D8",
            "--min-api", "34", "--lib", platform, "--output", "dex", "classes.jar", cwd=out)
        run(jdk / "bin/jar.exe", "uf", "unsigned.apk", "-C", "dex", "classes.dex", cwd=out)
        run(tools / "zipalign.exe", "-f", "4", "unsigned.apk", "aligned.apk", cwd=out)
        apk = dest / (pkg + ".apk")
        signer = (jdk / "bin/java.exe", "-jar", tools / "lib/apksigner.jar")
        run(*signer, "sign", "--ks", key, "--ks-pass", "env:" + password_var,
            "--out", apk, "aligned.apk", cwd=out)
        run(*signer, "verify", apk, cwd=out)
        hashes[pkg] = sha256_file(apk)

    (dest / "hashes.json").write_text(json.dumps(hashes, indent=2) + "\n", encoding="utf-8")
    summary = {
        "compile_sdk": 35,
        "runtime_target_api": 36,
        "javac_release": 8,
        "apk_sha256": {
            "observer": hashes["observer"],
            "target": hashes["target"],
        },
        "input_sha256": dict(sorted(input_sha256.items())),
        "installed_in_this_attempt": False,
        "sampled_in_this_attempt": False,
    }
    (dest / "prepared-summary.json").write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    return summary


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--sdk", type=Path, default=Path(os.environ["ANDROID_HOME"]) if "ANDROID_HOME" in os.environ else None)
    parser.add_argument("--jdk", type=Path, required=True)
    opts = parser.parse_args()
    if opts.sdk is None:
        parser.error("--sdk or ANDROID_HOME is required")
    result = build(opts.destination.resolve(), opts.sdk.resolve(), opts.jdk.resolve())
    print(json.dumps(result, indent=2))
