package dev.magina.crossappfixture;

import android.app.Activity;
import android.graphics.Matrix;
import android.graphics.Rect;
import android.graphics.RectF;
import android.os.Bundle;
import android.os.SystemClock;
import android.util.AtomicFile;
import android.view.Gravity;
import android.view.View;
import android.view.WindowManager;
import android.view.accessibility.AccessibilityNodeInfo;
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
import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.Executor;
import java.util.function.Consumer;
import org.json.JSONArray;
import org.json.JSONObject;

/** 每个新 Activity 在采样前建立一次空白右焦点，测量期间不移动焦点。 */
public final class TargetActivity extends Activity {
    private static final Set<String> ALLOWED_TRIALS = new HashSet<>(Arrays.asList(
            "west", "east", "overlap", "scaled", "match_parent", "unsupported", "opaque"));
    private EditText editor;
    private String trial;
    private int connections, requests;
    private boolean initialized;
    private Rect maximumFrame;
    private final JSONArray callbacks = new JSONArray();

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        trial = getIntent().getStringExtra("trial");
        if (trial == null || !ALLOWED_TRIALS.contains(trial))
            throw new IllegalArgumentException("unknown trial");
        final boolean unsupported = "unsupported".equals(trial);
        FrameLayout base = new FrameLayout(this);
        editor = new EditText(this) {
            @Override public InputConnection onCreateInputConnection(EditorInfo info) {
                InputConnection original = super.onCreateInputConnection(info);
                if (original == null) return null;
                synchronized (callbacks) { connections++; }
                post(TargetActivity.this::record);
                return new InputConnectionWrapper(original, false) {
                    @Override public void requestTextBoundsInfo(RectF rect, Executor executor,
                            Consumer<TextBoundsInfoResult> consumer) {
                        final int index;
                        synchronized (callbacks) { index = ++requests; }
                        final long received = SystemClock.uptimeMillis();
                        if (unsupported) {
                            try {
                                synchronized (callbacks) {
                                    callbacks.put(new JSONObject().put("request", index).put("received", received)
                                            .put("replied", SystemClock.uptimeMillis())
                                            .put("result_code", TextBoundsInfoResult.CODE_UNSUPPORTED));
                                }
                                record();
                            } catch (Exception e) { throw new IllegalStateException(e); }
                            executor.execute(() -> consumer.accept(
                                    new TextBoundsInfoResult(TextBoundsInfoResult.CODE_UNSUPPORTED)));
                            return;
                        }
                        super.requestTextBoundsInfo(rect, executor, result -> {
                            try {
                                synchronized (callbacks) {
                                    callbacks.put(new JSONObject().put("request", index).put("received", received)
                                            .put("replied", SystemClock.uptimeMillis()));
                                }
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
        FrameLayout.LayoutParams field;
        if ("match_parent".equals(trial)) {
            field = new FrameLayout.LayoutParams(
                    FrameLayout.LayoutParams.MATCH_PARENT,
                    FrameLayout.LayoutParams.WRAP_CONTENT,
                    Gravity.TOP);
            field.setMargins(24, 32, 40, 0);
        } else {
            field = new FrameLayout.LayoutParams(scaled ? 100 : 200, 70, Gravity.RIGHT | Gravity.TOP);
            field.setMargins(24, 32, scaled ? 140 : 40, 0);
        }
        if ("opaque".equals(trial)) {
            editor.setAccessibilityDelegate(new View.AccessibilityDelegate() {
                @Override public void onInitializeAccessibilityNodeInfo(View host, AccessibilityNodeInfo info) {
                    super.onInitializeAccessibilityNodeInfo(host, info);
                    info.setVisibleToUser(false);
                    info.setFocused(false);
                }
            });
        }
        base.addView(editor, field);
        setContentView(base);
        setFinishOnTouchOutside(false);
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
        } else if (focused && editor != null) {
            editor.post(this::record);
        }
    }

    private void startup() {
        if (maximumFrame == null || !editor.isAttachedToWindow()) return;
        try {
            int connSnapshot;
            synchronized (callbacks) { connSnapshot = connections; }
            JSONObject state = new JSONObject().put("task",getTaskId()).put("window_focus",hasWindowFocus())
                    .put("editor_focus",editor.isFocused()).put("connections",connSnapshot)
                    .put("display_size",new JSONArray(new int[]{maximumFrame.width(), maximumFrame.height()}));
            write(trial + "-state", state);
        } catch (Exception e) { throw new IllegalStateException(e); }
    }

    private synchronized void write(String name, JSONObject row) throws Exception {
        AtomicFile out = new AtomicFile(new File(getFilesDir(), name + ".json"));
        FileOutputStream stream = out.startWrite();
        try {
            stream.write(row.toString().getBytes(StandardCharsets.UTF_8));
            out.finishWrite(stream);
        } catch (Exception e) {
            out.failWrite(stream);
            throw e;
        }
    }

    private void record() {
        if (editor == null || !editor.isAttachedToWindow() || !editor.isFocused() || !hasWindowFocus()) return;
        if (editor.getWidth() <= 0 || editor.getHeight() <= 0) return;
        try {
            int[] xy = new int[2];
            editor.getLocationOnScreen(xy);
            Matrix matrix = new Matrix();
            editor.transformMatrixToGlobal(matrix);
            float[] values = new float[9];
            matrix.getValues(values);
            JSONObject row;
            synchronized (callbacks) {
                row = new JSONObject().put("task", getTaskId())
                        .put("window", editor.createAccessibilityNodeInfo().getWindowId())
                        .put("connections", connections).put("requests", requests)
                        .put("callbacks", new JSONArray(callbacks.toString()))
                        .put("display_size", new JSONArray(new int[]{maximumFrame.width(),maximumFrame.height()}))
                        .put("bounds", new JSONArray(new int[]{xy[0],xy[1],
                                xy[0]+Math.round(editor.getWidth()*editor.getScaleX()),
                                xy[1]+Math.round(editor.getHeight()*editor.getScaleY())}))
                        .put("local_size", new JSONArray(new int[]{editor.getWidth(),editor.getHeight()}))
                        .put("matrix", new JSONArray(values));
            }
            write(trial, row);
        } catch (Exception e) { throw new IllegalStateException(e); }
    }
}
