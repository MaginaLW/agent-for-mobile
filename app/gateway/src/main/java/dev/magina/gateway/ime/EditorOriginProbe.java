package dev.magina.gateway.ime;

import android.graphics.Matrix;
import android.graphics.PointF;
import android.graphics.RectF;
import android.os.Build;
import android.view.inputmethod.InputConnection;
import android.view.inputmethod.TextBoundsInfo;
import android.view.inputmethod.TextBoundsInfoResult;

import java.util.concurrent.Executor;
import java.util.function.BooleanSupplier;
import java.util.function.Consumer;

/** 只向本次输入连接请求局部坐标系的屏幕原点。编辑框的宽、高和窗口归属需要独立证据。 */
public final class EditorOriginProbe {
    private EditorOriginProbe() {}

    public static void request(InputConnection connection, Executor executor,
            BooleanSupplier stillCurrent, Consumer<PointF> completed) {
        if (Build.VERSION.SDK_INT < 34 || connection == null || !stillCurrent.getAsBoolean()) {
            completed.accept(null);
            return;
        }
        // 屏幕外的空查询。标准 EditText 即使草稿为空也会在空结果中附带变换矩阵。
        RectF query = new RectF(-1f, -1f, -1f, -1f);
        connection.requestTextBoundsInfo(query, executor, result -> {
            PointF origin = null;
            if (stillCurrent.getAsBoolean()) {
                try {
                    origin = readOrigin(result);
                } catch (RuntimeException malformedReply) {
                    // 此对象由远端编辑器构造。畸形几何也须在 IME 主线程内结束本次读取。
                }
            }
            completed.accept(origin);
        });
    }

    @android.annotation.TargetApi(34)
    private static PointF readOrigin(TextBoundsInfoResult result) {
        if (result == null || result.getResultCode() != TextBoundsInfoResult.CODE_SUCCESS) return null;
        TextBoundsInfo info = result.getTextBoundsInfo();
        if (info == null || info.getStartIndex() != info.getEndIndex()) return null;
        Matrix matrix = new Matrix();
        info.getMatrix(matrix);
        if (!matrix.isAffine() || !matrix.invert(new Matrix())) return null;
        float[] origin = {0f, 0f};
        matrix.mapPoints(origin);
        return Float.isFinite(origin[0]) && Float.isFinite(origin[1])
                ? new PointF(origin[0], origin[1]) : null;
    }
}
