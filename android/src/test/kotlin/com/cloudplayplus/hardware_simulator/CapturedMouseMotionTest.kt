package com.cloudplayplus.hardware_simulator

import android.view.InputDevice
import android.view.MotionEvent
import kotlin.test.Test
import kotlin.test.assertEquals
import org.mockito.Mockito

internal class CapturedMouseMotionTest {
  private fun event(source: Int, historySize: Int = 0): MotionEvent {
    val event = Mockito.mock(MotionEvent::class.java)
    Mockito.`when`(event.source).thenReturn(source)
    Mockito.`when`(event.historySize).thenReturn(historySize)
    return event
  }

  @Test
  fun mouseIncludesAllHistoricalDeltasOnBothAxes() {
    val event = event(InputDevice.SOURCE_MOUSE_RELATIVE, 2)
    Mockito.`when`(event.getAxisValue(MotionEvent.AXIS_X)).thenReturn(5f)
    Mockito.`when`(event.getHistoricalAxisValue(MotionEvent.AXIS_X, 0)).thenReturn(3f)
    Mockito.`when`(event.getHistoricalAxisValue(MotionEvent.AXIS_X, 1)).thenReturn(4f)
    Mockito.`when`(event.getAxisValue(MotionEvent.AXIS_Y)).thenReturn(-5f)
    Mockito.`when`(event.getHistoricalAxisValue(MotionEvent.AXIS_Y, 0)).thenReturn(-3f)
    Mockito.`when`(event.getHistoricalAxisValue(MotionEvent.AXIS_Y, 1)).thenReturn(-4f)
    assertEquals(12f, CapturedMouseMotion.deltaX(event))
    assertEquals(-12f, CapturedMouseMotion.deltaY(event))
  }

  @Test
  fun mouseKeepsFractionalMovementAndOppositeDeltasCancel() {
    val event = event(InputDevice.SOURCE_MOUSE_RELATIVE, 1)
    Mockito.`when`(event.getAxisValue(MotionEvent.AXIS_X)).thenReturn(0.25f)
    Mockito.`when`(event.getHistoricalAxisValue(MotionEvent.AXIS_X, 0)).thenReturn(0.5f)
    Mockito.`when`(event.getAxisValue(MotionEvent.AXIS_Y)).thenReturn(8f)
    Mockito.`when`(event.getHistoricalAxisValue(MotionEvent.AXIS_Y, 0)).thenReturn(-8f)
    assertEquals(0.75f, CapturedMouseMotion.deltaX(event))
    assertEquals(0f, CapturedMouseMotion.deltaY(event))
  }

  @Test
  fun mouseWithoutHistoryUsesCurrentXYEvenWhenRelativeAxesDiffer() {
    val event = event(InputDevice.SOURCE_MOUSE_RELATIVE)
    Mockito.`when`(event.getAxisValue(MotionEvent.AXIS_X)).thenReturn(0f)
    Mockito.`when`(event.getAxisValue(MotionEvent.AXIS_Y)).thenReturn(-2f)
    Mockito.`when`(event.getAxisValue(MotionEvent.AXIS_RELATIVE_X)).thenReturn(100f)
    Mockito.`when`(event.getAxisValue(MotionEvent.AXIS_RELATIVE_Y)).thenReturn(200f)
    assertEquals(0f, CapturedMouseMotion.deltaX(event))
    assertEquals(-2f, CapturedMouseMotion.deltaY(event))
  }

  @Test
  fun touchpadUsesRelativeHistoryAndDoesNotFallBackOnZeroAxis() {
    val event = event(InputDevice.SOURCE_TOUCHPAD, 1)
    Mockito.`when`(event.getAxisValue(MotionEvent.AXIS_X)).thenReturn(1000f)
    Mockito.`when`(event.getAxisValue(MotionEvent.AXIS_Y)).thenReturn(2000f)
    Mockito.`when`(event.getHistoricalAxisValue(MotionEvent.AXIS_X, 0)).thenReturn(900f)
    Mockito.`when`(event.getHistoricalAxisValue(MotionEvent.AXIS_Y, 0)).thenReturn(1900f)
    Mockito.`when`(event.getAxisValue(MotionEvent.AXIS_RELATIVE_X)).thenReturn(0f)
    Mockito.`when`(event.getHistoricalAxisValue(MotionEvent.AXIS_RELATIVE_X, 0)).thenReturn(0f)
    Mockito.`when`(event.getAxisValue(MotionEvent.AXIS_RELATIVE_Y)).thenReturn(2f)
    Mockito.`when`(event.getHistoricalAxisValue(MotionEvent.AXIS_RELATIVE_Y, 0)).thenReturn(3f)
    assertEquals(0f, CapturedMouseMotion.deltaX(event))
    assertEquals(5f, CapturedMouseMotion.deltaY(event))
  }

  @Test
  fun nextCallbackDoesNotReplayPreviousHistory() {
    val first = event(InputDevice.SOURCE_MOUSE_RELATIVE, 1)
    Mockito.`when`(first.getAxisValue(MotionEvent.AXIS_X)).thenReturn(5f)
    Mockito.`when`(first.getHistoricalAxisValue(MotionEvent.AXIS_X, 0)).thenReturn(3f)
    val next = event(InputDevice.SOURCE_MOUSE_RELATIVE)
    Mockito.`when`(next.getAxisValue(MotionEvent.AXIS_X)).thenReturn(2f)
    assertEquals(8f, CapturedMouseMotion.deltaX(first))
    assertEquals(2f, CapturedMouseMotion.deltaX(next))
  }
}
