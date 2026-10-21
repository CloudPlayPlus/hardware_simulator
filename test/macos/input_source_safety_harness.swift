import AppKit
import Foundation
@testable import hardware_simulator

// 仅mock映射读写；不触碰真实用户HID配置。执行生产恢复路径和跨实例lease保护。
@main struct SafetyHarness {
  static func main() {
    precondition(Thread.isMainThread)
    _ = NSApplication.shared
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
    precondition(owner.enableMacOSGlobeKeyProbeCapsLockRemapForTesting())
    owner.inputSourceTapDisabledForTesting()
    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    precondition(mapping.isEmpty && !owner.ownsMacOSGlobeKeyProbeCapsLockRemapForTesting)
    let afterDisabledWrites = writes
    // 客户自己的Caps→F20没有我们的journal，不应自动清理。
    mapping = [[src: caps, dst: f20]]
    owner.checkInputSourceSafetyForTesting(eligible: false)
    precondition(writes == afterDisabledWrites && !mapping.isEmpty)
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
    // 实际startup路径：Caps冲突不阻断纯tap能力，Caps-only不要求HID tap。
    mapping = [[src: caps, dst: 0x700000029]]
    var hidInstalls = 0
    precondition(owner.startInputCaptureForTesting(caps: true, fn: true, control: true,
      hid: { hidInstalls += 1; return true }, globe: { true }))
    precondition(hidInstalls == 1 && mapping == [[src: caps, dst: 0x700000029]])
    precondition(owner.stopMacOSGlobeKeyProbeForTesting())
    mapping = []
    precondition(owner.startInputCaptureForTesting(caps: true, fn: false, control: false,
      hid: { preconditionFailure("Caps-only must not install HID tap") }, globe: { false }))
    precondition(owner.stopMacOSGlobeKeyProbeForTesting())
    precondition(mapping.isEmpty)
    precondition(!owner.startInputCaptureForTesting(caps: false, fn: true, control: false,
      hid: { true }, globe: { false }))
    precondition(owner.startInputCaptureForTesting(caps: true, fn: true, control: true,
      hid: { false }, globe: { preconditionFailure("Failed HID path must not install Globe") }))
    precondition(mapping == [[src: caps, dst: f20]])
    precondition(owner.stopMacOSGlobeKeyProbeForTesting())
    precondition(mapping.isEmpty)
    precondition(!owner.startInputCaptureForTesting(caps: false, fn: true, control: true,
      hid: { false }, globe: { false }))
    print("PASS: eligible preserved; stale owner restored; other owner/custom mapping protected; idempotent; failure retained journal; retry restored")
  }
}
