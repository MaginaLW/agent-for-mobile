package dev.magina.autofillobserver;

import android.graphics.RectF;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.service.voice.VoiceInteractionService;
import android.service.voice.VoiceInteractionSession;
import android.util.Log;
import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;

public final class AssistService extends VoiceInteractionService {
    static final String TAG = "SyntheticAssist";
    private static final Set<String> STAGES = new HashSet<>(Arrays.asList(
            "assist", "noflag", "secure", "ccoptout", "obfuscated", "multiwin", "multiwin2"));
    static ProbeIme.Focus anchor;
    static String stage;
    static long requested;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private boolean ready;
    private String lastCommand = "";
    private final Runnable check = new Runnable() {
        @Override public void run() {
            if (!ready) return;
            File file = new File(getFilesDir(), "assist-command");
            if (file.isFile() && file.length() < 96) {
                try {
                    String cmd = new String(Files.readAllBytes(file.toPath()), StandardCharsets.US_ASCII).trim();
                    if (!cmd.equals(lastCommand)) {
                        lastCommand = cmd;
                        begin(cmd);
                    }
                } catch (IOException error) { Log.e(TAG, "command_read_failed"); }
            }
            handler.postDelayed(this, 250);
        }
    };

    @Override public void onReady() {
        super.onReady();
        setDisabledShowContext(VoiceInteractionSession.SHOW_WITH_SCREENSHOT);
        if (!ready) {
            ready = true;
            handler.post(check);
        }
        Log.i(TAG, "service_ready");
    }

    private void begin(String command) {
        String[] parts = command.split(" ");
        if (parts.length != 3 || !STAGES.contains(parts[0])) return;
        ProbeIme.Focus current = ProbeIme.active;
        if (current == null || !current.current() || !String.valueOf(current.generation).equals(parts[1])
                || !String.valueOf(current.started).equals(parts[2]) || stage != null) {
            Log.w(TAG, "command_rejected " + parts[0]); return;
        }
        anchor = current;
        stage = parts[0];
        requested = SystemClock.uptimeMillis();
        Bundle args = new Bundle();
        args.putString("stage", stage);
        args.putLong("requested", requested);
        int flags = "noflag".equals(stage) ? 0 : VoiceInteractionSession.SHOW_WITH_ASSIST;
        Log.i(TAG, "request " + stage + " tick=" + requested + " generation=" + anchor.generation);
        showSession(args, flags);
    }

    static void postProbe(ProbeIme.Focus focus) {
        if (focus != null && focus.current()) {
            focus.connection.requestTextBoundsInfo(new RectF(-4, -4, -4, -4),
                focus.owner.getMainExecutor(), unused -> {});
        }
    }

    @Override public void onShutdown() { stopChecks(); super.onShutdown(); }
    @Override public void onDestroy() { stopChecks(); super.onDestroy(); }
    private void stopChecks() { ready = false; handler.removeCallbacks(check); }
    @Override public void onShowSessionFailed(Bundle args) {
        String failedStage = args == null ? String.valueOf(stage) : args.getString("stage", String.valueOf(stage));
        if (stage != null && stage.equals(failedStage)) {
            stage = null;
            anchor = null;
        }
        Log.w(TAG, "session_show_failed " + failedStage);
    }
}
