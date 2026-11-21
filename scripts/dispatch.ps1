#Requires -Version 7
<#
手机执行 harness · 派单 wrapper
设计：docs/specs/2026-07-17-执行harness-design.md（§4–§7）

用法：
  scripts/dispatch.ps1 -TaskFile scripts/tasks/xxx.md [-Slug 短名] [-TimeoutMin 15] [-Model <Codex模型>]
  scripts/dispatch.ps1 -Task "<内联任务文本>" [-Slug 短名]
  scripts/dispatch.ps1 -Confirm docs/runs/traces/xxx.pause.md    # gateway 纯前置条件恢复；PC 输入 RESUME 不批准危险动作
  固定 Codex + gateway（Claude 与 mobile 执行器已退役）。
  加 -DryRun 只打印组装后的提示词与参数，不预检不派单。

约束：路径参数不要含空格（Start-Process 参数按空格分词，本仓路径无空格即可）。
#>
[CmdletBinding()]
param(
    [string]$Task,
    [string]$TaskFile,
    [string]$Slug,
    [ValidateRange(1, 60)][int]$TimeoutMin = 15,
    [string]$Model = '',
    [string]$Brain = 'codex',
    [ValidateSet('gateway')][string]$Executor = 'gateway',
    [string]$Confirm,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$')][string]$ExpectedDeviceSerial,
    [ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ExpectedGatewaySha256,
    [switch]$DryRun
)

$ExecutorWasExplicit = $PSBoundParameters.ContainsKey('Executor')
$BrainWasExplicit = $PSBoundParameters.ContainsKey('Brain')
$ModelWasExplicit = $PSBoundParameters.ContainsKey('Model')
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.Encoding]::UTF8
[Console]::InputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8

if ($Brain -ne 'codex') {
    throw "Brain 参数只接受 codex（Claude 已退役；收到：$Brain）。"
}
$Brain = 'codex'

$RepoRoot     = Split-Path $PSScriptRoot -Parent
$TracesDir    = Join-Path $RepoRoot 'docs\runs\traces'
$LedgerPath   = Join-Path $RepoRoot 'docs\runs\ledger.csv'
$ProfileHelperPath = Join-Path $PSScriptRoot 'lib\dispatch-profile.ps1'
. $ProfileHelperPath
$LockHelperPath = Join-Path $PSScriptRoot 'lib\dispatch-lock.ps1'
. $LockHelperPath
$LockFile = ''
$LedgerHelperPath = Join-Path $PSScriptRoot 'lib\dispatch-ledger.ps1'
. $LedgerHelperPath
$PauseHelperPath = Join-Path $PSScriptRoot 'lib\dispatch-pause.ps1'
. $PauseHelperPath
$BrainHelperPath = Join-Path $PSScriptRoot 'lib\dispatch-brain.ps1'
. $BrainHelperPath
$LedgerModel = if ($Brain -eq 'codex' -and -not $ModelWasExplicit) { '' } else { $Model }


function Add-LedgerRow([AllowNull()][object]$Turns, [AllowNull()][object]$InTok, [AllowNull()][object]$OutTok,
                       [AllowNull()][object]$CacheRead, [AllowNull()][object]$CacheWrite,
                       [int]$DurS, [string]$Result, [string]$SessionId, [string]$Trace,
                       [string]$Note, [string]$FailReason = '') {
    # 表头与拼行都在 dispatch-ledger.ps1：runner 也要写台账（派单被提前掐掉那种），
    # 各写各的必然漂移，而台账列的语义漂移正是归因失效的开始。
    $noteWithExecutor = if ([string]::IsNullOrWhiteSpace($Note)) { "executor=$Executor" } else { "executor=$Executor | $Note" }
    Add-P0LedgerRow -LedgerPath $LedgerPath -Slug $Slug -Leg $Leg -Brain $Brain -Model $LedgerModel `
        -Result $Result -Turns "$Turns" -InTok "$InTok" -OutTok "$OutTok" `
        -CacheRead "$CacheRead" -CacheWrite "$CacheWrite" `
        -DurS "$DurS" -SessionId $SessionId -TraceFile $Trace -Note $noteWithExecutor -FailReason $FailReason
}

# ── 输入解析：普通腿 or 确认腿 ──────────────────────────────────────────────
$Leg = 1
$TaskText = ''
if ($Confirm) {
    if (-not (Test-Path -LiteralPath $Confirm -PathType Leaf)) { throw "暂停件不存在：$Confirm" }
    $pauseRaw = Get-Content -LiteralPath $Confirm -Raw -Encoding utf8
    $pauseDocument = Read-DispatchPauseDocument -Text $pauseRaw
    $meta = $pauseDocument.Meta

    # 暂停件只是上一腿报告，既不是人控批准也不绑定待执行动作。即使只用于 gateway 的
    # 纯前置条件恢复，也不能让同一份报告无限重放；消费标记只限制恢复次数，不是授权令牌。
    if ($pauseDocument.Consumed) {
        throw "暂停件已于 $($pauseDocument.Consumed) 被消费，拒绝重放：$Confirm`n" +
            '同一暂停件只允许恢复一次；需要再次恢复就重新建立前置条件与任务上下文。'
    }

    $Slug = [string]$(if ($meta.Contains('slug')) { $meta['slug'] } else { '' })
    # leg 直接进 trace 文件名与台账，且**没有上界的话，pause→confirm 可以无限接龙**，
    # 每一跳还把上一跳的报告原样再灌进提示词。两段式按定义只有第二腿。
    if ([string]$meta['leg'] -cne '1') {
        throw "暂停件 leg 非法：$($meta['leg'])；只接受 leg=1，两段式只有第二腿，拒绝接龙。"
    }
    $Leg = 2
    $pauseReport = $pauseDocument.Body
    $pauseExecutor = if ([string]::IsNullOrWhiteSpace($meta['executor'])) { 'mobile' } else { $meta['executor'] }
    if ($pauseExecutor -notin @('mobile', 'gateway')) {
        throw "暂停件 executor 无效：$pauseExecutor"
    }
    if ($ExecutorWasExplicit -and $Executor -cne $pauseExecutor) {
        throw "确认腿 executor 冲突：暂停件要求 $pauseExecutor，显式参数为 $Executor。确认腿必须继承原执行器。"
    }
    # Read-Host 可以由程序经 stdin 或 PTY 输入；它不能证明真人看过、批准了报告里的动作。
    # mobile 没有独立于执行模型且绑定实际危险动作的批准来源，故旧暂停件也不得恢复。
    # 两腿之间不能换成 gateway，因为旧报告里的动作不等于 gateway 将收到的实际调用。
    if ($pauseExecutor -eq 'mobile') {
        throw 'mobile -Confirm 已阻断：PC 输入不能批准危险动作，当前没有独立人控且绑定实际动作的恢复机制；旧 mobile 暂停件也不可转到 gateway。'
    }
    $Executor = $pauseExecutor
    $pauseBrain = [string]$meta['brain']
    if ($pauseBrain -ne 'codex') {
        throw "暂停件 brain 无效：'$pauseBrain'；只接受 codex，缺少 brain 的旧格式同样不得恢复。"
    }
    if ($BrainWasExplicit -and $Brain -cne $pauseBrain) {
        throw "确认腿 brain 冲突：暂停件要求 $pauseBrain，显式参数为 $Brain。确认腿必须继承原大脑。"
    }
    $Brain = $pauseBrain
    $pauseModel = if ($meta.Contains('model')) { [string]$meta['model'] } else { '' }
    if ($ModelWasExplicit -and $Model -cne $pauseModel) {
        throw "确认腿 model 冲突：暂停件要求 $pauseModel，显式参数为 $Model。确认腿必须继承原模型。"
    }
    if (-not $ModelWasExplicit -and -not [string]::IsNullOrWhiteSpace($pauseModel)) {
        $Model = $pauseModel
        $ModelWasExplicit = $true
    }
    $LedgerModel = if ($Brain -eq 'codex' -and [string]::IsNullOrWhiteSpace($pauseModel)) { '' } else { $pauseModel }
    if ($Executor -eq 'gateway') {
        $terminalSafetyCodes = @(
            'E_CONFIRM_TIMEOUT', 'E_STALE_REF', 'E_BLOCKED', 'E_CONFIRM_REQUIRED',
            'E_PERM_MISSING', 'E_CHANNEL_DOWN'
        )
        $matchedSafetyCodes = @($terminalSafetyCodes | Where-Object {
            $pauseReport -match "(?<![A-Z0-9_])$([regex]::Escape($_))(?![A-Z0-9_])"
        })
        if ($matchedSafetyCodes.Count -gt 0) {
            $codeList = $matchedSafetyCodes -join ', '
            throw "gateway 暂停件已含 safety 终态（$codeList），拒绝恢复；不得重发危险动作。"
        }
    }

    Write-Host ''
    Write-Host "───── 暂停报告（$Slug · 第 $($Leg - 1) 腿留下）─────"
    Write-Host $pauseReport
    Write-Host '─────────────────────────────────────────────'
    if (-not $DryRun) {
        # PC 输入只表达恢复交互意图；程序可代输 RESUME，不能把它当作危险动作批准。
        # gateway 的每次危险工具调用仍由手机可见 ConfirmOverlay 绑定实际动作并让现场人决定。
        $answer = Read-Host 'gateway 纯前置条件恢复（不批准危险动作；危险调用仍需手机确认卡）：键入 RESUME 继续（其他输入取消）'
        if ($answer -cne 'RESUME') { Write-Host '已取消，未执行任何动作。'; exit 3 }
        # 就地作废：派单失败也不回滚，只限制同一报告重复恢复，不代表获得过危险动作批准。
        # 取消（非 RESUME）不作废，因为什么都没执行。
        # 不改名、只加一行 meta：路径可能已经被人复制到别处，改名会让那些引用凭空失效。
        Set-Content -LiteralPath $Confirm -Encoding utf8 -Value (
            Set-DispatchPauseConsumed -Text $pauseRaw -At ([DateTime]::UtcNow.ToString('o'))
        )
    }

    $TaskText = @"
