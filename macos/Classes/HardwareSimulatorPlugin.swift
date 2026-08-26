import Cocoa
import FlutterMacOS
import CommonCrypto
import CoreGraphics
import ApplicationServices
import Darwin

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

public class HardwareSimulatorPlugin: NSObject, FlutterPlugin {
  private var methodChannel: FlutterMethodChannel?
  private weak var registrar: FlutterPluginRegistrar?
  private weak var flutterView: NSView?
  private var trackpadScrollMonitor: Any?
  private var defaultCursorHasher: CursorHasher?
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
  private var activeKeyRepeatTimer: DispatchSourceTimer?
  private var activeRepeatingWindowsKeyCode: Int?
  private var activeKeyMacCodes: [Int: CGKeyCode] = [:]
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
#if CLOUDPLAYPLUS_DMG_DISTRIBUTION
  private let macVirtualDisplayQueueKey = DispatchSpecificKey<Void>()
  private let macVirtualDisplayQueue = DispatchQueue(
    label: "com.cloudplayplus.hardware-simulator.virtual-display"
  )
  private var macVirtualDisplayProcesses: [Int: Process] = [:]
  private var macVirtualDisplaySerials: [Int: Int] = [:]
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
    instance.methodChannel = channel
    instance.registrar = registrar
    instance.defaultCursorHasher = CursorHasher()
    instance.startDisplayBoundsCache()
#if CLOUDPLAYPLUS_DMG_DISTRIBUTION
    instance.registerMacTerminationObserver()
#endif
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  deinit {
    stopTrackpadScrollCapture()
    if let displayBoundsCacheObserver {
      NotificationCenter.default.removeObserver(displayBoundsCacheObserver)
    }
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
    flutterView = nil
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
  override init() {
    super.init()
    macVirtualDisplayQueue.setSpecific(key: macVirtualDisplayQueueKey, value: ())
  }

  private struct MacVirtualDisplayConfig: Hashable {
    let width: Int
    let height: Int
    let refreshRate: Int
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

  private func readMacHelperDisplayId(from output: Pipe, timeout: DispatchTime) -> String? {
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
    let usedSerials = Set(macVirtualDisplaySerials.values)
    for slot in 1...255 {
      let serial = macVirtualDisplaySerialBase + slot
      if !usedSerials.contains(serial) {
        return serial
      }
    }
    return macVirtualDisplaySerialBase + macVirtualDisplaySerials.count + 1
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
    process.standardOutput = output
    process.standardError = FileHandle.standardError

    do {
      try process.run()
    } catch {
      return -1
    }

    guard
      let text = readMacHelperDisplayId(
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
        self?.macVirtualDisplayProcesses.removeValue(forKey: displayId)
        self?.macVirtualDisplaySerials.removeValue(forKey: displayId)
      }
    }
    withMacVirtualDisplayProcesses {
      macVirtualDisplayProcesses[displayId] = process
      macVirtualDisplaySerials[displayId] = serial
    }
    Thread.sleep(forTimeInterval: 1.0)
    return displayId
  }

  private func terminateMacVirtualDisplay(_ displayId: Int) -> Bool {
    if macDisplayConfigurationBackup?.contains(
      where: { Int($0.displayId) == displayId }
    ) == true {
      _ = restoreMacDisplayConfiguration()
    }
    let process: Process? = withMacVirtualDisplayProcesses {
      macVirtualDisplaySerials.removeValue(forKey: displayId)
      return macVirtualDisplayProcesses.removeValue(forKey: displayId)
    }
    guard let process else {
      return false
    }
    if process.isRunning {
      process.terminate()
    }
    return true
  }

  private func terminateAllMacVirtualDisplays() {
    withMacVirtualDisplayProcesses {
      for process in macVirtualDisplayProcesses.values where process.isRunning {
        process.terminate()
      }
      macVirtualDisplayProcesses.removeAll()
      macVirtualDisplaySerials.removeAll()
    }
  }

  private func macVirtualDisplayIdsSnapshot() -> Set<Int> {
    return withMacVirtualDisplayProcesses {
      Set(macVirtualDisplayProcesses.keys)
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

    guard macVirtualDisplayIdsSnapshot().contains(displayId) else {
      return false
    }
    let config = MacVirtualDisplayConfig(
      width: width,
      height: height,
      refreshRate: refreshRate
    )
    _ = terminateMacVirtualDisplay(displayId)
    return spawnMacVirtualDisplay(
      width: width,
      height: height,
      refreshRate: refreshRate,
      configs: macCreateDisplayConfigs(primary: config, rawConfigs: nil)
    ) > 0
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

      // Create and post the keyboard event.
      //
      // Strip the Fn (secondaryFn) and NumericPad flags before posting.
      // Arrow / navigation keys (kVK 0x7B–0x7E) are macOS function + numpad
      // keys, so CGEvent auto-tags their events with Fn | NumericPad. Posting
      // such an event latches Fn into the shared session modifier state — and
      // because the key-up event carries Fn too, it is never released. Every
      // subsequent injected key is built with `keyboardEventSource: nil`,
      // which inherits that polluted session state, so the stray Fn leaks onto
      // ordinary keys: e.g. "E" becomes 🌐+E and opens the Emoji & Symbols
      // picker. We never intend to inject Fn, so clear it (and NumericPad)
      // from every event; the virtual key code alone still drives arrows.
      let event = CGEvent(
        keyboardEventSource: nil,
        virtualKey: macKeyCode,
        keyDown: isDown
      )
      let inheritedFlags = CGEventSource.flagsState(.combinedSessionState)
      event?.flags = Self.keyboardFlagsForPressedKeyCodes(
        Array(activeKeyMacCodes.values),
        inheritedFlags: inheritedFlags
      )
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
      inheritedFlags: CGEventFlags
  ) -> CGEventFlags {
      var flags = inheritedFlags
      // Modifier state for injected input must come from our own pressed-key
      // table. Inheriting the host's physical modifiers makes a remote chord
      // nondeterministic, while omitting these flags makes Command+A arrive as
      // a plain A on macOS.
      flags.remove([
        .maskShift,
        .maskControl,
        .maskAlternate,
        .maskCommand,
        .maskSecondaryFn,
        .maskNumericPad,
      ])
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
      isDown: Bool
  ) -> CGEventFlags? {
      // Caps Lock is a status key on macOS. Its release does not create a
      // second state change; the next press flips AlphaShift back instead.
      guard isDown else {
          return nil
      }

      var flags = currentFlags
      flags.remove([.maskSecondaryFn, .maskNumericPad])
      if flags.contains(.maskAlphaShift) {
          flags.remove(.maskAlphaShift)
      } else {
          flags.insert(.maskAlphaShift)
      }
      return flags
  }

  private func postCapsLockEvent(isDown: Bool) {
      let currentFlags = CGEventSource.flagsState(.combinedSessionState)
      guard let flags = Self.capsLockFlagsForKeyEvent(
        currentFlags: currentFlags,
        isDown: isDown
      ) else {
          return
      }
      let capsLockEnabled = flags.contains(.maskAlphaShift)
      guard let event = CGEvent(
        keyboardEventSource: nil,
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
  // 远程注入移动后 WindowServer getter 可能一直停留在 false；新的非透明纹理
  // 证明系统已经重新绘制光标，不能被同一个滞留值立即覆盖。
  var cursorTextureProvesVisible = false
#endif
  var previousCursorImageHashes: String = ""
  var cursorChangedCallbacks = Set<Int>()
  var cursorPositionCallbacks = Set<Int>()
  var jsHashWithImageHash = Dictionary<String, UInt32>()
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

    var hashInput: [UInt8] = []
    appendUInt32BE(UInt32(clamping: bitmapRep.pixelsWide), to: &hashInput)
    appendUInt32BE(UInt32(clamping: bitmapRep.pixelsHigh), to: &hashInput)
    appendUInt32BE(hotSpotPixels.x, to: &hashInput)
    appendUInt32BE(hotSpotPixels.y, to: &hashInput)
    appendUInt32LE(systemCursorId, to: &hashInput)
    hashInput.append(contentsOf: pixels)
    let messageHash = JSHash(buffer: hashInput, size: hashInput.count)

    var bytes: [UInt8] = [9]
    appendUInt32BE(UInt32(clamping: bitmapRep.pixelsWide), to: &bytes)
    appendUInt32BE(UInt32(clamping: bitmapRep.pixelsHigh), to: &bytes)
    appendUInt32BE(hotSpotPixels.x, to: &bytes)
    appendUInt32BE(hotSpotPixels.y, to: &bytes)
    appendUInt32BE(messageHash, to: &bytes)
    appendUInt32LE(systemCursorId, to: &bytes)
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

    if(cursorImageHashes == previousCursorImageHashes){
        return;
    }
#if CLOUDPLAYPLUS_DMG_DISTRIBUTION
    updateCursorVisibilityAfterTextureChange(cursorImage)
#endif
    //system default
    if let cursorIndex = defaultCursorHasher?.getHashMap()[cursorImageHashes] {
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
                jsHashWithImageHash[cursorImageHashes] = messageHash

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
          previousCursorImageHashes = cursorImageHashes
        }
        return ;
    }
      
    //cache iamge
    if jsHashWithImageHash.keys.contains(cursorImageHashes) {
      //print("cache: \(jsHashWithImageHash[cursorImageHashes])");
      guard let messageHash = jsHashWithImageHash[cursorImageHashes] else {
        return
      }
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
      previousCursorImageHashes = cursorImageHashes
      return ;
    }
      
    guard let encoded = encodeCursorBitmap(
      image: cursorImage,
      hotSpot: hotSpot
    ) else {
      return
    }
    let messageHash = encoded.hash
    jsHashWithImageHash[cursorImageHashes] = messageHash

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
    previousCursorImageHashes = cursorImageHashes
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
                defaultCursorHasher?.getHashMap()[cursorImageHashes]
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
                  jsHashWithImageHash[cursorImageHashes] = messageHash

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
    private var cursorHashMap: [String: Int] = [:]
    
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
          let hash = sha256ForAllBitmapReps(in: cursor.image)
          cursorHashMap[hash] = index
          
          // 打印每个光标的尺寸
          if let rep = cursor.image.representations.first as? NSBitmapImageRep {
              print("Cursor \(index) size: \(rep.pixelsWide)x\(rep.pixelsHigh)")
          }
      }
    }
    
    func getHashMap() -> [String: Int] {
        return cursorHashMap
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
