import 'hardware_simulator_platform_interface.dart';
export 'hardware_simulator_platform_interface.dart'
    show DisplayCountChangedCallback;
import 'display_data.dart';

class HWKeyboard {
  HWKeyboard();
  void performKeyEvent(int keyCode, bool isDown) {
    HardwareSimulatorPlatform.instance.performKeyEvent(keyCode, isDown);
  }
}

class HWMouse {
  HWMouse();
  void performMouseMoveRelative(double deltax, double deltay, int screenId) {
    HardwareSimulatorPlatform.instance
        .performMouseMoveRelative(deltax, deltay, screenId);
  }

  void performMouseMoveAbsl(double percentx, double percenty, int screenId) {
    HardwareSimulatorPlatform.instance
        .performMouseMoveAbsl(percentx, percenty, screenId);
  }

  void performMouseMoveToWindowPosition(double percentx, double percenty) {
    HardwareSimulatorPlatform.instance
        .performMouseMoveToWindowPosition(percentx, percenty);
  }

  // mouse left button id 1, right button id 3
  void performMouseClick(int buttonId, bool isDown) {
    HardwareSimulatorPlatform.instance.performMouseClick(buttonId, isDown);
  }

  void performMouseScroll(double dx, double dy) {
    HardwareSimulatorPlatform.instance.performMouseScroll(dx, dy);
  }
}

class GameController {
  int controllerId;

  GameController(this.controllerId);

  static Future<GameController?> createGameController() async {
    int id = await HardwareSimulatorPlatform.instance.createGameController();
    // creation failed.
    if (id < 0) return null;
    return GameController(id);
  }

  Future<void> dispose() async {
    if (controllerId < 0) return;
    await HardwareSimulatorPlatform.instance.removeGameController(controllerId);
  }

  Future<void> simulate(String action) async {
    HardwareSimulatorPlatform.instance.doControllerAction(controllerId, action);
  }
}

class HardwareSimulator {
  //For keyboard and mouse, it is a singleton. For other hardwares like game controllers,
  //it should be plugged in and then used.
  static HWKeyboard keyboard = HWKeyboard();
  static HWMouse mouse = HWMouse();

  static bool cursorlocked = false;

  Future<String?> getPlatformVersion() {
    return HardwareSimulatorPlatform.instance.getPlatformVersion();
  }

  //Only used for ios and android.
  static Future<bool?> getIsMouseConnected() {
    return HardwareSimulatorPlatform.instance.getIsMouseConnected();
  }

  static Future<int?> getMonitorCount() async {
    return HardwareSimulatorPlatform.instance.getMonitorCount();
  }

  static Future<bool> registerService() {
    return HardwareSimulatorPlatform.instance.registerService();
  }

  static Future<void> unregisterService() {
    return HardwareSimulatorPlatform.instance.unregisterService();
  }

  static Future<bool?> isRunningAsSystem() {
    return HardwareSimulatorPlatform.instance.isRunningAsSystem();
  }

  static Future<bool> putImmersiveModeEnabled(bool enabled) {
    return HardwareSimulatorPlatform.instance.putImmersiveModeEnabled(enabled);
  }

  static Future<void> showNotification(String content) {
    return HardwareSimulatorPlatform.instance.showNotification(content);
  }

  static Future<void> lockCursor() async {
    cursorlocked = true;
    return HardwareSimulatorPlatform.instance.lockCursor();
  }

  static Future<void> unlockCursor() async {
    if (!cursorlocked) return;
    cursorlocked = false;
    return HardwareSimulatorPlatform.instance.unlockCursor();
  }

  static void addCursorMoved(CursorMovedCallback callback) {
    HardwareSimulatorPlatform.instance.addCursorMoved(callback);
  }

  static void removeCursorMoved(CursorMovedCallback callback) {
    HardwareSimulatorPlatform.instance.removeCursorMoved(callback);
  }

  static void addCursorPressed(CursorPressedCallback callback) {
    HardwareSimulatorPlatform.instance.addCursorPressed(callback);
  }

  static void removeCursorPressed(CursorPressedCallback callback) {
    HardwareSimulatorPlatform.instance.removeCursorPressed(callback);
  }

