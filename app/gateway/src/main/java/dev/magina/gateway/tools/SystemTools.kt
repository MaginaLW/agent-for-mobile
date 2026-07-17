package dev.magina.gateway.tools

import android.bluetooth.BluetoothManager
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.media.AudioManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.Build
import android.os.PowerManager
import android.os.SystemClock
import android.provider.MediaStore
import android.provider.Settings
import dev.magina.gateway.Gateway
import dev.magina.gateway.a11y.GatewayA11yService
import dev.magina.gateway.core.ErrorCode
import dev.magina.gateway.core.GatewayError
import org.json.JSONArray
import org.json.JSONObject

/**
 * L1 系统通道（无特权子集，M1a）。
 * 特权位阶：普通 API（本文件）→ Shizuku shell 白名单（M1b，system_set_state 的主通道）。
 * M0 发现 #2：settings 键不可信——真值源标注在 source 字段；dumpsys 交叉复核待 Shizuku 通道。
 */
object SystemTools {

    private val ctx: Context get() = Gateway.appContext

    fun deviceInfo(): JSONObject {
        val wm = ctx.getSystemService(Context.WINDOW_SERVICE) as android.view.WindowManager
        val b = wm.maximumWindowMetrics.bounds
        val bm = ctx.getSystemService(Context.BATTERY_SERVICE) as BatteryManager
        return JSONObject()
            .put("model", "${Build.BRAND} ${Build.MODEL}")
            .put("android", Build.VERSION.RELEASE)
            .put("sdk", Build.VERSION.SDK_INT)
            .put("screen", JSONArray(listOf(b.width(), b.height())))
            .put("density", ctx.resources.displayMetrics.density.toDouble())
            .put("battery_pct", bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY))
            .put("caps", JSONArray(Gateway.caps()))
            .put("gateway_version", "0.1.0-m1a")
    }

    fun getState(key: String): JSONObject = when (key) {
        "bluetooth" -> {
            val adapter = (ctx.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
                ?: throw GatewayError(ErrorCode.E_CHANNEL_DOWN, "设备无蓝牙", channel = "api")
            val on = try {
                adapter.isEnabled
            } catch (e: SecurityException) {
                throw GatewayError(
                    ErrorCode.E_PERM_MISSING, "缺 BLUETOOTH_CONNECT 权限",
                    channel = "api", fallback = "在网关主界面点「授予运行权限」",
                )
            }
            state(if (on) "on" else "off", "BluetoothAdapter.isEnabled")
        }
        "wifi" -> {
            @Suppress("DEPRECATION")
            val on = (ctx.applicationContext.getSystemService(Context.WIFI_SERVICE) as android.net.wifi.WifiManager).isWifiEnabled
            state(if (on) "on" else "off", "WifiManager.isWifiEnabled")
        }
        "airplane" -> state(
            if (Settings.Global.getInt(ctx.contentResolver, Settings.Global.AIRPLANE_MODE_ON, 0) == 1) "on" else "off",
            "Settings.Global(仅此键实测可信度未标定)",
        )
        "battery" -> {
            val bm = ctx.getSystemService(Context.BATTERY_SERVICE) as BatteryManager
            JSONObject()
                .put("value", bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CAPACITY))
                .put("charging", bm.isCharging)
                .put("source", "BatteryManager")
                .put("cross_checked", false)
        }
        "network" -> {
            val cm = ctx.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            val nc = cm.activeNetwork?.let { cm.getNetworkCapabilities(it) }
            val kind = when {
                nc == null -> "none"
                nc.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                nc.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
                else -> "other"
            }
            state(kind, "ConnectivityManager")
        }
        "screen" -> state(
            if ((ctx.getSystemService(Context.POWER_SERVICE) as PowerManager).isInteractive) "on" else "off",
            "PowerManager.isInteractive",
        )
        "volume" -> {
            val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            JSONObject()
                .put("value", am.getStreamVolume(AudioManager.STREAM_MUSIC))
                .put("max", am.getStreamMaxVolume(AudioManager.STREAM_MUSIC))
                .put("source", "AudioManager").put("cross_checked", false)
        }
        "brightness" -> state(
            Settings.System.getInt(ctx.contentResolver, Settings.System.SCREEN_BRIGHTNESS, -1).toString(),
            "Settings.System",
        )
        else -> throw GatewayError(
            ErrorCode.E_UNSUPPORTED_KEY, "key「$key」不在白名单",
            fallback = "可用：bluetooth/wifi/airplane/battery/network/screen/volume/brightness",
        )
    }

    private fun state(v: String, source: String) =
        JSONObject().put("value", v).put("source", source).put("cross_checked", false)

    fun setState(key: String, value: String): JSONObject = when (key) {
        "volume" -> {
            val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
            val target = value.toIntOrNull() ?: throw GatewayError(ErrorCode.E_INVALID_ARG, "volume 需整数")
            am.setStreamVolume(AudioManager.STREAM_MUSIC, target, 0)
            val actual = am.getStreamVolume(AudioManager.STREAM_MUSIC)
            JSONObject().put("applied", true).put("verified", actual == target).put("actual", actual)
        }
        // 蓝牙/WiFi 等：Android 13+ 已封死普通 app 编程开关（spec §6），主通道 = Shizuku shell（M1b）
        else -> throw GatewayError(
            ErrorCode.E_CHANNEL_DOWN,
            "system_set_state($key) 需要 Shizuku 特权通道（M1b）",
            channel = "shell", retryable = false,
            fallback = "open_uri 打开对应系统设置页，用 ui_find/ui_action 点开关（UI 兜底链路）",
        )
    }

    fun verifyState(key: String, expected: String): JSONObject {
        val cur = getState(key)
        val actual = cur.opt("value").toString()
        return JSONObject()
            .put("match", actual.equals(expected, ignoreCase = true))
            .put("actual", actual)
            .put("source", cur.optString("source"))
    }

    fun foregroundApp(): JSONObject {
        val a11y = GatewayA11yService.require()
        return JSONObject()
            .put("package", a11y.foregroundPackage())
            .put("activity", a11y.ctx(Gateway.caps()).optString("activity"))
    }

    fun keyboardState(): JSONObject = GatewayA11yService.require().keyboardState()

    fun appLaunch(nameOrPackage: String): JSONObject {
        val pkg = Gateway.skills.resolvePackage(nameOrPackage)
        val intent = ctx.packageManager.getLaunchIntentForPackage(pkg)
            ?: throw GatewayError(
                ErrorCode.E_NOT_FOUND, "找不到可启动的 app：$pkg",
                channel = "intent", fallback = "确认包名或在技能包 apps.json 加别名",
            )
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        ctx.startActivity(intent)
        val verified = waitForeground(pkg, 3000)
        return JSONObject().put("launched", true).put("package", pkg).put("foreground_verified", verified)
    }

    fun appStop(@Suppress("UNUSED_PARAMETER") pkg: String): JSONObject = throw GatewayError(
        ErrorCode.E_CHANNEL_DOWN, "app_stop 需要 Shizuku 特权通道（M1b：am force-stop）",
        channel = "shell", fallback = "press_key(home) 把它置于后台即可满足多数任务",
    )

    fun clipboard(op: String, text: String?): JSONObject {
        val cm = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        return when (op) {
            "set" -> {
                cm.setPrimaryClip(ClipData.newPlainText("gateway", text ?: ""))
                JSONObject().put("done", true)
            }
            "get" -> {
                // Android 10+ 后台读剪贴板受限；本 app 为默认 IME 时豁免（自建 IME 的副产品红利，spec §6）
                val clip = try { cm.primaryClip } catch (e: SecurityException) { null }
                val value = clip?.takeIf { it.itemCount > 0 }?.getItemAt(0)?.coerceToText(ctx)?.toString()
                    ?: throw GatewayError(
                        ErrorCode.E_PERM_MISSING, "剪贴板读取被系统限制",
                        channel = "api", fallback = "把「执行网关」设为默认输入法后重试（IME 豁免）",
                    )
                JSONObject().put("text", value)
            }
            else -> throw GatewayError(ErrorCode.E_INVALID_ARG, "op ∈ get|set")
        }
    }

    fun mediaQuery(type: String, album: String?, limit: Int): JSONObject {
        if (type != "image" && type != "screenshot") throw GatewayError(
            ErrorCode.E_INVALID_ARG, "type ∈ image|screenshot（video 待需求）",
        )
        val proj = arrayOf(
            MediaStore.Images.Media._ID, MediaStore.Images.Media.DISPLAY_NAME,
            MediaStore.Images.Media.DATE_ADDED, MediaStore.Images.Media.SIZE,
            MediaStore.Images.Media.BUCKET_DISPLAY_NAME,
        )
        val (sel, selArgs) = when {
            type == "screenshot" ->
                "${MediaStore.Images.Media.BUCKET_DISPLAY_NAME} IN (?,?,?) OR ${MediaStore.Images.Media.RELATIVE_PATH} LIKE ?" to
                    arrayOf("Screenshots", "截屏", "截图", "%Screenshots%")
            album != null -> "${MediaStore.Images.Media.BUCKET_DISPLAY_NAME} = ?" to arrayOf(album)
            else -> null to null
        }
        val items = JSONArray()
        try {
            ctx.contentResolver.query(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI, proj, sel, selArgs,
                "${MediaStore.Images.Media.DATE_ADDED} DESC",
            )?.use { c ->
                var n = 0
                while (c.moveToNext() && n < limit) {
                    val id = c.getLong(0)
                    items.put(
                        JSONObject()
                            .put("uri", "${MediaStore.Images.Media.EXTERNAL_CONTENT_URI}/$id")
                            .put("name", c.getString(1))
                            .put("date_added", c.getLong(2))
                            .put("size", c.getLong(3))
                            .put("album", c.getString(4) ?: "")
                    )
                    n++
                }
            }
        } catch (e: SecurityException) {
            throw GatewayError(
                ErrorCode.E_PERM_MISSING, "缺媒体读取权限",
                channel = "api", fallback = "在网关主界面点「授予运行权限」",
            )
        }
        if (items.length() == 0) throw GatewayError(
            ErrorCode.E_NOT_FOUND, "media_query 无结果（type=$type album=$album）",
            channel = "api", fallback = "type=image 不带 album 重查，或改走相册 app UI 路径",
        )
        return JSONObject().put("items", items)
    }

    /** 轮询 a11y 前台包名（无 a11y 时直接返回 false，不抛——启动本身已发生）。 */
    fun waitForeground(pkg: String, timeoutMs: Long): Boolean {
        val a11y = GatewayA11yService.instance ?: return false
        val start = SystemClock.elapsedRealtime()
        while (SystemClock.elapsedRealtime() - start < timeoutMs) {
            if (a11y.foregroundPackage() == pkg) return true
            SystemClock.sleep(200)
        }
        return false
    }
}
