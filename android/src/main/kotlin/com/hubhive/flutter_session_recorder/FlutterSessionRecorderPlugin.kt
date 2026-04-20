package com.hubhive.flutter_session_recorder

import android.app.Activity
import android.app.Application
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Canvas
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.view.PixelCopy
import android.view.MotionEvent
import android.view.SurfaceView
import android.view.TextureView
import android.view.View
import android.view.ViewGroup
import android.view.ViewTreeObserver
import android.view.Window
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.util.UUID
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

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
        captureManager.dispose()
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
                @Suppress("UNCHECKED_CAST")
                captureManager.startSnapshotCapture(
                    (call.arguments as? Map<String, Any?>) ?: emptyMap(),
                    result,
                )
            }

            "stopSnapshotCapture" -> {
                captureManager.stopSnapshotCapture(result)
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

private class AndroidWindowSnapshotCaptureManager(
    private val context: Context,
) {
    var activity: Activity? = null
    var eventSink: EventChannel.EventSink? = null
    var screenNameProvider: (() -> String?)? = null

    private val mainHandler = Handler(Looper.getMainLooper())
    private val writerThread = HandlerThread("flutter_session_recorder.snapshot_writer").apply {
        start()
    }
    private val writerHandler = Handler(writerThread.looper)
    private var isRecording = false
    private var jpegQuality = 65
    private var maxDimension = 720
    private var sequence = 0
    private var snapshotIntervalMs = 500L
    private var snapshotRunnable: Runnable? = null

    fun start(config: Map<String, Any?>, result: MethodChannel.Result) {
        mainHandler.post {
            if (isRecording) {
                result.success(null)
                return@post
            }

            snapshotIntervalMs = max(250L, config.longValue("nativeSnapshotIntervalMs", 500L))
            jpegQuality = config.doubleValue("nativeSnapshotJpegQuality", 0.65)
                .coerceIn(0.2, 0.95)
                .times(100)
                .roundToInt()
            maxDimension = max(240, config.intValue("nativeSnapshotMaxDimension", 720))
            sequence = 0
            isRecording = true

            emitStatus(
                phase = "started",
                message = "Android window snapshot capture started.",
                attributes = mutableMapOf(
                    "captureStrategy" to "android_flutter_render_surface",
                    "fallbackCaptureStrategy" to fallbackCaptureStrategyName(),
                    "jpegQuality" to jpegQuality / 100.0,
                    "maxDimension" to maxDimension,
                    "snapshotIntervalMs" to snapshotIntervalMs,
                ),
            )
            scheduleNextSnapshot()
            result.success(null)
        }
    }

    fun stop() {
        mainHandler.post {
            isRecording = false
            snapshotRunnable?.let { mainHandler.removeCallbacks(it) }
            snapshotRunnable = null
        }
    }

    fun dispose() {
        stop()
        writerThread.quitSafely()
    }

    private fun scheduleNextSnapshot() {
        snapshotRunnable?.let { mainHandler.removeCallbacks(it) }
        if (!isRecording) {
            return
        }

        val runnable = Runnable {
            captureSnapshotFrame()
        }
        snapshotRunnable = runnable
        mainHandler.postDelayed(runnable, snapshotIntervalMs)
    }

    private fun captureSnapshotFrame() {
        if (!isRecording) {
            return
        }

        val currentActivity = activity
        val window = currentActivity?.window
        val decorView = window?.decorView
        if (currentActivity == null || window == null || decorView == null || decorView.width <= 0 || decorView.height <= 0) {
            emitStatus(
                phase = "snapshot_skipped",
                level = "warning",
                message = "Unable to snapshot the active Android window.",
            )
            scheduleNextSnapshot()
            return
        }

        val renderView = findFlutterRenderView(decorView)
        if (renderView is TextureView && renderView.width > 0 && renderView.height > 0) {
            captureTextureView(renderView)
            return
        }

        if (renderView is SurfaceView &&
            renderView.width > 0 &&
            renderView.height > 0 &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
        ) {
            captureSurfaceView(renderView)
            return
        }

        captureWindowOrDecor(window, decorView)
    }

    private fun captureSurfaceView(surfaceView: SurfaceView) {
        val scale = captureScaleForView(surfaceView)
        val width = max(1, (surfaceView.width * scale).roundToInt())
        val height = max(1, (surfaceView.height * scale).roundToInt())
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)

        try {
            PixelCopy.request(surfaceView, bitmap, { result ->
                if (!isRecording) {
                    bitmap.recycle()
                } else if (result == PixelCopy.SUCCESS) {
                    writeSnapshot(bitmap, "android_flutter_surface_pixel_copy")
                } else {
                    bitmap.recycle()
                    captureWindowOrDecor(activity?.window, activity?.window?.decorView)
                }
            }, mainHandler)
        } catch (error: Throwable) {
            bitmap.recycle()
            captureWindowOrDecor(activity?.window, activity?.window?.decorView, error)
        }
    }

    private fun captureTextureView(textureView: TextureView) {
        try {
            val scale = captureScaleForView(textureView)
            val width = max(1, (textureView.width * scale).roundToInt())
            val height = max(1, (textureView.height * scale).roundToInt())
            val bitmap = textureView.getBitmap(width, height)
            if (bitmap != null) {
                writeSnapshot(bitmap, "android_flutter_texture_view")
            } else {
                captureWindowOrDecor(activity?.window, activity?.window?.decorView)
            }
        } catch (error: Throwable) {
            captureWindowOrDecor(activity?.window, activity?.window?.decorView, error)
        }
    }

    private fun captureWindowOrDecor(
        window: Window?,
        decorView: View?,
        originalError: Throwable? = null,
    ) {
        if (!isRecording || decorView == null || decorView.width <= 0 || decorView.height <= 0) {
            originalError?.let { emitError(it) }
            scheduleNextSnapshot()
            return
        }

        val scale = captureScaleForView(decorView)
        val width = max(1, (decorView.width * scale).roundToInt())
        val height = max(1, (decorView.height * scale).roundToInt())
        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)

        if (window != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                PixelCopy.request(window, bitmap, { result ->
                    if (!isRecording) {
                        bitmap.recycle()
                    } else if (result == PixelCopy.SUCCESS) {
                        writeSnapshot(bitmap, "android_pixel_copy")
                    } else {
                        bitmap.recycle()
                        captureWithDecorDraw(decorView, scale, width, height, originalError)
                    }
                }, mainHandler)
            } catch (error: Throwable) {
                bitmap.recycle()
                captureWithDecorDraw(decorView, scale, width, height, originalError ?: error)
            }
        } else {
            bitmap.recycle()
            captureWithDecorDraw(decorView, scale, width, height, originalError)
        }
    }

    private fun captureWithDecorDraw(
        decorView: View,
        scale: Float,
        width: Int,
        height: Int,
        originalError: Throwable? = null,
    ) {
        if (!isRecording) {
            return
        }

        val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
        try {
            val canvas = Canvas(bitmap)
            canvas.scale(scale, scale)
            decorView.draw(canvas)
            writeSnapshot(bitmap, "android_view_draw")
        } catch (error: Throwable) {
            bitmap.recycle()
            emitError(originalError ?: error)
            scheduleNextSnapshot()
        }
    }

    private fun writeSnapshot(bitmap: Bitmap, captureStrategy: String) {
        if (!isRecording) {
            bitmap.recycle()
            return
        }
        val timestampMs = System.currentTimeMillis()
        sequence += 1
        val snapshotId = "android_${timestampMs}_$sequence"
        val file = File.createTempFile(
            "flutter_session_recorder_snapshot_",
            ".jpg",
            context.cacheDir,
        )
        val width = bitmap.width
        val height = bitmap.height

        writerHandler.post {
            try {
                FileOutputStream(file).use { stream ->
                    bitmap.compress(Bitmap.CompressFormat.JPEG, jpegQuality, stream)
                }
                emitSnapshotReady(
                    file = file,
                    snapshotId = snapshotId,
                    timestampMs = timestampMs,
                    width = width,
                    height = height,
                    fileSize = file.length(),
                    captureStrategy = captureStrategy,
                )
            } catch (error: Throwable) {
                emitError(error)
            } finally {
                bitmap.recycle()
                mainHandler.post {
                    scheduleNextSnapshot()
                }
            }
        }
    }

    private fun emitSnapshotReady(
        file: File,
        snapshotId: String,
        timestampMs: Long,
        width: Int,
        height: Int,
        fileSize: Long,
        captureStrategy: String,
    ) {
        val attributes = mutableMapOf<String, Any?>(
            "captureStrategy" to captureStrategy,
            "contentType" to "image/jpeg",
            "filePath" to file.absolutePath,
            "fileSize" to fileSize,
            "format" to "jpg",
            "height" to height,
            "platform" to "android",
            "snapshotId" to snapshotId,
            "sequence" to sequence,
            "timestampMs" to timestampMs,
            "width" to width,
        )
        screenNameProvider?.invoke()?.let { screenName ->
            attributes["screenName"] = screenName
        }
        emitEvent(
            type = "replay.snapshot.ready",
            timestampMs = timestampMs,
            attributes = attributes,
        )
    }

    private fun captureScaleForView(view: View): Float {
        val longestSide = max(view.width, view.height)
        if (longestSide <= 0) {
            return 1f
        }
        return min(1f, maxDimension.toFloat() / longestSide.toFloat())
    }

    private fun fallbackCaptureStrategyName(): String {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            "android_pixel_copy"
        } else {
            "android_view_draw"
        }
    }

    private fun findFlutterRenderView(root: View): View? {
        val candidates = mutableListOf<View>()
        collectRenderSurfaceCandidates(root, candidates)
        return candidates
            .filter { it.width > 0 && it.height > 0 && it.visibility == View.VISIBLE }
            .sortedWith(
                compareByDescending<View> {
                    if (it.javaClass.name.contains("Flutter", ignoreCase = true)) 1 else 0
                }
                    .thenByDescending { it.width * it.height },
            )
            .firstOrNull()
    }

    private fun collectRenderSurfaceCandidates(view: View, candidates: MutableList<View>) {
        if (view is SurfaceView || view is TextureView) {
            candidates.add(view)
        }
        if (view is ViewGroup) {
            for (index in 0 until view.childCount) {
                collectRenderSurfaceCandidates(view.getChildAt(index), candidates)
            }
        }
    }

    private fun emitStatus(
        phase: String,
        level: String = "info",
        message: String,
        attributes: MutableMap<String, Any?> = mutableMapOf(),
    ) {
        attributes["level"] = level
        attributes["message"] = message
        attributes["phase"] = phase
        attributes["platform"] = "android"
        emitEvent(type = "native.snapshot_capture.status", attributes = attributes)
    }

    private fun emitError(error: Throwable) {
        emitEvent(
            type = "native.snapshot_capture.error",
            attributes = mutableMapOf(
                "message" to (error.message ?: error::class.java.simpleName),
                "platform" to "android",
            ),
        )
    }

    private fun emitEvent(
        type: String,
        timestampMs: Long = System.currentTimeMillis(),
        attributes: MutableMap<String, Any?>,
    ) {
        val sink = eventSink ?: return
        val payload = mutableMapOf<String, Any?>(
            "id" to UUID.randomUUID().toString(),
            "type" to type,
            "timestampMs" to timestampMs,
            "attributes" to attributes,
        )
        mainHandler.post {
            sink.success(payload)
        }
    }
}

