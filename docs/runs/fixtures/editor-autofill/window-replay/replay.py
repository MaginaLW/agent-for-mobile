"""编译当前观察器，用 JDK 在临时目录运行两个同包结构窗口的离线对照。"""

import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile


here = Path(__file__).resolve().parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--jdk", type=Path, help="JDK 根目录，默认使用 JAVA_HOME 或 PATH")
parser.add_argument("--json-jar", type=Path, help="仓库单测依赖 json-20240303.jar")
args = parser.parse_args()
jdk = args.jdk or os.environ.get("JAVA_HOME")
gradle = Path(os.environ.get("GRADLE_USER_HOME", Path.home() / ".gradle"))
json_jar = args.json_jar or next(
    (gradle / "caches/modules-2/files-2.1/org.json/json/20240303").glob("*/json-20240303.jar"),
    None,
)
if not json_jar or not json_jar.is_file():
    parser.error("请用 --json-jar 指定已缓存的 json-20240303.jar")


def tool(name):
    return str(Path(jdk, "bin", name)) if jdk else name


with tempfile.TemporaryDirectory(prefix="autofill-window-replay-") as tmp:
    build = Path(tmp)
    sources = [here / "HostAndroid.java", here / "WindowReplay.java"]
    for name in ("ProbeIme", "ProbeAutofillService"):
        source = (here.parent / "observer" / (name + ".java")).read_text(encoding="utf-8")
        # 只替换 Android 类型的导入，保留 onStartInput、onFillRequest、回执和全部判定。
        source = re.sub(r"^import android\.[\w.]+\.(\w+);$",
                        r"import dev.magina.autofillobserver.HostAndroid.\1;", source, flags=re.MULTILINE)
        target = build / (name + ".java")
        target.write_text(source, encoding="utf-8")
        sources.append(target)
    log = build / "Log.java"
    log.write_text("package android.util; public class Log { public static int w(String tag, "
                   "String message) { throw new AssertionError(message); } "
                   "public static int i(String tag,String message) { return 0; } }", encoding="utf-8")
    subprocess.run([tool("javac"), "-encoding", "UTF-8", "-cp", str(json_jar),
                    "-d", tmp, *sources, log], check=True)
    subprocess.run([tool("java"), "-cp", os.pathsep.join([tmp, str(json_jar.resolve())]),
                    "dev.magina.autofillobserver.WindowReplay", tmp], check=True)
