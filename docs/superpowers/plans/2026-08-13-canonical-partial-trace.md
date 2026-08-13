# Canonical Partial Trace Execution Plan

> **For agentic workers:** REQUIRED EXECUTION FLOW: Use `subagent-driven-development` to execute this plan task-by-task when subagents are available. If no subagent capability is available, execute inline with the same task checklist and review checkpoints.

**Goal:** Make failure-path tool-policy scanning consume a canonical, lifecycle-safe partial trace without relaxing normal transcript validation.

**Approach:** Extend the shared transcript reader with an opt-in EOF-only partial mode, then remove the runner's duplicate event parser. Legal complete traces retain the same canonical output and default parsing still requires a complete lifecycle; both modes share stricter malformed frame/object validation, while `AllowPartial` only relaxes the EOF boundary. Lock the contract with direct two-brain parser tests and deterministic runner integration fixtures, taking RED evidence before changing production code.

**Materials:** `scripts/lib/dispatch-brain.ps1`, `scripts/run-p0-safety-smoke.ps1`, `scripts/tests/dispatch-offline.ps1`, `scripts/tests/p0-supervised-runner-offline.ps1`, and the existing trace lifecycle fixtures.

**Validation:** Focused offline tests must first fail against the old implementation, then pass after the change; existing malformed, lifecycle, and unknown-item regressions must remain green. No adb, device, install, or commit commands are permitted.

---

### Task 1: Encode the canonical partial contract

**Artifacts / Locations:**
- Modify: `scripts/tests/dispatch-offline.ps1`
- Modify: `scripts/tests/p0-supervised-runner-offline.ps1`

- [x] **Step 1: Add direct two-brain positive cases**

Cover complete-trace equivalence, EOF without terminal, and EOF with only the last call unfinished. Verify default mode remains strict and partial mode preserves the unfinished call identity.

- [x] **Step 2: Add lifecycle-negative cases**

For Claude, reject terminal-with-unfinished-call, non-tail unfinished calls, malformed/unknown frames, duplicate IDs, and orphan/duplicate results. For Codex, additionally reject orphan/duplicate completed items and started/completed server, tool, argument, ID, and ordering mismatches.

- [x] **Step 3: Add runner integration coverage**

Keep the deterministic Claude Bash prefix fixture and add a Codex non-gateway `item.started` prefix without completed/terminal. Directly cover partial gateway and ToolSearch prefixes as allowed/non-offending identities.

- [x] **Step 4: Record RED**

Run only the newly focused offline tests. Expected: failures specifically show that `-AllowPartial` is absent or that the old strict reader rejects the valid prefixes.

Evidence: `pwsh -NoProfile -File scripts/tests/dispatch-offline.ps1 -Filter '*canonical partial*'` produced 3 passed / 1 failed; the sole failure was `A parameter cannot be found that matches parameter name 'AllowPartial'.`. Log: `.checks/canonical-partial-red-dispatch-offline-20260813.log`.

### Task 2: Implement EOF-only partial parsing

**Artifacts / Locations:**
- Modify: `scripts/lib/dispatch-brain.ps1`
- Modify: `scripts/run-p0-safety-smoke.ps1`

- [x] **Step 1: Add `-AllowPartial` to the shared reader**

Keep canonical output unchanged for legal complete traces and keep the default path's complete-lifecycle requirement. Both modes use the same stricter malformed frame/object checks; with the switch, additionally allow only EOF without a terminal and an optional unfinished final call.

- [x] **Step 2: Replace the runner parser**

Call the shared reader with `-AllowPartial`, map `Bash` and all other non-gateway identities to fixed public labels, and map every parse failure to `trace_transcript_invalid`.

- [x] **Step 3: Review the production diff**

Confirm no status/backlog, device, provisioning, teardown, or unrelated runner semantics changed.

Evidence: scoped review found changes only in the shared parser, failure-path scanner, offline tests, and this execution plan. Existing unrelated worktree changes were not modified.

### Task 3: Verify GREEN and regressions

**Artifacts / Locations:**
- Review: focused test output and saved logs

- [x] **Step 1: Run direct parser tests**

Expected: all new two-brain partial and negative cases pass.

Evidence: focused direct parser suite passed 4/0, including empty Claude rejection and Codex `thread.started`-only prefix behavior. Log: `.checks/canonical-partial-green-dispatch-offline-20260813-v6.log`.

