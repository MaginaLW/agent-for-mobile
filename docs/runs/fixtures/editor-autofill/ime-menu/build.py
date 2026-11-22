"""Build two identically signed experimental APKs in a new private output directory."""
import argparse
import os
from pathlib import Path
import secrets
import subprocess

from prepare import prepare


def build(dest, sdk, jdk):
    prepare(dest)
    platform = sdk / "platforms/android-35/android.jar"
    tools = sdk / "build-tools/35.0.0"
    env = {**os.environ, "JAVA_HOME": str(jdk)}
    env["PATH"] = str(jdk / "bin") + os.pathsep + env["PATH"]
    password_var = "IME_MENU_KEYSTORE_PASSWORD"
    env[password_var] = secrets.token_urlsafe(32)

    def run(*args, cwd=dest):
        subprocess.run([str(arg) for arg in args], cwd=cwd, env=env, check=True)

    key = dest / "fixture.p12"
    # Disposable synthetic signing key. Both apps check their package signature.
    run(jdk / "bin/keytool.exe", "-genkeypair", "-keystore", key, "-alias", "fixture",
        "-storepass:env", password_var, "-keypass:env", password_var, "-dname", "CN=Synthetic Autofill",
        "-keyalg", "RSA", "-validity", "3")
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
        signer = (jdk / "bin/java.exe", "-jar", tools / "lib/apksigner.jar")
        run(*signer, "sign", "--ks", key, "--ks-pass", "env:" + password_var,
            "--out", apk, "aligned.apk", cwd=out)
        run(*signer, "verify", apk, cwd=out)


if __name__ == "__main__":
    args = argparse.ArgumentParser(description=__doc__)
    args.add_argument("destination", type=Path)
    args.add_argument("--sdk", type=Path, default=os.environ.get("ANDROID_HOME"))
    args.add_argument("--jdk", type=Path, required=True)
    opts = args.parse_args()
    build(opts.destination.resolve(), opts.sdk, opts.jdk)
