import Cocoa
import FlutterMacOS
import CommonCrypto
import CoreGraphics
import ApplicationServices
import Carbon.HIToolbox
import Darwin
import IOKit.hid

class CursorConstants {    
#if CLOUDPLAYPLUS_DMG_DISTRIBUTION
  static let cursorInvisible = 1
#endif
  static let cursorVisible = 2
  static let cursorUpdatedDefault = 3    
  static let cursorUpdatedImage = 4    
  static let cursorUpdatedCached = 5
  static let cursorPositionChanged = 6
}

struct MacOSTextInputTraits {
  let role: String?
  let subrole: String?
  let enabled: Bool
  let editable: Bool?
  let valueSettable: Bool
}

struct MacOSTextInputDecision: Equatable {
  let active: Bool
  let secure: Bool?
}

/// The only input-source data allowed to cross from the main/AppKit lane to
/// the serial remote-keyboard lane. The latter must never read TIS directly:
/// doing so previously caused a main-thread dispatch assertion under load.
private enum MacOSInputSourceClass: String {
  case keyboardLayout
  case inputMethod
  case unknown
}

private struct MacOSInputSourceSnapshot {
  let id: String?
  let sourceClass: MacOSInputSourceClass
  let selectableCount: Int
}

private let macOSInputSourceChangedCallback: CFNotificationCallback = {
  _, observer, _, _, _ in
  guard let observer else { return }
  let plugin = Unmanaged<HardwareSimulatorPlugin>
    .fromOpaque(observer)
    .takeUnretainedValue()
  DispatchQueue.main.async {
    plugin.handleMacOSInputSourceChanged()
  }
}

#if CPP_LOG_AVAILABLE
private typealias MacOSCppLogEmit = @convention(c) (
  Int32,
  UnsafePointer<CChar>,
  UnsafePointer<CChar>
) -> Void

private let macOSCppLogEmit: MacOSCppLogEmit? = {
  guard
    let library = dlopen("@rpath/cpp_log.framework/cpp_log", RTLD_LAZY | RTLD_LOCAL),
    let symbol = dlsym(library, "cpp_log_emit")
  else {
    return nil
  }
  return unsafeBitCast(symbol, to: MacOSCppLogEmit.self)
}()
#endif

public class HardwareSimulatorPlugin: NSObject, FlutterPlugin {
  private static let registeredInstances =
    NSHashTable<HardwareSimulatorPlugin>.weakObjects()
  private var methodChannel: FlutterMethodChannel?
  private weak var registrar: FlutterPluginRegistrar?
  private weak var flutterView: NSView?
  private var trackpadScrollMonitor: Any?
  private var macOSGlobeKeyProbeLocalMonitor: Any?
  private let inputCaptureRegistry = MacOSInputCaptureRegistry()
  private var globeProcessGate = MacOSGlobeProcessGate()
  private var inputSourceChordRouter = MacOSInputSourceChordRouter()
  private var capturesControlSpace = false
  private var inputSourceCaptureEpoch = 0
  private var macOSGlobeKeyProbeCapsLockIsDown = false
  private var macOSGlobeKeyProbeCapturesCapsLock = false
  private var macOSGlobeKeyProbeCapturesFn = false
  private var macOSGlobeKeyProbeOwnsCapsLockRemap = false
  private var macOSGlobeKeyProbeOwnsFnSystemAction = false
  private var macOSGlobeKeyProbeFnSystemActionLeaseFileDescriptor: Int32?
  private var macOSGlobeKeyProbeCapsLockRemapLeaseFileDescriptor: Int32?
  private var macOSGlobeKeyProbeStopRequested = false
  private var macOSGlobeKeyProbeRestoreRetryWorkItem: DispatchWorkItem?
  private var macOSGlobeKeyProbeTerminationObserver: NSObjectProtocol?
  private var inputSourceSafetyObservers: [NSObjectProtocol] = []
  private var macOSGlobeKeyProbeLastLeaseFailureReason: String?
  private var macOSGlobeKeyProbeLastRecoveryFailureReason: String?
  private var macOSInputSourceCaptureLastDiagnostic: String?
  private var defaultCursorHasher: CursorHasher?
  private var cursorSeedProducerActive = false
  private var currentDisplayId: Int?
  private let displayBoundsCacheLock = NSLock()
  private var displayBoundsCache: [Int: CGRect] = [:]
  private var cursorDisplayOrderCache: [Int] = []
  private var displayBoundsCacheObserver: NSObjectProtocol?
  private var lastMouseClickButtonId: Int?
  private var lastMouseClickTime: TimeInterval = 0
  private var lastMouseClickLocation: CGPoint?
  private var lastMouseClickCount: Int64 = 0
  private var activeMouseButtonId: Int?
  private var activeMouseClickCount: Int64 = 1
  private let mouseEventSource = CGEventSource(stateID: .hidSystemState)
  private var injectedMouseButtonIds = Set<Int>()
  private let maxDoubleClickDistance: CGFloat = 6
  private let keyboardRepeatQueue = DispatchQueue(
    label: "com.cloudplayplus.hardware-simulator.keyboard-repeat"
  )
  private let keyboardInjectionQueue = DispatchQueue(
    label: "com.cloudplayplus.hardware-simulator.keyboard-injection"
  )
  private var activeKeyRepeatTimer: DispatchSourceTimer?
  private var activeRepeatingWindowsKeyCode: Int?
  private var activeKeyMacCodes: [Int: CGKeyCode] = [:]
  // Keep synthetic remote keyboard state separate from the Host's physical
  // keyboard session. This is the user-validated IME path: event flags are
  // reconstructed from remote state below, never inherited from the Host.
  private let remoteKeyboardEventSource = CGEventSource(stateID: .privateState)
  private var remoteCapsLockEnabled = false
  private let macOSInputSourceSnapshotLock = NSLock()
  private var macOSInputSourceSnapshot = MacOSInputSourceSnapshot(
    id: nil,
    sourceClass: .unknown,
    selectableCount: 0
  )
  private var macOSInputSourceNotificationRegistered = false
#if CLOUDPLAYPLUS_DMG_DISTRIBUTION
  private let macTextInputQueue = DispatchQueue(
    label: "com.cloudplayplus.hardware-simulator.text-input"
  )
  private var macTextInputObserver: AXObserver?
  private var macTextInputObservedApplication: AXUIElement?
  private var macTextInputWorkspaceObserver: NSObjectProtocol?
  private var macTextInputCaptureStarted = false
  private var macTextInputSnapshot = MacOSTextInputDecision(
    active: false,
    secure: nil
  )
  private var macTextInputSnapshotKnown = false
  private var macTextInputRequestSequence: UInt64 = 0
#endif

  override init() {
    super.init()
#if CLOUDPLAYPLUS_DMG_DISTRIBUTION
    macVirtualDisplayQueue.setSpecific(key: macVirtualDisplayQueueKey, value: ())
#endif
    // Injection can start before a MethodChannel call reaches this instance,
    // so source classification belongs to the plugin object's own lifecycle.
    // AppKit/TIS work is restricted to the main thread; registration creates
    // this object there in the desktop host.
    if Thread.isMainThread {
      startMacOSInputSourceTracking()
    } else {
      DispatchQueue.main.async { [weak self] in
        self?.startMacOSInputSourceTracking()
      }
    }
  }
#if DEBUG
  private var inputCaptureStartFixture: (caps: Bool, fn: Bool, control: Bool, hid: () -> Bool, globe: () -> Bool)?
  func startInputCaptureForTesting(caps: Bool, fn: Bool, control: Bool,
                                  hid: @escaping () -> Bool, globe: @escaping () -> Bool) -> Bool {
    inputCaptureStartFixture = (caps, fn, control, hid, globe)
    defer { inputCaptureStartFixture = nil }
    return startMacOSGlobeKeyProbe()
  }
  var cursorSeedRefreshHandlerForTesting: (() -> Void)?
  var cursorSeedProducerActiveForTesting: Bool {
    cursorSeedProducerActive
  }

  static func resetRegisteredInstancesForTesting() {
    registeredInstances.removeAllObjects()
  }

  static func registerInstanceForTesting(_ instance: HardwareSimulatorPlugin) {
    registeredInstances.add(instance)
  }

  var macOSUserKeyMappingReaderForTesting: (() -> MacOSUserKeyMapping?)?
  var macOSUserKeyMappingWriterForTesting: ((MacOSUserKeyMapping) -> Bool)?
  var macOSCapsLockRemapStateSynchronizerForTesting: (() -> Bool)?
  var macOSFnUsageTypeReaderForTesting: (() -> Int32?)?
  var macOSFnUsageTypeWriterForTesting: ((Int32) -> Void)?
  var macOSFnUsageTypePreferenceClearerForTesting: (() -> Void)?
  var macOSKeyboardInputSourceIdReaderForTesting: (() -> String?)?
  static var macOSCapsLockRemapLeaseFilePathForTesting: String?

  static var macOSCapsLockRemapStateDataForTesting: Data? {
    UserDefaults.standard.data(forKey: macOSCapsLockRemapStateKey)
  }

  static let macOSCapsLockHidUsageForTesting: UInt64 = macOSCapsLockHidUsage
  static let macOSGlobeRemappedF20HidUsageForTesting: UInt64 =
    macOSGlobeRemappedF20HidUsage

  func enableMacOSGlobeKeyProbeCapsLockRemapForTesting(
    captureCapsLock: Bool = true
  ) -> Bool {
    enableMacOSGlobeKeyProbeCapsLockRemap(captureCapsLock: captureCapsLock)
      .applied
  }

  func macOSFnInputSourceSwitchEnabledForTesting() -> Bool {
    macOSFnInputSourceSwitchEnabled()
  }

  @discardableResult
  func restoreMacOSGlobeKeyProbeFnSuppressionForTesting() -> Bool {
    restoreMacOSGlobeKeyProbeFnSuppression()
  }

  func recoverMacOSGlobeKeyProbeFnSuppressionForTesting() {
    recoverMacOSGlobeKeyProbeFnSuppressionIfNeeded()
  }

  func abandonMacOSGlobeKeyProbeFnSuppressionForTesting() {
    macOSGlobeKeyProbeOwnsFnSystemAction = false
    releaseMacOSGlobeKeyProbeFnSystemActionLease()
  }

  var ownsMacOSGlobeKeyProbeFnSuppressionForTesting: Bool {
    macOSGlobeKeyProbeOwnsFnSystemAction
  }

  @discardableResult
  func restoreMacOSGlobeKeyProbeCapsLockRemapForTesting() -> Bool {
    restoreMacOSGlobeKeyProbeCapsLockRemap()
  }

  @discardableResult
  func stopMacOSGlobeKeyProbeForTesting() -> Bool {
    stopMacOSGlobeKeyProbe()
  }

  func stopMacOSGlobeKeyProbeForTerminationForTesting() {
    stopMacOSGlobeKeyProbeForTermination()
  }

  func checkInputSourceSafetyForTesting(eligible: Bool) {
    checkInputSourceSafety(eligible: eligible)
  }

  func inputSourceTapDisabledForTesting() {
    inputSourceTapDisabled()
  }

  func currentMacOSUserKeyMappingForTesting() -> MacOSUserKeyMapping? {
    currentMacOSUserKeyMapping()
  }

  @discardableResult
  func setMacOSUserKeyMappingForTesting(_ mapping: MacOSUserKeyMapping) -> Bool {
    setMacOSUserKeyMapping(mapping)
  }

  /// Exercises the production Host-side direct-TIS selection path in the
  /// signed same-process AppKit integration harness.
  ///
  /// It is deliberately unavailable from production plugin APIs.
  @discardableResult
  func selectNextMacOSInputSourceInProcessForTesting() -> Bool {
    selectNextMacOSInputSource()
  }

  func recoverMacOSGlobeKeyProbeCapsLockRemapForTesting() {
    recoverMacOSGlobeKeyProbeCapsLockRemapIfNeeded()
  }

  func abandonMacOSGlobeKeyProbeCapsLockRemapForTesting() {
    macOSGlobeKeyProbeOwnsCapsLockRemap = false
    releaseMacOSGlobeKeyProbeCapsLockRemapLease()
  }

  var ownsMacOSGlobeKeyProbeCapsLockRemapForTesting: Bool {
    macOSGlobeKeyProbeOwnsCapsLockRemap
  }

  static var hasMacOSGlobeKeyProbeCapsLockRemapStateForTesting: Bool {
    UserDefaults.standard.data(forKey: macOSCapsLockRemapStateKey) != nil
  }

  static func resetMacOSGlobeKeyProbeCapsLockRemapForTesting() {
    macOSCapsLockRemapLeaseLock.lock()
    if let owner = macOSCapsLockRemapLeaseOwner,
       let descriptor = owner.macOSGlobeKeyProbeCapsLockRemapLeaseFileDescriptor {
      _ = flock(descriptor, LOCK_UN)
      _ = close(descriptor)
      owner.macOSGlobeKeyProbeCapsLockRemapLeaseFileDescriptor = nil
    }
    macOSCapsLockRemapLeaseOwner = nil
    macOSCapsLockRemapLeaseLock.unlock()
    macOSFnSystemActionLeaseLock.lock()
    if let owner = macOSFnSystemActionLeaseOwner,
       let descriptor = owner.macOSGlobeKeyProbeFnSystemActionLeaseFileDescriptor {
      _ = flock(descriptor, LOCK_UN)
      _ = close(descriptor)
      owner.macOSGlobeKeyProbeFnSystemActionLeaseFileDescriptor = nil
    }
    macOSFnSystemActionLeaseOwner = nil
    macOSFnSystemActionLeaseLock.unlock()
    UserDefaults.standard.removeObject(forKey: macOSCapsLockRemapStateKey)
    UserDefaults.standard.removeObject(forKey: macOSFnSystemActionStateKey)
    UserDefaults.standard.synchronize()
  }
#endif
#if CLOUDPLAYPLUS_DMG_DISTRIBUTION
  private let macVirtualDisplayQueueKey = DispatchSpecificKey<Void>()
  private let macVirtualDisplayQueue = DispatchQueue(
    label: "com.cloudplayplus.hardware-simulator.virtual-display"
  )
  private var macVirtualDisplaySessions: [Int: MacVirtualDisplaySession] = [:]
  private var macDisplayConfigurationBackup: [MacDisplayBackupItem]? = nil
  private var macLastVirtualDisplayError: String? = nil
  private var macSkyLightHandle: UnsafeMutableRawPointer?
  private var macTerminationObserver: NSObjectProtocol?
  private lazy var macSLSDisplayConfig = MacSLSDisplayConfig.load(
    using: { [weak self] in self?.loadMacSkyLight() }
  )
  private let macVirtualDisplaySerialBase = 0x4350_5600
  private let macVirtualDisplaySerialMax = 0x4350_56ff
  private let macCustomDisplayConfigsKey =
    "com.cloudplayplus.hardware_simulator.macos.custom_display_configs"
  private let macHelperName = "cloudplayplus_vd_helper"
#endif

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "hardware_simulator", binaryMessenger: registrar.messenger)
    let instance = HardwareSimulatorPlugin()
    registeredInstances.add(instance)
    instance.methodChannel = channel
    instance.registrar = registrar
    instance.defaultCursorHasher = CursorHasher()
    instance.startDisplayBoundsCache()
    instance.recoverMacOSGlobeKeyProbeCapsLockRemapIfNeeded()
    instance.recoverMacOSGlobeKeyProbeFnSuppressionIfNeeded()
    instance.registerMacOSGlobeKeyProbeTerminationObserver()
    instance.installInputSourceSafetyWatch()
#if CLOUDPLAYPLUS_DMG_DISTRIBUTION
    instance.registerMacTerminationObserver()
