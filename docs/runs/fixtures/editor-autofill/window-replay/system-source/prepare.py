"""在新目录准备 B 的实验 APK 源，沿用既有双框与选框判定。"""
import argparse
from pathlib import Path
import shutil

here = Path(__file__).resolve().parent
fixture = here.parent.parent
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("output", type=Path)
args = parser.parse_args()
args.output.mkdir()
for part in ("target", "observer"):
    shutil.copytree(fixture / part, args.output / part)
for name in ("OriginWindows.java", "OriginEvidence.java"):
    shutil.copy(here / name, args.output / "observer")


def replace(relative_path, before, after):
    path = args.output / relative_path
    text = path.read_text(encoding="utf8")
    if text.count(before) != 1:
        raise RuntimeError(f"{relative_path}: expected exactly one instrumentation point")
    path.write_text(text.replace(before, after), encoding="utf8")


replace("observer/ProbeAutofillService.java", "        // Allow queued",
        "        if (manual && o.imeMatches == 1) OriginEvidence.record(this, request, context, sample, o.imeRow.id);\n        // Allow queued")
replace("observer/ProbeAutofillService.java", "if (!cancellation.isCanceled()) callback.onSuccess(null);",
        "main.postDelayed(() -> { if (!cancellation.isCanceled()) callback.onSuccess(null); }, manual ? 3600 : 0);")
replace("observer/AndroidManifest.xml", "    </application>", """
        <service android:name=".OriginWindows" android:exported="true"
                 android:permission="android.permission.BIND_ACCESSIBILITY_SERVICE">
            <intent-filter><action android:name="android.accessibilityservice.AccessibilityService" /></intent-filter>
            <meta-data android:name="android.accessibilityservice" android:resource="@xml/origin_windows" />
        </service>
    </application>""")
(args.output / "observer/res/xml/origin_windows.xml").write_text("""<accessibility-service
    xmlns:android="http://schemas.android.com/apk/res/android"
    android:accessibilityEventTypes="typeWindowsChanged" android:accessibilityFeedbackType="feedbackGeneric"
    android:canRetrieveWindowContent="true" android:accessibilityFlags="flagRetrieveInteractiveWindows" />
""", encoding="utf8")
replace("target/TargetActivity.java", '        requested = "conflict".equals(scenario)', """
        // 只延迟既有手动请求，让宿主能在请求前独立读取 WindowManager。
        File release = new File(getFilesDir(), "origin-release");
        if (!release.isFile()) {
            try {
                File ready = new File(getFilesDir(), "origin-ready");
                if (!ready.isFile()) java.nio.file.Files.write(ready.toPath(), new byte[]{'1'});
            } catch (IOException failure) { throw new IllegalStateException(failure); }
            root.postDelayed(this::onProbedFocus, 50);
            return;
        }
        requested = "conflict".equals(scenario)""")
replace("target/TargetActivity.java", '.put("instance", instance).put("stageIndex", stageIndex)', """
                    .put("oracleTaskId", getTaskId())
                    .put("oracleAccessibilityWindow", desired.createAccessibilityNodeInfo().getWindowId())
                    .put("instance", instance).put("stageIndex", stageIndex)""")
