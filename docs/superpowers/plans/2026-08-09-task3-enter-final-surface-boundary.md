# Task 3 Enter Final Surface Boundary Execution Plan

> **For agentic workers:** REQUIRED EXECUTION FLOW: Use `subagent-driven-development` to execute this plan task-by-task when subagents are available. If no subagent capability is available, execute inline with the same task checklist and review checkpoints.

**Goal:** Bind the last fresh conversation-surface proof and exactly one Enter delivery into one production action boundary, so a same-app conversation switch after evidence rebuild cannot reuse the approved evidence.

**Approach:** Trace the real SafetyGate-to-UiTools path and isolate the existing gap as a pure, production-shared executor test. Then move final fresh bundle validation immediately beside the existing single-channel Enter API, preserving package/session/connection checks and rollback semantics.

**Materials:** `ToolRegistry.kt`, `SafetyGate.kt`, `UiTools.kt`, `GatewayIme.kt`, `GatewayA11yService.kt`, `FreshEvidenceRebuild.kt`, existing Enter/rebuild unit tests, and `docs/specs/2026-08-02-语义意图审批-design.md` §9.

**Validation:** Focused Debug/Release tests reproduce then close the same-app switch; full `:gateway:testDebugUnitTest :gateway:testReleaseUnitTest`; Task 3 `git diff --check`; independent final review.

**Execution result (2026-08-09):** 第三份 fresh bundle 返回后到真正 Enter 之间的同 App 会话切换被行为 RED 复现（旧边界 9 tests / 1 failure，实际 Enter=1、期望 0）。最终边界在 service monitor 内取得第四份真实 fresh Bitmap，复核标题、同图 OCR、输入节点与 generation，再以固定 service→IME 锁序进入 session lock，验证 package/session/connection 后只投递一个通道；false/Exception/Error 均清空双 evidence store。Focused Debug/Release 各 22 tests 全绿；fresh full Debug 496、Release 393，0 failure/error/skip；独立最终复审 Approved，无剩余 Critical/Important。

---

### Task 1: Trace the final Enter data and action path

**Artifacts / Locations:**
- Review: `app/gateway/src/main/java/dev/magina/gateway/mcp/ToolRegistry.kt`
- Review: `app/gateway/src/main/java/dev/magina/gateway/core/SafetyGate.kt`
- Review: `app/gateway/src/main/java/dev/magina/gateway/tools/UiTools.kt`
- Review: `app/gateway/src/main/java/dev/magina/gateway/ime/GatewayIme.kt`

- [x] **Step 1: Gather the needed input**

Read the complete functions from approved evidence rebuild through `pressKey`, including context resampling, prepared/input evidence lookup, session validation, and the selected Enter channel.

- [x] **Step 2: Produce the task output**

Record the precise first point after the third fresh bundle at which a same-package surface switch can occur, and identify the smallest production executor seam that already owns exactly-one delivery.

- [x] **Step 3: Verify the output**

Check that the traced path accounts for both a11y `ACTION_IME_ENTER` and InputConnection delivery, plus all store-clearing paths.

- [x] **Step 4: Record the result**

Update the active plan with the root-cause hypothesis before editing production code.

### Task 2: Pin the cross-layer TOCTOU as RED

**Artifacts / Locations:**
- Modify or create: focused JVM tests under `app/gateway/src/test/java/dev/magina/gateway/tools` or `.../a11y`

- [x] **Step 1: Gather the needed input**

Reuse the production-shared Enter and fresh-bundle helpers; do not assert source strings or duplicate the safety predicate in the test.

- [x] **Step 2: Produce the task output**

Add a case where the third rebuild bundle is valid, then the same package title or same-image OCR content changes while IME session/input identity remain unchanged; assert zero Enter deliveries and both evidence stores cleared.

- [x] **Step 3: Verify the output**

Run the focused Debug test and require a behavioral failure showing the old boundary still delivers Enter.

- [x] **Step 4: Record the result**

Preserve the failing command, test count, and assertion in the handoff.

### Task 3: Implement one final fresh-and-deliver boundary

**Artifacts / Locations:**
- Modify: `app/gateway/src/main/java/dev/magina/gateway/a11y/FreshEvidenceRebuild.kt`
- Modify: `app/gateway/src/main/java/dev/magina/gateway/a11y/GatewayA11yService.kt`
- Modify: `app/gateway/src/main/java/dev/magina/gateway/tools/UiTools.kt`
- Modify only if required: `app/gateway/src/main/java/dev/magina/gateway/ime/GatewayIme.kt`

- [x] **Step 1: Gather the needed input**

Compare the current `enterIfCurrentSession` lock boundary with the fresh rebuild executor and choose a lock order that does not introduce service-monitor/session-lock ABBA.

- [x] **Step 2: Produce the task output**

Immediately before delivery, obtain and validate a new fresh bundle against the approved expected surface/content; select one channel; validate package/session/id/connection and surface at the delivery boundary; deliver at most once. On any validation/delivery exception, fail closed and clear both stores without retry/fallback.

- [x] **Step 3: Verify the output**

Run the focused Debug and Release tests. Expected: same-app drift gives `E_STALE_REF`/non-retryable failure, zero delivery, zero evidence; stable state delivers once through only the selected channel.

- [x] **Step 4: Record the result**

Document the final lock/action ordering and the reason it cannot double-deliver.

### Task 4: Full verification and independent review

**Artifacts / Locations:**
- Review: all Task 3 Kotlin files touched by Tasks 2–3

- [x] **Step 1: Gather the needed input**

Collect focused XML counts and inspect the final diff for Task 1/Task 2/script overlap.

- [x] **Step 2: Produce the task output**

Run `app\gradlew.bat -p app :gateway:testDebugUnitTest :gateway:testReleaseUnitTest --console=plain` and Task 3-only whitespace checks.

- [x] **Step 3: Verify the output**

Expected: all Debug/Release tests pass with zero failures/errors/skips, diff check clean, no script or Task 2 changes.

- [x] **Step 4: Record the result**

Request a fresh independent Critical/Important review and report RED/GREEN evidence, changed files, atomic boundary, and remaining conservative-failure risk.
