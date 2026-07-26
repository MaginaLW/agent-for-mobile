package dev.magina.gateway.a11y

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ForegroundWindowTrackerTest {
    private val wechat = ForegroundWindow(
        id = 11,
        type = ForegroundWindowType.APPLICATION,
        isActive = true,
        isFocused = true,
    )
    private val wechatIdentity = ForegroundIdentity.Known(
        windowId = wechat.id,
        packageName = "com.tencent.mm",
        activityName = "com.tencent.mm.ui.LauncherUI",
    )

    @Test
    fun `gateway overlay event does not replace active WeChat identity`() {
        val tracker = ForegroundWindowTracker()
        val overlay = ForegroundWindow(id = 22, type = ForegroundWindowType.OTHER)
        val windows = listOf(wechat, overlay)

        assertTrue(tracker.onWindowStateChanged(
            eventWindowId = wechat.id,
            packageName = "com.tencent.mm",
            activityName = "com.tencent.mm.ui.LauncherUI",
            windows = windows,
        ))
        assertFalse(tracker.onWindowStateChanged(
            eventWindowId = overlay.id,
            packageName = "dev.magina.gateway",
            activityName = "android.widget.FrameLayout",
            windows = windows,
        ))

        assertEquals(
            wechatIdentity,
            tracker.current(),
        )
    }

    @Test
    fun `new active application window id updates foreground identity`() {
        val tracker = ForegroundWindowTracker()
        tracker.onWindowStateChanged(
            eventWindowId = wechat.id,
            packageName = "com.tencent.mm",
            activityName = "com.tencent.mm.ui.LauncherUI",
            windows = listOf(wechat),
        )
        val settings = ForegroundWindow(
            id = 33,
            type = ForegroundWindowType.APPLICATION,
            isActive = true,
            isFocused = true,
        )

        assertTrue(tracker.onWindowStateChanged(
            eventWindowId = settings.id,
            packageName = "com.android.settings",
            activityName = "com.android.settings.Settings",
            windows = listOf(wechat.copy(isActive = false, isFocused = false), settings),
        ))
        assertEquals(
            ForegroundIdentity.Known(
                settings.id,
                "com.android.settings",
                "com.android.settings.Settings",
            ),
            tracker.current(),
        )
    }

    @Test
    fun `IME and inactive application events do not update foreground identity`() {
        val ignoredWindows = listOf(
            ForegroundWindow(id = 44, type = ForegroundWindowType.INPUT_METHOD, isFocused = true),
            ForegroundWindow(id = 55, type = ForegroundWindowType.APPLICATION),
        )

        ignoredWindows.forEach { ignored ->
            val tracker = trackerAtWeChat(listOf(wechat, ignored))
            assertFalse(
                "window ${ignored.id} should be ignored",
                tracker.onWindowStateChanged(
                    eventWindowId = ignored.id,
                    packageName = "ignored.package",
                    activityName = "ignored.Activity",
                    windows = listOf(wechat, ignored),
                ),
            )
            assertEquals(
                wechatIdentity,
                tracker.current(),
            )
        }
    }

    @Test
    fun `focused application is conservative fallback when no application is active`() {
        val tracker = ForegroundWindowTracker()
        val focused = ForegroundWindow(
            id = 66,
            type = ForegroundWindowType.APPLICATION,
            isFocused = true,
        )

        assertEquals(ForegroundIdentity.Unknown, tracker.current())
        assertTrue(tracker.onWindowStateChanged(
            eventWindowId = focused.id,
            packageName = "com.example.focused",
            activityName = "com.example.focused.MainActivity",
            windows = listOf(focused),
        ))
        assertEquals(
            ForegroundIdentity.Known(
                focused.id,
                "com.example.focused",
                "com.example.focused.MainActivity",
            ),
            tracker.current(),
        )
    }

    @Test
    fun `accepted package event clears missing activity instead of retaining old activity`() {
        val tracker = trackerAtWeChat(listOf(wechat))
        val settings = ForegroundWindow(
            id = 77,
            type = ForegroundWindowType.APPLICATION,
            isActive = true,
        )

        assertTrue(tracker.onWindowStateChanged(
            eventWindowId = settings.id,
            packageName = "com.android.settings",
            activityName = null,
            windows = listOf(settings),
        ))
        assertEquals(
            ForegroundIdentity.Known(settings.id, "com.android.settings", ""),
            tracker.current(),
        )
    }

    @Test
    fun `window event arriving before windows list publishes on next windows change`() {
        val tracker = ForegroundWindowTracker()

        assertFalse(tracker.onWindowStateChanged(
            eventWindowId = wechat.id,
            packageName = "com.tencent.mm",
            activityName = "com.tencent.mm.ui.LauncherUI",
            windows = emptyList(),
        ))
        assertEquals(ForegroundIdentity.Unknown, tracker.current())

        assertTrue(tracker.onWindowsChanged(listOf(wechat)))
        assertEquals(
            wechatIdentity,
            tracker.current(),
        )
    }

    @Test
    fun `real application candidate survives unrelated missing package overlay and IME events`() {
        val tracker = ForegroundWindowTracker()
        val overlay = ForegroundWindow(
            id = 177,
            type = ForegroundWindowType.OTHER,
            isActive = true,
            isFocused = true,
        )
        val ime = ForegroundWindow(
            id = 188,
            type = ForegroundWindowType.INPUT_METHOD,
            isActive = true,
            isFocused = true,
        )
        val focusedWeChat = wechat.copy(isActive = false, isFocused = true)

        assertFalse(tracker.onWindowStateChanged(
            eventWindowId = wechat.id,
            packageName = "com.tencent.mm",
            activityName = "com.tencent.mm.ui.LauncherUI",
            windows = emptyList(),
        ))
        assertFalse(tracker.onWindowStateChanged(
            eventWindowId = 199,
            packageName = null,
            activityName = "missing.Package",
            windows = emptyList(),
        ))
        // 当前列表已明确归属为非应用窗口的事件，不得清掉先到的真实应用候选。
        assertFalse(tracker.onWindowStateChanged(
            eventWindowId = overlay.id,
            packageName = "dev.magina.gateway",
            activityName = "android.widget.FrameLayout",
            windows = listOf(overlay, focusedWeChat),
        ))
        assertFalse(tracker.onWindowStateChanged(
            eventWindowId = ime.id,
            packageName = "dev.magina.gateway.ime",
            activityName = "android.inputmethodservice.InputMethodService",
            windows = listOf(ime, focusedWeChat),
        ))
        // 列表完全未出现的非应用事件先进入候选，下一次刷新再按窗口类型淘汰。
        assertFalse(tracker.onWindowStateChanged(
            eventWindowId = overlay.id,
            packageName = "dev.magina.gateway",
            activityName = "android.widget.FrameLayout",
            windows = emptyList(),
        ))
        assertFalse(tracker.onWindowStateChanged(
            eventWindowId = ime.id,
            packageName = "dev.magina.gateway.ime",
            activityName = "android.inputmethodservice.InputMethodService",
            windows = emptyList(),
        ))

        assertTrue(tracker.onWindowsChanged(listOf(wechat, overlay, ime)))
        assertEquals(wechatIdentity, tracker.current())

        // 刷新已整批消费候选，其他 id 后续复用为应用窗口也不能发布。
        listOf(overlay, ime).forEach { staleCandidate ->
            assertFalse(tracker.onWindowsChanged(listOf(
                staleCandidate.copy(type = ForegroundWindowType.APPLICATION),
            )))
            assertEquals(wechatIdentity, tracker.current())
        }
    }

    @Test
    fun `known overlay and IME events are rejected without pending publication`() {
        listOf(
            ForegroundWindow(
                id = 88,
                type = ForegroundWindowType.OTHER,
                isActive = true,
                isFocused = true,
            ),
            ForegroundWindow(
                id = 99,
                type = ForegroundWindowType.INPUT_METHOD,
                isActive = true,
                isFocused = true,
            ),
        ).forEach { nonApplication ->
            val focusedWeChat = wechat.copy(isActive = false, isFocused = true)
            val windows = listOf(nonApplication, focusedWeChat)
            val tracker = trackerAtWeChat(listOf(wechat))

            assertFalse(tracker.onWindowStateChanged(
                eventWindowId = nonApplication.id,
                packageName = "ignored.package",
                activityName = "ignored.Activity",
                windows = windows,
            ))
            assertFalse(tracker.onWindowsChanged(windows))
            assertEquals(
                wechatIdentity,
                tracker.current(),
            )

            // 已消费的候选不能因相同 windowId 后续复用为应用窗口而发布。
            assertFalse(tracker.onWindowsChanged(listOf(
                nonApplication.copy(type = ForegroundWindowType.APPLICATION),
            )))
            // 已明确归属为非应用窗口的事件也不能被暂存后借 windowId 复用发布。
            assertFalse(tracker.onWindowStateChanged(
                eventWindowId = nonApplication.id,
                packageName = "ignored.package",
                activityName = "ignored.Activity",
                windows = windows,
            ))
            assertFalse(tracker.onWindowsChanged(listOf(
                nonApplication.copy(type = ForegroundWindowType.APPLICATION),
            )))
            assertEquals(
                wechatIdentity,
                tracker.current(),
            )
        }
    }

    @Test
    fun `active application takes priority over focused application`() {
        val tracker = ForegroundWindowTracker()
        val focused = wechat.copy(isActive = false, isFocused = true)
        val active = ForegroundWindow(
            id = 111,
            type = ForegroundWindowType.APPLICATION,
            isActive = true,
        )
        val windows = listOf(focused, active)

        assertFalse(tracker.onWindowStateChanged(
            eventWindowId = focused.id,
            packageName = "com.tencent.mm",
            activityName = "com.tencent.mm.ui.LauncherUI",
            windows = windows,
        ))
        assertTrue(tracker.onWindowStateChanged(
            eventWindowId = active.id,
            packageName = "com.android.settings",
            activityName = "com.android.settings.Settings",
            windows = windows,
        ))
        assertEquals(
            ForegroundIdentity.Known(
                active.id,
                "com.android.settings",
                "com.android.settings.Settings",
            ),
            tracker.current(),
        )
    }

    @Test
    fun `known inactive application event is never published after it becomes active`() {
        val tracker = trackerAtWeChat(listOf(wechat))
        val inactive = ForegroundWindow(
            id = 122,
            type = ForegroundWindowType.APPLICATION,
        )

        assertFalse(tracker.onWindowStateChanged(
            eventWindowId = inactive.id,
            packageName = "com.android.settings",
            activityName = "com.android.settings.Settings",
            windows = listOf(wechat, inactive),
        ))
        assertFalse(tracker.onWindowsChanged(listOf(
            wechat.copy(isActive = false, isFocused = false),
            inactive.copy(isActive = true),
        )))
        assertEquals(wechatIdentity, tracker.current())
    }

    @Test
    fun `late windows list discards candidate when id belongs to overlay or IME`() {
        listOf(ForegroundWindowType.OTHER, ForegroundWindowType.INPUT_METHOD).forEach { type ->
            val tracker = ForegroundWindowTracker()
            val delayedWindow = ForegroundWindow(
                id = if (type == ForegroundWindowType.OTHER) 133 else 144,
                type = type,
                isActive = true,
                isFocused = true,
            )

            assertFalse(tracker.onWindowStateChanged(
                eventWindowId = delayedWindow.id,
                packageName = "ignored.package",
                activityName = "ignored.Activity",
                windows = emptyList(),
            ))
            assertFalse(tracker.onWindowsChanged(listOf(delayedWindow)))
            assertEquals(ForegroundIdentity.Unknown, tracker.current())
            assertFalse(tracker.onWindowsChanged(listOf(
                delayedWindow.copy(type = ForegroundWindowType.APPLICATION),
            )))
            assertEquals(ForegroundIdentity.Unknown, tracker.current())
        }
    }

    @Test
    fun `pending id is removed when later identified as non selected window`() {
        listOf(
            ForegroundWindow(id = 211, type = ForegroundWindowType.OTHER, isActive = true),
            ForegroundWindow(id = 222, type = ForegroundWindowType.INPUT_METHOD, isFocused = true),
            ForegroundWindow(id = 233, type = ForegroundWindowType.APPLICATION),
        ).forEach { identified ->
            val tracker = ForegroundWindowTracker()
            assertFalse(tracker.onWindowStateChanged(
                eventWindowId = identified.id,
                packageName = "stale.package",
                activityName = "stale.Activity",
                windows = emptyList(),
            ))
            assertFalse(tracker.onWindowStateChanged(
                eventWindowId = identified.id,
                packageName = "stale.package",
                activityName = "stale.Activity",
                windows = listOf(identified),
            ))

            val reused = identified.copy(
                type = ForegroundWindowType.APPLICATION,
                isActive = true,
                isFocused = true,
            )
            assertFalse(tracker.onWindowsChanged(listOf(reused)))
            assertFalse(tracker.onWindowsChanged(listOf(reused)))
            assertEquals(ForegroundIdentity.Unknown, tracker.current())
        }
    }

    @Test
    fun `removing stale id does not clear another real application candidate`() {
        val tracker = ForegroundWindowTracker()
        val stale = ForegroundWindow(id = 244, type = ForegroundWindowType.OTHER, isActive = true)

        tracker.onWindowStateChanged(
            eventWindowId = wechat.id,
            packageName = "com.tencent.mm",
            activityName = "com.tencent.mm.ui.LauncherUI",
            windows = emptyList(),
        )
        tracker.onWindowStateChanged(
            eventWindowId = stale.id,
            packageName = "stale.package",
            activityName = "stale.Activity",
            windows = emptyList(),
        )
        assertFalse(tracker.onWindowStateChanged(
            eventWindowId = stale.id,
            packageName = "stale.package",
            activityName = "stale.Activity",
            windows = listOf(stale, wechat.copy(isActive = false, isFocused = true)),
        ))

        assertTrue(tracker.onWindowsChanged(listOf(wechat, stale)))
        assertEquals(wechatIdentity, tracker.current())
        assertFalse(tracker.onWindowsChanged(listOf(
            stale.copy(type = ForegroundWindowType.APPLICATION, isActive = true),
        )))
        assertEquals(wechatIdentity, tracker.current())
    }

    @Test
    fun `missing package removes only the pending candidate with the same id`() {
        val tracker = ForegroundWindowTracker()
        val staleId = 255

        tracker.onWindowStateChanged(
            eventWindowId = wechat.id,
            packageName = "com.tencent.mm",
            activityName = "com.tencent.mm.ui.LauncherUI",
            windows = emptyList(),
        )
        tracker.onWindowStateChanged(
            eventWindowId = staleId,
            packageName = "stale.package",
            activityName = "stale.Activity",
            windows = emptyList(),
        )
        assertFalse(tracker.onWindowStateChanged(
            eventWindowId = staleId,
            packageName = null,
            activityName = null,
            windows = emptyList(),
        ))

        assertTrue(tracker.onWindowsChanged(listOf(wechat)))
        assertEquals(wechatIdentity, tracker.current())
        assertFalse(tracker.onWindowsChanged(listOf(
            ForegroundWindow(staleId, ForegroundWindowType.APPLICATION, isActive = true),
        )))
    }

    @Test
    fun `resolved foreground is unknown when selected application id differs from tracked window`() {
        val resolved = resolveForeground(
            identity = wechatIdentity,
            applicationWindowId = 155,
            applicationWindowPackageName = "com.android.settings",
        )

        assertEquals(
            ResolvedForeground(
                known = false,
                packageName = "com.android.settings",
                activityName = "",
                reason = ForegroundUnknownReason.WINDOW_ID_MISMATCH,
            ),
            resolved,
        )
        assertEquals(
            ResolvedForeground(
                known = false,
                packageName = "",
                activityName = "",
                reason = ForegroundUnknownReason.IDENTITY_UNSET,
            ),
            resolveForeground(
                identity = ForegroundIdentity.Unknown,
                applicationWindowId = 166,
                applicationWindowPackageName = null,
            ),
        )
    }

    @Test
    fun `unknown reason distinguishes missing application window from stale identity`() {
        assertEquals(
            ForegroundUnknownReason.NO_APPLICATION_WINDOW,
            resolveForeground(
                identity = wechatIdentity,
                applicationWindowId = null,
                applicationWindowPackageName = null,
            ).reason,
        )
        assertEquals(
            ForegroundUnknownReason.NO_APPLICATION_WINDOW,
            resolveForeground(
                identity = ForegroundIdentity.Unknown,
                applicationWindowId = null,
                applicationWindowPackageName = null,
            ).reason,
        )
        assertEquals(
            ForegroundUnknownReason.NONE,
            resolveForeground(
                identity = wechatIdentity,
                applicationWindowId = wechat.id,
                applicationWindowPackageName = null,
            ).reason,
        )
    }

    @Test
    fun `recent events record every decision with the window list it saw`() {
        var now = 1_000L
        val tracker = ForegroundWindowTracker(clock = { now })
        val overlay = ForegroundWindow(id = 266, type = ForegroundWindowType.OTHER, isFocused = true)

        tracker.onWindowStateChanged(
            eventWindowId = wechat.id,
            packageName = "com.tencent.mm",
            activityName = "com.tencent.mm.ui.LauncherUI",
            windows = listOf(wechat),
        )
        now = 1_200L
        tracker.onWindowStateChanged(
            eventWindowId = overlay.id,
            packageName = "dev.magina.gateway",
            activityName = "android.widget.FrameLayout",
            windows = listOf(wechat, overlay),
        )
        now = 1_300L
        tracker.onWindowStateChanged(
            eventWindowId = 277,
            packageName = null,
            activityName = null,
            windows = listOf(wechat),
        )
        now = 1_400L
        tracker.onWindowsChanged(listOf(wechat))

        val events = tracker.recentEvents()
        assertEquals(
            listOf(
                ForegroundEventDecision.ACCEPTED,
                ForegroundEventDecision.DROPPED_NOT_SELECTED,
                ForegroundEventDecision.DROPPED_NO_PACKAGE,
                ForegroundEventDecision.DROPPED_NO_CANDIDATE,
            ),
            events.map { it.decision },
        )
        assertEquals(listOf(1L, 2L, 3L, 4L), events.map { it.seq })
        assertEquals(listOf(1_000L, 1_200L, 1_300L, 1_400L), events.map { it.atMillis })
        assertEquals("com.tencent.mm", events.first().packageName)
        assertEquals(listOf(wechat, overlay), events[1].windows)
        assertEquals(wechat.id, events[1].selectedApplicationWindowId)
    }

    @Test
    fun `recent events keep the newest entries within a bounded ring`() {
        val tracker = ForegroundWindowTracker(clock = { 0L })
        repeat(40) {
            tracker.onWindowStateChanged(
                eventWindowId = wechat.id,
                packageName = "com.tencent.mm",
                activityName = "com.tencent.mm.ui.LauncherUI",
                windows = listOf(wechat),
            )
        }

        val events = tracker.recentEvents()
        assertTrue("ring should stay bounded, was ${events.size}", events.size in 1..24)
        assertEquals(40L, events.last().seq)
        assertEquals(40L - events.size + 1, events.first().seq)
    }

    @Test
    fun `pending candidate published by windows change is recorded as published`() {
        val tracker = ForegroundWindowTracker(clock = { 0L })

        tracker.onWindowStateChanged(
            eventWindowId = wechat.id,
            packageName = "com.tencent.mm",
            activityName = "com.tencent.mm.ui.LauncherUI",
            windows = emptyList(),
        )
        tracker.onWindowsChanged(listOf(wechat))

        assertEquals(
            listOf(ForegroundEventDecision.PENDING, ForegroundEventDecision.PUBLISHED_PENDING),
            tracker.recentEvents().map { it.decision },
        )
        assertEquals("com.tencent.mm", tracker.recentEvents().last().packageName)
    }

    @Test
    fun `resolved foreground stays known while overlay leaves application window selected`() {
        val resolved = resolveForeground(
            identity = wechatIdentity,
            applicationWindowId = wechat.id,
            applicationWindowPackageName = null,
        )

        assertEquals(
            ResolvedForeground(
                known = true,
                packageName = "com.tencent.mm",
                activityName = "com.tencent.mm.ui.LauncherUI",
            ),
            resolved,
        )
    }

    private fun trackerAtWeChat(windows: List<ForegroundWindow>): ForegroundWindowTracker =
        ForegroundWindowTracker().also { tracker ->
            tracker.onWindowStateChanged(
                eventWindowId = wechat.id,
                packageName = "com.tencent.mm",
                activityName = "com.tencent.mm.ui.LauncherUI",
                windows = windows,
            )
        }
}
