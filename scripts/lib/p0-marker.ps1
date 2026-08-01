#Requires -Version 7
<#
marker 的生成与归一（纯函数，不碰设备）。

单独成册的理由：marker 是整套 P0 判据的锚点——它被 OCR 读两遍（落框复核、发送后 ui_find）、
被两套归一分别处理（runner 侧与网关侧）。它的字符集与归一规则**必须能被离线用例直接钓住**，
而它们原本埋在 runner 中间、在 `-DryRun` 的 `exit` 之后，用例根本取不到
（又一例「判据看不见的东西就会烂掉」）。
#>

<#
marker 归一化。**必须与网关的 `OcrEngine.norm` 同口径**，否则 runner 的判据比网关自己还严，
真机上就会出现"网关认了、runner 不认"的自相矛盾。

O→0 是 knowledge 明写的实测规则（「归一（全角/大小写/o→0）」，CJK 形近字与数字 0→O 抖动
是 ML Kit 在这台设备上的已知行为）。2026-07-31 第六轮实锤：消息确实发出去了、marker 也确实
出现在消息区，OCR 读成 `POALLOW-…`（字母 O），而 runner 只做大写+去符号，判成"证据不匹配"。

放宽是否削弱证据？不：marker 形如 `P0ALLOW-<12 位十六进制>`，十六进制字母表里没有 O，
折叠 O→0 只影响固定前缀，不影响那 12 位随机部分，碰撞风险为零。
#>
<#
marker 后缀的字符集。**刻意不用十六进制**。

2026-08-02 真机：`type_text` 的落框 OCR 复核连着两次把合法输入判成不匹配，读回里
`C` 变成 `0`、`D` 变成 `d`。网关那侧的行为是**对的**（fail-closed，读不实就不记证据），
错在 marker 用了十六进制——`0/O`、`C/0`、`B/8`、`D/0`、`E/F` 全在一个字符集里，
混淆面大得离谱，而它每一腿都要被 OCR 读两遍（落框复核 + 发送后 ui_find）。

**修字符集，不修判据**：放宽 fail-closed 那一侧是拿安全换通过率，而换字符集不损失任何严格性。

排除的几族（都是本仓真读错过或公认易混的）：
- `0 O D Q` 圆形族——`0↔O` 两侧归一虽已互折，`D` 与它们仍近；
- `C` 与 `0`（本轮实锤）、`B` 与 `8`、`E` 与 `F`、`G` 与 `6`；
- `1 I L J` 竖线族、`2` 与 `Z`、`5` 与 `S`、`U` 与 `V`、`N` 与 `M`、`R` 与 `P`。

留下 12 个：数字 3 4 7 9 与字母 A H K M P T X Y。12^12 ≈ 8.9e12，
一次跑测只用三个 marker，唯一性绰绰有余。

**注意两侧归一并不对称**：runner 侧 `Normalize-P0MarkerText` 是大写 + 去非字母数字 + O→0；
网关侧 `OcrEngine.norm` 是小写 + o→0。两者都不折叠 `c↔0`，所以只能靠字符集躲开。
#>
$script:P0MarkerAlphabet = '3479AHKMPTXY'

function New-P0MarkerSuffix {
    param([int]$Length = 12)
    $bytes = [byte[]]::new($Length)
    [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $chars = [char[]]::new($Length)
    for ($i = 0; $i -lt $Length; $i++) {
        $chars[$i] = $script:P0MarkerAlphabet[$bytes[$i] % $script:P0MarkerAlphabet.Length]
    }
    return -join $chars
}

function Normalize-P0MarkerText {
    param([AllowEmptyString()][string]$Text)
    $upper = [regex]::Replace($Text.ToUpperInvariant(), '[^A-Z0-9]', '')
    return $upper.Replace('O', '0')
}

