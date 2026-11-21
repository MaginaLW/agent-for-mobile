package dev.magina.editororigin;

import android.content.Intent;
import android.graphics.PointF;
import android.graphics.RectF;
import android.inputmethodservice.InputMethodService;
import android.os.Handler;
import android.os.Looper;
import android.os.Process;
import android.view.inputmethod.CursorAnchorInfo;
import android.view.inputmethod.EditorBoundsInfo;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import dev.magina.gateway.ime.EditorOriginProbe;
import java.util.ArrayDeque;

/** A single immediate update per stage. CursorAnchorInfo has no request ID. */
public final class BoundsProbeIme extends InputMethodService {
    private final Handler handler = new Handler(Looper.getMainLooper());
    private int lastStage = -1;
    private Sample pending;
    private final ArrayDeque<Sample> deferred = new ArrayDeque<>();

    private static final class Sample {
        final int stage;
        final int fieldId;
        final InputConnection connection;
        boolean accepted, originReceived, anchorReceived;
        boolean testDeferred;
        int rejected, revisitedRejected;
        PointF origin;
        RectF bounds;

        Sample(int stage, int fieldId, InputConnection connection) {
            this.stage = stage;
            this.fieldId = fieldId;
            this.connection = connection;
        }
    }

    @Override public void onStartInput(EditorInfo editor, boolean restarting) {
        super.onStartInput(editor, restarting);
        pending = null;
        if (!getPackageName().equals(editor.packageName)) return;
        for (int stage = 0; stage < 4; stage++) {
            if (!(OriginProbeActivity.TAG + stage).equals(editor.privateImeOptions) || stage <= lastStage) continue;
            InputConnection connection = getCurrentInputConnection();
            if (connection == null) return;
            lastStage = stage;
            Sample sample = new Sample(stage, editor.fieldId, connection);
            pending = sample;
            sample.testDeferred = editor.extras != null && editor.extras.getBoolean(OriginProbeActivity.SESSION_CASE);
            if (sample.testDeferred) {
                for (Sample prior : deferred) {
                    if (!acceptBounds(prior, prior.bounds)) {
                        sample.rejected++;
                        if (prior.fieldId == sample.fieldId) sample.revisitedRejected++;
                    }
                }
            }
            sample.accepted = connection.requestCursorUpdates(InputConnection.CURSOR_UPDATE_IMMEDIATE,
                InputConnection.CURSOR_UPDATE_FILTER_EDITOR_BOUNDS);
            EditorOriginProbe.request(connection, getMainExecutor(),
                () -> pending == sample && getCurrentInputConnection() == connection, point -> {
                    sample.origin = point;
                    sample.originReceived = true;
                    complete(sample, false);
                });
            handler.postDelayed(() -> complete(sample, true), 3000);
            return;
        }
    }

    @Override public void onUpdateCursorAnchorInfo(CursorAnchorInfo info) {
        super.onUpdateCursorAnchorInfo(info);
        Sample sample = pending;
        if (sample == null || getCurrentInputConnection() != sample.connection || info == null) return;
        EditorBoundsInfo editor = info.getEditorBoundsInfo();
        if (editor == null || editor.getEditorBounds() == null) return;
        RectF bounds = new RectF(editor.getEditorBounds());
        info.getMatrix().mapRect(bounds);
        acceptBounds(sample, bounds);
    }

    // Preserve the recipient observed at callback entry when consumption is deferred.
    private boolean acceptBounds(Sample sample, RectF bounds) {
        if (pending != sample || getCurrentInputConnection() != sample.connection) return false;
        sample.bounds = bounds;
        sample.anchorReceived = true;
        complete(sample, false);
        return true;
    }

    private void complete(Sample sample, boolean timedOut) {
        if (pending != sample || getCurrentInputConnection() != sample.connection) return;
        if (!timedOut && !(sample.originReceived && (sample.anchorReceived || !sample.accepted))) return;
        pending = null;
        Intent receipt = new Intent(OriginProbeActivity.RESULT).setPackage(getPackageName());
        receipt.putExtra("stage", sample.stage).putExtra("field_id", sample.fieldId).putExtra("ime_pid", Process.myPid())
            .putExtra("filter_accepted", sample.accepted).putExtra("anchor_received", sample.anchorReceived)
            .putExtra("origin_received", sample.originReceived).putExtra("timeout", timedOut);
        if (sample.origin != null) receipt.putExtra("origin", new float[]{sample.origin.x, sample.origin.y});
        RectF r = sample.bounds;
        if (r != null) receipt.putExtra("observed_bounds", new float[]{r.left, r.top, r.right, r.bottom});
        if (sample.testDeferred) {
            receipt.putExtra("deferred_rejected", sample.rejected)
                .putExtra("revisited_rejected", sample.revisitedRejected);
            if (r != null) {
                if (deferred.size() == 2) deferred.removeFirst();
                deferred.addLast(sample);
            }
        }
        sendBroadcast(receipt);
    }

    @Override public void onFinishInput() {
        pending = null;
        super.onFinishInput();
    }
}
