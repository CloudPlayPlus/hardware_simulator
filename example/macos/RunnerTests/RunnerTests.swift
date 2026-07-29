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

}
