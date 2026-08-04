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

  private func readUInt32BE(_ bytes: [UInt8], offset: Int) -> UInt32 {
    bytes[offset..<offset + 4].reduce(0) { ($0 << 8) | UInt32($1) }
  }

}
