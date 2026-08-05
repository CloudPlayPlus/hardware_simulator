import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'hardware_simulator_method_channel.dart';
import 'display_data.dart';

typedef CursorMovedCallback = void Function(double x, double y);
typedef CursorPressedCallback = void Function(int button, bool isDown);
typedef KeyboardPressedCallback = void Function(int button, bool isDown);
typedef KeyBlockedCallback = void Function(int keyCode, bool isDown);
typedef CursorWheelCallback = void Function(double deltaX, double deltaY);
typedef TrackpadScrollCallback = void Function(TrackpadScrollEvent event);
typedef WindowsTextInputDecisionCallback = void Function(
  WindowsTextInputDecision decision,
);
typedef CursorImageUpdatedCallback = void Function(
    int message, int messageInfo, Uint8List cursorImage);
typedef CursorPositionUpdatedCallback = void Function(
    int message, int screenId, double xPercent, double yPercent);
typedef DisplayCountChangedCallback = void Function(int displayCount);

/// Platform-independent lifecycle for a native precision trackpad gesture.
enum TrackpadScrollPhase {
  none,
  mayBegin,
  began,
  changed,
  stationary,
  ended,
  cancelled,
}

/// A precision trackpad scroll event captured by the platform embedder.
///
/// [x] and [y] use Flutter view coordinates. Deltas use page direction:
/// positive x scrolls right and positive y scrolls down. Every platform
/// implementation normalizes its native convention to this contract. The
/// resulting page direction follows the user's platform scroll-direction
/// preference.
@immutable
class TrackpadScrollEvent {
  const TrackpadScrollEvent({
    required this.x,
    required this.y,
    required this.deltaX,
    required this.deltaY,
    required this.phase,
    required this.isMomentum,
  });

  final double x;
  final double y;
  final double deltaX;
  final double deltaY;
  final TrackpadScrollPhase phase;
  final bool isMomentum;
}

/// 远端左键抬起后，Windows UI Automation 给出的软件盘决策。
///
/// [active] 为 true 时应弹出软件盘，否则应收起。[secure] 只在 UIA 明确判断
/// 当前可编辑控件是否为密码框时取 true 或 false；无法确认或 [active] 为 false
/// 时为 null。
@immutable
class WindowsTextInputDecision {
  const WindowsTextInputDecision({
    required this.active,
    required this.secure,
  });

  factory WindowsTextInputDecision.fromMap(Map<Object?, Object?> map) {
    final active = map['active'] == true;
    final secure = map['secure'];
    return WindowsTextInputDecision(
      active: active,
      secure: active && secure is bool ? secure : null,
    );
  }

  final bool active;
  final bool? secure;
}

abstract class HardwareSimulatorPlatform extends PlatformInterface {
  /// Constructs a HardwareSimulatorPlatform.
  HardwareSimulatorPlatform() : super(token: _token);

  static final Object _token = Object();

  static HardwareSimulatorPlatform _instance = MethodChannelHardwareSimulator();

  /// The default instance of [HardwareSimulatorPlatform] to use.
  ///
  /// Defaults to [MethodChannelHardwareSimulator].
  static HardwareSimulatorPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [HardwareSimulatorPlatform] when
  /// they register themselves.
  static set instance(HardwareSimulatorPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }

  /// macOS only. Returns the current process's live TCC permission status as a
  /// map with keys `screenCapture`, `inputInjection`, `accessibility`. Does not
  /// prompt. On non-macOS platforms returns an empty map.
  Future<Map<String, bool>> checkMacOSPermissions() async {
    return const <String, bool>{};
  }

  /// macOS only. Asks macOS to show the consent prompt for [type]
  /// (`screenCapture` or `inputInjection`), opening System Settings if no
  /// auto-prompt is available. Returns the granted state after the request.
  Future<bool> requestMacOSPermission(String type) async {
    return false;
  }

