package dev.magina.autofillobserver;

import android.app.assist.AssistStructure;
import android.app.assist.AssistStructure.ViewNode;
import android.app.assist.AssistStructure.WindowNode;
import android.content.ComponentName;
import android.graphics.Matrix;
import android.graphics.Rect;
import android.os.CancellationSignal;
import android.os.Handler;
import android.os.Looper;
import android.os.Process;
import android.os.SystemClock;
import android.service.autofill.AutofillService;
import android.service.autofill.FillCallback;
import android.service.autofill.FillContext;
import android.service.autofill.FillRequest;
import android.service.autofill.SaveCallback;
import android.service.autofill.SaveRequest;
import android.util.AtomicFile;
import android.view.View;
import android.view.autofill.AutofillId;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.util.ArrayList;
import java.util.List;

public final class ProbeAutofillService extends AutofillService {
    private static final ComponentName TARGET = new ComponentName(ProbeIme.TARGET, ProbeIme.TARGET + ".TargetActivity");
    private final Handler main = new Handler(Looper.getMainLooper());

    private static final class Editor {
        final AutofillId id;
        final boolean focused;
        final Rect bounds;
        boolean matchesIme, matchesFill, rawEqualsIme, rawEqualsFill, inSession;

        Editor(ViewNode node, Rect bounds) {
            this.id = node.getAutofillId();
            this.focused = node.isFocused();
            this.bounds = bounds;
        }
    }

    private static final class Observation {
        final List<Editor> editors = new ArrayList<>();
        int focusCount, imeMatches, fillMatches, rawImeMatches, rawFillMatches;
        Editor imeRow, fillRow;
        boolean before, after, supportedGeometry = true;
        String reason = "INCOMPLETE";

        void collect(ViewNode node, int parentX, int parentY, boolean visible) {
            int importance = node.getImportantForAutofill();
            if (importance == View.IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS) return;
            int x = parentX + node.getLeft(), y = parentY + node.getTop();
            Matrix transform = node.getTransformation();
            if (transform != null && !transform.isIdentity()) supportedGeometry = false;
            visible = visible && node.getVisibility() == View.VISIBLE;
            if (importance != View.IMPORTANT_FOR_AUTOFILL_NO && node.getAutofillType() == View.AUTOFILL_TYPE_TEXT) {
                Rect frame = new Rect(x, y, x + node.getWidth(), y + node.getHeight());
                if (!visible || frame.isEmpty()) supportedGeometry = false;
                editors.add(new Editor(node, frame));
                if (node.isFocused()) focusCount++;
            }
            if (importance == View.IMPORTANT_FOR_AUTOFILL_YES_EXCLUDE_DESCENDANTS) return;
            for (int i = 0; i < node.getChildCount(); i++)
                collect(node.getChildAt(i), x - node.getScrollX(), y - node.getScrollY(), visible);
        }

        String side(Editor row) {
            if (row == null || editors.size() != 2 || !supportedGeometry) return null;
            Editor other = editors.get(0) == row ? editors.get(1) : editors.get(0);
            if (row.bounds.right <= other.bounds.left) return "LEFT";
            if (row.bounds.left >= other.bounds.right) return "RIGHT";
            return null;
        }

        String evaluate(FillContext context, ProbeIme.Focus sample) throws ReflectiveOperationException {
            AssistStructure tree = context.getStructure();
            if (tree.getWindowNodeCount() != 1) return "WINDOW_COUNT";
            WindowNode window = tree.getWindowNodeAt(0);
            collect(window.getRootViewNode(), window.getLeft(), window.getTop(), true);
            if (!before) return "NO_CURRENT_IME";
            if (sample.error != null) return sample.error;
            long acquired = tree.getAcquisitionStartTime(), completed = tree.getAcquisitionEndTime();
            if (acquired < sample.started || completed < acquired || completed > SystemClock.uptimeMillis())
                return "STALE_STRUCTURE";
            if (editors.size() != 2) return "EDITOR_COUNT";
            AutofillId trigger = context.getFocusedId();
            if (trigger == null) return "MISSING_FILL_ID";
            if (isVirtual(sample.id) || isVirtual(trigger)) return "VIRTUAL_ID";
            int imeViewId = viewId(sample.id), triggerViewId = viewId(trigger);
            Integer first = null;
            for (Editor row : editors) {
                if (row.id == null) return "MISSING_NODE_ID";
                if (isVirtual(row.id)) return "VIRTUAL_ID";
                int viewId = viewId(row.id);
                if (first != null && first.intValue() == viewId) return "DUPLICATE_NODE_ID";
                first = viewId;
                row.inSession = (boolean) AutofillId.class.getMethod("isInAutofillSession").invoke(row.id);
                row.rawEqualsIme = row.id.equals(sample.id);
                row.rawEqualsFill = row.id.equals(trigger);
                row.matchesIme = viewId == imeViewId;
                row.matchesFill = viewId == triggerViewId;
                if (row.rawEqualsIme) rawImeMatches++;
                if (row.rawEqualsFill) rawFillMatches++;
                if (row.matchesIme) { imeMatches++; imeRow = row; }
                if (row.matchesFill) { fillMatches++; fillRow = row; }
            }
            if (imeMatches != 1 || fillMatches != 1) return "NO_ID_MATCH";
            if (!supportedGeometry) return "UNSUPPORTED_GEOMETRY";
            if (side(imeRow) == null) return "INDISTINGUISHABLE_BOUNDS";
            if (fillRow != imeRow || focusCount != 1 || !imeRow.focused) return "FOCUS_DISAGREES";
            return "MATCH";
        }

