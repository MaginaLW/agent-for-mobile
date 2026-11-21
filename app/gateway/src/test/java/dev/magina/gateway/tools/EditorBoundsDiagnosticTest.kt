package dev.magina.gateway.tools

import android.text.InputType
import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import dev.magina.gateway.ime.ImeEditorContract
import dev.magina.gateway.ime.ImeSessionIdentity
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.util.concurrent.CompletableFuture
import java.util.concurrent.ExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException

class EditorBoundsDiagnosticTest {

    private val pkg = "com.tencent.mm"
    private val sessionId = "ime|0123456789abcdef01234567"
    private val fieldId = 0x7f090042
    private val otherFieldId = 0x7f090043
    private val fieldName = "$pkg:id/chat_input"
    private val otherFieldName = "$pkg:id/other_input"
    private val windowBounds = IntBounds(960, 0, 2400, 1600)
    private val editorBounds = IntBounds(1040, 1420, 2120, 1540)
    private val editorFloatBounds = FloatBounds(1040f, 1420f, 2120f, 1540f)

    private class FakeNode(
        val id: String,
        override var isFocused: Boolean = true,
        override var isVisibleToUser: Boolean = true,
        override var windowId: Int = 7,
        override var packageName: String? = "com.tencent.mm",
        override var isPassword: Boolean = false,
        override var isAccessibilityDataSensitive: Boolean = false,
        override var viewIdResourceName: String? = "com.tencent.mm:id/chat_input",
        override var isEditable: Boolean = true,
        var refreshResult: Boolean = true,
        var bounds: IntBounds = IntBounds(1040, 1420, 2120, 1540),
        var onRefresh: ((FakeNode) -> Unit)? = null,
    ) : EditorFocusNode {
        override fun refresh(): Boolean {
            onRefresh?.invoke(this)
            return refreshResult
        }

        override fun boundsInScreen(): IntBounds = bounds

        /** 模拟真机跨次 Binder 返回不同实例但同一节点身份。 */
        fun cloneInstance(): FakeNode = FakeNode(
            id = id,
            isFocused = isFocused,
            isVisibleToUser = isVisibleToUser,
            windowId = windowId,
            packageName = packageName,
            isPassword = isPassword,
            isAccessibilityDataSensitive = isAccessibilityDataSensitive,
            viewIdResourceName = viewIdResourceName,
            isEditable = isEditable,
            refreshResult = refreshResult,
            bounds = bounds,
            onRefresh = onRefresh,
        )

        override fun equals(other: Any?): Boolean = other is FakeNode && id == other.id
        override fun hashCode(): Int = id.hashCode()
    }

    private data class FakeWindow(
        override val id: Int = 7,
        override val isApplicationType: Boolean = true,
        override val isActive: Boolean = true,
        override val isFocused: Boolean = true,
        val bounds: IntBounds = IntBounds(960, 0, 2400, 1600),
    ) : EditorFocusWindow {
        override fun boundsInScreen(): IntBounds = bounds
    }

    private class PhaseSnapshot(
        var clearCache: Boolean = true,
        var hasRoot: Boolean = true,
        var rootPackage: String? = "com.tencent.mm",
        var window: FakeWindow? = FakeWindow(),
        var serviceFocus: FakeNode? = null,
        var rootFocus: FakeNode? = null,
        var firstLookup: ((String) -> List<FakeNode>)? = null,
        var secondLookup: ((String) -> List<FakeNode>)? = null,
        var defaultNodesById: Map<String, List<FakeNode>> = emptyMap(),
        var cloneNodes: Boolean = true,
    ) {
        var rootFocusCalls: Int = 0
        var viewIdLookupCalls: Int = 0

        fun toRoot(): EditorFocusRoot? {
            if (!hasRoot) return null
            return object : EditorFocusRoot {
                override val packageName: String? get() = rootPackage
                override fun window(): EditorFocusWindow? = window
                override fun findNodesByViewId(viewId: String): List<EditorFocusNode> {
                    val call = ++viewIdLookupCalls
                    val nodes = when {
                        call == 1 && firstLookup != null -> firstLookup!!.invoke(viewId)
                        call >= 2 && secondLookup != null -> secondLookup!!.invoke(viewId)
                        else -> defaultNodesById[viewId].orEmpty()
                    }
                    return if (cloneNodes) nodes.map { it.cloneInstance() } else nodes
                }

                override fun findInputFocus(): EditorFocusNode? {
                    rootFocusCalls++
                    return if (cloneNodes) rootFocus?.cloneInstance() else rootFocus
                }
            }
        }
    }

    private class FakeRequest(
        private val onAwait: (Long) -> EditorBoundsMeasurement?,
    ) : EditorBoundsRequest {
        var cancelled: Boolean = false
            private set

        override fun await(timeoutMs: Long): EditorBoundsMeasurement? = onAwait(timeoutMs)
        override fun cancel() {
            cancelled = true
        }
    }

    private inner class FakeEnv(
        override var sdkInt: Int = 34,
        var session: ImeSessionIdentity? = ImeSessionIdentity(sessionId, pkg, connected = true),
        var contract: ImeEditorContract? = ImeEditorContract(InputType.TYPE_CLASS_TEXT, 0, 0, null, fieldId = fieldId),
        var foregroundPackage: String = pkg,
        var gatewayImeSelected: Boolean = true,
        var blocked: Boolean = false,
        var onMainThread: Boolean = false,
        val resources: MutableMap<Int, ResourceNameResult> = mutableMapOf(
            fieldId to ResourceNameResult.Found(fieldName),
            otherFieldId to ResourceNameResult.Found(otherFieldName),
        ),
        var beforePhase: PhaseSnapshot = PhaseSnapshot(),
        var afterPhase: PhaseSnapshot = PhaseSnapshot(),
        var requestFactory: (FakeEnv, ImeSessionIdentity) -> EditorBoundsRequest = { _, _ ->
            FakeRequest { EditorBoundsMeasurement(fieldId, editorFloatBounds) }
        },
        var onSampleRequest: ((FakeEnv) -> Unit)? = null,
        var securityFailureAt: String? = null,
    ) : EditorBoundsEnvironment {
        var clearCacheCalls: Int = 0
        var imeRequestCalls: Int = 0
        var editorContractCalls: Int = 0
        private var currentPhaseIndex: Int = 0

        private fun phase(): PhaseSnapshot = if (currentPhaseIndex <= 1) beforePhase else afterPhase

        override fun session(): ImeSessionIdentity? = session
        override fun editorContract(): ImeEditorContract? {
            editorContractCalls++
            return contract
        }
        override fun foregroundPackage(): String = foregroundPackage
        override fun ensurePackageAllowed(pkg: String) {
            if (blocked) throw GatewayError(ErrorCode.E_BLOCKED, "blocked")
        }

        override fun checkNotMainThread() {
            check(!onMainThread) { "main thread" }
        }

        override fun isGatewayImeSelected(): Boolean {
            if (securityFailureAt == "selected_ime") throw SecurityException("denied")
            return gatewayImeSelected
        }

        override fun clearCache(): Boolean {
            currentPhaseIndex++
            clearCacheCalls++
            if (securityFailureAt == "clear_cache") throw SecurityException("denied")
            return phase().clearCache
        }

        override fun activeRoot(): EditorFocusRoot? = phase().toRoot()
        override fun serviceFocus(): EditorFocusNode? =
            phase().let { if (it.cloneNodes) it.serviceFocus?.cloneInstance() else it.serviceFocus }

        override fun resourceName(pkg: String, resId: Int): ResourceNameResult {
            if (securityFailureAt == "resource_name") throw SecurityException("denied")
            return resources[resId] ?: ResourceNameResult.Missing
        }

        override fun requestEditorBounds(session: ImeSessionIdentity): EditorBoundsRequest {
            imeRequestCalls++
            onSampleRequest?.invoke(this)
            return requestFactory(this, session)
        }
    }

