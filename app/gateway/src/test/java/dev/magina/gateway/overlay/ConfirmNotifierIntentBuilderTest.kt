package dev.magina.gateway.overlay

import android.app.PendingIntent
import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [35])
class ConfirmNotifierIntentBuilderTest {

    private val context get() = RuntimeEnvironment.getApplication()

    @Test
    fun `production decision intent builder carries the complete explicit contract`() {
        val intent = buildDecisionIntent(
            context = context,
            confirmationId = "confirmation/a",
            nonce = "nonce-a",
            allowed = true,
        )
        assertDecisionIntentContract(intent, "confirmation/a", "nonce-a", allowed = true)

        // 不只测可调用的 builder：生产 decisionIntent 创建 PendingIntent 时保存的也必须是同一契约。
        val pending = ConfirmNotifier.decisionIntent(context, "confirmation/a", "nonce-a", true)
        val shadow = shadowOf(pending)
        assertDecisionIntentContract(shadow.savedIntent, "confirmation/a", "nonce-a", allowed = true)
        assertEquals(decisionPendingIntentSpec("confirmation/a", true).requestCode, shadow.requestCode)
        assertEquals(decisionPendingIntentSpec("confirmation/a", true).flags, shadow.flags)
        assertTrue(shadow.isBroadcast)
        assertTrue(shadow.isImmutable)
    }

    @Test
    fun `intent filter identity and pending intent identity bind confirmation plus decision`() {
        val allowA = buildDecisionIntent(context, "confirmation-a", "nonce-a", allowed = true)
        val allowARepost = buildDecisionIntent(context, "confirmation-a", "nonce-new", allowed = true)
        val allowB = buildDecisionIntent(context, "confirmation-b", "nonce-b", allowed = true)
        val denyA = buildDecisionIntent(context, "confirmation-a", "nonce-a", allowed = false)

        // extras 不参与 Android Intent.filterEquals；同一次确认重发仍是同一个待取消身份。
        assertTrue(allowA.filterEquals(allowARepost))
        assertFalse(allowA.filterEquals(allowB))
        assertFalse(allowA.filterEquals(denyA))

        val pendingAllowA = ConfirmNotifier.decisionIntent(context, "confirmation-a", "nonce-a", true)
        val pendingAllowB = ConfirmNotifier.decisionIntent(context, "confirmation-b", "nonce-b", true)
        val pendingDenyA = ConfirmNotifier.decisionIntent(context, "confirmation-a", "nonce-a", false)
        assertNotEquals(pendingAllowA, pendingAllowB)
        assertNotEquals(pendingAllowA, pendingDenyA)
    }

    @Test
    fun `reposting the same decision cancels the previous one shot handle`() {
        val oldHandle = ConfirmNotifier.decisionIntent(context, "confirmation-a", "nonce-old", true)
        val replacement = ConfirmNotifier.decisionIntent(context, "confirmation-a", "nonce-new", true)

        try {
            oldHandle.send()
            fail("FLAG_CANCEL_CURRENT must invalidate the old handle")
        } catch (_: PendingIntent.CanceledException) {
            // expected
        }
        replacement.send()
        try {
            replacement.send()
            fail("FLAG_ONE_SHOT must invalidate the replacement after its first send")
        } catch (_: PendingIntent.CanceledException) {
            // expected
        }
    }

    private fun assertDecisionIntentContract(
        intent: Intent,
        confirmationId: String,
        nonce: String,
        allowed: Boolean,
    ) {
        val spec = decisionPendingIntentSpec(confirmationId, allowed)
        assertEquals(ConfirmNotifier.ACTION_DECIDE, intent.action)
        assertEquals(
            ComponentName(context.packageName, ConfirmDecisionReceiver::class.java.name),
            intent.component,
        )
        assertEquals(context.packageName, intent.`package`)
        assertEquals(Uri.parse(spec.dataUri), intent.data)
        assertEquals(
            setOf(
                ConfirmNotifier.EXTRA_CONFIRMATION_ID,
                ConfirmNotifier.EXTRA_NONCE,
                ConfirmNotifier.EXTRA_ALLOWED,
            ),
            intent.extras?.keySet(),
        )
        assertEquals(confirmationId, intent.getStringExtra(ConfirmNotifier.EXTRA_CONFIRMATION_ID))
        assertEquals(nonce, intent.getStringExtra(ConfirmNotifier.EXTRA_NONCE))
        assertEquals(allowed, intent.getBooleanExtra(ConfirmNotifier.EXTRA_ALLOWED, !allowed))
    }
}
