# 已持焦右框的系统助理结构

**2026-11-22 实测停在选择系统助理时。** 两个合成 APK 已装入全新 API 36 模拟器。宿主安装循环误用了保存助理角色名的变量，选择时把 `observer` 传给系统角色管理器，命令失败。场景尚未启动，普通助理树能否采到、采集时右框连接是否连续、树与输入法有无共同标识及四边均为未知。零标志对照与过期回放也未取得本场数据。

首轮 167 秒收尾。两包卸载后各自的包名查询均为空。入场记录的 13 项设置全部恢复并读回，含默认助理组件、语音交互与语音识别服务。恢复原角色持有者的命令也因同一变量错误返回失败，终场缺少角色管理器对持有者的直接读回。私有 ADB 与模拟器已停止，三个专属端口全部释放。以 `python -B read_result.py --setup-only <首轮原件目录>` 可复核两条命令的失败回执、缺失场景、逐项恢复和进程收尾。

宿主随后把角色名保存在独立变量，并补齐了观察器对普通资源 ID 与原生自动填充标识的分别记录。重建时一次因隔离环境里的 SDK 路径不存在而停止，指定已安装的只读 SDK 后成功构建两份 APK。已完成构建的靶包和观察器摘要分别为 `3ce96f1d9069963f00cd00a5492ac02fc5f166f87a52640047c9541c17412844` 和 `b3e96a4f169b3ee2b308f6f6d8396896da560751fdb68916c0eb2e7a10c1a1f3`。收尾时未启动第二轮。

## 待验证的问题

本夹具在 API 36 全新合成模拟器上检验两个问题。系统选择的助理能否在右框的新输入连接仍活跃时取得一次新的普通 `AssistStructure`？树中是否存在可与该连接的 `EditorInfo` 独立比对的字段标识？靶应用的两个空白 `EditText` 均无资源 ID。焦点、四边与靶私有回执一致可以佐证几何。按连接选框还需共同标识。

Android 16 的普通助理路径调用 `View.onProvideStructure`，同一位置只在自动填充路径显式调用 `setAutofillId`。这是框架源码给出的预期。本场没有现场树来核实节点键值。当前实验助理所需的额外系统角色也没有在现有网关启用。[Android 16 的结构分发](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r1/core/java/android/view/View.java#L11300-L11313)

## 夹具方法与验收条件

1. 运行 `python -B prepare.py <全新目录>`，分别构建生成的 `target` 与 `observer`。基底来自[双框夹具](../README.md)。用临时合成签名安装，分别核对设备端摘要与不同 UID。观察器同时提供实验输入法、返回空响应的自动填充服务和系统助理。助理的服务元数据声明 `sessionService`、`recognitionService` 与 `supportsAssist=true`。识别器只返回错误，APK 没有录音权限。[系统助理角色资格](https://android.googlesource.com/platform/packages/modules/Permission/+/refs/heads/android16-qpr2-release/PermissionController/res/xml/roles.xml)
2. 按[本地测试台](../../../../runbooks/本地测试台.md)核实专属私有 ADB 的初始空表、禁 USB 和 mDNS、唯一模拟器名称与 API 36。记录原默认助理、默认输入法、自动填充源等设置。测试台在自有虚拟机上经系统角色管理器选择观察器作为助理，读回角色持有者、系统绑定的服务组件，并确认 `onReady`。助理角色是额外条件。
3. 在系统原输入法下启动 `automatic-right-switch`，读取靶包的 `right-ready.json` 与首次自然回调，切至实验输入法。保留上层 A2 的两侧、控件实例、代次和原始探针回执。此后分别在观察器自己的私有文件 `files/assist-command` 中一次性给出 `assist <generation> <ime_started_ms>`、`noflag <generation> <ime_started_ms>`。只在上一会话 `finish()` 并销毁后运行下一场。两场均核对当前输入绑定 UID 和合成靶包。
4. 两场均在 `onPrepareShow` 之前关闭会话 UI，先后用 `SHOW_WITH_ASSIST` 和零标志调用公开的 `showSession`。两场均禁止截图。观察器只查看合成靶组件、窗口和节点类型、焦点、几何及标识是否匹配。它不调用读取正文的访问器，不序列化树。目标的 `onProvideStructure` 在调用超类后记下写入时刻、实例和焦点，保留系统原有的节点标识。每场结束时实验输入法向原连接发送屏幕外的第二枚探针，靶包只回报该请求到达哪个连接。录制靶包的 ART 方法轨迹，分别统计结构写入、焦点方法和重新建连。[助理请求标志及回调](https://developer.android.com/reference/android/service/voice/VoiceInteractionSession#SHOW_WITH_ASSIST) · [关闭助理界面](https://developer.android.com/reference/android/service/voice/VoiceInteractionSession#setUiEnabled(boolean))
5. 恢复原助理角色，逐项读回原系统设置，卸载两包，关闭本轮模拟器及其 ADB。运行 `python -B read_result.py <运行目录>`。输入包括 `state.json`、上层 A2 原件、`A2/assist-{assist,noflag}.json`、`A2/assist.log` 和同目录两份 `.trace`。脚本分别给出新树、结构内焦点、共同标识及可严格归属的四边。它用设备 uptime 比较输入、采集和送达时间，用 ART 头的时钟、溢出标志和记录数检验轨迹。框架在靶进程采集前后写入这两个时间戳。[系统记录采集起止](https://github.com/aosp-mirror/platform_frameworks_base/blob/android-16.0.0_r1/core/java/android/app/ActivityThread.java#L4586-L4596)
