# Tablet T-L1 C1b v2：保留未知类型的 pure-a11y 诊断合同

## 版本与边界

`tablet-layout-observation/c1b-v2` 在 [C1b v1](tablet-layout-observation-c1b-v1.md) 基础上，只将窗口 `platform_type_code` 的 wire 域从 `0..255` 改为完整 signed Int32，保持平台已经返回的整数原值。对应 [v2 schema](tablet-layout-observation-c1b-v2.schema.json) 及 provenance.version 均为显式新版本 `c1b-v2`；v1 schema、fixtures 和历史证据不迁移。

Android API 返回 int，并不保证 `0..255`。负数或大于 255 的值本身不证明读取异常、ROM 缺陷或某种窗口身份。生产端不再因数值越出旧域而丢弃窗口壳，仍按原顺序执行后续字段读取；任何后续读取失败、容量截断和原语义判据保持。

## 数值、类型与未知信息

| platform_type_code | type |
|---|---|
| 1 | application |
| 2 | input_method |
| 3 | system |
| 4 | accessibility_overlay |
| 5 | split_screen_divider |
| 6 | magnification_overlay |
| 7 | window_control |
| 其余 signed Int32 | unknown |

数值必须是 JSON 整数 token，范围为 `-2147483648..2147483647`；字符串、Boolean、null、浮点/指数 token 或越界整数均拒绝。相同类型值可出现在多个窗口中，不能用类型值替代窗口身份或跨帧关联。

未知类型可以成为**合同有效**的诊断事实，不能升级为完整类型 inventory：

- 保留 `window_type_invalid` 语义 reason，窗口/ownership/root projection/topology observed 不成立；
- focus 必须为 unknown，window/node label 均为空；
- IME hidden 不成立并保留 `ime_inventory_invalid`，即使 visible=false 或 tuple 看似 hidden；
- 原 pane、会话、区域及动作、P0 和 execution 安全常量不变。

已知类型数值与 type 名称不匹配，也沿用原语义阻断，不增加新的 fatal 分类。合同失败与“诚实描述了不可用语义”应区分；伪造 focus、IME 或权限不能获得对应结论。

## 消费端隔离

新公开入口为 `Test-TabletLayoutObservationC1BV2File` 和 `Test-TabletLayoutObservationC1BV2TrustedRuntimeFile`，输出 `tablet-layout-observation-validation/c1b-v2` 及对应 contract_schema。

薄 v2 入口调用现有共享内核，并固定传入版本参数；内核仅接受 `c1b-v1|c1b-v2`，默认仍为 v1。旧公开 API 不暴露该参数，仍只接受旧 schema 和旧数值域。共载或改变加载顺序不得修改 script-global 版本来临时放宽旧入口。其余严格 UTF-8、数字/重复键、隐私、受控路径、时间、来源绑定、frame 语义及可信度边界沿用 v1。

trusted-runtime 入口仍最多给出 `runtime_binding_inputs_match`；`runtime_origin_verified`、runtime_evidence 和所有 verified/动作授权均不由字符串相等自证。

## inventory-result/v3

新的外层为 `tablet-c1b-inventory-result/v3`，schema 见 [v3 封套](tablet-c1b-inventory-result-v3.schema.json)。它保留此前 v2 的外层三键、12 类首次停止键和全部 frame 字段，但要求：

- `first_stop_counts.window_type_invalid=0`；新 producer 已不因类型范围丢弃窗口；
- `rejected_type_code_counts=[]`；拒绝表不再承载可接受项，不另加 unknown 聚合；
- observation_json 绑定 `tablet-layout-observation/c1b-v2` 原文。

外层同名 `window_type_invalid` 是“因范围门丢弃的首次停止次数”，必须为零；内层同名 reason 是“语义类型 inventory 不完整”，未知壳被保留时仍可存在。不能混淆两者。

消费者只收 v3 封套，旧 v1/v2 显式拒绝。顺序继续是解封、隐私检查、内层运行/版本绑定、双文件原字节落盘、计数校验、完整 observation 校验。通过原形状/容量检查的非空拒绝表或非零范围首次停止，在绑定后的计数阶段报 count_mismatch，保留已绑定失败证据；不得补采、转换旧结果或提前绕过原隐私与绑定步骤。

原 observation v1 与外层 v1/v2 schema 均保留。新数值域只是记录范围变化，不证明任一未知类型已可识别或 T-L1 已通过。

## 定向验证

`scripts/tests/tablet-layout-observation-c1b-v2-offline.ps1` 覆盖 signed Int32 边界、重复未知值、错误数字 token、伪已知映射、focus/IME 与能力拒绝、版本隔离及新旧 API 共载；封套回归继续由 `scripts/tests/tablet-c1b-inventory-result-offline.ps1` 覆盖闭合形状、隐私/原文、绑定和守恒顺序。离线通过不替代固定 SHA 的真机验收。
