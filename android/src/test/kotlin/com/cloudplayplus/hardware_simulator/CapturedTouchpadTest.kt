package com.cloudplayplus.hardware_simulator

import android.view.InputDevice
import android.view.MotionEvent
import android.view.ViewConfiguration
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import org.mockito.Mockito

internal class CapturedTouchpadTest {
  private val moves = mutableListOf<Pair<Float, Float>>()
  private val scrolls = mutableListOf<Pair<Float, Float>>()
  private var clicks = 0
  private val pad = CapturedTouchpad({ x, y -> moves.add(x to y) }, { clicks++ }, { x, y -> scrolls.add(x to y) })
  private val device = Mockito.mock(InputDevice::class.java)

  private fun contact(action: Int, x: Float, y: Float, time: Long = 1000L, fingers: Int = 1): MotionEvent {
    val e = Mockito.mock(MotionEvent::class.java)
    Mockito.`when`(e.isFromSource(InputDevice.SOURCE_TOUCHPAD)).thenReturn(true)
    Mockito.`when`(e.source).thenReturn(InputDevice.SOURCE_TOUCHPAD)
    Mockito.`when`(e.device).thenReturn(device)
    Mockito.`when`(e.actionMasked).thenReturn(action)
    Mockito.`when`(e.eventTime).thenReturn(time)
    Mockito.`when`(e.x).thenReturn(x)
    Mockito.`when`(e.y).thenReturn(y)
    Mockito.`when`(e.pointerCount).thenReturn(fingers)
    for (i in 0 until fingers) {
      Mockito.`when`(e.getX(i)).thenReturn(x + i * 40)
      Mockito.`when`(e.getY(i)).thenReturn(y)
    }
    return e
  }

  @Test fun noRelativeAxesMoveByContactDeltaAndResetBetweenFingers() {
    pad.handle(contact(MotionEvent.ACTION_DOWN, 500f, 500f))
    pad.handle(contact(MotionEvent.ACTION_MOVE, 516f, 508f))
    pad.handle(contact(MotionEvent.ACTION_UP, 516f, 508f))
    pad.handle(contact(MotionEvent.ACTION_DOWN, 1400f, 800f))
    pad.handle(contact(MotionEvent.ACTION_MOVE, 1402f, 796f))
    pad.handle(contact(MotionEvent.ACTION_CANCEL, 1402f, 796f))
    pad.handle(contact(MotionEvent.ACTION_MOVE, 1450f, 800f))
    assertEquals(listOf(16f to 8f, 2f to -4f), moves)
    assertEquals(0, clicks)
  }

  @Test fun declaredRelativeAxisPreservesZeroAndUsesItsHistory() {
    val range = Mockito.mock(InputDevice.MotionRange::class.java)
    Mockito.`when`(device.getMotionRange(MotionEvent.AXIS_RELATIVE_X, InputDevice.SOURCE_TOUCHPAD)).thenReturn(range)
    pad.handle(contact(MotionEvent.ACTION_DOWN, 100f, 10f))
    pad.handle(contact(MotionEvent.ACTION_MOVE, 120f, 11f))
    val move = contact(MotionEvent.ACTION_MOVE, 140f, 13f)
    Mockito.`when`(move.historySize).thenReturn(1)
    Mockito.`when`(move.getHistoricalAxisValue(MotionEvent.AXIS_RELATIVE_X, 0)).thenReturn(4f)
    Mockito.`when`(move.getAxisValue(MotionEvent.AXIS_RELATIVE_X)).thenReturn(1f)
    pad.handle(move)
    assertEquals(listOf(0f to 1f, 5f to 2f), moves)
  }

  @Test fun tapUsesObservedDownEventTimeAndPhysicalClickIsNotDuplicated() {
    Mockito.mockStatic(ViewConfiguration::class.java).use { config ->
      config.`when`<Int> { ViewConfiguration.getDoubleTapTimeout() }.thenReturn(300)
      pad.handle(contact(MotionEvent.ACTION_DOWN, 10f, 10f))
      pad.handle(contact(MotionEvent.ACTION_UP, 10f, 10f, 1040))
      pad.handle(contact(MotionEvent.ACTION_DOWN, 10f, 10f))
      pad.handle(contact(MotionEvent.ACTION_UP, 10f, 10f, 1600))
      pad.handle(contact(MotionEvent.ACTION_DOWN, 10f, 10f))
      assertFalse(pad.handle(contact(MotionEvent.ACTION_BUTTON_PRESS, 10f, 10f)))
      assertFalse(pad.handle(contact(MotionEvent.ACTION_BUTTON_RELEASE, 10f, 10f)))
      pad.handle(contact(MotionEvent.ACTION_UP, 10f, 10f, 1040))
      assertEquals(1, clicks)
    }
  }

  @Test fun twoFingersScrollWithoutMovingCursorOrClickingOnLift() {
    pad.handle(contact(MotionEvent.ACTION_DOWN, 100f, 100f))
    pad.handle(contact(MotionEvent.ACTION_POINTER_DOWN, 100f, 100f, fingers = 2))
    pad.handle(contact(MotionEvent.ACTION_MOVE, 100f, 102f, fingers = 2))
    pad.handle(contact(MotionEvent.ACTION_MOVE, 100f, 104f, fingers = 2))
    pad.handle(contact(MotionEvent.ACTION_POINTER_UP, 100f, 104f, fingers = 2))
    pad.handle(contact(MotionEvent.ACTION_MOVE, 110f, 104f))
    pad.handle(contact(MotionEvent.ACTION_UP, 110f, 104f))
    assertEquals(listOf(0f to -20f), scrolls)
    assertEquals(emptyList(), moves)
    assertEquals(0, clicks)
  }
}
