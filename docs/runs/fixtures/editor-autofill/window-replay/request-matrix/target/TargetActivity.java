package dev.magina.crossappfixture;

import android.app.Activity;
import android.graphics.Matrix;
import android.graphics.Rect;
import android.graphics.RectF;
import android.os.Bundle;
import android.os.SystemClock;
import android.view.Gravity;
import android.view.WindowManager;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputConnectionWrapper;
import android.view.inputmethod.InputMethodManager;
import android.view.inputmethod.TextBoundsInfoResult;
import android.widget.EditText;
import android.widget.FrameLayout;
import java.io.File;
import java.nio.file.Files;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.Executor;
import java.util.function.Consumer;
import org.json.JSONArray;
import org.json.JSONObject;

/** 每个新 Activity 在采样前建立一次空白右焦点，测量期间不移动焦点。 */
public final class TargetActivity extends Activity {
    private EditText editor;
    private String trial;
    private int connections, requests;
    private boolean initialized;
    private Rect maximumFrame;
    private final JSONArray callbacks = new JSONArray();

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        trial = getIntent().getStringExtra("trial");
        if (!("west".equals(trial) || "east".equals(trial) || "overlap".equals(trial) || "scaled".equals(trial)))
            throw new IllegalArgumentException("unknown trial");
        FrameLayout base = new FrameLayout(this);
        editor = new EditText(this) {
            @Override public InputConnection onCreateInputConnection(EditorInfo info) {
                InputConnection original = super.onCreateInputConnection(info);
                if (original == null) return null;
                connections++;
                post(TargetActivity.this::record);
                return new InputConnectionWrapper(original, false) {
                    @Override public void requestTextBoundsInfo(RectF rect, Executor executor,
                            Consumer<TextBoundsInfoResult> consumer) {
                        final int index = ++requests;
                        final long received = SystemClock.uptimeMillis();
                        super.requestTextBoundsInfo(rect, executor, result -> {
                            try {
                                callbacks.put(new JSONObject().put("request", index).put("received", received)
                                        .put("replied", SystemClock.uptimeMillis()));
                                record();
                            } catch (Exception e) { throw new IllegalStateException(e); }
                            consumer.accept(result);
                        });
                    }
                };
            }
        };
        editor.setSingleLine();
        editor.setFocusedByDefault(true);
        boolean scaled = "scaled".equals(trial);
        editor.setPivotX(0);
        editor.setScaleX(scaled ? 2f : 1f);
        FrameLayout.LayoutParams field = new FrameLayout.LayoutParams(scaled ? 100 : 200, 70, Gravity.RIGHT | Gravity.TOP);
        field.setMargins(24, 32, scaled ? 140 : 40, 0);
        base.addView(editor, field);
        setContentView(base);
        maximumFrame = getWindowManager().getMaximumWindowMetrics().getBounds();
        WindowManager.LayoutParams p = getWindow().getAttributes();
        p.gravity = Gravity.TOP | Gravity.LEFT;
        p.width = Math.min(760, (maximumFrame.width()-160)/2);
        p.x = trial.equals("west") ? 40 : maximumFrame.width()-p.width-80;
        p.y = 112;
        p.height = 280;
        p.flags |= WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL;
        p.flags &= ~WindowManager.LayoutParams.FLAG_DIM_BEHIND;
        getWindow().setAttributes(p);
        editor.postDelayed(this::startup, 500);
    }

    @Override public void onWindowFocusChanged(boolean focused) {
        super.onWindowFocusChanged(focused);
        if (editor != null) editor.post(this::startup);
        if (focused && !initialized) {
            initialized = true;
            editor.post(() -> {
                if (editor.requestFocus() && editor.isFocused())
                    getSystemService(InputMethodManager.class).showSoftInput(editor, 0);
                startup();
                record();
            });
        }
    }

    private void startup() {
        if (maximumFrame == null || !editor.isAttachedToWindow()) return;
        try {
            JSONObject state = new JSONObject().put("task",getTaskId()).put("window_focus",hasWindowFocus())
                    .put("editor_focus",editor.isFocused()).put("connections",connections)
                    .put("display_size",new JSONArray(new int[]{maximumFrame.width(), maximumFrame.height()}));
            write(trial + "-state", state);
        } catch (Exception e) { throw new IllegalStateException(e); }
    }

    private void write(String name, JSONObject row) throws Exception {
        File tmp = new File(getFilesDir(), name + ".tmp");
        Files.write(tmp.toPath(), row.toString().getBytes(StandardCharsets.UTF_8));
        if (!tmp.renameTo(new File(getFilesDir(), name + ".json"))) throw new IllegalStateException("rename");
    }

    private void record() {
        if (editor == null || !editor.isAttachedToWindow() || !editor.isFocused() || !hasWindowFocus()) return;
        try {
            int[] xy = new int[2];
            editor.getLocationOnScreen(xy);
            Matrix matrix = new Matrix();
            editor.transformMatrixToGlobal(matrix);
            float[] values = new float[9];
            matrix.getValues(values);
            JSONObject row = new JSONObject().put("task", getTaskId())
                    .put("window", editor.createAccessibilityNodeInfo().getWindowId())
                    .put("connections", connections).put("requests", requests).put("callbacks", callbacks)
                    .put("display_size", new JSONArray(new int[]{maximumFrame.width(),maximumFrame.height()}))
                    .put("bounds", new JSONArray(new int[]{xy[0],xy[1],xy[0]+Math.round(editor.getWidth()*editor.getScaleX()),xy[1]+editor.getHeight()}))
                    .put("local_size", new JSONArray(new int[]{editor.getWidth(),editor.getHeight()}))
                    .put("matrix", new JSONArray(values));
            write(trial,row);
        } catch (Exception e) { throw new IllegalStateException(e); }
    }
}
