import AppKit

// 本机可选真实tap回归，仅向本进程投递无文本系统事件。
@main struct RegistryHarness {
  static func main() {
    _ = NSApplication.shared
    let registry = MacOSInputCaptureRegistry()
    var first = 0
    var second = 0
    let pid = ProcessInfo.processInfo.processIdentifier
    func sendMarker() {
      NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
        subtype: 6, data1: 0x435050, data2: 0)?.cgEvent?.postToPid(pid)
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    precondition(registry.register(id: "test", processID: pid, mask: 1 << 14) { _, _ in first += 1; return true })
    precondition(registry.isActive(id: "test"))
    sendMarker()
    precondition(first == 1)
    precondition(registry.register(id: "test", processID: pid, mask: 1 << 14) { _, _ in second += 1; return false })
    sendMarker()
    precondition(first == 1 && second == 1) // 同ID替换，旧callback不再执行。
    registry.unregister(id: "test")
    registry.unregister(id: "test")
    sendMarker()
    precondition(!registry.isActive(id: "test") && second == 1)
    registry.unregisterAll()
    print("PASS: register/consume, replace/pass, unregister/idempotence")
  }
}