    private fun unfocusedWindowFieldEnv(
        editable: Boolean = true,
        beforeNode: FakeNode = FakeNode(id = "n1", isFocused = false, isEditable = editable),
        afterNode: FakeNode = beforeNode.cloneInstance(),
        beforeRootFocus: FakeNode? = null,
        afterRootFocus: FakeNode? = null,
    ): FakeEnv = FakeEnv(
        beforePhase = PhaseSnapshot(
            serviceFocus = null,
            rootFocus = beforeRootFocus,
            defaultNodesById = mapOf(fieldName to listOf(beforeNode)),
        ),
        afterPhase = PhaseSnapshot(
            serviceFocus = null,
            rootFocus = afterRootFocus,
            defaultNodesById = mapOf(fieldName to listOf(afterNode)),
        ),
    )

    private fun unfocusedServiceEnv(
        editable: Boolean = true,
        beforeNode: FakeNode = FakeNode(id = "n1", isFocused = false, isEditable = editable),
        afterNode: FakeNode = beforeNode.cloneInstance(),
        beforeRootFocus: FakeNode? = beforeNode,
        afterRootFocus: FakeNode? = afterNode,
    ): FakeEnv = FakeEnv(
        beforePhase = PhaseSnapshot(
            serviceFocus = beforeNode,
            rootFocus = beforeRootFocus,
            defaultNodesById = mapOf(fieldName to listOf(beforeNode)),
        ),
        afterPhase = PhaseSnapshot(
            serviceFocus = afterNode,
            rootFocus = afterRootFocus,
            defaultNodesById = mapOf(fieldName to listOf(afterNode)),
        ),
    )

    private fun focusedServiceEnv(
        editable: Boolean = true,
        beforeNode: FakeNode = FakeNode(id = "n1", isFocused = true, isEditable = editable),
        afterNode: FakeNode = beforeNode.cloneInstance(),
    ): FakeEnv = FakeEnv(
        beforePhase = PhaseSnapshot(
            serviceFocus = beforeNode,
            rootFocus = beforeNode,
            defaultNodesById = mapOf(fieldName to listOf(beforeNode)),
        ),
        afterPhase = PhaseSnapshot(
            serviceFocus = afterNode,
            rootFocus = afterNode,
            defaultNodesById = mapOf(fieldName to listOf(afterNode)),
        ),
    )

    private fun assertFailure(reply: JSONObject, expectedReason: String) {
        assertTrue(reply.has("ime_editor_bounds") && reply.isNull("ime_editor_bounds"))
        assertEquals(expectedReason, reply.getString("ime_editor_bounds_reason"))
        assertFalse(reply.has("ime_editor_focus_phase"))
        assertFalse(reply.has("ime_editor_focus_check"))
        assertFalse(reply.has("window_field_phase"))
        assertFalse(reply.has("node_focused"))
    }

    private fun assertFocusUnavailable(reply: JSONObject, expectedPhase: String, expectedCheck: String) {
        assertTrue(reply.has("ime_editor_bounds") && reply.isNull("ime_editor_bounds"))
        assertEquals("focus_unavailable", reply.getString("ime_editor_bounds_reason"))
        assertEquals(expectedPhase, reply.getString("ime_editor_focus_phase"))
        assertEquals(expectedCheck, reply.getString("ime_editor_focus_check"))
        assertFalse(reply.has("window_field_phase"))
        assertFalse(reply.has("node_focused"))
    }

    // ---- 正例与回执契约 ----

    @Test
    fun `focused service focus succeeds without editorContract window_field_phase or node_focused`() {
        val contracts = listOf(
            ImeEditorContract(InputType.TYPE_CLASS_TEXT, 0, 0, null, fieldId = fieldId),
            null,
            ImeEditorContract(InputType.TYPE_CLASS_TEXT, 0, 0, null, fieldId = 0),
        )
        for (contract in contracts) {
            val env = focusedServiceEnv(editable = false).apply { this.contract = contract }
            val state = JSONObject().put("visible", true).put("height_px", 420)
            val reply = readEditorBounds(env, state)

            assertTrue(reply.getBoolean("visible"))
            assertEquals(420, reply.getInt("height_px"))
            assertFalse(reply.has("ime_editor_bounds_reason"))
            assertFalse(reply.has("ime_editor_focus_phase"))
            assertFalse(reply.has("ime_editor_focus_check"))
            assertFalse(reply.has("window_field_phase"))
            assertFalse(reply.has("node_focused"))

            val bounds = reply.getJSONObject("ime_editor_bounds")
            assertEquals(7, bounds.getInt("window_id"))
            assertEquals(sessionId, bounds.getString("session_id"))
            assertFalse(bounds.getBoolean("editable"))
            assertEquals(editorBounds.left, bounds.getInt("left"))
            assertEquals(editorBounds.top, bounds.getInt("top"))
            assertEquals(editorBounds.right, bounds.getInt("right"))
            assertEquals(editorBounds.bottom, bounds.getInt("bottom"))
            assertFalse(bounds.has("window_field_phase"))
            assertFalse(bounds.has("node_focused"))
            assertEquals(0, env.editorContractCalls)
            assertEquals(1, env.imeRequestCalls)
        }
    }

    @Test
    fun `focused window field fallback preserves window_field_phase values and omits node_focused`() {
        val node = FakeNode(id = "n1", isFocused = true)
        val cases = listOf(
            Triple(null, node, "before_sample"),
            Triple(node, null, "after_sample"),
            Triple(null, null, "both"),
        )
        for ((beforeServiceFocus, afterServiceFocus, expectedPhase) in cases) {
            val env = FakeEnv(
                beforePhase = PhaseSnapshot(
                    serviceFocus = beforeServiceFocus,
                    rootFocus = if (beforeServiceFocus != null) node else null,
                    defaultNodesById = mapOf(fieldName to listOf(node)),
                ),
                afterPhase = PhaseSnapshot(
                    serviceFocus = afterServiceFocus,
                    rootFocus = node,
                    defaultNodesById = mapOf(fieldName to listOf(node)),
                ),
            )
            val reply = readEditorBounds(env, JSONObject())
            assertFalse(reply.has("ime_editor_bounds_reason"))
            assertFalse(reply.has("window_field_phase"))
            assertFalse(reply.has("node_focused"))
            val bounds = reply.getJSONObject("ime_editor_bounds")
            assertEquals(expectedPhase, bounds.getString("window_field_phase"))
            assertFalse(bounds.has("node_focused"))
        }
    }

