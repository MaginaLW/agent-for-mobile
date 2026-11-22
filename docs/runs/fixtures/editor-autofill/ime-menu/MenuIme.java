package dev.magina.autofillobserver;

import android.content.pm.PackageManager;
import android.graphics.Rect;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.util.Log;
import android.view.Gravity;
import android.view.View;
import android.view.WindowManager;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputMethod;
import android.widget.Button;
import android.widget.LinearLayout;

import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.HashMap;
import java.util.Map;

/**
 * Supports two host-selected modes via private files/mode:
 * - visible-opted-in (default): visible 3-button IME menu requiring right-field opt-in + same signature.
 * - zero-ui-uncooperative: zero-UI IME (onEvaluateInputViewShown=false) requiring no target opt-in or signature match;
 *   host triggers noop/expired/request via private files/trigger through the exact same expiry and single-use guard.
 */
public final class MenuIme extends ProbeIme {
    static final String MODE_VISIBLE_OPTED_IN = "visible-opted-in";
    static final String MODE_ZERO_UI_UNCOOPERATIVE = "zero-ui-uncooperative";

    static Focus used;
    static long issuedAt;
    static volatile String lastMode = MODE_VISIBLE_OPTED_IN;

    private final Handler main = new Handler(Looper.getMainLooper());
    private final Map<String, Button> buttons = new HashMap<>();
    private final Map<String, String> lastReported = new HashMap<>();
    private String lastTriggerToken = "";

    static String readMode(ProbeIme ime) {
        if (ime == null) return "invalid";
        File marker = new File(ime.getFilesDir(), "mode");
        if (!marker.isFile()) return MODE_VISIBLE_OPTED_IN;
        if (marker.length() > 64) return "invalid";
        try {
            String value = new String(Files.readAllBytes(marker.toPath()), StandardCharsets.US_ASCII).trim();
            if (value.isEmpty() || MODE_VISIBLE_OPTED_IN.equals(value)) return MODE_VISIBLE_OPTED_IN;
            if (MODE_ZERO_UI_UNCOOPERATIVE.equals(value)) return MODE_ZERO_UI_UNCOOPERATIVE;
            return "invalid";
        } catch (IOException unreadable) {
            return "invalid";
        }
    }

    static boolean optedIn(ProbeIme ime, EditorInfo editor) {
        if (editor == null || !TARGET.equals(editor.packageName)) return false;
        String mode = readMode(ime);
        if (MODE_VISIBLE_OPTED_IN.equals(mode)) {
            return "dev.magina.autofilltarget.menu-test.right".equals(editor.privateImeOptions)
                && ime.getPackageManager().checkSignatures(ime.getPackageName(), TARGET)
                    == PackageManager.SIGNATURE_MATCH;
        }
        return MODE_ZERO_UI_UNCOOPERATIVE.equals(mode);
    }

    private boolean isVisibleMode() {
        return MODE_VISIBLE_OPTED_IN.equals(readMode(this));
    }

    private boolean usable(Focus focus) {
        return focus != null && focus.current() && focus.error == null
            && optedIn(this, getCurrentInputEditorInfo());
    }

    @Override public void onStartInput(EditorInfo editor, boolean restarting) {
        main.removeCallbacksAndMessages(null);
        lastReported.clear();
        super.onStartInput(editor, restarting);
        String mode = readMode(this);
        lastMode = mode;
        Focus current = active;
        boolean usableNow = usable(current);
        boolean sigMatch = getPackageManager().checkSignatures(getPackageName(), TARGET)
            == PackageManager.SIGNATURE_MATCH;
        Log.i("MenuChoice", "event=start_input ms=" + SystemClock.uptimeMillis()
            + " gen=" + (current == null ? 0 : current.generation)
            + " restarting=" + restarting + " mode=" + mode
            + " usable=" + usableNow + " ui_shown=" + isInputViewShown()
            + " sig_match=" + sigMatch);
        if (!usableNow) return;
        if (MODE_VISIBLE_OPTED_IN.equals(mode)) {
            requestVisibleMenu(current, 0);
        } else if (MODE_ZERO_UI_UNCOOPERATIVE.equals(mode)) {
            if (isInputViewShown()) requestHideSelf(0);
            Log.i("MenuChoice", "event=zero_ui_ready ms=" + SystemClock.uptimeMillis()
                + " gen=" + current.generation + " started=" + current.started
                + " ui_shown=" + isInputViewShown() + " sig_match=" + sigMatch);
            scheduleTriggerPoll(current);
        }
    }

