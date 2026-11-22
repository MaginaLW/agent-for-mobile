"""Create separate synthetic APK inputs; the baseline does not register an assistant."""
import argparse
import shutil
from pathlib import Path


def change(path, old, new):
    source = path.read_text(encoding="utf-8")
    if source.count(old) != 1:
        raise ValueError(f"unexpected baseline for {path.name}")
    path.write_text(source.replace(old, new), encoding="utf-8")


def prepare(out):
    here = Path(__file__).resolve().parent
    out.mkdir()
    for package in ("observer", "target"):
        shutil.copytree(here.parent / package, out / package)
    observer = out / "observer"
    for java in here.glob("*.java"):
        shutil.copyfile(java, observer / java.name)
    shutil.copyfile(here / "voice.xml", observer / "res/xml/voice.xml")
    services = """
        <service android:name=".AssistService" android:exported="true"
            android:permission="android.permission.BIND_VOICE_INTERACTION">
            <intent-filter><action android:name="android.service.voice.VoiceInteractionService"/></intent-filter>
            <meta-data android:name="android.voice_interaction" android:resource="@xml/voice"/>
        </service>
        <service android:name=".AssistSessionService" android:exported="true"
            android:permission="android.permission.BIND_VOICE_INTERACTION" />
        <service android:name=".SilentRecognition" android:exported="true"
            android:permission="android.permission.BIND_SPEECH_RECOGNITION_SERVICE">
            <intent-filter><action android:name="android.speech.RecognitionService"/></intent-filter>
        </service>
"""
    change(observer / "AndroidManifest.xml", "    </application>", services + "    </application>")
    target = out / "target/TargetActivity.java"
    change(target, "int connectionStage = stageIndex;",
           "int connectionStage = stageIndex;\n            final int wire = connections;")
    marker = "                    if (area.left == -3 && area.top == -3 && area.right == -3 && area.bottom == -3) {"
    change(target, marker, """
                    if ((area.left == -3 || area.left == -4) && area.left == area.top
                            && area.left == area.right && area.left == area.bottom) {
                        android.util.Log.i("AssistTarget", "wire=" + wire + " probe=" + (int) area.left
                            + " side=" + side(Editor.this) + " instance=" + instance
                            + " view=" + System.identityHashCode(Editor.this) + " tick=" + SystemClock.uptimeMillis());
                        if (area.left == -4) {
                            executor.execute(() -> callback.accept(
                                new TextBoundsInfoResult(TextBoundsInfoResult.CODE_UNSUPPORTED)));
                            return;
                        }
                    }
""" + marker)
    marker = "        @Override public void onProvideAutofillStructure(ViewStructure structure, int flags) {"
    change(target, marker, """        @Override public void onProvideStructure(ViewStructure structure) {
            super.onProvideStructure(structure);
            android.util.Log.i("AssistTarget", "assist_write side=" + side(this) + " focus=" + hasFocus()
                + " window_focus=" + hasWindowFocus() + " instance=" + instance
                + " view=" + System.identityHashCode(this) + " tick=" + SystemClock.uptimeMillis());
        }

""" + marker)


if __name__ == "__main__":
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("destination", type=Path, help="new directory")
    prepare(p.parse_args().destination)