#endif
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  deinit {
    for observer in inputSourceSafetyObservers {
      NotificationCenter.default.removeObserver(observer)
    }
    stopTrackpadScrollCapture()
    // `deinit` must never enqueue work that weakly captures this instance:
    // registering an Objective-C weak reference while the object is already
    // deallocating aborts the process. Do the one synchronous restore attempt
    // and retain the persisted journal for the next startup if IOKit rejects
    // it. The regular stream-close path below remains responsible for retrying
    // while the plugin is alive.
    macOSGlobeKeyProbeRestoreRetryWorkItem?.cancel()
    macOSGlobeKeyProbeRestoreRetryWorkItem = nil
    _ = stopMacOSGlobeKeyProbe(scheduleRetry: false, reportStatus: false)
    // A failed restoration deliberately keeps its journal. Closing the lease
    // here lets a future plugin instance treat it as crash recovery instead of
    // being blocked forever by an object that is going away.
    releaseMacOSGlobeKeyProbeCapsLockRemapLease()
    releaseMacOSGlobeKeyProbeFnSystemActionLease()
    if let displayBoundsCacheObserver {
      NotificationCenter.default.removeObserver(displayBoundsCacheObserver)
    }
    if let macOSGlobeKeyProbeTerminationObserver {
      NotificationCenter.default.removeObserver(macOSGlobeKeyProbeTerminationObserver)
    }
    stopMacOSInputSourceTracking()
#if CLOUDPLAYPLUS_DMG_DISTRIBUTION
    stopCursorVisibilityTimer()
    stopMacOSTextInputDecisionCapture()
    if let cursorVisibilityProcessHandle {
      dlclose(cursorVisibilityProcessHandle)
    }
    if let macTerminationObserver {
      NotificationCenter.default.removeObserver(macTerminationObserver)
    }
    restoreMacDisplaysBeforeExit()
#endif
  }

  private func startTrackpadScrollCapture() -> Bool {
    if trackpadScrollMonitor != nil {
      return flutterView != nil
    }
    flutterView = registrar?.view ?? registrar?.viewController?.view
    guard flutterView != nil else { return false }
    trackpadScrollMonitor = NSEvent.addLocalMonitorForEvents(
      matching: .scrollWheel
    ) { [weak self] event in
      self?.handleTrackpadScroll(event)
      return event
    }
    return true
  }

  private func stopTrackpadScrollCapture() {
    if let trackpadScrollMonitor {
      NSEvent.removeMonitor(trackpadScrollMonitor)
    }
    self.trackpadScrollMonitor = nil
    if macOSGlobeKeyProbeLocalMonitor == nil {
      flutterView = nil
    }
  }

  /// Starts the viewer-only input-source-key probe.
  ///
  /// macOS exposes configured input-source switching through two independent
  /// physical paths. Caps Lock is remapped to F20 while focused; Globe/Fn
  /// is intercepted by a focus-scoped event tap without changing Fn usage type.
  /// Both paths call the
  /// same semantic callback, but neither path is allowed to make the other a
  /// prerequisite.
  private func startMacOSGlobeKeyProbe() -> Bool {
    // A previous teardown can be retrying the system mapping restoration in
    // the background, but it must never keep this stream's input blocked.
    guard !macOSGlobeKeyProbeStopRequested else {
      reportMacOSGlobeKeyProbeStatus(armed: false)
      return false
    }
    if macOSGlobeKeyProbeLocalMonitor != nil {
      return flutterView != nil
    }
    guard Thread.isMainThread else {
      reportMacOSGlobeKeyProbeStatus(armed: false)
      return false
    }
    flutterView = registrar?.view ?? registrar?.viewController?.view
    var windowReady = NSApp.isActive && flutterView?.window?.isKeyWindow == true
#if DEBUG
    if inputCaptureStartFixture != nil { windowReady = true }
#endif
    guard windowReady else {
      reportMacOSGlobeKeyProbeStatus(armed: false)
      return false
    }

    // Do not intercept ordinary Caps Lock or Globe/Fn. These are the exact
    // live settings shown by macOS Keyboard Settings.
    var captureCapsLock = macOSCapsLockInputSourceSwitchEnabled()
    var captureFnInputSource = macOSFnInputSourceSwitchEnabled()
    var controlSpace = macOSControlSpaceInputSourceEnabled()
#if DEBUG
    if let fixture = inputCaptureStartFixture {
      captureCapsLock = fixture.caps
      captureFnInputSource = fixture.fn
      controlSpace = fixture.control
    }
#endif
    let fnUsageType = currentMacOSFnUsageType()
    let configDiagnostic =
      "capsInputSource=\(captureCapsLock), " +
      "fnInputSource=\(captureFnInputSource), " +
      "fnUsageType=\(fnUsageType.map(String.init) ?? "unknown"), " +
      "mapping=\(macOSUserKeyMappingDiagnostic(currentMacOSUserKeyMapping()))"
    guard captureCapsLock || captureFnInputSource || controlSpace else {
      reportMacOSInputSourceCaptureDiagnostic(
        "Viewer input-source capture unavailable: no_configured_key, " +
          configDiagnostic
      )
      flutterView = nil
      reportMacOSGlobeKeyProbeStatus(armed: false)
      return false
    }

    let capsAttempt = enableMacOSGlobeKeyProbeCapsLockRemap(
      captureCapsLock: captureCapsLock
    )
    if !capsAttempt.applied {
      reportMacOSInputSourceCaptureDiagnostic(
        "Viewer Caps capture unavailable: caps=\(capsAttempt.reason), " +
          configDiagnostic
      )
      captureCapsLock = false
    }

    // Fn / Control 只使用局部 event tap；不再修改全局 Fn usage type。
    let needsEventTap = captureFnInputSource || controlSpace
    if needsEventTap && !installInputSourceEventTap() {
      reportMacOSInputSourceCaptureDiagnostic(
        "Viewer Fn/Control capture unavailable: event_tap_unavailable, " +
          configDiagnostic
      )
      captureFnInputSource = false
      controlSpace = false
    }

    macOSGlobeKeyProbeCapturesCapsLock = captureCapsLock
    macOSGlobeKeyProbeCapturesFn = captureFnInputSource
    capturesControlSpace = controlSpace
    macOSGlobeKeyProbeLocalMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.keyDown, .keyUp, .flagsChanged]
    ) { [weak self] event in
      guard let self else { return event }
      return self.handleMacOSGlobeKeyProbe(event) ? nil : event
    }
    guard macOSGlobeKeyProbeLocalMonitor != nil else {
      _ = stopMacOSGlobeKeyProbe()
      reportMacOSGlobeKeyProbeStatus(armed: false)
      return false
    }
    if captureFnInputSource { installGlobeSystemCapture() }
    guard captureCapsLock || capturesControlSpace || macOSGlobeKeyProbeCapturesFn else {
      _ = stopMacOSGlobeKeyProbe()
      return false
    }
    reportMacOSGlobeKeyProbeStatus(armed: true)
    reportMacOSInputSourceCaptureDiagnostic(
      "Viewer input-source capture armed: caps=\(captureCapsLock), " +
      "fn=\(macOSGlobeKeyProbeCapturesFn), " +
      "capsMapping=\(macOSUserKeyMappingDiagnostic(currentMacOSUserKeyMapping())), " +
      "fnUsageTypeDuringCapture=\(currentMacOSFnUsageType().map(String.init) ?? "unknown")."
    )
    return true
  }

  private func reportMacOSGlobeKeyProbeStatus(armed: Bool) {
    methodChannel?.invokeMethod(
      "onMacOSGlobeKeyProbeStatus",
      arguments: ["armed": armed]
    )
  }

  /// Plugin deallocation is not a lifecycle contract: Flutter/plugin teardown
  /// order is undefined during app termination. Restore synchronously while
  /// the registered plugin is still alive so a normal quit never leaves the
  /// user's Caps Lock mapping behind. A failed IOKit restore keeps its durable
  /// journal for startup recovery; it never queues work from `deinit`.
  private func registerMacOSGlobeKeyProbeTerminationObserver() {
    guard macOSGlobeKeyProbeTerminationObserver == nil else { return }
    macOSGlobeKeyProbeTerminationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      self?.stopMacOSGlobeKeyProbeForTermination()
    }
  }

  private func stopMacOSGlobeKeyProbeForTermination() {
    macOSGlobeKeyProbeRestoreRetryWorkItem?.cancel()
    macOSGlobeKeyProbeRestoreRetryWorkItem = nil
    _ = stopMacOSGlobeKeyProbe(scheduleRetry: false, reportStatus: false)
  }

  private func installInputSourceSafetyWatch() {
    guard inputSourceSafetyObservers.isEmpty else { return }
    for name in [NSApplication.didResignActiveNotification,
                 NSApplication.didBecomeActiveNotification,
                 NSWindow.didResignKeyNotification, NSWindow.didBecomeKeyNotification,
                 NSWindow.willCloseNotification] {
      let observer = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
        guard let self else { return }
        if name == NSWindow.didResignKeyNotification || name == NSWindow.willCloseNotification {
          guard let window = notification.object as? NSWindow,
                window === self.flutterView?.window else { return }
        }
        let losingFocus = name == NSApplication.didResignActiveNotification ||
          name == NSWindow.didResignKeyNotification || name == NSWindow.willCloseNotification
        let eligible = !losingFocus && NSApp.isActive && self.flutterView?.window?.isKeyWindow == true &&
          self.macOSGlobeKeyProbeLocalMonitor != nil &&
          (!(self.macOSGlobeKeyProbeCapturesFn || self.capturesControlSpace) ||
            self.inputCaptureRegistry.isActive(id: "input-source"))
        self.checkInputSourceSafety(eligible: eligible)
      }
      inputSourceSafetyObservers.append(observer)
    }
  }

  private func checkInputSourceSafety(eligible: Bool) {
    guard Thread.isMainThread else { return }
    if macOSGlobeKeyProbeStopRequested {
      // 已有100ms恢复重试在处理，不额外重复写映射或刷日志。
      return
    }
    let hasCapture = macOSGlobeKeyProbeLocalMonitor != nil
    if !eligible && (hasCapture || macOSGlobeKeyProbeOwnsCapsLockRemap) {
      macOSInputSourceDiagnosticLog("input_source_safety stop reason=inactive_or_unhealthy ownedCaps=\(macOSGlobeKeyProbeOwnsCapsLockRemap)")
      _ = stopMacOSGlobeKeyProbe()
      return
    }
    // 只处理带本产品journal的遗留状态，并先拿lease，避免另一实例仍在接管。
    if !hasCapture && !macOSGlobeKeyProbeOwnsCapsLockRemap &&
        UserDefaults.standard.data(forKey: Self.macOSCapsLockRemapStateKey) != nil {
      Self.withMacOSCapsLockRemapRecoveryLease { [weak self] in
        guard let self else { return }
        _ = self.recoverMacOSGlobeKeyProbeCapsLockRemapWhileLeaseHeld()
      }
    }
  }

  /// Stops stream-specific capture immediately. Mapping restoration continues
  /// independently when IOHID transiently fails, so closing one stream never
  /// blocks the user's local keyboard or another part of the application.
  @discardableResult
  private func stopMacOSGlobeKeyProbe(
    scheduleRetry: Bool = true,
    reportStatus: Bool = true
  ) -> Bool {
    macOSGlobeKeyProbeStopRequested = true
    if let monitor = macOSGlobeKeyProbeLocalMonitor {
      NSEvent.removeMonitor(monitor)
    }
    macOSGlobeKeyProbeLocalMonitor = nil
    inputCaptureRegistry.unregisterAll()
    globeProcessGate.reset()
    inputSourceChordRouter.reset()
    inputSourceCaptureEpoch += 1
    capturesControlSpace = false
    macOSGlobeKeyProbeCapsLockIsDown = false
    macOSGlobeKeyProbeCapturesCapsLock = false
    macOSGlobeKeyProbeCapturesFn = false
    if trackpadScrollMonitor == nil {
      flutterView = nil
    }
    if reportStatus {
      reportMacOSGlobeKeyProbeStatus(armed: false)
    }
    macOSInputSourceCaptureLastDiagnostic = nil
    let capsRestored = restoreMacOSGlobeKeyProbeCapsLockRemap()
    let fnRestored = restoreMacOSGlobeKeyProbeFnSuppression()
    let restored = capsRestored && fnRestored
    if !restored {
      reportMacOSInputSourceCaptureDiagnostic("Input-source mapping restore failed caps=\(capsRestored) fn=\(fnRestored)")
    }
    if restored {
      finishMacOSGlobeKeyProbeStopIfRestored()
    } else if scheduleRetry {
      scheduleMacOSGlobeKeyProbeRestoreRetry()
    }
    return restored
  }

  @discardableResult
  private func finishMacOSGlobeKeyProbeStopIfRestored() -> Bool {
    guard macOSGlobeKeyProbeStopRequested else { return true }
    guard
      restoreMacOSGlobeKeyProbeCapsLockRemap(),
      restoreMacOSGlobeKeyProbeFnSuppression()
    else {
      scheduleMacOSGlobeKeyProbeRestoreRetry()
      return false
    }
    macOSGlobeKeyProbeStopRequested = false
    macOSGlobeKeyProbeRestoreRetryWorkItem?.cancel()
    macOSGlobeKeyProbeRestoreRetryWorkItem = nil
    releaseMacOSGlobeKeyProbeCapsLockRemapLease()
    releaseMacOSGlobeKeyProbeFnSystemActionLease()
    return true
  }

  private func scheduleMacOSGlobeKeyProbeRestoreRetry() {
    guard macOSGlobeKeyProbeRestoreRetryWorkItem == nil else { return }
    let retry = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.macOSGlobeKeyProbeRestoreRetryWorkItem = nil
      _ = self.finishMacOSGlobeKeyProbeStopIfRestored()
    }
    macOSGlobeKeyProbeRestoreRetryWorkItem = retry
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: retry)
  }

  // Caps Lock is HID Keyboard/Keypad page 0x07, usage 0x39. Only Caps is
  // mapped to unused F20 (virtual keycode 0x5A). The Globe/Fn Top Case usage
  // must not enter UserKeyMapping: on real hardware that mapping has no
  // reliable readback/apply behaviour, which previously prevented both paths
  // from arming.
  private static let macOSCapsLockHidUsage: UInt64 = 0x700000039
  private static let macOSGlobeRemappedF20HidUsage: UInt64 = 0x70000006F
  private static let macOSGlobeRemappedF20KeyCode: UInt16 = 0x5A
  private static let macOSGlobeFnKeyCode: UInt16 = 0x3F
  private static let macOSFnUsageTypeChangeInputSource: Int32 = 1
  private static let macOSFnUsageTypeDoNothing: Int32 = 0
  private static let macOSUserKeyMappingSourceKey =
    "HIDKeyboardModifierMappingSrc"
  private static let macOSUserKeyMappingDestinationKey =
    "HIDKeyboardModifierMappingDst"
  private static let macOSUserKeyMappingKey = "UserKeyMapping" as CFString
  private static let macOSCapsLockRemapStateVersion = 1
  private static let macOSCapsLockRemapStateKey =
    "com.cloudplayplus.hardwareSimulator.macosCapsLockRemapState"
  private static let macOSFnSystemActionStateVersion = 1
  private static let macOSFnSystemActionStateKey =
    "com.cloudplayplus.hardwareSimulator.macosFnSystemActionState"
  private static let macOSHIToolboxPreferenceDomain =
    "com.apple.HIToolbox" as CFString
  private static let macOSFnUsagePreferenceKey =
    "AppleFnUsageType" as CFString
  private static let macOSCapsLockRemapLeaseLock = NSLock()
  private static weak var macOSCapsLockRemapLeaseOwner: HardwareSimulatorPlugin?
  private static let macOSFnSystemActionLeaseLock = NSLock()
  private static weak var macOSFnSystemActionLeaseOwner: HardwareSimulatorPlugin?

  private struct MacOSGlobeKeyProbeRemapAttempt {
    let applied: Bool
    let reason: String

    static func success(_ reason: String) -> Self {
      Self(applied: true, reason: reason)
    }

    static func failure(_ reason: String) -> Self {
      Self(applied: false, reason: reason)
    }
  }

  private typealias MacOSGetFnUsageType = @convention(c) () -> Int32
  private typealias MacOSUpdateFnUsageType = @convention(c) (Int32) -> Void

  private struct MacOSFnSystemActionState: Codable {
    let version: Int
    let originalUsageType: Int32
    let preferenceExisted: Bool
  }

  private static let macOSFnUsageTypeEntryPoints:
    (get: MacOSGetFnUsageType, update: MacOSUpdateFnUsageType)? = {
    guard
      let carbon = dlopen(
        "/System/Library/Frameworks/Carbon.framework/Carbon",
        RTLD_LAZY
      ),
      let get = dlsym(carbon, "TISGetFnUsageType"),
      let update = dlsym(carbon, "TISUpdateFnUsageType")
    else {
      return nil
    }
    return (
      get: unsafeBitCast(get, to: MacOSGetFnUsageType.self),
      update: unsafeBitCast(update, to: MacOSUpdateFnUsageType.self)
    )
  }()

  /// `UserKeyMapping` is a per-user global. Hold this advisory lock for the
  /// full lifetime of our mapping, rather than treating a matching mapping as
  /// a crash remnant. That lets a new process distinguish a live owner from a
  /// crashed one: macOS closes the file descriptor when the owner dies.
  private static func macOSCapsLockRemapLeaseFilePath() -> String? {
#if DEBUG
    if let macOSCapsLockRemapLeaseFilePathForTesting {
      return macOSCapsLockRemapLeaseFilePathForTesting
    }
#endif
    guard let supportDirectory = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first else {
      return nil
    }
    let directory = supportDirectory.appendingPathComponent(
      "CloudPlayPlus",
      isDirectory: true
    )
    do {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    } catch {
      return nil
    }
    return directory.appendingPathComponent(
      "macos-caps-lock-remap.lock",
      isDirectory: false
    ).path
  }

  private static func withMacOSCapsLockRemapRecoveryLease(
    _ body: () -> Void
  ) {
    macOSCapsLockRemapLeaseLock.lock()
    defer { macOSCapsLockRemapLeaseLock.unlock() }
    guard
      macOSCapsLockRemapLeaseOwner == nil,
      let path = macOSCapsLockRemapLeaseFilePath()
    else {
      return
    }
    let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { return }
    defer { _ = close(descriptor) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return }
    defer { _ = flock(descriptor, LOCK_UN) }
    body()
  }

  private static func macOSFnSystemActionLeaseFilePath() -> String? {
#if DEBUG
    if let macOSCapsLockRemapLeaseFilePathForTesting {
      return macOSCapsLockRemapLeaseFilePathForTesting + ".fn"
    }
#endif
    guard let supportDirectory = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first else {
      return nil
    }
    let directory = supportDirectory.appendingPathComponent(
      "CloudPlayPlus",
      isDirectory: true
    )
    do {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
    } catch {
      return nil
    }
    return directory.appendingPathComponent(
      "macos-fn-input-source-action.lock",
      isDirectory: false
    ).path
  }

  private static func withMacOSFnSystemActionRecoveryLease(
    _ body: () -> Void
  ) {
    macOSFnSystemActionLeaseLock.lock()
    defer { macOSFnSystemActionLeaseLock.unlock() }
    guard
      macOSFnSystemActionLeaseOwner == nil,
      let path = macOSFnSystemActionLeaseFilePath()
    else {
      return
    }
    let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { return }
    defer { _ = close(descriptor) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { return }
    defer { _ = flock(descriptor, LOCK_UN) }
    body()
  }


  private func acquireMacOSGlobeKeyProbeCapsLockRemapLease() -> Bool {
    Self.macOSCapsLockRemapLeaseLock.lock()
    defer { Self.macOSCapsLockRemapLeaseLock.unlock() }
    if Self.macOSCapsLockRemapLeaseOwner === self {
      macOSGlobeKeyProbeLastLeaseFailureReason = nil
      return true
    }
    guard
      Self.macOSCapsLockRemapLeaseOwner == nil,
      let path = Self.macOSCapsLockRemapLeaseFilePath()
    else {
      macOSGlobeKeyProbeLastLeaseFailureReason =
        Self.macOSCapsLockRemapLeaseOwner == nil
        ? "lease_path_unavailable"
        : "lease_owned_by_another_plugin_instance"
      return false
    }
    let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else {
      macOSGlobeKeyProbeLastLeaseFailureReason = "lease_open_failed_errno=\(errno)"
      return false
    }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      macOSGlobeKeyProbeLastLeaseFailureReason = "lease_busy_errno=\(errno)"
      _ = close(descriptor)
      return false
    }
    macOSGlobeKeyProbeCapsLockRemapLeaseFileDescriptor = descriptor
    Self.macOSCapsLockRemapLeaseOwner = self
    macOSGlobeKeyProbeLastLeaseFailureReason = nil
    return true
  }

  private func releaseMacOSGlobeKeyProbeCapsLockRemapLease() {
    Self.macOSCapsLockRemapLeaseLock.lock()
    defer { Self.macOSCapsLockRemapLeaseLock.unlock() }
    guard Self.macOSCapsLockRemapLeaseOwner === self else { return }
    if let descriptor = macOSGlobeKeyProbeCapsLockRemapLeaseFileDescriptor {
      _ = flock(descriptor, LOCK_UN)
      _ = close(descriptor)
    }
    macOSGlobeKeyProbeCapsLockRemapLeaseFileDescriptor = nil
    Self.macOSCapsLockRemapLeaseOwner = nil
  }

  private func acquireMacOSGlobeKeyProbeFnSystemActionLease() -> Bool {
    Self.macOSFnSystemActionLeaseLock.lock()
    defer { Self.macOSFnSystemActionLeaseLock.unlock() }
    if Self.macOSFnSystemActionLeaseOwner === self {
      return true
    }
    guard
      Self.macOSFnSystemActionLeaseOwner == nil,
      let path = Self.macOSFnSystemActionLeaseFilePath()
    else {
      return false
    }
    let descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { return false }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      _ = close(descriptor)
      return false
    }
    macOSGlobeKeyProbeFnSystemActionLeaseFileDescriptor = descriptor
    Self.macOSFnSystemActionLeaseOwner = self
    return true
  }

  private func releaseMacOSGlobeKeyProbeFnSystemActionLease() {
    Self.macOSFnSystemActionLeaseLock.lock()
    defer { Self.macOSFnSystemActionLeaseLock.unlock() }
    guard Self.macOSFnSystemActionLeaseOwner === self else { return }
    if let descriptor = macOSGlobeKeyProbeFnSystemActionLeaseFileDescriptor {
      _ = flock(descriptor, LOCK_UN)
      _ = close(descriptor)
    }
    macOSGlobeKeyProbeFnSystemActionLeaseFileDescriptor = nil
    Self.macOSFnSystemActionLeaseOwner = nil
  }

  private func handleMacOSGlobeKeyProbe(_ event: NSEvent) -> Bool {
    guard
      let flutterView,
      let flutterWindow = flutterView.window,
      NSApp.isActive,
      NSApp.keyWindow === flutterWindow
    else {
      return false
    }

    if macOSGlobeKeyProbeCapturesCapsLock,
       event.keyCode == Self.macOSGlobeRemappedF20KeyCode {
      let isDown = event.type == .keyDown
      if isDown && !macOSGlobeKeyProbeCapsLockIsDown {
        emitMacOSInputSourceKeyCapture(kind: "caps")
      }
      macOSGlobeKeyProbeCapsLockIsDown = isDown
      return true
    }

    return false
  }

  private func macOSControlSpaceInputSourceEnabled() -> Bool {
    // 只读当前系统输入源快捷键，不创建/改写符号快捷键。
    guard let preferences = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString,
        "com.apple.symbolichotkeys" as CFString) as? [String: Any] else { return false }
    return ["60", "61"].contains { id in
      guard let entry = preferences[id] as? [String: Any], entry["enabled"] as? Bool == true,
            let value = entry["value"] as? [String: Any],
            let parameters = value["parameters"] as? [NSNumber], parameters.count == 3 else { return false }
      return parameters[1].intValue == 49 && parameters[2].uint64Value == CGEventFlags.maskControl.rawValue
    }
  }

  private func installInputSourceEventTap() -> Bool {
#if DEBUG
    if let fixture = inputCaptureStartFixture { return fixture.hid() }
#endif
    let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .leftMouseDown, .rightMouseDown]
    let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
    return inputCaptureRegistry.register(id: "input-source", mask: mask) { [weak self] type, event in
      guard let self else { return false }
      if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        self.inputSourceTapDisabled()
        return false
      }
      guard self.hasFocusedInputSourceCapture else {
        self.inputSourceChordRouter.reset()
        self.globeProcessGate.reset()
        return false
      }
      _ = self.globeProcessGate.cancelForNewAction(type: type, flags: event.flags)
      let decision = self.inputSourceChordRouter.handle(type: type,
        code: Int(event.getIntegerValueField(.keyboardEventKeycode)), flags: event.flags,
        captureFn: self.macOSGlobeKeyProbeCapturesFn, captureControlSpace: self.capturesControlSpace)
      if let kind = decision.intent {
        if kind == "fn" { self.globeProcessGate.completedFn(now: ProcessInfo.processInfo.systemUptime) }
        self.emitMacOSInputSourceKeyCapture(kind: kind)
      }
      return decision.consume
    }
  }

  private var hasFocusedInputSourceCapture: Bool {
    NSApp.isActive && flutterView?.window?.isKeyWindow == true && macOSGlobeKeyProbeLocalMonitor != nil
  }

  private func installGlobeSystemCapture() {
#if DEBUG
    if let fixture = inputCaptureStartFixture {
      macOSGlobeKeyProbeCapturesFn = fixture.globe()
      return
    }
#endif
    guard let target = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextInputSwitcher").first,
          target.executableURL?.path == "/System/Library/CoreServices/TextInputSwitcher.app/Contents/MacOS/TextInputSwitcher" else {
      macOSInputSourceDiagnosticLog("Globe capture unavailable: TextInputSwitcher is not running")
      macOSGlobeKeyProbeCapturesFn = false
      return
    }
    let installed = inputCaptureRegistry.register(id: "globe-system", processID: target.processIdentifier,
      mask: CGEventMask(1) << 14) { [weak self] type, event in
      guard let self else { return false }
      if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        self.inputSourceTapDisabled()
        return false
      }
      guard self.hasFocusedInputSourceCapture, self.macOSGlobeKeyProbeCapturesFn else {
        self.globeProcessGate.reset()
        return false
      }
      guard let native = NSEvent(cgEvent: event), native.type == .systemDefined else { return false }
      return self.globeProcessGate.consume(type: type.rawValue, subtype: Int(native.subtype.rawValue),
        data1: native.data1, now: ProcessInfo.processInfo.systemUptime)
    }
    if !installed { macOSGlobeKeyProbeCapturesFn = false }
    if !installed { reportMacOSInputSourceCaptureDiagnostic("Globe system capture unavailable") }
  }

  private func inputSourceTapDisabled() {
    inputSourceChordRouter.reset()
    globeProcessGate.reset()
    macOSGlobeKeyProbeCapturesFn = false
    // 回调返回后统一注销，通知Dart失效并恢复映射；由既有受focus约束重试重建。
    DispatchQueue.main.async { [weak self] in _ = self?.stopMacOSGlobeKeyProbe() }
  }

  private func emitMacOSInputSourceKeyCapture(kind: String) {
    let epoch = inputSourceCaptureEpoch
    DispatchQueue.main.async { [weak self] in
      guard let self, self.inputSourceCaptureEpoch == epoch,
            self.hasFocusedInputSourceCapture else { return }
      self.methodChannel?.invokeMethod("onMacOSGlobeKeyProbe", arguments: [:])
    }
  }

  typealias MacOSUserKeyMapping = [[String: UInt64]]
  private typealias MacOSIsRomanSwitchEnabled = @convention(c) () -> Bool

  private struct MacOSCapsLockRemapState: Codable {
    let version: Int
    let originalMapping: MacOSUserKeyMapping
    let expectedMapping: MacOSUserKeyMapping
  }

  /// Reads the same live state used by Keyboard Settings for the Caps-Lock
  /// input-source-switch toggle. This is intentionally not derived from the
  /// input method's capability declaration: a capable IME can remain enabled
  /// while the user has turned the feature off.
  private func macOSCapsLockInputSourceSwitchEnabled() -> Bool {
    guard
      let carbon = dlopen(
        "/System/Library/Frameworks/Carbon.framework/Carbon",
        RTLD_LAZY
      ),
      let symbol = dlsym(
        carbon,
        "TISIsRomanSwitchEnabled"
      )
    else {
      return false
    }
    let isEnabled = unsafeBitCast(
      symbol,
      to: MacOSIsRomanSwitchEnabled.self
    )
    return isEnabled()
  }

  /// Reads the live Keyboard Settings choice for "Press 🌐 key to". The
  /// runtime symbol is intentionally resolved dynamically because Carbon does
  /// not expose this as a stable public Swift API. Fail closed on an absent or
  /// unknown value so ordinary Globe/Fn actions remain local.
  private func macOSFnInputSourceSwitchEnabled() -> Bool {
    currentMacOSFnUsageType() == Self.macOSFnUsageTypeChangeInputSource
  }

  private func currentMacOSFnUsageType() -> Int32? {
#if DEBUG
    if let macOSFnUsageTypeReaderForTesting {
      return macOSFnUsageTypeReaderForTesting()
    }
#endif
    return Self.macOSFnUsageTypeEntryPoints?.get()
  }

  /// Restores the independently journalled Globe/Fn system action after an
  /// abnormal exit. This only writes when the current value remains our
  /// temporary Do Nothing value; a user or another tool's later choice wins.
  private func recoverMacOSGlobeKeyProbeFnSuppressionIfNeeded() {
    Self.withMacOSFnSystemActionRecoveryLease { [weak self] in
      guard let self else { return }
      guard
        let data = UserDefaults.standard.data(
          forKey: Self.macOSFnSystemActionStateKey
        ),
        let state = try? JSONDecoder().decode(
          MacOSFnSystemActionState.self,
          from: data
        ),
        state.version == Self.macOSFnSystemActionStateVersion
      else {
        return
      }
      guard self.currentMacOSFnUsageType() == Self.macOSFnUsageTypeDoNothing else {
        self.clearMacOSGlobeKeyProbeFnSystemActionState()
        self.macOSInputSourceDiagnosticLog(
          "Startup Fn recovery skipped: current setting changed outside capture."
        )
        return
      }
      self.setMacOSFnUsageType(state.originalUsageType)
      guard self.currentMacOSFnUsageType() == state.originalUsageType else {
        self.macOSInputSourceDiagnosticLog(
          "Startup Fn recovery failed: usage type readback did not restore."
        )
        return
      }
      if !state.preferenceExisted {
        self.clearMacOSFnUsagePreference()
      }
      self.clearMacOSGlobeKeyProbeFnSystemActionState()
      self.macOSInputSourceDiagnosticLog(
        "Startup Fn recovery restored usageType=\(state.originalUsageType)."
      )
    }
  }

  @discardableResult
  private func restoreMacOSGlobeKeyProbeFnSuppression() -> Bool {
    guard macOSGlobeKeyProbeOwnsFnSystemAction else { return true }
    guard
      let data = UserDefaults.standard.data(
        forKey: Self.macOSFnSystemActionStateKey
      ),
      let state = try? JSONDecoder().decode(
        MacOSFnSystemActionState.self,
        from: data
      ),
      state.version == Self.macOSFnSystemActionStateVersion
    else {
      macOSInputSourceDiagnosticLog("Fn restore failed: journal unreadable.")
      return false
    }
    // A deliberate user/other-tool setting update must not be overwritten.
    // If the original setting was Do Nothing, no system mutation was
    // performed and there is nothing to restore.
    guard currentMacOSFnUsageType() == Self.macOSFnUsageTypeDoNothing else {
      macOSGlobeKeyProbeOwnsFnSystemAction = false
      clearMacOSGlobeKeyProbeFnSystemActionState()
      macOSInputSourceDiagnosticLog(
        "Fn restore skipped: current setting changed outside capture."
      )
      return true
    }
    setMacOSFnUsageType(state.originalUsageType)
    guard currentMacOSFnUsageType() == state.originalUsageType else {
      macOSInputSourceDiagnosticLog(
        "Fn restore failed: usage type readback did not restore."
      )
      return false
    }
    if !state.preferenceExisted {
      clearMacOSFnUsagePreference()
    }
    clearMacOSGlobeKeyProbeFnSystemActionState()
    macOSGlobeKeyProbeOwnsFnSystemAction = false
    return true
  }

  private func setMacOSFnUsageType(_ usageType: Int32) {
#if DEBUG
    if let macOSFnUsageTypeWriterForTesting {
      macOSFnUsageTypeWriterForTesting(usageType)
      return
    }
#endif
    Self.macOSFnUsageTypeEntryPoints?.update(usageType)
  }

  private func clearMacOSGlobeKeyProbeFnSystemActionState() {
    UserDefaults.standard.removeObject(forKey: Self.macOSFnSystemActionStateKey)
    UserDefaults.standard.synchronize()
  }

  private func clearMacOSFnUsagePreference() {
#if DEBUG
    if let macOSFnUsageTypePreferenceClearerForTesting {
      macOSFnUsageTypePreferenceClearerForTesting()
      return
    }
#endif
    CFPreferencesSetValue(
      Self.macOSFnUsagePreferenceKey,
      nil,
      Self.macOSHIToolboxPreferenceDomain,
      kCFPreferencesCurrentUser,
      kCFPreferencesAnyHost
    )
    CFPreferencesSynchronize(
      Self.macOSHIToolboxPreferenceDomain,
      kCFPreferencesCurrentUser,
      kCFPreferencesAnyHost
    )
  }

  /// Restores a remap left only by a previous CloudPlayPlus crash. The
  /// recovery lease prevents a second engine/process from restoring a mapping
  /// that an existing viewer still owns.
  private func recoverMacOSGlobeKeyProbeCapsLockRemapIfNeeded() {
    Self.withMacOSCapsLockRemapRecoveryLease { [weak self] in
      guard let self else { return }
      let recovered = self.recoverMacOSGlobeKeyProbeCapsLockRemapWhileLeaseHeld()
      self.macOSInputSourceDiagnosticLog(
        "Startup input-source mapping recovery result=\(recovered), " +
          "reason=\(self.macOSGlobeKeyProbeLastRecoveryFailureReason ?? "none"), " +
          "mapping=\(self.macOSUserKeyMappingDiagnostic(self.currentMacOSUserKeyMapping()))"
      )
    }
  }

  /// The caller must hold either the temporary recovery lease or this
  /// instance's active owner lease.
  @discardableResult
  private func recoverMacOSGlobeKeyProbeCapsLockRemapWhileLeaseHeld() -> Bool {
    macOSGlobeKeyProbeLastRecoveryFailureReason = nil
    guard
      let data = UserDefaults.standard.data(
        forKey: Self.macOSCapsLockRemapStateKey
      )
    else {
      return true
    }
    guard let currentMapping = currentMacOSUserKeyMapping() else {
      macOSGlobeKeyProbeLastRecoveryFailureReason = "recovery_mapping_unreadable"
      return false
    }
    guard
      let state = try? JSONDecoder().decode(
        MacOSCapsLockRemapState.self,
        from: data
      ),
      state.version == Self.macOSCapsLockRemapStateVersion
    else {
      // A previous experimental build wrote a journal format that this
      // version cannot decode. Do not use it to mutate a nonempty user-wide
      // mapping. If the live mapping is already empty, though, there is no
      // product remap left to restore and retaining a corrupt journal would
      // permanently disable the user's configured input-source keys.
      guard currentMapping.isEmpty else {
        macOSGlobeKeyProbeLastRecoveryFailureReason =
          "recovery_journal_unreadable_live_mapping_not_empty"
        return false
      }
      clearMacOSGlobeKeyProbeCapsLockRemapState()
      macOSInputSourceDiagnosticLog(
        "Discarded unreadable legacy Caps recovery journal after confirming " +
          "an empty live UserKeyMapping."
      )
      return true
    }
    if macOSUserKeyMappingsEqual(currentMapping, state.originalMapping) ||
        !macOSUserKeyMappingsEqual(currentMapping, state.expectedMapping) {
      // It was already restored, or the user changed this mapping after our
      // process exited. The current user state wins in both cases. An
      // externally modified mapping is not confirmation that the original
      // mapping was restored, so retain the journal rather than losing the
      // only recovery record after a failed/contended IOHID transition.
      if macOSUserKeyMappingsEqual(currentMapping, state.originalMapping) {
        clearMacOSGlobeKeyProbeCapsLockRemapState()
      }
      return true
    }

    guard
      setMacOSUserKeyMapping(state.originalMapping),
      macOSUserKeyMappingsEqual(
        currentMacOSUserKeyMapping(),
        state.originalMapping
      )
    else {
      // Keep the journal. A later startup can safely retry a transient IOHID
      // failure, because the lease proves no live owner is being interrupted.
      macOSGlobeKeyProbeLastRecoveryFailureReason = "recovery_write_or_readback_failed"
      return false
    }
    clearMacOSGlobeKeyProbeCapsLockRemapState()
    return true
  }

  private func enableMacOSGlobeKeyProbeCapsLockRemap(
    captureCapsLock: Bool
  ) -> MacOSGlobeKeyProbeRemapAttempt {
    guard captureCapsLock else {
      // Fn capture has its own reversible TIS adapter and must not require the
      // global UserKeyMapping transaction at all.
      return .success("not_configured")
    }
    guard acquireMacOSGlobeKeyProbeCapsLockRemapLease() else {
      return .failure(
        macOSGlobeKeyProbeLastLeaseFailureReason ?? "lease_acquisition_failed"
      )
    }
    guard recoverMacOSGlobeKeyProbeCapsLockRemapWhileLeaseHeld() else {
      releaseMacOSGlobeKeyProbeCapsLockRemapLease()
      return .failure(
        macOSGlobeKeyProbeLastRecoveryFailureReason ?? "recovery_failed"
      )
    }
    // A failed read must never be treated as an empty user mapping: doing so
    // could overwrite a mapping that we failed to observe.
    guard let originalMapping = currentMacOSUserKeyMapping() else {
      releaseMacOSGlobeKeyProbeCapsLockRemapLease()
      return .failure("mapping_unreadable_before_apply")
    }
    // The monitor consumes every F20 event while armed. A user mapping from
    // any other physical key to F20 would therefore be swallowed even though
    // that key was not configured as an input-source switch. Refuse to arm
    // instead of broadening local key capture.
    let hasUnrelatedF20Mapping = originalMapping.contains { mapping in
      mapping[Self.macOSUserKeyMappingDestinationKey] ==
        Self.macOSGlobeRemappedF20HidUsage &&
        mapping[Self.macOSUserKeyMappingSourceKey] != Self.macOSCapsLockHidUsage
    }
    guard !hasUnrelatedF20Mapping else {
      releaseMacOSGlobeKeyProbeCapsLockRemapLease()
      return .failure(
        "unrelated_f20_mapping_conflict " +
          macOSUserKeyMappingDiagnostic(originalMapping)
      )
    }
    var expectedMapping = originalMapping
    var addedRemap = false

    func appendRequiredRemap(_ sourceUsage: UInt64) -> String? {
      let mappings = originalMapping.filter {
        $0[Self.macOSUserKeyMappingSourceKey] == sourceUsage
      }
      guard mappings.count <= 1 else {
        return "multiple_source_mappings source=\(macOSHidUsageDiagnostic(sourceUsage))"
      }
      if let existingMapping = mappings.first {
        // A user-owned mapping always wins. Reuse only the exact F20 mapping
        // this capture needs, without claiming ownership of it.
        guard existingMapping[Self.macOSUserKeyMappingDestinationKey] ==
          Self.macOSGlobeRemappedF20HidUsage
        else {
          return "source_mapping_conflict source=\(macOSHidUsageDiagnostic(sourceUsage))"
        }
        return nil
      }
      expectedMapping.append([
        Self.macOSUserKeyMappingSourceKey: sourceUsage,
        Self.macOSUserKeyMappingDestinationKey: Self.macOSGlobeRemappedF20HidUsage,
      ])
      addedRemap = true
      return nil
    }

    let remapFailure = appendRequiredRemap(Self.macOSCapsLockHidUsage)
    if let remapFailure {
      releaseMacOSGlobeKeyProbeCapsLockRemapLease()
      return .failure(remapFailure)
    }

    // Both configured keys may already have the exact F20 user mapping. It is
    // safe to consume F20 for this focused session, but there is nothing to
    // journal or restore.
    guard addedRemap else {
      return .success("reused_exact_existing_f20_mapping")
    }
    let state = MacOSCapsLockRemapState(
      version: Self.macOSCapsLockRemapStateVersion,
      originalMapping: originalMapping,
      expectedMapping: expectedMapping
    )
    guard
      let data = try? JSONEncoder().encode(state)
    else {
      releaseMacOSGlobeKeyProbeCapsLockRemapLease()
      return .failure("journal_encode_failed")
    }
    // Persist the recovery record before altering the system-wide mapping. A
    // cached preference is not enough: if the process dies before it reaches
    // disk, recovery could lose the original Caps Lock mapping forever.
    guard persistMacOSGlobeKeyProbeCapsLockRemapState(data) else {
      releaseMacOSGlobeKeyProbeCapsLockRemapLease()
      return .failure("journal_persist_or_readback_failed")
    }
    let mappingApplied = setMacOSUserKeyMapping(expectedMapping)
    let readback = currentMacOSUserKeyMapping()
    guard
      mappingApplied,
      macOSUserKeyMappingsEqual(readback, expectedMapping)
    else {
      var rollback = "not_attempted"
      if
        mappingApplied,
        macOSUserKeyMappingIsSubset(readback, of: expectedMapping)
      {
        _ = setMacOSUserKeyMapping(originalMapping)
        rollback = macOSUserKeyMappingsEqual(
          currentMacOSUserKeyMapping(),
          originalMapping
        )
          ? "restored_original"
          : "write_or_readback_failed"
      }
      if macOSUserKeyMappingsEqual(
        currentMacOSUserKeyMapping(),
        originalMapping
      ) {
        clearMacOSGlobeKeyProbeCapsLockRemapState()
      }
      releaseMacOSGlobeKeyProbeCapsLockRemapLease()
      return .failure(
        "mapping_apply_or_readback_failed set=\(mappingApplied), " +
          "expected=\(macOSUserKeyMappingDiagnostic(expectedMapping)), " +
          "readback=\(macOSUserKeyMappingDiagnostic(readback)), " +
          "rollback=\(rollback)"
      )
    }
    macOSGlobeKeyProbeOwnsCapsLockRemap = true
    return .success(
      "applied " + macOSUserKeyMappingDiagnostic(expectedMapping)
    )
  }

  @discardableResult
  private func restoreMacOSGlobeKeyProbeCapsLockRemap() -> Bool {
    macOSGlobeKeyProbeLastRecoveryFailureReason = nil
    guard macOSGlobeKeyProbeOwnsCapsLockRemap else { return true }
    guard
      let data = UserDefaults.standard.data(
        forKey: Self.macOSCapsLockRemapStateKey
      ),
      let state = try? JSONDecoder().decode(
        MacOSCapsLockRemapState.self,
        from: data
      ),
      state.version == Self.macOSCapsLockRemapStateVersion
    else {
      macOSGlobeKeyProbeLastRecoveryFailureReason = "restore_journal_unreadable"
      return false
    }
    guard let currentMapping = currentMacOSUserKeyMapping() else {
      macOSGlobeKeyProbeLastRecoveryFailureReason = "restore_mapping_unreadable"
      return false
    }
    if macOSUserKeyMappingsEqual(currentMapping, state.originalMapping) ||
        !macOSUserKeyMappingsEqual(currentMapping, state.expectedMapping) {
      if macOSUserKeyMappingsEqual(currentMapping, state.originalMapping) {
        clearMacOSGlobeKeyProbeCapsLockRemapState()
      }
      macOSGlobeKeyProbeOwnsCapsLockRemap = false
      return true
    }
    guard
      setMacOSUserKeyMapping(state.originalMapping),
      macOSUserKeyMappingsEqual(
        currentMacOSUserKeyMapping(),
        state.originalMapping
      )
    else {
      // Do not discard the only recovery record when the IOHID write or its
      // confirmation fails. The next owner can retry after this lease closes.
      macOSGlobeKeyProbeLastRecoveryFailureReason =
        "restore_write_or_readback_failed"
      return false
    }
    clearMacOSGlobeKeyProbeCapsLockRemapState()
    macOSGlobeKeyProbeOwnsCapsLockRemap = false
    return true
  }

  private func clearMacOSGlobeKeyProbeCapsLockRemapState() {
    UserDefaults.standard.removeObject(forKey: Self.macOSCapsLockRemapStateKey)
    UserDefaults.standard.synchronize()
  }

  /// Synchronously commits the recovery journal before mutating the global
  /// event-system mapping. The matching read verifies the exact bytes are
  /// available through the persistent preference boundary.
  private func persistMacOSGlobeKeyProbeCapsLockRemapState(_ data: Data) -> Bool {
    UserDefaults.standard.set(data, forKey: Self.macOSCapsLockRemapStateKey)
    guard
      synchronizeMacOSGlobeKeyProbeCapsLockRemapState(),
      UserDefaults.standard.data(forKey: Self.macOSCapsLockRemapStateKey) == data
    else {
      UserDefaults.standard.removeObject(forKey: Self.macOSCapsLockRemapStateKey)
      _ = UserDefaults.standard.synchronize()
      return false
    }
    return true
  }

  private func synchronizeMacOSGlobeKeyProbeCapsLockRemapState() -> Bool {
#if DEBUG
    if let macOSCapsLockRemapStateSynchronizerForTesting {
      return macOSCapsLockRemapStateSynchronizerForTesting()
    }
#endif
    return UserDefaults.standard.synchronize()
  }

  private func currentMacOSUserKeyMapping() -> MacOSUserKeyMapping? {
#if DEBUG
    if let macOSUserKeyMappingReaderForTesting {
      return macOSUserKeyMappingReaderForTesting()
    }
#endif
    let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    guard let rawMapping = IOHIDEventSystemClientCopyProperty(
      client,
      Self.macOSUserKeyMappingKey
    ) else {
      // IOHID omits UserKeyMapping when the user has no custom mappings. That
      // is the canonical empty mapping, not a failed read.
      return []
    }
    // IOHID bridges this property differently across macOS releases and
    // keyboard drivers (`NSArray` / `NSDictionary` vs a typed Swift array).
    // Normalize the Objective-C containers explicitly; treating a valid custom
    // mapping as unreadable leaves the controller key path permanently off.
    guard let mappings = rawMapping as? NSArray else { return nil }
    var normalizedMappings: MacOSUserKeyMapping = []
    for rawItem in mappings {
      guard let rawItem = rawItem as? NSDictionary else { return nil }
      var mapping: [String: UInt64] = [:]
      for (rawKey, rawValue) in rawItem {
        guard
          let key = rawKey as? String,
          let value = rawValue as? NSNumber
        else {
          return nil
        }
        mapping[key] = value.uint64Value
      }
      normalizedMappings.append(mapping)
    }
    return normalizedMappings
  }

  private func setMacOSUserKeyMapping(_ mapping: MacOSUserKeyMapping) -> Bool {
#if DEBUG
    if let macOSUserKeyMappingWriterForTesting {
      return macOSUserKeyMappingWriterForTesting(mapping)
    }
#endif
    let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    let bridgedMapping = mapping.map { item in
      Dictionary(
        uniqueKeysWithValues: item.map { key, value in
          (key, NSNumber(value: value))
        }
      ) as NSDictionary
    } as NSArray
    return IOHIDEventSystemClientSetProperty(
      client,
      Self.macOSUserKeyMappingKey,
      bridgedMapping
    )
  }

  private func currentMacOSKeyboardInputSourceId() -> String? {
#if DEBUG
    if let macOSKeyboardInputSourceIdReaderForTesting {
      return macOSKeyboardInputSourceIdReaderForTesting()
    }
#endif
    let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    guard let rawId = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
    else {
      return nil
    }
    return Unmanaged<CFString>
      .fromOpaque(rawId)
      .takeUnretainedValue() as String
  }

  private func macOSSelectableKeyboardInputSources() -> [TISInputSource] {
    let filter = [
      kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource,
    ] as CFDictionary
    let sourceList = TISCreateInputSourceList(filter, false)
      .takeRetainedValue() as NSArray
    return sourceList.map { $0 as! TISInputSource }.filter { source in
      guard
        let enabledValue = TISGetInputSourceProperty(
          source,
          kTISPropertyInputSourceIsEnabled
        ),
        let selectableValue = TISGetInputSourceProperty(
          source,
          kTISPropertyInputSourceIsSelectCapable
        )
      else {
        return false
      }
      let enabled = Unmanaged<CFBoolean>
        .fromOpaque(enabledValue)
        .takeUnretainedValue()
      let selectable = Unmanaged<CFBoolean>
        .fromOpaque(selectableValue)
        .takeUnretainedValue()
      return CFBooleanGetValue(enabled) && CFBooleanGetValue(selectable)
    }
  }

  private func macOSInputSourceClass(_ source: TISInputSource) -> MacOSInputSourceClass {
    guard let rawType = TISGetInputSourceProperty(source, kTISPropertyInputSourceType)
    else {
      return .unknown
    }
    let type = Unmanaged<CFString>.fromOpaque(rawType).takeUnretainedValue()
    if CFEqual(type, kTISTypeKeyboardLayout) {
      return .keyboardLayout
    }
    return .inputMethod
  }

  private func macOSInputSourceSnapshot(
    selectableSources: [TISInputSource]? = nil
  ) -> MacOSInputSourceSnapshot {
    let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    let sources = selectableSources ?? macOSSelectableKeyboardInputSources()
    return MacOSInputSourceSnapshot(
      id: macOSKeyboardInputSourceId(current),
      sourceClass: macOSInputSourceClass(current),
      selectableCount: sources.count
    )
  }

  private func refreshMacOSInputSourceSnapshot(
    selectableSources: [TISInputSource]? = nil
  ) {
    guard Thread.isMainThread else { return }
    let snapshot = macOSInputSourceSnapshot(selectableSources: selectableSources)
    macOSInputSourceSnapshotLock.lock()
    macOSInputSourceSnapshot = snapshot
    macOSInputSourceSnapshotLock.unlock()
  }

  private func startMacOSInputSourceTracking() {
    guard Thread.isMainThread else { return }
    refreshMacOSInputSourceSnapshot()
    guard !macOSInputSourceNotificationRegistered else { return }
    CFNotificationCenterAddObserver(
      CFNotificationCenterGetDistributedCenter(),
      Unmanaged.passUnretained(self).toOpaque(),
      macOSInputSourceChangedCallback,
      kTISNotifySelectedKeyboardInputSourceChanged,
      nil,
      .deliverImmediately
    )
    macOSInputSourceNotificationRegistered = true
  }

  private func stopMacOSInputSourceTracking() {
    guard macOSInputSourceNotificationRegistered else { return }
    CFNotificationCenterRemoveObserver(
      CFNotificationCenterGetDistributedCenter(),
      Unmanaged.passUnretained(self).toOpaque(),
      CFNotificationName(kTISNotifySelectedKeyboardInputSourceChanged!),
      nil
    )
    macOSInputSourceNotificationRegistered = false
  }

  fileprivate func handleMacOSInputSourceChanged() {
    guard Thread.isMainThread else { return }
    refreshMacOSInputSourceSnapshot()
  }

  private func readMacOSInputSourceSnapshot() -> MacOSInputSourceSnapshot {
    macOSInputSourceSnapshotLock.lock()
    defer { macOSInputSourceSnapshotLock.unlock() }
    return macOSInputSourceSnapshot
  }

  /// Selects the next enabled/selectable keyboard input source owned by this
  /// macOS Host.
  ///
  /// The Viewer supplies no source identity or language. The Host owns the
  /// selectable list and cycles it directly with `TISSelectInputSource`, which
  /// is the previously user-validated production path.
  private func selectNextMacOSInputSource(requestOrdinal: Int? = nil) -> Bool {
    guard Thread.isMainThread else {
      macOSInputSourceDiagnosticLog("selection_rejected reason=not_main_thread")
      return false
    }
    let selectableSources = macOSSelectableKeyboardInputSources()
    guard selectableSources.count > 1 else {
      macOSInputSourceDiagnosticLog(
        "selection_rejected reason=fewer_than_two_sources"
      )
      return false
    }

    let current = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    guard let currentIndex = selectableSources.firstIndex(where: {
      CFEqual($0, current)
    }) else {
      macOSInputSourceDiagnosticLog(
        "selection_rejected reason=current_not_selectable"
      )
      return false
    }
    let next = selectableSources[(currentIndex + 1) % selectableSources.count]
    let selectionStatus = TISSelectInputSource(next)
    guard selectionStatus == noErr else {
      macOSInputSourceDiagnosticLog("Input-source selection failed status=\(selectionStatus)")
      return false
    }
    return true
  }

  private func macOSInputSourceRequestOrdinal(
    from arguments: Any?
  ) -> Int? {
    guard
      let values = arguments as? [String: Any],
      let ordinal = values["requestOrdinal"] as? Int,
      ordinal > 0
    else {
      return nil
    }
    return ordinal
  }

  private func macOSKeyboardInputSourceId(_ source: TISInputSource) -> String? {
    guard let rawId = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
    else {
      return nil
    }
    return Unmanaged<CFString>
      .fromOpaque(rawId)
      .takeUnretainedValue() as String
  }

  private func macOSInputSourceLogValue(_ value: String?) -> String {
    value ?? "none"
  }

  private func macOSInputSourceDiagnosticLog(_ message: String) {
#if CPP_LOG_AVAILABLE
    guard let emit = macOSCppLogEmit else { return }
    "RD_INPUT_SOURCE_NATIVE".withCString { tag in
      message.withCString { message in
        emit(2, tag, message)
      }
    }
#endif
  }

  /// Capture retries can occur once per second while a remote view remains
  /// eligible. Preserve the first occurrence of each state/reason, rather
  /// than flooding diagnostic storage with identical lines.
  private func reportMacOSInputSourceCaptureDiagnostic(_ message: String) {
    guard macOSInputSourceCaptureLastDiagnostic != message else { return }
    macOSInputSourceCaptureLastDiagnostic = message
    macOSInputSourceDiagnosticLog(message)
  }

  private func macOSHidUsageDiagnostic(_ usage: UInt64) -> String {
    String(format: "0x%llX", usage)
  }

  /// The log contains only mapping identities and counts, never user input.
  private func macOSUserKeyMappingDiagnostic(
    _ mapping: MacOSUserKeyMapping?
  ) -> String {
    guard let mapping else { return "unreadable" }
    if mapping.isEmpty { return "empty" }
    let entries = mapping.map { item -> String in
      let source = item[Self.macOSUserKeyMappingSourceKey]
        .map(macOSHidUsageDiagnostic) ?? "missing"
      let destination = item[Self.macOSUserKeyMappingDestinationKey]
        .map(macOSHidUsageDiagnostic) ?? "missing"
      return "\(source)->\(destination)"
    }.joined(separator: ",")
    return "count=\(mapping.count)[\(entries)]"
  }

  /// IOHID may reorder independent UserKeyMapping entries when it writes them
  /// back. Ordering is not part of this user preference's semantics; every
  /// source/destination pair must still match exactly.
  private func macOSUserKeyMappingsEqual(
    _ lhs: MacOSUserKeyMapping?,
    _ rhs: MacOSUserKeyMapping
  ) -> Bool {
    guard let lhs, lhs.count == rhs.count else { return false }
    return macOSUserKeyMappingEntries(lhs) == macOSUserKeyMappingEntries(rhs)
  }

  /// A successful IOHID write with a strict-readback failure can leave only a
  /// subset of the mapping behind. That subset contains no user-owned entries
  /// outside the transaction, so it is safe to roll back immediately. A
  /// readback with an unfamiliar entry is treated as a possible user/tool edit
  /// and remains protected by the journal rather than being overwritten.
  private func macOSUserKeyMappingIsSubset(
    _ candidate: MacOSUserKeyMapping?,
    of expected: MacOSUserKeyMapping
  ) -> Bool {
    guard let candidate else { return false }
    let candidateEntries = Set(macOSUserKeyMappingEntries(candidate))
    let expectedEntries = Set(macOSUserKeyMappingEntries(expected))
    return candidateEntries.isSubset(of: expectedEntries)
  }

  private func macOSUserKeyMappingEntries(
    _ mapping: MacOSUserKeyMapping
  ) -> [String] {
    mapping.map { item in
      let source = item[Self.macOSUserKeyMappingSourceKey]
        .map(macOSHidUsageDiagnostic) ?? "missing"
      let destination = item[Self.macOSUserKeyMappingDestinationKey]
        .map(macOSHidUsageDiagnostic) ?? "missing"
      return "\(source)->\(destination)"
    }.sorted()
  }

  private func handleTrackpadScroll(_ event: NSEvent) {
    guard event.hasPreciseScrollingDeltas else { return }
    if flutterView?.window !== event.window {
      flutterView = registrar?.view ?? registrar?.viewController?.view
    }
    guard let flutterView, event.window === flutterView.window else { return }

    let isMomentum = event.momentumPhase.rawValue != 0
    let eventPhase = isMomentum ? event.momentumPhase : event.phase
    guard eventPhase.rawValue != 0 else { return }

    let point = flutterView.convert(event.locationInWindow, from: nil)
    let flutterY = flutterView.isFlipped
      ? point.y
      : flutterView.bounds.height - point.y
    methodChannel?.invokeMethod(
      "onTrackpadScroll",
      arguments: [
        "x": point.x,
        "y": flutterY,
        // AppKit reports gesture direction; the plugin API uses page direction.
        "dx": -event.scrollingDeltaX,
        "dy": -event.scrollingDeltaY,
        "phase": trackpadScrollPhaseName(eventPhase),
        "isMomentum": isMomentum,
      ]
    )
  }

  private func trackpadScrollPhaseName(_ phase: NSEvent.Phase) -> String {
    if phase.contains(.cancelled) { return "cancelled" }
    if phase.contains(.ended) { return "ended" }
    if phase.contains(.began) { return "began" }
    if phase.contains(.mayBegin) { return "mayBegin" }
    if phase.contains(.stationary) { return "stationary" }
    if phase.contains(.changed) { return "changed" }
    return "none"
  }

