package dev.magina.autofillobserver;

import java.io.*;
import java.nio.file.Files;
import java.util.List;
import java.util.concurrent.Executor;
import java.util.function.Consumer;

/** 只提供夹具读写的 Android 值和回调，不持有真值窗口或选框逻辑。 */
public final class HostAndroid {
    static File filesDir;
    static long clock;
    record ComponentName(String pkg, String name) {}
    record RectF(float left, float top, float right, float bottom) {}
    static final class Rect {
        final int left, top, right, bottom;
        Rect(int left, int top, int right, int bottom) {
            this.left = left; this.top = top; this.right = right; this.bottom = bottom;
        }
        boolean isEmpty() { return left >= right || top >= bottom; }
    }
    record Matrix(boolean isIdentity) {}
    static final class SystemClock { static long uptimeMillis() { return clock; } }
    static final class Process {
        static int myUid() { return 2; }
        static int myPid() { return 20; }
    }
    static final class Looper { static Looper getMainLooper() { return new Looper(); } }
    record Handler(Looper looper) {
        void postDelayed(Runnable callback, long millis) { clock += millis; callback.run(); }
    }
    record AtomicFile(File getBaseFile) {
        byte[] readFully() throws IOException { return Files.readAllBytes(getBaseFile.toPath()); }
        FileOutputStream startWrite() throws IOException { return new FileOutputStream(getBaseFile); }
        void finishWrite(FileOutputStream stream) throws IOException { stream.close(); }
        void failWrite(FileOutputStream stream) throws IOException { stream.close(); }
    }
    // API 36 公开方法经反射调用。完整相等包含会话号，原生 viewId 单独可比。
    public record AutofillId(int getViewId, int session) {
        public boolean isInAutofillSession() { return session != 0; }
        public boolean isVirtual() { return false; }
    }
    static final class View {
        static final int VISIBLE = 0, AUTOFILL_TYPE_TEXT = 1;
        static final int IMPORTANT_FOR_AUTOFILL_NO = 2, IMPORTANT_FOR_AUTOFILL_YES_EXCLUDE_DESCENDANTS = 4,
                IMPORTANT_FOR_AUTOFILL_NO_EXCLUDE_DESCENDANTS = 8;
    }
    record ViewNode(int getLeft, int getTop, int getWidth, int getHeight, AutofillId getAutofillId,
                    boolean isFocused, List<ViewNode> children) {
        int getAutofillType() { return getAutofillId == null ? 0 : View.AUTOFILL_TYPE_TEXT; }
        int getImportantForAutofill() { return 0; }
        int getScrollX() { return 0; }
        int getScrollY() { return 0; }
        int getVisibility() { return View.VISIBLE; }
        Matrix getTransformation() { return null; }
        int getChildCount() { return children.size(); }
        ViewNode getChildAt(int i) { return children.get(i); }
    }
    static final class WindowNode {
        final int x;
        final ViewNode root;
        int reads;
        WindowNode(int x, ViewNode root) { this.x = x; this.root = root; }
        int getLeft() { return x; }
        int getTop() { return 0; }
        ViewNode getRootViewNode() { reads++; return root; }
    }
    record AssistStructure(ComponentName getActivityComponent, List<WindowNode> windows,
                           long getAcquisitionStartTime, long getAcquisitionEndTime) {
        int getWindowNodeCount() { return windows.size(); }
        WindowNode getWindowNodeAt(int i) { return windows.get(i); }
    }
    record FillContext(AssistStructure getStructure, AutofillId getFocusedId, int getRequestId) {}
    record FillRequest(List<FillContext> getFillContexts, int getId, int getFlags) {
        static final int FLAG_MANUAL_REQUEST = 1;
    }
    record CancellationSignal(boolean isCanceled) {}
    interface FillCallback { void onSuccess(Object result); }
    static final class SaveRequest {}
    interface SaveCallback { void onSuccess(); }
    abstract static class AutofillService {
        File getFilesDir() { return filesDir; }
        public abstract void onFillRequest(FillRequest request, CancellationSignal signal, FillCallback callback);
        public abstract void onSaveRequest(SaveRequest request, SaveCallback callback);
    }

    public static final class EditorInfo {
        final String packageName;
        final AutofillId id;
        EditorInfo(String pkg, AutofillId id) { this.packageName = pkg; this.id = id; }
        public AutofillId getAutofillId() { return id; }
    }
    interface InputConnection {
        void requestTextBoundsInfo(RectF area, Executor executor, Consumer<Object> callback);
    }
    record InputBinding(int getUid) {}
    static final class PackageManager {
        static class NameNotFoundException extends Exception {}
        static final class ApplicationInfo { final int uid = 1; }
        ApplicationInfo getApplicationInfo(String pkg, int flags) throws NameNotFoundException {
            if (!ProbeIme.TARGET.equals(pkg)) throw new NameNotFoundException();
            return new ApplicationInfo();
        }
    }
    static class InputMethodService {
        EditorInfo editor;
        InputConnection connection;
        EditorInfo getCurrentInputEditorInfo() { return editor; }
        InputBinding getCurrentInputBinding() { return new InputBinding(1); }
        InputConnection getCurrentInputConnection() { return connection; }
        PackageManager getPackageManager() { return new PackageManager(); }
        Executor getMainExecutor() { return Runnable::run; }
        public void onStartInput(EditorInfo info, boolean restarting) {}
        public void onFinishInput() {}
        public void onUnbindInput() {}
        public void onDestroy() {}
        public boolean onEvaluateFullscreenMode() { return false; }
        public boolean onShowInputRequested(int flags, boolean configChange) { return false; }
    }
}