    @Test
    fun `unfocused service focus with matching rootFocus and editorContract succeeds without window_field_phase`() {
        for (editable in listOf(true, false)) {
            val env = unfocusedServiceEnv(editable = editable)
            val reply = readEditorBounds(env, JSONObject().put("visible", true))

            assertTrue(reply.getBoolean("visible"))
            assertFalse(reply.has("ime_editor_bounds_reason"))
            assertFalse(reply.has("ime_editor_focus_phase"))
            assertFalse(reply.has("ime_editor_focus_check"))
            assertFalse(reply.has("window_field_phase"))
            assertFalse(reply.has("node_focused"))

            val bounds = reply.getJSONObject("ime_editor_bounds")
            assertEquals(7, bounds.getInt("window_id"))
            assertEquals(sessionId, bounds.getString("session_id"))
            assertEquals(editable, bounds.getBoolean("editable"))
            assertEquals(editorBounds.left, bounds.getInt("left"))
            assertEquals(editorBounds.top, bounds.getInt("top"))
            assertEquals(editorBounds.right, bounds.getInt("right"))
            assertEquals(editorBounds.bottom, bounds.getInt("bottom"))
            assertFalse(bounds.has("window_field_phase"))
            assertFalse(bounds.getBoolean("node_focused"))
            assertEquals(1, env.beforePhase.rootFocusCalls)
            assertEquals(1, env.afterPhase.rootFocusCalls)
            assertEquals(2, env.editorContractCalls)
            assertEquals(1, env.imeRequestCalls)
        }
    }

    @Test
    fun `unfocused window field node with matching rootFocus succeeds with window_field_phase both and node_focused false`() {
        for (editable in listOf(true, false)) {
            val node = FakeNode(id = "n1", isFocused = false, isEditable = editable)
            val env = unfocusedWindowFieldEnv(
                editable = editable,
                beforeNode = node,
                afterNode = node.cloneInstance(),
                beforeRootFocus = node,
                afterRootFocus = node,
            )
            val reply = readEditorBounds(env, JSONObject().put("visible", true))

            assertTrue(reply.getBoolean("visible"))
            assertFalse(reply.has("ime_editor_bounds_reason"))
            assertFalse(reply.has("ime_editor_focus_phase"))
            assertFalse(reply.has("ime_editor_focus_check"))
            assertFalse(reply.has("window_field_phase"))
            assertFalse(reply.has("node_focused"))

            val bounds = reply.getJSONObject("ime_editor_bounds")
            assertEquals(7, bounds.getInt("window_id"))
            assertEquals(sessionId, bounds.getString("session_id"))
            assertEquals(editable, bounds.getBoolean("editable"))
            assertEquals(editorBounds.left, bounds.getInt("left"))
            assertEquals(editorBounds.top, bounds.getInt("top"))
            assertEquals(editorBounds.right, bounds.getInt("right"))
            assertEquals(editorBounds.bottom, bounds.getInt("bottom"))
            assertEquals("both", bounds.getString("window_field_phase"))
            assertFalse(bounds.getBoolean("node_focused"))
            assertEquals(1, env.beforePhase.rootFocusCalls)
            assertEquals(1, env.afterPhase.rootFocusCalls)
            assertEquals(2, env.editorContractCalls)
            assertEquals(1, env.imeRequestCalls)
        }
    }

    @Test
    fun `unfocused window field node with null rootFocus succeeds and marks node_focused false`() {
        for (editable in listOf(true, false)) {
            val env = unfocusedWindowFieldEnv(editable = editable)
            val reply = readEditorBounds(env, JSONObject().put("visible", true))

            assertTrue(reply.getBoolean("visible"))
            assertFalse(reply.has("ime_editor_bounds_reason"))
            assertFalse(reply.has("ime_editor_focus_phase"))
            assertFalse(reply.has("ime_editor_focus_check"))
            assertFalse(reply.has("window_field_phase"))
            assertFalse(reply.has("node_focused"))

            val bounds = reply.getJSONObject("ime_editor_bounds")
            assertEquals(7, bounds.getInt("window_id"))
            assertEquals(sessionId, bounds.getString("session_id"))
            assertEquals(editable, bounds.getBoolean("editable"))
            assertEquals(editorBounds.left, bounds.getInt("left"))
            assertEquals(editorBounds.top, bounds.getInt("top"))
            assertEquals(editorBounds.right, bounds.getInt("right"))
            assertEquals(editorBounds.bottom, bounds.getInt("bottom"))
            assertEquals("both", bounds.getString("window_field_phase"))
            assertFalse(bounds.getBoolean("node_focused"))
            assertEquals(1, env.beforePhase.rootFocusCalls)
            assertEquals(1, env.afterPhase.rootFocusCalls)
            assertEquals(2, env.editorContractCalls)
            assertEquals(1, env.imeRequestCalls)
        }
    }

    @Test
    fun `unfocused mixed service focus and window field phases emit window_field_phase and node_focused false`() {
        val node = FakeNode(id = "n1", isFocused = false)
        for (windowFieldRootFocus in listOf<FakeNode?>(null, node)) {
            val afterFieldEnv = FakeEnv(
                beforePhase = PhaseSnapshot(
                    serviceFocus = node,
                    rootFocus = node,
                    defaultNodesById = mapOf(fieldName to listOf(node)),
                ),
                afterPhase = PhaseSnapshot(
                    serviceFocus = null,
                    rootFocus = windowFieldRootFocus,
                    defaultNodesById = mapOf(fieldName to listOf(node)),
                ),
            )
            val afterFieldReply = readEditorBounds(afterFieldEnv, JSONObject())
            assertFalse(afterFieldReply.has("ime_editor_bounds_reason"))
            assertFalse(afterFieldReply.has("window_field_phase"))
            assertFalse(afterFieldReply.has("node_focused"))
            val afterFieldBounds = afterFieldReply.getJSONObject("ime_editor_bounds")
            assertEquals("after_sample", afterFieldBounds.getString("window_field_phase"))
            assertFalse(afterFieldBounds.getBoolean("node_focused"))
            assertEquals(2, afterFieldEnv.editorContractCalls)

            val beforeFieldEnv = FakeEnv(
                beforePhase = PhaseSnapshot(
                    serviceFocus = null,
                    rootFocus = windowFieldRootFocus,
                    defaultNodesById = mapOf(fieldName to listOf(node)),
                ),
                afterPhase = PhaseSnapshot(
                    serviceFocus = node,
                    rootFocus = node,
                    defaultNodesById = mapOf(fieldName to listOf(node)),
                ),
            )
            val beforeFieldReply = readEditorBounds(beforeFieldEnv, JSONObject())
            assertFalse(beforeFieldReply.has("ime_editor_bounds_reason"))
            assertFalse(beforeFieldReply.has("window_field_phase"))
            assertFalse(beforeFieldReply.has("node_focused"))
            val beforeFieldBounds = beforeFieldReply.getJSONObject("ime_editor_bounds")
            assertEquals("before_sample", beforeFieldBounds.getString("window_field_phase"))
            assertFalse(beforeFieldBounds.getBoolean("node_focused"))
            assertEquals(2, beforeFieldEnv.editorContractCalls)
        }
    }

    // ---- serviceFocus != null 反例（聚焦与未聚焦） ----

