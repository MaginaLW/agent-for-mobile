package dev.magina.gateway.overlay

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class ConfirmationReadinessGateTest {
    @Test
    fun `evidence cannot start before hardware frame commit`() {
        val gate = ConfirmationReadinessGate()

        expectIllegalState { gate.beginEvidence() }
        assertTrue(gate.registerFrameCommit())
        expectIllegalState { gate.beginEvidence() }
        assertTrue(gate.observeDraw())
        expectIllegalState { gate.beginEvidence() }
        gate.frameCommitted()
        gate.beginEvidence()

        assertEquals(ConfirmationReadinessGate.State.EVIDENCE_PENDING, gate.state())
    }

    @Test
    fun `buttons cannot enable until evidence is ready`() {
        val gate = drawnGate()
        gate.beginEvidence()

        expectIllegalState { gate.enableButtons() }
        gate.evidenceReady()
        gate.enableButtons()

        assertEquals(ConfirmationReadinessGate.State.BUTTONS_ENABLED, gate.state())
    }

    @Test
    fun `only first draw observation owns completion fence`() {
        val gate = ConfirmationReadinessGate()

        assertTrue(gate.registerFrameCommit())
        assertTrue(gate.observeDraw())
        assertFalse(gate.observeDraw())
        gate.frameCommitted()
        assertFalse(gate.observeDraw())
    }

    @Test
    fun `single traversal succeeds without requiring a later redraw`() {
        val gate = ConfirmationReadinessGate()

        gate.registerFrameCommit() // onPreDraw
        gate.observeDraw() // same traversal onDraw
        assertTrue(gate.frameCommitted()) // same frame commit callback
        gate.beginEvidence()

        assertEquals(ConfirmationReadinessGate.State.EVIDENCE_PENDING, gate.state())
    }

    @Test
    fun `commit and draw event ordering is robust`() {
        val gate = ConfirmationReadinessGate()

        gate.registerFrameCommit()
        assertFalse(gate.frameCommitted())
        assertTrue(gate.observeDraw())

        gate.beginEvidence()
        assertEquals(ConfirmationReadinessGate.State.EVIDENCE_PENDING, gate.state())
    }

    @Test
    fun `failure permanently prevents evidence and button enabling`() {
        val gate = ConfirmationReadinessGate()
        gate.fail()

        assertEquals(ConfirmationReadinessGate.State.FAILED, gate.state())
        expectIllegalState { gate.beginEvidence() }
        expectIllegalState { gate.enableButtons() }
    }

    @Test
    fun `frame commit timeout fails closed after draw observation`() {
        val gate = ConfirmationReadinessGate()
        gate.registerFrameCommit()
        gate.observeDraw()
        gate.fail()

        expectIllegalState { gate.frameCommitted() }
        expectIllegalState { gate.beginEvidence() }
        assertEquals(ConfirmationReadinessGate.State.FAILED, gate.state())
    }

    private fun drawnGate(): ConfirmationReadinessGate = ConfirmationReadinessGate().also {
        it.registerFrameCommit()
        it.observeDraw()
        it.frameCommitted()
    }

    private fun expectIllegalState(block: () -> Unit) {
        try {
            block()
            fail("expected IllegalStateException")
        } catch (_: IllegalStateException) {
            // expected
        }
    }
}
