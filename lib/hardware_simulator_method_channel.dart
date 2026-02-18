import 'dart:io' /* if (dart.library.js) 'dart:html'*/;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'dart:async';

import 'hardware_simulator_platform_interface.dart';
import 'display_data.dart';

/// An implementation of [HardwareSimulatorPlatform] that uses method channels.
class MethodChannelHardwareSimulator extends HardwareSimulatorPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('hardware_simulator');
  bool isinitialized = false;

  void init() {
    methodChannel.setMethodCallHandler((call) async {
      if (call.method == "onCursorMoved") {
        for (var callback in cursorMovedCallbacks) {
          callback(call.arguments['dx'], call.arguments['dy']);
        }
      } else if (call.method == "onCursorButton") {
        for (var callback in cursorPressedCallbacks) {
          callback(call.arguments['buttonId'], call.arguments['isDown']);
        }
      }
      // used only when locked cursor and using keyboard for android.
      else if (call.method == "onKeyboardButton") {
        for (var callback in keyBoardPressedCallbacks) {
          callback(call.arguments['buttonId'], call.arguments['isDown']);
        }
      } else if (call.method == "onCursorScroll") {
        for (var callback in cursorWheelCallbacks) {
          callback(call.arguments['dx'], call.arguments['dy']);
        }
      } else if (call.method == "onCursorImageMessage") {
        int callbackID = call.arguments['callbackID'];
        if (cursorImageCallbacks.containsKey(callbackID)) {
          cursorImageCallbacks[callbackID]!(call.arguments['message'],
              call.arguments['msg_info'], call.arguments['cursorImage']);
        }
      } else if (call.method == "onCursorPositionMessage") {
        int callbackID = call.arguments['callbackID'];
        if (cursorPositionCallbacks.containsKey(callbackID)) {
          // Directly get double values from arguments
          double xPercent = call.arguments['xPercent'];
          double yPercent = call.arguments['yPercent'];

          cursorPositionCallbacks[callbackID]!(call.arguments['message'],
              call.arguments['screenId'], xPercent, yPercent);
        }
      } else if (call.method == "onKeyBlocked") {
        int keyCode = call.arguments['keyCode'];
        bool isDown = call.arguments['isDown'];
        for (var callback in keyBlockedCallbacks) {
          callback(keyCode, isDown);
        }
      } else if (call.method == "onDisplayCountChanged") {
        int callbackID = call.arguments['callbackID'];
        if (displayCountCallbacks.containsKey(callbackID)) {
          displayCountCallbacks[callbackID]!(call.arguments['displayCount']);
        }
      }
      return null;
    });
    isinitialized = true;
  }

  @override
  Future<String?> getPlatformVersion() async {
    final version =
        await methodChannel.invokeMethod<String>('getPlatformVersion');
    return version;
  }

  Future<bool?> getIsMouseConnected() {
    return methodChannel.invokeMethod<bool>('isMouseConnected');
  }

  @override
  Future<void> lockCursor() async {
    // NOTE: cloudplayplus_nova 版本移除了 pointer_lock 依赖，统一走 native 实现（best-effort）。
    await methodChannel.invokeMethod('lockCursor');
  }

  @override
  Future<void> unlockCursor() async {
    await methodChannel.invokeMethod('unlockCursor');
  }

  @override
  Future<int?> getMonitorCount() async {
    if (kIsWeb || Platform.isAndroid || Platform.isIOS) {
      return 1;
    }
    final count = await methodChannel.invokeMethod('getMonitorCount');
    return count;
  }

  @override
  Future<bool> registerService() async {
    if (!Platform.isWindows) {
      return false;
    }
    bool result = await methodChannel.invokeMethod('registerService');
    return result;
  }

  @override
  Future<void> unregisterService() async {
    if (!Platform.isWindows) {
      return;
    }
    methodChannel.invokeMethod('unregisterService');
  }

  @override
  Future<bool> isRunningAsSystem() async {
    if (!Platform.isWindows) {
      return true;
    }
    final result = await methodChannel.invokeMethod<bool>('isRunningAsSystem');
    return result!;
  }

  @override
  Future<void> showNotification(String content) async {
    if (!Platform.isWindows) {
      return;
    }
    methodChannel.invokeMethod('showNotification', {
      'content': content,
    });
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

  final List<KeyboardPressedCallback> keyBoardPressedCallbacks = [];

  @override
  void addKeyboardPressed(KeyboardPressedCallback callback) {
    if (!isinitialized) init();
    keyBoardPressedCallbacks.add(callback);
  }

  @override
  void removeKeyboardPressed(KeyboardPressedCallback callback) {
    keyBoardPressedCallbacks.remove(callback);
  }

  final List<KeyBlockedCallback> keyBlockedCallbacks = [];

  @override
  void addKeyBlocked(KeyBlockedCallback callback) {
    if (!isinitialized) init();
    keyBlockedCallbacks.add(callback);
  }

  @override
  void removeKeyBlocked(KeyBlockedCallback callback) {
    keyBlockedCallbacks.remove(callback);
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

  final Map<int, CursorImageUpdatedCallback> cursorImageCallbacks = {};
  final Map<int, CursorPositionUpdatedCallback> cursorPositionCallbacks = {};
  final Map<int, DisplayCountChangedCallback> displayCountCallbacks = {};

  @override
  void addCursorImageUpdated(
      CursorImageUpdatedCallback callback, int callbackId, bool hookAll) {
    if (kIsWeb || Platform.isIOS || Platform.isAndroid) {
      return;
    }
    if (!isinitialized) init();
    cursorImageCallbacks[callbackId] = callback;
    methodChannel.invokeMethod('hookCursorImage', {
      'callbackID': callbackId,
      'hookAll': hookAll,
    });
  }

  @override
  void removeCursorImageUpdated(int callbackId) {
    if (cursorImageCallbacks.containsKey(callbackId)) {
      cursorImageCallbacks.remove(callbackId);
    }
    methodChannel.invokeMethod('unhookCursorImage', {
      'callbackID': callbackId,
    });
  }

  @override
  void addCursorPositionUpdated(
      CursorPositionUpdatedCallback callback, int callbackId) {
    if (kIsWeb || Platform.isIOS || Platform.isAndroid) {
      return;
    }
    if (!isinitialized) init();
    cursorPositionCallbacks[callbackId] = callback;
    methodChannel.invokeMethod('hookCursorPosition', {
      'callbackID': callbackId,
    });
  }

  @override
  void removeCursorPositionUpdated(int callbackId) {
    if (cursorPositionCallbacks.containsKey(callbackId)) {
      cursorPositionCallbacks.remove(callbackId);
    }
    methodChannel.invokeMethod('unhookCursorPosition', {
      'callbackID': callbackId,
    });
  }

  @override
  void addDisplayCountChangedCallback(
      DisplayCountChangedCallback callback, int callbackId) {
    if (kIsWeb || Platform.isIOS || Platform.isAndroid) {
      return;
    }
    if (!isinitialized) init();
    if (displayCountCallbacks.containsKey(callbackId)) {
      displayCountCallbacks.remove(callbackId);
    }
    displayCountCallbacks[callbackId] = callback;
    methodChannel.invokeMethod('addDisplayCountChangedCallback', {
      'callbackID': callbackId,
    });
  }

  @override
  void removeDisplayCountChangedCallback(int callbackId) {
    if (displayCountCallbacks.containsKey(callbackId)) {
      displayCountCallbacks.remove(callbackId);
    }
    methodChannel.invokeMethod('removeDisplayCountChangedCallback', {
      'callbackID': callbackId,
    });
  }

  @override
  Future<void> performKeyEvent(int keyCode, bool isDown) async {
    await methodChannel.invokeMethod('KeyPress', {
      'code': keyCode,
      'isDown': isDown,
    });
  }

  // Relative mouse movement.
  @override
  Future<void> performMouseMoveRelative(
      double deltax, double deltay, int screenId) async {
    await methodChannel.invokeMethod('mouseMoveR', {
      'x': deltax,
      'y': deltay,
      'screenId': screenId,
    });
  }

  // Absolute mouse movement. x, y is the percentage of the screen ranged from 0 - 1.
  @override
  Future<void> performMouseMoveAbsl(
      double percentx, double percenty, int screenId) async {
    await methodChannel.invokeMethod('mouseMoveA', {
      'x': percentx,
      'y': percenty,
      'screenId': screenId,
    });
  }

  @override
  Future<void> performMouseMoveToWindowPosition(
      double percentx, double percenty) async {
    await methodChannel.invokeMethod('mouseMoveToWindowPosition', {
      'x': percentx,
      'y': percenty,
    });
  }

  @override
  Future<void> performMouseClick(int buttonId, bool isDown) async {
    await methodChannel.invokeMethod('mousePress', {
      'buttonId': buttonId,
      'isDown': isDown,
    });
  }

  @override
  Future<void> performMouseScroll(double dx, double dy) async {
    await methodChannel.invokeMethod('mouseScroll', {
      'dx': dx,
      'dy': dy,
    });
  }

  @override
  Future<void> performTouchEvent(
      double x, double y, int touchId, bool isDown, int screenId) async {
    await methodChannel.invokeMethod('touchEvent', {
      'x': x,
      'y': y,
      'touchId': touchId,
      'isDown': isDown,
      'screenId': screenId,
    });
  }

  @override
  Future<void> performTouchMove(
      double x, double y, int touchId, int screenId) async {
    await methodChannel.invokeMethod('touchMove', {
      'x': x,
      'y': y,
      'touchId': touchId,
      'screenId': screenId,
    });
  }

  @override
  Future<void> performPenEvent(double x, double y, bool isDown, bool hasButton,
      double pressure, double rotation, double tilt, int screenId) async {
    await methodChannel.invokeMethod('penEvent', {
      'x': x,
      'y': y,
      'isDown': isDown,
      'hasButton': hasButton,
      'pressure': pressure,
      'rotation': rotation,
      'tilt': tilt,
      'screenId': screenId,
    });
  }

  @override
  Future<void> performPenMove(double x, double y, bool hasButton,
      double pressure, double rotation, double tilt, int screenId) async {
    await methodChannel.invokeMethod('penMove', {
      'x': x,
      'y': y,
      'hasButton': hasButton,
      'pressure': pressure,
      'rotation': rotation,
      'tilt': tilt,
      'screenId': screenId,
    });
  }

  @override
  Future<int> createGameController() async {
    if (!Platform.isWindows) return -1;
    final gamepadId =
        await methodChannel.invokeMethod<int>('createGameController');
    return gamepadId!;
  }

  @override
  Future<void> removeGameController(int controllerId) async {
    await methodChannel.invokeMethod('removeGameController', {
      'id': controllerId,
    });
  }

  @override
  Future<void> doControllerAction(int controllerId, String action) async {
    await methodChannel.invokeMethod(
      'doControlAction',
      <String, dynamic>{'id': controllerId, 'action': action},
    );
  }

  @override
  Future<bool> initParsecVdd() async {
    return await methodChannel.invokeMethod('initParsecVdd');
  }

  @override
  Future<int> createDisplay() async {
    return await methodChannel.invokeMethod('createDisplay');
  }

  @override
  Future<bool> removeDisplay(int displayUid) async {
    return await methodChannel.invokeMethod('removeDisplay', {
      'displayUid': displayUid,
    });
  }

  @override
  Future<int> getAllDisplays() async {
    return await methodChannel.invokeMethod('getAllDisplays');
  }

  @override
  Future<List<DisplayData>> getDisplayList() async {
    final result = await methodChannel.invokeMethod('getDisplayList');
    if (result == null) return [];

    final List<dynamic> dynamicList = List<dynamic>.from(result);
    final List<Map<String, dynamic>> mapList = dynamicList.map((item) {
      return Map<String, dynamic>.from(item as Map);
    }).toList();

    return mapList.map((map) => DisplayData.fromMap(map)).toList();
  }

  @override
  Future<bool> changeDisplaySettings(
      int displayUid, int width, int height, int refreshRate,
      {int? bitDepth}) async {
    final Map<String, dynamic> arguments = {
      'displayUid': displayUid,
      'width': width,
      'height': height,
      'refreshRate': refreshRate,
    };

    if (bitDepth != null) {
      arguments['bitDepth'] = bitDepth;
    }

    return await methodChannel.invokeMethod('changeDisplaySettings', arguments);
  }

  @override
  Future<List<Map<String, dynamic>>> getDisplayConfigs(int displayUid) async {
    final result = await methodChannel.invokeMethod('getDisplayConfigs', {
      'displayUid': displayUid,
    });

    return List<Map<String, dynamic>>.from(
        result.map((item) => Map<String, dynamic>.from(item)));
  }

  @override
  Future<List<Map<String, dynamic>>> getCustomDisplayConfigs() async {
    final result = await methodChannel.invokeMethod('getCustomDisplayConfigs');

    return List<Map<String, dynamic>>.from(
        result.map((item) => Map<String, dynamic>.from(item)));
  }

  @override
  Future<bool> setCustomDisplayConfigs(
      List<Map<String, dynamic>> configs) async {
    return await methodChannel.invokeMethod('setCustomDisplayConfigs', {
      'configs': configs,
    });
  }

  @override
  Future<bool> setDisplayOrientation(int displayUid, int orientation) async {
    return await methodChannel.invokeMethod('setDisplayOrientation', {
      'displayUid': displayUid,
      'orientation': orientation,
    });
  }

  @override
  Future<int> getDisplayOrientation(int displayUid) async {
    return await methodChannel.invokeMethod('getDisplayOrientation', {
      'displayUid': displayUid,
    });
  }

  @override
  Future<bool> setMultiDisplayMode(int mode, int primaryDisplayId) async {
    return await methodChannel.invokeMethod('setMultiDisplayMode', {
      'mode': mode,
      'primaryDisplayId': primaryDisplayId,
    });
  }

  @override
  Future<int> getCurrentMultiDisplayMode() async {
    return await methodChannel.invokeMethod('getCurrentMultiDisplayMode');
  }

  @override
  Future<bool> setPrimaryDisplayOnly(int displayUid) async {
    return await methodChannel.invokeMethod('setPrimaryDisplayOnly', {
      'displayUid': displayUid,
    });
  }

  @override
  Future<bool> restoreDisplayConfiguration() async {
    return await methodChannel.invokeMethod('restoreDisplayConfiguration');
  }

  @override
  Future<bool> hasPendingConfiguration() async {
    return await methodChannel.invokeMethod('hasPendingConfiguration');
  }

  @override
  Future<bool> putImmersiveModeEnabled(bool enabled) async {
    return await methodChannel.invokeMethod('putImmersiveModeEnabled', {
      'enabled': enabled,
    });
  }

  @override
  Future<void> setDragWindowContents(bool enabled) async {
    await methodChannel.invokeMethod('setDragWindowContents', {
      'enabled': enabled,
    });
  }

  @override
  Future<void> clearAllPressedEvents() async {
    await methodChannel.invokeMethod('clearAllPressedEvents');
  }

  @override
  Future<bool> setPrimaryDisplay(int displayIndex) async {
    return await methodChannel.invokeMethod('setPrimaryDisplay', {
      'displayIndex': displayIndex,
    });
  }

  @override
  Future<void> updateStaticMonitors() async {
    if (!Platform.isWindows) {
      return;
    }
    await methodChannel.invokeMethod('updateStaticMonitors');
  }
}
