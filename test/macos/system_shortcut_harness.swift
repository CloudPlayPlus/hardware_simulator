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
    precondition(router.handle(code:53, down:true, flags:[.maskControl,.maskAlternate], repeatKey:false) == .escape)
    precondition(!router.armed)
    precondition(router.handle(code:53, down:false, flags:[], repeatKey:false) == .consume)
    precondition(MacOSSystemShortcutRouter.hostFlags(code:126, flags:.maskControl).contains(.maskSecondaryFn))
    precondition(!MacOSSystemShortcutRouter.hostFlags(code:126, flags:[.maskControl,.maskShift]).contains(.maskSecondaryFn))
    precondition(!MacOSSystemShortcutRouter.hostFlags(code:14, flags:.maskControl).contains(.maskSecondaryFn))
    print("PASS: system shortcut matching, repeat, tail, escape, modifier release, host flags")
  }
}
