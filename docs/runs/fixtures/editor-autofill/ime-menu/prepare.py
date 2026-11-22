"""Stage the two synthetic APK source trees in a new private directory."""
from pathlib import Path
import argparse
import shutil


def replace_once(path, old, new):
    source = path.read_text(encoding="utf-8")
    if source.count(old) != 1:
        raise ValueError(f"{path.name} does not match the fixture baseline")
    path.write_text(source.replace(old, new), encoding="utf-8")


def prepare(dest):
    here = Path(__file__).resolve().parent
    dest.mkdir(exist_ok=False)
    target = dest / "target"
    target.mkdir()
    shutil.copy(here.parent / "target" / "AndroidManifest.xml", target)
    shutil.copy(here / "TargetActivity.java", target)
    observer = dest / "observer"
    shutil.copytree(here.parent / "observer", observer)
    shutil.copy(here / "MenuIme.java", observer)
    replace_once(observer / "AndroidManifest.xml", '".ProbeIme"', '".MenuIme"')
    replace_once(observer / "ProbeIme.java", "final class ProbeIme", "class ProbeIme")
    replace_once(observer / "ProbeIme.java", "if (editor == null || !TARGET.equals(editor.packageName)) return;",
                 "if (!MenuIme.optedIn(this, editor)) return;")
    service = observer / "ProbeAutofillService.java"
    code = service.read_text(encoding="utf-8")
    marker = "    // Only the host can open"
    if code.count(marker) != 1:
        raise ValueError("service baseline changed")
    service.write_text(code.split(marker)[0] + (here / "MenuServiceTail.java.txt").read_text(encoding="utf-8"),
                       encoding="utf-8")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    prepare(parser.parse_args().destination)
