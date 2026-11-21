# 当前输入连接的屏幕几何实验

合成 Activity 中有两个不同位置、尺寸相同的 EditText。它们共享具有偏移和滚动的祖先。独立的 `:ime` 进程只向当前 InputConnection 请求数据。四个场景依次聚焦甲空稿、乙有稿、甲有稿、乙空稿。回执只含身份、几何及判定结果。

原点实验复用网关的 `EditorOriginProbe.java`。它必须排除错误候选以及不同 ID 同原点的歧义候选。首个场景还在真实连接回调的 executor 中推进世代，检查过期请求返回空值。

四边实验为每个位置增加另一个同原点、更宽且更高的实际 EditText。当前 IME 对每个场景单独申请一次 `CURSOR_UPDATE_IMMEDIATE` 和 `CURSOR_UPDATE_FILTER_EDITOR_BOUNDS`，用回调的矩阵将编辑区域映射至屏幕。同一场景还执行有归属的原点请求。Activity 在自身进程以 `getLocalVisibleRect` 和 `getLocationOnScreen` 计算这些平移布局中经祖先裁剪的屏幕矩形。单个场景最多等 3 秒，超时后保留已取得的读数。Android 的 CursorAnchorInfo 回调没有请求编号，样本记录当前连接上观测到的事件。

2026-11-20 在 API 36 rev7 的隔离模拟器上，两轮各通过 4/4。屏幕原点为 (46, 84) 和 (259, 195)，对应可见矩形为 [46, 84, 246, 154] 和 [259, 195, 459, 265]。同原点但宽 24、高 16 像素的对照框均被排除。原点实验的宿主读取命令首次因引号错误超时，随后在同一 AVD 核对 APK 摘要和文件时间，取回了该次运行的原始回执。两个实验完成后均已停止自建模拟器，最后一次恢复原输入法并核对了端口释放。

## 构建

使用已有 JDK、API 35 平台包和 Android Build Tools 35。在新建的私有构建目录中执行下列 PowerShell 命令。`$Fixture` 指向本目录，`$Probe` 指向仓内的 [网关原点查询](../../../../app/gateway/src/main/java/dev/magina/gateway/ime/EditorOriginProbe.java)，`$PlatformJar` 为平台的 android.jar，`$FixtureKey` 为实验专用临时签名库。将当前 Build Tools 和 JDK 的 bin 加入本 shell 的 PATH。

```powershell
New-Item -ItemType Directory classes,dex
aapt2 compile --dir "$Fixture/res" -o res.zip
aapt2 link -I $PlatformJar --manifest "$Fixture/AndroidManifest.xml" -o unsigned.apk res.zip
$sources = @(Get-ChildItem $Fixture -Filter '*.java' -File | ForEach-Object FullName)
javac --release 8 -encoding UTF-8 -g:none -classpath $PlatformJar -d classes @sources $Probe
jar cf classes.jar -C classes .
d8 --min-api 34 --lib $PlatformJar --output dex classes.jar
jar uf unsigned.apk -C dex classes.dex
zipalign -f 4 unsigned.apk aligned.apk
apksigner sign --ks $FixtureKey --out experiment.apk aligned.apk
apksigner verify experiment.apk
```

## 隔离模拟器内复现

使用[本地测试台](../../../runbooks/本地测试台.md)的独占 API 36 AVD、私有 ADB、启动前空设备表、端口归属和模拟器身份检查。下例中的 `$Adb`、`$PrivatePort`、`$Serial` 来自该轮核验。使用新临时签名时，从全新 AVD 用户数据开始。复用旧 AVD 时，须确认此次 APK 与该 AVD 中同包名实验包的签名证书一致，并确认本轮结果和进度文件均不存在。普通包清单或结果目录为空也可能遇到 `INSTALL_FAILED_UPDATE_INCOMPATIBLE`；旧签名无法核实时，保留旧 AVD，另建实例。每种模式只启动一次，先保存并在收尾恢复原 IME。

