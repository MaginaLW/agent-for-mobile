package dev.magina.publicwindow;

import android.accessibilityservice.AccessibilityService;
import android.graphics.Rect;
import android.os.Bundle;
import android.util.Size;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityWindowInfo;
import java.util.ArrayDeque;
import java.util.List;
import org.json.JSONArray;
import org.json.JSONObject;

/** 枚举全部可见的靶应用窗口。每个窗口只记录节点几何，不读取文本。 */
public final class WindowProbe extends AccessibilityService {
    private static WindowProbe active;
    static volatile String lastReason = "uninitialized";
    @Override protected void onServiceConnected() { active = this; lastReason = "connected"; }
    @Override public void onAccessibilityEvent(AccessibilityEvent e) {}
    @Override public void onInterrupt() {}
    @Override public void onDestroy() { active = null; lastReason = "destroyed"; super.onDestroy(); }

    private static JSONArray rect(Rect r) throws Exception {
        return new JSONArray(new int[]{r.left, r.top, r.right, r.bottom});
    }

    private static boolean isTargetPackage(CharSequence pkg) {
        return pkg != null && ImeProbe.TARGET.contentEquals(pkg);
    }

    static JSONArray read() throws Exception {
        WindowProbe service = active;
        if (service == null) { lastReason = "service_null"; return null; }
        if (!service.clearCache()) { lastReason = "clear_cache_false"; return null; }
        JSONArray result = new JSONArray();
        boolean sawTarget = false;
        for (AccessibilityWindowInfo window : service.getWindows()) {
            if (window.getType() != AccessibilityWindowInfo.TYPE_APPLICATION) continue;
            AccessibilityNodeInfo root = window.getRoot(0);
            if (root == null || root.getPackageName() == null || root.getPackageName().length() == 0) {
                result.put(new JSONObject().put("scope","unknown").put("window",window.getId()));
                continue;
            }
            if (!isTargetPackage(root.getPackageName())) {
                result.put(new JSONObject().put("scope","other").put("window",window.getId()));
                continue;
            }
            sawTarget = true;
            Rect frame = new Rect();
            window.getBoundsInScreen(frame);
            JSONArray editors = new JSONArray();
            int hiddenEditors = 0;
            ArrayDeque<AccessibilityNodeInfo> queue = new ArrayDeque<>();
            queue.add(root);
            int visited = 0;
            while (!queue.isEmpty()) {
                if (++visited > 128) { lastReason = "visited_limit"; return null; }
                AccessibilityNodeInfo node = queue.remove();
                if (node.getWindowId() != window.getId() || !isTargetPackage(node.getPackageName())) {
                    lastReason = "node_window_or_pkg_mismatch";
                    return null;
                }
                if (node.isEditable()) {
                    if (node.isAccessibilityDataSensitive() || node.isPassword()) {
                        lastReason = "sensitive_or_password";
                        return null;
                    }
                    if (!node.isVisibleToUser()) {
                        hiddenEditors++;
                    } else {
                        Size size = null;
                        boolean visibleAfterRefresh = true;
                        List<String> extra = node.getAvailableExtraData();
                        if (extra != null && extra.contains(AccessibilityNodeInfo.EXTRA_DATA_RENDERING_INFO_KEY)
                                && node.refreshWithExtraData(AccessibilityNodeInfo.EXTRA_DATA_RENDERING_INFO_KEY, new Bundle())) {
                            if (node.getWindowId() != window.getId() || !isTargetPackage(node.getPackageName())
                                    || node.isAccessibilityDataSensitive() || node.isPassword()) {
                                lastReason = "refreshed_node_mismatch";
                                return null;
                            }
                            if (!node.isEditable()) {
                                lastReason = "refreshed_not_editable";
                                return null;
                            }
                            if (!node.isVisibleToUser()) {
                                hiddenEditors++;
                                visibleAfterRefresh = false;
                            } else {
                                AccessibilityNodeInfo.ExtraRenderingInfo info = node.getExtraRenderingInfo();
                                if (info != null) size = info.getLayoutSize();
                            }
                        }
                        if (visibleAfterRefresh) {
                            Rect local = new Rect(), screen = new Rect();
                            node.getBoundsInWindow(local);
                            node.getBoundsInScreen(screen);
                            editors.put(new JSONObject().put("window_rect", rect(local)).put("screen_rect", rect(screen))
                                    .put("focused", node.isFocused()).put("named", node.getViewIdResourceName() != null)
                                    .put("layout_size", size == null ? JSONObject.NULL
                                            : new JSONArray(new int[]{size.getWidth(),size.getHeight()})));
                        }
                    }
                }
                for (int i=0; i<node.getChildCount(); i++) {
                    AccessibilityNodeInfo child = node.getChild(i);
                    if (child == null) { lastReason = "child_null"; return null; }
                    queue.add(child);
                }
            }
            result.put(new JSONObject().put("scope","target").put("window",window.getId()).put("display",window.getDisplayId())
                    .put("active",window.isActive()).put("focused",window.isFocused())
                    .put("frame",rect(frame)).put("hidden_editors",hiddenEditors).put("editors",editors));
        }
        if (!sawTarget) { lastReason = "no_target_window"; return null; }
        lastReason = "ok";
        return result;
    }
}
