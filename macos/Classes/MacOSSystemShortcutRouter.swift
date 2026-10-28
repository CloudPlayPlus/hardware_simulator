import AppKit

/// 仅识别当前支持的系统组合；按下归属与抬起消费保持成对。
final class MacOSSystemShortcutRouter {
  enum Decision { case pass, consume, send, escape }
  static let modifiers: CGEventFlags = [.maskCommand,.maskControl,.maskShift,.maskAlternate]
  var armed = false
  private var pressed = Set<Int>()
  private var tails = Set<Int>()
  var hasPendingKeys: Bool { !pressed.isEmpty || !tails.isEmpty }
  static func matches(code: Int, flags: CGEventFlags) -> Bool {
    let chord = flags.intersection(modifiers)
    if code == 48 {
      return !flags.contains(.maskSecondaryFn) && (chord == .maskCommand || chord == [.maskCommand,.maskShift])
    }
    return [123,124,125,126].contains(code) && chord == .maskControl
  }
  static func hostFlags(code: Int, flags: CGEventFlags) -> CGEventFlags {
    var result = flags
    result.remove([.maskSecondaryFn,.maskNumericPad])
    if [123,124,125,126].contains(code), result.intersection(modifiers) == .maskControl {
      result.insert(.maskSecondaryFn)
    }
    return result
  }
  func stop() { armed = false; tails.formUnion(pressed); pressed.removeAll() }
  func reconcileReleasedKeys() {
    tails = Set(tails.filter { CGEventSource.keyState(.combinedSessionState, key: CGKeyCode($0)) })
  }
  func handle(code: Int, down: Bool, flags: CGEventFlags, repeatKey: Bool) -> Decision {
    if tails.contains(code) {
      if down && !repeatKey {
        // 新按下意味着旧up已丢失；不能把本机的新按键当作旧尾部。
        tails.remove(code)
      } else {
        if !down { tails.remove(code) }
        return .consume
      }
    }
    if down && armed && code == 53 && flags.intersection(Self.modifiers) == [.maskControl,.maskAlternate] {
      stop(); tails.insert(code); return .escape
    }
    if !down { return pressed.remove(code) != nil ? .send : .pass }
    if pressed.contains(code) { return .consume } // Host既有repeat机制负责长按。
    guard armed, !repeatKey, Self.matches(code:code,flags:flags) else { return .pass }
    pressed.insert(code); return .send
  }
}
