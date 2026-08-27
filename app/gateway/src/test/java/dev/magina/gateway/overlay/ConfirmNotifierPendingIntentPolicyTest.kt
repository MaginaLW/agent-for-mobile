package dev.magina.gateway.overlay

import android.app.PendingIntent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ConfirmNotifierPendingIntentPolicyTest {

    @Test
    fun `notification exposes deny and details but never allow`() {
        assertEquals(
            listOf(ConfirmNotificationAction.DENY, ConfirmNotificationAction.DETAILS),
            confirmNotificationActions(),
        )
    }

    @Test
    fun `every action is immutable one shot and cannot update an old handle`() {
        confirmNotificationActions().forEach { action ->
            val spec = confirmNotificationPendingIntentSpec("confirmation-a", action)

            assertTrue(spec.flags and PendingIntent.FLAG_IMMUTABLE != 0)
            assertTrue(spec.flags and PendingIntent.FLAG_CANCEL_CURRENT != 0)
            assertTrue(spec.flags and PendingIntent.FLAG_ONE_SHOT != 0)
            assertEquals(0, spec.flags and PendingIntent.FLAG_UPDATE_CURRENT)
        }
    }

    @Test
    fun `confirmation and action both participate in pending intent identity`() {
        val denyA = confirmNotificationPendingIntentSpec(
            "confirmation/a",
            ConfirmNotificationAction.DENY,
        )
        val denyB = confirmNotificationPendingIntentSpec(
            "confirmation%2Fa",
            ConfirmNotificationAction.DENY,
        )
        val detailsA = confirmNotificationPendingIntentSpec(
            "confirmation/a",
            ConfirmNotificationAction.DETAILS,
        )

        // requestCode 可按动作复用；data URI 必须让不同确认无法被 Android 匹配成同一身份。
        assertEquals(denyA.requestCode, denyB.requestCode)
        assertNotEquals(denyA.dataUri, denyB.dataUri)
        assertNotEquals(denyA.requestCode, detailsA.requestCode)
        assertNotEquals(denyA.dataUri, detailsA.dataUri)
    }

    @Test
    fun `reposting one action replaces rather than mutates the old identity`() {
        val first = confirmNotificationPendingIntentSpec(
            "confirmation-a",
            ConfirmNotificationAction.DENY,
        )
        val repost = confirmNotificationPendingIntentSpec(
            "confirmation-a",
            ConfirmNotificationAction.DENY,
        )

        assertEquals(first, repost)
        assertTrue(first.flags and PendingIntent.FLAG_CANCEL_CURRENT != 0)
    }
}