  /// macOS only. Opens the given Privacy & Security pane in System Settings.
  /// [section] is one of `screenCapture`, `accessibility`, `inputMonitoring`.
  Future<void> openMacOSPrivacySettings(String section) async {}

  Future<bool?> getIsMouseConnected() {
    throw UnimplementedError('getIsMouseConnected() has not been implemented.');
  }

  Future<int?> getMonitorCount() async {
    // if not implemented, just care about main monitor.
    return 1;
  }

  Future<bool> registerService() async {
    return false;
  }

  Future<void> setDesktopServiceAvailable(bool available) async {
    return;
  }

  Future<void> unregisterService() async {
    return;
  }

  Future<bool> isRunningAsSystem() async {
    return true;
  }

  Future<void> showNotification(String content) async {
    return;
  }

  Future<void> lockCursor() async {
    // if not implemented, just care about main monitor.
    print("lockCursor called but not supported.");
  }

  Future<void> unlockCursor() async {
    // if not implemented, just care about main monitor.
    print("unlockCursor called but not supported.");
  }

  Future<void> unlockCursorAndReseed(
    double windowXPercent,
    double windowYPercent,
  ) async {
    await unlockCursor();
  }

  void addCursorMoved(CursorMovedCallback callback) async {
    print("addCursorMoved called but not supported.");
  }

  void removeCursorMoved(CursorMovedCallback callback) {
    throw UnimplementedError('removeCursorMoved() has not been implemented.');
  }

  void addCursorPressed(CursorPressedCallback callback) {
    throw UnimplementedError('addCursorPressed() has not been implemented.');
  }

  void removeCursorPressed(CursorPressedCallback callback) {
    throw UnimplementedError('removeCursorPressed() has not been implemented.');
  }

  void addKeyboardPressed(KeyboardPressedCallback callback) {
    throw UnimplementedError('addKeyboardPressed() has not been implemented.');
  }

  void removeKeyboardPressed(KeyboardPressedCallback callback) {
    throw UnimplementedError('removeCursorPressed() has not been implemented.');
  }

  Future<bool> putImmersiveModeEnabled(bool enabled) {
    throw UnimplementedError(
        'putImmersiveModeEnabled() has not been implemented.');
  }

  /// When Immersive Mode is enabled, the callback will be called when a key is blocked(e.g. Alt+Tab, the Tab key is blocked).
  void addKeyBlocked(KeyBlockedCallback callback) {
    throw UnimplementedError('addKeyBlocked() has not been implemented.');
  }

  void removeKeyBlocked(KeyBlockedCallback callback) {
    throw UnimplementedError('removeKeyBlocked() has not been implemented.');
  }

  void addCursorWheel(CursorWheelCallback callback) {
    throw UnimplementedError('addCursorWheel() has not been implemented.');
  }

  void removeCursorWheel(CursorWheelCallback callback) {
    throw UnimplementedError('removeCursorWheel() has not been implemented.');
  }

  /// Registers for native precision trackpad scrolling when implemented.
  void addTrackpadScroll(TrackpadScrollCallback callback) {}

  /// Removes a previously registered precision trackpad listener.
  void removeTrackpadScroll(TrackpadScrollCallback callback) {}

  /// Starts native precision trackpad capture.
  ///
  /// Returns false on platforms that have not implemented the unified source.
  Future<bool> startTrackpadScrollCapture() async {
    return false;
  }

  /// Stops native precision trackpad capture when implemented.
  Future<void> stopTrackpadScrollCapture() async {}

  /// 注册 Windows 远端点击后的文本输入决策。
  void addWindowsTextInputDecision(
    WindowsTextInputDecisionCallback callback,
  ) {}

  /// 移除 Windows 软件盘决策监听器。
  void removeWindowsTextInputDecision(
    WindowsTextInputDecisionCallback callback,
  ) {}

  /// 启动 Windows 按需 UI Automation 检查；不支持的平台返回 false。
  Future<bool> startWindowsTextInputDecisionCapture() async {
    return false;
  }

