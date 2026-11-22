"""Prepare a separate build of the baseline observer with only a retained response and inline support."""
import argparse
import shutil
from pathlib import Path


def replace_once(path, old, new):
    source = path.read_text(encoding="utf-8")
    if source.count(old) != 1:
        raise ValueError(f"expected exactly one {old!r} in {path.name}")
    path.write_text(source.replace(old, new), encoding="utf-8")


def prepare(destination):
    here = Path(__file__).resolve().parent
    shutil.copytree(here.parent / "observer", destination)
    shutil.copyfile(here / "RetainedReply.java", destination / "RetainedReply.java")
    service = destination / "ProbeAutofillService.java"
    replace_once(service, "if (!cancellation.isCanceled()) callback.onSuccess(null);",
                 "if (!cancellation.isCanceled()) RetainedReply.deliver(request, stage, callback);")
    replace_once(service, "SaveCallback callback) { callback.onSuccess(); }",
                 'SaveCallback callback) { android.util.Log.e("RetainedReply", "UNEXPECTED_SAVE");'
                 ' callback.onFailure("save disabled"); }')
    marker = "    @Override public boolean onEvaluateFullscreenMode()"
    replace_once(destination / "ProbeIme.java", marker,
                 "    @Override public android.view.inputmethod.InlineSuggestionsRequest\n"
                 "    onCreateInlineSuggestionsRequest(android.os.Bundle unused) {\n"
                 "        return RetainedReply.inlineRequest();\n    }\n\n" + marker)
    for xml in ("autofill.xml", "method.xml"):
        replace_once(destination / "res" / "xml" / xml,
                     'xmlns:android="http://schemas.android.com/apk/res/android"',
                     'xmlns:android="http://schemas.android.com/apk/res/android"'
                     ' android:supportsInlineSuggestions="true"')


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path, help="new observer source directory")
    prepare(parser.parse_args().destination)
