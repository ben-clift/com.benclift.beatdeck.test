import Flutter
import UIKit

/// The small iPhone helpers the Android app does in MainActivity: open a link,
/// and dim the screen. Everything else (the engine) is called over dart:ffi.
public class DjEngineIosPlugin: NSObject, FlutterPlugin {
  private var originalBrightness: CGFloat?

  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "sidedeck/audio", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(DjEngineIosPlugin(), channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "openUrl":
      guard let s = args?["url"] as? String, let url = URL(string: s) else { result(false); return }
      DispatchQueue.main.async {
        UIApplication.shared.open(url, options: [:]) { ok in result(ok) }
      }
    case "openAppByName":
      result(false)
    case "setBrightness":
      let v = (args?["value"] as? Double) ?? -1
      DispatchQueue.main.async {
        if self.originalBrightness == nil { self.originalBrightness = UIScreen.main.brightness }
        if v < 0 {
          if let o = self.originalBrightness { UIScreen.main.brightness = o }
        } else {
          UIScreen.main.brightness = CGFloat(max(0.05, min(1.0, v)))
        }
        result(nil)
      }
    default:
      result(nil)
    }
  }
}