    @Test
    fun `serviceFocus non-null focused still rejects null or mismatched rootFocus`() {
        val node = FakeNode(id = "n1", isFocused = true)
        val other = FakeNode(id = "other", isFocused = true)
        for (rootFocus in listOf<FakeNode?>(null, other)) {
            val env = FakeEnv(
                beforePhase = PhaseSnapshot(
                    serviceFocus = node,
                    rootFocus = rootFocus,
                    defaultNodesById = mapOf(fieldName to listOf(node)),
                ),
            )
            assertFocusUnavailable(readEditorBounds(env, JSONObject()), "before_sample", "root_focus_mismatch")
            assertEquals(0, env.editorContractCalls)
            assertEquals(0, env.imeRequestCalls)
        }
    }

    @Test
    fun `unfocused service focus rejects null or mismatched rootFocus in before and after phases`() {
        val node = FakeNode(id = "n1", isFocused = false)
        val other = FakeNode(id = "other", isFocused = true)
        for (badRootFocus in listOf<FakeNode?>(null, other)) {
            val beforeEnv = unfocusedServiceEnv(beforeNode = node, beforeRootFocus = badRootFocus)
            assertFocusUnavailable(readEditorBounds(beforeEnv, JSONObject()), "before_sample", "root_focus_mismatch")
            assertEquals(1, beforeEnv.beforePhase.rootFocusCalls)
            assertEquals(0, beforeEnv.editorContractCalls)
            assertEquals(0, beforeEnv.imeRequestCalls)

            val afterEnv = unfocusedServiceEnv(afterNode = node, afterRootFocus = badRootFocus)
            assertFocusUnavailable(readEditorBounds(afterEnv, JSONObject()), "after_sample", "root_focus_mismatch")
            assertEquals(1, afterEnv.afterPhase.rootFocusCalls)
            assertEquals(1, afterEnv.editorContractCalls)
            assertEquals(1, afterEnv.imeRequestCalls)
        }
    }

    @Test
    fun `unfocused service focus enforces refresh visibility window and package checks in order`() {
        val checks: List<Pair<String, (FakeNode) -> Unit>> = listOf(
            "node_refresh_failed" to { it.refreshResult = false },
            "node_not_visible" to { it.isVisibleToUser = false },
            "node_window_mismatch" to { it.windowId = 99 },
            "node_package_mismatch" to { it.packageName = "com.other.app" },
        )
        val other = FakeNode(id = "other", isFocused = true)
        for ((expectedCheck, mutate) in checks) {
            val badBefore = FakeNode(id = "n1", isFocused = false).apply(mutate)
            val beforeEnv = unfocusedServiceEnv(beforeNode = badBefore, beforeRootFocus = other).apply {
                contract = null
            }
            assertFocusUnavailable(readEditorBounds(beforeEnv, JSONObject()), "before_sample", expectedCheck)
            assertEquals(0, beforeEnv.beforePhase.rootFocusCalls)
            assertEquals(0, beforeEnv.editorContractCalls)
            assertEquals(0, beforeEnv.imeRequestCalls)

            val badAfter = FakeNode(id = "n1", isFocused = false).apply(mutate)
            val afterEnv = unfocusedServiceEnv(afterNode = badAfter, afterRootFocus = other)
            assertFocusUnavailable(readEditorBounds(afterEnv, JSONObject()), "after_sample", expectedCheck)
            assertEquals(0, afterEnv.afterPhase.rootFocusCalls)
            assertEquals(1, afterEnv.editorContractCalls)
            assertEquals(1, afterEnv.imeRequestCalls)
        }
    }

    @Test
    fun `unfocused service focus rejects password contracts and sensitive nodes before IME request`() {
        val passwordInputTypes = listOf(
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD,
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD,
            InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD,
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD or InputType.TYPE_TEXT_FLAG_MULTI_LINE,
        )
        for (inputType in passwordInputTypes) {
            val env = unfocusedServiceEnv()
            env.contract = ImeEditorContract(inputType, 0, 0, null, fieldId = fieldId)
            assertFailure(readEditorBounds(env, JSONObject()), "sensitive_field")
            assertEquals(1, env.editorContractCalls)
            assertEquals(0, env.imeRequestCalls)
        }

        val afterPasswordEnv = unfocusedServiceEnv()
        afterPasswordEnv.onSampleRequest = {
            it.contract = ImeEditorContract(
                InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD,
                0,
                0,
                null,
                fieldId = fieldId,
            )
        }
        assertFailure(readEditorBounds(afterPasswordEnv, JSONObject()), "sensitive_field")
        assertEquals(2, afterPasswordEnv.editorContractCalls)
        assertEquals(1, afterPasswordEnv.imeRequestCalls)

        val pwdNodeEnv = unfocusedServiceEnv(beforeNode = FakeNode(id = "n1", isFocused = false, isPassword = true)).apply {
            contract = null
        }
        assertFailure(readEditorBounds(pwdNodeEnv, JSONObject()), "sensitive_field")
        assertEquals(0, pwdNodeEnv.editorContractCalls)
        assertEquals(0, pwdNodeEnv.imeRequestCalls)

        val sensitiveNodeEnv = unfocusedServiceEnv(
            beforeNode = FakeNode(id = "n1", isFocused = false, isAccessibilityDataSensitive = true),
        ).apply {
            contract = null
        }
        assertFailure(readEditorBounds(sensitiveNodeEnv, JSONObject()), "sensitive_field")
        assertEquals(0, sensitiveNodeEnv.editorContractCalls)
        assertEquals(0, sensitiveNodeEnv.imeRequestCalls)
    }

    @Test
    fun `unfocused service focus rejects missing invalid or mismatched EditorInfo fieldId before IME request`() {
        val missingIdCases = listOf<FakeEnv.() -> Unit>(
            { contract = null },
            { contract = ImeEditorContract(InputType.TYPE_CLASS_TEXT, 0, 0, null, fieldId = 0) },
            { contract = ImeEditorContract(InputType.TYPE_CLASS_TEXT, 0, 0, null, fieldId = -1) },
            { resources[fieldId] = ResourceNameResult.Missing },
            { resources[fieldId] = ResourceNameResult.Found("$pkg:string/chat_input") },
            { resources[fieldId] = ResourceNameResult.Found("id/chat_input") },
        )
        for (mutate in missingIdCases) {
            val env = unfocusedServiceEnv().apply(mutate)
            assertFailure(readEditorBounds(env, JSONObject()), "missing_id")
            assertEquals(0, env.imeRequestCalls)
        }

        val blankNodeIdEnv = unfocusedServiceEnv(
            beforeNode = FakeNode(id = "n1", isFocused = false, viewIdResourceName = "   "),
        )
        assertFailure(readEditorBounds(blankNodeIdEnv, JSONObject()), "missing_id")
        assertEquals(0, blankNodeIdEnv.imeRequestCalls)

        val resUnavailableEnv = unfocusedServiceEnv().apply {
            resources[fieldId] = ResourceNameResult.ResourcesUnavailable
        }
        assertFailure(readEditorBounds(resUnavailableEnv, JSONObject()), "resources_unavailable")
        assertEquals(0, resUnavailableEnv.imeRequestCalls)

        val accessDeniedEnv = unfocusedServiceEnv().apply { securityFailureAt = "resource_name" }
        assertFailure(readEditorBounds(accessDeniedEnv, JSONObject()), "access_denied")
        assertEquals(0, accessDeniedEnv.imeRequestCalls)

        val contractMismatchEnv = unfocusedServiceEnv().apply {
            contract = ImeEditorContract(InputType.TYPE_CLASS_TEXT, 0, 0, null, fieldId = otherFieldId)
        }
        assertFailure(readEditorBounds(contractMismatchEnv, JSONObject()), "different_id")
        assertEquals(0, contractMismatchEnv.imeRequestCalls)

        val nodeMismatchEnv = unfocusedServiceEnv(
            beforeNode = FakeNode(id = "n1", isFocused = false, viewIdResourceName = otherFieldName),
        )
        assertFailure(readEditorBounds(nodeMismatchEnv, JSONObject()), "different_id")
        assertEquals(0, nodeMismatchEnv.imeRequestCalls)

        val imeMismatchEnv = unfocusedServiceEnv()
        imeMismatchEnv.requestFactory = { _, _ ->
            FakeRequest { EditorBoundsMeasurement(otherFieldId, editorFloatBounds) }
        }
        assertFailure(readEditorBounds(imeMismatchEnv, JSONObject()), "different_id")
        assertEquals(1, imeMismatchEnv.imeRequestCalls)
    }

