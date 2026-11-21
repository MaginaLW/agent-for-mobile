package dev.magina.autofilltarget;

import android.app.Activity;
import android.content.ComponentName;
import android.content.Intent;
import android.content.res.Configuration;
import android.graphics.RectF;
import android.os.Bundle;
import android.text.InputType;
import android.view.Gravity;
import android.view.View;
import android.view.ViewStructure;
import android.view.WindowInsets;
import android.view.autofill.AutofillManager;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputConnectionWrapper;
import android.view.inputmethod.InputMethodManager;
import android.view.inputmethod.TextBoundsInfoResult;
import android.widget.EditText;
import android.widget.FrameLayout;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.UUID;
import java.util.concurrent.Executor;
import java.util.function.Consumer;

public final class TargetActivity extends Activity {
    private String scenario;
    private FrameLayout root;
    private Editor left, right, desired, connection, probed, requested;
    private final String instance = UUID.randomUUID().toString();
    private boolean started, finished, settled;
    private int stageIndex, autofillRequests;
    private final Runnable timeout = () -> finishOracle("timeout");

    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        scenario = getIntent().getStringExtra("scenario");
        if (!"left".equals(scenario) && !"right".equals(scenario)
                && !"overlap".equals(scenario) && !"conflict".equals(scenario)) {
            throw new IllegalArgumentException("unknown scenario");
        }
        root = new FrameLayout(this);
        root.setFocusableInTouchMode(true);
        left = addEditor(Gravity.LEFT);
        right = addEditor("overlap".equals(scenario) ? Gravity.LEFT : Gravity.RIGHT);
        desired = "right".equals(scenario) ? right : left;
        root.requestFocus();
        setContentView(root);
        getWindow().getInsetsController().hide(WindowInsets.Type.systemBars());
        root.postDelayed(timeout, 15000);
    }

    @Override protected void onNewIntent(Intent intent) {
        super.onNewIntent(intent);
        if (!settled || !"left".equals(scenario) || !"right".equals(intent.getStringExtra("scenario"))
                || new File(getFilesDir(), "oracle.json").exists()) return;

        setIntent(intent);
        stageIndex++;
        scenario = "right";
        desired = right;
        connection = probed = requested = null;
        autofillRequests = 0;
        left.resetMeasurements();
        right.resetMeasurements();
        finished = settled = started = false;
        root.postDelayed(timeout, 15000);
        if (!desired.requestFocus()) {
            finishOracle("focus_unavailable");
            return;
        }
        if (hasWindowFocus()) startFocusedStage();
    }

    private Editor addEditor(int horizontalGravity) {
        Editor editor = new Editor();
        FrameLayout.LayoutParams layout = new FrameLayout.LayoutParams(200, 70,
                Gravity.TOP | horizontalGravity);
        layout.setMargins(40, 32, 40, 0);
        root.addView(editor, layout);
        return editor;
    }

    @Override public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus) startFocusedStage();
    }

    private void startFocusedStage() {
        if (started || finished) return;
        started = true;
        root.post(() -> {
            AutofillManager manager = getSystemService(AutofillManager.class);
            ComponentName service = manager == null ? null : manager.getAutofillServiceComponentName();
            if (service == null || !"dev.magina.autofillobserver".equals(service.getPackageName())) {
                finishOracle("observer_service_unavailable");
            } else if (desired.requestFocus()) {
                getSystemService(InputMethodManager.class).showSoftInput(desired, 0);
            } else {
                finishOracle("focus_unavailable");
            }
        });
    }

    private final class Editor extends EditText {
        int connections, probes, structureWrites;
        Boolean reportedFocused;

        Editor() {
            super(TargetActivity.this);
            setSingleLine(true);
            setInputType(InputType.TYPE_CLASS_TEXT);
            setImeOptions(EditorInfo.IME_FLAG_NO_FULLSCREEN | EditorInfo.IME_FLAG_NO_EXTRACT_UI);
            setImportantForAutofill(View.IMPORTANT_FOR_AUTOFILL_YES);
            setSaveEnabled(false);
        }

        void resetMeasurements() {
            connections = probes = structureWrites = 0;
            reportedFocused = null;
        }

        @Override public InputConnection onCreateInputConnection(EditorInfo info) {
            InputConnection input = super.onCreateInputConnection(info);
            if (input == null) return null;
            connection = this;
            connections++;
            int connectionStage = stageIndex;
            return new InputConnectionWrapper(input, false) {
                @Override public void requestTextBoundsInfo(RectF area, Executor executor,
                        Consumer<TextBoundsInfoResult> callback) {
                    if (area.left == -3 && area.top == -3 && area.right == -3 && area.bottom == -3) {
                        root.post(() -> {
                            if (connectionStage == stageIndex) receiveProbe(Editor.this);
                        });
                        executor.execute(() -> callback.accept(
                                new TextBoundsInfoResult(TextBoundsInfoResult.CODE_UNSUPPORTED)));
                    } else {
                        super.requestTextBoundsInfo(area, executor, callback);
                    }
                }
            };
        }

        @Override public void onProvideAutofillStructure(ViewStructure structure, int flags) {
            super.onProvideAutofillStructure(structure, flags);
            boolean focused = hasFocus();
            if ("conflict".equals(scenario)) {
                focused = this == right;
                structure.setFocused(focused);
            }
            if (!finished && autofillRequests == 1) {
                reportedFocused = focused;
                structureWrites++;
                if (left.structureWrites > 0 && right.structureWrites > 0) {
                    int structureStage = stageIndex;
                    root.post(() -> {
                        if (structureStage == stageIndex) finishOracle("observed");
                    });
                }
            }
        }
    }

    private void receiveProbe(Editor editor) {
        if (finished) return;
        editor.probes++;
        probed = editor;
        if (requested != null) return;
        if (editor != desired || connection != desired || getCurrentFocus() != desired || !hasWindowFocus()) {
            finishOracle("probe_focus_mismatch");
            return;
        }
        requested = "conflict".equals(scenario) ? right : desired;
        autofillRequests++;
        try {
            getSystemService(AutofillManager.class).requestAutofill(requested);
        } catch (RuntimeException failure) {
            finishOracle("request_error_" + failure.getClass().getSimpleName());
        }
    }

    private String side(View view) {
        if (view == left) return "left";
        if (view == right) return "right";
        return "none";
    }

    private JSONArray bounds(View view) {
        int[] location = new int[2];
        view.getLocationOnScreen(location);
        return new JSONArray().put(location[0]).put(location[1])
                .put(location[0] + view.getWidth()).put(location[1] + view.getHeight());
    }

    private void finishOracle(String status) {
        if (finished) return;
        finished = true;
        root.removeCallbacks(timeout);
        boolean landscape = getResources().getConfiguration().orientation == Configuration.ORIENTATION_LANDSCAPE;
        settled = "observed".equals(status) && connection == desired && probed == desired
                && getCurrentFocus() == desired && hasWindowFocus() && landscape && root.getWidth() > root.getHeight();
        File receipt = new File(getFilesDir(), "oracle.json");
        File temporary = new File(getFilesDir(), "oracle.tmp");
        try {
            JSONObject row = new JSONObject().put("scenario", scenario).put("status", status).put("settled", settled)
                    .put("instance", instance).put("stageIndex", stageIndex).put("samePairHandoff", stageIndex == 1)
                    .put("leftViewInstance", System.identityHashCode(left))
                    .put("rightViewInstance", System.identityHashCode(right))
                    .put("focusSide", side(getCurrentFocus())).put("connectionSide", side(connection))
                    .put("probeSide", side(probed)).put("requestedSide", side(requested))
                    .put("leftBounds", bounds(left)).put("rightBounds", bounds(right))
                    .put("leftConnections", left.connections).put("rightConnections", right.connections)
                    .put("leftProbeCount", left.probes).put("rightProbeCount", right.probes)
                    .put("leftViewId", left.getId()).put("rightViewId", right.getId())
                    .put("distinctAutofillIds", !left.getAutofillId().equals(right.getAutofillId()))
                    .put("leftStructureWrites", left.structureWrites).put("rightStructureWrites", right.structureWrites)
                    .put("leftReportedFocused", left.reportedFocused == null ? JSONObject.NULL : left.reportedFocused)
                    .put("rightReportedFocused", right.reportedFocused == null ? JSONObject.NULL : right.reportedFocused)
                    .put("landscape", landscape).put("windowWidth", root.getWidth()).put("windowHeight", root.getHeight())
                    .put("autofillRequests", autofillRequests);
            try (FileOutputStream output = new FileOutputStream(temporary)) {
                output.write(row.toString().getBytes(StandardCharsets.UTF_8));
            }
            if (!temporary.renameTo(receipt)) throw new IOException("oracle rename failed");
        } catch (IOException | JSONException failure) {
            throw new IllegalStateException("synthetic oracle", failure);
        }
    }

    @Override protected void onDestroy() {
        root.removeCallbacks(timeout);
        super.onDestroy();
    }
}
