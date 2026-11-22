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
import java.util.ArrayList;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

final class GeometrySession extends VoiceInteractionSession {
    private static final ComponentName TARGET_MAIN =
            new ComponentName(ProbeIme.TARGET, ProbeIme.TARGET + ".TargetActivity");
    private final ProbeIme.Focus anchor = AssistService.anchor;
    private final String stage = AssistService.stage;
    private final long requested = AssistService.requested;
    private final Handler handler = new Handler(Looper.getMainLooper());
    private final JSONArray editors = new JSONArray();
    private final JSONArray activities = new JSONArray();
    private final JSONArray focusedWindows = new JSONArray();
    private final List<ActivityId> seenActivityIds = new ArrayList<>();
    private final Context context;
    private final JSONObject row = new JSONObject();
    private boolean shown, matchedArgs, geometryValid = true, currentOnReceive, assistBlocked;
    private Boolean primaryStateFocused;
    private int callbacks, trees, focused, identityMatches, focusedActivityCount;
    private int showFlags = -1, showId = -1, primaryIndex = -1, primaryCount = -1, primaryWindowCount = -1;
    private Object primaryActivityIdHash = JSONObject.NULL;
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

    private boolean isMultiWindowStage() {
        return "multiwin".equals(stage) || "multiwin2".equals(stage);
    }

    private int activityIdSlot(ActivityId id) {
        if (id == null) return -1;
        for (int i = 0; i < seenActivityIds.size(); i++) {
            if (seenActivityIds.get(i).equals(id)) return i;
        }
        seenActivityIds.add(id);
        return seenActivityIds.size() - 1;
    }

    @Override public void onHandleAssist(AssistState state) {
        callbacks++;
        long now = SystemClock.uptimeMillis();
        ActivityId actId = state.getActivityId();
        int actSlot = activityIdSlot(actId);
        Object actHash = actId == null ? JSONObject.NULL : actId.hashCode();
        AssistStructure tree = state.getAssistStructure();
        if (tree == null) {
            try {
                activities.put(new JSONObject().put("index", state.getIndex()).put("count", state.getCount())
                        .put("state_focused", state.isFocused()).put("activity_id_slot", actSlot)
                        .put("activity_id_hash", actHash).put("structure_null", true));
            } catch (JSONException ignored) {}
            return;
        }
        ComponentName comp = tree.getActivityComponent();
        boolean targetPkg = comp != null && ProbeIme.TARGET.equals(comp.getPackageName());
        if (!targetPkg) {
            try {
                activities.put(new JSONObject().put("index", state.getIndex()).put("count", state.getCount())
                        .put("state_focused", state.isFocused()).put("activity_id_slot", actSlot)
                        .put("activity_id_hash", actHash)
                        .put("component", comp == null ? JSONObject.NULL : comp.flattenToShortString())
                        .put("target_package", false));
            } catch (JSONException ignored) {}
            if (!isMultiWindowStage()) {
                trees++;
                received = now;
                currentOnReceive = anchor != null && anchor.current();
                reject("component");
            }
            return;
        }
        trees++;
        try {
            boolean cur = anchor != null && anchor.current();
            currentOnReceive = trees == 1 ? cur : (currentOnReceive && cur);
            received = now;
            long acq = tree.getAcquisitionStartTime();
            long cmp = tree.getAcquisitionEndTime();
            acquired = acquired < 0 ? acq : Math.min(acquired, acq);
            completed = completed < 0 ? cmp : Math.max(completed, cmp);
            if (state.isFocused()) focusedActivityCount++;
            if (!isMultiWindowStage()) {
                primaryStateFocused = state.isFocused();
                primaryIndex = state.getIndex();
                primaryCount = state.getCount();
                primaryActivityIdHash = actHash;
                primaryWindowCount = tree.getWindowNodeCount();
            }
            JSONArray windowsJson = new JSONArray();
            int winCount = tree.getWindowNodeCount();
            boolean multi = isMultiWindowStage();
            if (!multi && !TARGET_MAIN.equals(comp)) reject("component");
            if (!multi && (state.getIndex() != 0 || state.getCount() != 1)) reject("activity_count");
            if (!multi && winCount != 1) reject("window_count");

            EditorInfo info = cur ? anchor.owner.getCurrentInputEditorInfo() : null;
            for (int wIdx = 0; wIdx < winCount; wIdx++) {
                AssistStructure.WindowNode w = tree.getWindowNodeAt(wIdx);
                JSONArray wRect = new JSONArray().put(w.getLeft()).put(w.getTop())
                        .put(w.getLeft() + w.getWidth()).put(w.getTop() + w.getHeight());
                if (!multi && wIdx == 0) {
                    row.put("display", w.getDisplayId()).put("window", wRect);
                }
                AssistStructure.ViewNode root = w.getRootViewNode();
                WindowWalk walk = new WindowWalk(info);
                if (root != null) {
                    walk.collect(root, w.getLeft(), w.getTop(), true, 0);
                } else {
                    walk.valid = false;
                }
                if (walk.blocked) {
                    assistBlocked = true;
                    if (!multi) reject("assist_blocked");
                }
                if (!walk.valid) geometryValid = false;
                focused += walk.focusedCount;
                identityMatches += walk.idMatches;
                for (int i = 0; i < walk.editors.length(); i++) {
                    JSONObject ed = walk.editors.getJSONObject(i);
                    editors.put(ed);
                    if (ed.optBoolean("focused", false)) {
                        focusedWindows.put(new JSONObject()
                                .put("activity_index", state.getIndex())
                                .put("activity_component", comp.flattenToShortString())
                                .put("state_focused", state.isFocused())
                                .put("activity_id_slot", actSlot)
                                .put("activity_id_hash", actHash)
                                .put("window_index", wIdx)
                                .put("display", w.getDisplayId())
                                .put("window", wRect)
                                .put("editor_bounds", ed.getJSONArray("bounds"))
                                .put("has_id", ed.getBoolean("has_id"))
                                .put("id_matches_ime", ed.getBoolean("id_matches_ime"))
                                .put("has_resource_id", ed.getBoolean("has_resource_id"))
                                .put("resource_matches_ime", ed.getBoolean("resource_matches_ime")));
                    }
                }
                windowsJson.put(new JSONObject()
                        .put("window_index", wIdx)
                        .put("display", w.getDisplayId())
                        .put("window", wRect)
                        .put("root_assist_blocked", root != null && root.isAssistBlocked())
                        .put("assist_blocked", walk.blocked)
                        .put("geometry_valid", walk.valid)
                        .put("focus_count", walk.focusedCount)
                        .put("editors", walk.editors));
            }
            activities.put(new JSONObject()
                    .put("index", state.getIndex())
                    .put("count", state.getCount())
                    .put("state_focused", state.isFocused())
                    .put("activity_id_slot", actSlot)
                    .put("activity_id_hash", actHash)
                    .put("component", comp.flattenToShortString())
                    .put("target_package", true)
                    .put("acquired", acq)
                    .put("completed", cmp)
                    .put("received", now)
                    .put("window_count", winCount)
                    .put("windows", windowsJson));
        } catch (Exception unavailable) {
            reject("geometry_unavailable");
        }
    }

