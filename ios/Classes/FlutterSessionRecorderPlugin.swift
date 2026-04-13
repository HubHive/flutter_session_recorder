import Flutter
import Foundation
import UIKit

public class FlutterSessionRecorderPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var captureManager = IOSReplayCaptureManager()

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = FlutterSessionRecorderPlugin()
    let methodChannel = FlutterMethodChannel(
      name: "flutter_session_recorder/methods",
      binaryMessenger: registrar.messenger()
    )
    let eventChannel = FlutterEventChannel(
      name: "flutter_session_recorder/events",
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(instance, channel: methodChannel)
    eventChannel.setStreamHandler(instance)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "startCapture":
      let arguments = call.arguments as? [String: Any] ?? [:]
      captureManager.start(config: arguments)
      result(nil)
    case "pauseCapture":
      captureManager.pause()
      result(nil)
    case "resumeCapture":
      let arguments = call.arguments as? [String: Any] ?? [:]
      captureManager.resume(config: arguments)
      result(nil)
    case "stopCapture":
      captureManager.stop()
      result(nil)
    case "getDeviceContext":
      result(deviceContext())
    case "setScreenName":
      let arguments = call.arguments as? [String: Any]
      captureManager.setScreenName(arguments?["screenName"] as? String)
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    captureManager.eventSink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    captureManager.eventSink = nil
    return nil
  }

  private func deviceContext() -> [String: Any] {
    let device = UIDevice.current
    let identifier = modelIdentifier()
    return [
      "deviceType": platformDeviceType(device.userInterfaceIdiom),
      "model": friendlyModelName(for: identifier),
      "modelIdentifier": identifier,
      "osName": device.systemName,
      "osVersion": device.systemVersion,
    ]
  }

  private func platformDeviceType(_ idiom: UIUserInterfaceIdiom) -> String {
    switch idiom {
    case .pad:
      return "ipad"
    case .phone:
      return "iphone"
    case .tv:
      return "appletv"
    case .carPlay:
      return "carplay"
    case .mac:
      return "mac"
    default:
      return "ios"
    }
  }

  private func modelIdentifier() -> String {
    var systemInfo = utsname()
    uname(&systemInfo)
    let mirror = Mirror(reflecting: systemInfo.machine)
    return mirror.children.reduce(into: "") { identifier, element in
      guard let value = element.value as? Int8, value != 0 else { return }
      identifier.append(Character(UnicodeScalar(UInt8(value))))
    }
  }

  private func friendlyModelName(for identifier: String) -> String {
    let known: [String: String] = [
      "iPhone11,8": "iPhone XR",
      "iPhone11,2": "iPhone XS",
      "iPhone11,4": "iPhone XS Max",
      "iPhone11,6": "iPhone XS Max",
      "iPhone12,1": "iPhone 11",
      "iPhone12,3": "iPhone 11 Pro",
      "iPhone12,5": "iPhone 11 Pro Max",
      "iPhone13,1": "iPhone 12 mini",
      "iPhone13,2": "iPhone 12",
      "iPhone13,3": "iPhone 12 Pro",
      "iPhone13,4": "iPhone 12 Pro Max",
      "iPhone14,4": "iPhone 13 mini",
      "iPhone14,5": "iPhone 13",
      "iPhone14,2": "iPhone 13 Pro",
      "iPhone14,3": "iPhone 13 Pro Max",
      "iPhone14,7": "iPhone 14",
      "iPhone14,8": "iPhone 14 Plus",
      "iPhone15,2": "iPhone 14 Pro",
      "iPhone15,3": "iPhone 14 Pro Max",
      "iPhone15,4": "iPhone 15",
      "iPhone15,5": "iPhone 15 Plus",
      "iPhone16,1": "iPhone 15 Pro",
      "iPhone16,2": "iPhone 15 Pro Max",
      "x86_64": "iOS Simulator",
      "arm64": "iOS Simulator",
    ]

    return known[identifier] ?? identifier
  }
}

private final class IOSReplayCaptureManager: NSObject, UIGestureRecognizerDelegate {
  var eventSink: FlutterEventSink?

