package dev.magina.wechatparity;

import android.app.Activity;
import android.graphics.Color;
import android.graphics.PixelFormat;
import android.graphics.Rect;
import android.graphics.RectF;
import android.graphics.drawable.ColorDrawable;
import android.os.Bundle;
import android.os.Process;
import android.text.InputType;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.view.Window;
import android.view.WindowManager;
import android.view.accessibility.AccessibilityNodeInfo;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.InputConnectionWrapper;
import android.view.inputmethod.InputMethodManager;
import android.view.inputmethod.TextBoundsInfoResult;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.io.File;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.Executor;
import java.util.function.Consumer;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * 微信 PA2553 横屏平行视界等效对抗靶标（纯只读诊断验证）：
 * 1) 两个同包 TYPE_APPLICATION 横屏窗口（互不重叠分栏 + 重叠负对照）；
 * 2) MATCH_PARENT EditText 叠加剥离 viewIdResourceName/focused/visible 的 AccessibilityDelegate，
 *    且同窗存在 2 个共享同一 R.id 的 View；
 * 3) 自定义 InputConnectionWrapper 在 API 34 requestTextBoundsInfo 固定返回 CODE_UNSUPPORTED，
 *    同时保留标准 requestCursorUpdates()（以及仅支持 1 参降级的变体）。
 */
public final class WeChatParityActivity extends Activity {
    private static final int PANE_GAP_PX = 16;

    private String scenario;
    private LinearLayout leftRoot;
    private LinearLayout rightRoot;
    private boolean rightWindowAdded;
    private ParityEditText targetEditor;
    private View nonEditorFocusView;
    private boolean started;
    private boolean connected;
    private int exportedFieldId;
    private int exportedInputType = InputType.TYPE_NULL;
    private int textBoundsRequests;
    private int filteredCursorRequests;
    private int legacyCursorRequests;
    private int duplicateIdCount;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        scenario = getIntent().getStringExtra("lab_case");
        if (!isKnownScenario(scenario)) {
            throw new IllegalArgumentException("unknown lab_case: " + scenario);
        }

        Rect maxBounds = getWindowManager().getMaximumWindowMetrics().getBounds();
        int screenW = maxBounds.width();
        int screenH = maxBounds.height();
        int topY = Math.min(120, Math.max(48, screenH / 10));
        int winH = Math.max(320, screenH - topY * 2);

        int leftW;
        if ("overlap_right".equals(scenario)) {
            leftW = (int) (screenW * 0.80f);
        } else {
            leftW = (int) (screenW * 0.36f);
        }

