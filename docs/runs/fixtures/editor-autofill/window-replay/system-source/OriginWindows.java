package dev.magina.autofillobserver;

import android.accessibilityservice.AccessibilityService;
import android.view.accessibility.AccessibilityEvent;
import android.view.accessibility.AccessibilityWindowInfo;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

/** Android 公开窗口枚举。只取应用窗号、标题、显示屏与焦点，不访问节点。 */
public final class OriginWindows extends AccessibilityService {
    private static OriginWindows connected;
    @Override protected void onServiceConnected() { connected = this; }
    @Override public void onAccessibilityEvent(AccessibilityEvent event) {}
    @Override public void onInterrupt() {}
    @Override public void onDestroy() { connected = null; super.onDestroy(); }

    static JSONArray snapshot() throws JSONException {
        if (connected == null) throw new IllegalStateException("window service absent");
        JSONArray rows = new JSONArray();
        for (AccessibilityWindowInfo window : connected.getWindows()) {
            if (window.getType() != AccessibilityWindowInfo.TYPE_APPLICATION) continue;
            rows.put(new JSONObject().put("id", window.getId()).put("title", String.valueOf(window.getTitle()))
                    .put("display", window.getDisplayId()).put("focused", window.isFocused()).put("active", window.isActive()));
        }
        return rows;
    }
}