  private var captureNativeLifecycle = true
  private var captureNativeViewHierarchy = true
  private var captureScrolls = true
  private var captureTaps = true
  private var flutterScreenName: String?
  private var isStarted = false
  private var lastScreenName: String?
  private var maskAllText = false
  private var maskTextInputs = true
  private var minimumScrollDelta: CGFloat = 24
  private var panRecognizer: UIPanGestureRecognizer?
  private var snapshotInterval: TimeInterval = 0.7
  private var tapRecognizer: UITapGestureRecognizer?
  private var timer: Timer?

  func start(config: [String: Any]) {
    captureNativeLifecycle = config.boolValue("captureNativeLifecycle", fallback: true)
    captureNativeViewHierarchy = config.boolValue("captureNativeViewHierarchy", fallback: true)
    captureScrolls = config.boolValue("captureScrolls", fallback: true)
    captureTaps = config.boolValue("captureTaps", fallback: true)
    maskAllText = config.boolValue("maskAllText", fallback: false)
    maskTextInputs = config.boolValue("maskTextInputs", fallback: true)
    minimumScrollDelta = CGFloat(config.doubleValue("minimumScrollDelta", fallback: 24))
    snapshotInterval = TimeInterval(config.doubleValue("nativeViewTreeSnapshotIntervalMs", fallback: 700) / 1000.0)
    isStarted = true

    registerLifecycleObservers()
    attachGestureRecognizersIfNeeded()
    startTimer()
    emitScreenAndFrame(reason: "start")
  }

  func stop() {
    isStarted = false
    flutterScreenName = nil
    timer?.invalidate()
    timer = nil
    NotificationCenter.default.removeObserver(self)
    detachGestureRecognizers()
  }

  func pause() {
    guard isStarted else { return }
    timer?.invalidate()
    timer = nil
    detachGestureRecognizers()
  }

  func resume(config: [String: Any]) {
    guard isStarted else {
      start(config: config)
      return
    }

    captureNativeLifecycle = config.boolValue("captureNativeLifecycle", fallback: captureNativeLifecycle)
    captureNativeViewHierarchy = config.boolValue("captureNativeViewHierarchy", fallback: captureNativeViewHierarchy)
    captureScrolls = config.boolValue("captureScrolls", fallback: captureScrolls)
    captureTaps = config.boolValue("captureTaps", fallback: captureTaps)
    snapshotInterval = TimeInterval(config.doubleValue("nativeViewTreeSnapshotIntervalMs", fallback: snapshotInterval * 1000) / 1000.0)
    attachGestureRecognizersIfNeeded()
    startTimer()
    emitScreenAndFrame(reason: "resume_capture")
  }

  private func startTimer() {
    timer?.invalidate()
    guard captureNativeViewHierarchy else { return }
    timer = Timer.scheduledTimer(withTimeInterval: snapshotInterval, repeats: true) { [weak self] _ in
      self?.emitScreenAndFrame(reason: "interval")
    }
  }