  static void addKeyboardPressed(CursorPressedCallback callback) {
    HardwareSimulatorPlatform.instance.addKeyboardPressed(callback);
  }

  static void removeKeyboardPressed(CursorPressedCallback callback) {
    HardwareSimulatorPlatform.instance.removeKeyboardPressed(callback);
  }

  static void addKeyBlocked(KeyBlockedCallback callback) {
    HardwareSimulatorPlatform.instance.addKeyBlocked(callback);
  }

  static void removeKeyBlocked(KeyBlockedCallback callback) {
    HardwareSimulatorPlatform.instance.removeKeyBlocked(callback);
  }

  static void addCursorWheel(CursorWheelCallback callback) {
    HardwareSimulatorPlatform.instance.addCursorWheel(callback);
  }

  static void removeCursorWheel(CursorWheelCallback callback) {
    HardwareSimulatorPlatform.instance.removeCursorWheel(callback);
  }

  // ignore: constant_identifier_names
  static const int CURSOR_INVISIBLE = 1;
  // ignore: constant_identifier_names
  static const int CURSOR_VISIBLE = 2;
  // ignore: constant_identifier_names
  static const int CURSOR_UPDATED_DEFAULT = 3;
  // ignore: constant_identifier_names
  static const int CURSOR_UPDATED_IMAGE = 4;
  // ignore: constant_identifier_names
  static const int CURSOR_UPDATED_CACHED = 5;
  // ignore: constant_identifier_names
  static const int CURSOR_POSITION_CHANGED = 6;

  // hook_all means we stream cursor image including standard system cursor.
  static void addCursorImageUpdated(
      CursorImageUpdatedCallback callback, int callbackId, bool hookAll) {
    HardwareSimulatorPlatform.instance
        .addCursorImageUpdated(callback, callbackId, hookAll);
  }

  static void removeCursorImageUpdated(int callbackId) {
    HardwareSimulatorPlatform.instance.removeCursorImageUpdated(callbackId);
  }

  // Monitor cursor position changes with screenId, xPercent, yPercent
  static void addCursorPositionUpdated(
      CursorPositionUpdatedCallback callback, int callbackId) {
    HardwareSimulatorPlatform.instance
        .addCursorPositionUpdated(callback, callbackId);
  }

  static void removeCursorPositionUpdated(int callbackId) {
    HardwareSimulatorPlatform.instance.removeCursorPositionUpdated(callbackId);
  }

  // Display count change callbacks
  static void addDisplayCountChangedCallback(
      DisplayCountChangedCallback callback, int callbackId) {
    HardwareSimulatorPlatform.instance
        .addDisplayCountChangedCallback(callback, callbackId);
  }

  static void removeDisplayCountChangedCallback(int callbackId) {
    HardwareSimulatorPlatform.instance
        .removeDisplayCountChangedCallback(callbackId);
  }

  HWKeyboard getKeyboard() {
    return HWKeyboard();
  }

  HWMouse getMouse() {
    return HWMouse();
  }

  static void performTouchEvent(
      double x, double y, int touchId, bool isDown, int screenId) {
    HardwareSimulatorPlatform.instance
        .performTouchEvent(x, y, touchId, isDown, screenId);
  }

  static void performTouchMove(double x, double y, int touchId, int screenId) {
    HardwareSimulatorPlatform.instance
        .performTouchMove(x, y, touchId, screenId);
  }

  static void performPenEvent(double x, double y, bool isDown, bool hasButton,
      double pressure, double rotation, double tilt, int screenId) {
    HardwareSimulatorPlatform.instance.performPenEvent(
        x, y, isDown, hasButton, pressure, rotation, tilt, screenId);
  }

  static void performPenMove(double x, double y, bool hasButton,
      double pressure, double rotation, double tilt, int screenId) {
    HardwareSimulatorPlatform.instance
        .performPenMove(x, y, hasButton, pressure, rotation, tilt, screenId);
  }

  static Future<GameController?> createGameController() {
    return GameController.createGameController();
  }

