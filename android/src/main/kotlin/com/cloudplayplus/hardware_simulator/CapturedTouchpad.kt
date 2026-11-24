package com.cloudplayplus.hardware_simulator

import android.view.InputDevice
import android.view.MotionEvent
import android.view.ViewConfiguration
import kotlin.math.abs

/** Captured SOURCE_TOUCHPAD delivers finger contacts instead of Android's pointer gestures. */
internal class CapturedTouchpad(
  private val move: (Float, Float) -> Unit,
  private val tap: (Int) -> Unit,
  private val scroll: (Float, Float) -> Unit
) {
  private var deviceId = -1
  private var fingerId = -1
  private var contactStartTime = 0L
  private val tapOrigins = mutableMapOf<Int, Pair<Float, Float>>()
  private var lastX = 0f
  private var lastY = 0f
  private var unitsPerMmX = 1f
  private var unitsPerMmY = 1f
  private var relativeX = false
  private var relativeY = false
  private var tapCandidate = false
  private var multipleFingers = false
  private var scrollRemainderX = 0f
  private var scrollRemainderY = 0f

  fun reset() {
    fingerId = -1
    deviceId = -1
    tapOrigins.clear()
    tapCandidate = false
    multipleFingers = false
    scrollRemainderX = 0f
    scrollRemainderY = 0f
  }

  fun handle(event: MotionEvent): Boolean {
    if (!event.isFromSource(InputDevice.SOURCE_TOUCHPAD)) return false
    if (event.deviceId != deviceId) reset()
    if (tapCandidate && event.actionMasked != MotionEvent.ACTION_DOWN) {
      checkTap(event)
    }
    when (event.actionMasked) {
      MotionEvent.ACTION_DOWN -> {
        reset()
        deviceId = event.deviceId
        fingerId = event.getPointerId(0)
        contactStartTime = event.eventTime
        lastX = event.x
        lastY = event.y
        tapOrigins[fingerId] = lastX to lastY
        tapCandidate = event.buttonState == 0
        val device = event.device
        unitsPerMmX = unitsPerMm(device, MotionEvent.AXIS_X, 100f)
        unitsPerMmY = unitsPerMm(device, MotionEvent.AXIS_Y, 65f)
        relativeX = device?.getMotionRange(MotionEvent.AXIS_RELATIVE_X, event.source) != null
        relativeY = device?.getMotionRange(MotionEvent.AXIS_RELATIVE_Y, event.source) != null
      }
      MotionEvent.ACTION_POINTER_DOWN, MotionEvent.ACTION_POINTER_UP -> {
        if (event.actionMasked == MotionEvent.ACTION_POINTER_DOWN) {
          if (multipleFingers || event.pointerCount != 2) tapCandidate = false
          val i = event.actionIndex
          tapOrigins[event.getPointerId(i)] = event.getX(i) to event.getY(i)
        }
        multipleFingers = true
        val lifted = if (event.actionMasked == MotionEvent.ACTION_POINTER_UP) event.actionIndex else -1
        val remaining = event.pointerCount - if (lifted < 0) 0 else 1
        if (remaining == 2) {
          var x = 0f
          var y = 0f
          for (i in 0 until event.pointerCount) {
            if (i == lifted) continue
            x += event.getX(i)
            y += event.getY(i)
          }
          lastX = x / 2
          lastY = y / 2
        }
        scrollRemainderX = 0f
        scrollRemainderY = 0f
      }
      MotionEvent.ACTION_MOVE -> {
        if (fingerId < 0) return true
        if (event.pointerCount == 2 && multipleFingers) {
          scrollPair(event)
        } else if (!multipleFingers && event.pointerCount == 1 && event.getPointerId(0) == fingerId) {
          // Android 15 can expose only absolute axes. A declared relative axis may validly be zero.
          val dx = if (relativeX) CapturedMouseMotion.deltaX(event) else event.x - lastX
          val dy = if (relativeY) CapturedMouseMotion.deltaY(event) else event.y - lastY
          lastX = event.x
          lastY = event.y
          if (dx != 0f || dy != 0f) move(dx, dy)
        }
      }
      MotionEvent.ACTION_UP -> {
        if (tapCandidate && tapOrigins.containsKey(event.getPointerId(0)) &&
          event.eventTime - contactStartTime <= ViewConfiguration.getDoubleTapTimeout() &&
          (event.flags and MotionEvent.FLAG_CANCELED) == 0) {
          tap(if (multipleFingers) 3 else 1)
        }
        reset()
      }
      MotionEvent.ACTION_CANCEL -> reset()
      MotionEvent.ACTION_BUTTON_PRESS, MotionEvent.ACTION_BUTTON_RELEASE -> {
        tapCandidate = false
        return false // Forward the physical button exactly once via the normal mouse handler.
      }
      else -> return false
    }
    return true
  }

  private fun unitsPerMm(device: InputDevice?, axis: Int, nominalSizeMm: Float): Float {
    val range = device?.getMotionRange(axis, InputDevice.SOURCE_TOUCHPAD) ?: return 1f
    return if (range.resolution > 0f) range.resolution else (range.range / nominalSizeMm).coerceAtLeast(1f)
  }

  private fun checkTap(event: MotionEvent) {
    if (event.buttonState != 0 || (event.flags and MotionEvent.FLAG_CANCELED) != 0) {
      tapCandidate = false
      return
    }
    for (i in 0 until event.pointerCount) {
      val start = tapOrigins[event.getPointerId(i)] ?: continue
      fun moved(x: Float, y: Float) =
        abs(x - start.first) > 1.5f * unitsPerMmX || abs(y - start.second) > 1.5f * unitsPerMmY
      if (moved(event.getX(i), event.getY(i)) || (0 until event.historySize).any {
          moved(event.getHistoricalX(i, it), event.getHistoricalY(i, it))
        }) {
        tapCandidate = false
        return
      }
    }
  }

  private fun scrollPair(event: MotionEvent) {
    val x = (event.getX(0) + event.getX(1)) / 2
    val y = (event.getY(0) + event.getY(1)) / 2
    // Drag content with the fingers. Accumulate in physical units to avoid one wheel tick per sample.
    scrollRemainderX += (lastX - x) / (3f * unitsPerMmX)
    scrollRemainderY += (lastY - y) / (3f * unitsPerMmY)
    lastX = x
    lastY = y
    val ticksX = scrollRemainderX.toInt()
    val ticksY = scrollRemainderY.toInt()
    scrollRemainderX -= ticksX
    scrollRemainderY -= ticksY
    if (ticksX != 0 || ticksY != 0) {
      tapCandidate = false
      scroll(20f * ticksX, 20f * ticksY)
    }
  }
}