  private func registerLifecycleObservers() {
    guard captureNativeLifecycle else { return }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(appDidBecomeActive),
      name: UIApplication.didBecomeActiveNotification,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(appWillResignActive),
      name: UIApplication.willResignActiveNotification,
      object: nil
    )
  }

  @objc private func appDidBecomeActive() {
    emitEvent(type: "native.lifecycle", attributes: [
      "state": "resumed",
      "screenName": currentScreenName() as Any,
    ])
    emitScreenAndFrame(reason: "resume")
  }

  @objc private func appWillResignActive() {
    emitEvent(type: "native.lifecycle", attributes: [
      "state": "paused",
      "screenName": currentScreenName() as Any,
    ])
  }

  private func attachGestureRecognizersIfNeeded() {
    guard let window = keyWindow() else { return }

    if captureTaps, tapRecognizer == nil {
      let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
      recognizer.cancelsTouchesInView = false
      recognizer.delegate = self
      window.addGestureRecognizer(recognizer)
      tapRecognizer = recognizer
    }

    if captureScrolls, panRecognizer == nil {
      let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
      recognizer.cancelsTouchesInView = false
      recognizer.delegate = self
      window.addGestureRecognizer(recognizer)
      panRecognizer = recognizer
    }
  }

  private func detachGestureRecognizers() {
    if let recognizer = tapRecognizer {
      recognizer.view?.removeGestureRecognizer(recognizer)
    }
    if let recognizer = panRecognizer {
      recognizer.view?.removeGestureRecognizer(recognizer)
    }
    tapRecognizer = nil
    panRecognizer = nil
  }

  @objc private func handleTap(_ recognizer: UITapGestureRecognizer) {
    let point = recognizer.location(in: recognizer.view)
    emitEvent(type: "interaction.tap", attributes: [
      "dx": point.x,
      "dy": point.y,
      "screenName": currentScreenName() as Any,
    ])
  }

  @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
    let translation = recognizer.translation(in: recognizer.view)
    if abs(translation.y) < minimumScrollDelta && abs(translation.x) < minimumScrollDelta {
      return
    }
    emitEvent(type: "interaction.scroll", attributes: [
      "axis": abs(translation.y) >= abs(translation.x) ? "vertical" : "horizontal",
      "dx": translation.x,
      "dy": translation.y,
      "screenName": currentScreenName() as Any,
    ])
    recognizer.setTranslation(.zero, in: recognizer.view)
  }

  private func emitScreenAndFrame(reason: String) {
    let screenName = currentScreenName()
    if screenName != lastScreenName {
      lastScreenName = screenName
      emitEvent(type: "screen.view", attributes: [
        "screenName": screenName as Any,
        "properties": [
          "source": "ios_native",
          "reason": reason,
        ],
      ])
    }

    guard captureNativeViewHierarchy, let window = keyWindow() else { return }
    emitEvent(type: "replay.frame", attributes: [
      "screenName": screenName as Any,
      "metadata": [
        "platform": "ios",
        "reason": reason,
        "captureStrategy": "native_view_hierarchy",
      ],
      "viewport": buildViewport(window: window),
      "tree": buildNode(view: window),
    ])
  }

  private func buildNode(view: UIView) -> [String: Any] {
    let frame = view.convert(view.bounds, to: nil)
    var node: [String: Any] = [
      "id": String(ObjectIdentifier(view).hashValue),
      "type": String(describing: type(of: view)),
      "alpha": view.alpha,
      "bounds": [
        "x": frame.origin.x,
        "y": frame.origin.y,
        "width": frame.size.width,
        "height": frame.size.height,
      ],
      "enabled": view.isUserInteractionEnabled,
      "hidden": view.isHidden,
      "padding": [
        "left": 0,
        "top": 0,
        "right": 0,
        "bottom": 0,
      ],
      "render": buildRenderProperties(view: view),
      "scrollable": view is UIScrollView,
      "transform": [
        "rotation": atan2(view.transform.b, view.transform.a),
        "scaleX": sqrt((view.transform.a * view.transform.a) + (view.transform.c * view.transform.c)),
        "scaleY": sqrt((view.transform.b * view.transform.b) + (view.transform.d * view.transform.d)),
        "translationX": view.transform.tx,
        "translationY": view.transform.ty,
      ],
    ]

    if let control = view as? UIControl {
      node["selected"] = control.isSelected
      node["highlighted"] = control.isHighlighted
      node["enabled"] = control.isEnabled
    }

    if let label = view as? UILabel {
      node["text"] = maskAllText ? "•••" : label.text
      node["textStyle"] = buildTextStyle(
        color: label.textColor,
        font: label.font,
        alignment: label.textAlignment,
        lineBreakMode: label.lineBreakMode,
        numberOfLines: label.numberOfLines
      )
    } else if let textView = view as? UITextView {
      node["text"] = (maskAllText || maskTextInputs) ? "•••" : textView.text
      node["textStyle"] = buildTextStyle(
        color: textView.textColor,
        font: textView.font,
        alignment: textView.textAlignment,
        lineBreakMode: textView.textContainer.lineBreakMode,
        numberOfLines: 0
      )
      node["contentOffset"] = [
        "x": textView.contentOffset.x,
        "y": textView.contentOffset.y,
      ]
    } else if view is UITextField {
      node["text"] = "•••"
      if let textField = view as? UITextField {
        node["hint"] = maskTextInputs ? "•••" : textField.placeholder
        node["textStyle"] = buildTextStyle(
          color: textField.textColor,
          font: textField.font,
          alignment: textField.textAlignment,
          lineBreakMode: .byTruncatingTail,
          numberOfLines: 1
        )
      }
    }

    if let button = view as? UIButton {
      node["text"] = maskAllText ? "•••" : button.title(for: .normal)
      node["textStyle"] = buildTextStyle(
        color: button.titleColor(for: .normal),
        font: button.titleLabel?.font,
        alignment: button.titleLabel?.textAlignment ?? .center,
        lineBreakMode: button.titleLabel?.lineBreakMode ?? .byTruncatingTail,
        numberOfLines: button.titleLabel?.numberOfLines ?? 1
      )
    }

    if let imageView = view as? UIImageView {
      node["image"] = [
        "contentMode": contentModeName(imageView.contentMode),
        "hasImage": imageView.image != nil,
        "tintColor": colorToHex(imageView.tintColor),
      ]
    }

    if let control = view as? UISwitch {
      node["checked"] = control.isOn
    }

    if let slider = view as? UISlider {
      node["progress"] = [
        "minimum": slider.minimumValue,
        "maximum": slider.maximumValue,
        "value": slider.value,
      ]
    }

    if let progress = view as? UIProgressView {
      node["progress"] = [
        "minimum": 0,
        "maximum": 1,
        "value": progress.progress,
      ]
    }

    if !view.subviews.isEmpty {
      node["children"] = view.subviews.enumerated().map { index, child in
        var childNode = buildNode(view: child)
        childNode["childIndex"] = index
        return childNode
      }
    }

    if let scrollView = view as? UIScrollView {
      node["contentOffset"] = [
        "x": scrollView.contentOffset.x,
        "y": scrollView.contentOffset.y,
      ]
      node["contentSize"] = [
        "width": scrollView.contentSize.width,
        "height": scrollView.contentSize.height,
      ]
      node["contentInset"] = [
        "top": scrollView.contentInset.top,
        "left": scrollView.contentInset.left,
        "bottom": scrollView.contentInset.bottom,
        "right": scrollView.contentInset.right,
      ]
    }

    return node
  }

  private func buildViewport(window: UIWindow) -> [String: Any] {
    let safeArea = window.safeAreaInsets
    return [
      "width": window.bounds.width,
      "height": window.bounds.height,
      "scale": window.screen.scale,
      "safeAreaInsets": [
        "top": safeArea.top,
        "left": safeArea.left,
        "bottom": safeArea.bottom,
        "right": safeArea.right,
      ],
    ]
  }

  private func buildRenderProperties(view: UIView) -> [String: Any] {
    var render: [String: Any] = [
      "background": [
        "type": "solid",
        "color": colorToHex(view.backgroundColor),
      ],
      "clipsToBounds": view.clipsToBounds,
      "cornerRadius": view.layer.cornerRadius,
      "borderWidth": view.layer.borderWidth,
      "borderColor": colorToHex(UIColor(cgColor: view.layer.borderColor ?? UIColor.clear.cgColor)),
    ]

    if let stackView = view as? UIStackView {
      render["stack"] = [
        "axis": stackView.axis == .vertical ? "vertical" : "horizontal",
        "alignment": stackAlignmentName(stackView.alignment),
        "distribution": stackDistributionName(stackView.distribution),
        "spacing": stackView.spacing,
      ]
    }

    return render
  }

  private func buildTextStyle(
    color: UIColor?,
    font: UIFont?,
    alignment: NSTextAlignment,
    lineBreakMode: NSLineBreakMode,
    numberOfLines: Int
  ) -> [String: Any] {
    return [
      "alignment": textAlignmentName(alignment),
      "color": colorToHex(color),
      "fontFamily": font?.familyName as Any,
      "fontName": font?.fontName as Any,
      "fontSize": font?.pointSize as Any,
      "fontWeight": fontWeightName(font),
      "lineBreakMode": lineBreakModeName(lineBreakMode),
      "numberOfLines": numberOfLines,
    ]
  }

  private func emitEvent(type: String, attributes: [String: Any]) {
    guard let eventSink else { return }
    eventSink([
      "id": UUID().uuidString,
      "type": type,
      "timestampMs": Int(Date().timeIntervalSince1970 * 1000),
      "attributes": attributes,
    ])
  }

  func setScreenName(_ screenName: String?) {
    flutterScreenName = screenName?
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .nonEmptyValue
  }

  private func currentScreenName() -> String? {
    if let flutterScreenName {
      return flutterScreenName
    }

    guard let controller = topViewController() else { return nil }
    if let title = controller.title?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyValue {
      return title
    }
    return String(describing: type(of: controller))
  }

  private func keyWindow() -> UIWindow? {
    if #available(iOS 13.0, *) {
      return UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
        .first(where: \.isKeyWindow)
    }
    return UIApplication.shared.keyWindow
  }

  private func topViewController(base: UIViewController? = nil) -> UIViewController? {
    let root = base ?? keyWindow()?.rootViewController
    if let nav = root as? UINavigationController {
      return topViewController(base: nav.visibleViewController)
    }
    if let tab = root as? UITabBarController, let selected = tab.selectedViewController {
      return topViewController(base: selected)
    }
    if let presented = root?.presentedViewController {
      return topViewController(base: presented)
    }
    return root
  }

  func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
    return true
  }
}