    private void reject(String reason) {
        geometryValid = false;
        if (rejected == null) rejected = reason;
    }

    private final class WindowWalk {
        final EditorInfo info;
        final JSONArray editors = new JSONArray();
        boolean valid = true, blocked = false;
        int visits = 0, focusedCount = 0, idMatches = 0;

        WindowWalk(EditorInfo info) { this.info = info; }

        void collect(AssistStructure.ViewNode node, int px, int py, boolean visible, int depth)
                throws ReflectiveOperationException, JSONException {
            if (++visits > 512 || depth > 32) { valid = false; return; }
            if (node.isAssistBlocked()) { blocked = true; valid = false; return; }
            Matrix m = node.getTransformation();
            if (m != null && !m.isIdentity()) { valid = false; return; }
            int x = px + node.getLeft(), y = py + node.getTop();
            visible &= node.getVisibility() == View.VISIBLE;
            String type = node.getClassName();
            if ("android.widget.EditText".equals(type)
                    || (type != null && type.startsWith(ProbeIme.TARGET + ".") && type.endsWith("$Editor"))) {
                Rect bounds = new Rect(x, y, x + node.getWidth(), y + node.getHeight());
                if (!visible || bounds.isEmpty()) valid = false;
                AutofillId id = node.getAutofillId();
                boolean same = id != null && anchor != null && anchor.id != null && viewId(id) == viewId(anchor.id);
                boolean hasResource = node.getId() > 0;
                if (same) idMatches++;
                if (node.isFocused()) focusedCount++;
                editors.put(new JSONObject()
                        .put("focused", node.isFocused())
                        .put("has_id", id != null)
                        .put("id_matches_ime", same)
                        .put("has_resource_id", hasResource)
                        .put("resource_matches_ime", hasResource && info != null && info.fieldId == node.getId())
                        .put("input_type", node.getInputType())
                        .put("ime_input_type_matches", info != null && info.inputType == node.getInputType())
                        .put("important_for_autofill", node.getImportantForAutofill())
                        .put("autofill_type", node.getAutofillType())
                        .put("assist_blocked", node.isAssistBlocked())
                        .put("bounds", new JSONArray()
                                .put(bounds.left).put(bounds.top).put(bounds.right).put(bounds.bottom)));
            }
            for (int i = 0; i < node.getChildCount(); i++) {
                collect(node.getChildAt(i), x - node.getScrollX(), y - node.getScrollY(), visible, depth + 1);
            }
        }
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
                .put("ime_input_type", info == null ? JSONObject.NULL : info.inputType)
                .put("rejected", rejected == null ? JSONObject.NULL : rejected)
                .put("assist_blocked", assistBlocked)
                .put("geometry_valid", geometryValid).put("editors", editors).put("focus_count", focused)
                .put("native_id_matches", identityMatches)
                .put("state_focused", primaryStateFocused == null ? JSONObject.NULL : primaryStateFocused)
                .put("activity_index", primaryIndex < 0 ? JSONObject.NULL : primaryIndex)
                .put("activity_count", primaryCount < 0 ? JSONObject.NULL : primaryCount)
                .put("activity_id_hash", primaryActivityIdHash)
                .put("window_count", primaryWindowCount < 0 ? JSONObject.NULL : primaryWindowCount)
                .put("focused_activity_count", focusedActivityCount)
                .put("focused_windows", focusedWindows)
                .put("activities", activities);
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
