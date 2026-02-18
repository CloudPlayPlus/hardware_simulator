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
typedef CursorImageUpdatedCallback = void Function(
    int message, int messageInfo, Uint8List cursorImage);
typedef CursorPositionUpdatedCallback = void Function(
    int message, int screenId, double xPercent, double yPercent);
typedef DisplayCountChangedCallback = void Function(int displayCount);

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

  Future<void> performMouseScroll(double dx, double dy) async {
    throw UnimplementedError('performMouseScroll() has not been implemented.');
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

  Future<bool> initParsecVdd() {
    throw UnimplementedError('initParsecVdd() has not been implemented.');
  }

  Future<int> createDisplay() {
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
