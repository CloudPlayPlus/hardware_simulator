package com.cloudplayplus.hardware_simulator

import android.view.KeyEvent

interface HardwareSimulatorActivityBridge {
  fun registerLockedKeyEventHandler(handler: ((KeyEvent) -> Boolean)?)
}
