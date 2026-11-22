package dev.magina.autofillobserver;

import android.app.assist.AssistStructure;
import android.os.SystemClock;
import android.service.autofill.AutofillService;
import android.service.autofill.FillContext;
import android.service.autofill.FillRequest;
import android.view.autofill.AutofillId;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import org.json.JSONObject;

/** 仅合成实验使用，字段来自已交付的 FillRequest 与本进程 IME。 */
final class OriginEvidence {
    static void record(AutofillService service, FillRequest request, FillContext context, ProbeIme.Focus sample,
                       AutofillId matchedNode) {
        try {
            AssistStructure structure = context.getStructure();
            AutofillId trigger = context.getFocusedId();
            JSONObject row = new JSONObject().put("request", request.getId()).put("context", context.getRequestId())
                .put("session", AutofillId.class.getMethod("getSessionId").invoke(matchedNode))
                .put("trigger_session", AutofillId.class.getMethod("getSessionId").invoke(trigger))
                .put("trigger_view", AutofillId.class.getMethod("getViewId").invoke(trigger))
                .put("ime_view", AutofillId.class.getMethod("getViewId").invoke(sample.id))
                .put("ime_session", AutofillId.class.getMethod("getSessionId").invoke(sample.id))
                .put("generation", sample.generation).put("started", sample.started)
                .put("acquired", structure.getAcquisitionStartTime()).put("completed", structure.getAcquisitionEndTime())
                .put("received", SystemClock.uptimeMillis()).put("windows", structure.getWindowNodeCount());
            if (structure.getWindowNodeCount() == 1) {
                AssistStructure.WindowNode window = structure.getWindowNodeAt(0);
                row.put("display", window.getDisplayId()).put("title", String.valueOf(window.getTitle()));
            }
            row.put("accessibility", OriginWindows.snapshot());
            File tmp = new File(service.getFilesDir(), "origin.tmp");
            Files.write(tmp.toPath(), row.toString().getBytes(StandardCharsets.UTF_8));
            if (!tmp.renameTo(new File(service.getFilesDir(), "origin.json"))) throw new IllegalStateException("rename");
        } catch (Exception error) {
            throw new IllegalStateException("synthetic source receipt", error);
        }
    }
}
