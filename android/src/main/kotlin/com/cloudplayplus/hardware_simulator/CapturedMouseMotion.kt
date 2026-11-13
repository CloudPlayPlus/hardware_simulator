package com.cloudplayplus.hardware_simulator

import android.view.InputDevice
import android.view.MotionEvent

internal object CapturedMouseMotion {
  fun deltaX(event: MotionEvent): Float = sumAxis(
    event,
    MotionEvent.AXIS_X,
    MotionEvent.AXIS_RELATIVE_X
  )

  fun deltaY(event: MotionEvent): Float = sumAxis(
    event,
    MotionEvent.AXIS_Y,
    MotionEvent.AXIS_RELATIVE_Y
  )

  private fun sumAxis(event: MotionEvent, mouseAxis: Int, touchpadAxis: Int): Float {
    // 捕获鼠标的 X/Y 已是相对位移；触摸板使用专用相对轴，零值不切换轴。
    val axis = if (event.source == InputDevice.SOURCE_MOUSE_RELATIVE) mouseAxis else touchpadAxis
    var delta = event.getAxisValue(axis)
    // Android 的相对轴不会自动累加历史样本；只消费当前事件，不跨回调重放。
    for (index in 0 until event.historySize) {
      delta += event.getHistoricalAxisValue(axis, index)
    }
    return delta
  }
}
