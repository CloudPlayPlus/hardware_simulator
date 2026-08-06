import FlutterMacOS
import Cocoa
import XCTest

@testable import hardware_simulator

// This demonstrates a simple unit test of the Swift portion of this plugin's implementation.
//
// See https://developer.apple.com/documentation/xctest for more information about using XCTest.

class RunnerTests: XCTestCase {

  func testGetPlatformVersion() {
    let plugin = HardwareSimulatorPlugin()

    let call = FlutterMethodCall(methodName: "getPlatformVersion", arguments: [])

    let resultExpectation = expectation(description: "result block must be called.")
    plugin.handle(call) { result in
      XCTAssertEqual(result as! String,
                     "macOS " + ProcessInfo.processInfo.operatingSystemVersionString)
      resultExpectation.fulfill()
    }
    waitForExpectations(timeout: 1)
  }

  func testTrackpadPointDeltaUsesLogicalInverseAtOneToOneScale() {
    XCTAssertEqual(HardwareSimulatorPlugin.nativeTrackpadPointDelta(-30), 30)
    XCTAssertEqual(HardwareSimulatorPlugin.nativeTrackpadPointDelta(30), -30)
    XCTAssertEqual(HardwareSimulatorPlugin.nativeTrackpadPointDelta(-0.1), 1)
    XCTAssertEqual(HardwareSimulatorPlugin.nativeTrackpadPointDelta(0.1), -1)
    XCTAssertEqual(HardwareSimulatorPlugin.nativeTrackpadPointDelta(0), 0)
    XCTAssertNil(HardwareSimulatorPlugin.nativeTrackpadPointDelta(.nan))
  }

  func testCursorMonitorIncludesButtonTransitions() {
    let plugin = HardwareSimulatorPlugin()

    XCTAssertTrue(plugin.cursorMonitorMask.contains(.leftMouseDown))
    XCTAssertTrue(plugin.cursorMonitorMask.contains(.leftMouseUp))
    XCTAssertTrue(plugin.cursorMonitorMask.contains(.rightMouseDown))
    XCTAssertTrue(plugin.cursorMonitorMask.contains(.rightMouseUp))
    XCTAssertTrue(plugin.cursorMonitorMask.contains(.otherMouseDown))
    XCTAssertTrue(plugin.cursorMonitorMask.contains(.otherMouseUp))
    XCTAssertEqual(HardwareSimulatorPlugin.cursorTransitionProbeDelaysMs, [16, 50])
  }

  func testCursorHotSpotUsesBitmapRepresentationScale() {
    let hotSpot = HardwareSimulatorPlugin.cursorHotSpotInPixels(
      NSPoint(x: 7.5, y: 4),
      pixelWidth: 64,
      pixelHeight: 48,
      pointSize: NSSize(width: 32, height: 24)
    )

    XCTAssertEqual(hotSpot.x, 15)
    XCTAssertEqual(hotSpot.y, 8)
  }

  func testCursorHotSpotClampsInvalidCoordinates() {
    let hotSpot = HardwareSimulatorPlugin.cursorHotSpotInPixels(
      NSPoint(x: -2, y: CGFloat.nan),
      pixelWidth: 64,
      pixelHeight: 64,
      pointSize: .zero
    )

    XCTAssertEqual(hotSpot.x, 0)
    XCTAssertEqual(hotSpot.y, 0)
  }

  func testCapsLockDownTogglesAlphaShiftAndSanitizesInheritedFlags() throws {
    let inheritedFlags: CGEventFlags = [
      .maskShift,
      .maskSecondaryFn,
      .maskNumericPad,
    ]

    let enabledFlags = try XCTUnwrap(
      HardwareSimulatorPlugin.capsLockFlagsForKeyEvent(
        currentFlags: inheritedFlags,
        isDown: true
      )
    )
    XCTAssertTrue(enabledFlags.contains(.maskAlphaShift))
    XCTAssertTrue(enabledFlags.contains(.maskShift))
    XCTAssertFalse(enabledFlags.contains(.maskSecondaryFn))
    XCTAssertFalse(enabledFlags.contains(.maskNumericPad))

    let disabledFlags = try XCTUnwrap(
      HardwareSimulatorPlugin.capsLockFlagsForKeyEvent(
        currentFlags: enabledFlags,
        isDown: true
      )
    )
    XCTAssertFalse(disabledFlags.contains(.maskAlphaShift))
    XCTAssertTrue(disabledFlags.contains(.maskShift))
  }

  func testCapsLockReleaseDoesNotCreateAnotherStateChange() {
    let flags = HardwareSimulatorPlugin.capsLockFlagsForKeyEvent(
      currentFlags: [.maskAlphaShift],
      isDown: false
    )

    XCTAssertNil(flags)
  }

