package dev.magina.autofillobserver;

import android.app.assist.AssistStructure;
import android.content.ComponentName;
import android.content.Context;
import android.graphics.Bitmap;
import android.graphics.Matrix;
import android.graphics.Rect;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.os.SystemClock;
import android.service.voice.VoiceInteractionSession;
import android.util.Log;
import android.view.View;
import android.view.autofill.AutofillId;
import android.view.inputmethod.EditorInfo;
import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

final class GeometrySession extends VoiceInteractionSession {
    private final ProbeIme.Focus anchor = AssistService.anchor;
    private final String stage = AssistService.stage;
    private final long requested = AssistService.requested;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final JSONArray editors = new JSONArray();
    private final Context context;
    private final JSONObject row = new JSONObject();
    private boolean shown, matchedArgs, geometryValid = true, currentOnReceive;
    private int callbacks, trees, visits, focused, identityMatches;
    private int showFlags = -1, showId = -1;
    private long acquired = -1, completed = -1, received = -1;
    private String rejected;

    GeometrySession(Context context) { super(context); this.context = context; setUiEnabled(false); }
    @Override public void onPrepareShow(Bundle args, int flags) {
        setUiEnabled(false);
        matchedArgs = args != null && stage != null && stage.equals(args.getString("stage"))
                && requested == args.getLong("requested", -1);
        showId = args == null ? -1 : args.getInt(KEY_SHOW_SESSION_ID, -1);
        super.onPrepareShow(args, flags);
    }
    @Override public void onShow(Bundle args, int flags) {
        super.onShow(args, flags);
        shown = true;
        showFlags = flags;
        handler.postDelayed(this::closeStage, 3500);
    }
    @Override public View onCreateContentView() {
        Log.e(AssistService.TAG, "unexpected_ui"); return null;
    }
    @Override public void onHandleScreenshot(Bitmap ignored) {
        if (ignored != null) Log.e(AssistService.TAG, "unexpected_screenshot");
    }

    @Override public void onHandleAssist(AssistState state) {
        callbacks++;
        long now = SystemClock.uptimeMillis();
        AssistStructure tree = state.getAssistStructure();
        if (tree == null) return;
        trees++;
        try {
            received = now;
            currentOnReceive = anchor != null && anchor.current();
            ComponentName target = new ComponentName(ProbeIme.TARGET, ProbeIme.TARGET + ".TargetActivity");
            if (!target.equals(tree.getActivityComponent())) { reject("component"); return; }
            if (state.getIndex() != 0 || state.getCount() != 1) { reject("activity_count"); return; }
            if (tree.getWindowNodeCount() != 1) { reject("window_count"); return; }
            acquired = tree.getAcquisitionStartTime();
            completed = tree.getAcquisitionEndTime();
            AssistStructure.WindowNode w = tree.getWindowNodeAt(0);
            row.put("display", w.getDisplayId()).put("window", new JSONArray().put(w.getLeft()).put(w.getTop())
                    .put(w.getLeft() + w.getWidth()).put(w.getTop() + w.getHeight()));
            collect(w.getRootViewNode(), w.getLeft(), w.getTop(), true, 0);
        } catch (Exception unavailable) { reject("geometry_unavailable"); }
    }

    private void reject(String reason) { geometryValid = false; rejected = reason; }

    private void collect(AssistStructure.ViewNode node, int px, int py, boolean visible, int depth)
            throws ReflectiveOperationException, JSONException {
        if (++visits > 512 || depth > 32) { geometryValid = false; return; }
        Matrix m = node.getTransformation();
        if (node.isAssistBlocked() || (m != null && !m.isIdentity())) { geometryValid = false; return; }
        int x = px + node.getLeft(), y = py + node.getTop();
        visible &= node.getVisibility() == View.VISIBLE;
        String type = node.getClassName();
        if ("android.widget.EditText".equals(type) || (ProbeIme.TARGET + ".TargetActivity$Editor").equals(type)) {
            Rect bounds = new Rect(x, y, x + node.getWidth(), y + node.getHeight());
            if (!visible || bounds.isEmpty()) geometryValid = false;
            AutofillId id = node.getAutofillId();
            boolean same = id != null && anchor != null && anchor.id != null && viewId(id) == viewId(anchor.id);
            EditorInfo info = currentOnReceive ? anchor.owner.getCurrentInputEditorInfo() : null;
            boolean hasResource = node.getId() > 0;
            if (same) identityMatches++;
            if (node.isFocused()) focused++;
            editors.put(new JSONObject().put("focused", node.isFocused()).put("has_id", id != null)
                    .put("id_matches_ime", same).put("has_resource_id", hasResource)
                    .put("resource_matches_ime", hasResource && info != null && info.fieldId == node.getId())
                    .put("bounds", new JSONArray()
                    .put(bounds.left).put(bounds.top).put(bounds.right).put(bounds.bottom)));
        }
        for (int i = 0; i < node.getChildCount(); i++)
            collect(node.getChildAt(i), x - node.getScrollX(), y - node.getScrollY(), visible, depth + 1);
    }

    private int viewId(AutofillId id) throws ReflectiveOperationException {
        if ((boolean) AutofillId.class.getMethod("isVirtual").invoke(id)) throw new IllegalStateException();
        return (int) AutofillId.class.getMethod("getViewId").invoke(id);
    }
    private static Object tick(long value) { return value < 0 ? JSONObject.NULL : value; }

    private void closeStage() {
        if (stage == null) { finish(); return; }
        try {
            boolean current = anchor != null && anchor.current();
            EditorInfo info = current ? anchor.owner.getCurrentInputEditorInfo() : null;
            row.put("stage", stage).put("generation", anchor == null ? JSONObject.NULL : anchor.generation)
                .put("ime_start", anchor == null ? JSONObject.NULL : anchor.started)
                .put("request", requested).put("sample_close", SystemClock.uptimeMillis())
                .put("shown", shown).put("args_match", matchedArgs).put("show_flags", showFlags).put("show_id", showId)
                .put("assist_callbacks", callbacks).put("target_trees_examined", trees)
                .put("acquired", tick(acquired)).put("completed", tick(completed)).put("received", tick(received))
                .put("current_on_receive", currentOnReceive).put("current_at_close", current)
                .put("ime_has_native_id", anchor != null && anchor.id != null)
                .put("ime_has_resource_id", info != null && info.fieldId > 0)
                .put("rejected", rejected == null ? JSONObject.NULL : rejected)
                .put("geometry_valid", geometryValid).put("editors", editors).put("focus_count", focused)
                .put("native_id_matches", identityMatches);
            AssistService.postProbe(anchor);
            File tmp = new File(context.getFilesDir(), "assist-" + stage + ".tmp");
            Files.write(tmp.toPath(), row.toString().getBytes(StandardCharsets.UTF_8));
            if (!tmp.renameTo(new File(context.getFilesDir(), "assist-" + stage + ".json")))
                throw new IllegalStateException();
        } catch (Exception failure) { Log.e(AssistService.TAG, "receipt_failed " + stage); }
        finish();
    }
    @Override public void onDestroy() {
        handler.removeCallbacksAndMessages(null);
        if (stage != null && stage.equals(AssistService.stage)) {
            AssistService.stage = null;
            AssistService.anchor = null;
        }
        Log.i(AssistService.TAG, "session_destroyed " + stage + " tick=" + SystemClock.uptimeMillis());
        super.onDestroy();
    }
}
