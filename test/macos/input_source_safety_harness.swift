import AppKit
import Foundation
@testable import hardware_simulator

// 仅mock映射读写；不触碰真实用户HID配置。执行生产恢复路径和跨实例lease保护。
@main struct SafetyHarness {
  static func main() {
    precondition(Thread.isMainThread)
    let lease = NSTemporaryDirectory() + "cpp-safety-\(UUID().uuidString).lock"
    HardwareSimulatorPlugin.macOSCapsLockRemapLeaseFilePathForTesting = lease
    defer {
      HardwareSimulatorPlugin.resetMacOSGlobeKeyProbeCapsLockRemapForTesting()
      HardwareSimulatorPlugin.macOSCapsLockRemapLeaseFilePathForTesting = nil
      try? FileManager.default.removeItem(atPath: lease)
    }
    let src = "HIDKeyboardModifierMappingSrc"
    let dst = "HIDKeyboardModifierMappingDst"
    let caps = HardwareSimulatorPlugin.macOSCapsLockHidUsageForTesting
    let f20 = HardwareSimulatorPlugin.macOSGlobeRemappedF20HidUsageForTesting
    var mapping: [[String: UInt64]] = []
    var writes = 0
    var writeAllowed = true
    let owner = HardwareSimulatorPlugin()
    owner.macOSUserKeyMappingReaderForTesting = { mapping }
    owner.macOSUserKeyMappingWriterForTesting = { value in
      writes += 1
      guard writeAllowed else { return false }
      mapping = value
      return true
    }
    owner.macOSFnUsageTypeReaderForTesting = { 1 }
    precondition(owner.enableMacOSGlobeKeyProbeCapsLockRemapForTesting())
    let afterArm = writes
    owner.checkInputSourceSafetyForTesting(eligible: true)
    precondition(writes == afterArm && mapping == [[src: caps, dst: f20]])
    let other = HardwareSimulatorPlugin()
    other.macOSUserKeyMappingReaderForTesting = { mapping }
    other.macOSUserKeyMappingWriterForTesting = { _ in preconditionFailure("Other live owner overwritten") }
    other.checkInputSourceSafetyForTesting(eligible: false)
    precondition(mapping == [[src: caps, dst: f20]])
    owner.checkInputSourceSafetyForTesting(eligible: false)
    precondition(mapping.isEmpty)
    let restoredWrites = writes
    owner.checkInputSourceSafetyForTesting(eligible: false)
    precondition(writes == restoredWrites)
    // 客户自己的Caps→F20没有我们的journal，不应自动清理。
    mapping = [[src: caps, dst: f20]]
    owner.checkInputSourceSafetyForTesting(eligible: false)
    precondition(writes == restoredWrites && !mapping.isEmpty)
    mapping = []
    precondition(owner.enableMacOSGlobeKeyProbeCapsLockRemapForTesting())
    mapping.append([src: 0x700000004, dst: 0x700000005])
    let userMapping = mapping
    owner.checkInputSourceSafetyForTesting(eligible: false)
    precondition(mapping == userMapping) // 当前用户更新优先。
    HardwareSimulatorPlugin.resetMacOSGlobeKeyProbeCapsLockRemapForTesting()
    mapping = []
    precondition(owner.enableMacOSGlobeKeyProbeCapsLockRemapForTesting())
    writeAllowed = false
    owner.checkInputSourceSafetyForTesting(eligible: false)
    precondition(HardwareSimulatorPlugin.hasMacOSGlobeKeyProbeCapsLockRemapStateForTesting)
    precondition(!mapping.isEmpty)
    writeAllowed = true
    precondition(owner.stopMacOSGlobeKeyProbeForTesting())
    precondition(mapping.isEmpty)
    print("PASS: eligible preserved; stale owner restored; other owner/custom mapping protected; idempotent; failure retained journal; retry restored")
  }
}
