#Requires -Version 7
<#
gateway MCP 客户端私密配置的**唯一一份定义**：谁来写、下限是多少、闸门查哪些字段。

存在的理由是一次真实的翻车（2026-08-08）：我给 `timeout` 加了开跑前闸门，**却没回头看
一眼"谁在生成这份文件"**——`-Provision` 每轮都会用 `Set-P0GatewayConfigToken` 覆盖它，
而那个写入函数不写 `timeout`。顺序还是致命的：先覆盖、后校验，**手工放一份带 timeout 的
进去也会被原样冲掉**。结果是四腿在第 1 腿开跑前被自己的闸门拒掉，每轮复现。

`check.ps1` 五项全绿没拦住它：**两个函数各自都有用例、各自都对，缺的是把它们接起来的那一条。**
所以这里把"写"与"查"放进同一个文件，并由 `dispatch-offline` 那条端到端用例钉住
**产出必须能通过闸门**——那条用例对**将来新增的任何闸门字段**都自动生效，不需要有人记得同步。
#>

# per-server `timeout` 的下限（毫秒）。算式：决定期 90s + 等前台预算 300s + 宏与输入开销 ~30s。
# **这只解决第 1 层（HTTP 首字节计时器 60s）**；第 2 层（300s 空闲看门狗）靠网关在阻塞期间
# 发 `notifications/progress` 心跳解决。三层天花板的实测见 docs/knowledge/brain/harness.md。
#
# **两处引用一律从这里取，不许各写一个字面量**：各写一个的话，下次调下限就又是
# "两个都对、接起来不对"——正是这条坑今天的形状。
$GatewayMcpMinTimeoutMs = 420000

$GatewayMcpUrl = 'http://127.0.0.1:8848/mcp'

<#
闸门实际校验到的字段（`Get-GatewayConfigProblem` 一一对应）。
只作可读性辅助与穷举核对用；**真正自动防复发的是那条端到端用例**，
它不依赖有人记得往这个数组里补东西。
#>
$GatewayMcpGatedFields = @('type', 'url', 'timeout', 'headers')

<#
构造配置对象。**写入方与用例共用它**，避免"写出来的"和"测的"是两份。
#>
function New-GatewayMcpConfigObject {
    param([Parameter(Mandatory)][string]$Token)
    return [ordered]@{
        mcpServers = [ordered]@{
            gateway = [ordered]@{
                type = 'http'
                url = $GatewayMcpUrl
                timeout = $GatewayMcpMinTimeoutMs
                headers = [ordered]@{ Authorization = "Bearer $Token" }
            }
        }
    }
}
