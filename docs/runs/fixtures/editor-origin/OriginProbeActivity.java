package dev.magina.editororigin;

import android.app.Activity;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.graphics.Rect;
import android.os.Bundle;
import android.os.Process;
import android.view.WindowManager;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputConnectionWrapper;
import android.view.inputmethod.InputMethodManager;
import android.view.inputmethod.TextBoundsInfoResult;
import android.graphics.RectF;
import android.widget.EditText;
import android.widget.FrameLayout;
import org.json.JSONArray;
import org.json.JSONObject;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.Executor;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.function.Consumer;

/** A disposable, offline target. Screen coordinates come from the real views in this process. */
public final class OriginProbeActivity extends Activity {
    static final String RESULT = "dev.magina.editororigin.RESULT";
    static final String TAG = "synthetic-origin-";
    static final String SESSION_CASE = "session_bounds";
    private final AtomicInteger originRequests = new AtomicInteger();
    private final EditText[] editors = new EditText[2];
    private final EditText[] sameOrigin = new EditText[2];
    private final JSONArray rows = new JSONArray();
    private final JSONObject report = new JSONObject();
    private int stage = -1;
    private FrameLayout frame;
    private boolean allPassed = true;
    private boolean geometry;
    private boolean sessionCase;
    private boolean focusCheck;
    final ArrayBlockingQueue<Intent> focusSamples = new ArrayBlockingQueue<>(1);

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        focusCheck = getIntent().getBooleanExtra("focus_check", false);
        sessionCase = focusCheck || getIntent().getBooleanExtra(SESSION_CASE, false);
        geometry = sessionCase || getIntent().getBooleanExtra("geometry", false);
        getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING);
        FrameLayout root = new FrameLayout(this);
        root.setFocusableInTouchMode(true);
        frame = new FrameLayout(this);
        FrameLayout.LayoutParams pane = new FrameLayout.LayoutParams(560, 450);
        pane.leftMargin = 31;
        pane.topMargin = 47;
        root.addView(frame, pane);
        for (int i = 0; i < editors.length; i++) {
            EditText editor = sessionCase ? new NoOriginEditor(this) : new EditText(this);
            int id = focusCheck ? getResources().getIdentifier(i == 0 ? "editor_a" : "editor_b", "id", getPackageName()) : 101 + i;
            if (id == 0) throw new IllegalStateException("missing fixture resource");
            editor.setId(id);
            editor.setSingleLine(true);
            editor.setSaveEnabled(false);
            FrameLayout.LayoutParams position = new FrameLayout.LayoutParams(200, 70);
            position.leftMargin = 22 + 213 * i;
            position.topMargin = 50 + 111 * i;
            if (geometry) {
                EditText decoy = new EditText(this);
                decoy.setId(201 + i);
                decoy.setSaveEnabled(false);
                FrameLayout.LayoutParams larger = new FrameLayout.LayoutParams(position);
                larger.width += 24;
                larger.height += 16;
                frame.addView(decoy, larger);
                sameOrigin[i] = decoy;
            }
            frame.addView(editor, position);
            editors[i] = editor;
        }
        setContentView(root);
        root.requestFocus();
        frame.scrollTo(7, 13);
        registerReceiver(receiver, new IntentFilter(RESULT), Context.RECEIVER_NOT_EXPORTED);
    }

    /** A standard bounds-producing editor whose separate origin query is explicitly unsupported. */
    private final class NoOriginEditor extends EditText {
        NoOriginEditor(Context context) { super(context); }

        @Override public void onInitializeAccessibilityNodeInfo(AccessibilityNodeInfo info) {
            super.onInitializeAccessibilityNodeInfo(info);
            if (focusCheck && this == editors[1] && getId() != 102) info.setEditable(false);
        }

        @Override public InputConnection onCreateInputConnection(EditorInfo attributes) {
            InputConnection editor = super.onCreateInputConnection(attributes);
            if (editor == null) return null;
            if (attributes.extras == null) attributes.extras = new Bundle();
            attributes.extras.putBoolean(SESSION_CASE, true);
            return new InputConnectionWrapper(editor, false) {
                @Override public void requestTextBoundsInfo(RectF area, Executor executor,
                        Consumer<TextBoundsInfoResult> result) {
                    originRequests.incrementAndGet();
                    executor.execute(() -> result.accept(new TextBoundsInfoResult(TextBoundsInfoResult.CODE_UNSUPPORTED)));
                }
            };
        }
    }

    @Override public void onWindowFocusChanged(boolean focused) {
        super.onWindowFocusChanged(focused);
        if (focused && stage == -1) {
            stage = 0;
            frame.post(this::startStage);
        }
    }

    private void startStage() {
        EditText active = editors[stage % 2];
        active.setPrivateImeOptions(TAG + stage);
        active.setText(stage == 1 || stage == 2 ? "SYNTHETIC" : "");
        active.requestFocus();
        getSystemService(InputMethodManager.class).showSoftInput(active, InputMethodManager.SHOW_IMPLICIT);
    }

    void continueFocusCheck(int observedStage) {
        if (!focusCheck || stage != observedStage + 1 || stage >= 4) throw new IllegalStateException("stage changed");
        if (stage == 1) {
            FrameLayout.LayoutParams size = (FrameLayout.LayoutParams) editors[0].getLayoutParams();
            size.width += 12;
            editors[0].setLayoutParams(size);
        }
        if (stage == 3) editors[1].setId(102); // Runtime ID without a matching resource entry.
        frame.post(this::startStage);
    }

    private static Rect screenRect(EditText view) {
        int[] location = new int[2];
        view.getLocationOnScreen(location);
        Rect visible = new Rect();
        if (!view.getLocalVisibleRect(visible)) throw new IllegalStateException("candidate not visible");
        visible.offset(location[0] - view.getScrollX(), location[1] - view.getScrollY());
        return visible;
    }

    private static int uniqueField(float[] origin, int[] ids, Rect... candidates) {
        int match = -1;
        for (int i = 0; origin != null && i < candidates.length; i++) {
            if (origin[0] == candidates[i].left && origin[1] == candidates[i].top) {
                if (match != -1) return -1;
                match = ids[i];
            }
        }
        return match;
    }

    private final BroadcastReceiver receiver = new BroadcastReceiver() {
        @Override public void onReceive(Context context, Intent intent) {
            if (!RESULT.equals(intent.getAction()) || stage >= 4 || intent.getIntExtra("stage", -1) != stage) return;
            try {
                EditText active = editors[stage % 2], other = editors[(stage + 1) % 2];
                Rect expected = screenRect(active), wrong = screenRect(other);
                float[] origin = intent.getFloatArrayExtra("origin");
                int match = uniqueField(origin, new int[]{active.getId(), other.getId()}, expected, wrong);
                int wrongOnly = uniqueField(origin, new int[]{other.getId()}, wrong);
                int ambiguous = uniqueField(origin, new int[]{active.getId(), other.getId()}, expected, expected);
                boolean originMatches = sessionCase ? origin == null && originRequests.get() == stage + 1
                    : match == active.getId() && wrongOnly == -1 && ambiguous == -1;
                boolean pass = originMatches
                    && active.hasFocus() && active.hasWindowFocus()
                    && intent.getIntExtra("ime_pid", -1) != Process.myPid()
                    && intent.getIntExtra("field_id", -1) == active.getId()
                    && (geometry || stage != 0 || intent.getBooleanExtra("stale_rejected", false));
                JSONObject row = new JSONObject();
                row.put("stage", stage).put("empty_editor", stage == 0 || stage == 3)
                    .put("activity_pid", Process.myPid()).put("ime_pid", intent.getIntExtra("ime_pid", -1))
                    .put("expected_field_id", active.getId()).put("observed_field_id", intent.getIntExtra("field_id", -1))
                    .put("has_input_focus", active.hasFocus()).put("has_window_focus", active.hasWindowFocus())
                    .put("expected_rect", new JSONArray(new int[]{expected.left,expected.top,expected.right,expected.bottom}))
                    .put("other_rect", new JSONArray(new int[]{wrong.left,wrong.top,wrong.right,wrong.bottom}))
                    .put("origin", origin == null ? JSONObject.NULL : new JSONArray(origin))
                    .put("matched_field", match).put("wrong_only", wrongOnly).put("ambiguous_same_origin", ambiguous)
                    .put("pass", pass);
                if (!geometry && stage == 0) row.put("stale_callback_rejected", intent.getBooleanExtra("stale_rejected", false));
                if (sessionCase) {
                    int rejected = intent.getIntExtra("deferred_rejected", -1);
                    int revisited = intent.getIntExtra("revisited_rejected", -1);
                    boolean sameFieldRevisited = stage >= 2 && !(focusCheck && stage == 3);
                    pass &= rejected == Math.min(stage, 2) && revisited == (sameFieldRevisited ? 1 : 0);
                    row.put("unsupported_origin_requests", originRequests.get())
                        .put("deferred_rejected", rejected).put("revisited_rejected", revisited);
                }
                if (geometry) {
                    Rect decoy = screenRect(sameOrigin[stage % 2]);
                    float[] measured = intent.getFloatArrayExtra("observed_bounds");
                    boolean sharedOrigin = decoy.left == expected.left && decoy.top == expected.top;
                    boolean observedTarget = sameRect(measured, expected);
                    boolean observedDecoy = sameRect(measured, decoy);
                    pass &= sharedOrigin && observedTarget && !observedDecoy && intent.getBooleanExtra("filter_accepted", false)
                        && intent.getBooleanExtra("origin_received", false) && !intent.getBooleanExtra("timeout", true);
                    row.put("decoy_field_id", sameOrigin[stage % 2].getId())
                        .put("same_origin_decoy", new JSONArray(new int[]{decoy.left,decoy.top,decoy.right,decoy.bottom}))
                        .put("mapped_editor_bounds", measured == null ? JSONObject.NULL : new JSONArray(measured))
                        .put("filter_accepted", intent.getBooleanExtra("filter_accepted", false))
                        .put("anchor_received", intent.getBooleanExtra("anchor_received", false))
                        .put("timed_out", intent.getBooleanExtra("timeout", true))
                        .put("matched_full_rect", observedTarget).put("matched_decoy", observedDecoy).put("pass", pass);
                }
                rows.put(row);
                allPassed &= pass;
                stage++;
                report.put("rows", rows).put("complete", stage == 4).put("pass", stage == 4 && allPassed);
                File partial = new File(getFilesDir(), "latest.tmp");
                try (FileOutputStream stream = new FileOutputStream(partial)) {
                    stream.write(report.toString().getBytes(StandardCharsets.UTF_8));
                }
                String prefix = focusCheck ? "focus-bounds-" : sessionCase ? "session-bounds-" : geometry ? "bounds-" : "";
                if (!partial.renameTo(new File(getFilesDir(), prefix + (stage == 4 ? "result.json" : "progress.json")))) {
                    throw new IllegalStateException("receipt rename");
                }
                if (focusCheck) focusSamples.add(new Intent(intent));
                else if (stage < 4) frame.post(OriginProbeActivity.this::startStage);
            } catch (Exception e) {
                throw new IllegalStateException("synthetic receipt", e);
            }
        }
    };

    private static boolean sameRect(float[] measured, Rect candidate) {
        return measured != null && measured[0] == candidate.left && measured[1] == candidate.top
            && measured[2] == candidate.right && measured[3] == candidate.bottom;
    }

    @Override protected void onDestroy() {
        unregisterReceiver(receiver);
        super.onDestroy();
    }
}
