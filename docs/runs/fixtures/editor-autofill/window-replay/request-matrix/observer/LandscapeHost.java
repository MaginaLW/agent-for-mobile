package dev.magina.publicwindow;

import android.app.Activity;
import android.os.Bundle;
import android.widget.FrameLayout;

/** 浮动窗下方的横屏空白底窗。无输入控件、假数据或观测接口。 */
public final class LandscapeHost extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        setContentView(new FrameLayout(this));
    }
}