#if CLOUDPLAYPLUS_DMG_DISTRIBUTION
  private struct MacVirtualDisplayConfig: Hashable {
    let width: Int
    let height: Int
    let refreshRate: Int
  }

  private struct MacVirtualDisplaySession {
    let process: Process
    let input: Pipe
    let output: Pipe
    let serial: Int
    var configs: [MacVirtualDisplayConfig]
  }

  private struct MacDisplayBackupItem {
    let displayId: CGDirectDisplayID
    let mode: CGDisplayMode?
    let origin: CGPoint
    let mirrorTarget: CGDirectDisplayID
  }

  private struct MacSLSDisplayConfig {
    typealias ConfigureEnabledFn = @convention(c) (
      CGDisplayConfigRef?,
      CGDirectDisplayID,
      Bool
    ) -> CGError
    typealias GetDisplayListFn = @convention(c) (
      UInt32,
      UnsafeMutablePointer<CGDirectDisplayID>?,
      UnsafeMutablePointer<UInt32>?
    ) -> CGError

    let configureEnabled: ConfigureEnabledFn
    let getDisplayList: GetDisplayListFn

    static func load(
      using loadSkyLight: () -> UnsafeMutableRawPointer?
    ) -> MacSLSDisplayConfig? {
      guard let handle = loadSkyLight() else {
        return nil
      }

      func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let pointer = dlsym(handle, name) else {
          return nil
        }
        return unsafeBitCast(pointer, to: type)
      }

      guard
        let configureEnabled = symbol(
          "SLSConfigureDisplayEnabled",
          as: ConfigureEnabledFn.self
        ) ?? symbol("CGSConfigureDisplayEnabled", as: ConfigureEnabledFn.self),
        let getDisplayList =
          symbol("SLSGetDisplayList", as: GetDisplayListFn.self)
          ?? symbol("CGSGetDisplayList", as: GetDisplayListFn.self)
      else {
        return nil
      }

      return MacSLSDisplayConfig(
        configureEnabled: configureEnabled,
        getDisplayList: getDisplayList
      )
    }
  }

  private func loadMacSkyLight() -> UnsafeMutableRawPointer? {
    if let macSkyLightHandle {
      return macSkyLightHandle
    }
    let path = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    guard let handle = dlopen(path, RTLD_NOW) else {
      return nil
    }
    macSkyLightHandle = handle
    return handle
  }

  private func clearMacDisplayError() {
    macLastVirtualDisplayError = nil
  }

  private func macCGErrorDescription(_ error: CGError) -> String {
    return "CGError(\(error.rawValue))"
  }

  private func completeMacDisplayConfiguration(
    _ config: CGDisplayConfigRef,
    reason: String
  ) -> Bool {
    let completeError = CGCompleteDisplayConfiguration(config, .forSession)
    guard completeError == .success else {
      return setMacDisplayError(
        "CGCompleteDisplayConfiguration(\(reason)) failed: \(macCGErrorDescription(completeError))"
      )
    }
    return true
  }

  @discardableResult
  private func setMacDisplayError(_ message: String) -> Bool {
    macLastVirtualDisplayError = message
    NSLog("CloudPlayPlus macOS display: %@", message)
    return false
  }

  private func registerMacTerminationObserver() {
    guard macTerminationObserver == nil else {
      return
    }
    macTerminationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      self?.restoreMacDisplaysBeforeExit()
    }
  }

  private func restoreMacDisplaysBeforeExit() {
    if macDisplayConfigurationBackup != nil {
      _ = restoreMacDisplayConfiguration()
    }
    terminateAllMacVirtualDisplays()
  }

  private func macHelperURL() -> URL? {
    return Bundle.main.bundleURL
      .appendingPathComponent("Contents")
      .appendingPathComponent("MacOS")
      .appendingPathComponent(macHelperName)
  }

  private func macVirtualDisplayAvailable() -> Bool {
    guard #available(macOS 14.0, *) else {
      return false
    }
    guard loadMacSkyLight() != nil else {
      return false
    }
    guard NSClassFromString("CGVirtualDisplay") != nil else {
      return false
    }
    guard let helper = macHelperURL() else {
      return false
    }
    return FileManager.default.isExecutableFile(atPath: helper.path)
  }

  private func macDefaultDisplayConfig() -> MacVirtualDisplayConfig {
    return MacVirtualDisplayConfig(width: 1920, height: 1080, refreshRate: 60)
  }

  private func macCommonDisplayConfigs(
    refreshRate: Int = 60
  ) -> [MacVirtualDisplayConfig] {
    return [
      MacVirtualDisplayConfig(width: 1280, height: 720, refreshRate: refreshRate),
      MacVirtualDisplayConfig(width: 1366, height: 768, refreshRate: refreshRate),
      MacVirtualDisplayConfig(width: 1600, height: 900, refreshRate: refreshRate),
      MacVirtualDisplayConfig(width: 1600, height: 1200, refreshRate: refreshRate),
      MacVirtualDisplayConfig(width: 1920, height: 1080, refreshRate: refreshRate),
      MacVirtualDisplayConfig(width: 1920, height: 1200, refreshRate: refreshRate),
      MacVirtualDisplayConfig(width: 2560, height: 1080, refreshRate: refreshRate),
      MacVirtualDisplayConfig(width: 2560, height: 1440, refreshRate: refreshRate),
      MacVirtualDisplayConfig(width: 3440, height: 1440, refreshRate: refreshRate),
      MacVirtualDisplayConfig(width: 3840, height: 2160, refreshRate: refreshRate),
    ]
  }

  private func macVirtualDisplayConfig(
    from raw: [String: Any]
  ) -> MacVirtualDisplayConfig? {
    guard
      let width = raw["width"] as? Int,
      let height = raw["height"] as? Int,
      let refreshRate = raw["refreshRate"] as? Int,
      width > 0,
      height > 0,
      refreshRate > 0
    else {
      return nil
    }
    return MacVirtualDisplayConfig(
      width: width,
      height: height,
      refreshRate: refreshRate
    )
  }

  private func macVirtualDisplayConfig(
    from raw: [String: Int]
  ) -> MacVirtualDisplayConfig? {
    guard
      let width = raw["width"],
      let height = raw["height"],
      let refreshRate = raw["refreshRate"],
      width > 0,
      height > 0,
      refreshRate > 0
    else {
      return nil
    }
    return MacVirtualDisplayConfig(
      width: width,
      height: height,
      refreshRate: refreshRate
    )
  }

  private func macCreateDisplayConfigs(
    primary: MacVirtualDisplayConfig,
    rawConfigs: [[String: Any]]?
  ) -> [MacVirtualDisplayConfig] {
    var configs: [MacVirtualDisplayConfig] = []
    var seen = Set<MacVirtualDisplayConfig>()
    func append(_ config: MacVirtualDisplayConfig) {
      guard !seen.contains(config) else {
        return
      }
      seen.insert(config)
      configs.append(config)
    }

    append(primary)
    if let rawConfigs, !rawConfigs.isEmpty {
      for raw in rawConfigs {
        guard let config = macVirtualDisplayConfig(from: raw) else {
          continue
        }
        append(config)
      }
      return configs
    }

    for config in macCommonDisplayConfigs(refreshRate: primary.refreshRate) {
      append(config)
    }
    for raw in macCustomDisplayConfigs().prefix(5) {
      guard let config = macVirtualDisplayConfig(from: raw) else {
        continue
      }
      append(config)
    }
    return configs
  }

  private func readMacHelperLine(from output: Pipe, timeout: DispatchTime) -> String? {
    let handle = output.fileHandleForReading
    let semaphore = DispatchSemaphore(value: 0)
    let lock = NSLock()
    var data = Data()
    var finished = false

    handle.readabilityHandler = { readableHandle in
      let chunk = readableHandle.availableData
      lock.lock()
      defer { lock.unlock() }
      guard !finished else {
        return
      }
      if chunk.isEmpty {
        finished = true
        semaphore.signal()
        return
      }
      data.append(chunk)
      if data.contains(0x0A) {
        finished = true
        semaphore.signal()
      }
    }

    let status = semaphore.wait(timeout: timeout)
    handle.readabilityHandler = nil
    if status == .timedOut {
      return nil
    }

    lock.lock()
    let captured = data
    lock.unlock()
    return String(data: captured, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func macCustomDisplayConfigs() -> [[String: Int]] {
    guard
      let raw = UserDefaults.standard.array(forKey: macCustomDisplayConfigsKey)
        as? [[String: Any]]
    else {
      return []
    }
    return raw.compactMap { item in
      guard
        let width = item["width"] as? Int,
        let height = item["height"] as? Int,
        let refreshRate = item["refreshRate"] as? Int,
        width > 0,
        height > 0,
        refreshRate > 0
      else {
        return nil
      }
      return [
        "width": width,
        "height": height,
        "refreshRate": refreshRate,
      ]
    }
  }

  private func setMacCustomDisplayConfigs(_ configs: [[String: Any]]) -> Bool {
    let sanitized = configs.compactMap { item -> [String: Int]? in
      let width = item["width"] as? Int
      let height = item["height"] as? Int
      let refreshRate = item["refreshRate"] as? Int
      guard
        let width = width,
        let height = height,
        let refreshRate = refreshRate,
        width > 0,
        height > 0,
        refreshRate > 0
      else {
        return nil
      }
      return [
        "width": width,
        "height": height,
        "refreshRate": refreshRate,
      ]
    }
    let capped = sanitized.count <= 5
      ? sanitized
      : Array(sanitized.suffix(5))
    UserDefaults.standard.set(capped, forKey: macCustomDisplayConfigsKey)
    return sanitized.count == configs.count
  }

  private func withMacVirtualDisplayProcesses<T>(_ body: () -> T) -> T {
    if DispatchQueue.getSpecific(key: macVirtualDisplayQueueKey) != nil {
      return body()
    }
    return macVirtualDisplayQueue.sync(execute: body)
  }

  private func nextMacVirtualDisplaySerial() -> Int {
    let usedSerials = Set(macVirtualDisplaySessions.values.map(\.serial))
    for slot in 1...255 {
      let serial = macVirtualDisplaySerialBase + slot
      if !usedSerials.contains(serial) {
        return serial
      }
    }
    return macVirtualDisplaySerialBase + macVirtualDisplaySessions.count + 1
  }

  private func spawnMacVirtualDisplay(
    width: Int,
    height: Int,
    refreshRate: Int,
    configs: [MacVirtualDisplayConfig]? = nil
  ) -> Int {
    guard macVirtualDisplayAvailable(), let helper = macHelperURL() else {
      return -1
    }

    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let serial = nextMacVirtualDisplaySerial()
    let requested = MacVirtualDisplayConfig(
      width: width,
      height: height,
      refreshRate: refreshRate
    )
    let displayConfigs = configs ?? macCreateDisplayConfigs(
      primary: requested,
      rawConfigs: nil
    )
    process.executableURL = helper
    var arguments = [
      "\(width)",
      "\(height)",
      "\(refreshRate)",
      "\(ProcessInfo.processInfo.processIdentifier)",
      "\(serial)",
    ]
    arguments.append(contentsOf: displayConfigs.flatMap { config in
      [
        "\(config.width)",
        "\(config.height)",
        "\(config.refreshRate)",
      ]
    })
    process.arguments = arguments
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.standardError

    do {
      try process.run()
    } catch {
      return -1
    }

    guard
      let text = readMacHelperLine(
        from: output,
        timeout: .now() + .seconds(10)
      )
    else {
      process.terminate()
      return -1
    }
    guard let displayId = Int(text), displayId > 0 else {
      process.terminate()
      return -1
    }

    process.terminationHandler = { [weak self] _ in
      self?.macVirtualDisplayQueue.async {
        guard
          let session = self?.macVirtualDisplaySessions[displayId],
          session.process === process
        else {
          return
        }
        self?.macVirtualDisplaySessions.removeValue(forKey: displayId)
      }
    }
    withMacVirtualDisplayProcesses {
      macVirtualDisplaySessions[displayId] = MacVirtualDisplaySession(
        process: process,
        input: input,
        output: output,
        serial: serial,
        configs: displayConfigs
      )
    }
    // 初始 ID 不代表尺寸已就绪；让 helper 统一完成 HiDPI / 1× 选择，
    // 再由主进程核验实际像素尺寸。失败必须回收，不能留下误报成功的显示器。
    Thread.sleep(forTimeInterval: 2.0)
    guard applyMacVirtualDisplayMode(displayId: displayId, config: requested),
      macDisplayBackingMatches(displayId: displayId, config: requested)
    else {
      _ = terminateMacVirtualDisplay(displayId)
      return -1
    }
    return displayId
  }

  private func terminateMacVirtualDisplay(_ displayId: Int) -> Bool {
    if macDisplayConfigurationBackup?.contains(
      where: { Int($0.displayId) == displayId }
    ) == true {
      _ = restoreMacDisplayConfiguration()
    }
    let session: MacVirtualDisplaySession? = withMacVirtualDisplayProcesses {
      macVirtualDisplaySessions.removeValue(forKey: displayId)
    }
    guard let session else {
      return false
    }
    try? session.input.fileHandleForWriting.close()
    let process = session.process
    if process.isRunning {
      process.terminate()
    }
    return true
  }

  private func terminateAllMacVirtualDisplays() {
    withMacVirtualDisplayProcesses {
      for session in macVirtualDisplaySessions.values {
        try? session.input.fileHandleForWriting.close()
        if session.process.isRunning {
          session.process.terminate()
        }
      }
      macVirtualDisplaySessions.removeAll()
    }
  }

  private func macVirtualDisplayIdsSnapshot() -> Set<Int> {
    return withMacVirtualDisplayProcesses {
      Set(macVirtualDisplaySessions.keys)
    }
  }

  private func macVirtualDisplayConfigsSnapshot(
    _ displayId: Int
  ) -> [MacVirtualDisplayConfig]? {
    withMacVirtualDisplayProcesses {
      macVirtualDisplaySessions[displayId]?.configs
    }
  }

  private func applyMacVirtualDisplayMode(
    displayId: Int,
    config: MacVirtualDisplayConfig
  ) -> Bool {
    withMacVirtualDisplayProcesses {
      guard var session = macVirtualDisplaySessions[displayId] else {
        return false
      }
      let command = "SET \(config.width) \(config.height) \(config.refreshRate)\n"
      guard let data = command.data(using: .utf8) else {
        return false
      }
      if #available(macOS 10.15.4, *) {
        do {
          try session.input.fileHandleForWriting.write(contentsOf: data)
        } catch {
          return false
        }
      } else {
        session.input.fileHandleForWriting.write(data)
      }
      guard
        let response = readMacHelperLine(
          from: session.output,
          timeout: .now() + .seconds(8)
        )
      else {
        return false
      }
      guard response == "OK \(displayId)" else {
        return false
      }
      if !session.configs.contains(config) {
        session.configs.append(config)
        macVirtualDisplaySessions[displayId] = session
      }
      return true
    }
  }

  private func screenNameByDisplayId() -> [Int: String] {
    var names: [Int: String] = [:]
    for screen in NSScreen.screens {
      guard
        let number = screen.deviceDescription[
          NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber
      else {
        continue
      }
      if #available(macOS 10.15, *) {
        names[number.intValue] = screen.localizedName
      } else {
        names[number.intValue] = "Display \(number.intValue)"
      }
    }
    return names
  }

  private func displayRefreshRate(_ mode: CGDisplayMode?) -> Int {
    guard let mode else {
      return 60
    }
    let refresh = mode.refreshRate
    if refresh.isFinite && refresh > 0 {
      return Int(refresh.rounded())
    }
    return 60
  }

  private func macDisplayBackingMatches(
    displayId: Int,
    config: MacVirtualDisplayConfig
  ) -> Bool {
    guard let mode = CGDisplayCopyDisplayMode(CGDirectDisplayID(displayId)) else {
      return false
    }
    return mode.pixelWidth == config.width && mode.pixelHeight == config.height
  }

  private func macDisplayList() -> [[String: Any]] {
    let displayIds = enabledMacDisplayIds()
    guard !displayIds.isEmpty else {
      return []
    }

    let names = screenNameByDisplayId()
    let mainId = Int(CGMainDisplayID())
    let virtualDisplayIds = macVirtualDisplayIdsSnapshot()
    return displayIds.enumerated().map { index, id in
      let displayId = Int(id)
      let mode = CGDisplayCopyDisplayMode(id)
      // Keep the reported size in the same pixel coordinate space used by
      // macDisplayConfigs() and setMacDisplayMode(). CGDisplayPixelsWide/High
      // can expose the scaled logical size for HiDPI virtual displays.
      let modeWidth = mode?.pixelWidth ?? 0
      let modeHeight = mode?.pixelHeight ?? 0
      let bounds = CGDisplayBounds(id)
      let isVirtual = virtualDisplayIds.contains(displayId)
      let name = isVirtual
        ? "CloudPlayPlus Virtual Display"
        : (names[displayId] ?? "Display \(displayId)")
      return [
        "index": index,
        "width": modeWidth > 0 ? modeWidth : CGDisplayPixelsWide(id),
        "height": modeHeight > 0 ? modeHeight : CGDisplayPixelsHigh(id),
        "refreshRate": displayRefreshRate(mode),
        "isVirtual": isVirtual,
        "displayName": name,
        "deviceName": "\(displayId)",
        "active": isMacDisplayEnabled(id),
        "displayUid": displayId,
        "rawScreenId": displayId,
        "orientation": 0,
        "left": Int(bounds.minX.rounded()),
        "top": Int(bounds.minY.rounded()),
        "right": Int(bounds.maxX.rounded()),
        "bottom": Int(bounds.maxY.rounded()),
        "isPrimary": displayId == mainId,
      ]
    }
  }

  private func macDisplayConfigs(_ displayId: CGDirectDisplayID) -> [[String: Int]] {
    var configs: [[String: Int]] = []
    if let virtualConfigs = macVirtualDisplayConfigsSnapshot(Int(displayId)) {
      configs.append(contentsOf: virtualConfigs.map { config in
        [
          "width": config.width,
          "height": config.height,
          "refreshRate": config.refreshRate,
        ]
      })
    }
    let options = [
      kCGDisplayShowDuplicateLowResolutionModes as String: true,
    ] as CFDictionary
    if let modes = CGDisplayCopyAllDisplayModes(displayId, options) as? [CGDisplayMode] {
      for mode in modes {
        let width = mode.pixelWidth > 0 ? mode.pixelWidth : mode.width
        let height = mode.pixelHeight > 0 ? mode.pixelHeight : mode.height
        let refreshRate = displayRefreshRate(mode)
        if width > 0 && height > 0 && refreshRate > 0 {
          configs.append([
            "width": width,
            "height": height,
            "refreshRate": refreshRate,
          ])
        }
      }
    }
    configs.append(contentsOf: macCustomDisplayConfigs())
    var seen = Set<String>()
    return configs.filter { item in
      let key = "\(item["width"] ?? 0)x\(item["height"] ?? 0)@\(item["refreshRate"] ?? 0)"
      if seen.contains(key) {
        return false
      }
      seen.insert(key)
      return true
    }.sorted { lhs, rhs in
      let lw = lhs["width"] ?? 0
      let rw = rhs["width"] ?? 0
      if lw != rw { return lw < rw }
      let lh = lhs["height"] ?? 0
      let rh = rhs["height"] ?? 0
      if lh != rh { return lh < rh }
      return (lhs["refreshRate"] ?? 0) < (rhs["refreshRate"] ?? 0)
    }
  }

  private func setMacDisplayMode(
    displayId: Int,
    width: Int,
    height: Int,
    refreshRate: Int
  ) -> Bool {
    let cgDisplayId = CGDirectDisplayID(displayId)
    let config = MacVirtualDisplayConfig(
      width: width,
      height: height,
      refreshRate: refreshRate
    )
    if macVirtualDisplayIdsSnapshot().contains(displayId) {
      if applyMacVirtualDisplayMode(displayId: displayId, config: config),
        macDisplayBackingMatches(displayId: displayId, config: config)
      {
        return true
      }
      var configs = macVirtualDisplayConfigsSnapshot(displayId) ?? []
      if !configs.contains(config) {
        configs.append(config)
      }
      _ = terminateMacVirtualDisplay(displayId)
      return spawnMacVirtualDisplay(
        width: width,
        height: height,
        refreshRate: refreshRate,
        configs: configs
      ) > 0
    }

    let options = [
      kCGDisplayShowDuplicateLowResolutionModes as String: true,
    ] as CFDictionary
    if let modes = CGDisplayCopyAllDisplayModes(cgDisplayId, options) as? [CGDisplayMode] {
      for mode in modes {
        let modeWidth = mode.pixelWidth > 0 ? mode.pixelWidth : mode.width
        let modeHeight = mode.pixelHeight > 0 ? mode.pixelHeight : mode.height
        let modeRefresh = displayRefreshRate(mode)
        if modeWidth == width && modeHeight == height && modeRefresh == refreshRate {
          return CGDisplaySetDisplayMode(cgDisplayId, mode, nil) == .success
        }
      }
    }

    return false
  }

  private func allMacDisplayIds(limit: Int = 32) -> [CGDirectDisplayID] {
    guard let sls = macSLSDisplayConfig else {
      setMacDisplayError("SkyLight display configuration symbols are unavailable")
      return []
    }

    var displayIds = Array<CGDirectDisplayID>(repeating: 0, count: limit)
    var displayCount: UInt32 = 0
    let error = displayIds.withUnsafeMutableBufferPointer { buffer in
      sls.getDisplayList(UInt32(buffer.count), buffer.baseAddress, &displayCount)
    }
    guard error == .success else {
      setMacDisplayError(
        "SLSGetDisplayList failed: \(macCGErrorDescription(error))"
      )
      return []
    }
    return Array(displayIds.prefix(min(Int(displayCount), displayIds.count)))
  }

  private func isMacDisplayEnabled(_ displayId: CGDirectDisplayID) -> Bool {
    return CGDisplayIsActive(displayId) != 0 ||
      CGDisplayIsInMirrorSet(displayId) != 0
  }

  private func enabledMacDisplayIds() -> [CGDirectDisplayID] {
    return allMacDisplayIds().filter(isMacDisplayEnabled)
  }

  private func isMacCloudPlayVirtualDisplay(_ displayId: CGDirectDisplayID) -> Bool {
    let serial = Int(CGDisplaySerialNumber(displayId))
    return macVirtualDisplayIdsSnapshot().contains(Int(displayId)) ||
      (serial > macVirtualDisplaySerialBase && serial <= macVirtualDisplaySerialMax)
  }

  private func isMacDisplayEnableCandidate(_ displayId: CGDirectDisplayID) -> Bool {
    if CGDisplayIsBuiltin(displayId) != 0 || isMacDisplayEnabled(displayId) {
      return true
    }
    if isMacCloudPlayVirtualDisplay(displayId) {
      return macVirtualDisplayIdsSnapshot().contains(Int(displayId))
    }
    return CGDisplayVendorNumber(displayId) != 0 ||
      CGDisplayModelNumber(displayId) != 0 ||
      CGDisplaySerialNumber(displayId) != 0
  }

  private func enableableMacDisplayIds() -> [CGDirectDisplayID] {
    return allMacDisplayIds().filter(isMacDisplayEnableCandidate)
  }

  private func unmirrorMacDisplays(_ displayIds: [CGDirectDisplayID]) -> Bool {
    var config: CGDisplayConfigRef?
    let beginError = CGBeginDisplayConfiguration(&config)
    guard beginError == .success, let config else {
      return setMacDisplayError(
        "CGBeginDisplayConfiguration(unmirror) failed: \(macCGErrorDescription(beginError))"
      )
    }

    var changed = false
    for id in displayIds {
      guard CGDisplayIsInMirrorSet(id) != 0,
        CGDisplayMirrorsDisplay(id) != 0
      else {
        continue
      }
      let error = CGConfigureDisplayMirrorOfDisplay(
        config,
        id,
        kCGNullDirectDisplay
      )
      guard error == .success else {
        CGCancelDisplayConfiguration(config)
        return setMacDisplayError(
          "CGConfigureDisplayMirrorOfDisplay(unmirror \(id)) failed: \(macCGErrorDescription(error))"
        )
      }
      changed = true
    }

    guard changed else {
      CGCancelDisplayConfiguration(config)
      return true
    }

    return completeMacDisplayConfiguration(config, reason: "unmirror")
  }

  private func configureMacDisplayEnabled(
    _ displayIds: [CGDirectDisplayID],
    enabled: (CGDirectDisplayID) -> Bool
  ) -> Bool {
    guard let sls = macSLSDisplayConfig else {
      return setMacDisplayError(
        "SkyLight display configuration symbols are unavailable"
      )
    }

    var config: CGDisplayConfigRef?
    let beginError = CGBeginDisplayConfiguration(&config)
    guard beginError == .success, let config else {
      return setMacDisplayError(
        "CGBeginDisplayConfiguration(enable) failed: \(macCGErrorDescription(beginError))"
      )
    }

    for id in displayIds {
      let shouldEnable = enabled(id)
      if isMacDisplayEnabled(id) == shouldEnable {
        continue
      }
      let enabledError = sls.configureEnabled(config, id, shouldEnable)
      guard enabledError == .success else {
        CGCancelDisplayConfiguration(config)
        return setMacDisplayError(
          "SLSConfigureDisplayEnabled(\(id), \(shouldEnable)) failed: \(macCGErrorDescription(enabledError))"
        )
      }
    }

    return completeMacDisplayConfiguration(config, reason: "enable")
  }

  private func setMacExtendMode() -> Bool {
    clearMacDisplayError()
    let displayIds = enableableMacDisplayIds()
    guard !displayIds.isEmpty else {
      return setMacDisplayError("No displays found for extend mode")
    }
    guard configureMacDisplayEnabled(displayIds, enabled: { _ in true }) else {
      return false
    }
    Thread.sleep(forTimeInterval: 0.3)

    let activeIds = activeMacDisplayIds()
    guard !activeIds.isEmpty else {
      return setMacDisplayError("No active displays after enabling extend mode")
    }
    guard unmirrorMacDisplays(activeIds) else {
      return false
    }

    var config: CGDisplayConfigRef?
    let beginError = CGBeginDisplayConfiguration(&config)
    guard beginError == .success, let config else {
      return setMacDisplayError(
        "CGBeginDisplayConfiguration(extend) failed: \(macCGErrorDescription(beginError))"
      )
    }

    let primary = activeIds.contains(CGMainDisplayID())
      ? CGMainDisplayID()
      : activeIds[0]
    let orderedIds = [primary] + activeIds.filter { $0 != primary }

    var nextX: Int32 = 0
    for id in orderedIds {
      let bounds = CGDisplayBounds(id)
      let originError = CGConfigureDisplayOrigin(config, id, nextX, 0)
      guard originError == .success else {
        CGCancelDisplayConfiguration(config)
        return setMacDisplayError(
          "CGConfigureDisplayOrigin(extend \(id)) failed: \(macCGErrorDescription(originError))"
        )
      }
      nextX += Int32(bounds.width.rounded())
    }

    guard completeMacDisplayConfiguration(config, reason: "extend") else {
      return false
    }
    macDisplayConfigurationBackup = nil
    return true
  }

  private func setMacDuplicateMode() -> Bool {
    clearMacDisplayError()
    let displayIds = enableableMacDisplayIds()
    guard displayIds.count >= 2 else {
      return setMacDisplayError("Duplicate mode needs at least two displays")
    }
    guard configureMacDisplayEnabled(displayIds, enabled: { _ in true }) else {
      return false
    }
    Thread.sleep(forTimeInterval: 0.3)

    let activeIds = activeMacDisplayIds()
    guard activeIds.count >= 2 else {
      return setMacDisplayError(
        "Duplicate mode has fewer than two active displays after enabling"
      )
    }
    let primary = activeIds.contains(CGMainDisplayID())
      ? CGMainDisplayID()
      : activeIds[0]

    var config: CGDisplayConfigRef?
    let beginError = CGBeginDisplayConfiguration(&config)
    guard beginError == .success, let config else {
      return setMacDisplayError(
        "CGBeginDisplayConfiguration(duplicate) failed: \(macCGErrorDescription(beginError))"
      )
    }

    for id in activeIds where id != primary {
      let mirrorError = CGConfigureDisplayMirrorOfDisplay(config, id, primary)
      guard mirrorError == .success else {
        CGCancelDisplayConfiguration(config)
        return setMacDisplayError(
          "CGConfigureDisplayMirrorOfDisplay(\(id) -> \(primary)) failed: \(macCGErrorDescription(mirrorError))"
        )
      }
    }

    guard completeMacDisplayConfiguration(config, reason: "duplicate") else {
      return false
    }
    guard waitForMacDuplicateTopology(primary, expectedDisplayIds: activeIds) else {
      let mirrors = enabledMacDisplayIds().map {
        "\($0)->\(CGDisplayMirrorsDisplay($0))"
      }.joined(separator: ",")
      return setMacDisplayError(
        "Timed out waiting for duplicate topology; mirrors: [\(mirrors)]"
      )
    }
    macDisplayConfigurationBackup = nil
    return true
  }

  private func setMacSingleDisplayMode(at index: Int) -> Bool {
    clearMacDisplayError()
    let displayIds = enableableMacDisplayIds()
    guard displayIds.indices.contains(index) else {
      return setMacDisplayError("Display index \(index) is unavailable")
    }
    return setMacPrimaryDisplayOnly(Int(displayIds[index]))
  }

  private func getCurrentMacMultiDisplayMode() -> Int {
    let displayIds = macDisplayConfigurationBackup?.map { $0.displayId }
      ?? allMacDisplayIds()
    let enabledIds = displayIds.filter(isMacDisplayEnabled)
    guard !enabledIds.isEmpty else {
      return 4
    }
    if enabledIds.count <= 1 {
      guard let activeId = enabledIds.first,
        let index = displayIds.firstIndex(of: activeId)
      else {
        return 1
      }
      return index == 1 ? 2 : 1
    }

    let mirroredCount = enabledIds.filter { id in
      CGDisplayMirrorsDisplay(id) != 0
    }.count
    if mirroredCount > 0 {
      return 3
    }
    return 0
  }

  private func activeMacDisplayIds(limit: Int = 32) -> [CGDirectDisplayID] {
    var displayIds = Array<CGDirectDisplayID>(repeating: 0, count: limit)
    var displayCount: UInt32 = 0
    let error = CGGetActiveDisplayList(
      UInt32(displayIds.count),
      &displayIds,
      &displayCount
    )
    guard error == .success else {
      setMacDisplayError(
        "CGGetActiveDisplayList failed: \(macCGErrorDescription(error))"
      )
      return []
    }
    return Array(displayIds.prefix(Int(displayCount)))
  }

  private func saveMacDisplayConfiguration(
    displayIds inputDisplayIds: [CGDirectDisplayID]? = nil
  ) -> Bool {
    let displayIds = inputDisplayIds ?? activeMacDisplayIds()
    guard !displayIds.isEmpty else {
      return setMacDisplayError("No displays available to save configuration")
    }

    macDisplayConfigurationBackup = displayIds.map { displayId in
      let bounds = CGDisplayBounds(displayId)
      return MacDisplayBackupItem(
        displayId: displayId,
        mode: CGDisplayCopyDisplayMode(displayId),
        origin: bounds.origin,
        mirrorTarget: CGDisplayMirrorsDisplay(displayId)
      )
    }
    return true
  }

  private func waitForMacMainDisplay(
    _ displayId: CGDirectDisplayID,
    timeout: TimeInterval = 1
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      if CGMainDisplayID() == displayId || CGDisplayIsMain(displayId) != 0 {
        return true
      }
      Thread.sleep(forTimeInterval: 0.1)
    } while Date() < deadline
    return false
  }

  private func waitForMacPrimaryOnlyTopology(
    _ displayId: CGDirectDisplayID,
    timeout: TimeInterval = 1.5
  ) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      let enabledIds = enabledMacDisplayIds()
      if enabledIds.count == 1 && enabledIds.first == displayId {
        return true
      }
      Thread.sleep(forTimeInterval: 0.1)
    } while Date() < deadline
    return false
  }

  private func waitForMacDuplicateTopology(
    _ primaryDisplayId: CGDirectDisplayID,
    expectedDisplayIds: [CGDirectDisplayID],
    timeout: TimeInterval = 1.5
  ) -> Bool {
    let expected = Set(expectedDisplayIds)
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
      let enabledIds = enabledMacDisplayIds()
      let enabled = Set(enabledIds)
      let allExpectedEnabled = expected.isSubset(of: enabled)
      let mirroredDisplays = enabledIds.filter { id in
        id != primaryDisplayId && CGDisplayMirrorsDisplay(id) == primaryDisplayId
      }
      if enabled.contains(primaryDisplayId),
        allExpectedEnabled,
        mirroredDisplays.count == enabledIds.count - 1 {
        return true
      }
      Thread.sleep(forTimeInterval: 0.1)
    } while Date() < deadline
    return false
  }

  private func setMacMainDisplay(
    _ targetDisplayId: CGDirectDisplayID,
    displayIds: [CGDirectDisplayID]
  ) -> Bool {
    guard displayIds.contains(targetDisplayId) else {
      return setMacDisplayError("Target display \(targetDisplayId) is not configurable")
    }

    let targetBounds = CGDisplayBounds(targetDisplayId)
    let deltaX = -targetBounds.origin.x
    let deltaY = -targetBounds.origin.y

    var config: CGDisplayConfigRef?
    let beginError = CGBeginDisplayConfiguration(&config)
    guard beginError == .success, let config else {
      return setMacDisplayError(
        "CGBeginDisplayConfiguration(primary) failed: \(macCGErrorDescription(beginError))"
      )
    }

    for id in displayIds {
      let bounds = CGDisplayBounds(id)
      let newX = Int32((bounds.origin.x + deltaX).rounded())
      let newY = Int32((bounds.origin.y + deltaY).rounded())
      let originError = CGConfigureDisplayOrigin(config, id, newX, newY)
      guard originError == .success else {
        CGCancelDisplayConfiguration(config)
        return setMacDisplayError(
          "CGConfigureDisplayOrigin(primary \(id)) failed: \(macCGErrorDescription(originError))"
        )
      }
    }

    guard completeMacDisplayConfiguration(config, reason: "primary") else {
      return false
    }
    guard waitForMacMainDisplay(targetDisplayId) else {
      return setMacDisplayError(
        "Timed out waiting for display \(targetDisplayId) to become main"
      )
    }
    return true
  }

  private func setMacPrimaryDisplay(_ displayId: Int) -> Bool {
    clearMacDisplayError()
    let targetDisplayId = CGDirectDisplayID(displayId)
    guard CGDisplayIsActive(targetDisplayId) != 0 else {
      return setMacDisplayError("Target display \(targetDisplayId) is not active")
    }
    return setMacMainDisplay(targetDisplayId, displayIds: activeMacDisplayIds())
  }

  private func setMacPrimaryDisplayOnly(_ displayId: Int) -> Bool {
    clearMacDisplayError()
    let previousBackup = macDisplayConfigurationBackup
    func rollbackMacDisplayConfiguration() {
      let backup = previousBackup ?? macDisplayConfigurationBackup
      macDisplayConfigurationBackup = nil
      if backup != nil {
        _ = restoreMacDisplayConfiguration(from: backup)
      }
    }

    let targetDisplayId = CGDirectDisplayID(displayId)
    let displayIds = enableableMacDisplayIds()
    guard displayIds.contains(targetDisplayId) else {
      return setMacDisplayError("Target display \(targetDisplayId) is unavailable")
    }

    guard
      (macDisplayConfigurationBackup != nil ||
        saveMacDisplayConfiguration(displayIds: displayIds.filter(isMacDisplayEnabled)))
    else {
      rollbackMacDisplayConfiguration()
      return false
    }
    guard configureMacDisplayEnabled(displayIds, enabled: { id in
      id == targetDisplayId || CGDisplayIsActive(id) != 0
    }) else {
      rollbackMacDisplayConfiguration()
      return false
    }
    Thread.sleep(forTimeInterval: 0.3)

    let activeIds = activeMacDisplayIds()
    guard activeIds.contains(targetDisplayId) else {
      rollbackMacDisplayConfiguration()
      return setMacDisplayError(
        "Target display \(targetDisplayId) is not active after enabling"
      )
    }
    guard unmirrorMacDisplays(activeIds) else {
      rollbackMacDisplayConfiguration()
      return false
    }
    guard setMacMainDisplay(targetDisplayId, displayIds: activeIds) else {
      rollbackMacDisplayConfiguration()
      return false
    }

    guard configureMacDisplayEnabled(allMacDisplayIds(), enabled: { id in
      id == targetDisplayId
    }) else {
      rollbackMacDisplayConfiguration()
      return false
    }

    Thread.sleep(forTimeInterval: 0.5)
    guard waitForMacMainDisplay(targetDisplayId) else {
      rollbackMacDisplayConfiguration()
      return setMacDisplayError(
        "Timed out waiting for display \(targetDisplayId) to remain main"
      )
    }
    guard waitForMacPrimaryOnlyTopology(targetDisplayId) else {
      let activeIds = activeMacDisplayIds().map(String.init).joined(separator: ",")
      rollbackMacDisplayConfiguration()
      return setMacDisplayError(
        "Timed out waiting for primary-only topology; active displays: [\(activeIds)]"
      )
    }
    return true
  }

  private func restoreMacDefaultDisplayConfiguration() -> Bool {
    let displayIds = enableableMacDisplayIds()
    guard !displayIds.isEmpty else {
      return setMacDisplayError("No displays found for default restore")
    }
    guard configureMacDisplayEnabled(displayIds, enabled: { _ in true }) else {
      return false
    }
    Thread.sleep(forTimeInterval: 0.3)

    let activeIds = activeMacDisplayIds()
    guard !activeIds.isEmpty else {
      return setMacDisplayError("No active displays after default restore")
    }
    guard unmirrorMacDisplays(activeIds) else {
      return false
    }

    let virtualDisplayIds = macVirtualDisplayIdsSnapshot()
    let preferredMainDisplayId: CGDirectDisplayID
    if let builtInDisplayId = activeIds.first(where: { CGDisplayIsBuiltin($0) != 0 }) {
      preferredMainDisplayId = builtInDisplayId
    } else if let physicalDisplayId = activeIds.first(
      where: { !virtualDisplayIds.contains(Int($0)) }
    ) {
      preferredMainDisplayId = physicalDisplayId
    } else {
      preferredMainDisplayId = activeIds[0]
    }
    guard setMacMainDisplay(preferredMainDisplayId, displayIds: activeIds) else {
      return false
    }
    macDisplayConfigurationBackup = nil
    return true
  }

  private func restoreMacDisplayConfiguration(
    from backupOverride: [MacDisplayBackupItem]? = nil
  ) -> Bool {
    if backupOverride == nil {
      clearMacDisplayError()
    }
    guard let backup = backupOverride ?? macDisplayConfigurationBackup else {
      return restoreMacDefaultDisplayConfiguration()
    }
    let restorableBackup = backup.filter { item in
      isMacDisplayEnableCandidate(item.displayId)
    }
    guard !restorableBackup.isEmpty else {
      return restoreMacDefaultDisplayConfiguration()
    }

    let displayIds = restorableBackup.map { $0.displayId }
    let displayIdSet = Set(displayIds)
    let restoredMainDisplayId = restorableBackup.first { item in
      abs(item.origin.x) < 1 && abs(item.origin.y) < 1
    }?.displayId ?? restorableBackup.first?.displayId

    guard configureMacDisplayEnabled(allMacDisplayIds(), enabled: { id in
      displayIdSet.contains(id)
    }) else {
      return false
    }
    Thread.sleep(forTimeInterval: 0.3)

    for item in restorableBackup {
      if let mode = item.mode {
        _ = CGDisplaySetDisplayMode(item.displayId, mode, nil)
      }
    }

    var mirrorConfig: CGDisplayConfigRef?
    let beginError = CGBeginDisplayConfiguration(&mirrorConfig)
    guard beginError == .success, let mirrorConfig else {
      return setMacDisplayError(
        "CGBeginDisplayConfiguration(restore layout) failed: \(macCGErrorDescription(beginError))"
      )
    }
    for item in restorableBackup {
      let mirrorError = CGConfigureDisplayMirrorOfDisplay(
        mirrorConfig,
        item.displayId,
        item.mirrorTarget == 0 ? kCGNullDirectDisplay : item.mirrorTarget
      )
      guard mirrorError == .success else {
        CGCancelDisplayConfiguration(mirrorConfig)
        return setMacDisplayError(
          "CGConfigureDisplayMirrorOfDisplay(restore \(item.displayId)) failed: \(macCGErrorDescription(mirrorError))"
        )
      }
      let originError = CGConfigureDisplayOrigin(
        mirrorConfig,
        item.displayId,
        Int32(item.origin.x.rounded()),
        Int32(item.origin.y.rounded())
      )
      guard originError == .success else {
        CGCancelDisplayConfiguration(mirrorConfig)
        return setMacDisplayError(
          "CGConfigureDisplayOrigin(restore \(item.displayId)) failed: \(macCGErrorDescription(originError))"
        )
      }
    }
    guard completeMacDisplayConfiguration(mirrorConfig, reason: "restore layout") else {
      return false
    }

    if let restoredMainDisplayId,
      !waitForMacMainDisplay(restoredMainDisplayId, timeout: 1.5) {
      return setMacDisplayError(
        "Timed out waiting for restored main display \(restoredMainDisplayId)"
      )
    }

    if backupOverride == nil {
      macDisplayConfigurationBackup = nil
    }
    Thread.sleep(forTimeInterval: 0.5)
    return true
  }
