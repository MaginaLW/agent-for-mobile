package dev.magina.autofilltarget;

import android.app.Activity;
import android.os.Bundle;
import android.os.SystemClock;
import android.text.InputType;
import android.util.Log;
import android.view.Gravity;
import android.view.View;
import android.view.ViewStructure;
import android.view.WindowInsets;
import android.view.inputmethod.EditorInfo;
import android.widget.EditText;
import android.widget.FrameLayout;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.UUID;
import org.json.JSONArray;
import org.json.JSONObject;

/** Left-pane Activity (Task 1) hosting an anonymous EditText on the left side of landscape. */
public final class LeftPaneActivity extends Activity {
    private final String instance = UUID.randomUUID().toString();
    private FrameLayout root;
    private Editor left;
    private boolean recorded;

    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        root = new FrameLayout(this);
        root.setBackgroundColor(0xFFFFFFFF);
        root.setFocusableInTouchMode(true);
        left = new Editor();
        FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(200, 70, Gravity.TOP | Gravity.LEFT);
        lp.setMargins(40, 32, 40, 0);
        root.addView(left, lp);
        root.requestFocus();
        setContentView(root);
        getWindow().getInsetsController().hide(WindowInsets.Type.systemBars());
        root.postDelayed(this::recordOracle, 300);
    }

    @Override public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) root.post(this::recordOracle);
    }

    private final class Editor extends EditText {
        Editor() {
            super(LeftPaneActivity.this);
            setSingleLine(true);
            setInputType(InputType.TYPE_CLASS_TEXT);
            setImeOptions(EditorInfo.IME_FLAG_NO_FULLSCREEN | EditorInfo.IME_FLAG_NO_EXTRACT_UI);
            setSaveEnabled(false);
        }

        @Override public void onProvideStructure(ViewStructure structure) {
            super.onProvideStructure(structure);
            Log.i("AssistTarget", "pane_assist_write side=left focus=" + hasFocus()
                    + " window_focus=" + hasWindowFocus() + " instance=" + instance
                    + " view=" + System.identityHashCode(this) + " tick=" + SystemClock.uptimeMillis());
        }
    }

    private static JSONArray rectOf(View v) {
        int[] xy = new int[2];
        v.getLocationOnScreen(xy);
        return new JSONArray().put(xy[0]).put(xy[1]).put(xy[0] + v.getWidth()).put(xy[1] + v.getHeight());
    }

    private void recordOracle() {
        if (recorded || !left.isAttachedToWindow() || left.getWidth() == 0) return;
        recorded = true;
        try {
            JSONObject row = new JSONObject()
                    .put("instance", instance)
                    .put("component", getComponentName().flattenToShortString())
                    .put("task", getTaskId())
                    .put("uptime_ms", SystemClock.uptimeMillis())
                    .put("windowBounds", rectOf(root))
                    .put("editorBounds", rectOf(left))
                    .put("windowId", left.createAccessibilityNodeInfo().getWindowId())
                    .put("viewId", left.getId())
                    .put("focused", left.hasFocus());
            File tmp = new File(getFilesDir(), "pane-left.tmp");
            try (FileOutputStream out = new FileOutputStream(tmp)) {
                out.write(row.toString().getBytes(StandardCharsets.UTF_8));
            }
            if (!tmp.renameTo(new File(getFilesDir(), "pane-left.json")))
                throw new IllegalStateException("rename failed");
        } catch (Exception e) {
            throw new IllegalStateException("pane-left oracle", e);
        }
    }
}
