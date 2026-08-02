<#
带外 OCR：把一张 PNG 读成「词 + 位置」列表。

**为什么是 Windows PowerShell 5.1 而不是 pwsh 7**：这里用的是系统自带的
`Windows.Media.Ocr`，走 WinRT 投影。5.1 自带投影，7 没有（要额外的 CsWinRT 互操作程序集）。
所以本册**由 pwsh 7 侧 `powershell.exe -File` 拉起**，不要直接 dot-source 进 runner。

**为什么不用网关的 OCR**：Deny 腿要的是一条**不来自被测组件**的独立证据。网关的 OCR 与
安全门同进程，用它等于让被测组件给自己作证——那正是 2026-08-01 Deny 腿假通过要补的窟窿。
系统 OCR 与 adb 截屏都在 PC 侧，与手机上的网关没有任何共享状态。

输出：每个词一行 `text|x|y|width|height`（设备像素，与 `screencap` 的原生分辨率同一坐标系）。
退出码：0=识别完成（**零个词也算完成**，由调用方判断"读不出来"）；2=本机没有可用 OCR 引擎；
1=其它失败。**任何一种失败都不许静默回空**——空结果与"没读到"在调用方看来必须能分开。

**输出是"词"不是"整行"，而 marker 会被切开。** 实测 `P0ALLOW-1D97824FD778` 被切成
`POALLOW-` / `1` / `D97824FD778` 三个词（还带 O→0 误识）。所以调用方必须先按行把词拼起来
再匹配，且必须走仓库既有的 marker 归一（大写 + 去符号 + O→0），不能拿单个词去 contains。

**本文件必须以 UTF-8 BOM 落盘。** Windows PowerShell 5.1 没有 BOM 时按 ANSI 读，中文注释与
字符串会乱码成解析错误——而 pwsh 7 侧的 AST 检查看不出来（它按 UTF-8 读，一切正常）。
2026-08-02 实锤：文件"语法可解析"却一执行就整片报错。同 .cmd 按 OEM 代码页读那条坑。
#>
param(
    [Parameter(Mandatory)][string]$Path
)

$ErrorActionPreference = 'Stop'

try {
    [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime] | Out-Null
    [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics, ContentType = WindowsRuntime] | Out-Null
    [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Graphics, ContentType = WindowsRuntime] | Out-Null
    [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
    [Windows.Globalization.Language, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
    Add-Type -AssemblyName System.Runtime.WindowsRuntime
}
catch {
    [Console]::Error.WriteLine("WinRT OCR 类型加载失败：$($_.Exception.Message)")
    exit 2
}

$asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
})[0]
if ($null -eq $asTask) {
    [Console]::Error.WriteLine('找不到 IAsyncOperation 的 AsTask 投影。')
    exit 2
}

function Wait-WinRt($Operation, $ResultType) {
    $task = $asTask.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    $task.Wait()
    return $task.Result
}

try {
    if (-not (Test-Path -LiteralPath $Path)) { throw "截图不存在：$Path" }
    # 系统 OCR 只吃绝对路径。
    $full = (Resolve-Path -LiteralPath $Path).ProviderPath

    $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    if ($null -eq $engine) {
        $available = @([Windows.Media.Ocr.OcrEngine]::AvailableRecognizerLanguages)
        if ($available.Count -eq 0) {
            [Console]::Error.WriteLine('本机没有安装任何 OCR 识别语言。')
            exit 2
        }
        $engine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($available[0])
    }
    if ($null -eq $engine) {
        [Console]::Error.WriteLine('无法创建 OCR 引擎。')
        exit 2
    }

    $file = Wait-WinRt ([Windows.Storage.StorageFile]::GetFileFromPathAsync($full)) ([Windows.Storage.StorageFile])
    $stream = Wait-WinRt ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
    try {
        $decoder = Wait-WinRt ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $bitmap = Wait-WinRt ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
        $result = Wait-WinRt ($engine.RecognizeAsync($bitmap)) ([Windows.Media.Ocr.OcrResult])
        foreach ($line in $result.Lines) {
            foreach ($word in $line.Words) {
                $rect = $word.BoundingRect
                # 词里不可能出现 `|`，用它当分隔符是安全的；真出现了也只会让这一行解析不出来，
                # 而调用方对解析不出来的行按"读不到"处理，不会倒向任何一边。
                '{0}|{1}|{2}|{3}|{4}' -f $word.Text, [int]$rect.X, [int]$rect.Y, [int]$rect.Width, [int]$rect.Height
            }
        }
    }
    finally { if ($null -ne $stream) { $stream.Dispose() } }
    exit 0
}
catch {
    [Console]::Error.WriteLine("OCR 失败：$($_.Exception.Message)")
    exit 1
}