#endif

  // Reverse mapping: Windows code to macOS code
  let windowsToMacKeyMap: [Int: Int] = [
      // 字母键 - 正确映射
      0x41: 0x00, // A
      0x53: 0x01, // S
      0x44: 0x02, // D
      0x46: 0x03, // F
      0x48: 0x04, // H
      0x47: 0x05, // G
      0x5A: 0x06, // Z
      0x58: 0x07, // X
      0x43: 0x08, // C
      0x56: 0x09, // V
      0x42: 0x0B, // B
      0x51: 0x0C, // Q
      0x57: 0x0D, // W
      0x45: 0x0E, // E
      0x52: 0x0F, // R
      0x59: 0x10, // Y
      0x54: 0x11, // T
      0x49: 0x22, // I
      0x55: 0x20, // U
      0x4F: 0x1F, // O
      0x50: 0x23, // P
      0x4C: 0x25, // L
      0x4A: 0x26, // J
      0x4B: 0x28, // K
      0x4E: 0x2D, // N
      0x4D: 0x2E, // M
      
      // 数字键 - 正确映射
      0x31: 0x12, // 1
      0x32: 0x13, // 2
      0x33: 0x14, // 3
      0x34: 0x15, // 4
      0x35: 0x17, // 5
      0x36: 0x16, // 6
      0x37: 0x1A, // 7
      0x38: 0x1C, // 8
      0x39: 0x19, // 9
      0x30: 0x1D, // 0
      
      // 符号键 - 正确映射
      0xBB: 0x18, // Equals (+)
      0xBD: 0x1B, // Minus (-)
      0xDD: 0x1E, // Right Bracket (])
      0xDB: 0x21, // Left Bracket ([)
      0xDE: 0x27, // Quote (')
      0xBA: 0x29, // Semicolon (;)
      0xDC: 0x2A, // Backslash (\)
      0xBC: 0x2B, // Comma (,)
      0xBF: 0x2C, // Slash (/)
      0xBE: 0x2F, // Period (.)
      0xC0: 0x32, // Back Quote (`)
      
      // 功能键 - 正确映射
      0x70: 0x7A, // F1
      0x71: 0x78, // F2
      0x72: 0x63, // F3
      0x73: 0x76, // F4
      0x74: 0x60, // F5
      0x75: 0x61, // F6
      0x76: 0x62, // F7
      0x77: 0x64, // F8
      0x78: 0x65, // F9
      0x79: 0x6D, // F10
      0x7A: 0x67, // F11
      0x7B: 0x6F, // F12
      0x7C: 0x69, // F13
      0x7D: 0x6B, // F14
      0x7E: 0x71, // F15
      0x7F: 0x6A, // F16
      0x80: 0x40, // F17
      0x81: 0x4F, // F18
      0x82: 0x50, // F19
      0x83: 0x5A, // F20
      
      // 控制键 - 正确映射
      0x08: 0x33, // Backspace
      0x09: 0x30, // Tab
      0x0D: 0x24, // Return/Enter
      0x1B: 0x35, // Escape
      0x10: 0x38, // Shift
      0x11: 0x3B, // Control
      0x12: 0x3A, // Alt/Option
      0x14: 0x39, // Caps Lock
      0x20: 0x31, // Space
      0x2E: 0x33, // Delete
      0x2D: 0x75, // Insert
      
      // 方向键 - 正确映射
      0x25: 0x7B, // Left Arrow
      0x26: 0x7E, // Up Arrow
      0x27: 0x7C, // Right Arrow
      0x28: 0x7D, // Down Arrow
      
      // 导航键 - 正确映射
      0x24: 0x73, // Home
      0x23: 0x77, // End
      0x21: 0x74, // Page Up
      0x22: 0x79, // Page Down
      
      // 数字键盘 - 正确映射
      0x60: 0x52, // Numpad 0
      0x61: 0x53, // Numpad 1
      0x62: 0x54, // Numpad 2
      0x63: 0x55, // Numpad 3
      0x64: 0x56, // Numpad 4
      0x65: 0x57, // Numpad 5
      0x66: 0x58, // Numpad 6
      0x67: 0x59, // Numpad 7
      0x68: 0x5B, // Numpad 8
      0x69: 0x5C, // Numpad 9
      0x6A: 0x43, // Numpad Multiply
      0x6B: 0x45, // Numpad Add
      0x6C: 0x41, // Numpad Separator
      0x6D: 0x4E, // Numpad Subtract
      0x6E: 0x2F, // Numpad Decimal
      0x6F: 0x4B, // Numpad Divide
      0x90: 0x47, // Num Lock
      
      // 特殊键 - 正确映射
      0x5B: 0x37, // Left Windows/Command
      0x5C: 0x36, // Right Windows/Command
      0x5D: 0x6E, // Apps/Context Menu
      0x5F: 0x7F, // Sleep
      
      // 音量控制 - 正确映射
      0xAD: 0x4A, // Volume Mute
      0xAE: 0x49, // Volume Down
      0xAF: 0x48, // Volume Up
      
      // 媒体控制 - 正确映射
      0xB0: 0x7F, // Media Next Track
      0xB1: 0x7F, // Media Previous Track
      0xB2: 0x7F, // Media Stop
      0xB3: 0x7F, // Media Play/Pause
      
      // 浏览器控制 - 正确映射
      0xA6: 0x7F, // Browser Back
      0xA7: 0x7F, // Browser Forward
      0xA8: 0x7F, // Browser Refresh
      0xA9: 0x7F, // Browser Stop
      0xAA: 0x7F, // Browser Search
      0xAB: 0x7F, // Browser Favorites
      0xAC: 0x7F, // Browser Home
      
      // 左右修饰键 - 正确映射
      0xA0: 0x38, // Left Shift
      0xA1: 0x3C, // Right Shift
      0xA2: 0x3B, // Left Control
      0xA3: 0x3E, // Right Control
      0xA4: 0x3A, // Left Alt
      0xA5: 0x3D, // Right Alt
      
      // 其他功能键
      0x2C: 0x7F, // Print Screen
      0x2A: 0x7F, // Print
      0x2B: 0x7F, // Execute
      0x29: 0x7F, // Select
      0x2F: 0x72, // Help
      0x13: 0x7F, // Pause
      0x91: 0x7F, // Scroll Lock
  ]

  private func postKeyboardEvent(
      macKeyCode: CGKeyCode,
      isDown: Bool,
      isRepeat: Bool
  ) {
      if macKeyCode == 0x39 {
          postCapsLockEvent(isDown: isDown)
          return
      }

      let inputSourceSnapshot = readMacOSInputSourceSnapshot()
      let flags = Self.keyboardFlagsForPressedKeyCodes(
        Array(activeKeyMacCodes.values),
        capsLockEnabled: remoteCapsLockEnabled &&
            inputSourceSnapshot.sourceClass == .keyboardLayout
      )
      // Create and post the keyboard event.
      //
      // Strip the Fn (secondaryFn) and NumericPad flags before posting.
      // Arrow / navigation keys (kVK 0x7B–0x7E) are macOS function + numpad
      // keys, so CGEvent auto-tags their events with Fn | NumericPad. Posting
      // such an event latches Fn into the shared session modifier state — and
      // because the key-up event carries Fn too, it is never released. Every
      // subsequent injected key needs the normal system event source so the
      // frontmost application's input method receives a real composition.
      // We still assemble flags solely from remote state below, which prevents
      // stray local Fn/NumPad state from leaking onto ordinary keys; the
      // virtual key code still drives arrows.
      let event = CGEvent(
        keyboardEventSource: remoteKeyboardEventSource,
        virtualKey: macKeyCode,
        keyDown: isDown
      )
      event?.flags = flags
      // Keep Shift/Control/Option/Command as ordinary keyDown/keyUp events.
      // Recasting them as flagsChanged can leave the combined session modifier
      // state latched after key-up (for example, after remote Ctrl+Tab).
      if isDown {
          event?.setIntegerValueField(
            .keyboardEventAutorepeat,
            value: isRepeat ? 1 : 0
          )
      }
      event?.post(tap: .cghidEventTap)
  }

  static func keyboardFlagsForPressedKeyCodes(
      _ pressedKeyCodes: [CGKeyCode],
      capsLockEnabled: Bool = false
  ) -> CGEventFlags {
      var flags: CGEventFlags = []
      // Modifier state for injected input must come from our own pressed-key
      // table. Inheriting the host's physical modifiers makes a remote chord
      // nondeterministic, while omitting these flags makes Command+A arrive as
      // a plain A on macOS.
      if capsLockEnabled {
          flags.insert(.maskAlphaShift)
      }
      for keyCode in pressedKeyCodes {
          switch keyCode {
          case 0x38, 0x3C:
              flags.insert(.maskShift)
          case 0x3B, 0x3E:
              flags.insert(.maskControl)
          case 0x3A, 0x3D:
              flags.insert(.maskAlternate)
          case 0x36, 0x37:
              flags.insert(.maskCommand)
          default:
              break
          }
      }
      return flags
  }

  static func capsLockFlagsForKeyEvent(
      currentFlags: CGEventFlags,
      isDown: Bool,
      capsLockEnabled: Bool? = nil
  ) -> CGEventFlags? {
      // Caps Lock is a status key on macOS. Its release does not create a
      // second state change; the next press flips AlphaShift back instead.
      guard isDown else {
          return nil
      }

      var flags = currentFlags
      flags.remove([.maskSecondaryFn, .maskNumericPad])
      let nextCapsLockEnabled = capsLockEnabled ?? !flags.contains(.maskAlphaShift)
      if nextCapsLockEnabled {
          flags.insert(.maskAlphaShift)
      } else {
          flags.remove(.maskAlphaShift)
      }
      return flags
  }

  private func postCapsLockEvent(isDown: Bool) {
      if isDown {
          remoteCapsLockEnabled.toggle()
      }
      guard let flags = Self.capsLockFlagsForKeyEvent(
        currentFlags: [],
        isDown: isDown,
        capsLockEnabled: remoteCapsLockEnabled
      ) else {
          return
      }
      let capsLockEnabled = flags.contains(.maskAlphaShift)
      guard let event = CGEvent(
        keyboardEventSource: remoteKeyboardEventSource,
        virtualKey: 0x39,
        keyDown: capsLockEnabled
      ) else {
          return
      }
      event.type = .flagsChanged
      event.flags = flags
      event.post(tap: .cghidEventTap)
  }

  private func systemKeyboardRepeatDelay() -> DispatchTimeInterval {
      let ticks = systemKeyboardRepeatTicks(
        key: "InitialKeyRepeat",
        defaultTicks: 34,
        minTicks: 10,
        maxTicks: 120
      )
      return .milliseconds(ticks * 15)
  }

  private func systemKeyboardRepeatInterval() -> DispatchTimeInterval {
      let ticks = systemKeyboardRepeatTicks(
        key: "KeyRepeat",
        defaultTicks: 3,
        minTicks: 1,
        maxTicks: 20
      )
      return .milliseconds(ticks * 15)
  }

  private func systemKeyboardRepeatTicks(
      key: String,
      defaultTicks: Int,
      minTicks: Int,
      maxTicks: Int
  ) -> Int {
      guard let value = UserDefaults.standard.object(forKey: key) as? NSNumber
      else {
          return defaultTicks
      }
      return min(max(value.intValue, minTicks), maxTicks)
  }

  private func shouldAutoRepeat(windowsKeyCode: Int) -> Bool {
      switch windowsKeyCode {
      case 0x10, 0x11, 0x12, // Generic Shift / Ctrl / Alt
           0x13,             // Pause
           0x14,             // Caps Lock
           0x29, 0x2A, 0x2B, 0x2C, // Select / Print / Execute / Print Screen
           0x5B, 0x5C, 0x5D, // Command / Context Menu
           0x90, 0x91,       // Num Lock / Scroll Lock
           0xA0...0xA5,      // Left/right Shift / Ctrl / Alt
           0xA6...0xAF,      // Browser + volume keys
           0xB0...0xB3:      // Media keys
          return false
      default:
          return true
      }
  }

  private func startAutoRepeatIfNeeded(
      windowsKeyCode: Int,
      macKeyCode: CGKeyCode
  ) {
      stopActiveAutoRepeat()
      guard shouldAutoRepeat(windowsKeyCode: windowsKeyCode) else {
          return
      }
      let timer = DispatchSource.makeTimerSource(queue: keyboardRepeatQueue)
      timer.schedule(
        deadline: .now() + systemKeyboardRepeatDelay(),
        repeating: systemKeyboardRepeatInterval(),
        leeway: .milliseconds(3)
      )
      timer.setEventHandler { [weak self] in
          guard let self = self else {
              return
          }
          guard self.activeKeyMacCodes[windowsKeyCode] == macKeyCode else {
              return
          }
          self.postKeyboardEvent(
            macKeyCode: macKeyCode,
            isDown: true,
            isRepeat: true
          )
      }
      activeRepeatingWindowsKeyCode = windowsKeyCode
      activeKeyRepeatTimer = timer
      timer.resume()
  }

  private func stopActiveAutoRepeat() {
      activeKeyRepeatTimer?.cancel()
      activeKeyRepeatTimer = nil
      activeRepeatingWindowsKeyCode = nil
  }

  private func stopAutoRepeatIfNeeded(windowsKeyCode: Int) {
      guard activeRepeatingWindowsKeyCode == windowsKeyCode else {
          return
      }
      stopActiveAutoRepeat()
  }

  private func handleKeyDown(windowsKeyCode: Int, macKeyCode: CGKeyCode) {
      if activeKeyMacCodes[windowsKeyCode] != nil {
          return
      }
      activeKeyMacCodes[windowsKeyCode] = macKeyCode
      postKeyboardEvent(macKeyCode: macKeyCode, isDown: true, isRepeat: false)
      startAutoRepeatIfNeeded(
        windowsKeyCode: windowsKeyCode,
        macKeyCode: macKeyCode
      )
  }

  private func handleKeyUp(windowsKeyCode: Int, macKeyCode: CGKeyCode) {
      activeKeyMacCodes.removeValue(forKey: windowsKeyCode)
      stopAutoRepeatIfNeeded(windowsKeyCode: windowsKeyCode)
      postKeyboardEvent(macKeyCode: macKeyCode, isDown: false, isRepeat: false)
  }

  private func clearAllPressedEventsOnKeyboardQueue() {
      let pressedKeyCodes = Array(activeKeyMacCodes.values)
      activeKeyMacCodes.removeAll()
      stopActiveAutoRepeat()
      for macKeyCode in pressedKeyCodes {
          postKeyboardEvent(macKeyCode: macKeyCode, isDown: false, isRepeat: false)
      }
  }

  // Function to perform key event based on Windows key code
  func PerformKeyEvent(code: Int, isDown: Bool) {
      // Reverse mapping from Windows key code to macOS key code
      guard let rawMacKeyCode = windowsToMacKeyMap[code] else {
          print("Key code \(code) not found in mapping.")
          return
      }
      let macKeyCode = CGKeyCode(rawMacKeyCode)
      keyboardRepeatQueue.async { [weak self] in
          guard let self = self else {
              return
          }
          if isDown {
              self.handleKeyDown(windowsKeyCode: code, macKeyCode: macKeyCode)
          } else {
              self.handleKeyUp(windowsKeyCode: code, macKeyCode: macKeyCode)
          }
      }
  }

  private func mouseButton(for buttonId: Int) -> CGMouseButton? {
      switch buttonId {
      case 1:
          return .left
      case 2:
          return .center
      case 3:
          return .right
      default:
          return nil
      }
  }

  private func mouseButtonEventType(buttonId: Int, isDown: Bool) -> CGEventType? {
      switch buttonId {
      case 1:
          return isDown ? .leftMouseDown : .leftMouseUp
      case 2:
          return isDown ? .otherMouseDown : .otherMouseUp
      case 3:
          return isDown ? .rightMouseDown : .rightMouseUp
      default:
          return nil
      }
  }

  private func injectedMouseMoveEvent() -> (type: CGEventType, button: CGMouseButton) {
      if injectedMouseButtonIds.contains(1) {
          return (.leftMouseDragged, .left)
      }
      if injectedMouseButtonIds.contains(2) {
          return (.otherMouseDragged, .center)
      }
      if injectedMouseButtonIds.contains(3) {
          return (.rightMouseDragged, .right)
      }
      return (.mouseMoved, .left)
  }

  private func updateInjectedMouseButtonState(buttonId: Int, isDown: Bool) {
      if isDown {
          injectedMouseButtonIds.insert(buttonId)
      } else {
          injectedMouseButtonIds.remove(buttonId)
      }
  }

  private func currentMouseLocation() -> CGPoint? {
      return CGEvent(source: mouseEventSource)?.location ?? CGEvent(source: nil)?.location
  }

  private func startDisplayBoundsCache() {
      refreshDisplayBoundsCache()
      displayBoundsCacheObserver = NotificationCenter.default.addObserver(
          forName: NSApplication.didChangeScreenParametersNotification,
          object: nil,
          queue: .main
      ) { [weak self] _ in
          self?.refreshDisplayBoundsCache()
      }
  }

  private func refreshDisplayBoundsCache() {
      let displayIds: [CGDirectDisplayID]
#if CLOUDPLAYPLUS_DMG_DISTRIBUTION
      displayIds = enabledMacDisplayIds()
#else
      displayIds = onlineMacDisplayIds()
#endif
      var updated: [Int: CGRect] = [:]
      var mirrorTargets: [Int: Int] = [:]
      for displayId in displayIds {
          let bounds = CGDisplayBounds(displayId)
          guard !bounds.isNull && !bounds.isEmpty else {
              continue
          }
          let nativeDisplayId = Int(displayId)
          updated[nativeDisplayId] = bounds
          mirrorTargets[nativeDisplayId] = Int(CGDisplayMirrorsDisplay(displayId))
      }
      let cursorOrder = MacDisplayCoordinateMapper.cursorDisplayOrder(
          displayIds: Array(updated.keys),
          mirrorTargetByDisplayId: mirrorTargets,
          mainDisplayId: Int(CGMainDisplayID())
      )
      displayBoundsCacheLock.lock()
      displayBoundsCache = updated
      cursorDisplayOrderCache = cursorOrder
      displayBoundsCacheLock.unlock()
  }

  private func displayTopologySnapshot() -> (bounds: [Int: CGRect], cursorOrder: [Int]) {
      displayBoundsCacheLock.lock()
      defer { displayBoundsCacheLock.unlock() }
      return (displayBoundsCache, cursorDisplayOrderCache)
  }

  private func onlineMacDisplayIds(limit: Int = 32) -> [CGDirectDisplayID] {
      var displayIds = Array<CGDirectDisplayID>(repeating: 0, count: limit)
      var displayCount: UInt32 = 0
      let error = CGGetOnlineDisplayList(
          UInt32(displayIds.count),
          &displayIds,
          &displayCount
      )
      guard error == .success else {
          return []
      }
      return Array(displayIds.prefix(min(Int(displayCount), displayIds.count)))
  }

  private func basicMacDisplayList() -> [[String: Any]] {
      let mainDisplayId = CGMainDisplayID()
      return NSScreen.screens.enumerated().compactMap { index, screen in
          guard let displayId = displayId(for: screen) else {
              return nil
          }
          let bounds = CGDisplayBounds(displayId)
          let refreshRate = CGDisplayCopyDisplayMode(displayId)?.refreshRate ?? 0
          let displayName: String
          if #available(macOS 10.15, *) {
              displayName = screen.localizedName
          } else {
              displayName = "Display \(displayId)"
          }
          return [
              "index": index,
              "width": CGDisplayPixelsWide(displayId),
              "height": CGDisplayPixelsHigh(displayId),
              "refreshRate": refreshRate.isFinite && refreshRate > 0
                  ? Int(refreshRate.rounded())
                  : 60,
              "isVirtual": false,
              "displayName": displayName,
              "deviceName": "\(displayId)",
              "active": CGDisplayIsActive(displayId) != 0,
              "displayUid": Int(displayId),
              "rawScreenId": Int(displayId),
              "orientation": 0,
              "left": Int(bounds.minX.rounded()),
              "top": Int(bounds.minY.rounded()),
              "right": Int(bounds.maxX.rounded()),
              "bottom": Int(bounds.maxY.rounded()),
              "isPrimary": displayId == mainDisplayId,
          ]
      }
  }

  private func displayId(for screen: NSScreen) -> CGDirectDisplayID? {
      guard let number = screen.deviceDescription[
          NSDeviceDescriptionKey("NSScreenNumber")
      ] as? NSNumber else {
          return nil
      }
      return CGDirectDisplayID(number.uint32Value)
  }

  private func displayBounds(nativeDisplayId: Int) -> CGRect? {
      displayBoundsCacheLock.lock()
      defer { displayBoundsCacheLock.unlock() }
      return displayBoundsCache[nativeDisplayId]
  }

  private func clampMouseLocation(
      _ location: CGPoint,
      screenId: Int? = nil,
      screenBounds: CGRect? = nil
  ) -> CGPoint {
      let bounds: CGRect?
      if let screenBounds {
          bounds = screenBounds
      } else if let id = screenId ?? currentDisplayId {
          bounds = displayBounds(nativeDisplayId: id)
      } else {
          bounds = nil
      }
      guard let bounds else {
          return location
      }
      return MacDisplayCoordinateMapper.clamp(location, to: bounds) ?? location
  }

  private func postMouse(
      button: CGMouseButton,
      type: CGEventType,
      location rawLocation: CGPoint,
      previousLocation: CGPoint,
      clickCount: Int64,
      screenId: Int? = nil,
      screenBounds: CGRect? = nil
  ) {
      let location = clampMouseLocation(
          rawLocation,
          screenId: screenId,
          screenBounds: screenBounds
      )
      let event = CGEvent(
          mouseEventSource: mouseEventSource,
          mouseType: type,
          mouseCursorPosition: location,
          mouseButton: button
      )

      event?.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button.rawValue))
      event?.setIntegerValueField(.mouseEventClickState, value: clickCount)
      event?.setDoubleValueField(.mouseEventDeltaX, value: Double(rawLocation.x - previousLocation.x))
      event?.setDoubleValueField(.mouseEventDeltaY, value: Double(rawLocation.y - previousLocation.y))
      event?.post(tap: .cghidEventTap)

      // Mirrors Sunshine: some macOS apps only observe the cursor position
      // correctly when the hardware cursor is warped after a synthetic event.
      CGWarpMouseCursorPosition(location)
  }

  func performMouseMoveAbsl(x: Double, y: Double, screenId: Int) {
      guard let bounds = displayBounds(nativeDisplayId: screenId) else {
          return
      }
      currentDisplayId = screenId

      guard let location = MacDisplayCoordinateMapper.absolutePoint(
          xPercent: x,
          yPercent: y,
          bounds: bounds
      ) else {
          return
      }

      let injectedMove = injectedMouseMoveEvent()
      let previousLocation = currentMouseLocation() ?? location
      postMouse(
          button: injectedMove.button,
          type: injectedMove.type,
          location: location,
          previousLocation: previousLocation,
          clickCount: 0,
          screenId: screenId,
          screenBounds: bounds
      )
#if CLOUDPLAYPLUS_DMG_DISTRIBUTION
      updateCursorVisibilityAfterInjectedMouseMove()
#endif
  }

  func performMouseMoveRelative(dx: Double, dy: Double, screenId: Int) {
      guard let bounds = displayBounds(nativeDisplayId: screenId) else {
          return
      }
      currentDisplayId = screenId

      if let currentMouseLocation = currentMouseLocation() {
          // Calculate new position based on dx and dy
          let newX = currentMouseLocation.x + CGFloat(dx)
          let newY = currentMouseLocation.y + CGFloat(dy)
          let injectedMove = injectedMouseMoveEvent()
          postMouse(
              button: injectedMove.button,
              type: injectedMove.type,
              location: CGPoint(x: newX, y: newY),
              previousLocation: currentMouseLocation,
              clickCount: 0,
              screenId: screenId,
              screenBounds: bounds
          )
#if CLOUDPLAYPLUS_DMG_DISTRIBUTION
          updateCursorVisibilityAfterInjectedMouseMove()
#endif
      }
  }

  func performMouseButton(buttonId: Int, isDown: Bool) {
      guard let mouseButton = mouseButton(for: buttonId),
            let mouseEventType = mouseButtonEventType(buttonId: buttonId, isDown: isDown) else {
          print("Unsupported buttonId")
          return
      }
      
      // 获取当前鼠标位置
      if let currentLocation = currentMouseLocation() {
          let clickCount = mouseClickCount(buttonId: buttonId, isDown: isDown, location: currentLocation)
          updateInjectedMouseButtonState(buttonId: buttonId, isDown: isDown)
          postMouse(
              button: mouseButton,
              type: mouseEventType,
              location: currentLocation,
              previousLocation: currentLocation,
              clickCount: clickCount
          )
          updateMouseClickStateAfterPost(buttonId: buttonId, isDown: isDown, location: currentLocation, clickCount: clickCount)
      } else {
          if !isDown {
              updateInjectedMouseButtonState(buttonId: buttonId, isDown: false)
          }
          print("Failed to get current mouse location")
      }
  }

  private func mouseClickCount(buttonId: Int, isDown: Bool, location: CGPoint) -> Int64 {
      if !isDown {
          if activeMouseButtonId == buttonId {
              return activeMouseClickCount
          }
          return 1
      }

      let now = Date().timeIntervalSince1970
      let interval = NSEvent.doubleClickInterval
      let sameButton = lastMouseClickButtonId == buttonId
      let closeEnough = lastMouseClickLocation.map {
          hypot(location.x - $0.x, location.y - $0.y) <= maxDoubleClickDistance
      } ?? false
      let withinInterval = now - lastMouseClickTime <= interval

      let nextClickCount: Int64
      if sameButton && closeEnough && withinInterval {
          nextClickCount = min(lastMouseClickCount + 1, 3)
      } else {
          nextClickCount = 1
      }
      activeMouseButtonId = buttonId
      activeMouseClickCount = nextClickCount
      return nextClickCount
  }

  private func updateMouseClickStateAfterPost(buttonId: Int, isDown: Bool, location: CGPoint, clickCount: Int64) {
      guard !isDown else { return }
      lastMouseClickButtonId = buttonId
      lastMouseClickTime = Date().timeIntervalSince1970
      lastMouseClickLocation = location
      lastMouseClickCount = clickCount
      if activeMouseButtonId == buttonId {
          activeMouseButtonId = nil
          activeMouseClickCount = 1
      }
  }

  private func nativeWheelDelta(_ logicalDelta: Double) -> Int32? {
      guard logicalDelta.isFinite else { return nil }
      let rounded = (-logicalDelta).rounded()
      let clamped = min(
          max(rounded, Double(Int32.min)),
          Double(Int32.max)
      )
      return Int32(clamped)
  }

  func performMouseScroll(dx: Double, dy: Double) {
      let eventSource = CGEventSource(stateID: .hidSystemState)

      guard
          let verticalWheel = nativeWheelDelta(dy),
          let horizontalWheel = nativeWheelDelta(dx)
      else {
          return
      }

      if horizontalWheel != 0 || verticalWheel != 0 {
          let wheelCount: UInt32 = horizontalWheel != 0 ? 2 : 1
          // RD_MOUSE_SCROLL uses logical page direction (+x right, +y down).
          // CoreGraphics wheel1/wheel2 use physical direction (+up/+left).
          if let scrollEvent = CGEvent(scrollWheelEvent2Source: eventSource, units: .pixel, wheelCount: wheelCount, wheel1: verticalWheel, wheel2: horizontalWheel, wheel3: 0) {
              scrollEvent.post(tap: .cghidEventTap)
          }
      }
  }

  static func nativeTrackpadPointDelta(_ logicalDelta: Double) -> Int32? {
      guard logicalDelta.isFinite else { return nil }
      if logicalDelta == 0 { return 0 }

      // CoreGraphics wheel/point axes use the opposite sign from our logical
      // page direction. Preserve their 1:1 magnitude for whole pixels; only
      // clamp a non-zero subpixel delta to the smallest representable integer.
      var rounded = (-logicalDelta).rounded()
      if rounded == 0 {
          rounded = logicalDelta.isLess(than: 0) ? 1 : -1
      }
      let clamped = min(
          max(rounded, Double(Int32.min)),
          Double(Int32.max)
      )
      return Int32(clamped)
  }

  private func nativeTrackpadScrollPhase(_ phase: String) -> Int64 {
      switch phase {
      case "mayBegin":
          return Int64(CGScrollPhase.mayBegin.rawValue)
      case "began":
          return Int64(CGScrollPhase.began.rawValue)
      case "changed", "stationary":
          return Int64(CGScrollPhase.changed.rawValue)
      case "ended":
          return Int64(CGScrollPhase.ended.rawValue)
      case "cancelled":
          return Int64(CGScrollPhase.cancelled.rawValue)
      default:
          return 0
      }
  }

  private func nativeTrackpadMomentumPhase(_ phase: String) -> Int64 {
      switch phase {
      case "mayBegin", "began":
          return Int64(CGMomentumScrollPhase.begin.rawValue)
      case "changed", "stationary":
          return Int64(CGMomentumScrollPhase.continuous.rawValue)
      case "ended", "cancelled":
          return Int64(CGMomentumScrollPhase.end.rawValue)
      default:
          return Int64(CGMomentumScrollPhase.none.rawValue)
      }
  }

  func performTrackpadScroll(
      dx: Double,
      dy: Double,
      phase: String,
      isMomentum: Bool
  ) {
      guard
          let horizontalPoint = Self.nativeTrackpadPointDelta(dx),
          let verticalPoint = Self.nativeTrackpadPointDelta(dy)
      else {
          return
      }

      let eventSource = CGEventSource(stateID: .hidSystemState)
      let wheelCount: UInt32 = horizontalPoint != 0 ? 2 : 1
      guard let scrollEvent = CGEvent(
          scrollWheelEvent2Source: eventSource,
          units: .pixel,
          wheelCount: wheelCount,
          wheel1: verticalPoint,
          wheel2: horizontalPoint,
          wheel3: 0
      ) else {
          return
      }

      // RD trackpad deltas use logical page direction. CoreGraphics fields use
      // the opposite gesture/device direction. Fixed-point preserves the exact
      // fraction; point/wheel fields provide the closest non-zero integer.
      scrollEvent.setDoubleValueField(
          .scrollWheelEventFixedPtDeltaAxis1,
          value: -dy
      )
      scrollEvent.setDoubleValueField(
          .scrollWheelEventFixedPtDeltaAxis2,
          value: -dx
      )
      scrollEvent.setIntegerValueField(
          .scrollWheelEventPointDeltaAxis1,
          value: Int64(verticalPoint)
      )
      scrollEvent.setIntegerValueField(
          .scrollWheelEventPointDeltaAxis2,
          value: Int64(horizontalPoint)
      )
      scrollEvent.setIntegerValueField(
          .scrollWheelEventIsContinuous,
          value: 1
      )
      scrollEvent.setIntegerValueField(
          .scrollWheelEventScrollPhase,
          value: isMomentum ? 0 : nativeTrackpadScrollPhase(phase)
      )
      scrollEvent.setIntegerValueField(
          .scrollWheelEventMomentumPhase,
          value: isMomentum ? nativeTrackpadMomentumPhase(phase) : 0
      )
      scrollEvent.post(tap: .cghidEventTap)
  }

  func performMouseMoveToWindowPosition(percentx: Double, percenty: Double) {
      // Get the current Flutter app's main window
      guard let mainWindow = NSApplication.shared.mainWindow ?? NSApplication.shared.windows.first else {
          print("Failed to get Flutter main window")
          return
      }
      
      // Get the window's content area (excluding title bar and decorations)
      let contentRect = mainWindow.contentView?.bounds ?? mainWindow.frame
      let windowFrame = mainWindow.frame
      
      // Calculate the content area position on screen
      // Convert from window coordinates to screen coordinates
      let contentOriginInWindow = mainWindow.contentView?.frame.origin ?? CGPoint.zero
      let contentOriginInScreen = CGPoint(
          x: windowFrame.origin.x + contentOriginInWindow.x,
          y: windowFrame.origin.y + contentOriginInWindow.y
      )
      
      // Calculate target position based on percentages within the content area
      let targetX = contentOriginInScreen.x + (percentx * contentRect.width)
      
      // For Y coordinate: NSWindow uses bottom-left origin, but percentages should work top-to-bottom
      // So percenty=0 should be top of content area, percenty=1 should be bottom
      // We need to convert from window coordinates (bottom-left origin) to screen coordinates (top-left origin)
      let screenHeight = NSScreen.main?.frame.height ?? 0
      let windowBottomInScreen = screenHeight - windowFrame.origin.y
      let contentTopInScreen = windowBottomInScreen - contentRect.height
      let targetY = contentTopInScreen + (percenty * contentRect.height)
      
      // Get current mouse button state to maintain drag behavior
      var eventType: CGEventType = .mouseMoved
      let pressedButtons = NSEvent.pressedMouseButtons
      if pressedButtons & (1 << 0) != 0 {
          eventType = .leftMouseDragged
      } else if pressedButtons & (1 << 1) != 0 {
          eventType = .rightMouseDragged
      }
      
      // Create and post the mouse move event
      let moveEvent = CGEvent(mouseEventSource: nil, 
                             mouseType: eventType, 
                             mouseCursorPosition: CGPoint(x: targetX, y: targetY), 
                             mouseButton: .left)
      moveEvent?.post(tap: .cghidEventTap)
#if CLOUDPLAYPLUS_DMG_DISTRIBUTION
      updateCursorVisibilityAfterInjectedMouseMove()
#endif
  }

  private func cursorLocationInQuartzCoordinates(
      windowXPercent: Double,
      windowYPercent: Double
  ) -> CGPoint? {
      guard let mainWindow = NSApplication.shared.mainWindow ??
              NSApplication.shared.windows.first,
            let contentView = mainWindow.contentView,
            let mainScreen = NSScreen.screens.first else {
          return nil
      }

      let bounds = contentView.bounds
      let localPoint = CGPoint(
          x: bounds.minX + min(max(windowXPercent, 0.0), 1.0) * bounds.width,
          y: bounds.maxY - min(max(windowYPercent, 0.0), 1.0) * bounds.height
      )
      let windowPoint = contentView.convert(localPoint, to: nil)
      let appKitScreenPoint = mainWindow.convertPoint(toScreen: windowPoint)

      // AppKit's global Y axis points up from the main display's bottom-left;
      // Quartz cursor coordinates point down from its top-left.
      return CGPoint(
          x: appKitScreenPoint.x,
          y: mainScreen.frame.maxY - appKitScreenPoint.y
      )
  }

  var monitor: Any?
    
  // 监听鼠标移动并解耦鼠标和光标
  func startTrackingMouse() {
      monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged]) { event -> NSEvent? in
          self.handleMouseMove(event)
          return event
      }
  }
  
  // 停止监听
  func stopTrackingMouse() {
      if let monitor = monitor {
          NSEvent.removeMonitor(monitor)
      }
  }
  
  // 处理鼠标移动事件
  private func handleMouseMove(_ event: NSEvent) {
      let deltaX = event.deltaX
      let deltaY = event.deltaY
      
      methodChannel?.invokeMethod("onCursorMoved", arguments: [
          "dx": deltaX,
          "dy": deltaY,
      ])
  }

  var mouseMovedMonitor: Any?
  var cursorPositionMonitor: Any?
