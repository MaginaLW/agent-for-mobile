# T-L1 v2 · 平板原生双窗 diagnostic-only 离线规程

## 当前可执行范围

当前只运行 synthetic fixture gate：

```powershell
pwsh -NoProfile -File scripts/run-tablet-layout-observation-v2-offline-gate.ps1
```

预期末行：

```text
tablet T-L1 v2 diagnostic-only gate：24/24 cases，24/24 coverage；layout=false，P0=unsupported，exec=false
```

机器摘要固定落在：

```text
.checks/tablet-tl1-v2-offline-gate.summary.json
```

不要传 evidence root、output path、suite 或 filter 给一键入口；wrapper 固定这些边界并为每次运行生成新的
gate run ID。

## 禁止事项

本规程不是 C 道真机 runner。不得据此：

- 调用 adb、安装/启动 App、点击、输入、截图、切换 IME 或修改任何系统/App 设置；
- 关闭 vivo“应用多窗”换取单窗；产品基线是适配设备的日常双窗形态；
- 把 fixture `diagnostic_observed=true` 写成 layout accepted、WeChat verified 或“T-L1 通过”；
- 启动 T-L2、手机 P0、gateway action 或 execution；
- 把 caller 自报 hash、Git SHA、device profile 或 fixture summary 当成 runtime attest。

直接调用 consumer 也必须显式 fixture 模式：

```powershell
pwsh -NoProfile -File scripts/validate-tablet-layout-observation-v2.ps1 `
  -Path <受控-root内的fixture.json> `
  -EvidenceRoot <固定本地受控root> `
  -FixtureMode
```

不带 `-FixtureMode` 时入口不会读取 caller 文件，只返回 `runtime_producer_unavailable`。
`FixtureMode` 不是 mandatory 参数；因此仍需提供 `Path/EvidenceRoot`，但省略该 switch 的 CLI 进程会输出上述
blocked JSON envelope 并以非零退出。不要把真实聊天文本作为参数；consumer 只使用内建 fixture-only dummy
canary 做定点隐私证明。

## 结果解释

- `fixture_contract_valid=true`：JSON/file/provenance 的 synthetic contract 路径有效；
- `diagnostic_observed=true`：两帧 synthetic native double-window 模型自洽；
- `diagnostic_status=blocked`：查看 `reason_codes`，不得用 caller 声明、删字段、改设置或关闭设备能力修绿；
- 最终 envelope 中的 `capture_in_future/capture_stale` 由 consumer 按实际 `UtcNow` 追加；evidence 不应预声明
  它们。出现这些 reason 时两分钟/future 门仍已 fail closed，只是不把 validation-time 差异误算成 producer
  intrinsic declaration mismatch；
- 任一结果的 `runtime_evidence/layout_accepted/wechat_layout_verified/editor_action_ready/
  settings_mutation_allowed/device_action_allowed/execution_grant` 都必须为 false，P0 必须 unsupported。

## 后续真机边界

真实 C1a 必须另有经独审的 producer、fresh T0 envelope 传递、runner attest、固定 SHA、隔离 evidence root 与
只读命令/能力证明。本离线入口明确不接受真实设备路径。即使未来 diagnostic runtime capture 成功，第一阶段
也仍不产生 layout acceptance/P0/action/execution；要提升结论必须新合同、新独审与新授权。

未来 runner 向 app producer 传递 T0 时必须使用 T0 producer 留下的原始 BOM-less bytes，不得先解析再序列化；
app 只接受 1..65,536 bytes strict UTF-8/RFC 8259 object，拒绝重复 key 与非 Int64 number，并按 consumer 同一规则
重算 device canonical hash。完成这些 intrinsic 检查仍不等于 runner attest，不能把 production capability
从 unavailable 改成 available。

字段与判据详见 [`tablet-layout-observation/v2` 契约](../contracts/tablet-layout-observation-v2.md)。
