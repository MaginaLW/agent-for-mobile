package dev.magina.publicwindow;

import android.accessibilityservice.AccessibilityService;
import android.graphics.Rect;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityWindowInfo;
import org.json.JSONArray;
import org.json.JSONObject;

public final class WindowProbe extends AccessibilityService {
    static WindowProbe active;
    @Override protected void onServiceConnected() { active = this; }
    @Override public void onAccessibilityEvent(AccessibilityEvent event) {}
    @Override public void onInterrupt() {}
    @Override public void onDestroy() { active = null; super.onDestroy(); }

    static JSONObject read() throws Exception {
        WindowProbe svc = active;
        if (svc == null || !svc.clearCache()) return null;
        AccessibilityNodeInfo root = svc.getRootInActiveWindow(0);
        if (root == null || !ImeProbe.TARGET.contentEquals(root.getPackageName())) return null;
        AccessibilityWindowInfo app = root.getWindow();
        AccessibilityNodeInfo node = root.findFocus(AccessibilityNodeInfo.FOCUS_INPUT);
        AccessibilityNodeInfo other = svc.findFocus(AccessibilityNodeInfo.FOCUS_INPUT);
        if (app == null || node == null || other == null || !node.equals(other)
                || !app.isActive() || !app.isFocused() || !node.isFocused()
                || !node.isEditable() || !node.isVisibleToUser() || node.isPassword() || node.isAccessibilityDataSensitive()
                || !ImeProbe.TARGET.contentEquals(node.getPackageName())) return null;
        AccessibilityWindowInfo nodeWindow = node.getWindow();
        if (nodeWindow == null || nodeWindow.getId() != app.getId() || node.getWindowId() != app.getId()) return null;
        Rect rect = new Rect();
        node.getBoundsInScreen(rect);
        return new JSONObject().put("window", app.getId()).put("display", app.getDisplayId())
                .put("root_window", root.getWindowId()).put("node_window", node.getWindowId())
                .put("unique_id_present", node.getUniqueId() != null).put("root_unique_id_present", root.getUniqueId() != null)
                .put("resource_name_present", node.getViewIdResourceName() != null)
                .put("anchor_present", app.getAnchor() != null)
                .put("bounds", new JSONArray(new int[]{rect.left, rect.top, rect.right, rect.bottom}));
    }
}
