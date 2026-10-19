import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Darwin

@testable import hardware_simulator

/// A signed, standalone AppKit process for the macOS Host input-source path.
///
/// XCTest is intentionally not used here: input methods need a real key AppKit
/// application, a focused NSTextView, and the same code-signing/TCC identity as
/// the desktop client. This harness has no networking, DataChannel, or remote
/// peer; its only purpose is local integration verification of the native Host
/// executor plus the production keyboard-injection method.
private let pinyinInputSourceID = "com.apple.inputmethod.SCIM.ITABC"
private let abcInputSourceID = "com.apple.keylayout.ABC"
private let expectedCommittedText = "你好"
private let expectedCapsLockText = "Ab"

private enum HarnessOutcome: String {
  case passed = "PASS"
  case skipped = "SKIP"
  case failed = "FAIL"
}

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

private func selectableKeyboardInputSources() -> [TISInputSource] {
  let filter = [
    kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource,
  ] as CFDictionary
  let sourceList = TISCreateInputSourceList(filter, false)
    .takeRetainedValue() as NSArray
  return sourceList.map { $0 as! TISInputSource }.filter { source in
    guard
      let enabledValue = TISGetInputSourceProperty(
        source,
        kTISPropertyInputSourceIsEnabled
      ),
      let selectableValue = TISGetInputSourceProperty(
        source,
        kTISPropertyInputSourceIsSelectCapable
      )
    else {
      return false
    }
    let enabled = Unmanaged<CFBoolean>
      .fromOpaque(enabledValue)
      .takeUnretainedValue()
    let selectable = Unmanaged<CFBoolean>
      .fromOpaque(selectableValue)
      .takeUnretainedValue()
    return CFBooleanGetValue(enabled) && CFBooleanGetValue(selectable)
  }
}

private func waitForCurrentInputSource(
  _ expectedID: String,
  timeout: TimeInterval = 1
) -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  repeat {
    if currentInputSourceID() == expectedID {
      return true
    }
    RunLoop.current.run(
      mode: .default,
      before: Date().addingTimeInterval(0.005)
    )
  } while Date() < deadline
  return false
}

private final class InputSourceIntegrationHarness: NSObject, NSApplicationDelegate {
  private let plugin = HardwareSimulatorPlugin()
  private let textView = NSTextView(frame: .zero)
  private let windowsKeyCodes = [0x4E, 0x49, 0x48, 0x41, 0x4F, 0x20]
  private let capsLockKeyCodes = [0x14, 0x41, 0x14, 0x42]
  private var originalInputSource: TISInputSource?
  private var originalInputSourceID: String?
  private var testWindow: NSWindow?
  private var completed = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Do not request or persist any TCC consent. A missing grant is an
    // environment prerequisite, not a reason for a test to pop a permission
    // dialog on a developer's workstation.
    guard CGPreflightPostEventAccess() else {
      finish(
        .skipped,
        reason: "Post Event permission is not already granted to this signed app"
      )
      return
    }

    originalInputSource = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
    guard
      let originalInputSource,
      let originalInputSourceID = inputSourceID(originalInputSource)
    else {
      finish(.failed, reason: "Unable to snapshot the current keyboard input source")
      return
    }
    self.originalInputSourceID = originalInputSourceID

    let sources = selectableKeyboardInputSources()
    guard
      let pinyinIndex = sources.firstIndex(where: {
        inputSourceID($0) == pinyinInputSourceID
      }),
      sources.count > 1
    else {
      finish(
        .skipped,
        reason: "Simplified Pinyin is not an enabled, selectable keyboard input source"
      )
      return
    }

    // Put the Pinyin source immediately after the current source. The actual
    // plugin executor must then select it and complete its own confirmation
    // barrier before the real CGEvent key sequence begins.
    let predecessorIndex = (pinyinIndex + sources.count - 1) % sources.count
    let predecessor = sources[predecessorIndex]
    guard
      TISSelectInputSource(predecessor) == noErr,
      let predecessorID = inputSourceID(predecessor),
      waitForCurrentInputSource(predecessorID)
    else {
      finish(.failed, reason: "Unable to prepare the source immediately before Pinyin")
      return
    }
    guard plugin.selectNextMacOSInputSourceInProcessForTesting() else {
      finish(.failed, reason: "Plugin did not confirm selection of the next input source")
      return
    }
    guard currentInputSourceID() == pinyinInputSourceID else {
      finish(.failed, reason: "Plugin confirmed a source other than Simplified Pinyin")
      return
    }

