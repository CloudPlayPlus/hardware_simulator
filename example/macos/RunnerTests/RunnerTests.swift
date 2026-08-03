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

}