    private void requestVisibleMenu(Focus target, int attempt) {
        main.postDelayed(() -> {
            if (active != target || !usable(target) || !isVisibleMode()) return;
            if (isInputViewShown()) {
                reportAllButtons("already_shown");
                return;
            }
            Log.i("MenuChoice", "event=request_show ms=" + SystemClock.uptimeMillis()
                + " gen=" + target.generation + " attempt=" + attempt);
            // IMMS does not auto-show the newly bound IME after SWITCH_IME when the prior IME was hidden
            // (e.g. emulator hard keyboard default). Explicitly request the visible test menu window.
            requestShowSelf(InputMethod.SHOW_EXPLICIT);
            if (attempt < 5) {
                requestVisibleMenu(target, attempt + 1);
            }
        }, attempt == 0 ? 50 : 400);
    }

    private void scheduleTriggerPoll(Focus target) {
        main.postDelayed(() -> {
            if (active != target || !usable(target) || isVisibleMode()) return;
            File trigger = new File(getFilesDir(), "trigger");
            if (trigger.isFile() && trigger.length() <= 64) {
                try {
                    String raw = new String(Files.readAllBytes(trigger.toPath()), StandardCharsets.US_ASCII).trim();
                    trigger.delete();
                    if (!raw.isEmpty() && !raw.equals(lastTriggerToken)) {
                        lastTriggerToken = raw;
                        String[] parts = raw.split("\\s+");
                        if (parts.length >= 1) choose(parts[0]);
                    }
                } catch (IOException ignored) {
                    trigger.delete();
                }
            }
            scheduleTriggerPoll(target);
        }, 100);
    }

