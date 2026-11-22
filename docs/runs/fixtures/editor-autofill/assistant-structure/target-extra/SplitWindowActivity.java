package dev.magina.autofilltarget;

import android.app.Activity;
import android.app.Dialog;
import android.graphics.Rect;
import android.graphics.RectF;
import android.os.Bundle;
import android.os.SystemClock;
import android.text.InputType;
import android.util.Log;
import android.view.Gravity;
import android.view.View;
import android.view.ViewStructure;
import android.view.Window;
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

/** Two OS windows owned by the same Activity/package in landscape (main left + dialog right). */
public final class SplitWindowActivity extends Activity {
    private final String instance = UUID.randomUUID().toString();
    private FrameLayout leftRoot, rightRoot;
    private Editor left, right;
    private Dialog rightDialog;
    private boolean dialogShown, recorded;

    @Override protected void onCreate(Bundle state) {
        super.onCreate(state);
        Rect max = getWindowManager().getMaximumWindowMetrics().getBounds();
        int paneW = Math.min(1000, Math.max(400, max.width() / 2 - 80));
        int paneH = Math.min(480, Math.max(240, max.height() - 120));

        leftRoot = new FrameLayout(this);
        leftRoot.setBackgroundColor(0xFFFFFFFF);
        leftRoot.setFocusableInTouchMode(true);
        left = new Editor("left");
        FrameLayout.LayoutParams lp = new FrameLayout.LayoutParams(200, 70, Gravity.TOP | Gravity.LEFT);
        lp.setMargins(40, 32, 40, 0);
        leftRoot.addView(left, lp);
        leftRoot.requestFocus();
        setContentView(leftRoot);
        positionWindow(getWindow(), 40, 40, paneW, paneH);

        rightDialog = new Dialog(this, android.R.style.Theme_Material_Light_NoActionBar);
        rightRoot = new FrameLayout(this);
        rightRoot.setBackgroundColor(0xFFF4F6FA);
        right = new Editor("right");
        FrameLayout.LayoutParams rp = new FrameLayout.LayoutParams(200, 70, Gravity.TOP | Gravity.RIGHT);
        rp.setMargins(40, 32, 40, 0);
        rightRoot.addView(right, rp);
        rightDialog.setContentView(rightRoot);
        rightDialog.setCancelable(false);
        Window dw = rightDialog.getWindow();
        if (dw != null) positionWindow(dw, max.width() - paneW - 40, 40, paneW, paneH);
    }

    private static void positionWindow(Window w, int x, int y, int width, int height) {
        WindowManager.LayoutParams p = w.getAttributes();
        p.gravity = Gravity.TOP | Gravity.LEFT;
        p.x = x;
        p.y = y;
        p.width = width;
        p.height = height;
        p.flags |= WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL;
        p.flags &= ~WindowManager.LayoutParams.FLAG_DIM_BEHIND;
        w.setAttributes(p);
    }

    @Override public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus && !dialogShown) {
            dialogShown = true;
            rightDialog.show();
            rightRoot.post(() -> {
                if (right.requestFocus()) {
                    getSystemService(InputMethodManager.class).showSoftInput(right, 0);
                }
            });
        }
    }

    private final class Editor extends EditText {
        final String side;
        int connections, probes;

        Editor(String side) {
            super(SplitWindowActivity.this);
            this.side = side;
            setSingleLine(true);
            setInputType(InputType.TYPE_CLASS_TEXT);
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
                        Log.i("AssistTarget", "multiwin_wire=" + wire + " probe=" + (int) area.left
                                + " side=" + side + " instance=" + instance
                                + " view=" + System.identityHashCode(Editor.this)
                                + " tick=" + SystemClock.uptimeMillis());
                        if (area.left == -3 && Editor.this == right) {
                            probes++;
                            rightRoot.post(SplitWindowActivity.this::recordOracle);
                            rightRoot.postDelayed(SplitWindowActivity.this::recordOracle, 250);
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
            Log.i("AssistTarget", "multiwin_assist_write side=" + side + " focus=" + hasFocus()
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
        if (recorded || !right.isAttachedToWindow() || !left.isAttachedToWindow()) return;
        if (!right.hasFocus() || !right.hasWindowFocus()) return;
        recorded = true;
        try {
            JSONObject row = new JSONObject()
                    .put("instance", instance)
                    .put("task", getTaskId())
                    .put("uptime_ms", SystemClock.uptimeMillis())
                    .put("leftWindowBounds", rectOf(leftRoot))
                    .put("rightWindowBounds", rectOf(rightRoot))
                    .put("leftBounds", rectOf(left))
                    .put("rightBounds", rectOf(right))
                    .put("leftWindowId", left.createAccessibilityNodeInfo().getWindowId())
                    .put("rightWindowId", right.createAccessibilityNodeInfo().getWindowId())
                    .put("leftViewId", left.getId())
                    .put("rightViewId", right.getId())
                    .put("leftFocused", left.hasFocus())
                    .put("rightFocused", right.hasFocus())
                    .put("leftWindowFocused", left.hasWindowFocus())
                    .put("rightWindowFocused", right.hasWindowFocus())
                    .put("leftConnections", left.connections)
                    .put("rightConnections", right.connections)
                    .put("rightProbeCount", right.probes);
            File tmp = new File(getFilesDir(), "multiwin-dialog.tmp");
            try (FileOutputStream out = new FileOutputStream(tmp)) {
                out.write(row.toString().getBytes(StandardCharsets.UTF_8));
            }
            if (!tmp.renameTo(new File(getFilesDir(), "multiwin-dialog.json")))
                throw new IllegalStateException("rename failed");
        } catch (Exception e) {
            throw new IllegalStateException("multiwin oracle", e);
        }
    }

    @Override protected void onDestroy() {
        if (rightDialog != null && rightDialog.isShowing()) rightDialog.dismiss();
        super.onDestroy();
    }
}