#if CLOUDPLAYPLUS_DMG_DISTRIBUTION
  var cursorVisibilityTimer: DispatchSourceTimer?
  var lastCursorVisible: Bool?
  var lastWindowServerCursorVisible: Bool?
  var previousCursorVisibilityImageHash: String?
  // 远程注入移动后 WindowServer getter 可能一直停留在 false；新的非透明纹理
  // 证明系统已经重新绘制光标，不能被同一个滞留值立即覆盖。
  var cursorTextureProvesVisible = false
#endif
  struct CursorImageSignature: Hashable {
    let imageHash: String
    let pixelWidth: UInt32
    let pixelHeight: UInt32
    let hotSpotX: UInt32
    let hotSpotY: UInt32
    let systemCursorId: Int?
    let sourceDevicePixelRatioBits: UInt32
  }

  static func cursorImageSignature(
    image: NSImage,
    imageHash: String,
    hotSpot: NSPoint,
    systemCursorId: Int?
  ) -> CursorImageSignature {
    let bitmapRep = image.representations.first(where: {
      $0 is NSBitmapImageRep
    }) as? NSBitmapImageRep
    let pixelWidth = bitmapRep?.pixelsWide ?? 0
    let pixelHeight = bitmapRep?.pixelsHigh ?? 0
    let pointSize = image.size.width > 0 && image.size.height > 0
      ? image.size
      : bitmapRep?.size ?? .zero
    let hotSpotPixels = cursorHotSpotInPixels(
      hotSpot,
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      pointSize: pointSize
    )
    let sourceDevicePixelRatio = cursorDevicePixelRatio(
      pixelWidth: pixelWidth,
      pixelHeight: pixelHeight,
      pointSize: pointSize
    )

    return CursorImageSignature(
      imageHash: imageHash,
      pixelWidth: UInt32(clamping: pixelWidth),
      pixelHeight: UInt32(clamping: pixelHeight),
      hotSpotX: hotSpotPixels.x,
      hotSpotY: hotSpotPixels.y,
      systemCursorId: systemCursorId,
      sourceDevicePixelRatioBits: sourceDevicePixelRatio.bitPattern
    )
  }

  static func cursorBitmapChangedForVisibility(
    previousImageHash: String?,
    currentImageHash: String
  ) -> Bool {
    previousImageHash != currentImageHash
  }

  var previousCursorImageSignature: CursorImageSignature?
  var cursorChangedCallbacks = Set<Int>()
  var cursorPositionCallbacks = Set<Int>()
  var cursorHashByImageSignature = Dictionary<CursorImageSignature, UInt32>()
  var cursorHashesByCallback = Dictionary<Int, Set<UInt32>>()
  var hookAllCursorImage = Dictionary<Int, Bool>()
  let cursorMonitorMask: NSEvent.EventTypeMask = [
    .mouseMoved,
    .leftMouseDragged,
    .rightMouseDragged,
    .otherMouseDragged,
    .leftMouseDown,
    .leftMouseUp,
    .rightMouseDown,
    .rightMouseUp,
    .otherMouseDown,
    .otherMouseUp,
  ]
  static let cursorTransitionProbeDelaysMs = [16, 50]

  static func shouldScheduleCursorTransitionProbes(
    isDmgDistribution: Bool,
    cursorSeedProducerActive: Bool
  ) -> Bool {
    !isDmgDistribution || !cursorSeedProducerActive
  }

  private var cursorTransitionProbesEnabled: Bool {
#if CLOUDPLAYPLUS_DMG_DISTRIBUTION
    let isDmgDistribution = true
#else
    let isDmgDistribution = false
#endif
    return Self.shouldScheduleCursorTransitionProbes(
      isDmgDistribution: isDmgDistribution,
      cursorSeedProducerActive: cursorSeedProducerActive
    )
  }
