# T-L1 v2 · 平板原生双窗 diagnostic-only 诊断/取证规程

## 当前可执行范围

无机入口只运行 synthetic fixture gate；真机只能按下文 C1a 受控只读入口、在固定干净 SHA 上执行：

> 2026-08-26 状态：fixed SHA `2635fc9f5eb229340870b0cdd599cefad97a9b91` 的首次真机 C1a 已按失败
> 冻结，禁止复用。A 道修复与标准全门/独审已完成；必须先提交新的完整 SHA、完成外部 clean/blob 复核，
> 并取得用户对新 C 轮的明确授权，才能再次连接设备。不得把已冻结 run 写成 C1a 或 T-L1 通过。

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

本节无机 fixture 入口不是 C 道真机 runner。不得据此：

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
- `diagnostic_observed=true`：2–4 帧 synthetic native double-window 模型自洽；受控 C1a 仍固定恰好 c1/c2 两帧；
- `diagnostic_status=blocked`：查看 `reason_codes`，不得用 caller 声明、删字段、改设置或关闭设备能力修绿；
- 最终 envelope 中的 `capture_in_future/capture_stale` 由 consumer 按实际 `UtcNow` 追加；evidence 不应预声明
  它们。出现这些 reason 时两分钟/future 门仍已 fail closed，只是不把 validation-time 差异误算成 producer
  intrinsic declaration mismatch；
- 任一结果的 `runtime_evidence/layout_accepted/wechat_layout_verified/editor_action_ready/
  settings_mutation_allowed/device_action_allowed/execution_grant` 都必须为 false，P0 必须 unsupported。

## 后续真机边界

真实 C1a 只能使用下节独立受控 producer/runner：fresh T0 原始 bytes、固定 SHA、隔离 evidence root 与只读
命令/能力证明必须同时成立。本节 fixture 入口明确不接受真实设备路径。即使 diagnostic runtime capture 成功，
第一阶段也仍不产生 layout acceptance/P0/action/execution；要提升结论必须新合同、新独审与新授权。

受控 runner 向 app producer 传递 T0 时必须使用 T0 producer 留下的原始 BOM-less bytes，不得先解析再序列化；
app 只接受 1..65,536 bytes strict UTF-8/RFC 8259 object，拒绝重复 key 与非 Int64 number，并按 consumer 同一规则
重算 device canonical hash。完成这些 intrinsic 检查仍不等于 runner attest，不能把 production capability
从 unavailable 改成 available。

Windows 宿主写 T0 必须使用 `adb exec-in content write --uri <raw-canonical-uri>`。`exec-in` 的 binary stdin
路径保持 CRLF 与全部原始 bytes；不得用普通 `adb shell content write`，后者会在 Windows text-mode stdin
路径把 CRLF 归一为 LF。`exec-in` 会自行 escape command argv，因此 URI 参数必须是已通过 closed grammar 的
raw canonical URI，不能预置字面 POSIX 单引号；status/c1/c2/result/abort 这些只读 endpoint 仍走
`adb shell content read`，并继续用远端 POSIX 单引号保护完整 query。write 没有远端 ACK 通道，首次 status 的
bounded wait 仍是唯一认证/完成边界。

## C1a 受控只读入口

C1a 已有独立受控 runner 候选；必须在 runner/Android provider 完成独审并钉住新的完整 SHA 后运行：

```powershell
pwsh -NoProfile -File scripts/run-tablet-layout-c1a.ps1 `
  -AdbPath 'C:\Android\platform-tools\adb.exe' `
  -ExpectedCommitSha '<独审后钉住的完整40位小写SHA>' `
  -Provision
