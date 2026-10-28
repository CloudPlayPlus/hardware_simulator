import AppKit

@main struct SystemShortcutHealthHarness {
  static func main() {
    _ = NSApplication.shared
    var now: TimeInterval = 10
    var events: [[String:Any]] = []
    var healthy = true
    let registry=MacOSInputCaptureRegistry()
    let capture=MacOSSystemShortcutCapture(registry:registry,view:nil,
      emit:{ events.append($0) },log:{ _ in },clock:{ now })
    capture.healthCheckForTesting = { healthy }
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
    // 停止必须真的注销入口，不能仅修改armed。
    capture.armForTesting(owner:"C")
    precondition(registry.containsForTesting(id:"system-shortcuts"))
    capture.stop(reason:"binding-stop")
    precondition(!registry.containsForTesting(id:"system-shortcuts"))
    capture.armForTesting(owner:"D", pressedCode:48)
    capture.stop(reason:"binding-stop")
    precondition(registry.containsForTesting(id:"system-shortcuts"))
    let up=CGEvent(keyboardEventSource:nil,virtualKey:48,keyDown:false)!
    precondition(capture.handleForTesting(.keyUp,up))
    precondition(!registry.containsForTesting(id:"system-shortcuts"))
    capture.armForTesting(owner:"E", pressedCode:126)
    capture.stop(reason:"binding-stop")
    now += 2
    capture.checkHealthForTesting()
    precondition(!registry.containsForTesting(id:"system-shortcuts"))
    // 已停止但仍有尾部时撤权，同样立即撤销入口。
    capture.armForTesting(owner:"F", pressedCode:126)
    capture.stop(reason:"binding-stop")
    capture.stop(reason:"permission-revoked", discardPending:true)
    precondition(!registry.containsForTesting(id:"system-shortcuts"))
    precondition(!capture.handleForTesting(.keyUp,up))
    capture.armForTesting(owner:"G", pressedCode:48)
    precondition(!capture.handleForTesting(.tapDisabledByTimeout,up))
    precondition(!registry.containsForTesting(id:"system-shortcuts"))
    capture.armForTesting(owner:"H", pressedCode:48)
    healthy=false
    capture.checkHealthForTesting()
    precondition(events.last?["reason"] as? String == "capture-unavailable")
    precondition(!registry.containsForTesting(id:"system-shortcuts"))
    print("PASS: consumer timeout, valid ack renewal, stale/replayed ack rejected, event-time fail-open")
  }
}
