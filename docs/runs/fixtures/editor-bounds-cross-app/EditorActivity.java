package dev.magina.crossappfixture;

import android.app.Activity;
import android.graphics.Rect;
import android.os.Bundle;
import android.view.View;
import android.view.WindowManager;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputConnectionWrapper;
import android.view.inputmethod.InputMethodManager;
import android.widget.EditText;
import android.widget.FrameLayout;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import org.json.JSONArray;
import org.json.JSONObject;

public final class EditorActivity extends Activity {
    private String scenario;
    private Editor target;
    private EditText decoy;
    private boolean started, connected;
    private int exportedField;
    private int boundsRequests;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        scenario = getIntent().getStringExtra("lab_case");
        if (!("named".equals(scenario) || "not_editable".equals(scenario)
                || "missing".equals(scenario) || "conflict".equals(scenario) || "bounds_conflict".equals(scenario))) {
            throw new IllegalArgumentException("unknown scenario");
        }
        getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING);
        FrameLayout root = new FrameLayout(this);
        root.setFocusableInTouchMode(true);
        decoy = new EditText(this);
        decoy.setId(resource("other_editor"));
        decoy.setSingleLine();
        root.addView(decoy, position(264, 92));
        target = new Editor();
        target.setId("missing".equals(scenario) ? View.generateViewId() : resource("focused_editor"));
        target.setSingleLine();
        root.addView(target, position(233, 70));
        setContentView(root);
        root.requestFocus();
    }

    private int resource(String name) {
        int id = getResources().getIdentifier(name, "id", getPackageName());
        if (id == 0) throw new IllegalStateException("fixture id");
        return id;
    }

    private FrameLayout.LayoutParams position(int width, int height) {
        FrameLayout.LayoutParams box = new FrameLayout.LayoutParams(width, height);
        box.leftMargin = 43;
        box.topMargin = 120;
        return box;
    }

    @Override public void onWindowFocusChanged(boolean focused) {
        super.onWindowFocusChanged(focused);
        if (focused && !started) {
            started = true;
            target.post(() -> {
                target.requestFocus();
                getSystemService(InputMethodManager.class).showSoftInput(target, InputMethodManager.SHOW_IMPLICIT);
                target.post(this::publish);
            });
        }
    }

    private final class Editor extends EditText {
        Editor() { super(EditorActivity.this); }

        @Override public void onInitializeAccessibilityNodeInfo(AccessibilityNodeInfo info) {
            super.onInitializeAccessibilityNodeInfo(info);
            if ("not_editable".equals(scenario)) info.setEditable(false);
            if ("bounds_conflict".equals(scenario)) {
                Rect reported = new Rect();
                info.getBoundsInScreen(reported);
                reported.right += 12;
                info.setBoundsInScreen(reported);
            }
        }

        @Override public InputConnection onCreateInputConnection(EditorInfo info) {
            InputConnection original = super.onCreateInputConnection(info);
            if (original == null) return null;
            if ("conflict".equals(scenario)) info.fieldId = decoy.getId();
            exportedField = info.fieldId;
            connected = true;
            post(EditorActivity.this::publish);
            return new InputConnectionWrapper(original, false) {
                @Override public boolean requestCursorUpdates(int mode, int filter) {
                    if ((filter & InputConnection.CURSOR_UPDATE_FILTER_EDITOR_BOUNDS) != 0) {
                        boundsRequests++;
                        post(EditorActivity.this::publish);
                    }
                    return super.requestCursorUpdates(mode, filter);
                }
            };
        }
    }

    private JSONArray rect(View view) throws Exception {
        int[] p = new int[2];
        view.getLocationOnScreen(p);
        Rect box = new Rect();
        if (!view.getLocalVisibleRect(box)) throw new IllegalStateException("hidden view");
        box.offset(p[0] - view.getScrollX(), p[1] - view.getScrollY());
        return new JSONArray(new int[]{box.left, box.top, box.right, box.bottom});
    }

    private void publish() {
        if (!connected || !target.hasFocus() || !target.hasWindowFocus()) return;
        try {
            AccessibilityNodeInfo node = target.createAccessibilityNodeInfo();
            Rect reported = new Rect();
            node.getBoundsInScreen(reported);
            JSONObject result = new JSONObject().put("case", scenario).put("uid", android.os.Process.myUid())
                .put("focused", target.hasFocus() && target.hasWindowFocus())
                .put("window_id", node.getWindowId()).put("editable", node.isEditable())
                .put("field_matches_view", exportedField == target.getId())
                .put("both_named_target", target.getId() == resource("focused_editor") && exportedField == target.getId())
                .put("accessibility_rect", new JSONArray(new int[]{reported.left, reported.top, reported.right, reported.bottom}))
                .put("rect", rect(target)).put("decoy", rect(decoy)).put("bounds_requests", boundsRequests);
            File temp = new File(getFilesDir(), scenario + ".tmp");
            try (FileOutputStream output = new FileOutputStream(temp)) {
                output.write(result.toString().getBytes(StandardCharsets.UTF_8));
            }
            if (!temp.renameTo(new File(getFilesDir(), scenario + ".json"))) throw new IllegalStateException("publish");
        } catch (Exception failure) { throw new IllegalStateException("fixture receipt", failure); }
    }
}
