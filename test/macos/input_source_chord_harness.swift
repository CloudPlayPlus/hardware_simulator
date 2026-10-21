import CoreGraphics
import Foundation

@main struct ChordHarness {
  static func main() {
    var gate = MacOSGlobeProcessGate()
    assert(!gate.consume(type: 14, subtype: 6, data1: 4, now: 0))
    gate.completedFn(now: 1)
    assert(!gate.cancelForNewAction(type: .flagsChanged, flags: []))
    assert(!gate.cancelForNewAction(type: .keyUp, flags: []))
    // R11 实际失败顺序：独立 Fn 已结束，紧接无修饰 keyDown，再收到切源事件对。
    assert(!gate.cancelForNewAction(type: .keyDown, flags: []))
    assert(!gate.consume(type: 14, subtype: 9, data1: 4, now: 1.01))
    assert(!gate.consume(type: 14, subtype: 6, data1: 5, now: 1.01))
    assert(!gate.consume(type: 21, subtype: 6, data1: 4, now: 1.01))
    assert(gate.consume(type: 14, subtype: 6, data1: 4, now: 1.01))
    assert(!gate.consume(type: 14, subtype: 6, data1: 4, now: 1.02))
    assert(gate.consume(type: 14, subtype: 9, data1: 4, now: 1.03))
    assert(!gate.consume(type: 14, subtype: 6, data1: 4, now: 1.04))
    gate.completedFn(now: 2)
    assert(!gate.consume(type: 14, subtype: 6, data1: 4, now: 2.151))
    gate.completedFn(now: 3)
    gate.reset()
    assert(!gate.consume(type: 14, subtype: 6, data1: 4, now: 3.01))
    for (type, flags): (CGEventType, CGEventFlags) in [
      (.keyDown, .maskControl), (.leftMouseDown, []), (.flagsChanged, .maskSecondaryFn), (.flagsChanged, .maskControl)
    ] {
      gate.completedFn(now: 4)
      assert(gate.cancelForNewAction(type: type, flags: flags))
      assert(!gate.consume(type: 14, subtype: 6, data1: 4, now: 4.01))
    }
    var router = MacOSInputSourceChordRouter()
    func event(_ type: CGEventType, _ code: Int, _ flags: CGEventFlags = [], fn: Bool = true, control: Bool = true) -> MacOSInputSourceChordRouter.Decision {
      router.handle(type: type, code: code, flags: flags, captureFn: fn, captureControlSpace: control)
    }
    assert(event(.flagsChanged, 63, .maskSecondaryFn).consume)
    assert(event(.flagsChanged, 63).intent == "fn")
    // 系统诊断事件只旁观：不取消 pending Fn，也不误吞已按住的 Space。
    _ = event(.flagsChanged, 63, .maskSecondaryFn)
    assert(!event(MacOSInputSourceChordRouter.systemDefinedType, 0).consume)
    assert(event(.flagsChanged, 63).intent == "fn")
    assert(event(.flagsChanged, 63).intent == nil) // 重复 up 不得再次切换。
    _ = event(.flagsChanged, 63, .maskSecondaryFn)
    assert(event(.flagsChanged, 63, .maskSecondaryFn).intent == nil)
    assert(event(.flagsChanged, 63).intent == "fn") // 重复 down 仍只产生一次。
    _ = event(.flagsChanged, 63, .maskSecondaryFn)
    assert(!event(.keyDown, 123, .maskSecondaryFn).consume)
    assert(event(.flagsChanged, 63).intent == nil)
    _ = event(.flagsChanged, 63, .maskSecondaryFn)
    assert(!event(.leftMouseDown, 0, .maskSecondaryFn).consume)
    assert(event(.flagsChanged, 63).intent == nil)
    _ = event(.flagsChanged, 63, [.maskSecondaryFn, .maskCommand])
    assert(event(.flagsChanged, 63, .maskCommand).intent == nil)
    assert(!event(.flagsChanged, 59, .maskControl).consume)
    assert(event(.keyDown, 49, .maskControl).intent == "control_space")
    assert(!event(MacOSInputSourceChordRouter.systemDefinedType, 49).consume)
    assert(event(.keyDown, 49, .maskControl).intent == nil)
    assert(event(.keyUp, 49).consume)
    assert(!event(.flagsChanged, 59).consume)
    assert(!event(.keyDown, 0, .maskControl).consume)
    assert(!event(.keyDown, 49, [.maskControl, .maskShift]).consume)
    assert(!event(.keyDown, 49, .maskControl, control: false).consume)
    assert(!event(.flagsChanged, 63, .maskSecondaryFn, fn: false).consume)
    _ = event(.flagsChanged, 63, .maskSecondaryFn)
    router.reset()
    assert(event(.flagsChanged, 63).intent == nil)
    print("PASS: Fn tap/chord, Control+Space/repeat/release, extra modifiers, disabled config, focus reset")
  }
}
