"""在空目录组装两款实验 App 的源文件，沿用普通权限夹具的声明。"""

import argparse
from pathlib import Path
from shutil import copyfile, copytree


def prepare(output):
    here = Path(__file__).resolve().parent
    original = here.parent / "candidate-permissions"
    output.mkdir(parents=True, exist_ok=False)
    for role in ("target", "observer"):
        dest = output / role
        dest.mkdir()
        for java in (here / role).glob("*.java"):
            copyfile(java, dest / java.name)
        manifest = (original / role / "AndroidManifest.xml").read_text(encoding="utf-8")
        if role == "target":
            style = "@android:style/Theme.Material.Light.NoActionBar.Fullscreen"
            if manifest.count(style) != 1:
                raise ValueError("target theme changed")
            manifest = manifest.replace(style, "@android:style/Theme.Material.Light.Dialog.NoActionBar")
            # 两个浮动窗跟随专用模拟器的横屏设置。
            manifest = manifest.replace(' android:screenOrientation="landscape"', "")
        else:
            copytree(original / role / "res", dest / "res")
            activity = ('<activity android:name=".LandscapeHost" android:exported="true" '
                        'android:screenOrientation="landscape" '
                        'android:theme="@android:style/Theme.Material.Light.NoActionBar.Fullscreen"/>')
            manifest = manifest.replace("</application>", activity + "\n    </application>")
        (dest / "AndroidManifest.xml").write_text(manifest, encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    prepare(parser.parse_args().output)