```

`-Provision` 是本轮安装 debug APK 的显式授权，不表示允许卸载、修改 settings、切换 IME、启动微信或操作
页面。runner 要求唯一设备，fresh build 后只安装一次；安装失败不重试。它只读检查网关无障碍服务是否 enabled
且 bound；已 enabled 时会给 vivo 系统最多 45 秒完成重绑，期间只每秒读一次 Bound services。
缺失或超时时输出 `status=needs-user`，由用户在设备上完成允许后另开一轮，脚本不会自动改设置。
安装后和 result 后都会从 strict `/data/app/.../base.apk` 路径以 `exec-out cat` 流式计算宿主 SHA-256；
不相等、路径/package/version 漂移或本地 APK 漂移都直接结束，不补拍、不重安装。

开始前由用户把 vivo 平板保持在日常横屏、保持“应用多窗”开启，并把微信停在“文件传输助手”会话；runner
不会导航或启动目标 App。项目适配设备原生双窗，不以关闭设备功能换绿。

Android debug-only C1a adapter 的 observation `capture.revision_*` 是可逆 logical marker，而不是冒充 raw
无障碍事件序号：`logical revision = raw event revision + capture ordinal`，其中 c1/c2 ordinal 固定为 1/2，
可由 capture token 反算 raw。稳定静态页允许两帧 raw revision 相等；raw 下降、溢出、未知 token 或同一帧内
raw event 漂移仍 fail closed。此映射只解决“恰好采了两帧且顺序明确”的表达，不删除 pane/title/focus/node/
region 等真实诊断 blocker，也不修改 producer/T0 六个 baseline blob。

正常证据固定落在：

```text
docs/runs/evidence/<run_id>/tablet-profile.json
docs/runs/evidence/<run_id>/tablet-layout-c1a/upstream-t0-v5.json
docs/runs/evidence/<run_id>/tablet-layout-c1a/tablet-layout-observation-v2.json
docs/runs/evidence/<run_id>/tablet-layout-c1a/tablet-layout-observation-validation-v2.json
docs/runs/evidence/<run_id>/tablet-layout-c1a/tablet-layout-c1a-sidecar-v1.json
```

`upstream-t0-v5.json` 与 provider 收到的是同一份原始 bytes；不得 parse/re-serialize。sidecar 会绑定
T0、observation、validation 三份文件的 artifact hash，并在 sidecar 原子发布前后重算。sidecar 的 origin/read-only
布尔只由 clean-port blob、fresh APK/install、provider 回显、同设备/T0、固定 argv 与实现/证据 hash 联合支撑。
即使 observation 显示 `diagnostic_status=observed`，C1a 仍固定 runtime/layout/action/P0/execution 不放行。

失败时不发布 success sidecar，只原子保留 `tablet-layout-c1a-failure.json` 与已经产生的只读证据。一次明确授权
只允许一个 capture attempt；任一失败都必须冻结 evidence 并回 A，不能在同轮重安装、重采或补拍。

## 2026-08-26 首次真机 C1a 冻结

- 第一授权轮在安装阶段超时：`run_id=none`，未调用 c1/c2，也未产生 evidence；没有自动重试。
- 用户另行明确授权后才开始第二轮。唯一 run `tl1-c1a-20260826t114535z-63667b68ce4f` 的 c1/c2 各执行
  一次，capture ID 为 `capture-c1`/`capture-c2`，间隔 1982.304 ms；result 单次消费，无补拍。
- trusted-runtime validation 失败且没有 success sidecar，故 origin 未成立；`runtime_evidence=false`、
  `layout_accepted=false`、`p0_capability=unsupported`、`execution_grant=false`。完整证据 hash、reason 与修复
  边界见 [`2026-08-26-T-L1-C1a只读取证失败.md`](../runs/2026-08-26-T-L1-C1a只读取证失败.md)。
- 失败期间 vivo“应用多窗”保持开启，未修改设备设置。A 修复与标准全门/独审现已完成；当前分支 HEAD 已作为新 fixed-SHA 候选固定，
  完成外部 clean/blob 复核并取得用户新授权前，不得进入下一轮 C。

无设备门：

```powershell
pwsh -NoProfile -File scripts/check-tablet-layout-c1a-offline.ps1
```

它只运行 AST/schema 与 fake adb/content/Gradle/apksigner 套件，不调用真实 adb、不发现设备。公共
`validate-tablet-layout-observation-v2.ps1` 不带 `-FixtureMode` 时仍在读 caller path 前返回
`runtime_producer_unavailable`；trusted-runtime 路径只由受控 C1a runner 内部调用，且 `runtime_evidence=false`。
项目标准 Gradle 门还会执行 `:gateway:verifyTabletC1aReleaseAbsence`，证明 C1a provider 只存在于 debug APK。

A 修复的标准全门已通过：C1a 15/15、required coverage 46/46、self 3/3，Debug 377/377、Release 261/261、
dispatch 28/28、runner 82/82、T-L1 24/24；assembleDebug、release absence、凭据扫描全绿，独立终审
P0/P1=0。以上仍只是离线准入，不是 C1a/T-L1 通过；当前分支 HEAD 已作为新 fixed-SHA 候选固定，待完成外部 clean/blob 复核。

完整协议见 [`tablet-layout-c1a/v1`](../contracts/tablet-layout-c1a-v1.md)。

字段与判据详见 [`tablet-layout-observation/v2` 契约](../contracts/tablet-layout-observation-v2.md)。