        leftRoot = buildPaneContainer("LEFT PANE (" + scenario + ")", Color.rgb(242, 245, 250));
        if ("disjoint_left_dead_end".equals(scenario)) {
            int sharedId = resourceId("wechat_left_input");
            targetEditor = populateWeChatEditorPane(leftRoot, sharedId, true, false);
        } else if ("type_null_decor".equals(scenario)) {
            nonEditorFocusView = new View(this);
            nonEditorFocusView.setFocusable(true);
            nonEditorFocusView.setFocusableInTouchMode(true);
            leftRoot.addView(nonEditorFocusView, new LinearLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT, 120));
        }
        setContentView(leftRoot);

        // 必须在 setContentView() 之后再设置浮动窗尺寸与位置，避免 PhoneWindow.generateLayout() 重置为 WRAP_CONTENT。
        Window win = getWindow();
        win.setBackgroundDrawable(new ColorDrawable(Color.WHITE));
        win.setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING);
        win.getDecorView().setPadding(0, 0, 0, 0);
        WindowManager.LayoutParams leftLp = win.getAttributes();
        leftLp.gravity = Gravity.TOP | Gravity.START;
        leftLp.x = 0;
        leftLp.y = topY;
        leftLp.width = leftW;
        leftLp.height = winH;
        leftLp.flags = (leftLp.flags & ~WindowManager.LayoutParams.FLAG_DIM_BEHIND)
                | WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL;
        win.setAttributes(leftLp);
        win.setLayout(leftW, winH);
    }

    @Override
    public void onAttachedToWindow() {
        super.onAttachedToWindow();
        if (rightWindowAdded) return;
        attachRightWindow();
    }

    private void attachRightWindow() {
        Rect maxBounds = getWindowManager().getMaximumWindowMetrics().getBounds();
        int screenW = maxBounds.width();
        int screenH = maxBounds.height();
        int topY = Math.min(120, Math.max(48, screenH / 10));
        int winH = Math.max(320, screenH - topY * 2);

        int rightX;
        int rightW;
        if ("overlap_right".equals(scenario)) {
            rightX = (int) (screenW * 0.25f);
            rightW = screenW - rightX;
        } else {
            int leftW = (int) (screenW * 0.36f);
            rightX = leftW + PANE_GAP_PX;
            rightW = Math.max(300, screenW - rightX);
        }

        rightRoot = buildPaneContainer("RIGHT PANE (" + scenario + ")", Color.rgb(250, 248, 242));
        boolean focusRight = isRightTargetScenario(scenario);
        if (focusRight) {
            int sharedId = resourceId("wechat_chat_input");
            boolean deadEndA11y = !"disjoint_right_valid_node".equals(scenario);
            boolean declineFiltered = "disjoint_right_legacy_1arg".equals(scenario);
            targetEditor = populateWeChatEditorPane(rightRoot, sharedId, deadEndA11y, declineFiltered);
        }

        WindowManager.LayoutParams rightLp = new WindowManager.LayoutParams(
                rightW,
                winH,
                rightX,
                topY,
                WindowManager.LayoutParams.TYPE_APPLICATION_ATTACHED_DIALOG,
                WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL
                        | (focusRight ? 0 : WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE),
                PixelFormat.OPAQUE
        );
        rightLp.gravity = Gravity.TOP | Gravity.START;
        rightLp.token = getWindow().getDecorView().getWindowToken();
        rightLp.softInputMode = WindowManager.LayoutParams.SOFT_INPUT_ADJUST_NOTHING;
        getWindowManager().addView(rightRoot, rightLp);
        rightWindowAdded = true;

        if (focusRight && targetEditor != null) {
            rightRoot.getViewTreeObserver().addOnWindowFocusChangeListener(hasFocus -> {
                if (hasFocus) {
                    startFocusAndPublish();
                }
            });
            rightRoot.post(this::startFocusAndPublish);
        } else {
            leftRoot.postDelayed(this::startFocusAndPublish, 150);
        }
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        if (hasFocus && rightWindowAdded && !isRightTargetScenario(scenario)) {
            startFocusAndPublish();
        }
    }

    private void startFocusAndPublish() {
        if (started || !rightWindowAdded) return;
        View focusHost = targetEditor != null ? targetEditor : nonEditorFocusView;
        if (focusHost == null) return;
        started = true;
        focusHost.post(() -> {
            focusHost.requestFocus();
            if (targetEditor != null) {
                getSystemService(InputMethodManager.class)
                        .showSoftInput(targetEditor, InputMethodManager.SHOW_IMPLICIT);
            }
            focusHost.postDelayed(this::publish, 250);
        });
    }

    @Override
    protected void onDestroy() {
        if (rightWindowAdded && rightRoot != null) {
            try {
                getWindowManager().removeViewImmediate(rightRoot);
            } catch (RuntimeException ignored) {
                // Window already detached
            }
            rightWindowAdded = false;
        }
        super.onDestroy();
    }

    private LinearLayout buildPaneContainer(String title, int bgColor) {
        LinearLayout container = new LinearLayout(this);
        container.setOrientation(LinearLayout.VERTICAL);
        container.setBackgroundColor(bgColor);
        container.setPadding(24, 24, 24, 24);
        TextView header = new TextView(this);
        header.setText(title);
        header.setTextColor(Color.DKGRAY);
        container.addView(header, new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.WRAP_CONTENT));
        return container;
    }

    /**
     * 复现微信右侧 ChattingUI 的 2 个同 R.id 视图：
     * 1) 隐藏空占位 View（同 R.id，[0,0,0,0]，剥离 viewId/focused/visible）；
     * 2) MATCH_PARENT 实际 EditText（同 R.id，按场景剥离全部或保留真实 bounds/editable/inputType）。
     */
    private ParityEditText populateWeChatEditorPane(
            LinearLayout parent,
            int sharedId,
            boolean deadEndA11y,
            boolean declineFilteredCursorUpdates
    ) {
        View duplicateStub = new View(this);
        duplicateStub.setId(sharedId);
        duplicateStub.setAccessibilityDelegate(new StrippingDelegate(true));
        parent.addView(duplicateStub, new LinearLayout.LayoutParams(0, 0));

        ParityEditText editor = new ParityEditText(declineFilteredCursorUpdates);
        editor.setId(sharedId);
        editor.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_FLAG_MULTI_LINE);
        editor.setImeOptions(EditorInfo.IME_ACTION_SEND);
        editor.setBackgroundColor(Color.rgb(232, 244, 232));
        editor.setPadding(16, 16, 16, 16);
        editor.setAccessibilityDelegate(new StrippingDelegate(deadEndA11y));
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT
        );
        lp.topMargin = 32;
        parent.addView(editor, lp);
        duplicateIdCount = 2;
        return editor;
    }

    private int resourceId(String name) {
        int id = getResources().getIdentifier(name, "id", getPackageName());
        if (id == 0) throw new IllegalStateException("missing resource id: " + name);
        return id;
    }

    private static boolean isKnownScenario(String s) {
        return "disjoint_right_dead_end".equals(s)
                || "disjoint_right_valid_node".equals(s)
                || "disjoint_right_legacy_1arg".equals(s)
                || "disjoint_left_dead_end".equals(s)
                || "overlap_right".equals(s)
                || "type_null_decor".equals(s);
    }

    private static boolean isRightTargetScenario(String s) {
        return "disjoint_right_dead_end".equals(s)
                || "disjoint_right_valid_node".equals(s)
                || "disjoint_right_legacy_1arg".equals(s)
                || "overlap_right".equals(s);
    }

    private static final class StrippingDelegate extends View.AccessibilityDelegate {
        private final boolean zeroBoundsAndMetadata;

        StrippingDelegate(boolean zeroBoundsAndMetadata) {
            this.zeroBoundsAndMetadata = zeroBoundsAndMetadata;
        }

        @Override
        public void onInitializeAccessibilityNodeInfo(View host, AccessibilityNodeInfo info) {
            super.onInitializeAccessibilityNodeInfo(host, info);
            // 复现微信 >=8.0.52 反无障碍脱敏：剥离 viewIdResourceName / focused / visibleToUser
            info.setViewIdResourceName(null);
            info.setFocused(false);
            info.setVisibleToUser(false);
            if (zeroBoundsAndMetadata) {
                info.setEditable(false);
                info.setInputType(InputType.TYPE_NULL);
                info.setBoundsInScreen(new Rect(0, 0, 0, 0));
            }
        }
    }

    private final class ParityEditText extends EditText {
        private final boolean declineFilteredCursorUpdates;

        ParityEditText(boolean declineFilteredCursorUpdates) {
            super(WeChatParityActivity.this);
            this.declineFilteredCursorUpdates = declineFilteredCursorUpdates;
        }

        @Override
        public InputConnection onCreateInputConnection(EditorInfo outAttrs) {
            InputConnection base = super.onCreateInputConnection(outAttrs);
            if (base == null) return null;
            exportedFieldId = outAttrs.fieldId;
            exportedInputType = outAttrs.inputType;
            connected = true;
            post(WeChatParityActivity.this::publish);
            return new InputConnectionWrapper(base, false) {
                @Override
                public void requestTextBoundsInfo(
                        RectF bounds,
                        Executor executor,
                        Consumer<TextBoundsInfoResult> consumer
                ) {
                    textBoundsRequests++;
                    post(WeChatParityActivity.this::publish);
                    executor.execute(() -> consumer.accept(
                            new TextBoundsInfoResult(TextBoundsInfoResult.CODE_UNSUPPORTED)));
                }

                @Override
                public boolean requestCursorUpdates(int cursorUpdateMode, int cursorUpdateFilter) {
                    filteredCursorRequests++;
                    post(WeChatParityActivity.this::publish);
                    if (declineFilteredCursorUpdates) {
                        return false;
                    }
                    return super.requestCursorUpdates(cursorUpdateMode, cursorUpdateFilter);
                }

                @Override
                public boolean requestCursorUpdates(int cursorUpdateMode) {
                    legacyCursorRequests++;
                    post(WeChatParityActivity.this::publish);
                    return super.requestCursorUpdates(cursorUpdateMode);
                }
            };
        }
    }

    private static Rect viewScreenRect(View view) {
        int[] p = new int[2];
        view.getLocationOnScreen(p);
        return new Rect(p[0], p[1], p[0] + view.getWidth(), p[1] + view.getHeight());
    }

    private static Rect editorVisibleScreenRect(View view) {
        int[] p = new int[2];
        view.getLocationOnScreen(p);
        Rect box = new Rect();
        if (!view.getLocalVisibleRect(box)) {
            return new Rect(0, 0, 0, 0);
        }
        box.offset(p[0] - view.getScrollX(), p[1] - view.getScrollY());
        return box;
    }

    private static JSONArray rectArray(Rect r) throws org.json.JSONException {
        return new JSONArray(new int[]{r.left, r.top, r.right, r.bottom});
    }

    private void publish() {
        try {
            Rect leftWinRect = leftRoot != null ? viewScreenRect(leftRoot.getRootView()) : new Rect();
            Rect rightWinRect = rightRoot != null ? viewScreenRect(rightRoot.getRootView()) : new Rect();
            boolean disjoint = !Rect.intersects(leftWinRect, rightWinRect);

            JSONObject result = new JSONObject()
                    .put("case", scenario)
                    .put("uid", Process.myUid())
                    .put("landscape", getResources().getConfiguration().orientation
                            == android.content.res.Configuration.ORIENTATION_LANDSCAPE)
                    .put("connected", connected)
                    .put("left_window_rect", rectArray(leftWinRect))
                    .put("right_window_rect", rectArray(rightWinRect))
                    .put("windows_disjoint", disjoint)
                    .put("duplicate_id_view_count", duplicateIdCount)
                    .put("exported_field_id", exportedFieldId)
                    .put("exported_input_type", exportedInputType)
                    .put("text_bounds_requests", textBoundsRequests)
                    .put("filtered_cursor_requests", filteredCursorRequests)
                    .put("legacy_cursor_requests", legacyCursorRequests);

            if (targetEditor != null) {
                AccessibilityNodeInfo node = targetEditor.createAccessibilityNodeInfo();
                Rect a11yRect = new Rect();
                node.getBoundsInScreen(a11yRect);
                ViewGroup.LayoutParams lp = targetEditor.getLayoutParams();
                result.put("target_pane", isRightTargetScenario(scenario) ? "right" : "left")
                        .put("focused", targetEditor.hasFocus())
                        .put("window_focused", targetEditor.hasWindowFocus())
                        .put("target_window_id", node.getWindowId())
                        .put("target_rect", rectArray(editorVisibleScreenRect(targetEditor)))
                        .put("layout_width", lp != null ? lp.width : 0)
                        .put("target_a11y_view_id", node.getViewIdResourceName() == null
                                ? JSONObject.NULL : node.getViewIdResourceName())
                        .put("target_a11y_focused", node.isFocused())
                        .put("target_a11y_visible", node.isVisibleToUser())
                        .put("target_a11y_editable", node.isEditable())
                        .put("target_a11y_input_type", node.getInputType())
                        .put("target_a11y_rect", rectArray(a11yRect));
            } else {
                result.put("target_pane", "none")
                        .put("focused", nonEditorFocusView != null && nonEditorFocusView.hasFocus())
                        .put("window_focused", nonEditorFocusView != null && nonEditorFocusView.hasWindowFocus());
            }

            File tmp = new File(getFilesDir(), scenario + ".tmp");
            try (FileOutputStream out = new FileOutputStream(tmp)) {
                out.write(result.toString().getBytes(StandardCharsets.UTF_8));
            }
            if (!tmp.renameTo(new File(getFilesDir(), scenario + ".json"))) {
                throw new IllegalStateException("rename receipt failed");
            }
        } catch (Exception failure) {
            throw new IllegalStateException("wechat parity receipt failed", failure);
        }
    }
}