  func testInjectedKeyboardFlagsUseRemoteModifierState() {
    let flags = HardwareSimulatorPlugin.keyboardFlagsForPressedKeyCodes(
      [0x36, 0x38, 0x3B],
      inheritedFlags: [
        .maskAlphaShift,
        .maskAlternate,
        .maskSecondaryFn,
        .maskNumericPad,
      ]
    )

    XCTAssertTrue(flags.contains(.maskAlphaShift))
    XCTAssertTrue(flags.contains(.maskCommand))
    XCTAssertTrue(flags.contains(.maskShift))
    XCTAssertTrue(flags.contains(.maskControl))
    XCTAssertFalse(flags.contains(.maskAlternate))
    XCTAssertFalse(flags.contains(.maskSecondaryFn))
    XCTAssertFalse(flags.contains(.maskNumericPad))
  }

  func testInjectedKeyboardFlagsClearReleasedRemoteModifiers() {
    let flags = HardwareSimulatorPlugin.keyboardFlagsForPressedKeyCodes(
      [],
      inheritedFlags: [.maskCommand, .maskControl]
    )

    XCTAssertFalse(flags.contains(.maskCommand))
    XCTAssertFalse(flags.contains(.maskControl))
  }

  func testMacTextInputObserverOnlyUsesFocusedElementChanges() {
    XCTAssertEqual(
      HardwareSimulatorPlugin.macTextInputNotificationNames,
      [kAXFocusedUIElementChangedNotification as String]
    )
  }

  func testMacTextInputClassifiesEditableAndSecureFields() {
    let ordinary = HardwareSimulatorPlugin.macTextInputDecision(
      for: MacOSTextInputTraits(
        role: kAXTextFieldRole as String,
        subrole: nil,
        enabled: true,
        editable: true,
        valueSettable: true
      )
    )
    XCTAssertTrue(ordinary.active)
    XCTAssertEqual(ordinary.secure, false)

    let secure = HardwareSimulatorPlugin.macTextInputDecision(
      for: MacOSTextInputTraits(
        role: kAXTextFieldRole as String,
        subrole: kAXSecureTextFieldSubrole as String,
        enabled: true,
        editable: true,
        valueSettable: false
      )
    )
    XCTAssertTrue(secure.active)
    XCTAssertEqual(secure.secure, true)
  }

  func testMacTextInputRejectsDisabledReadOnlyAndNonTextElements() {
    let disabled = HardwareSimulatorPlugin.macTextInputDecision(
      for: MacOSTextInputTraits(
        role: kAXTextAreaRole as String,
        subrole: nil,
        enabled: false,
        editable: true,
        valueSettable: true
      )
    )
    XCTAssertFalse(disabled.active)
    XCTAssertNil(disabled.secure)

    let readOnly = HardwareSimulatorPlugin.macTextInputDecision(
      for: MacOSTextInputTraits(
        role: kAXTextFieldRole as String,
        subrole: nil,
        enabled: true,
        editable: false,
        valueSettable: false
      )
    )
    XCTAssertFalse(readOnly.active)

    let button = HardwareSimulatorPlugin.macTextInputDecision(
      for: MacOSTextInputTraits(
        role: kAXButtonRole as String,
        subrole: nil,
        enabled: true,
        editable: nil,
        valueSettable: false
      )
    )
    XCTAssertFalse(button.active)
  }

  func testMacTextInputValidatesCommittedUnicodeAtomically() {
    XCTAssertEqual(
      HardwareSimulatorPlugin.validatedMacOSTextInputCodeUnits("你好 👋"),
      Array("你好 👋".utf16)
    )
    XCTAssertNil(HardwareSimulatorPlugin.validatedMacOSTextInputCodeUnits(""))
    XCTAssertNil(HardwareSimulatorPlugin.validatedMacOSTextInputCodeUnits("a\nb"))
    XCTAssertNil(HardwareSimulatorPlugin.validatedMacOSTextInputCodeUnits("\u{7f}"))
    XCTAssertNil(
      HardwareSimulatorPlugin.validatedMacOSTextInputCodeUnits(
        String(repeating: "界", count: 1366)
      )
    )
  }

  func testCursorEncodingPrefersImagePointSize() throws {
    let plugin = HardwareSimulatorPlugin()
    let bitmapRep = try XCTUnwrap(NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: 64,
      pixelsHigh: 48,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ))
    let image = NSImage(size: NSSize(width: 32, height: 24))
    image.addRepresentation(bitmapRep)
    bitmapRep.size = NSSize(width: 64, height: 48)

    let encoded = try XCTUnwrap(plugin.encodeCursorBitmap(
      image: image,
      hotSpot: NSPoint(x: 7.5, y: 4)
    ))
    let bytes = [UInt8](encoded.payload)

