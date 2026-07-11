import Flutter
import UIKit
import GameController
import ObjectiveC

class HomeIndicatorAwareFlutterViewController : FlutterViewController {
  static var hidingHomeIndicator: Bool = false
  static var lockCursor: Bool = false

  @available(iOS 11.0, *)
  override var prefersHomeIndicatorAutoHidden: Bool {
    return !HomeIndicatorAwareFlutterViewController.hidingHomeIndicator
  }

    
  @available(iOS 11.0, *)
  override var prefersPointerLocked: Bool {
    return HomeIndicatorAwareFlutterViewController.lockCursor
  }

  func setHidingHomeIndicator(newValue: Bool) {
    if (newValue != HomeIndicatorAwareFlutterViewController.hidingHomeIndicator) {
      HomeIndicatorAwareFlutterViewController.hidingHomeIndicator = newValue
      if #available(iOS 11.0, *) {
        if responds(to: #selector(setNeedsUpdateOfHomeIndicatorAutoHidden)) {
          setNeedsUpdateOfHomeIndicatorAutoHidden()
        }
      } else {
        // Fallback on earlier versions: do nothing
      }
    }
  }
    
  func setLockCursor(newValue: Bool) {
    if (newValue != HomeIndicatorAwareFlutterViewController.lockCursor) {
        HomeIndicatorAwareFlutterViewController.lockCursor = newValue
        if #available(iOS 14.0, *) {
          if responds(to: #selector(setNeedsUpdateOfPrefersPointerLocked)) {
            setNeedsUpdateOfPrefersPointerLocked()
          }
        } else {
          // Fallback on earlier versions: do nothing
        }
    }
  }

  static var deferredEdges: UIRectEdge = []

  @available(iOS 11.0, *)
  override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
    return HomeIndicatorAwareFlutterViewController.deferredEdges
  }

  func setDeferredEdges(newValue: UIRectEdge) {
    if (newValue != HomeIndicatorAwareFlutterViewController.deferredEdges) {
      HomeIndicatorAwareFlutterViewController.deferredEdges = newValue
      if #available(iOS 11.0, *) {
        setNeedsUpdateOfScreenEdgesDeferringSystemGestures()
      } else {
        // Fallback on earlier versions: do nothing
      }
    }
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    if #available(iOS 13.4, *) {
      if let touch = touches.first, touch.type == .indirectPointer, HomeIndicatorAwareFlutterViewController.lockCursor {
        return
      }
    }
    super.touchesBegan(touches, with: event)
  }
  
  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    if #available(iOS 13.4, *) {
      if let touch = touches.first, touch.type == .indirectPointer, HomeIndicatorAwareFlutterViewController.lockCursor {
        return
      }
    }
    super.touchesMoved(touches, with: event)
  }
  
  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    if #available(iOS 13.4, *) {
      if let touch = touches.first, touch.type == .indirectPointer, HomeIndicatorAwareFlutterViewController.lockCursor {
        return
      }
    }
    super.touchesEnded(touches, with: event)
  }
  
  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
    if #available(iOS 13.4, *) {
      if let touch = touches.first, touch.type == .indirectPointer, HomeIndicatorAwareFlutterViewController.lockCursor {
        return
      }
    }
    super.touchesCancelled(touches, with: event)
  }
}

/* used for other mouse types when CGMouse does not work.
@available(iOS 13.4, *)
extension UIView: UIPointerInteractionDelegate {
    public func pointerInteraction(_ interaction: UIPointerInteraction, regionFor request: UIPointerRegionRequest, defaultRegion: UIPointerRegion) -> UIPointerRegion? {
        return nil; //UIPointerRegion(rect: bounds)
    }
    
    public func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        return UIPointerStyle.hidden()
    }
}
*/