    @Test
    fun `unfocused service focus rejects ambiguous ids invalid bounds float drift and request errors`() {
        val n1 = FakeNode(id = "n1", isFocused = false)
        val n2 = FakeNode(id = "n2", isFocused = false)

        for (lookupResult in listOf(listOf(n1, n2), listOf(n2), emptyList())) {
            val env = unfocusedServiceEnv(beforeNode = n1)
            env.beforePhase.defaultNodesById = mapOf(fieldName to lookupResult)
            assertFailure(readEditorBounds(env, JSONObject()), "ambiguous_id")
            assertEquals(0, env.imeRequestCalls)
        }

        val invalidBounds = listOf(
            IntBounds(1040, 1420, 1040, 1540),
            IntBounds(959, 1420, 2120, 1540),
            IntBounds(1040, 1420, 2401, 1540),
        )
        for (badBounds in invalidBounds) {
            val env = unfocusedServiceEnv(beforeNode = FakeNode(id = "n1", isFocused = false, bounds = badBounds))
            assertFailure(readEditorBounds(env, JSONObject()), "invalid_bounds")
            assertEquals(0, env.imeRequestCalls)
        }

        val emptyWindowEnv = unfocusedServiceEnv()
        emptyWindowEnv.beforePhase.window = FakeWindow(bounds = IntBounds(2400, 0, 960, 1600))
        assertFailure(readEditorBounds(emptyWindowEnv, JSONObject()), "invalid_bounds")
        assertEquals(0, emptyWindowEnv.imeRequestCalls)

        val mismatchedFloats = listOf(
            FloatBounds(1040f, 1420f, 2132f, 1540f),
            FloatBounds(1040.5f, 1420f, 2120f, 1540f),
            FloatBounds(1040f, 1420.25f, 2120f, 1540f),
            FloatBounds(1040f, 1420f, 2120.1f, 1540f),
            FloatBounds(1040f, 1420f, 2120f, 1539.9f),
            FloatBounds(Float.NaN, 1420f, 2120f, 1540f),
        )
        for (sampleBounds in mismatchedFloats) {
            val env = unfocusedServiceEnv()
            env.requestFactory = { _, _ -> FakeRequest { EditorBoundsMeasurement(fieldId, sampleBounds) } }
            assertFailure(readEditorBounds(env, JSONObject()), "different_bounds")
        }

        val nullSampleEnv = unfocusedServiceEnv()
        nullSampleEnv.requestFactory = { _, _ -> FakeRequest { null } }
        assertFailure(readEditorBounds(nullSampleEnv, JSONObject()), "no_ime_bounds")

        val timeoutReq = FakeRequest { throw TimeoutException("late") }
        val timeoutEnv = unfocusedServiceEnv()
        timeoutEnv.requestFactory = { _, _ -> timeoutReq }
        assertFailure(readEditorBounds(timeoutEnv, JSONObject()), "timeout")
        assertTrue(timeoutReq.cancelled)

        val interruptedReq = FakeRequest { throw InterruptedException("stop") }
        val interruptedEnv = unfocusedServiceEnv()
        interruptedEnv.requestFactory = { _, _ -> interruptedReq }
        try {
            assertFailure(readEditorBounds(interruptedEnv, JSONObject()), "interrupted")
            assertTrue(interruptedReq.cancelled)
            assertTrue(Thread.currentThread().isInterrupted)
        } finally {
            Thread.interrupted()
        }

        val failedEnv = unfocusedServiceEnv()
        failedEnv.requestFactory = { _, _ ->
            FakeRequest { throw ExecutionException(IllegalStateException("boom")) }
        }
        assertFailure(readEditorBounds(failedEnv, JSONObject()), "request_failed")
    }

    // ---- serviceFocus == null && !node.isFocused 全套反例 ----

    @Test
    fun `unfocused window field rejects when rootFocus points to another node`() {
        val node = FakeNode(id = "n1", isFocused = false)
        val other = FakeNode(id = "n2", isFocused = true)

        val beforeEnv = unfocusedWindowFieldEnv(beforeNode = node)
        beforeEnv.beforePhase.rootFocus = other
        assertFocusUnavailable(readEditorBounds(beforeEnv, JSONObject()), "before_sample", "root_focus_mismatch")
        assertEquals(0, beforeEnv.imeRequestCalls)
        assertEquals(1, beforeEnv.beforePhase.rootFocusCalls)

        val afterEnv = unfocusedWindowFieldEnv(beforeNode = node)
        afterEnv.afterPhase.rootFocus = other
        assertFocusUnavailable(readEditorBounds(afterEnv, JSONObject()), "after_sample", "root_focus_mismatch")
        assertEquals(1, afterEnv.imeRequestCalls)
        assertEquals(1, afterEnv.afterPhase.rootFocusCalls)
    }

    @Test
    fun `unfocused window field still enforces refresh visibility window and package checks`() {
        val checks: List<Pair<String, (FakeNode) -> Unit>> = listOf(
            "node_refresh_failed" to { it.refreshResult = false },
            "node_not_visible" to { it.isVisibleToUser = false },
            "node_window_mismatch" to { it.windowId = 99 },
            "node_package_mismatch" to { it.packageName = "com.other.app" },
        )
        for ((expectedCheck, mutate) in checks) {
            val badBefore = FakeNode(id = "n1", isFocused = false).apply(mutate)
            val beforeEnv = unfocusedWindowFieldEnv(beforeNode = badBefore)
            assertFocusUnavailable(readEditorBounds(beforeEnv, JSONObject()), "before_sample", expectedCheck)
            assertEquals(0, beforeEnv.imeRequestCalls)

            val badAfter = FakeNode(id = "n1", isFocused = false).apply(mutate)
            val afterEnv = unfocusedWindowFieldEnv(afterNode = badAfter)
            assertFocusUnavailable(readEditorBounds(afterEnv, JSONObject()), "after_sample", expectedCheck)
            assertEquals(1, afterEnv.imeRequestCalls)
        }
    }