    guard sources.contains(where: { inputSourceID($0) == abcInputSourceID }) else {
      finish(.skipped, reason: "ABC is not an enabled, selectable keyboard input source")
      return
    }

    textView.isEditable = true
    textView.isRichText = false
    textView.string = ""
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 480, height: 220),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = "CloudPlayPlus local IME integration verification"
    window.contentView = textView
    testWindow = window
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    window.makeFirstResponder(textView)

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
      self?.sendKey(at: 0)
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    _ = restoreOriginalInputSource()
  }

  private func sendKey(at index: Int) {
    guard index < windowsKeyCodes.count else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
        guard let self else { return }
        self.verifyPinyinCommitThenRunCapsLockCheck()
      }
      return
    }

    let keyCode = windowsKeyCodes[index]
    plugin.PerformKeyEvent(code: keyCode, isDown: true)
    plugin.PerformKeyEvent(code: keyCode, isDown: false)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
      self?.sendKey(at: index + 1)
    }
  }

  private func verifyPinyinCommitThenRunCapsLockCheck() {
    let committedText = textView.string
    guard committedText == expectedCommittedText else {
      finish(
        .failed,
        reason: "Input method did not commit the expected text",
        committedText: committedText
      )
      return
    }
    guard
      let abc = selectableKeyboardInputSources().first(where: {
        inputSourceID($0) == abcInputSourceID
      }),
      TISSelectInputSource(abc) == noErr,
      waitForCurrentInputSource(abcInputSourceID)
    else {
      finish(.failed, reason: "Unable to select ABC for the real Caps Lock check")
      return
    }
    textView.string = ""
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
      self?.sendCapsLockKey(at: 0)
    }
  }

  private func sendCapsLockKey(at index: Int) {
    guard index < capsLockKeyCodes.count else {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
        guard let self else { return }
        let capsLockText = self.textView.string
        self.finish(
          capsLockText == expectedCapsLockText ? .passed : .failed,
          reason: capsLockText == expectedCapsLockText
            ? "Pinyin commit and ABC Caps Lock output both used the plugin CGEvent path"
            : "ABC Caps Lock state did not produce the expected mixed-case text",
          committedText: "pinyin=\(expectedCommittedText); abcCaps=\(capsLockText)"
        )
      }
      return
    }
    let keyCode = capsLockKeyCodes[index]
    plugin.PerformKeyEvent(code: keyCode, isDown: true)
    plugin.PerformKeyEvent(code: keyCode, isDown: false)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
      self?.sendCapsLockKey(at: index + 1)
    }
  }

  private func restoreOriginalInputSource() -> Bool {
    guard
      let originalInputSource,
      let originalInputSourceID
    else {
      return true
    }
    guard TISSelectInputSource(originalInputSource) == noErr else {
      return false
    }
    return waitForCurrentInputSource(originalInputSourceID)
  }

  private func finish(
    _ outcome: HarnessOutcome,
    reason: String,
    committedText: String? = nil
  ) {
    guard !completed else { return }
    completed = true
    let restoredOriginalInputSource = restoreOriginalInputSource()
    testWindow?.close()

    let finalOutcome: HarnessOutcome
    let finalReason: String
    if !restoredOriginalInputSource {
      finalOutcome = .failed
      finalReason = "Could not restore the original keyboard input source after local test"
    } else {
      finalOutcome = outcome
      finalReason = reason
    }

    var fields = [
      "outcome": finalOutcome.rawValue,
      "reason": finalReason,
      "currentInputSource": currentInputSourceID() ?? "unknown",
    ]
    if let committedText {
      fields["committedText"] = committedText
    }
    let result = (try? JSONSerialization.data(withJSONObject: fields))
      .flatMap { String(data: $0, encoding: .utf8) }
      ?? "{\"outcome\":\"FAIL\",\"reason\":\"Could not encode test result\"}"
    FileHandle.standardOutput.write(Data((result + "\n").utf8))
    fflush(stdout)
    exit(
      finalOutcome == .passed
        ? EXIT_SUCCESS
        : finalOutcome == .skipped ? 77 : EXIT_FAILURE
    )
  }
}

private let app = NSApplication.shared
private let delegate = InputSourceIntegrationHarness()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
