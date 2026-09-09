package com.github.tfox.flutter_vless

internal class RuntimeControlGeneration {
    private var value = 0L

    fun capture(): Long = value

    fun advance(): Long {
        value = Math.addExact(value, 1L)
        return value
    }

    fun isCurrent(captured: Long): Boolean = captured == value
}