  /// 停止 Windows 按需 UI Automation 检查。
  Future<void> stopWindowsTextInputDecisionCapture() async {}

  void addCursorImageUpdated(
      CursorImageUpdatedCallback callback, int callbackId, bool hookAll) {
    throw UnimplementedError(
        'addCursorImageUpdated() has not been implemented.');
  }

  void removeCursorImageUpdated(int callbackId) {
    throw UnimplementedError(
        'removeCursorImageUpdated() has not been implemented.');
  }

  void addCursorPositionUpdated(
      CursorPositionUpdatedCallback callback, int callbackId) {
    throw UnimplementedError(
        'addCursorPositionUpdated() has not been implemented.');
  }

  void removeCursorPositionUpdated(int callbackId) {
    throw UnimplementedError(
        'removeCursorPositionUpdated() has not been implemented.');
  }

  // Display count change callbacks
  void addDisplayCountChangedCallback(
      DisplayCountChangedCallback callback, int callbackId) {
    throw UnimplementedError(
        'addDisplayCountChangedCallback() has not been implemented.');
  }

  void removeDisplayCountChangedCallback(int callbackId) {
    throw UnimplementedError(
        'removeDisplayCountChangedCallback() has not been implemented.');
  }

  Future<void> performKeyEvent(int keyCode, bool isDown) async {
    throw UnimplementedError('performKeyEvent() has not been implemented.');
  }

  Future<void> performTextInput(String text) async {
    throw UnimplementedError('performTextInput() has not been implemented.');
  }

  // Relative mouse movement.
  Future<void> performMouseMoveRelative(
      double deltax, double deltay, int screenId) async {
    throw UnimplementedError(
        'performMouseMoveRelative() has not been implemented.');
  }

  // Absolute mouse movement. x, y is the percentage of the screen ranged from 0 - 1.
  Future<void> performMouseMoveAbsl(
      double percentx, double percenty, int screenId) async {
    throw UnimplementedError(
        'performMouseMoveAbsl() has not been implemented.');
  }

  // Move mouse to window position. x, y is the percentage of the current window (excluding title bar) ranged from 0 - 1.
  Future<void> performMouseMoveToWindowPosition(
      double percentx, double percenty) async {
    throw UnimplementedError(
        'performMouseMoveToWindowPosition() has not been implemented.');
  }

  Future<void> performMouseClick(int buttonId, bool isDown) async {
    throw UnimplementedError('performMouseClick() has not been implemented.');
  }

  /// Injects logical scroll: positive x is right, positive y is down.
  Future<void> performMouseScroll(double dx, double dy) async {
    throw UnimplementedError('performMouseScroll() has not been implemented.');
  }

  /// Injects logical continuous trackpad scrolling while preserving
  /// fractional pixels.
  Future<void> performTrackpadScroll(
    double dx,
    double dy, {
    TrackpadScrollPhase phase = TrackpadScrollPhase.none,
    bool isMomentum = false,
  }) {
    return performMouseScroll(dx, dy);
  }

  // Touch event simulation
  Future<void> performTouchEvent(
      double x, double y, int touchId, bool isDown, int screenId) async {
    throw UnimplementedError('performTouchEvent() has not been implemented.');
  }

  Future<void> performTouchMove(
      double x, double y, int touchId, int screenId) async {
    throw UnimplementedError('performTouchMove() has not been implemented.');
  }

  // Pen event simulation
  Future<void> performPenEvent(double x, double y, bool isDown, bool hasButton,
      double pressure, double rotation, double tilt, int screenId) async {
    throw UnimplementedError('performPenEvent() has not been implemented.');
  }

  Future<void> performPenMove(double x, double y, bool hasButton,
      double pressure, double rotation, double tilt, int screenId) async {
    throw UnimplementedError('performPenMove() has not been implemented.');
  }

