package dev.magina.autofillobserver;

import android.content.pm.PackageManager;
import android.graphics.RectF;
import android.inputmethodservice.InputMethodService;
import android.os.SystemClock;
import android.view.autofill.AutofillId;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputBinding;
import android.view.inputmethod.InputConnection;

/** Both services share one main looper. Even a restart creates a new generation. */
public final class ProbeIme extends InputMethodService {
    static final String TARGET = "dev.magina.autofilltarget";
    static Focus active;

    static final class Focus {
        final ProbeIme owner;
        final InputConnection connection;
        final AutofillId id;
        final String error;
        final long started = SystemClock.uptimeMillis();

        Focus(ProbeIme owner, InputConnection connection, AutofillId id, String error) {
            this.owner = owner;
            this.connection = connection;
            this.id = id;
            this.error = error;
        }

        boolean current() {
            EditorInfo editor = owner.getCurrentInputEditorInfo();
            return active == this && owner.getCurrentInputConnection() == connection
                && editor != null && TARGET.equals(editor.packageName);
        }
    }

    @Override public void onStartInput(EditorInfo editor, boolean restarting) {
        super.onStartInput(editor, restarting);
        active = null;
        if (editor == null || !TARGET.equals(editor.packageName)) return;
        InputBinding binding = getCurrentInputBinding();
        try {
            if (binding == null || binding.getUid() != getPackageManager().getApplicationInfo(TARGET, 0).uid) return;
        } catch (PackageManager.NameNotFoundException unavailable) {
            return;
        }
        InputConnection connection = getCurrentInputConnection();
        if (connection == null) return;
        try {
            // Public since API 36. Reflection allows this fixture to compile with the local API 35 SDK.
            AutofillId id = (AutofillId) EditorInfo.class.getMethod("getAutofillId").invoke(editor);
            active = new Focus(this, connection, id, id == null ? "MISSING_IME_ID" : null);
        } catch (ReflectiveOperationException | SecurityException unavailable) {
            active = new Focus(this, connection, null, "PUBLIC_API_UNAVAILABLE");
        }
        try {
            // Independent delivery witness recorded only by the target. No text or callback data is read.
            connection.requestTextBoundsInfo(new RectF(-3f, -3f, -3f, -3f), getMainExecutor(), ignored -> {});
        } catch (RuntimeException unavailable) {
            active = new Focus(this, connection, null, "CONNECTION_PROBE_FAILED");
            android.util.Log.w("AutofillObserver", "CONNECTION_PROBE_FAILED");
        }
    }

    @Override public void onFinishInput() {
        active = null;
        super.onFinishInput();
    }

    @Override public void onUnbindInput() {
        active = null;
        super.onUnbindInput();
    }

    @Override public void onDestroy() {
        if (active != null && active.owner == this) active = null;
        super.onDestroy();
    }

    @Override public boolean onEvaluateFullscreenMode() { return false; }
    @Override public boolean onShowInputRequested(int flags, boolean configChange) { return false; }
}
