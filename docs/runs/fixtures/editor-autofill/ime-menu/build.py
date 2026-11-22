"""Build experimental APKs (same-sig pair + distinct-sig target control) in a new private output directory."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import subprocess

from prepare import prepare


def sha256_file(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def cert_sha256(run_out, signer, apk, cwd):
    text = run_out(*signer, "verify", "--print-certs", apk, cwd=cwd)
    match = re.search(r"Signer #1 certificate SHA-256 digest:\s*([0-9a-fA-F]{64})", text)
    if not match:
        raise ValueError(f"could not parse signer cert digest for {apk.name}")
    return match.group(1).lower()


def build(dest, sdk, jdk):
    prepare(dest)
    platform = sdk / "platforms/android-35/android.jar"
    tools = sdk / "build-tools/35.0.0"
    env = {**os.environ, "JAVA_HOME": str(jdk)}
    env["PATH"] = str(jdk / "bin") + os.pathsep + env["PATH"]
    password_var = "IME_MENU_KEYSTORE_PASSWORD"
    other_password_var = "IME_MENU_OTHER_KEYSTORE_PASSWORD"
    env[password_var] = secrets.token_urlsafe(32)
    env[other_password_var] = secrets.token_urlsafe(32)

    def run(*args, cwd=dest):
        subprocess.run([str(arg) for arg in args], cwd=cwd, env=env, check=True)

    def run_out(*args, cwd=dest):
        res = subprocess.run([str(arg) for arg in args], cwd=cwd, env=env, check=True,
                             capture_output=True, text=True)
        return res.stdout

    key = dest / "fixture.p12"
    other_key = dest / "fixture-other.p12"
    # Disposable synthetic signing keys: primary pair shares one cert; other_key signs target-diffsig.apk.
    run(jdk / "bin/keytool.exe", "-genkeypair", "-keystore", key, "-alias", "fixture",
        "-storepass:env", password_var, "-keypass:env", password_var, "-dname", "CN=Synthetic Autofill",
        "-keyalg", "RSA", "-validity", "3")
    run(jdk / "bin/keytool.exe", "-genkeypair", "-keystore", other_key, "-alias", "other",
        "-storepass:env", other_password_var, "-keypass:env", other_password_var,
        "-dname", "CN=Synthetic Autofill Other", "-keyalg", "RSA", "-validity", "3")

    signer = (jdk / "bin/java.exe", "-jar", tools / "lib/apksigner.jar")
    for pkg in ("target", "observer"):
        src = dest / pkg
        out = dest / (pkg + "-build")
        out.mkdir()
        (out / "classes").mkdir()
        (out / "dex").mkdir()
        res = []
        if (src / "res").is_dir():
            run(tools / "aapt2.exe", "compile", "--dir", src / "res", "-o", "res.zip", cwd=out)
            res = ["res.zip"]
        run(tools / "aapt2.exe", "link", "-I", platform, "--manifest", src / "AndroidManifest.xml",
            "-o", "unsigned.apk", *res, cwd=out)
        run(jdk / "bin/javac.exe", "--release", "8", "-encoding", "UTF-8", "-g:none",
            "-classpath", platform, "-d", "classes", *src.glob("*.java"), cwd=out)
        run(jdk / "bin/jar.exe", "cf", "classes.jar", "-C", "classes", ".", cwd=out)
        run(jdk / "bin/java.exe", "-cp", tools / "lib/d8.jar", "com.android.tools.r8.D8",
            "--min-api", "34", "--lib", platform, "--output", "dex", "classes.jar", cwd=out)
        run(jdk / "bin/jar.exe", "uf", "unsigned.apk", "-C", "dex", "classes.dex", cwd=out)
        run(tools / "zipalign.exe", "-f", "4", "unsigned.apk", "aligned.apk", cwd=out)
        apk = dest / (pkg + ".apk")
        run(*signer, "sign", "--ks", key, "--ks-pass", "env:" + password_var,
            "--out", apk, "aligned.apk", cwd=out)
        run(*signer, "verify", apk, cwd=out)

    diffsig_apk = dest / "target-diffsig.apk"
    run(*signer, "sign", "--ks", other_key, "--ks-pass", "env:" + other_password_var,
        "--out", diffsig_apk, dest / "target-build/aligned.apk", cwd=dest / "target-build")
    run(*signer, "verify", diffsig_apk, cwd=dest / "target-build")

    target_cert = cert_sha256(run_out, signer, dest / "target.apk", dest)
    observer_cert = cert_sha256(run_out, signer, dest / "observer.apk", dest)
    diffsig_cert = cert_sha256(run_out, signer, diffsig_apk, dest)
    if target_cert != observer_cert:
        raise ValueError("target.apk and observer.apk signing certificates do not match")
    if diffsig_cert == observer_cert:
        raise ValueError("target-diffsig.apk must have a distinct signing certificate")

    manifest = {
        "target_apk": "target.apk",
        "observer_apk": "observer.apk",
        "target_diffsig_apk": "target-diffsig.apk",
        "sha256": {
            "target.apk": sha256_file(dest / "target.apk"),
            "observer.apk": sha256_file(dest / "observer.apk"),
            "target-diffsig.apk": sha256_file(diffsig_apk),
        },
        "cert_sha256": {
            "primary_pair": target_cert,
            "target_diffsig": diffsig_cert,
        },
        "same_cert_pair": target_cert == observer_cert,
        "distinct_diffsig_cert": diffsig_cert != observer_cert,
    }
    (dest / "build.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(manifest, indent=2))
    return manifest


if __name__ == "__main__":
    args = argparse.ArgumentParser(description=__doc__)
    args.add_argument("destination", type=Path)
    args.add_argument("--sdk", type=Path, default=os.environ.get("ANDROID_HOME"))
    args.add_argument("--jdk", type=Path, required=True)
    opts = args.parse_args()
    build(opts.destination.resolve(), opts.sdk, opts.jdk)