  Future<void> performPenHover(double x, double y, int screenId) async {
    throw UnimplementedError('performPenHover() has not been implemented.');
  }

  Future<int> createGameController() async {
    throw UnimplementedError(
        'createGameController() has not been implemented.');
  }

  Future<void> removeGameController(int controllerId) async {
    throw UnimplementedError(
        'removeGameController() has not been implemented.');
  }

  Future<void> doControllerAction(int controllerId, String action) async {
    throw UnimplementedError(
        'removeGameController() has not been implemented.');
  }

  Future<bool> ensureConsoleForDisplay() {
    throw UnimplementedError(
        'ensureConsoleForDisplay() has not been implemented.');
  }

  Future<bool> initParsecVdd() {
    throw UnimplementedError('initParsecVdd() has not been implemented.');
  }

  Future<int> createDisplay({
    List<Map<String, dynamic>>? configs,
  }) {
    throw UnimplementedError('createDisplay() has not been implemented.');
  }

  Future<bool> removeDisplay(int displayUid) {
    throw UnimplementedError('removeDisplay() has not been implemented.');
  }

  Future<int> getAllDisplays() {
    throw UnimplementedError('getAllDisplays() has not been implemented.');
  }

  Future<List<DisplayData>> getDisplayList() {
    throw UnimplementedError('getDisplayList() has not been implemented.');
  }

  Future<bool> changeDisplaySettings(
      int displayUid, int width, int height, int refreshRate,
      {int? bitDepth}) {
    throw UnimplementedError(
        'changeDisplaySettings() has not been implemented.');
  }

  Future<List<Map<String, dynamic>>> getDisplayConfigs(int displayUid) {
    throw UnimplementedError('getDisplayConfigs() has not been implemented.');
  }

  Future<List<Map<String, dynamic>>> getCustomDisplayConfigs() {
    throw UnimplementedError(
        'getCustomDisplayConfigs() has not been implemented.');
  }

  Future<bool> setCustomDisplayConfigs(List<Map<String, dynamic>> configs) {
    throw UnimplementedError(
        'setCustomDisplayConfigs() has not been implemented.');
  }

  Future<bool> setDisplayOrientation(int displayUid, int orientation) {
    throw UnimplementedError(
        'setDisplayOrientation() has not been implemented.');
  }

  Future<int> getDisplayOrientation(int displayUid) {
    throw UnimplementedError(
        'getDisplayOrientation() has not been implemented.');
  }

  // Multi-display mode management
  Future<bool> setMultiDisplayMode(int mode, int primaryDisplayId) {
    throw UnimplementedError('setMultiDisplayMode() has not been implemented.');
  }

  Future<int> getCurrentMultiDisplayMode() {
    throw UnimplementedError(
        'getCurrentMultiDisplayMode() has not been implemented.');
  }

  // Display control APIs for setting primary display and disabling others
  Future<bool> setPrimaryDisplayOnly(int displayUid) {
    throw UnimplementedError(
        'setPrimaryDisplayOnly() has not been implemented.');
  }

  Future<bool> restoreDisplayConfiguration() {
    throw UnimplementedError(
        'restoreDisplayConfiguration() has not been implemented.');
  }

  Future<bool> hasPendingConfiguration() {
    throw UnimplementedError(
        'hasPendingConfiguration() has not been implemented.');
  }

  Future<String?> getLastDisplayError() async {
    return null;
  }

  Future<void> setDragWindowContents(bool enabled) async {
    throw UnimplementedError(
        'setDragWindowContents() has not been implemented.');
  }

  Future<void> clearAllPressedEvents() async {
    throw UnimplementedError(
        'clearAllPressedEvents() has not been implemented.');
  }

  Future<bool> setPrimaryDisplay(int displayIndex) async {
    throw UnimplementedError('setPrimaryDisplay() has not been implemented.');
  }

  Future<void> updateStaticMonitors() async {
    throw UnimplementedError(
        'updateStaticMonitors() has not been implemented.');
  }
}
