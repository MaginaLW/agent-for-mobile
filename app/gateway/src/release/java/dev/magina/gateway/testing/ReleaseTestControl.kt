package dev.magina.gateway.testing

import android.content.Context

class ReleaseTestControl : NoopTestControl()

object TestControlFactory {
    fun create(context: Context): TestControl = ReleaseTestControl()
}
