package com.cloudplayplus.hardware_simulator

import android.view.MotionEvent

/** 同时处理按钮状态位和独立按钮事件，保证远端只收到一次状态转换。 */
internal class CapturedPointerButtons(
  private val send: (Int, Boolean) -> Unit,
  private val delayTapRelease: (Runnable) -> Unit
) {
  private val deviceMasks = mutableMapOf<Int, Int>()
  private val actionOnlyMasks = mutableMapOf<Int, Int>()
  private val pendingTaps = mutableMapOf<Int, Runnable>()
  private var physicalMask = 0

  fun observe(event: MotionEvent) {
    val action = event.actionMasked
    val id = event.deviceId
    var actionOnly = actionOnlyMasks[id] ?: 0
    val mask = when (action) {
      MotionEvent.ACTION_CANCEL -> {
        actionOnly = 0
        0
      }
      MotionEvent.ACTION_BUTTON_PRESS -> {
        // 部分设备只提供 actionButton；中间的移动仍可能带空 buttonState。
        actionOnly = actionOnly or (event.actionButton and event.buttonState.inv())
        event.buttonState or actionOnly
      }
      MotionEvent.ACTION_BUTTON_RELEASE -> {
        actionOnly = actionOnly and event.actionButton.inv()
        (event.buttonState or actionOnly) and event.actionButton.inv()
      }
      else -> event.buttonState or actionOnly
    }
    if (actionOnly != 0) actionOnlyMasks[id] = actionOnly else actionOnlyMasks.remove(id)
    if ((deviceMasks[id] ?: 0) == mask) return
    if (mask == 0) deviceMasks.remove(id) else deviceMasks[id] = mask
    val old = physicalMask
    physicalMask = deviceMasks.values.fold(0, Int::or)
    update(old, MotionEvent.BUTTON_PRIMARY, 1)
    update(old, MotionEvent.BUTTON_SECONDARY or MotionEvent.BUTTON_BACK, 3)
    update(old, MotionEvent.BUTTON_TERTIARY, 2)
  }

  private fun update(old: Int, flags: Int, id: Int) {
    val wasDown = old and flags != 0
    val isDown = physicalMask and flags != 0
    if (wasDown == isDown) return
    // 实体按下接管尚未释放的同键轻点，旧回调不能把实体拖动提前释放。
    if (isDown && pendingTaps.remove(id) != null) return
    send(id, isDown)
  }

  fun tap(id: Int) {
    val flags = if (id == 1) MotionEvent.BUTTON_PRIMARY else MotionEvent.BUTTON_SECONDARY or MotionEvent.BUTTON_BACK
    if (physicalMask and flags != 0) return
    pendingTaps.remove(id)?.let { send(id, false) }
    send(id, true)
    val release = object : Runnable {
      override fun run() {
        if (pendingTaps[id] !== this) return
        pendingTaps.remove(id)
        send(id, false)
      }
    }
    pendingTaps[id] = release
    delayTapRelease(release)
  }

  fun reset() {
    val taps = pendingTaps.keys.toList()
    pendingTaps.clear()
    taps.forEach { send(it, false) }
    val old = physicalMask
    physicalMask = 0
    deviceMasks.clear()
    actionOnlyMasks.clear()
    update(old, MotionEvent.BUTTON_PRIMARY, 1)
    update(old, MotionEvent.BUTTON_SECONDARY or MotionEvent.BUTTON_BACK, 3)
    update(old, MotionEvent.BUTTON_TERTIARY, 2)
  }
}
