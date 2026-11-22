package dev.magina.autofillobserver;

import android.content.pm.PackageManager;
import android.os.SystemClock;
import android.util.Log;
import android.view.Gravity;
import android.view.View;
import android.view.inputmethod.EditorInfo;
import android.widget.Button;
import android.widget.LinearLayout;

/** No automatic trigger. A visible IME choice belongs to one explicitly opted-in synthetic connection. */
public final class MenuIme extends ProbeIme {
    static boolean optedIn(ProbeIme ime, EditorInfo editor) {
        return editor != null && TARGET.equals(editor.packageName)
            && "dev.magina.autofilltarget.menu-test.right".equals(editor.privateImeOptions)
            && ime.getPackageManager().checkSignatures(ime.getPackageName(), TARGET)
                == PackageManager.SIGNATURE_MATCH;
    }

    private boolean usable(Focus focus) {
        return focus != null && focus.current() && focus.error == null
            && optedIn(this, getCurrentInputEditorInfo());
    }

    @Override public View onCreateInputView() {
        LinearLayout choices = new LinearLayout(this);
        choices.setGravity(Gravity.CENTER);
        choices.setOrientation(LinearLayout.HORIZONTAL);
        for (String choice : new String[] {"noop", "expired", "request"}) {
            Button button = new Button(this);
            String label = "noop".equals(choice) ? "空操作"
                : "expired".equals(choice) ? "过期对照" : "为本测试框请求自动填充";
            button.setText(label);
            choices.addView(button);
            button.setOnClickListener(v -> choose(choice));
            button.addOnLayoutChangeListener((v, l, t, r, b, ol, ot, or, ob) -> v.post(() -> {
                if (!v.isShown() || !usable(active)) return;
                int[] xy = new int[2];
                v.getLocationOnScreen(xy);
                Log.i("MenuChoice", "event=button name=" + choice + " gen=" + active.generation
                    + " x=" + (xy[0] + v.getWidth() / 2) + " y=" + (xy[1] + v.getHeight() / 2));
            }));
        }
        return choices;
    }

    private void choose(String choice) {
        Focus original = active;
        long now = SystemClock.uptimeMillis();
        if (!usable(original) || now - original.started < 1000) return;
        Log.i("MenuChoice", "event=" + choice + " ms=" + now + " gen=" + original.generation
            + " started=" + original.started);
        if ("expired".equals(choice)) {
            long expires = now + 200;
            new android.os.Handler(getMainLooper()).postDelayed(() -> submit(original, expires), 350);
        } else if ("request".equals(choice)) submit(original, now + 200);
    }

    private void submit(Focus original, long expires) {
        long now = SystemClock.uptimeMillis();
        if (now > expires || !usable(original) || used == original) {
            Log.i("MenuChoice", "event=rejected ms=" + now + " gen=" + original.generation);
            return;
        }
        used = original;
        issuedAt = now;
        boolean submitted = original.connection.performContextMenuAction(android.R.id.autofill);
        Log.i("MenuChoice", "event=dispatched ms=" + SystemClock.uptimeMillis()
            + " gen=" + original.generation + " submitted=" + submitted);
    }

    static Focus used;
    static long issuedAt;
    @Override public boolean onShowInputRequested(int flags, boolean configChange) {
        return usable(active);
    }
    @Override public boolean onEvaluateInputViewShown() { return usable(active); }
}
