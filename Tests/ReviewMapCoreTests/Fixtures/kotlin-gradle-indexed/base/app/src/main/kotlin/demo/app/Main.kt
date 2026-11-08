package demo.app

import demo.cache.Cache
import demo.store.Store

var warm: Cache? = null

fun start() {
    val s = Store()
    println(s.load("a") + (warm != null))
}

fun main() = start()