    @Test
    fun `unfocused window field rejects password contracts and sensitive nodes`() {
        val passwordInputTypes = listOf(
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_PASSWORD,
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_VISIBLE_PASSWORD,
            InputType.TYPE_CLASS_TEXT or InputType.TYPE_TEXT_VARIATION_WEB_PASSWORD,
            InputType.TYPE_CLASS_NUMBER or InputType.TYPE_NUMBER_VARIATION_PASSWORD,
        )
        for (inputType in passwordInputTypes) {
            val env = unfocusedWindowFieldEnv()
            env.contract = ImeEditorContract(inputType, 0, 0, null, fieldId = fieldId)
            assertFailure(readEditorBounds(env, JSONObject()), "sensitive_field")
            assertEquals(0, env.imeRequestCalls)
        }

        val pwdNodeEnv = unfocusedWindowFieldEnv(beforeNode = FakeNode(id = "n1", isFocused = false, isPassword = true))
        assertFailure(readEditorBounds(pwdNodeEnv, JSONObject()), "sensitive_field")
        assertEquals(0, pwdNodeEnv.imeRequestCalls)

        val sensitiveNodeEnv = unfocusedWindowFieldEnv(
            beforeNode = FakeNode(id = "n1", isFocused = false, isAccessibilityDataSensitive = true),
        )
        assertFailure(readEditorBounds(sensitiveNodeEnv, JSONObject()), "sensitive_field")
        assertEquals(0, sensitiveNodeEnv.imeRequestCalls)
    }

    @Test
    fun `unfocused window field rejects ambiguous view ids on initial and secondary lookups`() {
        val n1 = FakeNode(id = "n1", isFocused = false)
        val n2 = FakeNode(id = "n2", isFocused = false)

        val firstAmbiguous = unfocusedWindowFieldEnv(beforeNode = n1)
        firstAmbiguous.beforePhase.firstLookup = { listOf(n1, n2) }
        assertFailure(readEditorBounds(firstAmbiguous, JSONObject()), "ambiguous_id")
        assertEquals(0, firstAmbiguous.imeRequestCalls)

        val secondAmbiguous = unfocusedWindowFieldEnv(beforeNode = n1)
        secondAmbiguous.beforePhase.firstLookup = { listOf(n1) }
        secondAmbiguous.beforePhase.secondLookup = { listOf(n1, n2) }
        assertFailure(readEditorBounds(secondAmbiguous, JSONObject()), "ambiguous_id")
        assertEquals(0, secondAmbiguous.imeRequestCalls)

        val secondSwapped = unfocusedWindowFieldEnv(beforeNode = n1)
        secondSwapped.beforePhase.firstLookup = { listOf(n1) }
        secondSwapped.beforePhase.secondLookup = { listOf(n2) }
        assertFailure(readEditorBounds(secondSwapped, JSONObject()), "ambiguous_id")
        assertEquals(0, secondSwapped.imeRequestCalls)

        val secondEmpty = unfocusedWindowFieldEnv(beforeNode = n1)
        secondEmpty.beforePhase.firstLookup = { listOf(n1) }
        secondEmpty.beforePhase.secondLookup = { emptyList() }
        assertFailure(readEditorBounds(secondEmpty, JSONObject()), "ambiguous_id")
        assertEquals(0, secondEmpty.imeRequestCalls)
    }

    @Test
    fun `unfocused window field rejects different resource id from node or ime sample`() {
        val renamedNode = FakeNode(id = "n1", isFocused = false, viewIdResourceName = otherFieldName)
        val nodeMismatchEnv = unfocusedWindowFieldEnv(beforeNode = renamedNode)
        assertFailure(readEditorBounds(nodeMismatchEnv, JSONObject()), "different_id")
        assertEquals(0, nodeMismatchEnv.imeRequestCalls)

        val imeMismatchEnv = unfocusedWindowFieldEnv()
        imeMismatchEnv.requestFactory = { _, _ ->
            FakeRequest { EditorBoundsMeasurement(otherFieldId, editorFloatBounds) }
        }
        assertFailure(readEditorBounds(imeMismatchEnv, JSONObject()), "different_id")
    }

    @Test
    fun `unfocused window field enforces pixel-exact float bounds matching`() {
        val mismatchedBounds = listOf(
            FloatBounds(1040f, 1420f, 2132f, 1540f),
            FloatBounds(1040.5f, 1420f, 2120f, 1540f),
            FloatBounds(1040f, 1420.25f, 2120f, 1540f),
            FloatBounds(1040f, 1420f, 2120.1f, 1540f),
            FloatBounds(1040f, 1420f, 2120f, 1539.9f),
            FloatBounds(Float.NaN, 1420f, 2120f, 1540f),
        )
        for (sampleBounds in mismatchedBounds) {
            val env = unfocusedWindowFieldEnv()
            env.requestFactory = { _, _ ->
                FakeRequest { EditorBoundsMeasurement(fieldId, sampleBounds) }
            }
            assertFailure(readEditorBounds(env, JSONObject()), "different_bounds")
        }
    }

    @Test
    fun `unfocused window field rejects empty outside or empty-window bounds`() {
        val invalidNodeBounds = listOf(
            IntBounds(1040, 1420, 1040, 1540),
            IntBounds(1040, 1420, 2120, 1420),
            IntBounds(2120, 1420, 1040, 1540),
            IntBounds(959, 1420, 2120, 1540),
            IntBounds(1040, -1, 2120, 1540),
            IntBounds(1040, 1420, 2401, 1540),
            IntBounds(1040, 1420, 2120, 1601),
        )
        for (badBounds in invalidNodeBounds) {
            val env = unfocusedWindowFieldEnv(
                beforeNode = FakeNode(id = "n1", isFocused = false, bounds = badBounds),
            )
            assertFailure(readEditorBounds(env, JSONObject()), "invalid_bounds")
            assertEquals(0, env.imeRequestCalls)
        }

        val emptyWindowEnv = unfocusedWindowFieldEnv()
        emptyWindowEnv.beforePhase.window = FakeWindow(bounds = IntBounds(2400, 0, 960, 1600))
        assertFailure(readEditorBounds(emptyWindowEnv, JSONObject()), "invalid_bounds")
        assertEquals(0, emptyWindowEnv.imeRequestCalls)
    }