        // All three AutofillId methods used here are public on API 36.
        private static int viewId(AutofillId id) throws ReflectiveOperationException {
            return (int) AutofillId.class.getMethod("getViewId").invoke(id);
        }
        private static boolean isVirtual(AutofillId id) throws ReflectiveOperationException {
            return (boolean) AutofillId.class.getMethod("isVirtual").invoke(id);
        }

        JSONObject receipt() throws JSONException {
            boolean matched = "MATCH".equals(reason);
            String verdict = matched ? "MATCHED" : ("FOCUS_DISAGREES".equals(reason) ? "CONFLICT" : "UNKNOWN");
            JSONArray candidates = new JSONArray();
            for (Editor row : editors) {
                candidates.put(new JSONObject().put("bounds", rect(row.bounds)).put("focused", row.focused)
                    .put("native_matches_ime", row.matchesIme).put("native_matches_fill", row.matchesFill)
                    .put("raw_equals_ime", row.rawEqualsIme).put("raw_equals_fill", row.rawEqualsFill)
                    .put("id_in_session", row.inSession));
            }
            return new JSONObject().put("schema", 1).put("uid", Process.myUid()).put("verdict", verdict)
                .put("reason", reason).put("editor_count", editors.size()).put("focus_count", focusCount)
                .put("raw_equals_count", rawImeMatches).put("raw_fill_equals_count", rawFillMatches)
                .put("match_count", imeMatches).put("view_id_match_count", imeMatches)
                .put("fill_focus_match_count", fillMatches).put("before_current", before).put("after_current", after)
                .put("chosen_is_focused", imeRow == null ? JSONObject.NULL : imeRow.focused)
                .put("ime_match_side", nullable(side(imeRow))).put("fill_focus_side", nullable(side(fillRow)))
                .put("selected_side", matched ? side(imeRow) : JSONObject.NULL)
                .put("selected_bounds", matched ? rect(imeRow.bounds) : JSONObject.NULL).put("candidates", candidates);
        }

        private static Object nullable(String value) { return value == null ? JSONObject.NULL : value; }
        private static JSONArray rect(Rect r) { return new JSONArray().put(r.left).put(r.top).put(r.right).put(r.bottom); }
    }

    // Only the host can open a natural observation window, using this package's private test directory.
    private int naturalStage() {
        File marker = new File(getFilesDir(), "natural-stage");
        if (!marker.isFile() || marker.length() > 4) return 0;
        try {
            String value = new String(Files.readAllBytes(marker.toPath()), StandardCharsets.US_ASCII).trim();
            return value.length() == 1 && value.charAt(0) >= '1' && value.charAt(0) <= '3' ? value.charAt(0) - '0' : 0;
        } catch (IOException closed) {
            return 0;
        }
    }

    private final class NaturalCall {
        final int stage;
        final long received;
        final ProbeIme.Focus original;
        final AtomicFile journal;
        long acquired = -1, completed = -1;
        String evaluation;
        int index = -1;

        NaturalCall(int stage, long received, ProbeIme.Focus original) {
            this.stage = stage;
            this.received = received;
            this.original = original;
            journal = new AtomicFile(new File(getFilesDir(), "natural-" + stage + ".json"));
        }