- [x] **Step 2: Run focused runner tests**

Expected: Claude partial Bash and Codex partial non-gateway integrations pass with exact fixed policy labels.

Evidence: Claude partial Bash passed 1/0 and Codex partial non-gateway started passed 1/0. Log: `.checks/canonical-partial-green-runner-integrations-20260813.log`.

- [x] **Step 3: Run related regressions**

Expected: malformed trace, Claude result pairing, Codex lifecycle, and unknown-item cases retain their prior fail-closed results.

Evidence: full `dispatch-offline.ps1` passed 62/0 (`.checks/canonical-partial-full-dispatch-offline-20260813.log`). Focused runner malformed, Codex lifecycle, and Codex unknown-item groups each passed 1/0 (`.checks/canonical-partial-runner-regressions-20260813.log`).

- [x] **Step 4: Record result**

Report exact commands, pass/fail counts, log paths, and the final scoped diff; do not commit.

Result: all required offline gates above are green. No adb, device, install, STATUS/backlog edit, or commit was performed.

### Task 4: Close independent-review contract gaps

**Artifacts / Locations:**
- Modify: `scripts/lib/dispatch-brain.ps1`
- Modify: `scripts/tests/dispatch-offline.ps1`
- Modify: `scripts/tests/p0-supervised-runner-offline.ps1`

- [x] **Step 1: Record reviewer-focused RED**

Add cases for case-insensitive Claude `tool_use`/`tool_result`, JSON-object-only Claude input and Codex arguments, Codex terminal turn accounting, and an unfinished last call followed by valid non-call frames. Run only the new direct parser cases and record the exact failures.

Evidence: the initial reviewer-focused run produced 1 passed / 3 failed: uppercase Claude tool blocks were dropped, malformed input/arguments were accepted, and a complete Codex `turn.failed` transcript reported the wrong turn count (`.checks/canonical-partial-reviewer-red-dispatch-offline-20260813.log`). Raw non-string identity cases then produced 0 passed / 3 failed (`.checks/canonical-partial-reviewer-string-types-red-20260813.log`), and exact single-element object-array input/arguments produced 0 passed / 1 failed, demonstrating PowerShell property-enumeration unwrapping (`.checks/canonical-partial-reviewer-object-array-red-20260813.log`).

- [x] **Step 2: Implement the narrow contract fixes**

Recognize Claude tool block types case-insensitively, require input/arguments to be JSON objects in both modes, and report one turn for a complete Codex terminal even when `turn.started` is absent. Preserve the existing contract that only the final **call** may be unfinished: valid non-call suffix frames remain allowed, while a second call remains rejected.

Implementation also validates identity fields from their raw JSON values as non-empty strings and reads input/arguments from the raw property value, so numbers, booleans, objects, arrays, and single-element object arrays cannot pass through PowerShell string coercion or member-enumeration unwrapping. These shared malformed checks apply in default and partial modes; legal complete-trace canonical output and the default complete-lifecycle requirement remain unchanged.

- [x] **Step 3: Lock invalid-dominates integration behavior**

Add a failure-path fixture whose paired Bash call is followed by malformed JSON. Verify the scanner exposes only `trace_transcript_invalid`, never Bash or another model-controlled identity.

Evidence: the focused integration passed 1/0 and mechanically verified that the public violation list contains only `trace_transcript_invalid` (`.checks/canonical-partial-invalid-dominates-prefx-20260813.log`).

- [x] **Step 4: Verify and record**

Run reviewer-focused GREEN, full dispatch offline, the related runner partial/malformed/lifecycle/unknown-item groups, and `git diff --check`. Record commands, counts, and log paths without running adb, a full repository gate, or a commit.

Evidence: the final reviewer-focused direct suite passed 7/0 (`.checks/canonical-partial-reviewer-all-focused-green-20260813.log`); full `dispatch-offline.ps1` passed 69/0 (`.checks/canonical-partial-reviewer-final-full-dispatch-20260813.log`); the seven related runner filters each passed 1/0, including deterministic Claude/Codex partial traces, invalid-dominates, ToolSearch, six malformed fixtures, three Codex lifecycle fixtures, and the unknown-item fixture (`.checks/canonical-partial-reviewer-final-runner-regressions-20260813.log`). No adb, device, install, full repository gate, STATUS/backlog edit, or commit was performed.

