package dev.magina.editororigin;

import android.accessibilityservice.AccessibilityServiceInfo;
import android.app.Activity;
import android.app.Instrumentation;
import android.app.UiAutomation;
import android.content.Context;
import android.content.Intent;
import android.content.res.Resources;
import android.graphics.Rect;
import android.os.Bundle;
import android.os.SystemClock;
import android.provider.Settings;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityWindowInfo;
import java.io.File;
import java.util.List;
import java.util.concurrent.TimeUnit;
import org.json.JSONArray;
import org.json.JSONObject;

/** Compare IME receipts with two independent system focus reads while the fixture holds each stage. */
public final class FocusCheckInstrumentation extends Instrumentation {
    @Override public void onCreate(Bundle args) {
        super.onCreate(args);
        start();
    }

    @Override public void onStart() {
        Bundle results = new Bundle();
        JSONArray rows = new JSONArray();
        OriginProbeActivity activity = null;
        boolean passed = false;
        try {
            Context context = getTargetContext();
            UiAutomation ui = getUiAutomation(UiAutomation.FLAG_DONT_SUPPRESS_ACCESSIBILITY_SERVICES);
            AccessibilityServiceInfo config = ui.getServiceInfo();
            config.flags |= AccessibilityServiceInfo.FLAG_REPORT_VIEW_IDS
                | AccessibilityServiceInfo.FLAG_RETRIEVE_INTERACTIVE_WINDOWS;
            ui.setServiceInfo(config);
            // Instrumentation startup may stop the target package, including its selected IME.
            // Let the emulator host select the test IME only after this process is ready.
            File ready = new File(context.getFilesDir(), "focus-ready");
            File go = new File(context.getFilesDir(), "focus-go");
            if (go.exists() || !ready.createNewFile()) throw new IllegalStateException("stale_setup");
            long deadline = SystemClock.elapsedRealtime() + 30000;
            while (!go.exists() && SystemClock.elapsedRealtime() < deadline) SystemClock.sleep(200);
            if (!go.exists()) throw new IllegalStateException("host_setup_timeout");
            String selected = Settings.Secure.getString(context.getContentResolver(), Settings.Secure.DEFAULT_INPUT_METHOD);
            if (!(context.getPackageName() + "/.BoundsProbeIme").equals(selected)) throw new IllegalStateException("selected_ime");
            Intent launch = new Intent(context, OriginProbeActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK).putExtra("focus_check", true);
            activity = (OriginProbeActivity) startActivitySync(launch);
            Intent[] previous = new Intent[4];
            for (int stage = 0; stage < previous.length; stage++) {
                Intent sample = activity.focusSamples.poll(8, TimeUnit.SECONDS);
                if (sample == null || sample.getIntExtra("stage", -1) != stage) throw new IllegalStateException("ime_sample");
                Witness first = readFocus(ui, context.getPackageName());
                Witness second = readFocus(ui, context.getPackageName());
                boolean stable = first.window == second.window && first.node.equals(second.node)
                    && java.util.Objects.equals(first.id, second.id) && first.editable == second.editable
                    && first.rect.equals(second.rect);
                String match = second.compare(sample, context.getResources());
                String prior = stage == 0 ? "none" : second.compare(previous[stage - 1], context.getResources());
                String revisit = stage == 2 ? second.compare(previous[0], context.getResources()) : "none";
                boolean rowPass = stable && (stage == 3 ? "missing_id" : "matched").equals(match)
                    && second.editable == (stage != 1)
                    && (stage == 0 || (stage == 3 ? "missing_id" : "different_id").equals(prior))
                    && (stage != 2 || "different_bounds".equals(revisit));
                rows.put(new JSONObject().put("stage", stage).put("stable", stable).put("editable", second.editable)
                    .put("current", match).put("previous", prior).put("before_resize", revisit)
                    .put("focus_bounds", new JSONArray(new int[]{second.rect.left, second.rect.top,
                        second.rect.right, second.rect.bottom})).put("pass", rowPass));
                if (!rowPass) throw new IllegalStateException("comparison");
                previous[stage] = sample;
                if (stage < previous.length - 1) {
                    final OriginProbeActivity target = activity;
                    final int observed = stage;
                    runOnMainSync(() -> target.continueFocusCheck(observed));
                }
            }
            passed = true;
        } catch (Exception e) {
            results.putString("error", e.getClass().getSimpleName() + "/" + e.getMessage());
        } finally {
            if (activity != null) runOnMainSync(activity::finish);
            results.putString("focus_rows", rows.toString());
            finish(passed ? Activity.RESULT_OK : Activity.RESULT_CANCELED, results);
        }
    }

    private static Witness readFocus(UiAutomation ui, String pkg) {
        if (!ui.clearCache()) throw new IllegalStateException("cache");
        AccessibilityNodeInfo root = ui.getRootInActiveWindow();
        AccessibilityNodeInfo node = ui.findFocus(AccessibilityNodeInfo.FOCUS_INPUT);
        if (root == null || node == null || !pkg.contentEquals(root.getPackageName())
                || !pkg.contentEquals(node.getPackageName()) || !node.refresh()) throw new IllegalStateException("focus");
        AccessibilityWindowInfo window = root.getWindow();
        if (window == null || window.getType() != AccessibilityWindowInfo.TYPE_APPLICATION
                || !window.isActive() || !window.isFocused() || window.getId() != node.getWindowId()
                || !node.equals(root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)) || !node.isFocused()
                || !node.isVisibleToUser() || node.isPassword()) throw new IllegalStateException("window_or_node");
        String id = node.getViewIdResourceName();
        if (id != null && !id.isEmpty()) {
            List<AccessibilityNodeInfo> items = root.findAccessibilityNodeInfosByViewId(id);
            if (items.size() != 1 || !items.get(0).equals(node)) throw new IllegalStateException("ambiguous_node");
        }
        return new Witness(node);
    }

    private static final class Witness {
        final AccessibilityNodeInfo node;
        final int window;
        final String id;
        final boolean editable;
        final Rect rect = new Rect();

        Witness(AccessibilityNodeInfo node) {
            this.node = node;
            window = node.getWindowId();
            id = node.getViewIdResourceName();
            editable = node.isEditable();
            node.getBoundsInScreen(rect);
            if (rect.isEmpty()) throw new IllegalStateException("empty_bounds");
        }

        String compare(Intent sample, Resources resources) {
            if (id == null || id.isEmpty()) return "missing_id";
            String imeId;
            try {
                imeId = resources.getResourceName(sample.getIntExtra("field_id", 0));
            } catch (Resources.NotFoundException missing) {
                return "missing_id";
            }
            if (!id.equals(imeId)) return "different_id";
            float[] b = sample.getFloatArrayExtra("observed_bounds");
            return b != null && b.length == 4 && b[0] == rect.left && b[1] == rect.top
                && b[2] == rect.right && b[3] == rect.bottom ? "matched" : "different_bounds";
        }
    }
}
