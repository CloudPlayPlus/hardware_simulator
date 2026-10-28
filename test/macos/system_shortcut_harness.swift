import AppKit

@main struct SystemShortcutHarness {
  static func main() {
    precondition(MacOSSystemShortcutRouter.matches(code: 48, flags: .maskCommand))
    precondition(MacOSSystemShortcutRouter.matches(code: 48, flags: [.maskCommand, .maskShift]))
    precondition(!MacOSSystemShortcutRouter.matches(code: 48, flags: [.maskCommand, .maskAlternate]))
    precondition(!MacOSSystemShortcutRouter.matches(code: 48, flags: [.maskCommand, .maskSecondaryFn]))
    for code in [123,124,125,126] {
      precondition(MacOSSystemShortcutRouter.matches(code: code, flags: [.maskControl, .maskSecondaryFn]))
      precondition(!MacOSSystemShortcutRouter.matches(code: code, flags: [.maskControl, .maskShift]))
    }
    let router = MacOSSystemShortcutRouter()
    for code in [48,123,124,125,126] {
      let stopped = MacOSSystemShortcutRouter()
      let flags: CGEventFlags = code == 48 ? .maskCommand : .maskControl
      stopped.armed = true
      precondition(stopped.handle(code:code,down:true,flags:flags,repeatKey:false) == .send)
      stopped.stop()
      precondition(stopped.handle(code:code,down:true,flags:flags,repeatKey:true) == .consume)
      // 旧up丢失后第一次新按下就必须放行，不只是第二次。
      precondition(stopped.handle(code:code,down:true,flags:flags,repeatKey:false) == .pass)
      precondition(stopped.handle(code:code,down:false,flags:[],repeatKey:false) == .pass)
      precondition(!stopped.hasPendingKeys)
    }
    precondition(router.handle(code:48, down:false, flags:.maskCommand, repeatKey:false) == .pass)
    router.armed = true
    precondition(router.handle(code:48, down:true, flags:.maskCommand, repeatKey:true) == .pass)
    precondition(router.handle(code:48, down:true, flags:.maskCommand, repeatKey:false) == .send)
    precondition(router.handle(code:48, down:true, flags:.maskCommand, repeatKey:true) == .consume)
    router.stop()
    precondition(router.handle(code:48, down:true, flags:.maskCommand, repeatKey:true) == .consume)
    precondition(router.handle(code:48, down:false, flags:[], repeatKey:false) == .consume)
    precondition(router.handle(code:48, down:false, flags:[], repeatKey:false) == .pass)
    router.armed = true
    precondition(router.handle(code:126, down:true, flags:.maskControl, repeatKey:false) == .send)
    precondition(router.handle(code:126, down:false, flags:[], repeatKey:false) == .send)
    // 切换开关由本地monitor处理，router不再实现第二套单向释放。
    precondition(router.handle(code:53, down:true, flags:[.maskControl,.maskAlternate], repeatKey:false) == .pass)
    precondition(MacOSSystemShortcutRouter.hostFlags(code:126, flags:.maskControl).contains(.maskSecondaryFn))
    precondition(!MacOSSystemShortcutRouter.hostFlags(code:126, flags:[.maskControl,.maskShift]).contains(.maskSecondaryFn))
    precondition(!MacOSSystemShortcutRouter.hostFlags(code:14, flags:.maskControl).contains(.maskSecondaryFn))
    print("PASS: system shortcut matching, repeat, tail, modifier release, host flags")
  }
}