- [x] **Step 5: Close raw discriminator type coercion**

Require top-level event `type`, Claude content `type`, and Codex item `type` to be raw non-empty JSON strings; require Claude `message` and Codex event `item` to be raw JSON objects. The comparison contracts remain unchanged: Claude tool block types are recognized case-insensitively, while Codex item types keep their exact comparisons. Direct raw-property helpers are used instead of the generic getter so PowerShell cannot unwrap single-element JSON arrays.

Evidence: the focused aggregate RED produced 0 passed / 1 failed and listed all 14 accepted malformed combinations (seven discriminator/object shapes in both strict and `AllowPartial` modes), including `event.type` arrays, Claude `message` object arrays, Claude content `type` arrays, Codex `item` object arrays, and Codex MCP/reasoning item `type` arrays (`.checks/canonical-partial-discriminator-raw-types-red-v2-20260813.log`). The focused GREEN passed 1/0 (`.checks/canonical-partial-discriminator-raw-types-green-20260813.log`), the existing reviewer suite passed 7/0 (`.checks/canonical-partial-discriminator-reviewer-focused-green-20260813.log`), and full `dispatch-offline.ps1` passed 70/0 (`.checks/canonical-partial-discriminator-final-full-dispatch-20260813.log`). On the final parser code, all seven related runner filters passed 1/0, including their six malformed and three Codex lifecycle sub-fixtures (`.checks/canonical-partial-discriminator-final-runner-regressions-20260813.log`). `git diff --check` was the final source check; no adb, device, install, full repository gate, STATUS/backlog edit, or commit was performed.

- [x] **Step 6: Reject top-level JSON array frames before event parsing**

Parse each non-empty JSONL line with `ConvertFrom-Json -NoEnumerate`, then require the preserved top-level value to be a JSON object before reading event fields. This closes PowerShell's pipeline expansion of a single-element top-level object array without changing legal complete or partial object-frame semantics.

Evidence: the aggregate RED produced 0 passed / 1 failed and proved all four malformed combinations were accepted: Claude strict/partial exposed canonical `Bash`, and Codex strict/partial exposed canonical `local/shell` (`.checks/canonical-partial-top-level-frame-red-v2-20260813.log`). The focused GREEN passed 1/0 (`.checks/canonical-partial-top-level-frame-green-20260813.log`), all canonical-partial tests passed 13/0 (`.checks/canonical-partial-top-level-frame-all-focused-green-20260813.log`), and full `dispatch-offline.ps1` passed 71/0 (`.checks/canonical-partial-top-level-frame-final-full-dispatch-20260813.log`). On the final parser code, all seven related runner filters passed 1/0, including their six malformed and three Codex lifecycle sub-fixtures (`.checks/canonical-partial-top-level-frame-final-runner-regressions-20260813.log`). `git diff --check` was the final source check; no adb, device, install, full repository gate, STATUS/backlog edit, or commit was performed.

### Task 5: Final combined offline gate

- [x] **Step 1: Obtain fresh independent review**

The final combined OCR/parser diff received Critical 0 / Important 0 / Minor 0. The reviewer confirmed that both
brain paths preserve the top-level JSON value with `-NoEnumerate`, apply the object gate before the shared
strict/partial flow, and retain legal object-frame canonical output.

- [x] **Step 2: Run the repository gate on a stable snapshot**

`pwsh -NoProfile -File scripts/check.ps1 -Shards 3` exited 0: diff-check clean; dispatch 71/71; Gateway
Debug/Release tests plus `assembleDebug` passed; runner shards passed 50/50, 49/49, and 49/49 (148/148 total);
credential scan passed. Master log:
`.checks/input-ocr-and-partial-trace-final-full-gate-20260813.log`, SHA-256
`B7577776B9768548F3318978A7BE0B8E1C663C066CCE6F870C37408A8E319ED3`; stderr was empty.
Before and after the gate, HEAD was `f0a767335e70aa99ed0fc242a1217978600435af` and the composite diff
SHA-256 (including the untracked plan) was
`379F6E6787C25C1B3219D4753B20423D1CEB6C79415386CDD013EFD4FFDB5B96`. Relevant processes, fixture
directories, and `index.lock` were all absent after completion. Only these evidence paragraphs were filled in
afterward; production code and tests did not change.
