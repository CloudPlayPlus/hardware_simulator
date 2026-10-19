import AppKit
import Carbon.HIToolbox
import Foundation

/// A real, separately-running AppKit input client used by the local
/// cross-process IME integration test. Its NSTextView is deliberately not in
/// the process that constructs the injected CGEvents.
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

private func selectInputSource(_ expectedID: String) -> Bool {
  let filter = [
    kTISPropertyInputSourceCategory: kTISCategoryKeyboardInputSource,
  ] as CFDictionary
  let sources = TISCreateInputSourceList(filter, false)
    .takeRetainedValue() as NSArray
  guard let inputSource = sources
    .map({ $0 as! TISInputSource })
    .first(where: { inputSourceID($0) == expectedID })
  else {
    return false
  }
  return TISSelectInputSource(inputSource) == noErr
}

private final class CrossProcessTarget: NSObject, NSApplicationDelegate,
  NSTextViewDelegate {
  private let stateURL: URL
  private let selectedInputSourceID: String
  private let textView = NSTextView(frame: .zero)
  private var window: NSWindow?
  private var sourcePollTimer: Timer?
  private var textInputObserver: NSObjectProtocol?

  init(stateURL: URL, selectedInputSourceID: String) {
    self.stateURL = stateURL
    self.selectedInputSourceID = selectedInputSourceID
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    textView.isEditable = true
    textView.isRichText = false
    textView.delegate = self
    textView.string = ""

    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 240),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false
    )
    window.title = "CloudPlayPlus cross-process IME target"
    window.contentView = textView
    self.window = window
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    window.makeFirstResponder(textView)

    let selectedSource = selectInputSource(selectedInputSourceID)

    // Capture the input-method context that AppKit installs for this focused
    // text client. A production remote Host needs the same per-target session;
    // observing it here gives the companion injector a concrete context token.
    textInputObserver = NotificationCenter.default.addObserver(
      forName: NSTextInputContext.keyboardSelectionDidChangeNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.writeState(status: selectedSource ? "ready" : "missing_source")
    }

    writeState(status: selectedSource ? "ready" : "missing_source")
    sourcePollTimer = Timer.scheduledTimer(
      withTimeInterval: 0.05,
      repeats: true
    ) { [weak self] _ in
      self?.writeState(status: selectedSource ? "ready" : "missing_source")
    }
  }

  func textDidChange(_ notification: Notification) {
    writeState(status: "ready")
  }

  func applicationWillTerminate(_ notification: Notification) {
    sourcePollTimer?.invalidate()
    if let textInputObserver {
      NotificationCenter.default.removeObserver(textInputObserver)
    }
    writeState(status: "stopped")
  }

  private func writeState(status: String) {
    let fields: [String: String] = [
      "status": status,
      "inputSource": currentInputSourceID() ?? "unknown",
      "text": textView.string,
      "pid": String(ProcessInfo.processInfo.processIdentifier),
    ]
    guard
      let data = try? JSONSerialization.data(withJSONObject: fields),
      let text = String(data: data, encoding: .utf8)
    else {
      return
    }
    try? text.write(to: stateURL, atomically: true, encoding: .utf8)
  }
}

guard CommandLine.arguments.count == 3 else {
  fputs("Expected a state-file path and target input-source ID.\n", stderr)
  exit(EX_USAGE)
}

private let app = NSApplication.shared
private let delegate = CrossProcessTarget(
  stateURL: URL(fileURLWithPath: CommandLine.arguments[1]),
  selectedInputSourceID: CommandLine.arguments[2]
)
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
