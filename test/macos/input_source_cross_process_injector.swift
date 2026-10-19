import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Darwin

@testable import hardware_simulator

/// Owns the production Host executor and keyboard injection while the focused
/// NSTextView lives in a separate target process. This proves that the system
/// input-source action enters the target application's real IME context.
private let pinyinInputSourceID = "com.apple.inputmethod.SCIM.ITABC"

private func inputSourceID(_ source: TISInputSource) -> String? {
  guard let rawID = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
  else {
    return nil
  }
  return Unmanaged<CFString>.fromOpaque(rawID).takeUnretainedValue() as String
}

private func currentInputSourceID() -> String? {
  inputSourceID(TISCopyCurrentKeyboardInputSource().takeRetainedValue())
}

private final class CrossProcessInjector: NSObject, NSApplicationDelegate {
  private let targetPID: pid_t
  private var plugin: HardwareSimulatorPlugin?
  private let windowsKeyCodes = [0x4E, 0x49, 0x48, 0x41, 0x4F, 0x20]
  private var finished = false

  init(targetPID: pid_t) {
    self.targetPID = targetPID
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard CGPreflightPostEventAccess() else {
      finish(code: 77, reason: "Post Event permission is not granted")
      return
    }
    guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID
    else {
      finish(code: 1, reason: "Cross-process target lost frontmost focus")
      return
    }

    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let plugin = HardwareSimulatorPlugin()
      DispatchQueue.main.async {
        guard let self else { return }
        self.plugin = plugin
        self.selectThenInject()
      }
    }
  }

  private func selectThenInject() {
    guard let plugin else {
      finish(code: 1, reason: "Plugin did not initialize")
      return
    }
    guard plugin.selectNextMacOSInputSourceForFocusedTargetForTesting() else {
      finish(code: 1, reason: "Next-input-source action failed")
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      guard let self else { return }
      guard currentInputSourceID() == pinyinInputSourceID else {
        self.finish(
          code: 1,
          reason: "Next-input-source action did not select Simplified Pinyin"
        )
        return
      }
      self.sendKey(at: 0)
    }
  }

  private func sendKey(at index: Int) {
    guard index < windowsKeyCodes.count else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
        self?.finish(code: 0, reason: "Injected nihao<Space> with target still focused")
      }
      return
    }
    let keyCode = windowsKeyCodes[index]
    plugin?.PerformKeyEvent(code: keyCode, isDown: true)
    plugin?.PerformKeyEvent(code: keyCode, isDown: false)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
      self?.sendKey(at: index + 1)
    }
  }

  private func finish(code: Int32, reason: String) {
    guard !finished else { return }
    finished = true
    let outcome = code == 0 ? "PASS" : code == 77 ? "SKIP" : "FAIL"
    print("{\"outcome\":\"\(outcome)\",\"reason\":\"\(reason)\"}")
    fflush(stdout)
    exit(code)
  }
}

guard CommandLine.arguments.count == 2,
      let targetPID = pid_t(CommandLine.arguments[1])
else {
  fputs("Expected one target PID.\n", stderr)
  exit(EX_USAGE)
}

private let app = NSApplication.shared
private let delegate = CrossProcessInjector(targetPID: targetPID)
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
