import CoreGraphics

/// 实测 Globe 在进程 tap 表示中的事件对；只限刚完成的独立 Fn。
struct MacOSGlobeProcessGate {
  private var deadline: Double?
  private var downConsumed = false
  var isPending: Bool { deadline != nil }
  mutating func cancelForNewAction(type: CGEventType, flags: CGEventFlags) -> Bool {
    let modifiers = flags.intersection([.maskSecondaryFn, .maskControl, .maskCommand, .maskAlternate, .maskShift])
    let cancel = type == .leftMouseDown || type == .rightMouseDown ||
      ((type == .flagsChanged || type == .keyDown) && !modifiers.isEmpty)
    let wasPending = isPending
    if cancel { reset() }
    return cancel && wasPending
  }
  mutating func reset() { self = Self() }
  mutating func completedFn(now: Double) {
    deadline = now + 0.15
    downConsumed = false
  }
  mutating func consume(type: UInt32, subtype: Int, data1: Int, now: Double) -> Bool {
    guard let deadline, now <= deadline else { reset(); return false }
    guard type == 14, data1 == 4 else { return false }
    if subtype == 6 && !downConsumed { downConsumed = true; return true }
    if subtype == 9 && downConsumed { reset(); return true }
    return false
  }
}

/// 仅识别两种输入源动作；不改变系统配置，不模拟普通键。
struct MacOSInputSourceChordRouter {
  // IOLLEvent.h NX_SYSDEFINED / NSEventTypeSystemDefined；CGEventType 没有命名项。
  static let systemDefinedType = CGEventType(rawValue: 14)!
  struct Decision {
    var consume = false
    var intent: String? = nil
  }
  private var fnDown = false
  private var fnCombined = false
  private var spaceConsumed = false

  mutating func reset() { self = Self() }

  mutating func handle(type: CGEventType, code: Int, flags: CGEventFlags,
                       captureFn: Bool, captureControlSpace: Bool) -> Decision {
    if type == Self.systemDefinedType { return Decision() }
    let modifiers = flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift, .maskSecondaryFn])
    if captureFn && type == .flagsChanged && code == 63 {
      if flags.contains(.maskSecondaryFn) {
        if !fnDown {
          fnDown = true
          fnCombined = !modifiers.subtracting(.maskSecondaryFn).isEmpty
        }
        return Decision(consume: !fnCombined)
      }
      let tap = fnDown && !fnCombined
      fnDown = false
      fnCombined = false
      return Decision(consume: tap, intent: tap ? "fn" : nil)
    }
    // Fn 按住期间任何其它键（含鼠标）都取消“单独 Fn”。
    if fnDown && type != .keyUp { fnCombined = true }
    if code == 49 {
      if spaceConsumed {
        if type == .keyUp { spaceConsumed = false }
        return Decision(consume: true)
      }
      if captureControlSpace && type == .keyDown && modifiers == .maskControl {
        spaceConsumed = true
        return Decision(consume: true, intent: "control_space")
      }
    }
    return Decision()
  }
}
