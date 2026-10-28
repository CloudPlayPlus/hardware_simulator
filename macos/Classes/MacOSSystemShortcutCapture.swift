import AppKit
import Carbon.HIToolbox

/// 复用registry；所有状态在main lane，owner只属于本机绑定，不进入协议。
final class MacOSSystemShortcutCapture {
  private let registry: MacOSInputCaptureRegistry
  private let router = MacOSSystemShortcutRouter()
  private let emit: ([String: Any]) -> Void
  private let log: (String) -> Void
  private weak var view: NSView?
  private var owner: String?
  private var observers: [NSObjectProtocol] = []
  private let id = "system-shortcuts"
  private var toggleOwner: String?
  private var toggleMonitor: Any?
  private var togglePending = false
  private var toggleEscapeDown = false
  private var healthTimer: Timer?
  private var lastAcknowledged: TimeInterval = 0
  private var challenge = 0
  private var pendingChallenge: Int?
  private var tailDeadline: TimeInterval?
#if DEBUG
  var healthCheckForTesting: (() -> Bool)?
#endif
  private var permissionAvailable: Bool {
#if DEBUG
    if let healthCheckForTesting { return healthCheckForTesting() }
#endif
    return AXIsProcessTrusted() && !IsSecureEventInputEnabled()
  }
  private var tapAvailable: Bool {
#if DEBUG
    if let healthCheckForTesting { return healthCheckForTesting() }
#endif
    return registry.isActive(id:id)
  }
  private let clock: () -> TimeInterval
  private func startHealthCheck() {
    tailDeadline=nil
    lastAcknowledged=clock()
    pendingChallenge=nil
    healthTimer?.invalidate()
    let timer=Timer(timeInterval:0.5,repeats:true) { [weak self] _ in self?.checkHealth() }
    healthTimer=timer
    RunLoop.main.add(timer,forMode:.common)
  }
  private func expireIfNeeded() {
    if router.armed && clock()-lastAcknowledged >= 2 { stop(reason:"consumer-timeout",discardPending:true) }
  }
  private func checkHealth() {
    expireIfNeeded()
    if let tailDeadline, clock() >= tailDeadline {
      stop(reason:"tail-timeout",discardPending:true)
    }
    guard router.armed || router.hasPendingKeys else { return }
    if !permissionAvailable || !tapAvailable {
      stop(reason:"capture-unavailable",discardPending:true)
      return
    }
    guard router.armed, pendingChallenge == nil, let owner else { return }
    challenge += 1
    pendingChallenge=challenge
    emit(["owner":owner,"kind":"heartbeat","challenge":challenge])
  }
  func acknowledge(owner: String, challenge: Int) {
    expireIfNeeded()
    guard router.armed, self.owner == owner, pendingChallenge == challenge else { return }
    pendingChallenge=nil
    lastAcknowledged=clock()
  }
  func setToggle(owner: String, enabled: Bool) {
    if !enabled {
      guard toggleOwner == owner else { return }
      toggleOwner=nil; togglePending=false; toggleEscapeDown=false
      return
    }
    if toggleOwner != owner { togglePending=false; toggleEscapeDown=false }
    toggleOwner=owner
    if toggleMonitor == nil {
      toggleMonitor=NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.keyUp,.flagsChanged]) { [weak self] event in
        guard let self else { return event }
        return self.handleToggle(event)
      }
    }
  }
  static func isToggleChord(_ flags: CGEventFlags) -> Bool {
    flags.intersection(MacOSSystemShortcutRouter.modifiers) == [.maskControl,.maskCommand]
  }
  private func handleToggle(_ event: NSEvent) -> NSEvent? {
    guard let eventFlags=event.cgEvent?.flags else { return event }
    let flags=eventFlags.intersection(MacOSSystemShortcutRouter.modifiers)
    let eligible=toggleOwner != nil && focused && !IsSecureEventInputEnabled()
    if !eligible { togglePending=false; toggleEscapeDown=false }
    if event.keyCode == 53 && event.type == .keyDown {
      if toggleEscapeDown { return nil }
      if eligible && !event.isARepeat && Self.isToggleChord(flags) {
        togglePending=true;toggleEscapeDown=true;return nil
      }
    }
    let consume=event.keyCode == 53 && event.type == .keyUp && toggleEscapeDown
    if consume { toggleEscapeDown=false }
    if togglePending && !toggleEscapeDown && flags.isEmpty, let owner=toggleOwner {
      togglePending=false
      // 本机释放不依赖Dart是否能处理toggle；通知仅同步界面设置。
      stop(reason:"local-toggle")
      // 让当前modifier up先经过Flutter，再切换并重新检查arm条件。
      DispatchQueue.main.async { [weak self] in
        guard let self, self.toggleOwner == owner, self.focused else { return }
        self.log("toggle owner=\(owner)")
        self.emit(["owner":owner,"kind":"toggle"])
      }
    }
    return consume ? nil : event
  }
  func updateView(_ view: NSView?) { self.view = view }
  init(registry: MacOSInputCaptureRegistry, view: NSView?, emit: @escaping ([String: Any]) -> Void,
       log: @escaping (String) -> Void,
       clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
    self.registry=registry; self.view=view; self.emit=emit; self.log=log; self.clock=clock
    for name in [NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
      observers.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
        guard let self, !self.focused else { return }
        self.togglePending=false
        self.toggleEscapeDown=false
        if self.router.armed { self.stop(reason:"native-focus") }
      })
    }
  }
  private var focused: Bool { NSApp.isActive && view?.window?.isKeyWindow == true }
  func set(owner next: String, enabled: Bool) -> Bool {
    precondition(Thread.isMainThread)
    expireIfNeeded()
    if !enabled { if owner == next { stop(reason:"binding-stop") }; return false }
    if owner == next && router.armed && registry.isActive(id:id) && focused && !IsSecureEventInputEnabled() && AXIsProcessTrusted() { return true }
    if owner != next { stop(reason:"owner-change") }
    router.reconcileReleasedKeys()
    let keysReleased = CGEventSource.flagsState(.combinedSessionState).intersection(MacOSSystemShortcutRouter.modifiers).isEmpty &&
      ![48,123,124,125,126].contains(where: { CGEventSource.keyState(.combinedSessionState,key:CGKeyCode($0)) })
    // 修改型tap以实际创建/启用结果为准；ListenEvent预检查不是此路径的必要条件。
    guard focused, !IsSecureEventInputEnabled(), AXIsProcessTrusted(), !router.hasPendingKeys, keysReleased else {
      stop(reason:"arm-gate",discardPending:true)
      log("arm_rejected owner=\(next) focused=\(focused) secure=\(IsSecureEventInputEnabled()) ax=\(AXIsProcessTrusted()) listen=\(CGPreflightListenEventAccess()) pending=\(router.hasPendingKeys)")
      return false
    }
    owner=next
    if !registry.isActive(id:id) {
      let mask = [CGEventType.keyDown,.keyUp,.flagsChanged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
      guard registry.register(id:id,mask:mask,handler:{ [weak self] type,event in
        self?.handle(type,event) ?? false
      }), registry.isActive(id:id) else {
        stop(reason:"tap-failed",discardPending:true)
        log("tap_failed owner=\(next) ax=\(AXIsProcessTrusted()) listen=\(CGPreflightListenEventAccess())")
        return false
      }
    }
    router.armed=true
    startHealthCheck()
    log("armed owner=\(next) tap_active=\(registry.isActive(id:id)) ax=\(AXIsProcessTrusted()) listen=\(CGPreflightListenEventAccess())")
    return true
  }
  private func closeTap() {
    registry.unregister(id:id)
    healthTimer?.invalidate();healthTimer=nil;pendingChallenge=nil;tailDeadline=nil
  }
  func stop(reason: String, discardPending: Bool = false) {
    let wasArmed=router.armed
    router.stop()
    pendingChallenge=nil
    if discardPending { router.reset() }
    if !router.hasPendingKeys {
      closeTap()
    } else if tailDeadline == nil {
      // 正常停止仅短暂配对已捕获的up；不能无限保留全局tap。
      tailDeadline=clock()+2
    }
    guard wasArmed, let owner else { return }
    log("stopped owner=\(owner) reason=\(reason)")
    emit(["owner":owner,"kind":"stopped","reason":reason])
  }
  private func handle(_ type: CGEventType,_ event: CGEvent) -> Bool {
    expireIfNeeded()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { stop(reason:"tap-disabled",discardPending:true);return false }
    guard type == .keyDown || type == .keyUp || type == .flagsChanged else { return false }
    if (router.armed || router.hasPendingKeys) && !permissionAvailable {
      stop(reason:"native-gate",discardPending:true)
      return false
    }
    if router.armed && !focused { stop(reason:"native-focus") }
    defer {
      if !router.armed && !router.hasPendingKeys && tailDeadline != nil { closeTap() }
    }
    if type == .flagsChanged {
      if router.armed, let owner {
        emit(["owner":owner,"kind":"key","keyCode":0,"isDown":false,
          "flags":Int(event.flags.intersection(MacOSSystemShortcutRouter.modifiers).rawValue)])
      }
      return false
    }
    let code=Int(event.getIntegerValueField(.keyboardEventKeycode))
    let down=type == .keyDown
    let repeatKey=event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    let decision=router.handle(code:code,down:down,flags:event.flags,repeatKey:repeatKey)
    switch decision {
    case .pass:return false
    case .consume:return true
    case .send:
      guard let owner else { return true }
      let vk = [48:0x09,123:0x25,124:0x27,125:0x28,126:0x26][code]!
      let flags=event.flags.intersection(MacOSSystemShortcutRouter.modifiers).rawValue
      emit(["owner":owner,"kind":"key","keyCode":vk,"isDown":down,"flags":Int(flags)])
      return true
    }
  }
  deinit {
    healthTimer?.invalidate()
    if let toggleMonitor { NSEvent.removeMonitor(toggleMonitor) }
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    registry.unregister(id:id)
  }
#if DEBUG
  // 无TCC依赖地测试同一生产计时/停止路径，不替换其状态逻辑。
  func armForTesting(owner: String, pressedCode: Int? = nil) {
    self.owner=owner;router.armed=true;startHealthCheck()
    registry.registerForTesting(id:id,handler:{ _,_ in false })
    if let pressedCode {
      _ = router.handle(code:pressedCode,down:true,flags:pressedCode == 48 ? .maskCommand : .maskControl,repeatKey:false)
    }
  }
  func checkHealthForTesting() { checkHealth() }
  func handleForTesting(_ type: CGEventType, _ event: CGEvent) -> Bool { handle(type,event) }
#endif
}