  static Future<void> clearAllPressedEvents() async {
    await HardwareSimulatorPlatform.instance.clearAllPressedEvents();
  }

  static Future<bool> setPrimaryDisplay(int displayIndex) async {
    return await HardwareSimulatorPlatform.instance
        .setPrimaryDisplay(displayIndex);
  }

  static Future<bool> initParsecVdd() {
    return HardwareSimulatorPlatform.instance.initParsecVdd();
  }

  static Future<int> createDisplay() {
    return HardwareSimulatorPlatform.instance.createDisplay();
  }

  static Future<bool> removeDisplay(int displayUid) {
    return HardwareSimulatorPlatform.instance.removeDisplay(displayUid);
  }

  static Future<int> getAllDisplays() {
    return HardwareSimulatorPlatform.instance.getAllDisplays();
  }

  static Future<List<DisplayData>> getDisplayList() {
    return HardwareSimulatorPlatform.instance.getDisplayList();
  }

  static Future<bool> changeDisplaySettings(
      int displayUid, int width, int height, int refreshRate,
      {int? bitDepth}) {
    return HardwareSimulatorPlatform.instance.changeDisplaySettings(
        displayUid, width, height, refreshRate,
        bitDepth: bitDepth);
  }

  static Future<List<Map<String, dynamic>>> getDisplayConfigs(int displayUid) {
    return HardwareSimulatorPlatform.instance.getDisplayConfigs(displayUid);
  }

  static Future<List<Map<String, dynamic>>> getCustomDisplayConfigs() {
    return HardwareSimulatorPlatform.instance.getCustomDisplayConfigs();
  }

  static Future<bool> setCustomDisplayConfigs(
      List<Map<String, dynamic>> configs) {
    return HardwareSimulatorPlatform.instance.setCustomDisplayConfigs(configs);
  }

  // Display orientation management
  static Future<bool> setDisplayOrientation(
      int displayUid, DisplayOrientation orientation) {
    return HardwareSimulatorPlatform.instance
        .setDisplayOrientation(displayUid, orientation.index);
  }

  static Future<DisplayOrientation> getDisplayOrientation(
      int displayUid) async {
    int orientationIndex = await HardwareSimulatorPlatform.instance
        .getDisplayOrientation(displayUid);
    return DisplayOrientation.values[orientationIndex];
  }

  // Multi-display mode management
  static Future<bool> setMultiDisplayMode(MultiDisplayMode mode,
      {int primaryDisplayId = 0}) {
    return HardwareSimulatorPlatform.instance
        .setMultiDisplayMode(mode.index, primaryDisplayId);
  }

  static Future<MultiDisplayMode> getCurrentMultiDisplayMode() async {
    int modeIndex =
        await HardwareSimulatorPlatform.instance.getCurrentMultiDisplayMode();
    if (modeIndex >= 0 && modeIndex < MultiDisplayMode.values.length) {
      return MultiDisplayMode.values[modeIndex];
    }
    return MultiDisplayMode.unknown;
  }

  // Display control APIs for setting primary display and disabling others
  static Future<bool> setPrimaryDisplayOnly(int displayUid) {
    return HardwareSimulatorPlatform.instance.setPrimaryDisplayOnly(displayUid);
  }

  static Future<bool> restoreDisplayConfiguration() {
    return HardwareSimulatorPlatform.instance.restoreDisplayConfiguration();
  }

  static Future<bool> hasPendingConfiguration() {
    return HardwareSimulatorPlatform.instance.hasPendingConfiguration();
  }

  static Future<void> setDragWindowContents(bool enabled) {
    return HardwareSimulatorPlatform.instance.setDragWindowContents(enabled);
  }

  static Future<void> updateStaticMonitors() {
    return HardwareSimulatorPlatform.instance.updateStaticMonitors();
  }
}

// Enums for display management
enum DisplayOrientation {
  landscape, // Angle0
  portrait, // Angle90
  landscapeFlipped, // Angle180
  portraitFlipped // Angle270
}

enum DisplayTopologyMode {
  extend, // Extend desktop
  duplicate, // Mirror/Duplicate displays
  internal, // Internal display only
  external, // External display only
  clone // Clone mode
}
