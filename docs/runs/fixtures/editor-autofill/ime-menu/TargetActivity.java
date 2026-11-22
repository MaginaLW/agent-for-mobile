package dev.magina.autofilltarget;

import android.app.Activity;
import android.graphics.RectF;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
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

import java.io.File;
import java.util.concurrent.Executor;
import java.util.function.Consumer;

/**
 * Empty synthetic fields covering:
 * - opted-in: explicit IMPORTANT_FOR_AUTOFILL_YES + privateImeOptions + live-connection menu witness
 * - plain-auto: unmodified stock EditText (default IMPORTANT_FOR_AUTOFILL_AUTO, zero opt-in/wrappers)
 * - optout-no: unmodified stock EditText with IMPORTANT_FOR_AUTOFILL_NO
 * - swallow-ic: custom EditText whose InputConnection swallows android.R.id.autofill and returns CODE_UNSUPPORTED
 */
public final class TargetActivity extends Activity {
    private final Handler main = new Handler(Looper.getMainLooper());
    private FrameLayout root;
    private EditText left, right;
    private String scenario = "opted-in";
    private boolean started;
    private boolean polling;

    private final Runnable snapshotPoll = new Runnable() {
        @Override public void run() {
            if (!polling) return;
            File marker = new File(getFilesDir(), "snapshot");
            if (marker.isFile()) {
                marker.delete();
                logSnapshot("requested");
            }
            main.postDelayed(this, 200);
        }
    };

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        String requested = getIntent() == null ? null : getIntent().getStringExtra("scenario");
        if (requested != null && !requested.isEmpty()) scenario = requested;
        if (!"opted-in".equals(scenario) && !"plain-auto".equals(scenario)
                && !"optout-no".equals(scenario) && !"swallow-ic".equals(scenario)) {
            throw new IllegalArgumentException("unknown scenario: " + scenario);
        }
        root = new FrameLayout(this);
        root.setFocusableInTouchMode(true);
        left = add("left", Gravity.LEFT);
        right = add("right", Gravity.RIGHT);
        root.requestFocus();
        setContentView(root);
        Log.i("MenuOracle", "event=scenario ms=" + SystemClock.uptimeMillis()
            + " name=" + scenario
            + " left_imp=" + left.getImportantForAutofill()
            + " right_imp=" + right.getImportantForAutofill()
            + " left_view_id=" + left.getId()
            + " right_view_id=" + right.getId()
            + " left_class=" + left.getClass().getSimpleName()
            + " right_class=" + right.getClass().getSimpleName());
    }

    private EditText add(String side, int gravity) {
        final EditText editor;
        if ("opted-in".equals(scenario)) {
            editor = new TrackedEditor(side, true, false);
        } else if ("swallow-ic".equals(scenario)) {
            editor = new TrackedEditor(side, false, true);
        } else {
            // Unmodified stock android.widget.EditText: zero subclass overrides, zero InputConnectionWrapper.
            editor = new EditText(this);
            editor.setSingleLine(true);
            editor.setSaveEnabled(false);
            editor.setImeOptions(EditorInfo.IME_FLAG_NO_EXTRACT_UI | EditorInfo.IME_FLAG_NO_FULLSCREEN);
            if ("optout-no".equals(scenario)) {
                editor.setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_NO);
            }
            editor.setOnFocusChangeListener((v, focused) -> logViewEvent("focus", side, v, 0, 0, null));
            editor.addOnLayoutChangeListener((v, l, t, r, b, ol, ot, or, ob) -> {
                if (l != ol || t != ot || r != or || b != ob) {
                    logViewEvent("layout", side, v, 0, 0, null);
                }
            });
        }
        FrameLayout.LayoutParams layout = new FrameLayout.LayoutParams(200, 70, Gravity.TOP | gravity);
        layout.setMargins(40, 32, 40, 0);
        root.addView(editor, layout);
        return editor;
    }

    @Override protected void onResume() {
        super.onResume();
        polling = true;
        main.removeCallbacks(snapshotPoll);
        main.postDelayed(snapshotPoll, 200);
    }

    @Override protected void onPause() {
        polling = false;
        main.removeCallbacks(snapshotPoll);
        super.onPause();
    }

    @Override protected void onDestroy() {
        polling = false;
        main.removeCallbacks(snapshotPoll);
        super.onDestroy();
    }

    @Override public void onWindowFocusChanged(boolean focused) {
        super.onWindowFocusChanged(focused);
        if (!focused || started) return;
        started = true;
        root.post(() -> {
            if (right.requestFocus()) {
                getSystemService(InputMethodManager.class).showSoftInput(right, 0);
                root.post(() -> logSnapshot("initial"));
            }
        });
    }

    @Override public void onActionModeStarted(android.view.ActionMode mode) {
        super.onActionModeStarted(mode);
        if (right != null) {
            int live = right instanceof TrackedEditor ? ((TrackedEditor) right).liveConnection() : 0;
            int latest = right instanceof TrackedEditor ? ((TrackedEditor) right).createdConnections : 0;
            logViewEvent("action_mode", "right", right, live, latest, null);
        }
    }

    private void logSnapshot(String tag) {
        if (right == null || left == null) return;
        int rLive = right instanceof TrackedEditor ? ((TrackedEditor) right).liveConnection() : 0;
        int rLatest = right instanceof TrackedEditor ? ((TrackedEditor) right).createdConnections : 0;
        logViewEvent("snapshot", "right", right, rLive, rLatest,
            "tag=" + tag + " imp=" + right.getImportantForAutofill());
        int lLive = left instanceof TrackedEditor ? ((TrackedEditor) left).liveConnection() : 0;
        int lLatest = left instanceof TrackedEditor ? ((TrackedEditor) left).createdConnections : 0;
        logViewEvent("snapshot", "left", left, lLive, lLatest,
            "tag=" + tag + " imp=" + left.getImportantForAutofill());
    }

    private static void logViewEvent(String type, String side, View view, int connection, int latestCreated, String extra) {
        int[] xy = new int[2];
        view.getLocationOnScreen(xy);
        StringBuilder sb = new StringBuilder();
        sb.append("event=").append(type)
            .append(" ms=").append(SystemClock.uptimeMillis())
            .append(" side=").append(side)
            .append(" instance=").append(System.identityHashCode(view))
            .append(" connection=").append(connection)
            .append(" latest_created=").append(latestCreated)
            .append(" focus=").append(view.hasFocus())
            .append(" win=").append(view.hasWindowFocus())
            .append(" bounds=").append(xy[0]).append(',').append(xy[1]).append(',')
            .append(xy[0] + view.getWidth()).append(',').append(xy[1] + view.getHeight());
        if (extra != null && !extra.isEmpty()) sb.append(' ').append(extra);
        Log.i("MenuOracle", sb.toString());
    }

    private final class TrackedEditor extends EditText {
        final String side;
        final boolean optedIn;
        final boolean swallowMenu;
        int createdConnections;
        int probedConnection;
        int activeMenuConnection;

        TrackedEditor(String side, boolean optedIn, boolean swallowMenu) {
            super(TargetActivity.this);
            this.side = side;
            this.optedIn = optedIn;
            this.swallowMenu = swallowMenu;
            setSingleLine(true);
            setSaveEnabled(false);
            if (optedIn) setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_YES);
            setImeOptions(EditorInfo.IME_FLAG_NO_EXTRACT_UI | EditorInfo.IME_FLAG_NO_FULLSCREEN);
            setOnFocusChangeListener((v, focused) -> event("focus", liveConnection(), null));
        }

        int liveConnection() {
            if (activeMenuConnection > 0) return activeMenuConnection;
            if (probedConnection > 0) return probedConnection;
            return createdConnections;
        }

        void event(String type, int connection, String extra) {
            logViewEvent(type, side, this, connection, createdConnections, extra);
        }

        @Override public InputConnection onCreateInputConnection(EditorInfo info) {
            InputConnection base = super.onCreateInputConnection(info);
            if (base == null) return null;
            final int mine = ++createdConnections;
            if (optedIn && this == right && isImportantForAutofill() && hasFocus()) {
                info.privateImeOptions = "dev.magina.autofilltarget.menu-test.right";
            }
            event("connect", mine, null);
            return new InputConnectionWrapper(base, false) {
                private boolean closed;

                @Override public void closeConnection() {
                    closed = true;
                    event("close", mine, null);
                    super.closeConnection();
                }

                @Override public void requestTextBoundsInfo(RectF area, Executor executor,
                        Consumer<TextBoundsInfoResult> callback) {
                    if (area.left == -3 && area.right == -3 && area.top == -3 && area.bottom == -3) {
                        probedConnection = mine;
                        activeMenuConnection = 0;
                        event("probe", mine, "closed=" + closed);
                        executor.execute(() -> callback.accept(
                            new TextBoundsInfoResult(TextBoundsInfoResult.CODE_UNSUPPORTED)));
                    } else if (swallowMenu) {
                        // WeChat parity: return CODE_UNSUPPORTED on any requestTextBoundsInfo.
                        executor.execute(() -> callback.accept(
                            new TextBoundsInfoResult(TextBoundsInfoResult.CODE_UNSUPPORTED)));
                    } else {
                        super.requestTextBoundsInfo(area, executor, callback);
                    }
                }

                @Override public boolean performContextMenuAction(int id) {
                    if (swallowMenu && id == android.R.id.autofill) {
                        event("swallowed_menu", mine, "closed=" + closed);
                        return false;
                    }
                    // Android 16 InputMethodManager.startInputInner(BOUND_TO_IMMS) unconditionally calls
                    // onCreateInputConnection() before checking !mServedConnecting, then discards that
                    // extra wrapper while keeping the prior served connection live. Guard on !closed and
                    // probedConnection rather than requiring mine == createdConnections.
                    if (id != android.R.id.autofill || TrackedEditor.this != right || closed
                            || (probedConnection > 0 && mine != probedConnection)
                            || !isImportantForAutofill() || !hasWindowFocus() || !hasFocus()) {
                        event("connection_menu_rejected", mine,
                            "id=" + id + " closed=" + closed + " probed=" + probedConnection);
                        return false;
                    }
                    activeMenuConnection = mine;
                    event("connection_menu", mine, "closed=" + closed);
                    return super.performContextMenuAction(id);
                }
            };
        }

        @Override public boolean showContextMenu() {
            event("show_context_menu", liveConnection(), null);
            return super.showContextMenu();
        }

        @Override public boolean showContextMenu(float x, float y) {
            event("show_context_menu", liveConnection(), null);
            return super.showContextMenu(x, y);
        }

        @Override public boolean onTextContextMenuItem(int id) {
            if (id == android.R.id.autofill) event("view_menu", liveConnection(), null);
            return super.onTextContextMenuItem(id);
        }

        @Override public void onProvideAutofillStructure(ViewStructure structure, int flags) {
            super.onProvideAutofillStructure(structure, flags);
            event("structure", liveConnection(), null);
        }
    }
}
