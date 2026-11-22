package dev.magina.autofilltarget;

import android.app.Activity;
import android.graphics.Rect;
import android.graphics.RectF;
import android.os.Bundle;
import android.os.SystemClock;
import android.text.InputType;
import android.util.Log;
import android.view.Gravity;
import android.view.View;
import android.view.ViewStructure;
import android.view.WindowManager;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputConnectionWrapper;
import android.view.inputmethod.InputMethodManager;
import android.view.inputmethod.TextBoundsInfoResult;
import android.widget.EditText;
import android.widget.FrameLayout;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.UUID;
import java.util.concurrent.Executor;
import java.util.function.Consumer;
import org.json.JSONArray;
import org.json.JSONObject;

/** Right-pane translucent Activity (Task 2) positioned on the right half so LeftPaneActivity stays visible. */
public final class RightPaneActivity extends Activity {
    private final String instance = UUID.randomUUID().toString();
    private FrameLayout root;
    private Editor right;
    private boolean initialized, recorded;

    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        Rect max = getWindowManager().getMaximumWindowMetrics().getBounds();
        int paneW = Math.min(1000, Math.max(400, max.width() / 2 - 80));
        int paneH = Math.min(480, Math.max(240, max.height() - 120));

        root = new FrameLayout(this);
        root.setBackgroundColor(0xFFF4F6FA);
        right = new Editor();
        FrameLayout.LayoutParams rp = new FrameLayout.LayoutParams(200, 70, Gravity.TOP | Gravity.RIGHT);
        rp.setMargins(40, 32, 40, 0);
        root.addView(right, rp);
        setContentView(root);

        WindowManager.LayoutParams p = getWindow().getAttributes();
        p.gravity = Gravity.TOP | Gravity.LEFT;
        p.x = max.width() - paneW - 40;
        p.y = 40;
        p.width = paneW;
        p.height = paneH;
        p.flags |= WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL;
        p.flags &= ~WindowManager.LayoutParams.FLAG_DIM_BEHIND;
        getWindow().setAttributes(p);
    }

    @Override public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus && !initialized) {
            initialized = true;
            root.post(() -> {
                if (right.requestFocus()) {
                    getSystemService(InputMethodManager.class).showSoftInput(right, 0);
                }
            });
        }
    }

    private final class Editor extends EditText {
        int connections, probes;

        Editor() {
            super(RightPaneActivity.this);
            setSingleLine(true);
            setInputType(InputType.TYPE_CLASS_TEXT);
            setTextColor(0xFF000000);
            setImeOptions(EditorInfo.IME_FLAG_NO_FULLSCREEN | EditorInfo.IME_FLAG_NO_EXTRACT_UI);
            setSaveEnabled(false);
        }

        @Override public InputConnection onCreateInputConnection(EditorInfo info) {
            InputConnection input = super.onCreateInputConnection(info);
            if (input == null) return null;
            final int wire = ++connections;
            return new InputConnectionWrapper(input, false) {
                @Override public void requestTextBoundsInfo(RectF area, Executor executor,
                        Consumer<TextBoundsInfoResult> callback) {
                    if ((area.left == -3 || area.left == -4) && area.left == area.top
                            && area.left == area.right && area.left == area.bottom) {
                        Log.i("AssistTarget", "pane_wire=" + wire + " probe=" + (int) area.left
                                + " side=right instance=" + instance
                                + " view=" + System.identityHashCode(Editor.this)
                                + " tick=" + SystemClock.uptimeMillis());
                        if (area.left == -3) {
                            probes++;
                            root.post(RightPaneActivity.this::recordOracle);
                            root.postDelayed(RightPaneActivity.this::recordOracle, 250);
                        }
                        executor.execute(() -> callback.accept(
                                new TextBoundsInfoResult(TextBoundsInfoResult.CODE_UNSUPPORTED)));
                        return;
                    }
                    super.requestTextBoundsInfo(area, executor, callback);
                }
            };
        }

        @Override public void onProvideStructure(ViewStructure structure) {
            super.onProvideStructure(structure);
            Log.i("AssistTarget", "pane_assist_write side=right focus=" + hasFocus()
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
        if (recorded || !right.isAttachedToWindow() || !right.hasFocus() || !hasWindowFocus()) return;
        recorded = true;
        try {
            JSONObject row = new JSONObject()
                    .put("instance", instance)
                    .put("component", getComponentName().flattenToShortString())
                    .put("task", getTaskId())
                    .put("uptime_ms", SystemClock.uptimeMillis())
                    .put("windowBounds", rectOf(root))
                    .put("editorBounds", rectOf(right))
                    .put("windowId", right.createAccessibilityNodeInfo().getWindowId())
                    .put("viewId", right.getId())
                    .put("focused", right.hasFocus())
                    .put("windowFocus", hasWindowFocus())
                    .put("connections", right.connections)
                    .put("probeCount", right.probes);
            File tmp = new File(getFilesDir(), "pane-right.tmp");
            try (FileOutputStream out = new FileOutputStream(tmp)) {
                out.write(row.toString().getBytes(StandardCharsets.UTF_8));
            }
            if (!tmp.renameTo(new File(getFilesDir(), "pane-right.json")))
                throw new IllegalStateException("rename failed");
        } catch (Exception e) {
            throw new IllegalStateException("pane-right oracle", e);
        }
    }
}
