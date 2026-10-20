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
private let destinationKey = "HIDKeyboardModifierMappingDst"

private func currentUserKeyMapping() -> KeyMapping? {
  let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
  guard let rawMapping = IOHIDEventSystemClientCopyProperty(
    client,
    "UserKeyMapping" as CFString
  ) else {
    return []
  }
  guard let mappings = rawMapping as? NSArray else { return nil }
  return mappings.compactMap { rawItem in
    guard let rawItem = rawItem as? NSDictionary else { return nil }
    var mapping: [String: UInt64] = [:]
    for (rawKey, rawValue) in rawItem {
      guard let key = rawKey as? String, let value = rawValue as? NSNumber
      else { return nil }
      mapping[key] = value.uint64Value
    }
    return mapping
  }
}

private func mappingEntries(_ mapping: KeyMapping) -> [String] {
  mapping.map { item in
    "\(item[sourceKey] ?? 0)->\(item[destinationKey] ?? 0)"
  }.sorted()
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
    // Product code must never overwrite a user-owned Caps Lock mapping. Fn is
    // intentionally not a UserKeyMapping participant.
    return ("SKIP", "A user-owned Caps Lock mapping is already present")
  }
  let plugin = HardwareSimulatorPlugin()
  defer {
    // This second, process-local cleanup is independent of the assertion path.
    // It is intentionally retained even though the normal stream stop below
    // must restore first: a failed assertion must not strand the real keyboard.
    if currentUserKeyMapping().map(mappingEntries) != mappingEntries(original) {
      _ = setUserKeyMapping(original)
    }
    HardwareSimulatorPlugin.resetMacOSGlobeKeyProbeCapsLockRemapForTesting()
  }

  guard plugin.enableMacOSGlobeKeyProbeCapsLockRemapForTesting() else {
    return ("FAIL", "Unable to arm the real Caps Lock mapping")
  }

  guard let armedMapping = currentUserKeyMapping(),
        armedMapping.count == original.count + 1 else {
    return ("FAIL", "Arming did not add the Caps Lock UserKeyMapping entry")
  }

  guard plugin.stopMacOSGlobeKeyProbeForTesting() else {
    return ("FAIL", "Normal stream stop did not report mapping restoration")
  }
  guard currentUserKeyMapping().map(mappingEntries) == mappingEntries(original) else {
    return ("FAIL", "Normal stream stop did not restore the exact original mapping")
  }
  return ("PASS", "Normal stream stop restored the exact original UserKeyMapping")
}

let result = runHarness()
emit(result.outcome, result.reason)
exit(result.outcome == "PASS" ? EXIT_SUCCESS : result.outcome == "SKIP" ? 77 : EXIT_FAILURE)