public class HardwareSimulatorPlugin: NSObject, FlutterPlugin {
    private var channel: FlutterMethodChannel?
    private var mouseConnectObserver: NSObjectProtocol?
    private var mouseDisconnectObserver: NSObjectProtocol?
    private var accumulatedDeltaX: Float = 0
    private var accumulatedDeltaY: Float = 0
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "hardware_simulator", binaryMessenger: registrar.messenger())
        let instance = HardwareSimulatorPlugin()
        instance.channel = channel
        registrar.addMethodCallDelegate(instance, channel: channel)
        
        instance.startTrackingMouse()
    }
    
    private func controller() -> HomeIndicatorAwareFlutterViewController? {
      guard let window = UIApplication.shared.keyWindow else { print("no window"); return nil }
      guard let rvc = window.rootViewController else { print("no rvc"); return nil }
      if let rvc = rvc as? HomeIndicatorAwareFlutterViewController { return rvc }
      guard let fvc = findFlutterViewController(from: rvc) else { return nil }
      object_setClass(fvc, HomeIndicatorAwareFlutterViewController.self)
      let newController = fvc as! HomeIndicatorAwareFlutterViewController
      return newController
    }

    private func findFlutterViewController(from controller: UIViewController) -> FlutterViewController? {
      if let fvc = controller as? FlutterViewController {
        return fvc
      }
      for child in controller.children {
        if let fvc = findFlutterViewController(from: child) {
          return fvc
        }
      }
      if let presented = controller.presentedViewController,
         let fvc = findFlutterViewController(from: presented) {
        return fvc
      }
      return nil
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getPlatformVersion":
            result("iOS " + UIDevice.current.systemVersion)
        case "isMouseConnected":
            if #available(iOS 14.0, *) {
              result(!GCMouse.mice().isEmpty)
            }
            result(false)
        case "addCursorMoved":
            result(nil)
        case "addCursorButton":
            result(nil)
        case "addCursorScroll":
            result(nil)
        case "lockCursor":
            if #available(iOS 14.0, *) {
                if let controller = controller() {
                    controller.setLockCursor(newValue:true)
                    controller.setHidingHomeIndicator(newValue: true)
                    controller.setDeferredEdges(newValue: UIRectEdge.all)
                }
            }
            result(nil)
        case "unlockCursor":
            if #available(iOS 14.0, *) {
                if let controller = controller() {
                    controller.setLockCursor(newValue:false)
                    controller.setHidingHomeIndicator(newValue: false)
                    controller.setDeferredEdges(newValue: UIRectEdge.init(rawValue: 0))
                }
            }
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }
    
    private func startTrackingMouse() {
        if #available(iOS 14.0, *) {
            mouseConnectObserver = NotificationCenter.default.addObserver(
                forName: .GCMouseDidConnect,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                if let mouse = notification.object as? GCMouse {
                    self?.registerMouseCallbacks(mouse)
                }
            }
            
            mouseDisconnectObserver = NotificationCenter.default.addObserver(
                forName: .GCMouseDidDisconnect,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                if let mouse = notification.object as? GCMouse {
                    self?.unregisterMouseCallbacks(mouse)
                }
            }
            
            for mouse in GCMouse.mice() {
                registerMouseCallbacks(mouse)
            }
        }
    }
    
    @available(iOS 14.0, *)
    private func registerMouseCallbacks(_ mouse: GCMouse) {
        guard let mouseInput = mouse.mouseInput else { return }
        
        mouseInput.mouseMovedHandler = { [weak self] mouse, deltaX, deltaY in
            guard let self = self else { return }
            self.channel?.invokeMethod("onCursorMoved", arguments: [
                "dx": deltaX,
                "dy": -deltaY
            ])
            return
        }
        
        mouseInput.leftButton.pressedChangedHandler = { [weak self] button, value, pressed in
            self?.channel?.invokeMethod("onCursorButton", arguments: [
                "buttonId": 1,  // 左键
                "isDown": pressed
            ])
        }
        
        mouseInput.middleButton?.pressedChangedHandler = { [weak self] button, value, pressed in
            self?.channel?.invokeMethod("onCursorButton", arguments: [
                "buttonId": 2,  // 中键
                "isDown": pressed
            ])
        }
        
        mouseInput.rightButton?.pressedChangedHandler = { [weak self] button, value, pressed in
            self?.channel?.invokeMethod("onCursorButton", arguments: [
                "buttonId": 3,  // 右键
                "isDown": pressed
            ])
        }
        
        // Match the client-side PointerPanZoom/touch scroll convention.
        mouseInput.scroll.xAxis.valueChangedHandler = { [weak self] axis, value in
            self?.channel?.invokeMethod("onCursorScroll", arguments: [
                "dx": -Double(value),
                "dy": 0
            ])
        }
        
        mouseInput.scroll.yAxis.valueChangedHandler = { [weak self] axis, value in
            self?.channel?.invokeMethod("onCursorScroll", arguments: [
                "dx": 0,
                "dy": -Double(value)
            ])
        }
    }
    
    @available(iOS 14.0, *)
    private func unregisterMouseCallbacks(_ mouse: GCMouse) {
        guard let mouseInput = mouse.mouseInput else { return }
        mouseInput.mouseMovedHandler = nil
        mouseInput.leftButton.pressedChangedHandler = nil
        mouseInput.middleButton?.pressedChangedHandler = nil
        mouseInput.rightButton?.pressedChangedHandler = nil
        mouseInput.scroll.yAxis.valueChangedHandler = nil
        mouseInput.scroll.xAxis.valueChangedHandler = nil
    }
}
