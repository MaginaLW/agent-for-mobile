package dev.magina.autofilltarget;

import android.app.Activity;
import android.graphics.RectF;
import android.os.Bundle;
import android.os.SystemClock;
import android.util.Log;
import android.view.Gravity;
import android.view.View;
import android.view.ViewStructure;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputConnectionWrapper;
import android.view.inputmethod.InputMethodManager;
import android.view.inputmethod.TextBoundsInfoResult;
import android.widget.EditText;
import android.widget.FrameLayout;

import java.util.concurrent.Executor;
import java.util.function.Consumer;

/** Empty synthetic fields. The ordinary framework implementation handles the selected menu item. */
public final class TargetActivity extends Activity {
    private FrameLayout root;
    private Editor left, right;
    private boolean started;

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        root = new FrameLayout(this);
        root.setFocusableInTouchMode(true);
        left = add("left", Gravity.LEFT);
        right = add("right", Gravity.RIGHT);
        root.requestFocus();
        setContentView(root);
    }

    private Editor add(String side, int gravity) {
        Editor editor = new Editor(side);
        FrameLayout.LayoutParams layout = new FrameLayout.LayoutParams(200, 70, Gravity.TOP | gravity);
        layout.setMargins(40, 32, 40, 0);
        root.addView(editor, layout);
        return editor;
    }

    @Override public void onWindowFocusChanged(boolean focused) {
        super.onWindowFocusChanged(focused);
        if (!focused || started) return;
        started = true;
        root.post(() -> {
            if (right.requestFocus()) getSystemService(InputMethodManager.class).showSoftInput(right, 0);
        });
    }

    @Override public void onActionModeStarted(android.view.ActionMode mode) {
        super.onActionModeStarted(mode);
        if (right != null) right.event("action_mode", right.generation);
    }

    private final class Editor extends EditText {
        final String side;
        int generation;
        Editor(String side) {
            super(TargetActivity.this);
            this.side = side;
            setSingleLine(true);
            setSaveEnabled(false);
            setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_YES);
            setImeOptions(EditorInfo.IME_FLAG_NO_EXTRACT_UI | EditorInfo.IME_FLAG_NO_FULLSCREEN);
            setOnFocusChangeListener((v, focused) -> event("focus", generation));
        }
        void event(String type, int connection) {
            int[] xy = new int[2];
            getLocationOnScreen(xy);
            Log.i("MenuOracle", "event=" + type + " ms=" + SystemClock.uptimeMillis() + " side=" + side
                + " instance=" + System.identityHashCode(this) + " connection=" + connection
                + " focus=" + hasFocus() + " win=" + hasWindowFocus()
                + " bounds=" + xy[0] + "," + xy[1] + "," + (xy[0] + getWidth()) + "," + (xy[1] + getHeight()));
        }
        @Override public InputConnection onCreateInputConnection(EditorInfo info) {
            InputConnection base = super.onCreateInputConnection(info);
            if (base == null) return null;
            final int mine = ++generation;
            if (this == right && isImportantForAutofill() && hasFocus())
                info.privateImeOptions = "dev.magina.autofilltarget.menu-test.right";
            event("connect", mine);
            return new InputConnectionWrapper(base, false) {
                @Override public void requestTextBoundsInfo(RectF area, Executor executor,
                        Consumer<TextBoundsInfoResult> callback) {
                    if (area.left == -3 && area.right == -3 && area.top == -3 && area.bottom == -3) {
                        event("probe", mine);
                        executor.execute(() -> callback.accept(new TextBoundsInfoResult(TextBoundsInfoResult.CODE_UNSUPPORTED)));
                    } else super.requestTextBoundsInfo(area, executor, callback);
                }
                @Override public boolean performContextMenuAction(int id) {
                    if (id != android.R.id.autofill || Editor.this != right || mine != generation
                            || !isImportantForAutofill() || !hasWindowFocus() || !hasFocus()) return false;
                    event("connection_menu", mine);
                    return super.performContextMenuAction(id);
                }
            };
        }
        @Override public boolean showContextMenu() {
            event("show_context_menu", generation);
            return super.showContextMenu();
        }
        @Override public boolean showContextMenu(float x, float y) {
            event("show_context_menu", generation);
            return super.showContextMenu(x, y);
        }
        @Override public boolean onTextContextMenuItem(int id) {
            if (id == android.R.id.autofill) event("view_menu", generation);
            return super.onTextContextMenuItem(id);
        }
        @Override public void onProvideAutofillStructure(ViewStructure structure, int flags) {
            super.onProvideAutofillStructure(structure, flags);
            event("structure", generation);
        }
    }
}
