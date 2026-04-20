package com.hubhive.flutter_session_recorder

import android.app.Activity
import android.app.Application
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.MotionEvent
import android.view.View
import android.view.ViewTreeObserver
import android.view.Window
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import kotlin.math.abs

class FlutterSessionRecorderPlugin : FlutterPlugin, MethodChannel.MethodCallHandler,
    ActivityAware, EventChannel.StreamHandler {
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var captureManager: AndroidNativeCaptureManager
    private var activity: Activity? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel = MethodChannel(binding.binaryMessenger, "flutter_session_recorder/methods")
        eventChannel = EventChannel(binding.binaryMessenger, "flutter_session_recorder/events")
        captureManager = AndroidNativeCaptureManager(binding.applicationContext)
        methodChannel.setMethodCallHandler(this)
        eventChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        captureManager.stop()
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        captureManager.eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        captureManager.eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "startCapture" -> {
                @Suppress("UNCHECKED_CAST")
                captureManager.start((call.arguments as? Map<String, Any?>) ?: emptyMap())
                result.success(null)
            }

            "pauseCapture" -> {
                captureManager.pause()
                result.success(null)
            }

            "resumeCapture" -> {
                @Suppress("UNCHECKED_CAST")
                captureManager.resume((call.arguments as? Map<String, Any?>) ?: emptyMap())
                result.success(null)
            }

            "stopCapture" -> {
                captureManager.stop()
                result.success(null)
            }

            "startSnapshotCapture" -> {
                result.success(null)
            }

            "stopSnapshotCapture" -> {
                result.success(null)
            }

            "getDeviceContext" -> {
                result.success(
                    mapOf(
                        "deviceType" to "android",
                        "manufacturer" to Build.MANUFACTURER,
                        "brand" to Build.BRAND,
                        "model" to Build.MODEL,
                        "device" to Build.DEVICE,
                        "product" to Build.PRODUCT,
                        "osName" to "Android",
                        "osVersion" to Build.VERSION.RELEASE,
                        "sdkInt" to Build.VERSION.SDK_INT,
                    ),
                )
            }

            "setScreenName" -> {
                @Suppress("UNCHECKED_CAST")
                val arguments = (call.arguments as? Map<String, Any?>) ?: emptyMap()
                captureManager.setScreenName(arguments["screenName"] as? String)
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        captureManager.setActivity(binding.activity)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
        captureManager.setActivity(null)
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        captureManager.setActivity(binding.activity)
    }

    override fun onDetachedFromActivity() {
        activity = null
        captureManager.setActivity(null)
    }
}

