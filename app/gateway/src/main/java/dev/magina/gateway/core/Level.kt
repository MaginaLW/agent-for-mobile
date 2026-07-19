package dev.magina.gateway.core

/** 动作分级：R 只读 / W 普通写 / D 危险。放在 core，避免安全核心反向依赖 MCP。 */
enum class Level { R, W, D }
