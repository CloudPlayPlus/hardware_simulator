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
  private var repeats = 0
  private var toggleOwner: String?
  private var toggleMonitor: Any?
  private var togglePending = false
  private var toggleEscapeDown = false
  private var healthTimer: Timer?
  private var lastAcknowledged: TimeInterval = 0
  private var challenge = 0
  private var pendingChallenge: Int?
  private let clock: () -> TimeInterval
  private func startHealthCheck() {
    lastAcknowledged=clock()
    pendingChallenge=nil
    healthTimer?.invalidate()
    let timer=Timer(timeInterval:0.5,repeats:true) { [weak self] _ in self?.checkHealth() }
    healthTimer=timer
    RunLoop.main.add(timer,forMode:.common)
  }
  private func expireIfNeeded() {
    if router.armed && clock()-lastAcknowledged >= 2 { stop(reason:"consumer-timeout") }
  }
  private func checkHealth() {
    expireIfNeeded()
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
  private func handleToggle(_ event: NSEvent) -> NSEvent? {
    guard let eventFlags=event.cgEvent?.flags else { return event }
    let flags=eventFlags.intersection(MacOSSystemShortcutRouter.modifiers)
    let eligible=toggleOwner != nil && focused && !IsSecureEventInputEnabled()
    if !eligible { togglePending=false; toggleEscapeDown=false }
    if event.keyCode == 53 && event.type == .keyDown {
      if toggleEscapeDown { return nil }
      if eligible && !event.isARepeat && flags == [.maskControl,.maskAlternate] {
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
    if owner == next && router.armed && registry.isActive(id:id) && focused && !IsSecureEventInputEnabled() { return true }
    if owner != next { stop(reason:"owner-change") }
    router.reconcileReleasedKeys()
    let keysReleased = CGEventSource.flagsState(.combinedSessionState).intersection(MacOSSystemShortcutRouter.modifiers).isEmpty &&
      ![48,123,124,125,126].contains(where: { CGEventSource.keyState(.combinedSessionState,key:CGKeyCode($0)) })
    // 修改型tap以实际创建/启用结果为准；ListenEvent预检查不是此路径的必要条件。
    guard focused, !IsSecureEventInputEnabled(), AXIsProcessTrusted(), !router.hasPendingKeys, keysReleased else {
      stop(reason:"arm-gate")
      log("arm_rejected owner=\(next) focused=\(focused) secure=\(IsSecureEventInputEnabled()) ax=\(AXIsProcessTrusted()) listen=\(CGPreflightListenEventAccess()) pending=\(router.hasPendingKeys)")
      return false
    }
    owner=next
    if !registry.isActive(id:id) {
      let mask = [CGEventType.keyDown,.keyUp,.flagsChanged].reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
      guard registry.register(id:id,mask:mask,handler:{ [weak self] type,event in
        self?.handle(type,event) ?? false
      }), registry.isActive(id:id) else {
        registry.unregister(id:id)
        log("tap_failed owner=\(next) ax=\(AXIsProcessTrusted()) listen=\(CGPreflightListenEventAccess())")
        return false
      }
    }
    router.armed=true
    startHealthCheck()
    log("armed owner=\(next) tap_active=\(registry.isActive(id:id)) ax=\(AXIsProcessTrusted()) listen=\(CGPreflightListenEventAccess())")
    return true
  }
  func stop(reason: String) {
    let wasArmed=router.armed
    router.stop()
    healthTimer?.invalidate();healthTimer=nil;pendingChallenge=nil
    guard wasArmed, let owner else { return }
    log("stopped owner=\(owner) reason=\(reason) repeat_consumed=\(repeats)")
    repeats=0;emit(["owner":owner,"kind":"stopped","reason":reason])
  }
  private func handle(_ type: CGEventType,_ event: CGEvent) -> Bool {
    expireIfNeeded()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput { stop(reason:"tap-disabled");return false }
    guard type == .keyDown || type == .keyUp || type == .flagsChanged else { return false }
    if router.armed && (!focused || IsSecureEventInputEnabled() || !AXIsProcessTrusted()) { stop(reason:"native-gate") }
    if type == .flagsChanged {
      if router.armed, let owner {
        emit(["owner":owner,"kind":"key","keyCode":0,"isDown":false,
          "flags":Int(event.flags.intersection(MacOSSystemShortcutRouter.modifiers).rawValue)])
      }
      return false
    }
    let code=Int(event.getIntegerValueField(.keyboardEventKeycode))
    // 开关快捷键统一交给local monitor，关闭转发时同样可用。
    if code == 53 && toggleOwner != nil { return false }
    let down=type == .keyDown
    let repeatKey=event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    let decision=router.handle(code:code,down:down,flags:event.flags,repeatKey:repeatKey)
    switch decision {
    case .pass:return false
    case .consume:if repeatKey { repeats += 1 };return true
    case .escape:
      if let owner { log("escape owner=\(owner)"); emit(["owner":owner,"kind":"stopped","reason":"escape"]) }
      return true
    case .send:
      guard let owner else { return true }
      let vk = [48:0x09,123:0x25,124:0x27,125:0x28,126:0x26][code]!
      let flags=event.flags.intersection(MacOSSystemShortcutRouter.modifiers).rawValue
      log("capture owner=\(owner) vk=\(vk) down=\(down) flags=\(flags)")
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
  func armForTesting(owner: String) {
    self.owner=owner;router.armed=true;startHealthCheck()
  }
  func checkHealthForTesting() { checkHealth() }
  func handleForTesting(_ type: CGEventType, _ event: CGEvent) -> Bool { handle(type,event) }
#endif
}
