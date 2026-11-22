package dev.magina.publicwindow;

import android.graphics.Matrix;
import android.graphics.RectF;
import android.inputmethodservice.InputMethodService;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.text.InputType;
import android.util.AtomicFile;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.TextBoundsInfo;
import android.view.inputmethod.TextBoundsInfoResult;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import org.json.JSONArray;
import org.json.JSONObject;

/** 两个屏外空区间各用自己的回调。矩阵以外的返回数据只检查空区间。 */
public final class ImeProbe extends InputMethodService {
    static final String TARGET = "dev.magina.crossappfixture";
    private static final int MAX_ATTEMPTS = 4;
    private final Handler main = new Handler(Looper.getMainLooper());
    private long generation, sequence;

    @Override public void onStartInput(EditorInfo info, boolean restarting) {
        super.onStartInput(info, restarting);
        long gen = ++generation;
        if (info == null || !TARGET.equals(info.packageName) || info.fieldId != -1) return;
        if (info.inputType == InputType.TYPE_NULL) {
            status(gen, "null_input_type");
            return;
        }
        InputConnection connection = getCurrentInputConnection();
        if (connection == null) {
            status(gen, "no_input_connection");
            return;
        }
        status(gen, "input_started");
        scheduleAttempt(gen, connection, 1, 1100);
    }

    private void scheduleAttempt(long gen, InputConnection connection, int attempt, long delayMs) {
        main.postDelayed(() -> {
            try {
                if (!current(gen, connection)) return;
                JSONArray before = WindowProbe.read();
                if (before != null) {
                    status(gen, "attempt_" + attempt + "_request_1");
                    collect(gen, connection, before, new JSONArray(), attempt);
                } else {
                    status(gen, "no_complete_windows:" + WindowProbe.lastReason + ":attempt_" + attempt);
                    if (attempt < MAX_ATTEMPTS) scheduleAttempt(gen, connection, attempt + 1, 600);
                }
            } catch (Exception e) { status(gen, e.getClass().getSimpleName() + ":" + e.getMessage()); }
        }, delayMs);
    }

    private boolean current(long gen, InputConnection connection) {
        return generation == gen && getCurrentInputConnection() == connection;
    }

    private void write(String file, JSONObject row) throws Exception {
        AtomicFile out = new AtomicFile(new File(getFilesDir(), file));
        FileOutputStream stream = out.startWrite();
        try { stream.write(row.toString().getBytes(StandardCharsets.UTF_8)); out.finishWrite(stream); }
        catch (Exception e) { out.failWrite(stream); throw e; }
    }

    private void status(long gen, String step) {
        try { write("probe-state.json", new JSONObject().put("generation", gen).put("step", step)); }
        catch (Exception e) { throw new IllegalStateException(e); }
    }

    private void collect(long gen, InputConnection connection, JSONArray before, JSONArray replies, int attempt) throws Exception {
        if (!current(gen, connection)) return;
        int q = replies.length() == 0 ? -7 : -11;
        long issued = SystemClock.uptimeMillis(), id = ++sequence;
        connection.requestTextBoundsInfo(new RectF(q, q, q, q), getMainExecutor(), result -> {
            try {
                if (!current(gen, connection)) return;
                if (result == null) { status(gen, "null_result"); return; }
                if (result.getResultCode() != TextBoundsInfoResult.CODE_SUCCESS) {
                    status(gen, "result_code_" + result.getResultCode());
                    return;
                }
                TextBoundsInfo info = result.getTextBoundsInfo();
                if (info == null || info.getStartIndex() != info.getEndIndex()) {
                    status(gen, "non_empty_bounds");
                    return;
                }
                Matrix matrix = new Matrix();
                info.getMatrix(matrix);
                if (!matrix.isAffine() || !matrix.invert(new Matrix())) {
                    status(gen, "non_invertible_matrix");
                    return;
                }
                float[] values = new float[9];
                matrix.getValues(values);
                replies.put(new JSONObject().put("sequence", id).put("query", q)
                        .put("issued", issued).put("answered", SystemClock.uptimeMillis())
                        .put("matrix", new JSONArray(values)));
                main.postDelayed(() -> {
                    try {
                        if (!current(gen, connection)) return;
                        if (replies.length() < 2) {
                            status(gen, "attempt_" + attempt + "_request_2");
                            collect(gen, connection, before, replies, attempt);
                            return;
                        }
                        JSONArray after = WindowProbe.read();
                        if (after == null) {
                            status(gen, "after_null:" + WindowProbe.lastReason + ":attempt_" + attempt);
                            if (attempt < MAX_ATTEMPTS) scheduleAttempt(gen, connection, attempt + 1, 600);
                            return;
                        }
                        if (!before.toString().equals(after.toString())) {
                            status(gen, "before_after_changed:attempt_" + attempt);
                            if (attempt < MAX_ATTEMPTS) scheduleAttempt(gen, connection, attempt + 1, 600);
                            return;
                        }
                        JSONObject row = new JSONObject().put("generation", gen).put("replies", replies)
                                .put("before", before).put("after", after).put("closed", SystemClock.uptimeMillis());
                        write("matrix.json", row);
                        status(gen, "done");
                    } catch (Exception e) { status(gen, e.getClass().getSimpleName() + ":" + e.getMessage()); }
                }, 150);
            } catch (Exception e) { status(gen, e.getClass().getSimpleName() + ":" + e.getMessage()); }
        });
    }

    @Override public void onFinishInput() { generation++; super.onFinishInput(); }
    @Override public void onUnbindInput() { generation++; super.onUnbindInput(); }
    @Override public boolean onEvaluateInputViewShown() { super.onEvaluateInputViewShown(); return false; }
}