#if CLOUDPLAYPLUS_DMG_DISTRIBUTION
  static let cursorVisibilityPollIntervalMs = 200

  private typealias CGCursorIsVisibleFunction = @convention(c) () -> Int32
  private var cgCursorIsVisibleFunction: CGCursorIsVisibleFunction?
  private var cgCursorIsVisibleLookupAttempted = false
  private var cursorVisibilityProcessHandle: UnsafeMutableRawPointer?

  private typealias SLCursorIsVisibleFunction = @convention(c) () -> Int32
  private var slCursorIsVisibleFunction: SLCursorIsVisibleFunction?
  private var slCursorIsVisibleLookupAttempted = false
#endif

  func JSHash(buffer: [UInt8], size: Int) -> UInt32 {
    var hash: UInt32 = 1315423911
    for i in 0..<size {
        hash ^= ((hash << 5) &+ UInt32(buffer[i]) &+ (hash >> 2))
    }
    return hash & 0x7FFFFFFF
  }

  static func cursorHotSpotInPixels(
    _ hotSpot: NSPoint,
    pixelWidth: Int,
    pixelHeight: Int,
    pointSize: NSSize
  ) -> (x: UInt32, y: UInt32) {
    let scaleX = pointSize.width > 0
      ? CGFloat(pixelWidth) / pointSize.width
      : 1
    let scaleY = pointSize.height > 0
      ? CGFloat(pixelHeight) / pointSize.height
      : 1

    return (
      x: cursorCoordinate(hotSpot.x * scaleX),
      y: cursorCoordinate(hotSpot.y * scaleY)
    )
  }

  static func cursorDevicePixelRatio(
    pixelWidth: Int,
    pixelHeight: Int,
    pointSize: NSSize
  ) -> Float32 {
    let scaleX = pointSize.width > 0
      ? CGFloat(pixelWidth) / pointSize.width
      : 1
    let scaleY = pointSize.height > 0
      ? CGFloat(pixelHeight) / pointSize.height
      : 1
    let average = (scaleX + scaleY) / 2
    guard average.isFinite, average > 0 else { return 1 }
    return Float32(min(max(average, 0.25), 8))
  }

  private static func cursorCoordinate(_ value: CGFloat) -> UInt32 {
    guard value.isFinite, value > 0 else { return 0 }
    return UInt32(min(value.rounded(), CGFloat(UInt32.max)))
  }

  private func appendUInt32BE(_ value: UInt32, to bytes: inout [UInt8]) {
    bytes.append(UInt8((value >> 24) & 0xFF))
    bytes.append(UInt8((value >> 16) & 0xFF))
    bytes.append(UInt8((value >> 8) & 0xFF))
    bytes.append(UInt8(value & 0xFF))
  }

  private func appendUInt32LE(_ value: UInt32, to bytes: inout [UInt8]) {
    bytes.append(UInt8(value & 0xFF))
    bytes.append(UInt8((value >> 8) & 0xFF))
    bytes.append(UInt8((value >> 16) & 0xFF))
    bytes.append(UInt8((value >> 24) & 0xFF))
  }

  func encodeCursorBitmap(
    image: NSImage,
    hotSpot: NSPoint,
    systemCursorId: UInt32 = 0
  ) -> (hash: UInt32, payload: Data)? {
    guard let bitmapRep = image.representations.first(where: {
      $0 is NSBitmapImageRep
    }) as? NSBitmapImageRep,
      let pixels = getBitMapInt8(bitmapRep: bitmapRep) else {
      return nil
    }

    // NSCursor.hotSpot is expressed in the NSImage coordinate space. Prefer
    // the image's logical point size because a raw bitmap rep may report its
    // pixel dimensions as its size, then fall back to the rep if necessary.
    let pointSize = image.size.width > 0 && image.size.height > 0
      ? image.size
      : bitmapRep.size
    let hotSpotPixels = Self.cursorHotSpotInPixels(
      hotSpot,
      pixelWidth: bitmapRep.pixelsWide,
      pixelHeight: bitmapRep.pixelsHigh,
      pointSize: pointSize
    )
    let sourceDevicePixelRatio = Self.cursorDevicePixelRatio(
      pixelWidth: bitmapRep.pixelsWide,
      pixelHeight: bitmapRep.pixelsHigh,
      pointSize: pointSize
    )

    var hashInput: [UInt8] = []
    appendUInt32BE(UInt32(clamping: bitmapRep.pixelsWide), to: &hashInput)
    appendUInt32BE(UInt32(clamping: bitmapRep.pixelsHigh), to: &hashInput)
    appendUInt32BE(hotSpotPixels.x, to: &hashInput)
    appendUInt32BE(hotSpotPixels.y, to: &hashInput)
    appendUInt32LE(systemCursorId, to: &hashInput)
    appendUInt32LE(sourceDevicePixelRatio.bitPattern, to: &hashInput)
    hashInput.append(contentsOf: pixels)
    let messageHash = JSHash(buffer: hashInput, size: hashInput.count)

    var bytes: [UInt8] = [9]
    appendUInt32BE(UInt32(clamping: bitmapRep.pixelsWide), to: &bytes)
    appendUInt32BE(UInt32(clamping: bitmapRep.pixelsHigh), to: &bytes)
    appendUInt32BE(hotSpotPixels.x, to: &bytes)
    appendUInt32BE(hotSpotPixels.y, to: &bytes)
    appendUInt32BE(messageHash, to: &bytes)
    appendUInt32LE(systemCursorId, to: &bytes)
    appendUInt32LE(sourceDevicePixelRatio.bitPattern, to: &bytes)
    bytes.append(contentsOf: pixels)
    return (messageHash, Data(bytes))
  }

  static func cursorImageIsFullyTransparent(_ image: NSImage) -> Bool? {
    var inspectedRepresentation = false
    for case let bitmapRep as NSBitmapImageRep in image.representations {
      guard bitmapRep.pixelsWide > 0, bitmapRep.pixelsHigh > 0 else {
        continue
      }
      guard bitmapRep.hasAlpha else { return false }
      if let transparent = bitmapRepresentationIsFullyTransparent(bitmapRep) {
        inspectedRepresentation = true
        if !transparent { return false }
      }
    }
    return inspectedRepresentation ? true : nil
  }

  static func combinedCursorVisibility(
    windowServerVisible: Bool,
    cursorImageIsFullyTransparent: Bool?
  ) -> Bool {
    return windowServerVisible && cursorImageIsFullyTransparent != true
  }

  static func reconciledCursorVisibility(
    windowServerVisible: Bool,
    previousWindowServerVisible: Bool?,
    cursorTextureProvesVisible: Bool,
    cursorImageIsFullyTransparent: Bool?
  ) -> (visible: Bool, cursorTextureProvesVisible: Bool) {
    if cursorImageIsFullyTransparent == true {
      return (false, false)
    }
    if windowServerVisible {
      return (true, false)
    }
    if previousWindowServerVisible == nil || previousWindowServerVisible == true {
      return (false, false)
    }
    return (cursorTextureProvesVisible, cursorTextureProvesVisible)
  }

  private static func bitmapRepresentationIsFullyTransparent(
    _ bitmapRep: NSBitmapImageRep
  ) -> Bool? {
    if bitmapRep.bitsPerSample == 8,
       !bitmapRep.isPlanar,
       let bitmapData = bitmapRep.bitmapData {
      let bytesPerPixel = bitmapRep.bitsPerPixel / 8
      guard bytesPerPixel > 0 else { return nil }
      let alphaOffset = bitmapRep.bitmapFormat.contains(.alphaFirst)
        ? 0
        : bytesPerPixel - 1

      for y in 0..<bitmapRep.pixelsHigh {
        let row = bitmapData.advanced(by: y * bitmapRep.bytesPerRow)
        for x in 0..<bitmapRep.pixelsWide {
          if row[x * bytesPerPixel + alphaOffset] != 0 {
            return false
          }
        }
      }
      return true
    }

    var inspectedPixel = false
    for y in 0..<bitmapRep.pixelsHigh {
      for x in 0..<bitmapRep.pixelsWide {
        guard let color = bitmapRep.colorAt(x: x, y: y) else { continue }
        inspectedPixel = true
        if color.alphaComponent > 0 { return false }
      }
    }
    return inspectedPixel ? true : nil
  }