        // All updates run on the shared main looper. A restarted process can still preserve earlier samples.
        void record(Observation observation, boolean pending) {
            try {
                JSONObject ledger = journal.getBaseFile().isFile()
                    ? new JSONObject(new String(journal.readFully(), StandardCharsets.UTF_8))
                    : new JSONObject().put("schema", 1).put("stage", stage).put("samples", new JSONArray())
                        .put("terminal_count", 0);
                JSONArray samples = ledger.getJSONArray("samples");
                JSONObject event = observation.receipt().put("manual", false).put("observer_pid", Process.myPid())
                    .put("callback_uptime_ms", received)
                    .put("ime_generation", original == null ? JSONObject.NULL : original.generation)
                    .put("ime_started_uptime_ms", original == null ? JSONObject.NULL : original.started)
                    .put("acquisition_start_uptime_ms", acquired < 0 ? JSONObject.NULL : acquired)
                    .put("acquisition_end_uptime_ms", completed < 0 ? JSONObject.NULL : completed);
                if (pending) {
                    index = samples.length();
                    event.put("verdict", "PENDING").put("reason", "EVALUATING");
                } else {
                    if (index < 0 || index >= samples.length()) return;
                    event.put("initial_reason", evaluation)
                        .put("ime_generation_after", original == null || ProbeIme.active == null ? JSONObject.NULL : ProbeIme.active.generation);
                    ledger.put("terminal_count", ledger.getInt("terminal_count") + 1);
                }
                samples.put(index, event);
                ledger.put("callback_count", samples.length());
                writeJson(journal, ledger);
            } catch (IOException | JSONException unavailable) {
                android.util.Log.w("AutofillObserver", "NATURAL_RECEIPT_WRITE_FAILED");
            }
        }
    }

    @Override public void onFillRequest(FillRequest request, CancellationSignal cancellation, FillCallback callback) {
        long received = SystemClock.uptimeMillis();
        boolean manual = (request.getFlags() & FillRequest.FLAG_MANUAL_REQUEST) != 0;
        int stage = naturalStage();
        if (manual != (stage == 0)) { callback.onSuccess(null); return; }
        List<FillContext> contexts = request.getFillContexts();
        if (contexts.isEmpty()) { callback.onSuccess(null); return; }
        FillContext context = contexts.get(contexts.size() - 1);
        if (!TARGET.equals(context.getStructure().getActivityComponent())) { callback.onSuccess(null); return; }
        if (stage == 3) {
            Observation excluded = new Observation();
            NaturalCall trace = new NaturalCall(stage, received, null);
            excluded.reason = "TARGET_OPTED_OUT";
            trace.evaluation = excluded.reason;
            trace.record(excluded, true);
            trace.record(excluded, false);
            callback.onSuccess(null);
            return;
        }
        AtomicFile file = new AtomicFile(new File(getFilesDir(), "result.json"));
        if (manual && file.getBaseFile().exists()) { callback.onSuccess(null); return; }
        ProbeIme.Focus sample = ProbeIme.active;
        Observation o = new Observation();
        o.before = sample != null && sample.current();
        NaturalCall trace = manual ? null : new NaturalCall(stage, received, sample);
        if (trace != null) trace.record(o, true);
        try {
            if (trace != null) {
                trace.acquired = context.getStructure().getAcquisitionStartTime();
                trace.completed = context.getStructure().getAcquisitionEndTime();
            }
            o.reason = context.getRequestId() == request.getId() ? o.evaluate(context, sample) : "STALE_FILL_CONTEXT";
        } catch (ReflectiveOperationException | SecurityException unavailable) {
            o.reason = "PUBLIC_API_UNAVAILABLE";
        } catch (RuntimeException unavailable) {
            o.reason = "STRUCTURE_UNAVAILABLE";
        }
        if (trace != null) {
            // Uptime has millisecond resolution. Equality cannot establish the order of two cross-process events.
            if (sample != null && trace.acquired == sample.started) o.reason = "ACQUISITION_ORDER_UNRESOLVED";
            trace.evaluation = o.reason;
        }
        // Allow queued finish/restart/unbind callbacks to invalidate the original connection.
        main.postDelayed(() -> {
            o.after = sample != null && sample.current();
            if (cancellation.isCanceled()) o.reason = "REQUEST_CANCELLED";
            else if (o.before && !o.after) o.reason = "IME_CHANGED";
            if (trace != null) {
                if (naturalStage() != stage) o.reason = "STAGE_CLOSED";
                trace.record(o, false);
            } else if (!file.getBaseFile().exists()) {
                try {
                    writeJson(file, o.receipt());
                } catch (IOException | JSONException unavailable) {
                    android.util.Log.w("AutofillObserver", "RECEIPT_WRITE_FAILED");
                }
            }
            if (!cancellation.isCanceled()) callback.onSuccess(null);
        }, 100);
    }

    private static void writeJson(AtomicFile file, JSONObject data) throws IOException {
        FileOutputStream stream = file.startWrite();
        try {
            stream.write(data.toString().getBytes(StandardCharsets.UTF_8));
            file.finishWrite(stream);
        } catch (IOException error) {
            file.failWrite(stream);
            throw error;
        }
    }

    @Override public void onSaveRequest(SaveRequest request, SaveCallback callback) { callback.onSuccess(); }
}