private class AndroidNativeCaptureManager(
    private val context: Context,
) {
    var eventSink: EventChannel.EventSink? = null
        set(value) {
            field = value
            snapshotCaptureManager.eventSink = value
        }

    private val handler = Handler(Looper.getMainLooper())
    private val snapshotCaptureManager = AndroidWindowSnapshotCaptureManager(context)
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
        snapshotCaptureManager.stop()
        uninstallFromActivity()
        (context.applicationContext as? Application)?.unregisterActivityLifecycleCallbacks(lifecycleCallbacks)
    }

    fun dispose() {
        stop()
        snapshotCaptureManager.dispose()
    }

    fun pause() {
        if (!isStarted) {
            return
        }

        snapshotCaptureManager.stop()
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
        snapshotCaptureManager.activity = activity
        if (isStarted) {
            installOnActivity()
            emitScreenView(reason = "activity_attached")
        }
    }

    fun startSnapshotCapture(config: Map<String, Any?>, result: MethodChannel.Result) {
        snapshotCaptureManager.screenNameProvider = { currentScreenName() }
        snapshotCaptureManager.start(config, result)
    }

    fun stopSnapshotCapture(result: MethodChannel.Result) {
        snapshotCaptureManager.stop()
        result.success(null)
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

private fun Map<String, Any?>.intValue(key: String, fallback: Int): Int {
    return when (val value = this[key]) {
        is Int -> value
        is Long -> value.toInt()
        is Double -> value.toInt()
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
