import AppKit

@main struct SystemShortcutHealthHarness {
  static func main() {
    _ = NSApplication.shared
    var now: TimeInterval = 10
    var events: [[String:Any]] = []
    let registry=MacOSInputCaptureRegistry()
    let capture=MacOSSystemShortcutCapture(registry:registry,view:nil,
      emit:{ events.append($0) },log:{ _ in },clock:{ now })
    capture.armForTesting(owner:"A")
    now=10.5;capture.checkHealthForTesting()
    let first=events.last!["challenge"] as! Int
    capture.acknowledge(owner:"stale",challenge:first)
    now=12;capture.checkHealthForTesting()
    precondition(events.last?["reason"] as? String == "consumer-timeout")
    let count=events.count
    capture.acknowledge(owner:"A",challenge:first)
    capture.checkHealthForTesting()
    precondition(events.count == count) // 迟到确认不能重启。
    capture.armForTesting(owner:"B")
    now=12.5;capture.checkHealthForTesting()
    let second=events.last!["challenge"] as! Int
    precondition(second != first)
    capture.acknowledge(owner:"B",challenge:second)
    now=14.4;capture.checkHealthForTesting()
    precondition(events.last?["kind"] as? String == "heartbeat")
    capture.acknowledge(owner:"B",challenge:second) // 重放旧challenge不能续期。
    now=14.5
    let event=CGEvent(keyboardEventSource:nil,virtualKey:48,keyDown:true)!
    event.flags = .maskCommand
    precondition(!capture.handleForTesting(.keyDown,event)) // event先校验期限，直接本机放行。
    precondition(events.last?["reason"] as? String == "consumer-timeout")
    print("PASS: consumer timeout, valid ack renewal, stale/replayed ack rejected, event-time fail-open")
  }
}
