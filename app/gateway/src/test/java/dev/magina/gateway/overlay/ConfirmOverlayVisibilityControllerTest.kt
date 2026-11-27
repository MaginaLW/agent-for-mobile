package dev.magina.gateway.overlay

import android.content.Intent
import dev.magina.gateway.core.SafetyFallbacks
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ConfirmOverlayVisibilityControllerTest {

    private val unlocked = ConfirmOverlayDeviceState(
        isKeyguardLocked = false,
        isDeviceLocked = false,
        isInteractive = true,
    )
    private val keyguardLockedOnly = ConfirmOverlayDeviceState(
        isKeyguardLocked = true,
        isDeviceLocked = false,
        isInteractive = true,
    )
    private val deviceLocked = ConfirmOverlayDeviceState(
        isKeyguardLocked = true,
        isDeviceLocked = true,
        isInteractive = true,
    )
    private val screenOff = ConfirmOverlayDeviceState(
        isKeyguardLocked = false,
        isDeviceLocked = false,
        isInteractive = false,
    )

    @Test
    fun `device state hides overlay on keyguard lock device lock screen off or missing services`() {
        assertFalse(
            resolveConfirmOverlayDeviceState(
                isKeyguardLocked = false,
                isDeviceLocked = false,
                isInteractive = true,
            ).shouldHideOverlay,
        )
        // 无密码滑动锁屏或人脸解锁后停留锁屏：isDeviceLocked=false 但 isKeyguardLocked=true，必须隐藏。
        assertTrue(
            resolveConfirmOverlayDeviceState(
                isKeyguardLocked = true,
                isDeviceLocked = false,
                isInteractive = true,
            ).shouldHideOverlay,
        )
        assertTrue(
            resolveConfirmOverlayDeviceState(
                isKeyguardLocked = false,
                isDeviceLocked = true,
                isInteractive = true,
            ).shouldHideOverlay,
        )
        assertTrue(
            resolveConfirmOverlayDeviceState(
                isKeyguardLocked = false,
                isDeviceLocked = false,
                isInteractive = false,
            ).shouldHideOverlay,
        )
        // 系统服务缺失一律 fail-closed。
        assertTrue(
            resolveConfirmOverlayDeviceState(
                isKeyguardLocked = null,
                isDeviceLocked = false,
                isInteractive = true,
            ).shouldHideOverlay,
        )
        assertTrue(
            resolveConfirmOverlayDeviceState(
                isKeyguardLocked = false,
                isDeviceLocked = null,
                isInteractive = true,
            ).shouldHideOverlay,
        )
        assertTrue(
            resolveConfirmOverlayDeviceState(
                isKeyguardLocked = false,
                isDeviceLocked = false,
                isInteractive = null,
            ).shouldHideOverlay,
        )
    }

    @Test
    fun `broadcast actions enforce immediate hide on screen off and live check on screen on or user present`() {
        // 即使 PowerManager.isInteractive 尚未翻转为 false，ACTION_SCREEN_OFF 也必须立即隐藏。
        assertTrue(
            resolveConfirmOverlayDeviceState(
                isKeyguardLocked = false,
                isDeviceLocked = false,
                isInteractive = true,
                broadcastAction = Intent.ACTION_SCREEN_OFF,
            ).shouldHideOverlay,
        )
        // 亮屏进入锁屏界面：ACTION_SCREEN_ON 期间 keyguard 仍锁定，必须保持隐藏。
        assertTrue(
            resolveConfirmOverlayDeviceState(
                isKeyguardLocked = true,
                isDeviceLocked = true,
                isInteractive = true,
                broadcastAction = Intent.ACTION_SCREEN_ON,
            ).shouldHideOverlay,
        )
        // 无锁屏亮屏恢复交互：允许恢复。
        assertFalse(
            resolveConfirmOverlayDeviceState(
                isKeyguardLocked = false,
                isDeviceLocked = false,
                isInteractive = true,
                broadcastAction = Intent.ACTION_SCREEN_ON,
            ).shouldHideOverlay,
        )
        // 伪造或滞后 ACTION_USER_PRESENT 若实时 keyguard 仍锁定，绝不放行。
        assertTrue(
            resolveConfirmOverlayDeviceState(
                isKeyguardLocked = true,
                isDeviceLocked = false,
                isInteractive = true,
                broadcastAction = Intent.ACTION_USER_PRESENT,
            ).shouldHideOverlay,
        )
        assertFalse(
            resolveConfirmOverlayDeviceState(
                isKeyguardLocked = false,
                isDeviceLocked = false,
                isInteractive = true,
                broadcastAction = Intent.ACTION_USER_PRESENT,
            ).shouldHideOverlay,
        )
    }

    @Test
    fun `initial attach fails closed when device is locked or screen off`() {
        listOf(keyguardLockedOnly, deviceLocked, screenOff).forEach { lockedState ->
            val controller = ConfirmOverlayVisibilityController()
            assertEquals(
                ConfirmOverlayVisibilityController.Action.FailLockedBeforeShown,
                controller.beginInitialAttach(lockedState),
            )
            assertEquals(ConfirmOverlayVisibilityController.Phase.CLOSED, controller.phase())
            assertFalse(controller.isAttached())
            assertFalse(controller.canAcceptOverlayDecision(controller.currentGeneration(), unlocked))
        }
    }

    @Test
    fun `locking before initial frame commit aborts closed and rejects late frame commit`() {
        val controller = ConfirmOverlayVisibilityController()
        val attach = controller.beginInitialAttach(unlocked) as ConfirmOverlayVisibilityController.Action.AttachInitial
        assertEquals(1, attach.generation)

        val lockAction = controller.onDeviceStateChanged(deviceLocked)
        assertEquals(ConfirmOverlayVisibilityController.Action.DetachAndFailLocked(1), lockAction)
        assertEquals(ConfirmOverlayVisibilityController.Phase.CLOSED, controller.phase())
        assertFalse(controller.isAttached())
        assertFalse(controller.onInitialFrameCommitted(1))
        assertEquals(ConfirmOverlayVisibilityController.Action.NoOp, controller.onDeviceStateChanged(unlocked))
    }

    @Test
    fun `locking after armed hides overlay and unlocking requires fresh draw plus frame commit`() {
        val controller = armedController()
        val initialGen = controller.currentGeneration()
        assertTrue(controller.canAcceptOverlayDecision(initialGen, unlocked))

        // 息屏/锁屏：卸载悬浮窗，原 generation 按钮点击立即失效，但确认会话保持 ARMED 以支持通知拒绝。
        assertEquals(
            ConfirmOverlayVisibilityController.Action.DetachForLock(initialGen),
            controller.onDeviceStateChanged(screenOff),
        )
        assertEquals(ConfirmOverlayVisibilityController.Phase.ARMED, controller.phase())
        assertFalse(controller.isAttached())
        assertFalse(controller.canAcceptOverlayDecision(initialGen, unlocked))
        assertEquals(ConfirmOverlayVisibilityController.Action.NoOp, controller.onDeviceStateChanged(deviceLocked))

        // 解锁恢复：重新挂载新 generation，未完成新帧提交前按钮仍不可接受决定。
        val reattach = controller.onDeviceStateChanged(unlocked)
            as ConfirmOverlayVisibilityController.Action.ReattachAfterUnlock
        assertTrue(reattach.generation > initialGen)
        assertTrue(controller.isAttached())
        assertFalse(controller.canAcceptOverlayDecision(reattach.generation, unlocked))
        assertFalse(controller.canAcceptOverlayDecision(initialGen, unlocked))

        assertTrue(controller.registerReattachFrameCommit(reattach.generation))
        assertEquals(
            ConfirmOverlayVisibilityController.Action.NoOp,
            controller.observeReattachDraw(reattach.generation),
        )
        assertFalse(controller.canAcceptOverlayDecision(reattach.generation, unlocked))

        assertEquals(
            ConfirmOverlayVisibilityController.Action.EnableButtons(reattach.generation),
            controller.observeReattachFrameCommitted(reattach.generation),
        )
        assertTrue(controller.canAcceptOverlayDecision(reattach.generation, unlocked))
    }

    @Test
    fun `reattach frame fence accepts commit before draw ordering`() {
        val controller = armedController()
        controller.onDeviceStateChanged(deviceLocked)
        val reattach = controller.onDeviceStateChanged(unlocked)
            as ConfirmOverlayVisibilityController.Action.ReattachAfterUnlock

        assertTrue(controller.registerReattachFrameCommit(reattach.generation))
        assertEquals(
            ConfirmOverlayVisibilityController.Action.NoOp,
            controller.observeReattachFrameCommitted(reattach.generation),
        )
        assertFalse(controller.canAcceptOverlayDecision(reattach.generation, unlocked))

        assertEquals(
            ConfirmOverlayVisibilityController.Action.EnableButtons(reattach.generation),
            controller.observeReattachDraw(reattach.generation),
        )
        assertTrue(controller.canAcceptOverlayDecision(reattach.generation, unlocked))
    }

    @Test
    fun `relocking during reattach invalidates pending frame fence callbacks`() {
        val controller = armedController()
        controller.onDeviceStateChanged(deviceLocked)
        val firstReattach = controller.onDeviceStateChanged(unlocked)
            as ConfirmOverlayVisibilityController.Action.ReattachAfterUnlock
        assertTrue(controller.registerReattachFrameCommit(firstReattach.generation))

        // 在解锁新帧提交前再次锁屏。
        assertEquals(
            ConfirmOverlayVisibilityController.Action.DetachForLock(firstReattach.generation),
            controller.onDeviceStateChanged(keyguardLockedOnly),
        )
        // 陈旧 generation 的迟到 draw / commit 一律忽略。
        assertEquals(
            ConfirmOverlayVisibilityController.Action.NoOp,
            controller.observeReattachDraw(firstReattach.generation),
        )
        assertEquals(
            ConfirmOverlayVisibilityController.Action.NoOp,
            controller.observeReattachFrameCommitted(firstReattach.generation),
        )
        assertFalse(controller.canAcceptOverlayDecision(firstReattach.generation, unlocked))
    }

    @Test
    fun `multiple lock unlock cycles isolate generations cleanly`() {
        val controller = armedController()
        val seenGenerations = mutableListOf(controller.currentGeneration())

        repeat(3) {
            val prevGen = controller.currentGeneration()
            assertEquals(
                ConfirmOverlayVisibilityController.Action.DetachForLock(prevGen),
                controller.onDeviceStateChanged(deviceLocked),
            )
            val reattach = controller.onDeviceStateChanged(unlocked)
                as ConfirmOverlayVisibilityController.Action.ReattachAfterUnlock
            assertTrue(reattach.generation > prevGen)
            assertTrue(controller.registerReattachFrameCommit(reattach.generation))
            assertEquals(
                ConfirmOverlayVisibilityController.Action.NoOp,
                controller.observeReattachDraw(reattach.generation),
            )
            assertEquals(
                ConfirmOverlayVisibilityController.Action.EnableButtons(reattach.generation),
                controller.observeReattachFrameCommitted(reattach.generation),
            )
            seenGenerations.forEach { staleGen ->
                assertFalse(controller.canAcceptOverlayDecision(staleGen, unlocked))
            }
            assertTrue(controller.canAcceptOverlayDecision(reattach.generation, unlocked))
            seenGenerations.add(reattach.generation)
        }
    }

    @Test
    fun `locking during evidence pending keeps overlay hidden until unlocked and reattached`() {
        val controller = ConfirmOverlayVisibilityController()
        val attach = controller.beginInitialAttach(unlocked) as ConfirmOverlayVisibilityController.Action.AttachInitial
        assertTrue(controller.onInitialFrameCommitted(attach.generation))
        assertEquals(ConfirmOverlayVisibilityController.Phase.EVIDENCE_PENDING, controller.phase())

        // 取证阶段发生锁屏：立即卸载，但取证完成后仍可进入 ARMED（等待通知拒绝或解锁后恢复）。
        assertEquals(
            ConfirmOverlayVisibilityController.Action.DetachForLock(attach.generation),
            controller.onDeviceStateChanged(deviceLocked),
        )
        assertEquals(ConfirmOverlayVisibilityController.Action.NoOp, controller.onEvidenceReady())
        assertEquals(ConfirmOverlayVisibilityController.Phase.ARMED, controller.phase())
        assertFalse(controller.isAttached())

        val reattach = controller.onDeviceStateChanged(unlocked)
            as ConfirmOverlayVisibilityController.Action.ReattachAfterUnlock
        assertTrue(controller.registerReattachFrameCommit(reattach.generation))
        assertEquals(
            ConfirmOverlayVisibilityController.Action.NoOp,
            controller.observeReattachDraw(reattach.generation),
        )
        assertEquals(
            ConfirmOverlayVisibilityController.Action.EnableButtons(reattach.generation),
            controller.observeReattachFrameCommitted(reattach.generation),
        )
        assertTrue(controller.canAcceptOverlayDecision(reattach.generation, unlocked))
    }

    @Test
    fun `unlocking during evidence pending never enables buttons before evidence is ready`() {
        val controller = ConfirmOverlayVisibilityController()
        val attach = controller.beginInitialAttach(unlocked) as ConfirmOverlayVisibilityController.Action.AttachInitial
        assertTrue(controller.onInitialFrameCommitted(attach.generation))

        controller.onDeviceStateChanged(deviceLocked)
        val reattach = controller.onDeviceStateChanged(unlocked)
            as ConfirmOverlayVisibilityController.Action.ReattachAfterUnlock
        assertTrue(controller.registerReattachFrameCommit(reattach.generation))
        assertEquals(
            ConfirmOverlayVisibilityController.Action.NoOp,
            controller.observeReattachDraw(reattach.generation),
        )
        // 即使新帧已提交，取证门尚未放行，不能启用按钮。
        assertEquals(
            ConfirmOverlayVisibilityController.Action.NoOp,
            controller.observeReattachFrameCommitted(reattach.generation),
        )
        assertFalse(controller.canAcceptOverlayDecision(reattach.generation, unlocked))

        // 取证完成后立即启用按钮。
        assertEquals(
            ConfirmOverlayVisibilityController.Action.EnableButtons(reattach.generation),
            controller.onEvidenceReady(),
        )
        assertTrue(controller.canAcceptOverlayDecision(reattach.generation, unlocked))
    }

    @Test
    fun `evidence ready before reattach frame commit waits for commit before enabling buttons`() {
        val controller = ConfirmOverlayVisibilityController()
        val attach = controller.beginInitialAttach(unlocked) as ConfirmOverlayVisibilityController.Action.AttachInitial
        assertTrue(controller.onInitialFrameCommitted(attach.generation))

        controller.onDeviceStateChanged(deviceLocked)
        val reattach = controller.onDeviceStateChanged(unlocked)
            as ConfirmOverlayVisibilityController.Action.ReattachAfterUnlock
        assertTrue(controller.registerReattachFrameCommit(reattach.generation))

        // 取证先完成，但重挂后的新帧尚未提交，不能提前启用按钮。
        assertEquals(ConfirmOverlayVisibilityController.Action.NoOp, controller.onEvidenceReady())
        assertFalse(controller.canAcceptOverlayDecision(reattach.generation, unlocked))

        assertEquals(
            ConfirmOverlayVisibilityController.Action.NoOp,
            controller.observeReattachDraw(reattach.generation),
        )
        assertEquals(
            ConfirmOverlayVisibilityController.Action.EnableButtons(reattach.generation),
            controller.observeReattachFrameCommitted(reattach.generation),
        )
        assertTrue(controller.canAcceptOverlayDecision(reattach.generation, unlocked))
    }

    @Test
    fun `live click guard rejects clicks when device is locked even before broadcast arrives`() {
        val controller = armedController()
        val gen = controller.currentGeneration()

        assertFalse(controller.canAcceptOverlayDecision(gen, keyguardLockedOnly))
        assertFalse(controller.canAcceptOverlayDecision(gen, deviceLocked))
        assertFalse(controller.canAcceptOverlayDecision(gen, screenOff))
        assertFalse(controller.canAcceptOverlayDecision(gen + 1, unlocked))
    }

    @Test
    fun `closing controller rejects all future state changes and overlay decisions`() {
        val controller = armedController()
        val gen = controller.currentGeneration()

        assertTrue(controller.close())
        assertEquals(ConfirmOverlayVisibilityController.Phase.CLOSED, controller.phase())
        assertFalse(controller.isAttached())
        assertFalse(controller.close())
        assertEquals(ConfirmOverlayVisibilityController.Action.NoOp, controller.onDeviceStateChanged(deviceLocked))
        assertEquals(ConfirmOverlayVisibilityController.Action.NoOp, controller.onDeviceStateChanged(unlocked))
        assertEquals(ConfirmOverlayVisibilityController.Action.NoOp, controller.onEvidenceReady())
        assertFalse(controller.canAcceptOverlayDecision(gen, unlocked))
        assertFalse(controller.canAcceptOverlayDecision(controller.currentGeneration(), unlocked))
    }

    @Test
    fun `lock broadcast policy allowlists system actions and defers reattach on screen on`() {
        assertTrue(isConfirmOverlayLockBroadcastAction(Intent.ACTION_SCREEN_OFF))
        assertTrue(isConfirmOverlayLockBroadcastAction(Intent.ACTION_SCREEN_ON))
        assertTrue(isConfirmOverlayLockBroadcastAction(Intent.ACTION_USER_PRESENT))
        assertFalse(isConfirmOverlayLockBroadcastAction(null))
        assertFalse(isConfirmOverlayLockBroadcastAction(""))
        assertFalse(isConfirmOverlayLockBroadcastAction("dev.magina.gateway.FAKE_UNLOCK"))

        assertFalse(shouldAllowOverlayReattachOnBroadcast(Intent.ACTION_SCREEN_OFF))
        assertFalse(shouldAllowOverlayReattachOnBroadcast(Intent.ACTION_SCREEN_ON))
        assertTrue(shouldAllowOverlayReattachOnBroadcast(Intent.ACTION_USER_PRESENT))
        assertTrue(shouldAllowOverlayReattachOnBroadcast(null))
    }

    @Test
    fun `screen on defers reattach to avoid oem lockscreen flash while still hiding immediately if locked`() {
        val controller = armedController()
        val initialGen = controller.currentGeneration()

        // 1) 已挂载时即便 allowReattach=false，一旦实时态为锁屏仍必须立刻卸载。
        assertEquals(
            ConfirmOverlayVisibilityController.Action.DetachForLock(initialGen),
            controller.onDeviceStateChanged(deviceLocked, allowReattach = false),
        )
        assertFalse(controller.isAttached())
        assertTrue(controller.isLocked())

        // 2) 亮屏进锁屏瞬态（ACTION_SCREEN_ON 到达但 OEM 尚未翻转 isKeyguardLocked）：
        //    allowReattach=false 绝不立刻重挂，避免锁屏明文闪烁。
        assertEquals(
            ConfirmOverlayVisibilityController.Action.NoOp,
            controller.onDeviceStateChanged(unlocked, allowReattach = false),
        )
        assertFalse(controller.isAttached())
        assertTrue(controller.isLocked())

        // 3a) 若下一次轮询时 OEM 已翻转为锁定，保持隐藏。
        assertEquals(
            ConfirmOverlayVisibilityController.Action.NoOp,
            controller.onDeviceStateChanged(keyguardLockedOnly, allowReattach = true),
        )
        assertFalse(controller.isAttached())

        // 3b) 真正解锁（ACTION_USER_PRESENT 或无锁屏设备下一次轮询 allowReattach=true）后正常重挂。
        val reattach = controller.onDeviceStateChanged(unlocked, allowReattach = true)
            as ConfirmOverlayVisibilityController.Action.ReattachAfterUnlock
        assertTrue(reattach.generation > initialGen)
        assertTrue(controller.isAttached())
        assertFalse(controller.isLocked())
    }

    @Test
    fun `overlay locked fallback enforces terminal safety wording`() {
        assertTrue(SafetyFallbacks.OVERLAY_LOCKED.startsWith(SafetyFallbacks.TERMINAL))
        assertTrue(SafetyFallbacks.OVERLAY_LOCKED.contains("不得输出 [AWAIT_CONFIRM]"))
    }

    private fun armedController(): ConfirmOverlayVisibilityController =
        ConfirmOverlayVisibilityController().apply {
            val attach = beginInitialAttach(unlocked) as ConfirmOverlayVisibilityController.Action.AttachInitial
            assertTrue(onInitialFrameCommitted(attach.generation))
            assertEquals(
                ConfirmOverlayVisibilityController.Action.EnableButtons(attach.generation),
                onEvidenceReady(),
            )
        }
}