    @Test
    fun `focus state flip between before and after sampling fails as context_changed`() {
        val unfocused = FakeNode(id = "n1", isFocused = false)
        val focused = FakeNode(id = "n1", isFocused = true)

        // false (window field) -> true (window field)
        val falseToTrueField = unfocusedWindowFieldEnv(beforeNode = unfocused, afterNode = focused)
        assertFailure(readEditorBounds(falseToTrueField, JSONObject()), "context_changed")

        // false (window field) -> true (serviceFocus)
        val falseToTrueService = FakeEnv(
            beforePhase = PhaseSnapshot(
                serviceFocus = null,
                rootFocus = null,
                defaultNodesById = mapOf(fieldName to listOf(unfocused)),
            ),
            afterPhase = PhaseSnapshot(
                serviceFocus = focused,
                rootFocus = focused,
                defaultNodesById = mapOf(fieldName to listOf(focused)),
            ),
        )
        assertFailure(readEditorBounds(falseToTrueService, JSONObject()), "context_changed")

        // true (window field) -> false (window field)
        val trueToFalseField = unfocusedWindowFieldEnv(beforeNode = focused, afterNode = unfocused)
        assertFailure(readEditorBounds(trueToFalseField, JSONObject()), "context_changed")

        // true (serviceFocus) -> false (window field)
        val trueToFalseService = FakeEnv(
            beforePhase = PhaseSnapshot(
                serviceFocus = focused,
                rootFocus = focused,
                defaultNodesById = mapOf(fieldName to listOf(focused)),
            ),
            afterPhase = PhaseSnapshot(
                serviceFocus = null,
                rootFocus = null,
                defaultNodesById = mapOf(fieldName to listOf(unfocused)),
            ),
        )
        assertFailure(readEditorBounds(trueToFalseService, JSONObject()), "context_changed")

        // false (serviceFocus) -> true (serviceFocus)
        val falseToTrueServiceBoth = unfocusedServiceEnv(beforeNode = unfocused, afterNode = focused)
        assertFailure(readEditorBounds(falseToTrueServiceBoth, JSONObject()), "context_changed")

        // true (serviceFocus) -> false (serviceFocus)
        val trueToFalseServiceBoth = unfocusedServiceEnv(beforeNode = focused, afterNode = unfocused)
        assertFailure(readEditorBounds(trueToFalseServiceBoth, JSONObject()), "context_changed")

        // false (serviceFocus) -> true (window field)
        val falseServiceToTrueField = FakeEnv(
            beforePhase = PhaseSnapshot(
                serviceFocus = unfocused,
                rootFocus = unfocused,
                defaultNodesById = mapOf(fieldName to listOf(unfocused)),
            ),
            afterPhase = PhaseSnapshot(
                serviceFocus = null,
                rootFocus = focused,
                defaultNodesById = mapOf(fieldName to listOf(focused)),
            ),
        )
        assertFailure(readEditorBounds(falseServiceToTrueField, JSONObject()), "context_changed")

        // true (window field) -> false (serviceFocus)
        val trueFieldToFalseService = FakeEnv(
            beforePhase = PhaseSnapshot(
                serviceFocus = null,
                rootFocus = null,
                defaultNodesById = mapOf(fieldName to listOf(focused)),
            ),
            afterPhase = PhaseSnapshot(
                serviceFocus = unfocused,
                rootFocus = unfocused,
                defaultNodesById = mapOf(fieldName to listOf(unfocused)),
            ),
        )
        assertFailure(readEditorBounds(trueFieldToFalseService, JSONObject()), "context_changed")

        // 同一底层节点对象在 after refresh 时原地翻转焦点（窗口字段与 serviceFocus 两条路径），也必须被 EditorFocus 快照拦截
        val sharedMutable = FakeNode(id = "n1", isFocused = false)
        var refreshCount = 0
        sharedMutable.onRefresh = { node ->
            refreshCount++
            if (refreshCount == 2) node.isFocused = true
        }
        val inPlaceFlip = FakeEnv(
            beforePhase = PhaseSnapshot(
                serviceFocus = null,
                rootFocus = null,
                defaultNodesById = mapOf(fieldName to listOf(sharedMutable)),
                cloneNodes = false,
            ),
            afterPhase = PhaseSnapshot(
                serviceFocus = null,
                rootFocus = null,
                defaultNodesById = mapOf(fieldName to listOf(sharedMutable)),
                cloneNodes = false,
            ),
        )
        assertFailure(readEditorBounds(inPlaceFlip, JSONObject()), "context_changed")
        assertEquals(2, refreshCount)
        assertTrue(sharedMutable.isFocused)

        val sharedServiceMutable = FakeNode(id = "n1", isFocused = false)
        var serviceRefreshCount = 0
        sharedServiceMutable.onRefresh = { node ->
            serviceRefreshCount++
            if (serviceRefreshCount == 2) node.isFocused = true
        }
        val serviceInPlaceFlip = FakeEnv(
            beforePhase = PhaseSnapshot(
                serviceFocus = sharedServiceMutable,
                rootFocus = sharedServiceMutable,
                defaultNodesById = mapOf(fieldName to listOf(sharedServiceMutable)),
                cloneNodes = false,
            ),
            afterPhase = PhaseSnapshot(
                serviceFocus = sharedServiceMutable,
                rootFocus = sharedServiceMutable,
                defaultNodesById = mapOf(fieldName to listOf(sharedServiceMutable)),
                cloneNodes = false,
            ),
        )
        assertFailure(readEditorBounds(serviceInPlaceFlip, JSONObject()), "context_changed")
        assertEquals(2, serviceRefreshCount)
        assertTrue(sharedServiceMutable.isFocused)
    }

    @Test
    fun `focused window field still rejects rootFocus pointing to another node`() {
        val node = FakeNode(id = "n1", isFocused = true)
        val other = FakeNode(id = "n2", isFocused = true)
        val env = FakeEnv(
            beforePhase = PhaseSnapshot(
                serviceFocus = null,
                rootFocus = other,
                defaultNodesById = mapOf(fieldName to listOf(node)),
            ),
        )
        assertFocusUnavailable(readEditorBounds(env, JSONObject()), "before_sample", "root_focus_mismatch")
        assertEquals(0, env.imeRequestCalls)
    }

    @Test
    fun `unfocused window field rejects node identity editable session ime and foreground drift`() {
        val replacedNodeEnv = unfocusedWindowFieldEnv(
            beforeNode = FakeNode(id = "n1", isFocused = false),
            afterNode = FakeNode(id = "n2", isFocused = false),
        )
        assertFailure(readEditorBounds(replacedNodeEnv, JSONObject()), "context_changed")

        val editableFlipEnv = unfocusedWindowFieldEnv(
            beforeNode = FakeNode(id = "n1", isFocused = false, isEditable = true),
            afterNode = FakeNode(id = "n1", isFocused = false, isEditable = false),
        )
        assertFailure(readEditorBounds(editableFlipEnv, JSONObject()), "context_changed")

        val boundsDriftEnv = unfocusedWindowFieldEnv(
            beforeNode = FakeNode(id = "n1", isFocused = false, bounds = editorBounds),
            afterNode = FakeNode(id = "n1", isFocused = false, bounds = IntBounds(1040, 1420, 2132, 1540)),
        )
        assertFailure(readEditorBounds(boundsDriftEnv, JSONObject()), "context_changed")

        val imeMissingIdEnv = unfocusedWindowFieldEnv()
        imeMissingIdEnv.requestFactory = { _, _ -> FakeRequest { EditorBoundsMeasurement(0, editorFloatBounds) } }
        assertFailure(readEditorBounds(imeMissingIdEnv, JSONObject()), "missing_id")

        val sessionChangedEnv = unfocusedWindowFieldEnv()
        sessionChangedEnv.onSampleRequest = { it.session = ImeSessionIdentity("ime|fedcba9876543210fedcba98", pkg, true) }
        assertFailure(readEditorBounds(sessionChangedEnv, JSONObject()), "context_changed")

        val imeDeselectedAfterEnv = unfocusedWindowFieldEnv()
        imeDeselectedAfterEnv.onSampleRequest = { it.gatewayImeSelected = false }
        assertFailure(readEditorBounds(imeDeselectedAfterEnv, JSONObject()), "context_changed")

        val foregroundChangedEnv = unfocusedWindowFieldEnv()
        foregroundChangedEnv.onSampleRequest = { it.foregroundPackage = "com.other.app" }
        assertFailure(readEditorBounds(foregroundChangedEnv, JSONObject()), "context_changed")
    }

