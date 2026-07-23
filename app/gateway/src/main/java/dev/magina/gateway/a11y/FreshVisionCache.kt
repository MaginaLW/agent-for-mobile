package dev.magina.gateway.a11y

/** 纯 Kotlin 的 OCR 缓存壳；forceFresh 路径必须绕过已有值并执行 loader。 */
internal class FreshVisionCache<T> {
    @Volatile
    private var cached: T? = null

    @Synchronized
    fun getOrLoad(
        forceFresh: Boolean,
        reusable: (T) -> Boolean,
        loader: () -> T,
    ): T {
        if (!forceFresh) cached?.takeIf(reusable)?.let { return it }
        return loader().also { cached = it }
    }

    @Synchronized
    fun invalidate() {
        cached = null
    }
}
