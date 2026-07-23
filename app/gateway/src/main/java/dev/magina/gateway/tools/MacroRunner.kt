package dev.magina.gateway.tools

import org.json.JSONObject

/** 具体宏白名单由 build type 提供；main 源码不持有任何 debug 宏名称。 */
internal object MacroRunner {
    fun run(args: JSONObject): JSONObject {
        return MacroRunnerFactory.run(args)
    }
}
