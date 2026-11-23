package com.cloudplayplus.hardware_simulator

import android.view.MotionEvent
import kotlin.test.Test
import kotlin.test.assertEquals
import org.mockito.Mockito

internal class CapturedPointerButtonsTest {
  private val edges = mutableListOf<Pair<Int, Boolean>>()
  private val timers = mutableListOf<Runnable>()
  private val buttons = CapturedPointerButtons({ id, down -> edges.add(id to down) }, timers::add)

  private fun observe(action: Int, mask: Int, button: Int = 0, deviceId: Int = 1) {
    val event = Mockito.mock(MotionEvent::class.java)
    Mockito.`when`(event.actionMasked).thenReturn(action)
    Mockito.`when`(event.deviceId).thenReturn(deviceId)
    Mockito.`when`(event.buttonState).thenReturn(mask)
    Mockito.`when`(event.actionButton).thenReturn(button)
    buttons.observe(event)
  }

  @Test fun maskOnlyLeftAndRightAndDuplicateActions() {
    observe(MotionEvent.ACTION_DOWN, 1)
    observe(MotionEvent.ACTION_BUTTON_PRESS, 1, 1)
    observe(MotionEvent.ACTION_MOVE, 3)
    observe(MotionEvent.ACTION_MOVE, 2)
    observe(MotionEvent.ACTION_BUTTON_RELEASE, 2, 1)
    observe(MotionEvent.ACTION_UP, 0)
    assertEquals(listOf(1 to true, 3 to true, 1 to false, 3 to false), edges)
  }

  @Test fun actionOnlyPressStaysHeldAcrossMotion() {
    observe(MotionEvent.ACTION_BUTTON_PRESS, 0, 2)
    observe(MotionEvent.ACTION_MOVE, 0)
    assertEquals(listOf(3 to true), edges)
    observe(MotionEvent.ACTION_BUTTON_RELEASE, 0, 2)
    assertEquals(listOf(3 to true, 3 to false), edges)
  }
  @Test fun maskOnlyPressOnOtherDeviceSurvivesUnrelatedMotion() {
    observe(MotionEvent.ACTION_MOVE, 2)
    observe(MotionEvent.ACTION_HOVER_MOVE, 0, deviceId = 2)
    assertEquals(listOf(3 to true), edges)
    buttons.reset()
    assertEquals(listOf(3 to true, 3 to false), edges)
  }

  @Test fun delayedTapDoesNotReleaseAnOverlappingPhysicalPress() {
    buttons.tap(3)
    assertEquals(listOf(3 to true), edges)
    observe(MotionEvent.ACTION_BUTTON_PRESS, 2, 2)
    timers.single().run()
    observe(MotionEvent.ACTION_CANCEL, 0)
    assertEquals(listOf(3 to true, 3 to false), edges)
  }

  @Test fun rapidTapsAndResetLeaveNoStaleRelease() {
    buttons.tap(1)
    buttons.tap(1)
    timers.first().run()
    buttons.reset()
    timers.last().run()
    assertEquals(listOf(1 to true, 1 to false, 1 to true, 1 to false), edges)
  }
}
