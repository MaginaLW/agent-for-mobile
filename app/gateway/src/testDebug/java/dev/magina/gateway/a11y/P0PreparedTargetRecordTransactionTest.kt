package dev.magina.gateway.a11y

import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import dev.magina.gateway.core.FocusIdentity
import dev.magina.gateway.core.IdentitySource
import dev.magina.gateway.core.PreparedTargetEvidenceStore
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.fail
import org.junit.Test

class P0PreparedTargetRecordTransactionTest {
    @Test
    fun `wrapper rolls back record when service post guard detects revision drift`() {
        val store = PreparedTargetEvidenceStore()
        var guardedCalls = 0

        try {
            P0PreparedTargetRecordTransaction.run(rollback = store::clear) {
                guardedCalls++
                store.record(
                    label = P0_FILE_TRANSFER_ASSISTANT,
                    packageName = P0_WECHAT_PACKAGE,
                    identity = FocusIdentity(
                        IdentitySource.A11Y,
                        "7|id/chat_input|android.widget.EditText|com.tencent.mm|100,1600,980,1760",
                        "ime|0123456789abcdef01234567",
                    ),
                    bounds = "[100,1600][980,1760]",
                )
                throw GatewayError(ErrorCode.E_STALE_REF, "post guard revision drift")
            }
            fail("post guard drift must escape")
        } catch (error: GatewayError) {
            assertEquals(ErrorCode.E_STALE_REF, error.code)
        }

        assertEquals(1, guardedCalls)
        assertNull(store.peekActive())
    }
}
