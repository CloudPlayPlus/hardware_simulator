// In order to *not* need this ignore, consider extracting the "web" version
// of your plugin as a separate package, instead of inlining it in the same
// package as the core of your plugin.
// ignore: avoid_web_libraries_in_flutter

import 'package:hardware_simulator/hardware_simulator_platform_interface.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';
import 'package:web/web.dart' as web;

/// A web implementation of the HardwareSimulatorPlatform of the HardwareSimulator plugin.
class HardwareSimulatorPluginWeb extends HardwareSimulatorPlatform {
  /// Constructs a HardwareSimulatorWeb
  HardwareSimulatorPluginWeb();

  static void registerWith(Registrar registrar) {
    HardwareSimulatorPlatform.instance = HardwareSimulatorPluginWeb();
    //取消右键菜单
    web.EventStreamProviders.contextMenuEvent
        .forTarget(web.document)
        .listen((event) {
      event.preventDefault(); // 阻止默认的右键菜单
    });
  }

  /// Returns a [String] containing the version of the platform.
  @override
  Future<String?> getPlatformVersion() async {
    final version = web.window.navigator.userAgent;
    return version;
  }

  @override
  Future<int?> getMonitorCount() async {
    return 1;
  }

  @override
  Future<void> lockCursor() async {
    web.document.body?.requestPointerLock();
  }

  @override
  Future<void> unlockCursor() async {
    web.document.exitPointerLock();
  }

  bool isinitialized = false;

  Map<int, int> webToWindowsMouseButtonMap = {
    0: 1, //leftbutton
    1: 2, //middlebutton
    2: 3, //rightbutton
    3: 4, //x1
    4: 5, //x2
  };

  void init() {
    // 监听鼠标移动事件
    web.EventStreamProviders.mouseMoveEvent
        .forTarget(web.document)
        .listen((event) {
      // 使用 movementX 和 movementY 获取相对位移
      double dx = event.movementX.toDouble();
      double dy = event.movementY.toDouble();
      for (var callback in cursorMovedCallbacks) {
        callback(dx, dy);
      }
    });

    web.EventStreamProviders.wheelEvent.forTarget(web.document).listen((event) {
      double dx = event.deltaX.toDouble();
      double dy = event.deltaY.toDouble();
      for (var callback in cursorWheelCallbacks) {
        callback(dx, dy);
      }
    });

    web.EventStreamProviders.mouseDownEvent
        .forTarget(web.document)
        .listen((event) {
      int buttonId = event.button;
      if (webToWindowsMouseButtonMap.containsKey(buttonId)) {
        buttonId = webToWindowsMouseButtonMap[buttonId]!;
      }
      for (var callback in cursorPressedCallbacks) {
        callback(buttonId, true);
      }
    });

    web.EventStreamProviders.mouseUpEvent
        .forTarget(web.document)
        .listen((event) {
      int buttonId = event.button;
      if (webToWindowsMouseButtonMap.containsKey(buttonId)) {
        buttonId = webToWindowsMouseButtonMap[buttonId]!;
        for (var callback in cursorPressedCallbacks) {
          callback(buttonId, false);
        }
      }
    });

    //This is a workaround for https://github.com/flutter/engine/pull/19632.
    //You also need to care about engine/src/flutter/lib/web_ui/lib/src/engine/keyboard_binding.dart
    //to cancel the guard. CloudPlayPlus does not need this, you can do it as you like.
    //Currently I don't know why the fix does not work for my macbook.
    /*web.EventStreamProviders.keyDownEvent
        .forTarget(web.document)
        .listen((event){
      for (var callback in keyPressedCallbacks){
        callback(event.keyCode,true);
      }
    });*/

    isinitialized = true;
  }

  final List<CursorMovedCallback> cursorMovedCallbacks = [];

  @override
  void addCursorMoved(CursorMovedCallback callback) {
    if (!isinitialized) init();
    cursorMovedCallbacks.add(callback);
  }

  @override
  void removeCursorMoved(CursorMovedCallback callback) {
    cursorMovedCallbacks.remove(callback);
  }

  final List<CursorPressedCallback> cursorPressedCallbacks = [];

  @override
  void addCursorPressed(CursorPressedCallback callback) {
    if (!isinitialized) init();
    cursorPressedCallbacks.add(callback);
  }

  @override
  void removeCursorPressed(CursorPressedCallback callback) {
    cursorPressedCallbacks.remove(callback);
  }

  final List<CursorWheelCallback> cursorWheelCallbacks = [];
  @override
  void addCursorWheel(CursorWheelCallback callback) {
    if (!isinitialized) init();
    cursorWheelCallbacks.add(callback);
  }

  @override
  void removeCursorWheel(CursorWheelCallback callback) {
    cursorWheelCallbacks.remove(callback);
  }
}