    @Test
    fun `unfocused window field handles no_ime_bounds timeout interrupted and request_failed`() {
        val nullSampleEnv = unfocusedWindowFieldEnv()
        nullSampleEnv.requestFactory = { _, _ -> FakeRequest { null } }
        assertFailure(readEditorBounds(nullSampleEnv, JSONObject()), "no_ime_bounds")

        val pending = CompletableFuture<EditorBoundsMeasurement?>()
        var cancelledOnTimeout = false
        val timeoutEnv = unfocusedWindowFieldEnv()
        timeoutEnv.requestFactory = { _, _ ->
            object : EditorBoundsRequest {
                override fun await(timeoutMs: Long): EditorBoundsMeasurement? =
                    pending.get(timeoutMs, TimeUnit.MILLISECONDS)

                override fun cancel() {
                    cancelledOnTimeout = true
                    pending.cancel(false)
                }
            }
        }
        assertFailure(readEditorBounds(timeoutEnv, JSONObject(), timeoutMs = 15L), "timeout")
        assertTrue(cancelledOnTimeout)
        assertTrue(pending.isCancelled)

        val interruptedRequest = FakeRequest { throw InterruptedException("stop") }
        val interruptedEnv = unfocusedWindowFieldEnv()
        interruptedEnv.requestFactory = { _, _ -> interruptedRequest }
        try {
            assertFailure(readEditorBounds(interruptedEnv, JSONObject()), "interrupted")
            assertTrue(interruptedRequest.cancelled)
            assertTrue(Thread.currentThread().isInterrupted)
        } finally {
            Thread.interrupted()
        }

        val failedEnv = unfocusedWindowFieldEnv()
        failedEnv.requestFactory = { _, _ ->
            FakeRequest { throw ExecutionException(IllegalStateException("boom")) }
        }
        assertFailure(readEditorBounds(failedEnv, JSONObject()), "request_failed")

        val directTimeout = FakeRequest { throw TimeoutException("late") }
        val directTimeoutEnv = unfocusedWindowFieldEnv()
        directTimeoutEnv.requestFactory = { _, _ -> directTimeout }
        assertFailure(readEditorBounds(directTimeoutEnv, JSONObject()), "timeout")
        assertTrue(directTimeout.cancelled)
    }

    // ---- 4862535 既有前置与窗口字段回归 ----

    @Test
    fun `preconditions window checks missing_id resources_unavailable and access_denied remain fail-closed`() {
        assertFailure(readEditorBounds(unfocusedWindowFieldEnv().apply { sdkInt = 33 }, JSONObject()), "unsupported_api")
        assertFailure(readEditorBounds(unfocusedWindowFieldEnv().apply { session = null }, JSONObject()), "no_input_target")
        assertFailure(
            readEditorBounds(unfocusedWindowFieldEnv().apply { session = ImeSessionIdentity(sessionId, pkg, false) }, JSONObject()),
            "no_input_target",
        )
        assertFailure(readEditorBounds(unfocusedWindowFieldEnv().apply { foregroundPackage = "" }, JSONObject()), "no_input_target")
        assertFailure(readEditorBounds(unfocusedWindowFieldEnv().apply { gatewayImeSelected = false }, JSONObject()), "no_input_target")

        try {
            readEditorBounds(unfocusedWindowFieldEnv().apply { blocked = true }, JSONObject())
            fail("expected blocked package to throw GatewayError")
        } catch (error: GatewayError) {
            assertEquals(ErrorCode.E_BLOCKED, error.code)
        }

        assertFocusUnavailable(
            readEditorBounds(unfocusedWindowFieldEnv().apply { beforePhase.clearCache = false }, JSONObject()),
            "before_sample",
            "cache_clear_failed",
        )
        assertFocusUnavailable(
            readEditorBounds(unfocusedWindowFieldEnv().apply { beforePhase.hasRoot = false }, JSONObject()),
            "before_sample",
            "active_root_missing",
        )
        assertFocusUnavailable(
            readEditorBounds(unfocusedWindowFieldEnv().apply { beforePhase.window = null }, JSONObject()),
            "before_sample",
            "active_window_missing",
        )
        assertFocusUnavailable(
            readEditorBounds(unfocusedWindowFieldEnv().apply { beforePhase.defaultNodesById = emptyMap() }, JSONObject()),
            "before_sample",
            "input_focus_missing",
        )

        val windowMismatches = listOf<FakeEnv.() -> Unit>(
            { beforePhase.window = FakeWindow(isApplicationType = false) },
            { beforePhase.window = FakeWindow(isActive = false) },
            { beforePhase.window = FakeWindow(isFocused = false) },
            { beforePhase.rootPackage = "com.other.app" },
        )
        for (mutate in windowMismatches) {
            assertFailure(readEditorBounds(unfocusedWindowFieldEnv().apply(mutate), JSONObject()), "window_mismatch")
        }

        val missingIdCases = listOf<FakeEnv.() -> Unit>(
            { contract = null },
            { contract = ImeEditorContract(InputType.TYPE_CLASS_TEXT, 0, 0, null, fieldId = 0) },
            { contract = ImeEditorContract(InputType.TYPE_CLASS_TEXT, 0, 0, null, fieldId = -1) },
            { resources[fieldId] = ResourceNameResult.Missing },
            { resources[fieldId] = ResourceNameResult.Found("$pkg:string/chat_input") },
            { resources[fieldId] = ResourceNameResult.Found("id/chat_input") },
        )
        for (mutate in missingIdCases) {
            assertFailure(readEditorBounds(unfocusedWindowFieldEnv().apply(mutate), JSONObject()), "missing_id")
        }

        val blankNodeIdEnv = unfocusedWindowFieldEnv(
            beforeNode = FakeNode(id = "n1", isFocused = false, viewIdResourceName = "   "),
        )
        assertFailure(readEditorBounds(blankNodeIdEnv, JSONObject()), "missing_id")

        val resUnavailableEnv = unfocusedWindowFieldEnv().apply {
            resources[fieldId] = ResourceNameResult.ResourcesUnavailable
        }
        assertFailure(readEditorBounds(resUnavailableEnv, JSONObject()), "resources_unavailable")

        val accessDeniedEnv = unfocusedWindowFieldEnv().apply { securityFailureAt = "selected_ime" }
        assertFailure(readEditorBounds(accessDeniedEnv, JSONObject()), "access_denied")
    }

    @Test
    fun `IntBounds containment and float comparison match Android Rect semantics`() {
        assertTrue(IntBounds(10, 10, 10, 20).isEmpty)
        assertTrue(IntBounds(10, 20, 20, 10).isEmpty)
        assertFalse(windowBounds.isEmpty)
        assertTrue(windowBounds.contains(windowBounds))
        assertTrue(windowBounds.contains(editorBounds))
        assertFalse(IntBounds(10, 10, 10, 20).contains(IntBounds(10, 10, 10, 20)))
        assertTrue(editorBounds.matchesFloat(editorFloatBounds))
        assertFalse(editorBounds.matchesFloat(FloatBounds(1040.5f, 1420f, 2120f, 1540f)))
    }
}
