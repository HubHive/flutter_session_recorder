import Flutter
import Foundation
import UIKit

public class FlutterSessionRecorderPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private var captureManager = IOSNativeCaptureManager()

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
    case "startSnapshotCapture":
      debugLog("startSnapshotCapture method received")
      let arguments = call.arguments as? [String: Any] ?? [:]
      captureManager.startSnapshotCapture(config: arguments, result: result)
    case "stopSnapshotCapture":
      captureManager.stopSnapshotCapture(result: result)
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
    debugLog("event channel attached")
    captureManager.eventSink = events
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    debugLog("event channel detached")
    captureManager.eventSink = nil
    return nil
  }

  private func debugLog(_ message: String) {
    NSLog("[flutter_session_recorder ios] %@", message)
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

private final class IOSWindowSnapshotCaptureManager {
  var eventSink: FlutterEventSink? {
    didSet {
      flushPendingEventsIfNeeded()
    }
  }
  var screenNameProvider: (() -> String?)?

  private let snapshotQueue = DispatchQueue(label: "flutter_session_recorder.snapshot")
  private var isRecording = false
  private var jpegQuality: CGFloat = 0.65
  private var maxDimension = 720
  private var pendingEvents: [[String: Any]] = []
  private var sequence = 0
  private var snapshotInterval: TimeInterval = 0.5
  private var snapshotTimer: DispatchWorkItem?

  func start(config: [String: Any], result: @escaping FlutterResult) {
    snapshotQueue.async {
      if self.isRecording {
        self.debugLog("Window snapshot capture start skipped because capture is already recording")
        DispatchQueue.main.async { result(nil) }
        return
      }

      self.snapshotInterval = max(
        0.25,
        config.doubleValue("nativeSnapshotIntervalMs", fallback: 500) / 1000.0
      )
      self.jpegQuality = CGFloat(
        min(0.95, max(0.2, config.doubleValue("nativeSnapshotJpegQuality", fallback: 0.65)))
      )
      self.maxDimension = max(
        240,
        config.intValue("nativeSnapshotMaxDimension", fallback: 720)
      )
      self.sequence = 0
      self.isRecording = true

      self.debugLog(
        "Window snapshot capture started: interval=\(self.snapshotInterval)s quality=\(self.jpegQuality) maxDimension=\(self.maxDimension)"
      )
      self.emitStatus(
        phase: "started",
        message: "Window snapshot capture started.",
        attributes: [
          "captureStrategy": "uiwindow_draw_hierarchy",
          "jpegQuality": Double(self.jpegQuality),
          "maxDimension": self.maxDimension,
          "snapshotIntervalMs": Int(self.snapshotInterval * 1000),
        ]
      )
      self.scheduleNextSnapshot()
      DispatchQueue.main.async { result(nil) }
    }
  }

  func stop(completion: @escaping (Error?) -> Void) {
    snapshotQueue.async {
      self.isRecording = false
      self.snapshotTimer?.cancel()
      self.snapshotTimer = nil
      completion(nil)
    }
  }

  private func scheduleNextSnapshot() {
    snapshotTimer?.cancel()
    guard isRecording else { return }

    let workItem = DispatchWorkItem { [weak self] in
      self?.captureSnapshotFrame()
    }
    snapshotTimer = workItem
    DispatchQueue.main.asyncAfter(deadline: .now() + snapshotInterval, execute: workItem)
  }

  private func captureSnapshotFrame() {
    guard isRecording else { return }

    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      guard let image = self.snapshotKeyWindow() else {
        self.snapshotQueue.async {
          self.emitStatus(
            phase: "snapshot_skipped",
            level: "warning",
            message: "Unable to snapshot the key window for this frame."
          )
          self.scheduleNextSnapshot()
        }
        return
      }

      guard let data = image.jpegData(compressionQuality: self.jpegQuality) else {
        self.snapshotQueue.async {
          self.emitStatus(
            phase: "snapshot_encode_failed",
            level: "warning",
            message: "Unable to encode the key window snapshot."
          )
          self.scheduleNextSnapshot()
        }
        return
      }

      self.snapshotQueue.async {
        self.writeSnapshot(data: data, width: Int(image.size.width * image.scale), height: Int(image.size.height * image.scale))
      }
    }
  }

  private func writeSnapshot(data: Data, width: Int, height: Int) {
    guard isRecording else { return }
    sequence += 1
    let timestampMs = Int(Date().timeIntervalSince1970 * 1000)
    let snapshotId = "ios_\(timestampMs)_\(sequence)"
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "flutter_session_recorder_snapshot_\(UUID().uuidString).jpg"
    )

    do {
      try data.write(to: url, options: .atomic)
      debugLog("Window snapshot ready: id=\(snapshotId) bytes=\(data.count)")
      emitSnapshotReady(
        url: url,
        snapshotId: snapshotId,
        timestampMs: timestampMs,
        width: width,
        height: height,
        fileSize: data.count
      )
    } catch {
      emitError(error)
    }

    scheduleNextSnapshot()
  }

  private func snapshotKeyWindow() -> UIImage? {
    guard Thread.isMainThread else { return nil }
    guard let window = keyWindow() else { return nil }

    let captureScale = captureScaleForWindow(window)
    let format = UIGraphicsImageRendererFormat()
    format.scale = captureScale
    format.opaque = window.isOpaque
    let renderer = UIGraphicsImageRenderer(size: window.bounds.size, format: format)
    let image = renderer.image { _ in
      let didDraw = window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
      if !didDraw, let context = UIGraphicsGetCurrentContext() {
        window.layer.render(in: context)
      }
    }
    return image
  }

  private func captureScaleForWindow(_ window: UIWindow) -> CGFloat {
    let longestSide = max(window.bounds.width, window.bounds.height)
    guard longestSide > 0 else { return window.screen.scale }
    return min(window.screen.scale, CGFloat(maxDimension) / longestSide)
  }

  private func keyWindow() -> UIWindow? {
    if #available(iOS 13.0, *) {
      return UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first(where: { $0.activationState == .foregroundActive })?
        .windows
        .first(where: \.isKeyWindow)
    }
    return UIApplication.shared.keyWindow
  }

  private func emitSnapshotReady(
    url: URL,
    snapshotId: String,
    timestampMs: Int,
    width: Int,
    height: Int,
    fileSize: Int
  ) {
    let baseAttributes: [String: Any] = [
      "captureStrategy": "uiwindow_draw_hierarchy",
      "contentType": "image/jpeg",
      "filePath": url.path,
      "fileSize": fileSize,
      "format": "jpg",
      "height": height,
      "snapshotId": snapshotId,
      "sequence": sequence,
      "timestampMs": timestampMs,
      "width": width,
    ]
    DispatchQueue.main.async { [weak self] in
      guard let self = self else { return }
      var eventAttributes = baseAttributes
      if let screenName = self.screenNameProvider?() {
        eventAttributes["screenName"] = screenName
      }
      self.emitEvent(
        type: "replay.snapshot.ready",
        timestampMs: timestampMs,
        attributes: eventAttributes
      )
    }
  }

  private func emitError(_ error: Error) {
    debugLog("Window snapshot capture error: \(error.localizedDescription)")
    emitEvent(type: "native.snapshot_capture.error", attributes: [
      "message": error.localizedDescription,
      "platform": "ios",
    ])
  }

  private func emitStatus(
    phase: String,
    level: String = "info",
    message: String,
    attributes: [String: Any] = [:]
  ) {
    var eventAttributes = attributes
    eventAttributes["level"] = level
    eventAttributes["message"] = message
    eventAttributes["phase"] = phase
    eventAttributes["platform"] = "ios"
    emitEvent(type: "native.snapshot_capture.status", attributes: eventAttributes)
  }

  private func debugLog(_ message: String) {
    NSLog("[flutter_session_recorder ios] %@", message)
  }

  private func emitEvent(
    type: String,
    timestampMs: Int = Int(Date().timeIntervalSince1970 * 1000),
    attributes: [String: Any]
  ) {
    DispatchQueue.main.async {
      let payload: [String: Any] = [
        "id": UUID().uuidString,
        "type": type,
        "timestampMs": timestampMs,
        "attributes": attributes,
      ]
      guard let sink = self.eventSink else {
        self.pendingEvents.append(payload)
        self.debugLog("Queueing native event until event sink attaches: \(type)")
        return
      }
      sink(payload)
    }
  }

  private func flushPendingEventsIfNeeded() {
    guard let sink = eventSink, !pendingEvents.isEmpty else { return }
    let events = pendingEvents
    pendingEvents.removeAll()
    debugLog("Flushing \(events.count) queued native snapshot event(s)")
    DispatchQueue.main.async {
      events.forEach { sink($0) }
    }
  }
}

