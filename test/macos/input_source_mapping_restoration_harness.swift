import AppKit
import Darwin
import IOKit.hid

@testable import hardware_simulator

/// A signed standalone process for the UserKeyMapping exit-safety contract.
///
/// Unlike XCTest this runs inside the same sort of macOS application process
/// as the client. There is no Flutter engine, session, network, or remote peer.
private typealias KeyMapping = [[String: UInt64]]
private let sourceKey = "HIDKeyboardModifierMappingSrc"
private let capsLockHidUsage: UInt64 = 0x700000039

private func currentUserKeyMapping() -> KeyMapping? {
  let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
  guard let rawMapping = IOHIDEventSystemClientCopyProperty(
    client,
    "UserKeyMapping" as CFString
  ) as? [[String: NSNumber]] else {
    return nil
  }
  return rawMapping.map { item in
    Dictionary(uniqueKeysWithValues: item.map { key, value in
      (key, value.uint64Value)
    })
  }
}

private func setUserKeyMapping(_ mapping: KeyMapping) -> Bool {
  let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
  let bridged = mapping.map { item in
    Dictionary(uniqueKeysWithValues: item.map { key, value in
      (key, NSNumber(value: value))
    }) as NSDictionary
  } as NSArray
  return IOHIDEventSystemClientSetProperty(client, "UserKeyMapping" as CFString, bridged)
}

private func emit(_ outcome: String, _ reason: String) {
  let mappingDescription = String(describing: currentUserKeyMapping() ?? [])
  let fields: [String: String] = [
    "outcome": outcome,
    "reason": reason,
    "userKeyMapping": mappingDescription,
  ]
  let result = (try? JSONSerialization.data(withJSONObject: fields))
    .flatMap { String(data: $0, encoding: .utf8) }
    ?? "{\"outcome\":\"FAIL\",\"reason\":\"Could not encode test result\"}"
  FileHandle.standardOutput.write(Data((result + "\n").utf8))
  fflush(stdout)
}

private func runHarness() -> (outcome: String, reason: String) {
  guard let original = currentUserKeyMapping() else {
    return ("FAIL", "Unable to read the live UserKeyMapping")
  }
  guard !original.contains(where: { $0[sourceKey] == capsLockHidUsage }) else {
    // Product code must never overwrite a user-owned Caps Lock mapping. Do
    // not turn a developer's personal customization into a test precondition.
    return ("SKIP", "A user-owned Caps Lock mapping is already present")
  }
  let plugin = HardwareSimulatorPlugin()
  defer {
    // This second, process-local cleanup is independent of the assertion path.
    // It is intentionally retained even though the normal stream stop below
    // must restore first: a failed assertion must not strand the real keyboard.
    if currentUserKeyMapping() != original {
      _ = setUserKeyMapping(original)
    }
    HardwareSimulatorPlugin.resetMacOSGlobeKeyProbeCapsLockRemapForTesting()
  }

  guard plugin.enableMacOSGlobeKeyProbeCapsLockRemapForTesting() else {
    return ("FAIL", "Unable to arm the real Caps Lock to F20 mapping")
  }

  guard currentUserKeyMapping() != original else {
    return ("FAIL", "Arming did not change the live UserKeyMapping")
  }

  guard plugin.stopMacOSGlobeKeyProbeForTesting() else {
    return ("FAIL", "Normal stream stop did not report mapping restoration")
  }
  guard currentUserKeyMapping() == original else {
    return ("FAIL", "Normal stream stop did not restore the exact original mapping")
  }
  return ("PASS", "Normal stream stop restored the exact original UserKeyMapping")
}

let result = runHarness()
emit(result.outcome, result.reason)
exit(result.outcome == "PASS" ? EXIT_SUCCESS : result.outcome == "SKIP" ? 77 : EXIT_FAILURE)