#if CLOUDPLAYPLUS_DMG_DISTRIBUTION
  private static func cursorVisibilityValue(_ rawValue: Int32?) -> Bool? {
    return rawValue.map { $0 != 0 }
  }

  private func currentWindowServerCursorVisibility() -> Bool {
    if let slCursorIsVisible = resolveSLCursorIsVisibleFunction() {
      return Self.cursorVisibilityValue(slCursorIsVisible()) ?? true
    } else if let cgCursorIsVisible = resolveCGCursorIsVisibleFunction() {
      return Self.cursorVisibilityValue(cgCursorIsVisible()) ?? true
    }
    return true
  }

  private func currentSystemCursorVisibility() -> Bool {
    let windowServerVisible = currentWindowServerCursorVisibility()
    let cursorImage = NSCursor.currentSystem?.image
    let cursorImageIsFullyTransparent = cursorImage.flatMap {
      Self.cursorImageIsFullyTransparent($0)
    }
    let result = Self.reconciledCursorVisibility(
      windowServerVisible: windowServerVisible,
      previousWindowServerVisible: lastWindowServerCursorVisible,
      cursorTextureProvesVisible: cursorTextureProvesVisible,
      cursorImageIsFullyTransparent: cursorImageIsFullyTransparent
    )
    lastWindowServerCursorVisible = windowServerVisible
    cursorTextureProvesVisible = result.cursorTextureProvesVisible
    return result.visible
  }

  private func updateCursorVisibilityAfterTextureChange(_ image: NSImage) {
    let cursorImageIsFullyTransparent = Self.cursorImageIsFullyTransparent(image)
    guard cursorImageIsFullyTransparent != nil else { return }

    let windowServerVisible = currentWindowServerCursorVisibility()
    let result = Self.reconciledCursorVisibility(
      windowServerVisible: windowServerVisible,
      previousWindowServerVisible: lastWindowServerCursorVisible,
      cursorTextureProvesVisible: cursorImageIsFullyTransparent == false,
      cursorImageIsFullyTransparent: cursorImageIsFullyTransparent
    )
    lastWindowServerCursorVisible = windowServerVisible
    cursorTextureProvesVisible = result.cursorTextureProvesVisible
    updateCursorVisibility(result.visible)
  }

  private func sendCursorInvisible(callbackID: Int) {
    methodChannel?.invokeMethod("onCursorImageMessage", arguments: [
      "callbackID": callbackID,
      "message": CursorConstants.cursorInvisible,
      "msg_info": 0,
      "cursorImage": FlutterStandardTypedData.init(bytes: Data([]))
    ])
  }

  private func sendCursorVisibility(callbackID: Int, visible: Bool) {
    if visible {
      sendCursorImagePosition(callbackID: callbackID)
    } else {
      sendCursorInvisible(callbackID: callbackID)
    }
  }

  private func updateCursorVisibility(_ visible: Bool) {
    guard lastCursorVisible != visible else { return }

    lastCursorVisible = visible
    for callbackID in cursorChangedCallbacks {
      sendCursorVisibility(callbackID: callbackID, visible: visible)
    }
  }

  private func pollCursorVisibility() {
    guard !cursorChangedCallbacks.isEmpty else { return }

    updateCursorVisibility(currentSystemCursorVisibility())
  }

  private func startCursorVisibilityTimer() {
    guard cursorVisibilityTimer == nil else { return }

    let intervalMs = Self.cursorVisibilityPollIntervalMs
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(
      deadline: .now() + .milliseconds(intervalMs),
      repeating: .milliseconds(intervalMs),
      leeway: .milliseconds(25)
    )
    timer.setEventHandler { [weak self] in
      self?.pollCursorVisibility()
    }
    cursorVisibilityTimer = timer
    timer.resume()
  }

  private func stopCursorVisibilityTimer() {
    cursorVisibilityTimer?.setEventHandler {}
    cursorVisibilityTimer?.cancel()
    cursorVisibilityTimer = nil
    lastCursorVisible = nil
    lastWindowServerCursorVisible = nil
    cursorTextureProvesVisible = false
  }

  private func updateCursorVisibilityAfterInjectedMouseMove() {
    pollCursorVisibility()
  }

  private func resolveCGCursorIsVisibleFunction() -> CGCursorIsVisibleFunction? {
    if cgCursorIsVisibleLookupAttempted {
      return cgCursorIsVisibleFunction
    }
    cgCursorIsVisibleLookupAttempted = true

    guard let processHandle = dlopen(nil, RTLD_LAZY) else { return nil }
    guard let symbol = dlsym(processHandle, "CGCursorIsVisible") else {
      dlclose(processHandle)
      return nil
    }
    cursorVisibilityProcessHandle = processHandle
    cgCursorIsVisibleFunction = unsafeBitCast(
      symbol,
      to: CGCursorIsVisibleFunction.self
    )
    return cgCursorIsVisibleFunction
  }

  private func resolveSLCursorIsVisibleFunction() -> SLCursorIsVisibleFunction? {
    if slCursorIsVisibleLookupAttempted {
      return slCursorIsVisibleFunction
    }
    slCursorIsVisibleLookupAttempted = true

    if let skyLight = loadMacSkyLight(),
       let symbol = dlsym(skyLight, "SLCursorIsVisible") {
      slCursorIsVisibleFunction = unsafeBitCast(
        symbol,
        to: SLCursorIsVisibleFunction.self
      )
    }
    return slCursorIsVisibleFunction
  }
#endif

  private func handleCursorMonitorEvent(_ event: NSEvent) {
    checkMouseCursor()
    sendCursorPositionToAll()

    switch event.type {
    case .leftMouseDown, .leftMouseUp,
         .rightMouseDown, .rightMouseUp,
         .otherMouseDown, .otherMouseUp:
      guard cursorTransitionProbesEnabled else { break }
      // Games commonly swap their cursor after handling the button event or
      // on the following render frame. Bounded follow-up probes catch that
      // transition without introducing a permanent high-frequency timer.
      // One-frame and short-hitch probes cover the common transition window.
      // Changes after 50 ms are picked up by the next mouse event.
      for delay in Self.cursorTransitionProbeDelaysMs {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(delay)) {
          [weak self] in
          self?.checkMouseCursor()
        }
      }
    default:
      break
    }
  }

  public static func screenCaptureCursorSeedDidChange() {
    DispatchQueue.main.async {
      for instance in registeredInstances.allObjects {
        instance.handleScreenCaptureCursorSeedChanged()
      }
    }
  }

  public static func screenCaptureCursorSeedProducerDidChange(_ active: Bool) {
    DispatchQueue.main.async {
      for instance in registeredInstances.allObjects {
        instance.cursorSeedProducerActive = active
      }
    }
  }

  func handleScreenCaptureCursorSeedChanged() {
    guard !cursorChangedCallbacks.isEmpty else { return }
#if DEBUG
    if let cursorSeedRefreshHandlerForTesting {
      cursorSeedRefreshHandlerForTesting()
      return
    }
#endif
    checkMouseCursor()
  }

  func getBitMapInt8(bitmapRep: NSBitmapImageRep) -> [UInt8]?{
    let width = bitmapRep.pixelsWide
    let height = bitmapRep.pixelsHigh
    let samplesPerPixel = bitmapRep.samplesPerPixel

    guard let bitmapData = bitmapRep.bitmapData else {
        print("No bitmap Data")
        return nil
    }

    var pixels: [UInt8] = Array(repeating: 0, count: width * height*4)
    for pixelIndex in 0..<width*height{
          pixels[pixelIndex*4+1]  = bitmapData[pixelIndex*samplesPerPixel + 2]
          pixels[pixelIndex*4+2] = bitmapData[pixelIndex*samplesPerPixel + 1]
          pixels[pixelIndex*4+3] =  bitmapData[pixelIndex*samplesPerPixel ]
          pixels[pixelIndex*4+0] = samplesPerPixel == 4 ? bitmapData[pixelIndex*4 + 3] : 255
    }

    return pixels
  }

  private func currentMousePosition() -> (screenId: Int, xPercent: Double, yPercent: Double)? {
    guard let location = currentMouseLocation() else {
      return nil
    }
    let topology = displayTopologySnapshot()
    for displayId in topology.cursorOrder {
      guard let bounds = topology.bounds[displayId] else {
        continue
      }
      if location.x >= bounds.minX && location.x < bounds.maxX &&
          location.y >= bounds.minY && location.y < bounds.maxY {
        guard let position = MacDisplayCoordinateMapper.normalizedPoint(
          location,
          in: bounds
        ) else {
          continue
        }
        return (
          screenId: displayId,
          xPercent: position.x,
          yPercent: position.y
        )
      }
    }

    let mainDisplayId = CGMainDisplayID()
    let bounds = CGDisplayBounds(mainDisplayId)
    guard !bounds.isNull && !bounds.isEmpty else {
      return nil
    }
    guard let position = MacDisplayCoordinateMapper.normalizedPoint(
      location,
      in: bounds
    ) else {
      return nil
    }
    return (
      screenId: Int(mainDisplayId),
      xPercent: position.x,
      yPercent: position.y
    )
  }

  private func sendCursorPosition(callbackID: Int, message: Int = CursorConstants.cursorPositionChanged) {
    guard let position = currentMousePosition() else {
      return
    }
    methodChannel?.invokeMethod("onCursorPositionMessage", arguments: [
      "callbackID": callbackID,
      "message": message,
      "screenId": position.screenId,
      "xPercent": position.xPercent,
      "yPercent": position.yPercent,
    ])
  }

  private func sendCursorImagePosition(callbackID: Int, message: Int = CursorConstants.cursorVisible) {
    guard let position = currentMousePosition() else {
      return
    }
    let positionBytes = cursorPositionPayload(position.xPercent, position.yPercent)

    methodChannel?.invokeMethod("onCursorImageMessage", arguments: [
      "callbackID": callbackID,
      "message": message,
      "msg_info": position.screenId,
      "cursorImage": FlutterStandardTypedData.init(bytes: positionBytes)
    ])
  }

  private func cursorPositionPayload(_ xPercent: Double, _ yPercent: Double) -> Data {
    var bytes = Data()
    appendUInt16LE(encodeUnitU16(xPercent), to: &bytes)
    appendUInt16LE(encodeUnitU16(yPercent), to: &bytes)
    return bytes
  }

  private func encodeUnitU16(_ value: Double) -> UInt16 {
    if !value.isFinite || value <= 0.0 {
      return 0
    }
    if value >= 1.0 {
      return UInt16.max
    }
    return UInt16((value * 65535.0).rounded())
  }

  private func appendUInt16LE(_ value: UInt16, to data: inout Data) {
    var littleEndian = value.littleEndian
    withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
  }

  private func sendCursorPositionToAll(message: Int = CursorConstants.cursorPositionChanged) {
    for callbackID in cursorPositionCallbacks {
      sendCursorPosition(callbackID: callbackID, message: message)
    }
  }

  private func callbackHasCursorHash(_ callbackID: Int, _ hash: UInt32) -> Bool {
    return cursorHashesByCallback[callbackID]?.contains(hash) ?? false
  }

  private func markCursorHashSeen(_ callbackID: Int, _ hash: UInt32) {
    var hashes = cursorHashesByCallback[callbackID] ?? Set<UInt32>()
    hashes.insert(hash)
    cursorHashesByCallback[callbackID] = hashes
  }

  private func checkMouseCursor() {
    guard !cursorChangedCallbacks.isEmpty,
      let currentCursor = NSCursor.currentSystem else {
      return
    }

    let cursorImage = currentCursor.image
    let hotSpot = currentCursor.hotSpot
    let cursorImageHashes = sha256ForAllBitmapReps(in: cursorImage)
    let systemCursorId = defaultCursorHasher?.systemCursorId(for: currentCursor)
    let cursorImageSignature = Self.cursorImageSignature(
      image: cursorImage,
      imageHash: cursorImageHashes,
      hotSpot: hotSpot,
      systemCursorId: systemCursorId
    )

    if cursorImageSignature == previousCursorImageSignature {
        return;
    }
#if CLOUDPLAYPLUS_DMG_DISTRIBUTION
    if Self.cursorBitmapChangedForVisibility(
      previousImageHash: previousCursorVisibilityImageHash,
      currentImageHash: cursorImageHashes
    ) {
      updateCursorVisibilityAfterTextureChange(cursorImage)
      previousCursorVisibilityImageHash = cursorImageHashes
    }
#endif
    //system default
    if let cursorIndex = systemCursorId {
        var updatedAllCallbacks = true
        for callbackID in cursorChangedCallbacks {
            if !(hookAllCursorImage[callbackID] ?? false) {
                let message: [String: Any] = [
                    "callbackID": callbackID,
                    "message": CursorConstants.cursorUpdatedDefault,
                    "msg_info": cursorIndex,
                    "cursorImage": FlutterStandardTypedData.init(bytes: Data([]))
                ]
                methodChannel?.invokeMethod("onCursorImageMessage", arguments: message)
            } else {
                // For hookAll=true, treat it as if it's not a default cursor
                guard let encoded = encodeCursorBitmap(
                  image: cursorImage,
                  hotSpot: hotSpot,
                  systemCursorId: UInt32(clamping: cursorIndex)
                ) else {
                  updatedAllCallbacks = false
                  continue
                }
                let messageHash = encoded.hash
                cursorHashByImageSignature[cursorImageSignature] = messageHash

                let message: [String: Any] = [
                    "callbackID": callbackID,
                    "message": CursorConstants.cursorUpdatedImage,
                    "msg_info": messageHash,
                    "cursorImage": FlutterStandardTypedData.init(bytes: encoded.payload)
                ]
                methodChannel?.invokeMethod("onCursorImageMessage", arguments: message)
                markCursorHashSeen(callbackID, messageHash)
            }
        }
        if updatedAllCallbacks {
          previousCursorImageSignature = cursorImageSignature
        }
        return ;
    }
      
    //cache iamge
    if let messageHash = cursorHashByImageSignature[cursorImageSignature] {
      var fullImageMessage: [String: Any]? = nil
      if cursorChangedCallbacks.contains(where: { !callbackHasCursorHash($0, messageHash) }) {
        guard let encoded = encodeCursorBitmap(
          image: cursorImage,
          hotSpot: hotSpot
        ) else {
          return
        }
        fullImageMessage = [
          "message": CursorConstants.cursorUpdatedImage,
          "msg_info": messageHash,
          "cursorImage": FlutterStandardTypedData.init(bytes: encoded.payload)
        ]
      }
      for callbackID in cursorChangedCallbacks {
        if callbackHasCursorHash(callbackID, messageHash) {
          let message: [String: Any] = [
              "callbackID": callbackID,
              "message": CursorConstants.cursorUpdatedCached,
              "msg_info": messageHash,
              "cursorImage": FlutterStandardTypedData.init(bytes: Data([]))
          ]
          methodChannel?.invokeMethod("onCursorImageMessage", arguments: message)
        } else if var message = fullImageMessage {
          message["callbackID"] = callbackID
          methodChannel?.invokeMethod("onCursorImageMessage", arguments: message)
          markCursorHashSeen(callbackID, messageHash)
        }
      }
      previousCursorImageSignature = cursorImageSignature
      return ;
    }
      
    guard let encoded = encodeCursorBitmap(
      image: cursorImage,
      hotSpot: hotSpot
    ) else {
      return
    }
    let messageHash = encoded.hash
    cursorHashByImageSignature[cursorImageSignature] = messageHash

    for callbackID in cursorChangedCallbacks {
      let message: [String: Any] = [
          "callbackID": callbackID,
          "message": CursorConstants.cursorUpdatedImage,
          "msg_info": messageHash,
          "cursorImage": FlutterStandardTypedData.init(bytes: encoded.payload)
      ]
      methodChannel?.invokeMethod("onCursorImageMessage", arguments: message)
      markCursorHashSeen(callbackID, messageHash)
    }
    previousCursorImageSignature = cursorImageSignature
  }
  
  var activities: [String: NSObjectProtocol] = [:]

  // MARK: - macOS editable-focus observation and committed text

  static let macTextInputNotificationNames = [
    kAXFocusedUIElementChangedNotification as String
  ]

#if CLOUDPLAYPLUS_DMG_DISTRIBUTION
  private static let macTextInputObserverCallback: AXObserverCallback = {
    _, element, notification, refcon in
    guard
      notification as String == kAXFocusedUIElementChangedNotification as String,
      let refcon
    else {
      return
    }
    let plugin = Unmanaged<HardwareSimulatorPlugin>
      .fromOpaque(refcon)
      .takeUnretainedValue()
    plugin.updateMacTextInputSnapshot(from: element)
  }
#endif

  static func macTextInputDecision(
    for traits: MacOSTextInputTraits
  ) -> MacOSTextInputDecision {
    guard traits.enabled, traits.editable != false else {
      return MacOSTextInputDecision(active: false, secure: nil)
    }
    let secure = traits.subrole == kAXSecureTextFieldSubrole as String
    let knownTextRole = traits.role == kAXTextFieldRole as String
      || traits.role == kAXTextAreaRole as String
      || traits.role == kAXComboBoxRole as String
    let active = secure
      || traits.editable == true
      || (knownTextRole && traits.valueSettable)
    return MacOSTextInputDecision(
      active: active,
      secure: active ? secure : nil
    )
  }

  static func validatedMacOSTextInputCodeUnits(
    _ text: String
  ) -> [UniChar]? {
    guard !text.isEmpty, text.utf8.count <= 4096 else { return nil }
    for scalar in text.unicodeScalars {
      if scalar.value <= 0x1f || scalar.value == 0x7f {
        return nil
      }
    }
    let codeUnits = Array(text.utf16)
    return codeUnits.isEmpty ? nil : codeUnits
  }

#if CLOUDPLAYPLUS_DMG_DISTRIBUTION
  private static func macAXString(
    _ element: AXUIElement,
    attribute: String
  ) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      element,
      attribute as CFString,
      &value
    ) == .success else {
      return nil
    }
    return value as? String
  }

  private static func macAXBool(
    _ element: AXUIElement,
    attribute: String
  ) -> Bool? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
      element,
      attribute as CFString,
      &value
    ) == .success else {
      return nil
    }
    return value as? Bool
  }

  private static func macAXElement(
    _ element: AXUIElement,
    attribute: String
  ) -> AXUIElement? {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element,
        attribute as CFString,
        &value
      ) == .success,
      let value,
      CFGetTypeID(value) == AXUIElementGetTypeID()
    else {
      return nil
    }
    return (value as! AXUIElement)
  }

  private static func macAXPoint(
    _ element: AXUIElement,
    attribute: String
  ) -> CGPoint? {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element,
        attribute as CFString,
        &value
      ) == .success,
      let value,
      CFGetTypeID(value) == AXValueGetTypeID()
    else {
      return nil
    }
    let axValue = value as! AXValue
    guard AXValueGetType(axValue) == .cgPoint else { return nil }
    var point = CGPoint.zero
    return AXValueGetValue(axValue, .cgPoint, &point) ? point : nil
  }

  private static func macAXSize(
    _ element: AXUIElement,
    attribute: String
  ) -> CGSize? {
    var value: CFTypeRef?
    guard
      AXUIElementCopyAttributeValue(
        element,
        attribute as CFString,
        &value
      ) == .success,
      let value,
      CFGetTypeID(value) == AXValueGetTypeID()
    else {
      return nil
    }
    let axValue = value as! AXValue
    guard AXValueGetType(axValue) == .cgSize else { return nil }
    var size = CGSize.zero
    return AXValueGetValue(axValue, .cgSize, &size) ? size : nil
  }

  private static func macAXFrame(_ element: AXUIElement) -> CGRect? {
    guard
      let position = macAXPoint(
        element,
        attribute: kAXPositionAttribute as String
      ),
      let size = macAXSize(
        element,
        attribute: kAXSizeAttribute as String
      ),
      size.width > 0,
      size.height > 0
    else {
      return nil
    }
    return CGRect(origin: position, size: size)
  }

  private static func macAXAttributeIsSettable(
    _ element: AXUIElement,
    attribute: String
  ) -> Bool {
    var settable = DarwinBoolean(false)
    return AXUIElementIsAttributeSettable(
      element,
      attribute as CFString,
      &settable
    ) == .success && settable.boolValue
  }

  private static func macTextInputTraits(
    for element: AXUIElement
  ) -> MacOSTextInputTraits {
    let valueSettable = macAXAttributeIsSettable(
      element,
      attribute: kAXValueAttribute as String
    ) || macAXAttributeIsSettable(
      element,
      attribute: kAXSelectedTextAttribute as String
    ) || macAXAttributeIsSettable(
      element,
      attribute: kAXSelectedTextRangeAttribute as String
    )
    return MacOSTextInputTraits(
      role: macAXString(element, attribute: kAXRoleAttribute as String),
      subrole: macAXString(element, attribute: kAXSubroleAttribute as String),
      enabled: macAXBool(
        element,
        attribute: kAXEnabledAttribute as String
      ) ?? true,
      editable: macAXBool(
        element,
        attribute: kAXIsEditableAttribute as String
      ),
      valueSettable: valueSettable
    )
  }

  private static func inspectMacTextInputElement(
    _ element: AXUIElement,
    includeParentChain: Bool = false
  ) -> MacOSTextInputDecision {
    var candidates = [AXUIElement]()
    func appendUnique(_ candidate: AXUIElement) {
      if !candidates.contains(where: { CFEqual($0, candidate) }) {
        candidates.append(candidate)
      }
    }

    appendUnique(element)
    if let editableAncestor = macAXElement(
      element,
      attribute: kAXEditableAncestorAttribute as String
    ) {
      appendUnique(editableAncestor)
    }
    if let highestEditableAncestor = macAXElement(
      element,
      attribute: kAXHighestEditableAncestorAttribute as String
    ) {
      appendUnique(highestEditableAncestor)
    }
    if includeParentChain {
      var ancestor = element
      for _ in 0..<12 {
        guard let parent = macAXElement(
          ancestor,
          attribute: kAXParentAttribute as String
        ) else {
          break
        }
        appendUnique(parent)
        ancestor = parent
      }
    }
    for candidate in candidates {
      let decision = macTextInputDecision(
        for: macTextInputTraits(for: candidate)
      )
      if decision.active {
        return decision
      }
    }
    return MacOSTextInputDecision(active: false, secure: nil)
  }

  private static func inspectMacFocusedElement(
    _ application: AXUIElement
  ) -> MacOSTextInputDecision? {
    guard let focused = macAXElement(
      application,
      attribute: kAXFocusedUIElementAttribute as String
    ) else {
      return nil
    }
    return inspectMacTextInputElement(focused)
  }

  private static func inspectMacTextInputAtPosition(
    _ location: CGPoint
  ) -> MacOSTextInputDecision {
    let systemWide = AXUIElementCreateSystemWide()
    var hitElement: AXUIElement?
    if AXUIElementCopyElementAtPosition(
      systemWide,
      Float(location.x),
      Float(location.y),
      &hitElement
    ) == .success, let hitElement {
      let hitDecision = inspectMacTextInputElement(
        hitElement,
        includeParentChain: true
      )
      if hitDecision.active {
        return hitDecision
      }
    }

    // Browser accessibility providers sometimes expose the editable object as
    // the focused element but return a generic WebArea descendant for hit-test.
    // The frame check keeps an app-activation focus restore from opening the
    // keyboard when the remote click landed somewhere else.
    guard
      let application = macAXElement(
        systemWide,
        attribute: kAXFocusedApplicationAttribute as String
      ),
      let focused = macAXElement(
        application,
        attribute: kAXFocusedUIElementAttribute as String
      ),
      let frame = macAXFrame(focused),
      frame.contains(location)
    else {
      return MacOSTextInputDecision(active: false, secure: nil)
    }
    return inspectMacTextInputElement(focused, includeParentChain: true)
  }

  private func updateMacTextInputSnapshot(from element: AXUIElement) {
    macTextInputQueue.async { [weak self] in
      guard let self else { return }
      self.macTextInputSnapshot = Self.inspectMacTextInputElement(element)
      self.macTextInputSnapshotKnown = true
    }
  }

  private func refreshMacTextInputSnapshot(
    from application: AXUIElement
  ) {
    macTextInputQueue.async { [weak self] in
      guard let self else { return }
      if let decision = Self.inspectMacFocusedElement(application) {
        self.macTextInputSnapshot = decision
        self.macTextInputSnapshotKnown = true
      } else {
        self.macTextInputSnapshot = MacOSTextInputDecision(
          active: false,
          secure: nil
        )
        self.macTextInputSnapshotKnown = false
      }
    }
  }

  private func detachMacTextInputObserver() {
    if let observer = macTextInputObserver,
       let application = macTextInputObservedApplication {
      AXObserverRemoveNotification(
        observer,
        application,
        kAXFocusedUIElementChangedNotification as CFString
      )
      CFRunLoopRemoveSource(
        CFRunLoopGetMain(),
        AXObserverGetRunLoopSource(observer),
        .commonModes
      )
    }
    macTextInputObserver = nil
    macTextInputObservedApplication = nil
  }

  private func attachMacTextInputObserver(
    to runningApplication: NSRunningApplication
  ) {
    detachMacTextInputObserver()

    let application = AXUIElementCreateApplication(
      runningApplication.processIdentifier
    )
    AXUIElementSetMessagingTimeout(application, 0.2)
    var observer: AXObserver?
    guard AXObserverCreate(
      runningApplication.processIdentifier,
      Self.macTextInputObserverCallback,
      &observer
    ) == .success, let observer else {
      return
    }
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    guard AXObserverAddNotification(
      observer,
      application,
      kAXFocusedUIElementChangedNotification as CFString,
      refcon
    ) == .success else {
      return
    }

    macTextInputObserver = observer
    macTextInputObservedApplication = application
    CFRunLoopAddSource(
      CFRunLoopGetMain(),
      AXObserverGetRunLoopSource(observer),
      .commonModes
    )
    refreshMacTextInputSnapshot(from: application)
  }

  private func startMacOSTextInputDecisionCapture() -> Bool {
    if macTextInputCaptureStarted { return true }
    guard AXIsProcessTrusted() else { return false }
    macTextInputCaptureStarted = true
    macTextInputWorkspaceObserver = NSWorkspace.shared.notificationCenter
      .addObserver(
        forName: NSWorkspace.didActivateApplicationNotification,
        object: nil,
        queue: .main
      ) { [weak self] notification in
        guard
          let self,
          let application = notification.userInfo?[
            NSWorkspace.applicationUserInfoKey
          ] as? NSRunningApplication
        else {
          return
        }
        self.attachMacTextInputObserver(to: application)
      }
    if let application = NSWorkspace.shared.frontmostApplication {
      attachMacTextInputObserver(to: application)
    }
    return true
  }

  private func stopMacOSTextInputDecisionCapture() {
    guard macTextInputCaptureStarted else { return }
    macTextInputCaptureStarted = false
    if let macTextInputWorkspaceObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(
        macTextInputWorkspaceObserver
      )
    }
    macTextInputWorkspaceObserver = nil
    detachMacTextInputObserver()
    macTextInputQueue.async { [weak self] in
      guard let self else { return }
      self.macTextInputRequestSequence &+= 1
      self.macTextInputSnapshot = MacOSTextInputDecision(
        active: false,
        secure: nil
      )
      self.macTextInputSnapshotKnown = false
    }
  }

  private func inspectMacTextInputAfterRemotePointerUp(
    editFocusRequestId: Int?,
    location: CGPoint?
  ) {
    guard
      macTextInputCaptureStarted,
      let editFocusRequestId,
      let location
    else {
      return
    }
    macTextInputQueue.async { [weak self] in
      guard let self else { return }
      self.macTextInputRequestSequence &+= 1
      let sequence = self.macTextInputRequestSequence
      self.macTextInputQueue.asyncAfter(
        deadline: .now() + .milliseconds(50)
      ) { [weak self] in
        guard
          let self,
          sequence == self.macTextInputRequestSequence
        else {
          return
        }
        let decision = Self.inspectMacTextInputAtPosition(location)
        self.macTextInputSnapshot = decision
        self.macTextInputSnapshotKnown = true
        DispatchQueue.main.async { [weak self] in
          self?.methodChannel?.invokeMethod(
            "onTextInputDecision",
            arguments: [
              "active": decision.active,
              "secure": decision.secure as Any,
              "editFocusRequestId": editFocusRequestId,
            ]
          )
        }
      }
    }
  }

  private func performMacOSTextInput(_ text: String) -> Bool {
    guard let codeUnits = Self.validatedMacOSTextInputCodeUnits(text) else {
      return false
    }
    guard
      let keyDown = CGEvent(
        keyboardEventSource: nil,
        virtualKey: 0,
        keyDown: true
      ),
      let keyUp = CGEvent(
        keyboardEventSource: nil,
        virtualKey: 0,
        keyDown: false
      )
    else {
      return false
    }
    codeUnits.withUnsafeBufferPointer { buffer in
      keyDown.keyboardSetUnicodeString(
        stringLength: buffer.count,
        unicodeString: buffer.baseAddress
      )
      keyUp.keyboardSetUnicodeString(
        stringLength: buffer.count,
        unicodeString: buffer.baseAddress
      )
    }
    keyDown.flags = []
    keyUp.flags = []
    keyDown.post(tap: .cghidEventTap)
    keyUp.post(tap: .cghidEventTap)
    return true
  }