```powershell
$target = @('-H','127.0.0.1','-P',"$PrivatePort",'-s',$Serial)
$pkg = 'dev.magina.editororigin'
& $Adb @target install -r experiment.apk
$originalIme = & $Adb @target shell settings get secure default_input_method
$ime = "$pkg/.BoundsProbeIme"
$resultName = 'bounds-result.json'
try {
    & $Adb @target shell ime enable $ime
    & $Adb @target shell ime set $ime
    & $Adb @target shell am start -n "$pkg/.OriginProbeActivity" --ez geometry true
    $deadline = [DateTime]::UtcNow.AddSeconds(45)
    do {
        $dirs = & $Adb @target shell run-as $pkg ls -1 .
        if ($LASTEXITCODE -ne 0) { throw '无法读取靶标目录' }
        if ($dirs -contains 'files') {
            $files = & $Adb @target shell run-as $pkg ls -1 files
            if ($LASTEXITCODE -ne 0) { throw '无法读取靶标结果目录' }
            if ($files -contains $resultName) { break }
        }
        Start-Sleep -Seconds 1
    } while ([DateTime]::UtcNow -lt $deadline)
    if ($files -notcontains $resultName) { throw '等待合成结果超时' }
    & $Adb @target exec-out run-as $pkg cat "files/$resultName"
} finally {
    & $Adb @target shell ime set $originalIme
    & $Adb @target shell ime disable $ime
}
```

原点实验改用 `.OriginProbeIme`，启动时省略 `--ez geometry true`，并将 `$resultName` 设为 `result.json`。回执的 `complete`、四行 `pass` 和各项独立读数共同用于判定。再次开机读取留存回执时可用 `stat -c %Y` 核实其修改时间早于本次开机。

在同一套四边实验中，用 `--ez session_bounds true` 启动并读取 `session-bounds-result.json`，可验证原点为空时的延后处理。确认本次结果和进度文件均不存在，并保留此前的回执。新模式每阶段通过实际输入连接返回一次 `CODE_UNSUPPORTED`。核对四行原点均空、矩形分别匹配当前框且不匹配对照框。`deferred_rejected` 应依次为 0、1、2、2，其中再次聚焦同一框的 `revisited_rejected` 应为 0、0、1、1。保留的旧样本从输入法已收到的事件中取得，此模式没有为系统首次送达的回调提供请求编号。

## 用当前输入焦点核对身份和四边

在同一私有模拟器中安装合成包，保存原默认输入法及启用清单。使用干净实例，确认实验输入法原先未启用，应用私有目录 `files` 下没有本轮的 `focus-ready`、`focus-go` 或 `focus-bounds-*.json`。

1. 在第一个终端运行 `& $Adb @target shell am instrument -w -r "$pkg/.FocusCheckInstrumentation"`。它在初始化无障碍观察器后建立 `files/focus-ready`，最多等待宿主 30 秒。
2. 在第二个终端使用同一私有端口和模拟器序列号。当 `& $Adb @target shell run-as $pkg ls files` 显示 `focus-ready` 时，依次运行 `& $Adb @target shell ime enable $ime`、`& $Adb @target shell ime set $ime`。读回默认输入法，确认与 `$ime` 相同，再运行 `& $Adb @target shell run-as $pkg touch files/focus-go`。
3. 核对第一个终端的退出回执和四行 `focus_rows`。观察器每阶段最多等 8 秒，连续两次清缓存并读取系统当前的输入焦点，核对活动应用窗口、节点唯一性、资源名及屏幕矩形。另读应用私有的 `focus-bounds-result.json`，核对独立输入法进程、四个实际编辑框测量以及同原点对照框。首次失败即结束，保存已有结果。
4. 在收尾中恢复原默认输入法并停用实验输入法，逐项比对原默认值和启用清单。关闭本轮独占的模拟器和 ADB 服务并核实端口释放。

四个场景依次为具名甲、具名但无障碍节点报告不可编辑的乙、加宽后重新聚焦的甲，以及只有运行时 ID 的乙。预期前三次身份和四边一致，旧甲的矩形在第三次比对时因宽度不同被拒绝。第四行必须同时读到 `bounds_match=true` 和 `current=missing_id` 才能通过：无障碍焦点与输入法报告的四边逐边相等，身份核对仍因缺名停止。实验只观察元数据。
