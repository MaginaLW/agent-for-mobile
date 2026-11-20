package dev.magina.editororigin;

import android.content.Intent;
import android.inputmethodservice.InputMethodService;
import android.os.Process;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import dev.magina.gateway.ime.EditorOriginProbe;

/** The manifest runs this IME in :ime. The Activity sends no target coordinates to the IME. */
public final class OriginProbeIme extends InputMethodService {
    private int requestedStage = -1;
    private int generation;

    @Override public void onStartInput(EditorInfo editor, boolean restarting) {
        super.onStartInput(editor, restarting);
        final int requestGeneration = ++generation;
        if (!getPackageName().equals(editor.packageName)) return;
        for (int stage = 0; stage < 4; stage++) {
            if (!(OriginProbeActivity.TAG + stage).equals(editor.privateImeOptions) || stage <= requestedStage) continue;
            InputConnection connection = getCurrentInputConnection();
            if (connection == null) return;
            requestedStage = stage;
            final int activeStage = stage;
            final int fieldId = editor.fieldId;
            EditorOriginProbe.request(connection, getMainExecutor(),
                () -> generation == requestGeneration && getCurrentInputConnection() == connection, point -> {
                Intent receipt = new Intent(OriginProbeActivity.RESULT).setPackage(getPackageName());
                receipt.putExtra("stage", activeStage).putExtra("field_id", fieldId)
                    .putExtra("ime_pid", Process.myPid());
                if (point != null) receipt.putExtra("origin", new float[]{point.x, point.y});
                if (activeStage == 0) {
                    boolean[] delivered = {false};
                    EditorOriginProbe.request(connection, callback -> getMainExecutor().execute(() -> {
                        delivered[0] = true;
                        generation++;
                        callback.run();
                    }), () -> generation == requestGeneration && getCurrentInputConnection() == connection,
                        stale -> {
                            receipt.putExtra("stale_rejected", delivered[0] && stale == null);
                            sendBroadcast(receipt);
                        });
                } else {
                    sendBroadcast(receipt);
                }
            });
            return;
        }
    }

    @Override public void onFinishInput() {
        generation++;
        super.onFinishInput();
    }
}