    @Override public View onCreateInputView() {
        buttons.clear();
        lastReported.clear();
        LinearLayout choices = new LinearLayout(this);
        choices.setGravity(Gravity.CENTER);
        choices.setOrientation(LinearLayout.HORIZONTAL);
        choices.setPadding(16, 24, 16, 24);
        choices.setBackgroundColor(0xFFEEEEEE);
        for (String choice : new String[] {"noop", "expired", "request"}) {
            Button button = new Button(this);
            String label = "noop".equals(choice) ? "空操作"
                : "expired".equals(choice) ? "过期对照" : "为本测试框请求自动填充";
            button.setText(label);
            LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.WRAP_CONTENT, LinearLayout.LayoutParams.WRAP_CONTENT);
            params.setMargins(12, 0, 12, 0);
            choices.addView(button, params);
            buttons.put(choice, button);
            button.setOnClickListener(v -> choose(choice));
            button.addOnLayoutChangeListener((v, l, t, r, b, ol, ot, or, ob) ->
                v.post(() -> reportButton(choice, button, "layout")));
        }
        Log.i("MenuChoice", "event=create_input_view ms=" + SystemClock.uptimeMillis()
            + " gen=" + (active == null ? 0 : active.generation));
        return choices;
    }

    @Override public void onStartInputView(EditorInfo info, boolean restarting) {
        super.onStartInputView(info, restarting);
        Log.i("MenuChoice", "event=start_input_view ms=" + SystemClock.uptimeMillis()
            + " gen=" + (active == null ? 0 : active.generation)
            + " restarting=" + restarting + " ui_shown=" + isInputViewShown());
        scheduleButtonReports(active, "start_input_view");
    }

    @Override public void onWindowShown() {
        super.onWindowShown();
        Log.i("MenuChoice", "event=window_shown ms=" + SystemClock.uptimeMillis()
            + " gen=" + (active == null ? 0 : active.generation)
            + " ui_shown=" + isInputViewShown());
        scheduleButtonReports(active, "window_shown");
    }

    private void scheduleButtonReports(Focus target, String why) {
        if (target == null || !isVisibleMode()) return;
        for (int delay : new int[] {0, 250, 600}) {
            main.postDelayed(() -> {
                if (active == target && usable(target) && isVisibleMode()) {
                    reportAllButtons(why + "_" + delay);
                }
            }, delay);
        }
    }

    private void reportAllButtons(String why) {
        for (String choice : new String[] {"noop", "expired", "request"}) {
            Button button = buttons.get(choice);
            if (button != null) reportButton(choice, button, why);
        }
    }

    private void reportButton(String choice, Button v, String why) {
        Focus current = active;
        if (current == null || !isVisibleMode() || !v.isShown() || !v.isLaidOut() || !usable(current)) return;
        int w = v.getWidth(), h = v.getHeight();
        if (w <= 0 || h <= 0) return;
        int[] xy = new int[2];
        v.getLocationOnScreen(xy);
        int cx = xy[0] + w / 2, cy = xy[1] + h / 2;
        int maxW = 0, maxH = 0;
        WindowManager wm = getSystemService(WindowManager.class);
        if (wm != null) {
            Rect maxBounds = wm.getMaximumWindowMetrics().getBounds();
            maxW = maxBounds.width();
            maxH = maxBounds.height();
        }
        if (cx <= 0 || cy <= 0 || (maxW > 0 && cx >= maxW) || (maxH > 0 && cy >= maxH)) {
            Log.i("MenuChoice", "event=button_skip name=" + choice + " gen=" + current.generation
                + " x=" + cx + " y=" + cy + " max_w=" + maxW + " max_h=" + maxH + " why=" + why);
            return;
        }
        String key = current.generation + ":" + choice + ":" + cx + ":" + cy;
        if (key.equals(lastReported.get(choice))) return;
        lastReported.put(choice, key);
        Log.i("MenuChoice", "event=button name=" + choice + " gen=" + current.generation
            + " x=" + cx + " y=" + cy + " w=" + w + " h=" + h + " why=" + why);
    }

    private void choose(String choice) {
        Focus original = active;
        long now = SystemClock.uptimeMillis();
        if (!usable(original) || now - original.started < 1000) {
            Log.i("MenuChoice", "event=ignored name=" + choice + " ms=" + now
                + " gen=" + (original == null ? 0 : original.generation)
                + " usable=" + usable(original)
                + " age=" + (original == null ? -1 : now - original.started));
            return;
        }
        Log.i("MenuChoice", "event=" + choice + " ms=" + now + " gen=" + original.generation
            + " started=" + original.started + " ui_shown=" + isInputViewShown());
        if ("expired".equals(choice)) {
            long expires = now + 200;
            main.postDelayed(() -> submit(original, expires), 350);
        } else if ("request".equals(choice)) {
            submit(original, now + 200);
        }
    }

    private void submit(Focus original, long expires) {
        long now = SystemClock.uptimeMillis();
        if (now > expires || !usable(original) || used == original) {
            Log.i("MenuChoice", "event=rejected ms=" + now + " gen=" + original.generation
                + " expired=" + (now > expires) + " ui_shown=" + isInputViewShown());
            return;
        }
        used = original;
        issuedAt = now;
        boolean submitted = original.connection.performContextMenuAction(android.R.id.autofill);
        Log.i("MenuChoice", "event=dispatched ms=" + SystemClock.uptimeMillis()
            + " gen=" + original.generation + " submitted=" + submitted
            + " ui_shown=" + isInputViewShown());
    }

    @Override public boolean onShowInputRequested(int flags, boolean configChange) {
        boolean allow = isVisibleMode() && usable(active);
        Log.i("MenuChoice", "event=show_requested ms=" + SystemClock.uptimeMillis()
            + " gen=" + (active == null ? 0 : active.generation)
            + " flags=" + flags + " allow=" + allow);
        return allow;
    }

    @Override public boolean onEvaluateInputViewShown() {
        return isVisibleMode() && usable(active);
    }

    @Override public void onFinishInput() {
        main.removeCallbacksAndMessages(null);
        lastReported.clear();
        super.onFinishInput();
    }

    @Override public void onUnbindInput() {
        main.removeCallbacksAndMessages(null);
        lastReported.clear();
        super.onUnbindInput();
    }

    @Override public void onDestroy() {
        main.removeCallbacksAndMessages(null);
        lastReported.clear();
        super.onDestroy();
    }
}