private extension Dictionary where Key == String, Value == Any {
  func boolValue(_ key: String, fallback: Bool) -> Bool {
    return self[key] as? Bool ?? fallback
  }

  func doubleValue(_ key: String, fallback: Double) -> Double {
    if let value = self[key] as? Double {
      return value
    }
    if let value = self[key] as? Int {
      return Double(value)
    }
    return fallback
  }
}

private func colorToHex(_ color: UIColor?) -> String? {
  guard let color else { return nil }
  var red: CGFloat = 0
  var green: CGFloat = 0
  var blue: CGFloat = 0
  var alpha: CGFloat = 0
  guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
    return nil
  }
  return String(
    format: "#%02X%02X%02X%02X",
    Int(round(alpha * 255)),
    Int(round(red * 255)),
    Int(round(green * 255)),
    Int(round(blue * 255))
  )
}

private func textAlignmentName(_ alignment: NSTextAlignment) -> String {
  switch alignment {
  case .center:
    return "center"
  case .right:
    return "end"
  case .justified:
    return "justified"
  default:
    return "start"
  }
}

private func lineBreakModeName(_ mode: NSLineBreakMode) -> String {
  switch mode {
  case .byClipping:
    return "clip"
  case .byTruncatingHead:
    return "truncate_head"
  case .byTruncatingMiddle:
    return "truncate_middle"
  case .byTruncatingTail:
    return "truncate_tail"
  case .byWordWrapping:
    return "word_wrap"
  default:
    return "char_wrap"
  }
}

