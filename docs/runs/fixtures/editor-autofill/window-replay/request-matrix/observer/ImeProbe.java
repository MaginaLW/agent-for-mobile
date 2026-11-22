package dev.magina.publicwindow;

import android.graphics.Matrix;
import android.graphics.RectF;
import android.inputmethodservice.InputMethodService;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
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
    private final Handler main = new Handler(Looper.getMainLooper());
    private long generation, sequence;

    @Override public void onStartInput(EditorInfo info, boolean restarting) {
        super.onStartInput(info, restarting);
        long gen = ++generation;
        if (info == null || !TARGET.equals(info.packageName) || info.fieldId != -1) return;
        InputConnection connection = getCurrentInputConnection();
        if (connection == null) return;
        status(gen, "input_started");
        main.postDelayed(() -> {
            try {
                if (!current(gen, connection)) return;
                JSONArray before = WindowProbe.read();
                if (before != null) collect(gen, connection, before, new JSONArray());
                else status(gen, "no_complete_windows");
            } catch (Exception e) { status(gen, e.getClass().getSimpleName()); }
        }, 1100);
    }

    private boolean current(long gen, InputConnection connection) {
        return generation == gen && getCurrentInputConnection() == connection;
    }
    private void write(String file, JSONObject row) throws Exception {
        AtomicFile out = new AtomicFile(new File(getFilesDir(),file));
        FileOutputStream stream = out.startWrite();
        try { stream.write(row.toString().getBytes(StandardCharsets.UTF_8)); out.finishWrite(stream); }
        catch (Exception e) { out.failWrite(stream); throw e; }
    }

    private void status(long gen, String step) {
        try { write("probe-state.json", new JSONObject().put("generation",gen).put("step",step)); }
        catch (Exception e) { throw new IllegalStateException(e); }
    }
    private void collect(long gen, InputConnection connection, JSONArray before, JSONArray replies) throws Exception {
        if (!current(gen, connection)) return;
        int q = replies.length() == 0 ? -7 : -11;
        long issued = SystemClock.uptimeMillis(), id = ++sequence;
        connection.requestTextBoundsInfo(new RectF(q,q,q,q), getMainExecutor(), result -> {
            try {
                if (!current(gen, connection) || result == null || result.getResultCode() != TextBoundsInfoResult.CODE_SUCCESS) return;
                TextBoundsInfo info = result.getTextBoundsInfo();
                if (info == null || info.getStartIndex() != info.getEndIndex()) return;
                Matrix matrix = new Matrix();
                info.getMatrix(matrix);
                if (!matrix.isAffine() || !matrix.invert(new Matrix())) return;
                float[] values = new float[9];
                matrix.getValues(values);
                replies.put(new JSONObject().put("sequence",id).put("query",q)
                        .put("issued",issued).put("answered",SystemClock.uptimeMillis())
                        .put("matrix",new JSONArray(values)));
                main.postDelayed(() -> {
                    try {
                        if (!current(gen, connection)) return;
                        if (replies.length() < 2) { collect(gen,connection,before,replies); return; }
                        JSONArray after = WindowProbe.read();
                        if (after == null || !before.toString().equals(after.toString())) return;
                        JSONObject row = new JSONObject().put("generation",gen).put("replies",replies)
                                .put("before",before).put("after",after).put("closed",SystemClock.uptimeMillis());
                        write("matrix.json", row);
                    } catch (Exception e) { status(gen, e.getClass().getSimpleName()); }
                }, 150);
            } catch (Exception e) { status(gen, e.getClass().getSimpleName()); }
        });
    }

    @Override public void onFinishInput() { generation++; super.onFinishInput(); }
    @Override public void onUnbindInput() { generation++; super.onUnbindInput(); }
    @Override public boolean onEvaluateInputViewShown() { super.onEvaluateInputViewShown(); return false; }
}