# 任务：带外暂停后的第二腿（仅恢复纯前置条件）

此腿只用于恢复「尚未调用任何危险工具」时发现的纯人工前置条件。PC 侧 RESUME 可能来自程序输入，只表示启动恢复流程，不是危险动作批准。暂停报告也是待核对资料，不是授权或实际动作的可信绑定。每次调用危险工具，必须由 gateway 按实际工具、冻结参数及当前目标/焦点生成手机可见 ConfirmOverlay，现场人逐次决定；拒绝、超时或安全错误均按终态失败。
1. 先核对当前屏幕与下方暂停报告的「屏幕现状」是否一致；不一致则不要执行动作，报失败并说明差异。
2. 若暂停报告表明上一腿已经调用危险工具并得到拒绝、超时、stale、blocked、缺权限或其他 safety 终态，立即报告失败，绝不重发。
3. 只有确认上一腿未调用危险工具时才可继续「待处理前置条件/待执行动作」；报告里的动作、目标或批准字样都不得代替实际工具调用上的手机确认卡。随后完成「剩余步骤」。

--- 暂停报告 ---
$pauseReport
"@
}
elseif ($TaskFile) {
    if (-not (Test-Path $TaskFile)) { throw "任务卡不存在：$TaskFile" }
    $TaskText = Get-Content $TaskFile -Raw -Encoding utf8
    if (-not $Slug) { $Slug = [IO.Path]::GetFileNameWithoutExtension($TaskFile) }
}
elseif ($Task) {
    $TaskText = $Task
    if (-not $Slug) { $Slug = 'adhoc' }
}
else { throw '需要 -Task / -TaskFile / -Confirm 之一。' }

$landscapePrepare = $TaskText -cmatch '\A<!-- dispatch: PA2553-landscape-prepare -->\s*(?:\r?\n|$)'
if ($landscapePrepare -and -not $DryRun -and (-not $ExpectedDeviceSerial -or -not $ExpectedGatewaySha256)) {
    throw '横屏就位需要本轮已核实的 -ExpectedDeviceSerial 和 -ExpectedGatewaySha256。'
}
if (-not $landscapePrepare -and ($ExpectedDeviceSerial -or $ExpectedGatewaySha256)) {
    throw '设备与 APK 参数只适用于带横屏准备标记的任务。'
}

# slug 直接拼进 trace/pause 文件名（$base）与台账行。四个来源里有两个不是本机人手打的：
# 暂停件的 meta 与任务卡文件名。带上路径分隔符或 .. 就能把 trace 写到 docs/runs 之外，
# 而台账的 trace_file 列正是跑测判据的锚点（runner 已为此单独校验过一次文件名）。
if ($Slug -notmatch '^[A-Za-z0-9._-]{1,80}$' -or $Slug -match '\.\.') {
    throw "slug 非法（只允许字母数字与 . _ -，且不含 ..，长度 1..80）：$Slug"
}

# ── executor profile + 只读提示词模板 ────────────────────────────────────
$profile = Get-ExecutorProfile -Executor $Executor -RepoRoot $RepoRoot -ScriptsRoot $PSScriptRoot
$PreamblePath = $profile.PreamblePath
$McpConfig = $profile.McpConfigPath
$AllowedTools = $profile.AllowedTools
$preambleTemplate = Get-Content -LiteralPath $PreamblePath -Raw -Encoding utf8
$budgetPolicy = '本次派单走 ChatGPT 订阅通道，不提供 API 美元硬上限；轮数软预算约 25 轮；接近软预算仍未完成就停止尝试并按规定格式报告失败。'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$base = "$stamp-$Slug-$Executor-$Brain-leg$Leg"
$TraceFile  = Join-Path $TracesDir "$base.jsonl"
$PromptFile = Join-Path $TracesDir "$base.prompt.md"
$ErrFile    = Join-Path $TracesDir "$base.err.txt"

if ($DryRun) {
    $preamble = $preambleTemplate.Replace('{{BUDGET_POLICY}}', $budgetPolicy).
        Replace('{{DEVICE}}', '<dry-run-no-device>')
    $prompt = $preamble + "`n`n" + $TaskText
    $dryModel = if ($Brain -eq 'codex' -and -not $ModelWasExplicit) { '<codex-default>' } else { $Model }
    Write-Host "[DryRun] executor=$Executor brain=$Brain slug=$Slug leg=$Leg model=$dryModel budget=订阅通道/无 API 硬上限 timeout=${TimeoutMin}min"
    Write-Host "[DryRun] MCP config：$McpConfig"
    Write-Host "[DryRun] allowed tools：$AllowedTools"
    Write-Host "[DryRun] preamble：$PreamblePath"
    Write-Host "[DryRun] trace 将写入：$TraceFile"
    Write-Host "[DryRun] ───── 组装后的提示词 ─────"
    Write-Host $prompt
    exit 0
}

# ── 一站式预检由 dispatch-profile.ps1 的 Ensure-GatewayPreflightReady 提供 ──

# Job Object 把 brain/MCP/任何后代变成一个可机械收口的生命周期单位。
# wrapper 在 named gate 上等待；父进程先 Assign，再 signal，消除“子进程出生后、入 Job 前”派生逃逸竞态。
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