private final class IOSNativeCaptureManager: NSObject, UIGestureRecognizerDelegate {
  var eventSink: FlutterEventSink? {
    didSet {
      snapshotCaptureManager.eventSink = eventSink
    }
  }

  private let snapshotCaptureManager = IOSWindowSnapshotCaptureManager()
  private var captureNativeLifecycle = true
  private var captureScrolls = true
  private var captureTaps = true
  private var flutterScreenName: String?
  private var isStarted = false
  private var lastScreenName: String?
  private var minimumScrollDelta: CGFloat = 24
  private var panRecognizer: UIPanGestureRecognizer?
  private var tapRecognizer: UITapGestureRecognizer?

  func start(config: [String: Any]) {
    captureNativeLifecycle = config.boolValue("captureNativeLifecycle", fallback: true)
    captureScrolls = config.boolValue("captureScrolls", fallback: true)
    captureTaps = config.boolValue("captureTaps", fallback: true)
    minimumScrollDelta = CGFloat(config.doubleValue("minimumScrollDelta", fallback: 24))
    isStarted = true

    registerLifecycleObservers()
    attachGestureRecognizersIfNeeded()
    emitScreenView(reason: "start")
  }

  func stop() {
    isStarted = false
    flutterScreenName = nil
    snapshotCaptureManager.stop { _ in }
    NotificationCenter.default.removeObserver(self)
    detachGestureRecognizers()
  }

