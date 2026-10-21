import AppKit

/// 会话内原生事件入口：按ID注册/注销，handler同步返回是否消费。
/// 不知道远端协议、键位映射或业务优先级；具体规则仍由调用方提供。
final class MacOSInputCaptureRegistry {
  typealias Handler = (CGEventType, CGEvent) -> Bool
  private final class Entry {
    let handler: Handler
    var tap: CFMachPort?
    var source: CFRunLoopSource?
    init(_ handler: @escaping Handler) { self.handler = handler }
    func close() {
      if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
      if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
      tap = nil
      source = nil
    }
    deinit { close() }
  }
  private var entries: [String: Entry] = [:]

  @discardableResult
  func register(id: String, processID: pid_t? = nil, mask: CGEventMask,
                handler: @escaping Handler) -> Bool {
    precondition(Thread.isMainThread)
    unregister(id: id)
    let entry = Entry(handler)
    let context = Unmanaged.passUnretained(entry).toOpaque()
    let callback: CGEventTapCallBack = { _, type, event, context in
      guard let context else { return Unmanaged.passUnretained(event) }
      let entry = Unmanaged<Entry>.fromOpaque(context).takeUnretainedValue()
      return entry.handler(type, event) ? nil : Unmanaged.passUnretained(event)
    }
    let tap: CFMachPort?
    if let processID {
      tap = CGEvent.tapCreateForPid(pid: processID, place: .headInsertEventTap,
        options: .defaultTap, eventsOfInterest: mask, callback: callback, userInfo: context)
    } else {
      tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
        options: .defaultTap, eventsOfInterest: mask, callback: callback, userInfo: context)
    }
    guard let tap else { return false }
    entry.tap = tap
    guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return false }
    entry.source = source
    entries[id] = entry
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
  }

  func isActive(id: String) -> Bool {
    guard let tap = entries[id]?.tap else { return false }
    return CFMachPortIsValid(tap) && CGEvent.tapIsEnabled(tap: tap)
  }

  func unregister(id: String) {
    entries.removeValue(forKey: id)?.close()
  }

  func unregisterAll() {
    for entry in entries.values { entry.close() }
    entries.removeAll()
  }
  deinit { unregisterAll() }
}
