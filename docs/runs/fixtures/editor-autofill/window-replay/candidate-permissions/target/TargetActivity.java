package dev.magina.crossappfixture;

import android.app.Activity;
import android.graphics.Rect;
import android.os.Bundle;
import android.os.SystemClock;
import android.view.Gravity;
import android.view.View;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputConnectionWrapper;
import android.view.inputmethod.InputMethodManager;
import android.widget.EditText;
import android.widget.FrameLayout;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import org.json.JSONArray;
import org.json.JSONObject;

/** 两个等形实例。只在靶私有回执记录窗号和实际连接收到的几何查询。 */
public final class TargetActivity extends Activity {
    private Editor right;
    private boolean opened;
    private String name;
    private int requests, connections, field;
    private long lastRequest;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        name = getIntent().getStringExtra("trial");
        if (name == null || !name.matches("(named|anon|public)[12]")) throw new IllegalArgumentException("trial");
        FrameLayout root = new FrameLayout(this);
        root.setFocusableInTouchMode(true);
        EditText left = new EditText(this);
        left.setSingleLine();
        right = new Editor();
        right.setSingleLine();
        if (name.startsWith("named")) {
            right.setId(getResources().getIdentifier("focused_editor", "id", getPackageName()));
        }
        for (EditText view : new EditText[]{left, right}) {
            FrameLayout.LayoutParams box = new FrameLayout.LayoutParams(200, 70,
                    Gravity.TOP | (view == right ? Gravity.RIGHT : Gravity.LEFT));
            box.setMargins(40, 32, 40, 0);
            root.addView(view, box);
        }
        root.requestFocus();
        setContentView(root);
    }

    @Override public void onWindowFocusChanged(boolean focus) {
        super.onWindowFocusChanged(focus);
        if (focus && !opened) {
            opened = true;
            right.post(() -> {
                right.requestFocus();
                getSystemService(InputMethodManager.class).showSoftInput(right, InputMethodManager.SHOW_IMPLICIT);
                right.post(this::record);
            });
        }
    }

    private final class Editor extends EditText {
        Editor() { super(TargetActivity.this); }
        @Override public InputConnection onCreateInputConnection(EditorInfo info) {
            InputConnection ic = super.onCreateInputConnection(info);
            if (ic == null) return null;
            field = info.fieldId;
            connections++;
            post(TargetActivity.this::record);
            return new InputConnectionWrapper(ic, false) {
                @Override public boolean requestCursorUpdates(int mode, int filter) {
                    if ((filter & InputConnection.CURSOR_UPDATE_FILTER_EDITOR_BOUNDS) != 0) {
                        requests++;
                        lastRequest = SystemClock.uptimeMillis();
                        post(TargetActivity.this::record);
                    }
                    return super.requestCursorUpdates(mode, filter);
                }
            };
        }
    }

    private void record() {
        if (connections == 0 || !right.hasFocus() || !hasWindowFocus()) return;
        try {
            AccessibilityNodeInfo node = right.createAccessibilityNodeInfo();
            int[] xy = new int[2];
            right.getLocationOnScreen(xy);
            Rect r = new Rect();
            node.getBoundsInScreen(r);
            JSONObject row = new JSONObject().put("task", getTaskId()).put("window", node.getWindowId())
                    .put("right_focused", true).put("field", field).put("requests", requests)
                    .put("connections", connections).put("last_request", lastRequest)
                    .put("bounds", new JSONArray(new int[]{xy[0], xy[1], xy[0]+right.getWidth(), xy[1]+right.getHeight()}))
                    .put("node_bounds", new JSONArray(new int[]{r.left, r.top, r.right, r.bottom}));
            File tmp = new File(getFilesDir(), name + ".tmp");
            Files.write(tmp.toPath(), row.toString().getBytes(StandardCharsets.UTF_8));
            if (!tmp.renameTo(new File(getFilesDir(), name + ".json"))) throw new IllegalStateException("rename");
        } catch (Exception e) { throw new IllegalStateException("synthetic receipt", e); }
    }
}