private class AndroidNativeCaptureManager(
    private val context: Context,
) {
    var eventSink: EventChannel.EventSink? = null

    private val handler = Handler(Looper.getMainLooper())
    private var activity: Activity? = null
    private var captureNativeLifecycle = true
    private var captureScrolls = true
    private var captureTaps = true
    private var flutterScreenName: String? = null
    private var isStarted = false
    private var minimumScrollDelta = 24.0
    private var previousWindowCallback: Window.Callback? = null
    private var previousScreenName: String? = null
    private var scrollEventThrottleMs: Long = 250
    private var viewTreeObserver: ViewTreeObserver? = null
    private var scrollListener: ViewTreeObserver.OnScrollChangedListener? = null
    private var lastScrollAtMs: Long = 0
    private var lastScrollY: Int? = null

    private val lifecycleCallbacks = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityCreated(activity: Activity, savedInstanceState: android.os.Bundle?) {}
        override fun onActivityStarted(activity: Activity) {}
        override fun onActivityResumed(activity: Activity) {
            if (captureNativeLifecycle && this@AndroidNativeCaptureManager.activity === activity) {
                emitEvent(
                    type = "native.lifecycle",
                    attributes = mutableMapOf(
                        "state" to "resumed",
                        "screenName" to currentScreenName(),
                    ),
                )
                emitScreenView(reason = "resume")
            }
        }

        override fun onActivityPaused(activity: Activity) {
            if (captureNativeLifecycle && this@AndroidNativeCaptureManager.activity === activity) {
                emitEvent(
                    type = "native.lifecycle",
                    attributes = mutableMapOf(
                        "state" to "paused",
                        "screenName" to currentScreenName(),
                    ),
                )
            }
        }

        override fun onActivityStopped(activity: Activity) {}
        override fun onActivitySaveInstanceState(activity: Activity, outState: android.os.Bundle) {}
        override fun onActivityDestroyed(activity: Activity) {}
    }

    fun start(config: Map<String, Any?>) {
        captureNativeLifecycle = config.booleanValue("captureNativeLifecycle", true)
        captureScrolls = config.booleanValue("captureScrolls", true)
        captureTaps = config.booleanValue("captureTaps", true)
        minimumScrollDelta = config.doubleValue("minimumScrollDelta", 24.0)
        scrollEventThrottleMs = config.longValue("scrollEventThrottleMs", 250)
        isStarted = true

        (context.applicationContext as? Application)?.registerActivityLifecycleCallbacks(lifecycleCallbacks)
        installOnActivity()
        emitScreenView(reason = "start")
    }

    fun stop() {
        isStarted = false
        flutterScreenName = null
        uninstallFromActivity()
        (context.applicationContext as? Application)?.unregisterActivityLifecycleCallbacks(lifecycleCallbacks)
    }

    fun pause() {
        if (!isStarted) {
            return
        }

        uninstallFromActivity()
    }

    fun resume(config: Map<String, Any?>) {
        if (!isStarted) {
            start(config)
            return
        }

        captureNativeLifecycle = config.booleanValue("captureNativeLifecycle", captureNativeLifecycle)
        captureScrolls = config.booleanValue("captureScrolls", captureScrolls)
        captureTaps = config.booleanValue("captureTaps", captureTaps)
        installOnActivity()
        emitScreenView(reason = "resume_capture")
    }

    fun setScreenName(screenName: String?) {
        flutterScreenName = screenName?.trim()?.takeIf { it.isNotEmpty() }
    }

    fun setActivity(activity: Activity?) {
        uninstallFromActivity()
        this.activity = activity
        if (isStarted) {
            installOnActivity()
            emitScreenView(reason = "activity_attached")
        }
    }

    private fun installOnActivity() {
        val currentActivity = activity ?: return
        val decorView = currentActivity.window?.decorView ?: return

        if (captureTaps) {
            val originalCallback = currentActivity.window.callback
            previousWindowCallback = originalCallback
            if (originalCallback != null) {
                currentActivity.window.callback = object : Window.Callback by originalCallback {
                    override fun dispatchTouchEvent(event: MotionEvent): Boolean {
                        if (event.actionMasked == MotionEvent.ACTION_UP) {
                            emitEvent(
                                type = "interaction.tap",
                                attributes = mutableMapOf(
                                    "dx" to event.rawX.toDouble(),
                                    "dy" to event.rawY.toDouble(),
                                    "pointerCount" to event.pointerCount,
                                    "screenName" to currentScreenName(),
                                ),
                            )
                        }
                        return originalCallback.dispatchTouchEvent(event)
                    }
                }
            }
        }

        if (captureScrolls) {
            viewTreeObserver = decorView.viewTreeObserver
            scrollListener = ViewTreeObserver.OnScrollChangedListener {
                if (!captureScrolls) {
                    return@OnScrollChangedListener
                }

                val now = System.currentTimeMillis()
                if (now - lastScrollAtMs < scrollEventThrottleMs) {
                    return@OnScrollChangedListener
                }

                val scrollY = decorView.scrollY
                val previous = lastScrollY
                if (previous != null && abs(scrollY - previous) < minimumScrollDelta) {
                    return@OnScrollChangedListener
                }

                lastScrollAtMs = now
                lastScrollY = scrollY
                emitEvent(
                    type = "interaction.scroll",
                    attributes = mutableMapOf(
                        "screenName" to currentScreenName(),
                        "pixels" to scrollY.toDouble(),
                        "axis" to "vertical",
                        "source" to "decorView",
                    ),
                )
            }
            viewTreeObserver?.addOnScrollChangedListener(scrollListener)
        }
    }

    private fun uninstallFromActivity() {
        val currentActivity = activity
        if (currentActivity != null && previousWindowCallback != null) {
            currentActivity.window.callback = previousWindowCallback
        }
        previousWindowCallback = null

        val observer = viewTreeObserver
        val listener = scrollListener
        if (observer != null && observer.isAlive && listener != null) {
            observer.removeOnScrollChangedListener(listener)
        }
        viewTreeObserver = null
        scrollListener = null
    }

    private fun emitScreenView(reason: String) {
        val screenName = currentScreenName()
        if (screenName != null && screenName != previousScreenName) {
            previousScreenName = screenName
            emitEvent(
                type = "screen.view",
                attributes = mutableMapOf(
                    "screenName" to screenName,
                    "properties" to mutableMapOf(
                        "source" to "android_native",
                        "reason" to reason,
                    ),
                ),
            )
        }

        return
    }

    private fun currentScreenName(): String? {
        flutterScreenName?.let { return it }
        val currentActivity = activity ?: return null
        val title = currentActivity.title?.toString()
        return if (!title.isNullOrBlank()) title else currentActivity::class.java.simpleName
    }

    private fun emitEvent(
        type: String,
        attributes: MutableMap<String, Any?>,
    ) {
        val sink = eventSink ?: return
        val payload = mutableMapOf<String, Any?>(
            "id" to UUID.randomUUID().toString(),
            "type" to type,
            "timestampMs" to System.currentTimeMillis(),
            "attributes" to attributes,
        )
        handler.post {
            sink.success(payload)
        }
    }

}

private fun Map<String, Any?>.booleanValue(key: String, fallback: Boolean): Boolean {
    return (this[key] as? Boolean) ?: fallback
}

private fun Map<String, Any?>.doubleValue(key: String, fallback: Double): Double {
    return when (val value = this[key]) {
        is Double -> value
        is Float -> value.toDouble()
        is Int -> value.toDouble()
        is Long -> value.toDouble()
        else -> fallback
    }
}

private fun Map<String, Any?>.longValue(key: String, fallback: Long): Long {
    return when (val value = this[key]) {
        is Int -> value.toLong()
        is Long -> value
        is Double -> value.toLong()
        else -> fallback
    }
}