#endif

  // MARK: - macOS permission self-check

  /// Whether this process can capture the screen. Uses the official preflight
  /// API on macOS 11+; falls back to a window-name heuristic on 10.15 (where
  /// no preflight API exists — if we can read another app's window title, the
  /// Screen Recording grant is in effect).
  ///
  /// NOTE: `CGPreflightScreenCaptureAccess()` caches its result for the whole
  /// process lifetime, so a freshly-granted permission only shows up after the
  /// app is relaunched. The UI tells the user this after they request access.
  private func macScreenCaptureGranted() -> Bool {
    if #available(macOS 11.0, *) {
      return CGPreflightScreenCaptureAccess()
    }
    let myPid = NSRunningApplication.current.processIdentifier
    let info = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]] ?? []
    for w in info {
      guard let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != myPid else { continue }
      if let name = w[kCGWindowName as String] as? String, !name.isEmpty {
        return true
      }
    }
    return false
  }

  /// Whether this process may inject synthetic input (mouse clicks, key events)
  /// via CGEventPost. macOS exposes a dedicated "Post Event" privilege; being
  /// AX-trusted also satisfies it, so accept either.
  ///
  /// NOTE: both calls cache in-process, so a freshly-granted permission only
  /// shows up after relaunch. The UI tells the user this after they request it.
  private func macInputInjectionGranted() -> Bool {
    if #available(macOS 10.15, *) {
      return CGPreflightPostEventAccess() || AXIsProcessTrusted()
    }
    return AXIsProcessTrusted()
  }

  /// Opens the relevant pane of System Settings → Privacy & Security.
  private func openMacOSPrivacySettings(section: String) {
    let anchor: String
    switch section {
    case "screenCapture": anchor = "Privacy_ScreenCapture"
    case "accessibility": anchor = "Privacy_Accessibility"
    case "inputMonitoring": anchor = "Privacy_ListenEvent"
    default: anchor = "Privacy"
    }
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
      NSWorkspace.shared.open(url)
    }
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPlatformVersion":
      result("macOS " + ProcessInfo.processInfo.operatingSystemVersionString)
    case "startTextInputDecisionCapture":
#if CLOUDPLAYPLUS_DMG_DISTRIBUTION
      result(startMacOSTextInputDecisionCapture())
#else
      result(false)
#endif
    case "stopTextInputDecisionCapture":
#if CLOUDPLAYPLUS_DMG_DISTRIBUTION
      stopMacOSTextInputDecisionCapture()
#endif
      result(nil)
    case "startTrackpadScrollCapture":
      result(startTrackpadScrollCapture())
    case "stopTrackpadScrollCapture":
      stopTrackpadScrollCapture()
      result(nil)
    case "startMacOSGlobeKeyProbe":
      result(startMacOSGlobeKeyProbe())
    case "stopMacOSGlobeKeyProbe":
      result(stopMacOSGlobeKeyProbe())
    case "selectNextMacOSInputSource":
      result(
        selectNextMacOSInputSource(
          requestOrdinal: macOSInputSourceRequestOrdinal(from: call.arguments)
        )
      )
    case "checkMacOSPermissions":
      // Reports the *current process's* live TCC status. Does NOT prompt.
      // - screenCapture: needed to grab the screen (ScreenCaptureKit / CGDisplayStream)
      // - inputInjection: needed to post synthetic mouse clicks / key events (CGEventPost)
      // - accessibility: AX trust for editable-focus observation
      result([
        "screenCapture": macScreenCaptureGranted(),
        "inputInjection": macInputInjectionGranted(),
        "accessibility": AXIsProcessTrusted(),
      ])
    case "requestMacOSPermission":
      // Actively asks macOS to show the consent prompt for the given permission.
      // For permissions that have no auto-prompt API on this OS, opens the
      // relevant System Settings pane instead. Returns the (possibly updated)
      // granted state after the request.
      let type = (call.arguments as? [String: Any])?["type"] as? String ?? ""
      switch type {
      case "screenCapture":
        if #available(macOS 11.0, *) {
          // Triggers the system prompt the first time; afterwards a no-op.
          let granted = CGRequestScreenCaptureAccess()
          if !granted { openMacOSPrivacySettings(section: "screenCapture") }
          result(granted)
        } else {
          openMacOSPrivacySettings(section: "screenCapture")
          result(macScreenCaptureGranted())
        }
      case "inputInjection":
        // CGRequestPostEventAccess shows the prompt the first time (macOS 10.15+).
        if #available(macOS 10.15, *) {
          let granted = CGRequestPostEventAccess()
          if !granted { openMacOSPrivacySettings(section: "accessibility") }
          result(granted)
        } else {
          openMacOSPrivacySettings(section: "accessibility")
          result(AXIsProcessTrusted())
        }
      case "accessibility":
        let options = [
          kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        result(AXIsProcessTrustedWithOptions(options))
      default:
        result(FlutterError(code: "BAD_ARGS", message: "Unknown permission type: \(type)", details: nil))
      }
    case "openMacOSPrivacySettings":
      let section = (call.arguments as? [String: Any])?["section"] as? String ?? ""
      openMacOSPrivacySettings(section: section)
      result(nil)
    case "beginActivity":
      let key = UUID().uuidString
      let reason = call.arguments as? String ?? "Prevent nap to do an important task."
      let activity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated], reason: reason)
      activities[key] = activity
      result(key)
    case "endActivity":
      let key = call.arguments as? String ?? ""
      if let activity = activities[key] {
        ProcessInfo.processInfo.endActivity(activity)
        activities[key] = nil 
        result(true)
        return
      }
      result(FlutterError(code: "Unknown Activity", message: nil, details: nil))
    case "getMonitorCount":
      let key = UUID().uuidString
      let reason = call.arguments as? String ?? "Prevent nap to do an important task."
      let activity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated], reason: reason)
      activities[key] = activity
      result(NSScreen.screens.count)
#if CLOUDPLAYPLUS_DMG_DISTRIBUTION
    case "initParsecVdd":
      result(macVirtualDisplayAvailable())
    case "createDisplay":
      let args = call.arguments as? [String: Any]
      let rawConfigs = args?["configs"] as? [[String: Any]]
      macVirtualDisplayQueue.async {
        let defaultConfig = self.macDefaultDisplayConfig()
        let primaryConfig =
          rawConfigs?.compactMap { self.macVirtualDisplayConfig(from: $0) }.first
          ?? defaultConfig
        let configs = self.macCreateDisplayConfigs(
          primary: primaryConfig,
          rawConfigs: rawConfigs
        )
        let id = self.spawnMacVirtualDisplay(
          width: primaryConfig.width,
          height: primaryConfig.height,
          refreshRate: primaryConfig.refreshRate,
          configs: configs
        )
        DispatchQueue.main.async { result(id) }
      }
    case "removeDisplay":
      let args = call.arguments as? [String: Any]
      let displayUid = args?["displayUid"] as? Int ?? -1
      macVirtualDisplayQueue.async {
        let ok = self.terminateMacVirtualDisplay(displayUid)
        DispatchQueue.main.async { result(ok) }
      }
    case "getAllDisplays":
      result(macDisplayList().count)
    case "getDisplayList":
      result(macDisplayList())
    case "changeDisplaySettings":
      guard
        let args = call.arguments as? [String: Any],
        let displayUid = args["displayUid"] as? Int,
        let width = args["width"] as? Int,
        let height = args["height"] as? Int,
        let refreshRate = args["refreshRate"] as? Int
      else {
        result(false)
        return
      }
      macVirtualDisplayQueue.async {
        let ok = self.setMacDisplayMode(
          displayId: displayUid,
          width: width,
          height: height,
          refreshRate: refreshRate
        )
        DispatchQueue.main.async { result(ok) }
      }
    case "getDisplayConfigs":
      let args = call.arguments as? [String: Any]
      let displayUid = args?["displayUid"] as? Int ?? Int(CGMainDisplayID())
      result(macDisplayConfigs(CGDirectDisplayID(displayUid)))
    case "getCustomDisplayConfigs":
      result(macCustomDisplayConfigs())
    case "setCustomDisplayConfigs":
      let args = call.arguments as? [String: Any]
      let configs = args?["configs"] as? [[String: Any]] ?? []
      result(setMacCustomDisplayConfigs(configs))
    case "setDisplayOrientation":
      result(false)
    case "getDisplayOrientation":
      result(0)
    case "setPrimaryDisplay":
      let args = call.arguments as? [String: Any]
      let displayUid = args?["displayIndex"] as? Int ?? -1
      macVirtualDisplayQueue.async {
        let ok = self.setMacPrimaryDisplay(displayUid)
        DispatchQueue.main.async { result(ok) }
      }
    case "setMultiDisplayMode":
      let args = call.arguments as? [String: Any]
      let mode = args?["mode"] as? Int ?? 4
      let primaryDisplayId = args?["primaryDisplayId"] as? Int ?? 0
      macVirtualDisplayQueue.async {
        let ok: Bool
        switch mode {
        case 0:
          ok = self.setMacExtendMode()
        case 1:
          ok = primaryDisplayId > 0
            ? self.setMacPrimaryDisplayOnly(primaryDisplayId)
            : self.setMacSingleDisplayMode(at: 0)
        case 2:
          ok = primaryDisplayId > 0
            ? self.setMacPrimaryDisplayOnly(primaryDisplayId)
            : self.setMacSingleDisplayMode(at: 1)
        case 3:
          ok = self.setMacDuplicateMode()
        default:
          ok = false
        }
        DispatchQueue.main.async { result(ok) }
      }
    case "getCurrentMultiDisplayMode":
      result(getCurrentMacMultiDisplayMode())
    case "setPrimaryDisplayOnly":
      let args = call.arguments as? [String: Any]
      let displayUid = args?["displayUid"] as? Int ?? -1
      macVirtualDisplayQueue.async {
        let ok = self.setMacPrimaryDisplayOnly(displayUid)
        DispatchQueue.main.async { result(ok) }
      }
    case "restoreDisplayConfiguration":
      macVirtualDisplayQueue.async {
        let ok = self.restoreMacDisplayConfiguration()
        DispatchQueue.main.async { result(ok) }
      }
    case "hasPendingConfiguration":
      macVirtualDisplayQueue.async {
        let hasPending = self.macDisplayConfigurationBackup != nil
        DispatchQueue.main.async { result(hasPending) }
      }
    case "getLastDisplayError":
      macVirtualDisplayQueue.async {
        let message = self.macLastVirtualDisplayError
        DispatchQueue.main.async { result(message) }
      }
    case "updateStaticMonitors":
      result(nil)
#else
    case "initParsecVdd":
      result(false)
    case "createDisplay":
      result(-1)
    case "removeDisplay":
      result(false)
    case "getAllDisplays":
      result(basicMacDisplayList().count)
    case "getDisplayList":
      result(basicMacDisplayList())
    case "changeDisplaySettings":
      result(false)
    case "getDisplayConfigs":
      result([])
    case "getCustomDisplayConfigs":
      result([])
    case "setCustomDisplayConfigs":
      result(false)
    case "setDisplayOrientation":
      result(false)
    case "getDisplayOrientation":
      result(0)
    case "setPrimaryDisplay":
      result(false)
    case "setMultiDisplayMode":
      result(false)
    case "getCurrentMultiDisplayMode":
      result(4)
    case "setPrimaryDisplayOnly":
      result(false)
    case "restoreDisplayConfiguration":
      result(false)
    case "hasPendingConfiguration":
      result(false)
    case "getLastDisplayError":
      result(nil)
    case "updateStaticMonitors":
      result(nil)
#endif
    case "mouseMoveA":
      if let args = call.arguments as? [String: Any],
        let percentX = args["x"] as? Double,
        let percentY = args["y"] as? Double,
        let screenId = args["screenId"] as? Int {
        // 调用鼠标移动函数
        performMouseMoveAbsl(x: percentX, y: percentY, screenId:screenId)
        result(nil) // 表示成功执行，不返回值
      } else {
        result(FlutterError(code: "BAD_ARGS", message: "Missing or incorrect arguments for MouseMove ABSL", details: nil))
      }
    case "mouseMoveR":
      if let args = call.arguments as? [String: Any],
        let percentX = args["x"] as? Double,
        let percentY = args["y"] as? Double,
        let screenId = args["screenId"] as? Int {
        // 调用鼠标移动函数
        performMouseMoveRelative(dx: percentX, dy: percentY, screenId:screenId)
        result(nil) // 表示成功执行，不返回值
      } else {
        result(FlutterError(code: "BAD_ARGS", message: "Missing or incorrect arguments for MouseMove Relative", details: nil))
      }
    case "mousePress":
      if let args = call.arguments as? [String: Any],
        let buttonId = args["buttonId"] as? Int,
        let isDown = args["isDown"] as? Bool {
        // 调用鼠标移动函数
        let pointerLocation = currentMouseLocation()
        performMouseButton(buttonId: buttonId, isDown: isDown)
#if CLOUDPLAYPLUS_DMG_DISTRIBUTION
        if buttonId == 1 && !isDown {
          inspectMacTextInputAfterRemotePointerUp(
            editFocusRequestId: args["editFocusRequestId"] as? Int,
            location: pointerLocation
          )
        }
#endif
        result(nil) // 表示成功执行，不返回值
      } else {
        result(FlutterError(code: "BAD_ARGS", message: "Missing or incorrect arguments for Mouse Press", details: nil))
      }
    case "mouseScroll":
      if let args = call.arguments as? [String: Any],
        let dx = args["dx"] as? Double,
        let dy = args["dy"] as? Double {
        // 调用鼠标移动函数
        performMouseScroll(dx: dx, dy: dy)
        result(nil) // 表示成功执行，不返回值
      } else {
        result(FlutterError(code: "BAD_ARGS", message: "Missing or incorrect arguments for Mouse Scroll", details: nil))
      }
    case "trackpadScroll":
      if let args = call.arguments as? [String: Any],
        let dx = args["dx"] as? Double,
        let dy = args["dy"] as? Double,
        let phase = args["phase"] as? String,
        let isMomentum = args["isMomentum"] as? Bool {
        performTrackpadScroll(
          dx: dx,
          dy: dy,
          phase: phase,
          isMomentum: isMomentum
        )
        result(nil)
      } else {
        result(FlutterError(code: "BAD_ARGS", message: "Missing or incorrect arguments for Trackpad Scroll", details: nil))
      }
    case "mouseMoveToWindowPosition":
      if let args = call.arguments as? [String: Any],
        let percentX = args["x"] as? Double,
        let percentY = args["y"] as? Double {
        // 调用鼠标移动到窗口位置函数
        performMouseMoveToWindowPosition(percentx: percentX, percenty: percentY)
        result(nil) // 表示成功执行，不返回值
      } else {
        result(FlutterError(code: "BAD_ARGS", message: "Missing or incorrect arguments for mouseMoveToWindowPosition", details: nil))
      }
    case "KeyPress":
        if let args = call.arguments as? [String: Any],
        let keyCode = args["code"] as? Int,
        let isDown = args["isDown"] as? Bool {
        // 调用鼠标移动函数
        PerformKeyEvent(code: keyCode, isDown: isDown)
        result(nil) // 表示成功执行，不返回值
      } else {
        result(FlutterError(code: "BAD_ARGS", message: "Missing or incorrect arguments for KeyPress", details: nil))
      }
    case "performTextInput":
#if CLOUDPLAYPLUS_DMG_DISTRIBUTION
      guard
        let args = call.arguments as? [String: Any],
        let text = args["text"] as? String
      else {
        result(FlutterError(
          code: "INVALID_TEXT",
          message: "Text input must be a string",
          details: nil
        ))
        return
      }
      if performMacOSTextInput(text) {
        result(nil)
      } else {
        result(FlutterError(
          code: "INVALID_TEXT",
          message: "Text input is invalid or too long",
          details: nil
        ))
      }
#else
      result(FlutterMethodNotImplemented)
#endif
    case "clearAllPressedEvents":
      keyboardRepeatQueue.async { [weak self] in
        self?.clearAllPressedEventsOnKeyboardQueue()
        DispatchQueue.main.async {
          result(nil)
        }
      }
    case "lockCursor":
      CGAssociateMouseAndMouseCursorPosition(0)
      NSCursor.hide()
      startTrackingMouse()
      result(nil)
    case "unlockCursor":
      CGAssociateMouseAndMouseCursorPosition(1)
      NSCursor.unhide()
      stopTrackingMouse()
      result(nil)
    case "unlockCursorAndReseed":
      guard let args = call.arguments as? [String: Any],
            let windowXPercent = args["x"] as? Double,
            let windowYPercent = args["y"] as? Double else {
        result(FlutterError(
          code: "BAD_ARGS",
          message: "Missing cursor re-seed position",
          details: nil
        ))
        return
      }

      stopTrackingMouse()
      if let location = cursorLocationInQuartzCoordinates(
          windowXPercent: windowXPercent,
          windowYPercent: windowYPercent
      ) {
        // CGWarpMouseCursorPosition changes the physical cursor location
        // without posting a mouse event, so the move cannot echo remotely.
        CGWarpMouseCursorPosition(location)
      }
      CGAssociateMouseAndMouseCursorPosition(1)
      NSCursor.unhide()
      result(nil)
    case "hookCursorImage":
      if let args = call.arguments as? [String: Any],
          let callbackID = args["callbackID"] as? Int,
          let hookAll = args["hookAll"] as? Bool {
          if cursorChangedCallbacks.count == 0 {
            mouseMovedMonitor = NSEvent.addGlobalMonitorForEvents(matching: cursorMonitorMask) { [weak self] event in
              self?.handleCursorMonitorEvent(event)
            }
            if let monitor = cursorPositionMonitor {
              NSEvent.removeMonitor(monitor)
              cursorPositionMonitor = nil
            }
          }
          cursorChangedCallbacks.insert(callbackID)
          hookAllCursorImage[callbackID] = hookAll

          // Seed every callback with the current texture. Collaborative
          // sessions cache it on the Host until that Viewer clicks or drags.
          if let currentCursor = NSCursor.currentSystem {
              let cursorImage = currentCursor.image
              let cursorImageHashes = sha256ForAllBitmapReps(in: cursorImage)
              let systemCursorId =
                defaultCursorHasher?.systemCursorId(for: currentCursor)
              let cursorImageSignature = Self.cursorImageSignature(
                image: cursorImage,
                imageHash: cursorImageHashes,
                hotSpot: currentCursor.hotSpot,
                systemCursorId: systemCursorId
              )
              if !hookAll, let cursorIndex = systemCursorId {
                  let message: [String: Any] = [
                      "callbackID": callbackID,
                      "message": CursorConstants.cursorUpdatedDefault,
                      "msg_info": cursorIndex,
                      "cursorImage": FlutterStandardTypedData.init(bytes: Data([]))
                  ]
                  methodChannel?.invokeMethod("onCursorImageMessage", arguments: message)
              } else if let encoded = encodeCursorBitmap(
                image: cursorImage,
                hotSpot: currentCursor.hotSpot,
                systemCursorId: UInt32(clamping: systemCursorId ?? 0)
              ) {
                  let messageHash = encoded.hash
                  cursorHashByImageSignature[cursorImageSignature] = messageHash

                  let message: [String: Any] = [
                      "callbackID": callbackID,
                      "message": CursorConstants.cursorUpdatedImage,
                      "msg_info": messageHash,
                      "cursorImage": FlutterStandardTypedData.init(bytes: encoded.payload)
                  ]
                  methodChannel?.invokeMethod("onCursorImageMessage", arguments: message)
                  markCursorHashSeen(callbackID, messageHash)
#if !CLOUDPLAYPLUS_DMG_DISTRIBUTION
                  sendCursorImagePosition(callbackID: callbackID)
#endif
              }
          }

#if CLOUDPLAYPLUS_DMG_DISTRIBUTION
          let visible = currentSystemCursorVisibility()
          if lastCursorVisible == visible {
            sendCursorVisibility(callbackID: callbackID, visible: visible)
          } else {
            updateCursorVisibility(visible)
          }
          startCursorVisibilityTimer()
#endif
         }
      else {
        result(FlutterError(code: "BAD_ARGS", message: "Missing or incorrect arguments for hookCursorImage", details: nil))
      }
    case "unhookCursorImage":
      if let args = call.arguments as? [String: Any],
        let callbackID = args["callbackID"] as? Int{
          cursorChangedCallbacks.remove(callbackID)
          hookAllCursorImage.removeValue(forKey: callbackID)
          cursorHashesByCallback.removeValue(forKey: callbackID)
          if cursorChangedCallbacks.count == 0{
#if CLOUDPLAYPLUS_DMG_DISTRIBUTION
              stopCursorVisibilityTimer()
#endif
              if let monitor = mouseMovedMonitor {
               NSEvent.removeMonitor(monitor)
               mouseMovedMonitor = nil
            }
            if cursorPositionCallbacks.count > 0 && cursorPositionMonitor == nil {
              cursorPositionMonitor = NSEvent.addGlobalMonitorForEvents(matching: cursorMonitorMask) { [weak self] event in
                self?.sendCursorPositionToAll()
              }
            }
          }
         }
      else {
        result(FlutterError(code: "BAD_ARGS", message: "Missing or incorrect arguments for unhookCursorImage", details: nil))
      }
    case "hookCursorPosition":
      if let args = call.arguments as? [String: Any],
          let callbackID = args["callbackID"] as? Int {
          cursorPositionCallbacks.insert(callbackID)
          if cursorPositionMonitor == nil && mouseMovedMonitor == nil {
            cursorPositionMonitor = NSEvent.addGlobalMonitorForEvents(matching: cursorMonitorMask) { [weak self] event in
              self?.sendCursorPositionToAll()
            }
          }
          sendCursorPosition(callbackID: callbackID)
      } else {
        result(FlutterError(code: "BAD_ARGS", message: "Missing or incorrect arguments for hookCursorPosition", details: nil))
      }
    case "unhookCursorPosition":
      if let args = call.arguments as? [String: Any],
          let callbackID = args["callbackID"] as? Int {
          cursorPositionCallbacks.remove(callbackID)
          if cursorPositionCallbacks.count == 0, let monitor = cursorPositionMonitor {
            NSEvent.removeMonitor(monitor)
            cursorPositionMonitor = nil
          }
      } else {
        result(FlutterError(code: "BAD_ARGS", message: "Missing or incorrect arguments for unhookCursorPosition", details: nil))
      }

    default:
      print("Hardware Simulator: Method called but not implemented: \(call.method)")
      if let arguments = call.arguments {
          print("Arguments: \(arguments)")
      } else {
          print("No arguments provided.")
      }
      result(nil);
    }
  }
}

class CursorHasher {
    private struct CursorSignature: Hashable {
        let imageHash: String
        let hotSpotX: Double
        let hotSpotY: Double
    }

    private var cursorIds: [CursorSignature: Int] = [:]
    
    init() {
        calculateHashesForDefaultCursors()
    }
    
    private func calculateHashesForDefaultCursors() {
        let defaultCursors: [NSCursor : Int] = [
         .arrow : 32512,                // IDC_ARROW
         .iBeam : 32513,                // IDC_IBEAM
         .crosshair : 32515,             // IDC_CROSS
         .pointingHand:32649,           // IDC_HAND
         .resizeLeftRight:32644,        // IDC_SIZEWE
         .resizeUpDown:32645,           // IDC_SIZENS
         .operationNotAllowed:32648,    // IDC_NO
         .closedHand: 32401,          // custom grabbing
         .openHand: 32402,            // custom grab
         .resizeUp:32403,             // custom resizeUp
         .resizeDown:32404,           // custom resizeDown
         .resizeLeft:32405,           // custom resizeLeft
         .resizeRight:32406,          // custom resizeRight
         .disappearingItem:32407,     // custom disappearing
         .contextualMenu:32408,       // custom contextMenu
         .dragLink:  32409,           // custom alias
         .dragCopy:  32410,          // custom copy
         .iBeamCursorForVerticalLayout : 32411 // custom verticalText
      ]

      for (cursor,index) in defaultCursors {
          cursorIds[signature(for: cursor)] = index
          
          // 打印每个光标的尺寸
          if let rep = cursor.image.representations.first as? NSBitmapImageRep {
              print("Cursor \(index) size: \(rep.pixelsWide)x\(rep.pixelsHigh)")
          }
      }
    }

    private func signature(for cursor: NSCursor) -> CursorSignature {
        CursorSignature(
          imageHash: sha256ForAllBitmapReps(in: cursor.image),
          hotSpotX: Double(cursor.hotSpot.x),
          hotSpotY: Double(cursor.hotSpot.y)
        )
    }

    func systemCursorId(for cursor: NSCursor) -> Int? {
        return cursorIds[signature(for: cursor)]
    }
}

func sha256ForAllBitmapReps(in image: NSImage) -> String {
    var alldata = Data()
    for rep in image.representations {
        if let bitmapRep = rep as? NSBitmapImageRep {
            guard let pixelData = bitmapRep.bitmapData else { continue }
            let dataSize = bitmapRep.bytesPerRow * bitmapRep.pixelsHigh
            let data = Data(bytes: pixelData, count: dataSize)
            alldata.append(data)
        }
    }
    
    var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    alldata.withUnsafeBytes {
        _ = CC_SHA256($0.baseAddress, CC_LONG(alldata.count), &hash)
    }
    
    let hashString = hash.map { String(format: "%02x", $0) }.joined()
    return hashString
}