    XCTAssertEqual(bytes.count, 21 + 64 * 48 * 4)
    XCTAssertEqual(bytes[0], 9)
    XCTAssertEqual(readUInt32BE(bytes, offset: 1), 64)
    XCTAssertEqual(readUInt32BE(bytes, offset: 5), 48)
    XCTAssertEqual(readUInt32BE(bytes, offset: 9), 15)
    XCTAssertEqual(readUInt32BE(bytes, offset: 13), 8)
    XCTAssertEqual(readUInt32BE(bytes, offset: 17), encoded.hash)
  }

  func testCursorVisibilityTreatsFullyTransparentBitmapAsHidden() throws {
    let image = try makeCursorImage(alphaValues: [0, 0, 0, 0])

    XCTAssertEqual(
      HardwareSimulatorPlugin.cursorImageIsFullyTransparent(image),
      true
    )
  }

  func testCursorVisibilityTreatsAnyNonzeroAlphaAsVisible() throws {
    let image = try makeCursorImage(alphaValues: [0, 0, 1, 0])

    XCTAssertEqual(
      HardwareSimulatorPlugin.cursorImageIsFullyTransparent(image),
      false
    )
  }

  func testCursorVisibilityTreatsOpaqueBitmapWithoutAlphaAsVisible() throws {
    let bitmapRep = try XCTUnwrap(NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: 1,
      pixelsHigh: 1,
      bitsPerSample: 8,
      samplesPerPixel: 3,
      hasAlpha: false,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ))
    let image = NSImage(size: NSSize(width: 1, height: 1))
    image.addRepresentation(bitmapRep)

    XCTAssertEqual(
      HardwareSimulatorPlugin.cursorImageIsFullyTransparent(image),
      false
    )
  }

  func testCursorVisibilityCombinesWindowServerAndBitmapSignals() {
    XCTAssertFalse(HardwareSimulatorPlugin.combinedCursorVisibility(
      windowServerVisible: false,
      cursorImageIsFullyTransparent: false
    ))
    XCTAssertFalse(HardwareSimulatorPlugin.combinedCursorVisibility(
      windowServerVisible: false,
      cursorImageIsFullyTransparent: true
    ))
    XCTAssertFalse(HardwareSimulatorPlugin.combinedCursorVisibility(
      windowServerVisible: true,
      cursorImageIsFullyTransparent: true
    ))
    XCTAssertTrue(HardwareSimulatorPlugin.combinedCursorVisibility(
      windowServerVisible: true,
      cursorImageIsFullyTransparent: false
    ))
    XCTAssertTrue(HardwareSimulatorPlugin.combinedCursorVisibility(
      windowServerVisible: true,
      cursorImageIsFullyTransparent: nil
    ))
  }

  func testCursorVisibilityKeepsNontransparentTextureEvidenceWhileGetterIsStale() {
    let result = HardwareSimulatorPlugin.reconciledCursorVisibility(
      windowServerVisible: false,
      previousWindowServerVisible: false,
      cursorTextureProvesVisible: true,
      cursorImageIsFullyTransparent: false
    )

    XCTAssertTrue(result.visible)
    XCTAssertTrue(result.cursorTextureProvesVisible)
  }

  func testCursorVisibilityLetsTransparentTextureOverrideVisibleEvidence() {
    let result = HardwareSimulatorPlugin.reconciledCursorVisibility(
      windowServerVisible: false,
      previousWindowServerVisible: false,
      cursorTextureProvesVisible: true,
      cursorImageIsFullyTransparent: true
    )

    XCTAssertFalse(result.visible)
    XCTAssertFalse(result.cursorTextureProvesVisible)
  }

  func testCursorVisibilityUsesNewWindowServerHiddenTransition() {
    let result = HardwareSimulatorPlugin.reconciledCursorVisibility(
      windowServerVisible: false,
      previousWindowServerVisible: true,
      cursorTextureProvesVisible: true,
      cursorImageIsFullyTransparent: false
    )

    XCTAssertFalse(result.visible)
    XCTAssertFalse(result.cursorTextureProvesVisible)
  }

  func testCursorVisibilityClearsTextureEvidenceWhenGetterRecovers() {
    let result = HardwareSimulatorPlugin.reconciledCursorVisibility(
      windowServerVisible: true,
      previousWindowServerVisible: false,
      cursorTextureProvesVisible: true,
      cursorImageIsFullyTransparent: false
    )

    XCTAssertTrue(result.visible)
    XCTAssertFalse(result.cursorTextureProvesVisible)
  }

  private func makeCursorImage(alphaValues: [UInt8]) throws -> NSImage {
    let bitmapRep = try XCTUnwrap(NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: alphaValues.count,
      pixelsHigh: 1,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ))
    let bitmapData = try XCTUnwrap(bitmapRep.bitmapData)
    let bytesPerPixel = bitmapRep.bitsPerPixel / 8
    let alphaOffset = bitmapRep.bitmapFormat.contains(.alphaFirst)
      ? 0
      : bytesPerPixel - 1
    for (x, alpha) in alphaValues.enumerated() {
      bitmapData[x * bytesPerPixel + alphaOffset] = alpha
    }
    let image = NSImage(
      size: NSSize(width: alphaValues.count, height: 1)
    )
    image.addRepresentation(bitmapRep)
    return image
  }

  private func readUInt32BE(_ bytes: [UInt8], offset: Int) -> UInt32 {
    bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
  }

}
