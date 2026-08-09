package dev.magina.gateway.overlay

import android.app.PendingIntent
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ConfirmNotifierPendingIntentIdentityTest {

    @Test
    fun `same decision for different confirmations has a different pending intent identity`() {
        val confirmationA = decisionPendingIntentSpec("confirmation-a", allowed = true)
        val confirmationB = decisionPendingIntentSpec("confirmation-b", allowed = true)

        // 同一种决定可以复用 requestCode；data URI 必须阻止 A 与 B 被 Android 匹配成同一身份。
        assertEquals(confirmationA.requestCode, confirmationB.requestCode)
        assertNotEquals(confirmationA.dataUri, confirmationB.dataUri)
    }

    @Test
    fun `allow and deny remain different identities for one confirmation`() {
        val allow = decisionPendingIntentSpec("confirmation-a", allowed = true)
        val deny = decisionPendingIntentSpec("confirmation-a", allowed = false)

        assertNotEquals(allow.requestCode, deny.requestCode)
        assertNotEquals(allow.dataUri, deny.dataUri)
    }

    @Test
    fun `reposting one confirmation cancels its old one shot handle instead of updating it`() {
        val firstPost = decisionPendingIntentSpec("confirmation/a", allowed = true)
        val repeatedPost = decisionPendingIntentSpec("confirmation/a", allowed = true)
        val lookalikeId = decisionPendingIntentSpec("confirmation%2Fa", allowed = true)

        assertEquals(firstPost, repeatedPost)
        assertNotEquals(firstPost.dataUri, lookalikeId.dataUri)
        assertTrue(firstPost.flags and PendingIntent.FLAG_IMMUTABLE != 0)
        assertTrue(firstPost.flags and PendingIntent.FLAG_CANCEL_CURRENT != 0)
        assertTrue(firstPost.flags and PendingIntent.FLAG_ONE_SHOT != 0)
        assertEquals(0, firstPost.flags and PendingIntent.FLAG_UPDATE_CURRENT)
    }

    @Test
    fun `details action remains reusable while its notification stays visible`() {
        val flags = detailsPendingIntentFlags()

        assertEquals(PendingIntent.FLAG_IMMUTABLE, flags)
        assertEquals(0, flags and PendingIntent.FLAG_ONE_SHOT)
        assertEquals(0, flags and PendingIntent.FLAG_UPDATE_CURRENT)
        assertEquals(0, flags and PendingIntent.FLAG_CANCEL_CURRENT)
    }
}
