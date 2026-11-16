import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}

class CinePlannerViewController: FlutterViewController {
  private var requestedInitialLandscape = false

  override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
    return .landscapeLeft
  }

  override func viewDidAppear(_ animated: Bool) {
    super.viewDidAppear(animated)
    guard !requestedInitialLandscape else { return }
    requestedInitialLandscape = true
    if #available(iOS 16.0, *) {
      // iPadOS controls orientation in resized windows and may decline this request.
      view.window?.windowScene?.requestGeometryUpdate(
        .iOS(interfaceOrientations: .landscape),
        errorHandler: { _ in }
      )
    }
  }
}
