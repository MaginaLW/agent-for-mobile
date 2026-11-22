package dev.magina.publicwindow;

import android.accessibilityservice.AccessibilityService;
import android.graphics.Rect;
import android.os.Bundle;
import android.util.Size;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.accessibility.AccessibilityWindowInfo;
import java.util.ArrayDeque;
import org.json.JSONArray;
import org.json.JSONObject;

/** 枚举全部可见的靶应用窗口。每个窗口只记录节点几何，不读取文本。 */
public final class WindowProbe extends AccessibilityService {
    private static WindowProbe active;
    @Override protected void onServiceConnected() { active = this; }
    @Override public void onAccessibilityEvent(AccessibilityEvent e) {}
    @Override public void onInterrupt() {}
    @Override public void onDestroy() { active = null; super.onDestroy(); }

    private static JSONArray rect(Rect r) throws Exception {
        return new JSONArray(new int[]{r.left, r.top, r.right, r.bottom});
    }

    static JSONArray read() throws Exception {
        WindowProbe service = active;
        if (service == null || !service.clearCache()) return null;
        JSONArray result = new JSONArray();
        boolean sawTarget = false;
        for (AccessibilityWindowInfo window : service.getWindows()) {
            if (window.getType() != AccessibilityWindowInfo.TYPE_APPLICATION) continue;
            AccessibilityNodeInfo root = window.getRoot(0);
            if (root == null || root.getPackageName() == null || root.getPackageName().length() == 0) {
                result.put(new JSONObject().put("scope","unknown").put("window",window.getId()));
                continue;
            }
            if (!ImeProbe.TARGET.equals(root.getPackageName())) {
                result.put(new JSONObject().put("scope","other").put("window",window.getId()));
                continue;
            }
            sawTarget = true;
            Rect frame = new Rect();
            window.getBoundsInScreen(frame);
            JSONArray editors = new JSONArray();
            ArrayDeque<AccessibilityNodeInfo> queue = new ArrayDeque<>();
            queue.add(root);
            int visited = 0;
            while (!queue.isEmpty()) {
                if (++visited > 64) return null;
                AccessibilityNodeInfo node = queue.remove();
                if (node.getWindowId() != window.getId() || !ImeProbe.TARGET.equals(node.getPackageName())) return null;
                if (node.isEditable() && node.isVisibleToUser()) {
                    if (node.isAccessibilityDataSensitive() || node.isPassword()) return null;
                    Rect local = new Rect(), screen = new Rect();
                    node.getBoundsInWindow(local);
                    node.getBoundsInScreen(screen);
                    Size size = null;
                    if (node.getAvailableExtraData().contains(AccessibilityNodeInfo.EXTRA_DATA_RENDERING_INFO_KEY)
                            && node.refreshWithExtraData(AccessibilityNodeInfo.EXTRA_DATA_RENDERING_INFO_KEY, new Bundle())) {
                        AccessibilityNodeInfo.ExtraRenderingInfo info = node.getExtraRenderingInfo();
                        if (info != null) size = info.getLayoutSize();
                    }
                    editors.put(new JSONObject().put("window_rect", rect(local)).put("screen_rect", rect(screen))
                            .put("focused", node.isFocused()).put("named", node.getViewIdResourceName() != null)
                            .put("layout_size", size == null ? JSONObject.NULL
                                    : new JSONArray(new int[]{size.getWidth(),size.getHeight()})));
                }
                for (int i=0; i<node.getChildCount(); i++) {
                    AccessibilityNodeInfo child = node.getChild(i);
                    if (child == null) return null;
                    queue.add(child);
                }
            }
            result.put(new JSONObject().put("scope","target").put("window",window.getId()).put("display",window.getDisplayId())
                    .put("active",window.isActive()).put("focused",window.isFocused())
                    .put("frame",rect(frame)).put("editors",editors));
        }
        return sawTarget ? result : null;
    }
}