private func fontWeightName(_ font: UIFont?) -> String {
  guard let descriptor = font?.fontDescriptor else { return "400" }
  let traits = descriptor.object(forKey: .traits) as? [UIFontDescriptor.TraitKey: Any]
  let weight = (traits?[.weight] as? CGFloat) ?? 0
  switch weight {
  case ..<(-0.4):
    return "300"
  case ..<0.15:
    return "400"
  case ..<0.3:
    return "500"
  case ..<0.4:
    return "600"
  default:
    return "700"
  }
}

private extension String {
  var nonEmptyValue: String? {
    isEmpty ? nil : self
  }
}

private func contentModeName(_ mode: UIView.ContentMode) -> String {
  switch mode {
  case .scaleAspectFit:
    return "aspect_fit"
  case .scaleAspectFill:
    return "aspect_fill"
  case .scaleToFill:
    return "fill"
  case .center:
    return "center"
  default:
    return "other"
  }
}

private func stackAlignmentName(_ alignment: UIStackView.Alignment) -> String {
  switch alignment {
  case .center:
    return "center"
  case .leading, .top:
    return "start"
  case .trailing, .bottom:
    return "end"
  case .fill:
    return "fill"
  default:
    return "first_baseline"
  }
}

private func stackDistributionName(_ distribution: UIStackView.Distribution) -> String {
  switch distribution {
  case .fill:
    return "fill"
  case .fillEqually:
    return "fill_equally"
  case .fillProportionally:
    return "fill_proportionally"
  case .equalSpacing:
    return "equal_spacing"
  case .equalCentering:
    return "equal_centering"
  @unknown default:
    return "unknown"
  }
}