  func pause() {
    guard isStarted else { return }
    snapshotCaptureManager.stop { _ in }
    detachGestureRecognizers()
  }

  func resume(config: [String: Any]) {
    guard isStarted else {
      start(config: config)
      return
    }

    captureNativeLifecycle = config.boolValue("captureNativeLifecycle", fallback: captureNativeLifecycle)
    captureScrolls = config.boolValue("captureScrolls", fallback: captureScrolls)
    captureTaps = config.boolValue("captureTaps", fallback: captureTaps)
    attachGestureRecognizersIfNeeded()
    emitScreenView(reason: "resume_capture")
  }

  func startSnapshotCapture(config: [String: Any], result: @escaping FlutterResult) {
    snapshotCaptureManager.screenNameProvider = { [weak self] in
      self?.currentScreenName()
    }
    snapshotCaptureManager.start(config: config, result: result)
  }

  func stopSnapshotCapture(result: @escaping FlutterResult) {
    snapshotCaptureManager.stop { error in
      DispatchQueue.main.async {
        if let error = error {
          result(FlutterError(
            code: "SNAPSHOT_CAPTURE_STOP_FAILED",
            message: error.localizedDescription,
            details: nil
          ))
          return
        }
        result(nil)
      }
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
    var attributes: [String: Any] = [
      "state": "resumed",
    ]
    addCurrentScreenName(to: &attributes)
    emitEvent(type: "native.lifecycle", attributes: attributes)
    emitScreenView(reason: "resume")
  }

  @objc private func appWillResignActive() {
    var attributes: [String: Any] = [
      "state": "paused",
    ]
    addCurrentScreenName(to: &attributes)
    emitEvent(type: "native.lifecycle", attributes: attributes)
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
    var attributes: [String: Any] = [
      "dx": point.x,
      "dy": point.y,
    ]
    addCurrentScreenName(to: &attributes)
    emitEvent(type: "interaction.tap", attributes: attributes)
  }

  @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
    let translation = recognizer.translation(in: recognizer.view)
    if abs(translation.y) < minimumScrollDelta && abs(translation.x) < minimumScrollDelta {
      return
    }
    var attributes: [String: Any] = [
      "axis": abs(translation.y) >= abs(translation.x) ? "vertical" : "horizontal",
      "dx": translation.x,
      "dy": translation.y,
    ]
    addCurrentScreenName(to: &attributes)
    emitEvent(type: "interaction.scroll", attributes: attributes)
    recognizer.setTranslation(.zero, in: recognizer.view)
  }

  private func emitScreenView(reason: String) {
    let screenName = currentScreenName()
    if screenName != lastScreenName {
      lastScreenName = screenName
      var attributes: [String: Any] = [
        "properties": [
          "source": "ios_native",
          "reason": reason,
        ],
      ]
      if let screenName {
        attributes["screenName"] = screenName
      }
      emitEvent(type: "screen.view", attributes: attributes)
    }

    return
  }

  private func addCurrentScreenName(to attributes: inout [String: Any]) {
    if let screenName = currentScreenName() {
      attributes["screenName"] = screenName
    }
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

  func intValue(_ key: String, fallback: Int) -> Int {
    if let value = self[key] as? Int {
      return value
    }
    if let value = self[key] as? Double {
      return Int(value)
    }
    return fallback
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

private extension String {
  var nonEmptyValue: String? {
    isEmpty ? nil : self
  }
}