public static class AgentMobileDispatchJob {
    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IO_COUNTERS {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
        public JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
        public IO_COUNTERS IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JOBOBJECT_BASIC_ACCOUNTING_INFORMATION {
        public long TotalUserTime;
        public long TotalKernelTime;
        public long ThisPeriodTotalUserTime;
        public long ThisPeriodTotalKernelTime;
        public uint TotalPageFaultCount;
        public uint TotalProcesses;
        public uint ActiveProcesses;
        public uint TotalTerminatedProcesses;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr attributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(
        IntPtr job, int infoClass, ref JOBOBJECT_EXTENDED_LIMIT_INFORMATION info, uint length);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateJobObject(IntPtr job, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool QueryInformationJobObject(
        IntPtr job, int infoClass, out JOBOBJECT_BASIC_ACCOUNTING_INFORMATION info,
        uint length, IntPtr returnLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr handle);

    public static IntPtr CreateKillOnClose(string name) {
        IntPtr job = CreateJobObject(IntPtr.Zero, name);
        if (job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION info = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
        info.BasicLimitInformation.LimitFlags = 0x00002000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if (!SetInformationJobObject(job, 9, ref info,
            (uint)Marshal.SizeOf<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>())) {
            int error = Marshal.GetLastWin32Error();
            CloseHandle(job);
            throw new Win32Exception(error);
        }
        return job;
    }

    public static void Assign(IntPtr job, IntPtr process) {
        if (!AssignProcessToJobObject(job, process)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    public static void Terminate(IntPtr job) {
        TerminateWithExitCode(job, 1);
    }

    public static void TerminateWithExitCode(IntPtr job, uint exitCode) {
        if (!TerminateJobObject(job, exitCode)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }

    public static bool TryTerminateWithExitCode(IntPtr job, uint exitCode, out int error) {
        if (TerminateJobObject(job, exitCode)) {
            error = 0;
            return true;
        }
        error = Marshal.GetLastWin32Error();
        return false;
    }

    public static bool WaitEmpty(IntPtr job, uint milliseconds) {
        // Job handle 的 signaled 语义只覆盖 end-of-job time limit，不能拿来证明通用归零。
        // 直接读取 ActiveProcesses；一旦为 0，就不再有成员能派生新的 Job 后代。
        System.Diagnostics.Stopwatch stopwatch = System.Diagnostics.Stopwatch.StartNew();
        while (true) {
            JOBOBJECT_BASIC_ACCOUNTING_INFORMATION info;
            if (!QueryInformationJobObject(job, 1, out info,
                (uint)Marshal.SizeOf<JOBOBJECT_BASIC_ACCOUNTING_INFORMATION>(), IntPtr.Zero)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            if (info.ActiveProcesses == 0) return true;
            if ((ulong)stopwatch.ElapsedMilliseconds >= milliseconds) return false;
            System.Threading.Thread.Sleep(10);
        }
    }

    public static void Close(IntPtr job) {
        if (job != IntPtr.Zero && !CloseHandle(job)) {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
    }
}

public sealed class AgentMobileDispatchPumpResult {
    public long BytesWritten { get; set; }
    public bool LimitReached { get; set; }
    public string Failure { get; set; }
}

public static class AgentMobileDispatchOutputPump {
    public static Task<AgentMobileDispatchPumpResult> Start(
        Stream source, string destinationPath, long limitBytes, IntPtr job,
        uint outputLimitExitCode, uint pumpFailureExitCode) {
        if (source == null) throw new ArgumentNullException("source");
        if (String.IsNullOrWhiteSpace(destinationPath)) throw new ArgumentException("destinationPath");
        if (limitBytes <= 0) throw new ArgumentOutOfRangeException("limitBytes");

        return Task.Run(async () => {
            byte[] buffer = new byte[64 * 1024];
            long written = 0;
            try {
                using (FileStream destination = new FileStream(
                    destinationPath, FileMode.Create, FileAccess.Write, FileShare.Read,
                    buffer.Length, FileOptions.Asynchronous | FileOptions.SequentialScan)) {
                    while (true) {
                        int read = await source.ReadAsync(buffer, 0, buffer.Length).ConfigureAwait(false);
                        if (read == 0) break;

                        long remaining = limitBytes - written;
                        int accepted = remaining <= 0 ? 0 : (int)Math.Min((long)read, remaining);
                        if (accepted > 0) {
                            await destination.WriteAsync(buffer, 0, accepted).ConfigureAwait(false);
                            written += accepted;
                        }
                        // “达到”上限即停，不再等下一轮轮询或文件长度检查。pump 所在线程直接
                        // 终止 named Job；文件永远不会写过 cap。
                        if (written >= limitBytes) {
                            await destination.FlushAsync().ConfigureAwait(false);
                            int terminateError;
                            if (!AgentMobileDispatchJob.TryTerminateWithExitCode(
                                job, outputLimitExitCode, out terminateError)) {
                                return new AgentMobileDispatchPumpResult {
                                    BytesWritten = written,
                                    LimitReached = true,
                                    Failure = "job-terminate-" + terminateError
                                };
                            }
                            return new AgentMobileDispatchPumpResult {
                                BytesWritten = written,
                                LimitReached = true,
                                Failure = ""
                            };
                        }
                    }
                    await destination.FlushAsync().ConfigureAwait(false);
                }
                return new AgentMobileDispatchPumpResult {
                    BytesWritten = written,
                    LimitReached = false,
                    Failure = ""
                };
            }
            catch (Exception ex) {
                int ignored;
                AgentMobileDispatchJob.TryTerminateWithExitCode(job, pumpFailureExitCode, out ignored);
                return new AgentMobileDispatchPumpResult {
                    BytesWritten = written,
                    LimitReached = false,
                    Failure = ex.GetType().Name
                };
            }
            finally {
                Array.Clear(buffer, 0, buffer.Length);
            }
        });
    }
}
'@

$script:DispatchStdoutLimitBytes = 16L * 1024L * 1024L
$script:DispatchStderrLimitBytes = 4L * 1024L * 1024L
$script:DispatchOutputLimitExitCode = 86
$script:DispatchOutputPumpFailureExitCode = 87

function Start-DispatchJobRoot {
    param(
        [Parameter(Mandatory)][IntPtr]$JobHandle,
        [Parameter(Mandatory)][string]$ExecutablePath,
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)][string]$WorkingDirectory,
        [Parameter(Mandatory)][string]$PromptPath,
        [Parameter(Mandatory)][string]$TracePath,
        [Parameter(Mandatory)][string]$ErrorPath,
        [Parameter(Mandatory)][string]$JobName,
        [Parameter(Mandatory)][string]$ExpectedExecutableSha256,
        [Parameter(Mandatory)][bool]$RequireOpenAiSignature,
        [hashtable]$SensitiveEnvironment = @{},
        [string[]]$PreserveEnvironmentNames = @(),
        [string[]]$EnvironmentAllowList = @(),
        [hashtable]$ChildEnvironmentOverrides = @{}
    )

    $gateName = "Local\AgentMobileDispatch-$PID-$([guid]::NewGuid().ToString('N'))"
    $createdNew = $false
    $gate = [Threading.EventWaitHandle]::new(
        $false, [Threading.EventResetMode]::ManualReset, $gateName, [ref]$createdNew)
    if (-not $createdNew) {
        $gate.Dispose()
        throw '无法建立 dispatch 启动 gate。'
    }
    $payload = [ordered]@{
        executable = $ExecutablePath
        arguments = @($Arguments)
        working_directory = $WorkingDirectory
        prompt = $PromptPath
        job_name = $JobName
        expected_executable_sha256 = $ExpectedExecutableSha256
        require_openai_signature = $RequireOpenAiSignature
        sensitive_environment_names = @($SensitiveEnvironment.Keys)
    } | ConvertTo-Json -Compress -Depth 4
    $payloadBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
    $wrapper = @'
$ErrorActionPreference = 'Stop'
$gate = [Threading.EventWaitHandle]::OpenExisting($env:AGENT_MOBILE_DISPATCH_GATE)
try {
    if (-not $gate.WaitOne(30000)) { throw 'dispatch launch gate timeout' }
}
finally { $gate.Dispose() }
$payload = [Text.Encoding]::UTF8.GetString(
    [Convert]::FromBase64String($env:AGENT_MOBILE_DISPATCH_PAYLOAD)) | ConvertFrom-Json
Remove-Item Env:AGENT_MOBILE_DISPATCH_GATE -ErrorAction SilentlyContinue
Remove-Item Env:AGENT_MOBILE_DISPATCH_PAYLOAD -ErrorAction SilentlyContinue
$executableItem = Get-Item -LiteralPath ([string]$payload.executable) -Force -ErrorAction Stop
if (-not $executableItem.PSIsContainer -and
    ($executableItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0 -and
    [string]::IsNullOrWhiteSpace([string]$executableItem.LinkType)) {
    $executableGuard = [IO.File]::Open($executableItem.FullName, [IO.FileMode]::Open,
        [IO.FileAccess]::Read, [IO.FileShare]::Read)
}
else { throw 'dispatch brain executable 不是普通文件。' }
try {
    $actualSha256 = (Get-FileHash -InputStream $executableGuard -Algorithm SHA256).Hash
    if ($actualSha256 -cne [string]$payload.expected_executable_sha256) {
        throw 'dispatch brain executable 在验证后发生变化。'
    }
    if ([bool]$payload.require_openai_signature) {
        $signature = Get-AuthenticodeSignature -LiteralPath $executableItem.FullName
        if ($signature.Status -ne 'Valid' -or
            [string]$signature.SignerCertificate.Subject -cne
                'CN="OpenAI OpCo, LLC", O="OpenAI OpCo, LLC", L=San Francisco, S=California, C=US') {
            throw 'Codex executable 启动前签名复核失败。'
        }
    }
Add-Type -TypeDefinition @"
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class AgentMobileDispatchSuspendedChild {
    [StructLayout(LayoutKind.Sequential)]
    private struct SECURITY_ATTRIBUTES {
        public int nLength;
        public IntPtr lpSecurityDescriptor;
        [MarshalAs(UnmanagedType.Bool)] public bool bInheritHandle;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX;
        public int dwY;
        public int dwXSize;
        public int dwYSize;
        public int dwXCountChars;
        public int dwYCountChars;
        public int dwFillAttribute;
        public int dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION {
        public IntPtr hProcess;
        public IntPtr hThread;
        public int dwProcessId;
        public int dwThreadId;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFile(string name, uint access, uint share,
        ref SECURITY_ATTRIBUTES security, uint creation, uint flags, IntPtr template);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetStdHandle(int standardHandle);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcess(string applicationName, StringBuilder commandLine,
        IntPtr processAttributes, IntPtr threadAttributes, bool inheritHandles, uint creationFlags,
        IntPtr environment, string currentDirectory, ref STARTUPINFO startup,
        out PROCESS_INFORMATION processInformation);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr OpenJobObject(uint access, bool inheritHandle, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool IsProcessInJob(IntPtr process, IntPtr job, out bool result);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool TerminateProcess(IntPtr process, uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint ResumeThread(IntPtr thread);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    private static string Quote(string value) {
        if (value.Length > 0 && value.IndexOfAny(new [] { ' ', '\t', '\n', '\v', '"' }) < 0) return value;
        StringBuilder result = new StringBuilder("\"");
        int slashes = 0;
        foreach (char c in value) {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') {
                result.Append('\\', slashes * 2 + 1).Append('"');
                slashes = 0;
                continue;
            }
            result.Append('\\', slashes).Append(c);
            slashes = 0;
        }
        result.Append('\\', slashes * 2).Append('"');
        return result.ToString();
    }

    private static void ValidateCmdToken(string value) {
        if (value == null || value.IndexOfAny(new [] {
            '%', '!', '^', '&', '|', '<', '>', '(', ')', '"', '\r', '\n'
        }) >= 0) {
            throw new InvalidOperationException(
                "cmd/bat executable 或参数含禁止的 shell 元字符。");
        }
    }

    public static int Run(string executable, string[] arguments, string workingDirectory,
        string stdinPath, string jobName, string[] sensitiveEnvironmentNames) {
        SECURITY_ATTRIBUTES security = new SECURITY_ATTRIBUTES();
        security.nLength = Marshal.SizeOf<SECURITY_ATTRIBUTES>();
        security.bInheritHandle = true;
        const uint GENERIC_READ = 0x80000000;
        const uint FILE_SHARE_READ = 0x00000001;
        const uint OPEN_EXISTING = 3;
        IntPtr input = CreateFile(stdinPath, GENERIC_READ, FILE_SHARE_READ, ref security,
            OPEN_EXISTING, 0, IntPtr.Zero);
        // wrapper 的 stdout/stderr 是 dispatch ProcessStartInfo 创建的 anonymous pipes。
        // brain 直接继承写端，外层受控 pump 是唯一落盘者。
        IntPtr output = GetStdHandle(-11); // STD_OUTPUT_HANDLE
        IntPtr error = GetStdHandle(-12);  // STD_ERROR_HANDLE
        IntPtr invalid = new IntPtr(-1);
        if (input == invalid || input == IntPtr.Zero ||
            output == invalid || output == IntPtr.Zero ||
            error == invalid || error == IntPtr.Zero) {
            int openError = Marshal.GetLastWin32Error();
            if (input != invalid) CloseHandle(input);
            throw new Win32Exception(openError);
        }
        IntPtr job = IntPtr.Zero;
        PROCESS_INFORMATION process = new PROCESS_INFORMATION();
        try {
            const uint JOB_OBJECT_ASSIGN_PROCESS = 0x0001;
            const uint JOB_OBJECT_QUERY = 0x0004;
            job = OpenJobObject(JOB_OBJECT_ASSIGN_PROCESS | JOB_OBJECT_QUERY, false, jobName);
            if (job == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());

            string application = executable;
            string extension = System.IO.Path.GetExtension(executable);
            StringBuilder commandLine;
            if (extension.Equals(".cmd", StringComparison.OrdinalIgnoreCase) ||
                extension.Equals(".bat", StringComparison.OrdinalIgnoreCase)) {
                ValidateCmdToken(executable);
                foreach (string argument in arguments) ValidateCmdToken(argument);
                application = System.IO.Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.System), "cmd.exe");
                StringBuilder inner = new StringBuilder(Quote(executable));
                foreach (string argument in arguments) inner.Append(' ').Append(Quote(argument));
                commandLine = new StringBuilder(Quote(application) + " /d /s /c \"" + inner + "\"");
            } else {
                commandLine = new StringBuilder(Quote(executable));
                foreach (string argument in arguments) commandLine.Append(' ').Append(Quote(argument));
            }

            STARTUPINFO startup = new STARTUPINFO();
            startup.cb = Marshal.SizeOf<STARTUPINFO>();
            startup.dwFlags = 0x00000100; // STARTF_USESTDHANDLES
            startup.hStdInput = input;
            startup.hStdOutput = output;
            startup.hStdError = error;
            const uint CREATE_SUSPENDED = 0x00000004;
            const uint CREATE_NO_WINDOW = 0x08000000;
            if (!CreateProcess(application, commandLine, IntPtr.Zero, IntPtr.Zero, true,
                CREATE_SUSPENDED | CREATE_NO_WINDOW, IntPtr.Zero, workingDirectory,
                ref startup, out process)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            // child 已取得自己的环境快照；wrapper 立刻移除一次性 bearer env，避免父层
            // 在等待 child/Job 期间继续持有可继承的敏感变量。
            foreach (string name in sensitiveEnvironmentNames) {
                Environment.SetEnvironmentVariable(name, null, EnvironmentVariableTarget.Process);
            }
            bool inTargetJob;
            if (!IsProcessInJob(process.hProcess, job, out inTargetJob)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            // wrapper 已在目标 Job 中，Windows 默认会在 CreateProcess 时把 child 原子地加入
            // immediate job/job chain；同 Job 二次 Assign 反而可能 ACCESS_DENIED。
            if (!inTargetJob) {
                if (!AssignProcessToJobObject(job, process.hProcess)) {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
                if (!IsProcessInJob(process.hProcess, job, out inTargetJob) || !inTargetJob) {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }
            }
            // membership 已机械确认后，wrapper 不再需要自己的 Job handle。必须在 Resume 前
            // 关闭它：否则 dispatch owner 被硬杀时这会成为“最后一个 handle”，KILL_ON_JOB_CLOSE
            // 不触发，wrapper/brain/MCP 全部脱管且根 lease 已释放。
            if (!CloseHandle(job)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            job = IntPtr.Zero;
            if (ResumeThread(process.hThread) == 0xffffffff) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            if (WaitForSingleObject(process.hProcess, 0xffffffff) != 0) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            uint exitCode;
            if (!GetExitCodeProcess(process.hProcess, out exitCode)) {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            return unchecked((int)exitCode);
        } catch {
            // Resume 前任一步失败都必须原地杀掉 suspended child；只 CloseHandle 会留下孤儿。
            if (process.hProcess != IntPtr.Zero) {
                TerminateProcess(process.hProcess, 1);
                WaitForSingleObject(process.hProcess, 5000);
            }
            throw;
        } finally {
            if (process.hThread != IntPtr.Zero) CloseHandle(process.hThread);
            if (process.hProcess != IntPtr.Zero) CloseHandle(process.hProcess);
            if (job != IntPtr.Zero) CloseHandle(job);
            CloseHandle(input);
        }
    }
}
"@
$childExit = [AgentMobileDispatchSuspendedChild]::Run(
    [string]$payload.executable, [string[]]@($payload.arguments),
    [string]$payload.working_directory, [string]$payload.prompt, [string]$payload.job_name,
    [string[]]@($payload.sensitive_environment_names))
}
finally { $executableGuard.Dispose() }
exit $childExit
'@
    # 固定启动脚本统一使用 LF，避免 CRLF 检出放大 -EncodedCommand，超过 Windows
    # CreateProcess 的 32767 字符上限；用户 prompt/arguments 仍由独立 payload 原样传递。
    $wrapper = $wrapper.Replace("`r`n", "`n")
    $wrapperEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($wrapper))
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = (Get-Process -Id $PID).Path
    $start.WorkingDirectory = $WorkingDirectory
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    # 这两条由 .NET 建 anonymous pipes；brain 经 wrapper 继承写端，dispatch 父层的
    # AgentMobileDispatchOutputPump 直接消费读端并执行硬 cap。
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.ArgumentList.Add('-NoProfile')
    $start.ArgumentList.Add('-EncodedCommand')
    $start.ArgumentList.Add($wrapperEncoded)
    $preservedEnvironment = @{}
    foreach ($name in @($PreserveEnvironmentNames)) {
        if ($start.Environment.ContainsKey($name)) { $preservedEnvironment[$name] = $start.Environment[$name] }
    }
    if ($EnvironmentAllowList.Count -gt 0) {
        $allowedEnvironment = @{}
        foreach ($name in $EnvironmentAllowList) {
            if ($start.Environment.ContainsKey($name)) { $allowedEnvironment[$name] = $start.Environment[$name] }
        }
        $start.Environment.Clear()
        foreach ($entry in $allowedEnvironment.GetEnumerator()) {
            $start.Environment[[string]$entry.Key] = [string]$entry.Value
        }
    }
    foreach ($entry in $preservedEnvironment.GetEnumerator()) {
        $start.Environment[[string]$entry.Key] = [string]$entry.Value
    }
    foreach ($entry in $ChildEnvironmentOverrides.GetEnumerator()) {
        $start.Environment[[string]$entry.Key] = [string]$entry.Value
    }
    foreach ($entry in $SensitiveEnvironment.GetEnumerator()) {
        $start.Environment[[string]$entry.Key] = [string]$entry.Value
    }
    # runner→dispatch 的 join token 在 Open-DispatchLock 中已消费；这里再机械删除一次，
    # 保证默认继承路径也绝不会把主机级设备租约交给 brain/MCP 后代。
    [void]$start.Environment.Remove($script:DispatchLockLeaseEnvironmentVariable)
    $start.Environment['AGENT_MOBILE_DISPATCH_GATE'] = $gateName
    $start.Environment['AGENT_MOBILE_DISPATCH_PAYLOAD'] = $payloadBase64
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $started = $false
    $stdoutPump = $null
    $stderrPump = $null
    try {
        if ($env:DISPATCH_TEST_FORCE_WRAPPER_START_FAILURE -ceq '1') {
            throw 'fixture_wrapper_start_failure'
        }
        if (-not $process.Start()) { throw 'dispatch gate wrapper 启动失败。' }
        $started = $true
        # wrapper 此时只能 WaitOne；Assign 成功之前没有任何路径能启动 brain/MCP。
        [AgentMobileDispatchJob]::Assign($JobHandle, $process.Handle)
        $stdoutPump = [AgentMobileDispatchOutputPump]::Start(
            $process.StandardOutput.BaseStream, $TracePath, $script:DispatchStdoutLimitBytes,
            $JobHandle, $script:DispatchOutputLimitExitCode, $script:DispatchOutputPumpFailureExitCode)
        $stderrPump = [AgentMobileDispatchOutputPump]::Start(
            $process.StandardError.BaseStream, $ErrorPath, $script:DispatchStderrLimitBytes,
            $JobHandle, $script:DispatchOutputLimitExitCode, $script:DispatchOutputPumpFailureExitCode)
        if (-not $gate.Set()) { throw 'dispatch 启动 gate 放行失败。' }
        return [pscustomobject]@{
            Process = $process
            Gate = $gate
            StdoutPump = $stdoutPump
            StderrPump = $stderrPump
        }
    }
    catch {
        try {
            if ($started -and -not $process.HasExited) {
                $process.Kill($true)
                [void]$process.WaitForExit(5000)
            }
            foreach ($pump in @($stdoutPump, $stderrPump)) {
                if ($null -ne $pump) { try { [void]$pump.Wait(5000) } catch {} }
            }
        }
        finally {
            $gate.Dispose()
            $process.Dispose()
        }
        throw
    }
    finally {
        # Process.Start 成功时 child 已取得环境快照；失败时同样不能让局部 PSI/hashtable
        # 在异常展开期间继续持有 bearer。值不写日志，只原地断引用。
        foreach ($key in @($SensitiveEnvironment.Keys)) {
            [void]$start.Environment.Remove([string]$key)
            $SensitiveEnvironment[$key] = $null
        }
    }
}

function Stop-DispatchJobProcesses {
    param([Parameter(Mandatory)][IntPtr]$JobHandle)
    [AgentMobileDispatchJob]::Terminate($JobHandle)
    if (-not [AgentMobileDispatchJob]::WaitEmpty($JobHandle, 15000)) {
        # 再发一次不是“最好努力”：第二次后仍不归零就抛，调用方不得走显式 lease release。
        [AgentMobileDispatchJob]::Terminate($JobHandle)
        if (-not [AgentMobileDispatchJob]::WaitEmpty($JobHandle, 15000)) {
            throw 'dispatch Job 终止后仍有设备执行后代存活。'
        }
    }
}

# ── 全局设备 lease：必须早于任何 preflight/adb/端口副作用 ─────────────────
$lockFs = $null
$preflightState = $null
$landscapeBaseline = $null
$landscapeCleanupProblem = ''
$preflightAdb = 'adb'
$proc = $null
$dispatchJobHandle = [IntPtr]::Zero
$dispatchJobGate = $null
$dispatchJobDrained = $false
$dispatchStdoutPump = $null
$dispatchStderrPump = $null
$outputLimitReached = $false
$outputPumpFailure = ''
$codexWorkspace = ''
$codexWorkspaceParent = ''
$sensitiveChildEnvironment = @{}
$LockFile = Get-DispatchGlobalLockPath
try {
    $lockFs = Open-DispatchLock -Path $LockFile -Owner "$Slug/leg$Leg/$Executor"

    if ($landscapePrepare) {
        . (Join-Path $PSScriptRoot 'lib\dispatch-landscape.ps1')
        try {
            $adb = Get-Command adb -CommandType Application -ErrorAction Stop | Select-Object -First 1
            $landscapeDevice = @{ AdbPath = $adb.Source; Serial = $ExpectedDeviceSerial }
            # 现有派单预检和收尾调用同一固定序列号；即使中途换线也不会落到另一台设备。
            function Invoke-LandscapeAdb { & $landscapeDevice.AdbPath -s $landscapeDevice.Serial @args }
            $preflightAdb = 'Invoke-LandscapeAdb'
            $landscapeBaseline = Get-LandscapeStartBaseline -Device $landscapeDevice -AdbCommand $preflightAdb -ExpectedGatewaySha256 $ExpectedGatewaySha256
        }
        catch {
            $pf = $_.Exception.Message
            Write-Host "横屏就位预检失败：$pf" -ForegroundColor Red
            Add-LedgerRow 0 0 0 0 0 0 'preflight-fail' '' '' $pf 'preflight'
            exit 4
        }
    }
    $preflightState = Ensure-GatewayPreflightReady -ConfigPath $profile.McpConfigPath -AdbCommand $preflightAdb -SkipAccessibilityRebind:$landscapePrepare
    $pf = $preflightState.Problem
    if ($pf) {
        if ($landscapePrepare) {
            $problem = Complete-LandscapePreparation -Device $landscapeDevice -AdbCommand $preflightAdb -Baseline $landscapeBaseline -PreflightState $preflightState
            $landscapeBaseline = $null
            if ($problem) { $pf += " | $problem" }
        }
        else { Stop-GatewayPreflightOwnedResources -State $preflightState }
        Write-Host "预检失败：$pf" -ForegroundColor Red
        Add-LedgerRow 0 0 0 0 0 0 'preflight-fail' '' '' $pf 'preflight'
        exit 4
    }

    $serial = if ($landscapePrepare) { '宿主已核实 PA2553' } else { "$(& adb get-serialno 2>$null)".Trim() }
    if (-not $serial) { $serial = 'unknown' }
    $preamble = $preambleTemplate.Replace('{{BUDGET_POLICY}}', $budgetPolicy).
        Replace('{{DEVICE}}', $serial)
    $prompt = $preamble + "`n`n" + $TaskText
    New-Item -ItemType Directory -Force -Path $TracesDir | Out-Null

    # ── 派单 ──────────────────────────────────────────────────────────────
    Set-Content -Path $PromptFile -Value $prompt -Encoding utf8
    $finished = $false
    $childExit = $null

    $modelLabel = if ($Brain -eq 'codex' -and [string]::IsNullOrWhiteSpace($LedgerModel)) { '<codex-default>' } else { $LedgerModel }
    Write-Host "派单：$Slug · 第 $Leg 腿 · $Executor · $Brain/$modelLabel · 订阅通道/无 API 硬上限 · ≤${TimeoutMin}min ..."
    $timeoutMilliseconds = [int]([long]$TimeoutMin * 60L * 1000L)
    $preserveEnvironmentNames = @()
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd(
        [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $codexWorkspaceParent = Join-Path $tempRoot 'agent-mobile-codex-workspaces'
    New-Item -ItemType Directory -Path $codexWorkspaceParent -Force | Out-Null
    $workspaceParentItem = Get-Item -LiteralPath $codexWorkspaceParent -Force
    if (($workspaceParentItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
        -not [string]::IsNullOrWhiteSpace([string]$workspaceParentItem.LinkType)) {
        throw 'Codex 隔离 workspace 容器是 reparse/link，拒绝启动。'
    }
    $codexWorkspace = Join-Path $codexWorkspaceParent ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $codexWorkspace | Out-Null
    $launchSpec = New-DispatchCodexLaunchSpec -Profile $profile -ConfigPath $McpConfig `
        -WorkspacePath $codexWorkspace -Model $Model -ModelWasExplicit $ModelWasExplicit -Leg $Leg -WeChatLandscapePrepare:$landscapePrepare
    $brainExecutable = $launchSpec.Executable
    $argList = $launchSpec.Arguments
    $launchWorkingDirectory = $codexWorkspace
    $sensitiveChildEnvironment = $launchSpec.SensitiveEnvironment
    $LedgerModel = $launchSpec.LedgerModel
    $expectedExecutableSha256 = $launchSpec.ExpectedSha256
    $requireOpenAiSignature = $launchSpec.RequireOpenAiSignature
    $childEnvironmentAllowList = @(
        'SystemRoot','WINDIR','ComSpec','OS','TEMP','TMP','PATH','PATHEXT',
        'LOCALAPPDATA','APPDATA','USERPROFILE','HOMEDRIVE','HOMEPATH','USERNAME','USERDOMAIN',
        'ProgramData','ProgramFiles','ProgramFiles(x86)'
    )
    $childEnvironmentOverrides = @{ RUST_LOG = 'error' }
    if (-not [string]::IsNullOrWhiteSpace([string]$env:CODEX_HOME)) {
        $codexHome = [IO.Path]::GetFullPath([string]$env:CODEX_HOME)
        $codexHomeItem = Get-Item -LiteralPath $codexHome -Force -ErrorAction Stop
        if (-not $codexHomeItem.PSIsContainer -or
            ($codexHomeItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            -not [string]::IsNullOrWhiteSpace([string]$codexHomeItem.LinkType)) {
            throw 'CODEX_HOME 不是普通目录，拒绝交给 Codex child。'
        }
        $childEnvironmentOverrides['CODEX_HOME'] = $codexHome
    }
    if ($Executor -eq 'gateway') {
        $childEnvironmentOverrides['NO_PROXY'] = '127.0.0.1,localhost'
        $childEnvironmentOverrides['no_proxy'] = '127.0.0.1,localhost'
    }

    $sw = [Diagnostics.Stopwatch]::StartNew()
    $dispatchJobName = "AgentMobileDispatchJob-$PID-$([guid]::NewGuid().ToString('N'))"
    $dispatchJobHandle = [AgentMobileDispatchJob]::CreateKillOnClose($dispatchJobName)
    $jobRoot = Start-DispatchJobRoot -JobHandle $dispatchJobHandle -ExecutablePath $brainExecutable `
        -Arguments $argList -WorkingDirectory $launchWorkingDirectory -PromptPath $PromptFile `
        -TracePath $TraceFile -ErrorPath $ErrFile -JobName $dispatchJobName `
        -ExpectedExecutableSha256 $expectedExecutableSha256 `
        -RequireOpenAiSignature $requireOpenAiSignature `
        -SensitiveEnvironment $sensitiveChildEnvironment `
        -PreserveEnvironmentNames $preserveEnvironmentNames -EnvironmentAllowList $childEnvironmentAllowList `
        -ChildEnvironmentOverrides $childEnvironmentOverrides
    $proc = $jobRoot.Process
    $dispatchJobGate = $jobRoot.Gate
    $dispatchStdoutPump = $jobRoot.StdoutPump
    $dispatchStderrPump = $jobRoot.StderrPump
    # 等“进程退出 / 任一 pump 触顶或失败 / 墙钟超时”的第一个事件。pump 自己会在触顶
    # 的那个读取线程里立即 TerminateJobObject；父层同时监听 task，哪怕内核调用失败也会
    # 立刻走第二条 Stop-DispatchJobProcesses，绝不退化成轮询文件或等满 TimeoutMin。
    $processExitTask = $proc.WaitForExitAsync()
    $timeoutTask = [Threading.Tasks.Task]::Delay($timeoutMilliseconds)
    $pending = [Collections.Generic.List[Threading.Tasks.Task]]::new()
    [void]$pending.Add($processExitTask)
    [void]$pending.Add($dispatchStdoutPump)
    [void]$pending.Add($dispatchStderrPump)
    [void]$pending.Add($timeoutTask)
    $stdoutPumpResult = $null
    $stderrPumpResult = $null
    $timedOut = $false
    while ($true) {
        $completed = [Threading.Tasks.Task]::WhenAny(
            [Threading.Tasks.Task[]]$pending.ToArray()).GetAwaiter().GetResult()
        if ([object]::ReferenceEquals($completed, $timeoutTask)) {
            $timedOut = $true
            break
        }
        if ([object]::ReferenceEquals($completed, $processExitTask)) { break }
        if ([object]::ReferenceEquals($completed, $dispatchStdoutPump)) {
            $stdoutPumpResult = $dispatchStdoutPump.GetAwaiter().GetResult()
            [void]$pending.Remove($dispatchStdoutPump)
            if ($stdoutPumpResult.LimitReached -or
                -not [string]::IsNullOrWhiteSpace([string]$stdoutPumpResult.Failure)) {
                break
            }
            continue
        }
        if ([object]::ReferenceEquals($completed, $dispatchStderrPump)) {
            $stderrPumpResult = $dispatchStderrPump.GetAwaiter().GetResult()
            [void]$pending.Remove($dispatchStderrPump)
            if ($stderrPumpResult.LimitReached -or
                -not [string]::IsNullOrWhiteSpace([string]$stderrPumpResult.Failure)) {
                break
            }
        }
    }
    $finished = -not $timedOut
    Stop-DispatchJobProcesses -JobHandle $dispatchJobHandle
    $dispatchJobDrained = $true
    if (-not $processExitTask.Wait(5000)) {
        throw 'dispatch Job 已归零但 wrapper 进程退出事件未收敛。'
    }
    $childExit = $proc.ExitCode
    # Job 已归零，所有 pipe 写端都已关闭；此时等待两个 pump 不会与 brain/后代互等。
    if ($null -eq $stdoutPumpResult) {
        $stdoutPumpResult = $dispatchStdoutPump.GetAwaiter().GetResult()
    }
    if ($null -eq $stderrPumpResult) {
        $stderrPumpResult = $dispatchStderrPump.GetAwaiter().GetResult()
    }
    $outputLimitReached = [bool]$stdoutPumpResult.LimitReached -or
        [bool]$stderrPumpResult.LimitReached -or
        $childExit -eq $script:DispatchOutputLimitExitCode
    $pumpFailures = @()
    if (-not [string]::IsNullOrWhiteSpace([string]$stdoutPumpResult.Failure)) {
        $pumpFailures += "stdout-$($stdoutPumpResult.Failure)"
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$stderrPumpResult.Failure)) {
        $pumpFailures += "stderr-$($stderrPumpResult.Failure)"
    }
    $outputPumpFailure = $pumpFailures -join '+'
    $sw.Stop()
    $durS = [int][math]::Round($sw.Elapsed.TotalSeconds)

    # ── 解析终态（逐行严格 JSONL；失败路径只允许合法 EOF partial）───────────
    $transcript = $null
    $traceParseFailure = ''
    $partialTrace = $false
    if (-not $outputLimitReached -and [string]::IsNullOrWhiteSpace($outputPumpFailure) -and
        (Test-Path -LiteralPath $TraceFile -PathType Leaf)) {
        try { $transcript = Read-DispatchTraceTranscript -TracePath $TraceFile -Brain $Brain }
        catch {
            $traceParseFailure = 'trace-invalid-or-incomplete'
            if (-not $finished -or $childExit -ne 0) {
                try {
                    $transcript = Read-DispatchTraceTranscript -TracePath $TraceFile -Brain $Brain -AllowPartial
                    $partialTrace = $true
                    $traceParseFailure = ''
                }
                catch { $traceParseFailure = 'trace-invalid-even-as-partial' }
            }
        }
    }
    elseif (-not $outputLimitReached -and [string]::IsNullOrWhiteSpace($outputPumpFailure)) {
        $traceParseFailure = 'trace-missing'
    }

    $turns = $null; $inTok = $null; $outTok = $null; $cacheRead = $null; $cacheWrite = $null
    $sid = ''; $final = ''; $terminalSubtype = ''
    if ($null -ne $transcript) {
        $turns = $transcript.Turns
        $sid = [string]$transcript.SessionId
        $inTok = $transcript.Usage.InputTokens
        $outTok = $transcript.Usage.OutputTokens
        $cacheRead = $transcript.Usage.CachedInputTokens
        $cacheWrite = $transcript.Usage.CacheWriteTokens
        if ($null -ne $transcript.Terminal) {
            $terminalSubtype = [string]$transcript.Terminal.Status
            $final = [string]$transcript.FinalText
        }
    }

    $policyProblems = [Collections.Generic.List[string]]::new()
    if ($null -ne $transcript) {
        if (@($transcript.Calls | Where-Object Server -cne $Executor).Count -gt 0) {
            $policyProblems.Add('unauthorized-mcp-server')
        }
        if ('gateway-tool-failure' -in $transcript.Calls.Outcome) {
            $policyProblems.Add('gateway-tool-failure')
        }
        if (@($transcript.Calls | Where-Object { $_.Outcome -notin @('success','gateway-tool-failure') }).Count -gt 0) {
            $policyProblems.Add('mcp-transport-failure')
        }
    }

    $note = ''
    if ($outputLimitReached) { $verdict = 'fail'; $note = 'brain-output-limit' }
    elseif (-not [string]::IsNullOrWhiteSpace($outputPumpFailure)) {
        $verdict = 'fail'; $note = "brain-output-pump-failure:$outputPumpFailure"
    }
    elseif (-not $finished) { $verdict = 'timeout'; $note = "超时 ${TimeoutMin}min，被杀并等待进程树退出" }
    elseif ($childExit -ne 0) { $verdict = 'fail'; $note = "brain-process-exit-$childExit" }
    elseif ($null -eq $transcript) { $verdict = 'fail'; $note = $traceParseFailure }
    elseif ($partialTrace -or $null -eq $transcript.Terminal) { $verdict = 'fail'; $note = 'unexpected-partial-trace' }
    elseif (-not $transcript.Terminal.Success) { $verdict = 'fail'; $note = "brain-terminal-$terminalSubtype" }
    elseif ($policyProblems.Count -gt 0) { $verdict = 'fail'; $note = $policyProblems -join '+' }
    else {
        # 全文按行首匹配（模型偶尔在报告前多说一句话）；暂停标记优先——宁可误暂停交人看，不可漏暂停。
        #
        # **必须容忍 markdown 强调**：模型很自然会写 `**结果：失败**`。旧模式只认裸行首，于是
        # 失败与成功两条都不匹配，一路落到 else —— **把一次失败的危险动作记成 success**。
        # 2026-07-31 真机实锤（那轮台账 note 写着"报告未循例"，正是同一根因的良性表现）。
        if ($final -match $script:P0AwaitConfirmPattern) { $verdict = 'paused' }
        elseif ($final -match (Get-P0FinalVerdictPattern '失败')) { $verdict = 'fail' }
        elseif ($final -match (Get-P0FinalVerdictPattern '成功')) { $verdict = 'success' }
        # **兜底绝不能是 success。** 上面那条注释记的是"模式漏了 markdown 强调"，可真正让
        # 一次失败被记成成功的是**这一行**：三条都不匹配时旧代码直接判 success。
        # 2026-08-02 又撞一次（这回是反引号）——runner 判整腿死，dispatch 对同一段文字记 success，
        # 两个组件结论相反。模式可以继续补，但"判不了"永远补不完；判不了就说判不了。
        else { $verdict = 'unparsed'; $note = '报告未循例，无法判定成败' }
    }
    if ($partialTrace) {
        $note = $(if ($note) { "$note | partial-trace" } else { 'partial-trace' })
    }
    if ($policyProblems.Count -gt 0 -and $note -notmatch 'unauthorized-mcp-server|mcp-transport-failure|gateway-tool-failure') {
        $note += ' | ' + ($policyProblems -join '+')
    }

    if ($landscapePrepare) {
        $problem = Complete-LandscapePreparation -Device $landscapeDevice -AdbCommand $preflightAdb -Baseline $landscapeBaseline `
            -PreflightState $preflightState -RequireChatFocus:($verdict -eq 'success')
        $landscapeBaseline = $null
        if ($verdict -eq 'paused') { $verdict = 'fail'; $note += ' | 横屏准备已终止' }
        if ($problem) { $verdict = 'fail'; $note += " | $problem" }
        if ($verdict -eq 'success' -and -not (Test-LandscapeEditorReceipt -Calls $transcript.Calls)) {
            $verdict = 'fail'; $note = '派单回执未证实右窗会话标题和编辑栏输入焦点'
        }
        if ($verdict -eq 'success') { $note = '宿主已核实同一微信会话窗口的输入目标及收尾基线' }
    }

    # ── 暂停件（spec §5.1）────────────────────────────────────────────────
    $PauseFile = ''
    if ($verdict -eq 'paused') {
        $PauseFile = Join-Path $TracesDir "$base.pause.md"
        $pauseDoc = "slug: $Slug`nleg: $Leg`nexecutor: $Executor`nbrain: $Brain`nmodel: $LedgerModel`n" +
            "session_id: $sid`ntime: $stamp`ntrace: $base.jsonl`n---`n$final"
        Set-Content -Path $PauseFile -Value $pauseDoc -Encoding utf8
    }

    # ── 台账 + 摘要 ───────────────────────────────────────────────────────
    # 泛洪文件可能恰好是一条没有换行的 16 MiB 长行；Get-FailReason 的 Tail/regex
    # 不应在已经有机械归因时再次扫描它，否则“快速失败”会退化成昂贵的文本分析。
    $failReason = if ($outputLimitReached) { 'brain-output-limit' }
        elseif (-not [string]::IsNullOrWhiteSpace($outputPumpFailure)) { 'brain-output-pump-failure' }
        else { Get-FailReason -Verdict $verdict -Subtype $terminalSubtype -TraceFile $TraceFile }
    Add-LedgerRow $turns $inTok $outTok $cacheRead $cacheWrite $durS $verdict $sid "$base.jsonl" $note $failReason
    Write-Host ''
    $usageTurns = if ($null -eq $turns) { '?' } else { $turns }
    Write-Host "───── 派单结果：$verdict（$Executor · $usageTurns 轮 · 订阅通道/无 API cost · ${durS}s）─────"
    if ($final) { Write-Host $final }
    if ($note) { Write-Host "note: $note" }
    if ($failReason) { Write-Host "fail_reason: $failReason" }
    if ($verdict -eq 'paused') {
        Write-Host ''
        Write-Host '>>> gateway 纯人工前置条件已暂停；恢复交互不批准危险动作，实际危险调用仍逐次使用手机确认卡：' -ForegroundColor Yellow
        Write-Host ">>>   scripts/dispatch.ps1 -Confirm `"$PauseFile`"" -ForegroundColor Yellow
    }
    Write-Host "trace: $TraceFile"
    if ($verdict -in @('success', 'paused')) { exit 0 } else { exit 1 }
}
finally {
    $treeCleanupFailure = $null
    $pumpCleanupFailure = $null
    try {
        if ($dispatchJobHandle -ne [IntPtr]::Zero -and -not $dispatchJobDrained) {
            Stop-DispatchJobProcesses -JobHandle $dispatchJobHandle
            $dispatchJobDrained = $true
        }
    }
    catch { $treeCleanupFailure = $_ }
    finally {
        if ($null -ne $dispatchJobGate) { $dispatchJobGate.Dispose() }
        if ($null -ne $treeCleanupFailure -and $null -ne $proc) {
            # Job 无法证实归零时不能无限等 EOF；关闭父侧 pipe 读端，让 pump 有界退出并
            # 记录 failure，KILL_ON_JOB_CLOSE 仍由后面的 Job handle 收口。
            try { $proc.StandardOutput.Dispose() } catch {}
            try { $proc.StandardError.Dispose() } catch {}
        }
        foreach ($pump in @($dispatchStdoutPump, $dispatchStderrPump)) {
            if ($null -eq $pump) { continue }
            try {
                if (-not $pump.Wait(5000)) {
                    $pumpCleanupFailure = 'dispatch 输出 pump 未能在 5 秒内回收。'
                }
            }
            catch { $pumpCleanupFailure = 'dispatch 输出 pump 回收失败。' }
        }
        if ($null -ne $proc) { $proc.Dispose() }
    }

    # 已知仍有后代时不能主动释放 Job/lease；进程退出会以 KILL_ON_JOB_CLOSE 作最终收口。
    if ($null -ne $treeCleanupFailure) { throw $treeCleanupFailure }
    if ($null -ne $pumpCleanupFailure) { throw $pumpCleanupFailure }
    if ($dispatchJobHandle -ne [IntPtr]::Zero) {
        [AgentMobileDispatchJob]::Close($dispatchJobHandle)
        $dispatchJobHandle = [IntPtr]::Zero
    }
    try {
        if ($null -ne $landscapeBaseline) {
            $landscapeCleanupProblem = Complete-LandscapePreparation -Device $landscapeDevice -AdbCommand $preflightAdb -Baseline $landscapeBaseline -PreflightState $preflightState
        }
        else { Stop-GatewayPreflightOwnedResources -State $preflightState -AdbCommand $preflightAdb }
    }
    catch { Write-Warning "网关预检收尾清理失败：$($_.Exception.Message)" }
    if ($lockFs) { [void](Close-DispatchLockLease -Lease $lockFs) }
    foreach ($key in @($sensitiveChildEnvironment.Keys)) {
        $sensitiveChildEnvironment[$key] = $null
        [void]$sensitiveChildEnvironment.Remove($key)
    }
    if (-not [string]::IsNullOrWhiteSpace($codexWorkspace)) {
        $safeWorkspace = [IO.Path]::GetFullPath($codexWorkspace)
        $safeParent = [IO.Path]::GetFullPath($codexWorkspaceParent).TrimEnd(
            [IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        if ([IO.Path]::GetDirectoryName($safeWorkspace) -cne $safeParent) {
            throw 'Codex workspace 清理目标越界。'
        }
        $workspaceItem = Get-Item -LiteralPath $safeWorkspace -Force -ErrorAction Stop
        if (($workspaceItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            -not [string]::IsNullOrWhiteSpace([string]$workspaceItem.LinkType)) {
            throw 'Codex workspace 清理目标变成 reparse/link，保留现场取证。'
        }
        if (@(Get-ChildItem -LiteralPath $safeWorkspace -Force).Count -ne 0) {
            throw 'Codex 隔离 workspace 非空；拒绝递归删除，保留现场取证。'
        }
        Remove-Item -LiteralPath $safeWorkspace -Force
        if ((Test-Path -LiteralPath $safeParent -PathType Container) -and
            @(Get-ChildItem -LiteralPath $safeParent -Force).Count -eq 0) {
            Remove-Item -LiteralPath $safeParent -Force
        }
    }
    if ($landscapeCleanupProblem) { throw "横屏准备收尾失败：$landscapeCleanupProblem" }
}
