package dev.magina.publicwindow;

import android.inputmethodservice.InputMethodService;
import android.os.Handler;
import android.os.IBinder;
import android.os.Looper;
import android.os.SystemClock;
import android.util.AtomicFile;
import android.view.autofill.AutofillId;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputBinding;
import android.view.inputmethod.InputConnection;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import org.json.JSONObject;

/** 普通 IME 与无障碍同进程，无自动填充服务。只观察元数据，不索取输入文本。 */
public final class ImeProbe extends InputMethodService {
    static final String TARGET = "dev.magina.crossappfixture";
    private final Handler main = new Handler(Looper.getMainLooper());
    private final HashMap<IBinder,Integer> bindings = new HashMap<>();
    private long generation;

    @Override public void onStartInput(EditorInfo info, boolean restart) {
        super.onStartInput(info, restart);
        final long gen = ++generation;
        if (info == null || !TARGET.equals(info.packageName)) return;
        final long start = SystemClock.uptimeMillis();
        InputBinding binding = getCurrentInputBinding();
        InputConnection ic = getCurrentInputConnection();
        if (ic == null || binding == null || binding.getConnectionToken() == null) return;
        IBinder token = binding.getConnectionToken();
        int tokenIndex = bindings.computeIfAbsent(token, k -> bindings.size() + 1);
        main.postDelayed(() -> {
            try {
                if (gen != generation || ic != getCurrentInputConnection()) return;
                JSONObject a = WindowProbe.read();
                if (a == null) return;
                AutofillId id = (AutofillId) EditorInfo.class.getMethod("getAutofillId").invoke(info);
                JSONObject sample = new JSONObject().put("generation", gen).put("started", start)
                    .put("uid", binding.getUid()).put("pid", binding.getPid()).put("binding_label", tokenIndex)
                    .put("field", info.fieldId).put("native_id", id == null ? JSONObject.NULL
                            : AutofillId.class.getMethod("getViewId").invoke(id))
                    .put("fill_session", id == null ? JSONObject.NULL : AutofillId.class.getMethod("getSessionId").invoke(id))
                    .put("a11y", a).put("sampled", SystemClock.uptimeMillis());
                main.postDelayed(() -> {
                    try {
                        JSONObject b = WindowProbe.read();
                        if (gen != generation || ic != getCurrentInputConnection() || b == null
                                || !a.toString().equals(b.toString())) return;
                        sample.put("after", SystemClock.uptimeMillis());
                        AtomicFile journal = new AtomicFile(new File(getFilesDir(), "public.json"));
                        FileOutputStream stream = journal.startWrite();
                        try {
                            stream.write(sample.toString().getBytes(StandardCharsets.UTF_8));
                            journal.finishWrite(stream);
                        } catch (Exception failure) { journal.failWrite(stream); throw failure; }
                    } catch (Exception e) { throw new IllegalStateException("synthetic recheck", e); }
                }, 200);
            } catch (Exception e) { throw new IllegalStateException("synthetic sample", e); }
        }, 900);
    }
    @Override public void onFinishInput() { generation++; super.onFinishInput(); }
    @Override public void onUnbindInput() { generation++; super.onUnbindInput(); }
    @Override public boolean onEvaluateInputViewShown() { super.onEvaluateInputViewShown(); return false; }
}
