package com.hubhive.flutter_session_recorder

import android.app.Activity
import android.app.Application
import android.content.Context
import android.content.res.ColorStateList
import android.graphics.Color
import android.graphics.drawable.ColorDrawable
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.view.ViewTreeObserver
import android.view.Window
import android.widget.CompoundButton
import android.widget.EditText
import android.widget.ImageView
import android.widget.ProgressBar
import android.widget.RatingBar
import android.widget.ScrollView
import android.widget.TextView
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
    private lateinit var captureManager: AndroidReplayCaptureManager
    private var activity: Activity? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel = MethodChannel(binding.binaryMessenger, "flutter_session_recorder/methods")
        eventChannel = EventChannel(binding.binaryMessenger, "flutter_session_recorder/events")
        captureManager = AndroidReplayCaptureManager(binding.applicationContext)
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

private class AndroidReplayCaptureManager(
    private val context: Context,
) {
    var eventSink: EventChannel.EventSink? = null

    private val handler = Handler(Looper.getMainLooper())
    private var activity: Activity? = null
    private var captureNativeLifecycle = true
    private var captureNativeViewHierarchy = true
    private var captureScrolls = true
    private var captureTaps = true
    private var flutterScreenName: String? = null
    private var isStarted = false
    private var maskAllText = false
    private var maskTextInputs = true
    private var minimumScrollDelta = 24.0
    private var previousWindowCallback: Window.Callback? = null
    private var previousScreenName: String? = null
    private var scrollEventThrottleMs: Long = 250
    private var snapshotIntervalMs: Long = 700
    private var viewTreeObserver: ViewTreeObserver? = null
    private var scrollListener: ViewTreeObserver.OnScrollChangedListener? = null
    private var lastScrollAtMs: Long = 0
    private var lastScrollY: Int? = null

    private val snapshotRunnable = object : Runnable {
        override fun run() {
            emitScreenAndFrame(reason = "interval")
            if (isStarted) {
                handler.postDelayed(this, snapshotIntervalMs)
            }
        }
    }

    private val lifecycleCallbacks = object : Application.ActivityLifecycleCallbacks {
        override fun onActivityCreated(activity: Activity, savedInstanceState: android.os.Bundle?) {}
        override fun onActivityStarted(activity: Activity) {}
        override fun onActivityResumed(activity: Activity) {
            if (captureNativeLifecycle && this@AndroidReplayCaptureManager.activity === activity) {
                emitEvent(
                    type = "native.lifecycle",
                    attributes = mutableMapOf(
                        "state" to "resumed",
                        "screenName" to currentScreenName(),
                    ),
                )
                emitScreenAndFrame(reason = "resume")
            }
        }

        override fun onActivityPaused(activity: Activity) {
            if (captureNativeLifecycle && this@AndroidReplayCaptureManager.activity === activity) {
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
        captureNativeViewHierarchy = config.booleanValue("captureNativeViewHierarchy", true)
        captureScrolls = config.booleanValue("captureScrolls", true)
        captureTaps = config.booleanValue("captureTaps", true)
        maskAllText = config.booleanValue("maskAllText", false)
        maskTextInputs = config.booleanValue("maskTextInputs", true)
        minimumScrollDelta = config.doubleValue("minimumScrollDelta", 24.0)
        scrollEventThrottleMs = config.longValue("scrollEventThrottleMs", 250)
        snapshotIntervalMs = config.longValue("nativeViewTreeSnapshotIntervalMs", 700)
        isStarted = true

        (context.applicationContext as? Application)?.registerActivityLifecycleCallbacks(lifecycleCallbacks)
        installOnActivity()
        handler.removeCallbacks(snapshotRunnable)
        if (captureNativeViewHierarchy) {
            handler.post(snapshotRunnable)
        }
        emitScreenAndFrame(reason = "start")
    }

    fun stop() {
        isStarted = false
        flutterScreenName = null
        handler.removeCallbacks(snapshotRunnable)
        uninstallFromActivity()
        (context.applicationContext as? Application)?.unregisterActivityLifecycleCallbacks(lifecycleCallbacks)
    }

    fun pause() {
        if (!isStarted) {
            return
        }

        handler.removeCallbacks(snapshotRunnable)
        uninstallFromActivity()
    }

    fun resume(config: Map<String, Any?>) {
        if (!isStarted) {
            start(config)
            return
        }

        captureNativeLifecycle = config.booleanValue("captureNativeLifecycle", captureNativeLifecycle)
        captureNativeViewHierarchy = config.booleanValue("captureNativeViewHierarchy", captureNativeViewHierarchy)
        captureScrolls = config.booleanValue("captureScrolls", captureScrolls)
        captureTaps = config.booleanValue("captureTaps", captureTaps)
        snapshotIntervalMs = config.longValue("nativeViewTreeSnapshotIntervalMs", snapshotIntervalMs)
        installOnActivity()
        handler.removeCallbacks(snapshotRunnable)
        if (captureNativeViewHierarchy) {
            handler.post(snapshotRunnable)
        }
        emitScreenAndFrame(reason = "resume_capture")
    }

    fun setScreenName(screenName: String?) {
        flutterScreenName = screenName?.trim()?.takeIf { it.isNotEmpty() }
    }

    fun setActivity(activity: Activity?) {
        uninstallFromActivity()
        this.activity = activity
        if (isStarted) {
            installOnActivity()
            emitScreenAndFrame(reason = "activity_attached")
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

        if (captureScrolls || captureNativeViewHierarchy) {
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

    private fun emitScreenAndFrame(reason: String) {
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

        if (!captureNativeViewHierarchy) {
            return
        }

        val rootTree = buildRootTree() ?: return
        emitEvent(
            type = "replay.frame",
            attributes = mutableMapOf(
                "screenName" to screenName,
                "tree" to rootTree,
                "metadata" to mutableMapOf(
                    "platform" to "android",
                    "reason" to reason,
                    "captureStrategy" to "native_view_hierarchy",
                ),
                "viewport" to buildViewport(),
            ),
        )
    }

    private fun buildRootTree(): Map<String, Any?>? {
        val currentActivity = activity ?: return null
        val rootView = currentActivity.window?.decorView?.rootView ?: return null
        return buildNode(rootView)
    }

    private fun buildNode(view: View): Map<String, Any?> {
        val location = IntArray(2)
        view.getLocationOnScreen(location)
        val bounds = mutableMapOf<String, Any?>(
            "x" to location[0],
            "y" to location[1],
            "width" to view.width,
            "height" to view.height,
        )

        val node = mutableMapOf<String, Any?>(
            "id" to System.identityHashCode(view).toString(),
            "type" to view.javaClass.simpleName,
            "alpha" to view.alpha.toDouble(),
            "bounds" to bounds,
            "clickable" to view.isClickable,
            "contentDescription" to view.contentDescription?.toString(),
            "enabled" to view.isEnabled,
            "focused" to view.isFocused,
            "padding" to mutableMapOf(
                "left" to view.paddingLeft,
                "top" to view.paddingTop,
                "right" to view.paddingRight,
                "bottom" to view.paddingBottom,
            ),
            "render" to buildRenderProperties(view),
            "scrollable" to (view.canScrollVertically(1) || view.canScrollVertically(-1)),
            "selected" to view.isSelected,
            "transform" to mutableMapOf(
                "elevation" to view.elevation.toDouble(),
                "pivotX" to view.pivotX.toDouble(),
                "pivotY" to view.pivotY.toDouble(),
                "rotation" to view.rotation.toDouble(),
                "rotationX" to view.rotationX.toDouble(),
                "rotationY" to view.rotationY.toDouble(),
                "scaleX" to view.scaleX.toDouble(),
                "scaleY" to view.scaleY.toDouble(),
                "translationX" to view.translationX.toDouble(),
                "translationY" to view.translationY.toDouble(),
            ),
            "visible" to (view.visibility == View.VISIBLE),
        )

        if (view is TextView) {
            val maskTextValue = maskAllText || (maskTextInputs && isInputView(view))
            node["text"] = if (maskTextValue) "•••" else view.text?.toString()
            node["hint"] = if (maskTextValue) "•••" else view.hint?.toString()
            node["textStyle"] = mutableMapOf(
                "alignment" to gravityToAlignment(view.gravity),
                "color" to colorIntToHex(view.currentTextColor),
                "fontSizeSp" to pxToSp(view.textSize),
                "fontStyle" to if (view.typeface?.isItalic == true) "italic" else "normal",
                "fontWeight" to if (view.typeface?.isBold == true) "700" else "400",
                "lineHeightPx" to view.lineHeight.toDouble(),
                "maxLines" to view.maxLines,
                "textAlignment" to textAlignmentToString(view.textAlignment),
            )
        }

        if (view is EditText) {
            node["inputType"] = view.inputType
        }

        if (view is ImageView) {
            node["image"] = mutableMapOf(
                "hasDrawable" to (view.drawable != null),
                "scaleType" to view.scaleType.name,
                "tintColor" to colorStateListToHex(view.imageTintList),
            )
        }

        if (view is CompoundButton) {
            node["checked"] = view.isChecked
        }

        if (view is ProgressBar) {
            node["progress"] = mutableMapOf(
                "indeterminate" to view.isIndeterminate,
                "max" to view.max,
                "progress" to view.progress,
            )
        }

        if (view is RatingBar) {
            node["rating"] = view.rating.toDouble()
        }

        if (view is ScrollView) {
            val child = if (view.childCount > 0) view.getChildAt(0) else null
            node["contentOffset"] = mutableMapOf(
                "x" to view.scrollX,
                "y" to view.scrollY,
            )
            node["contentSize"] = mutableMapOf(
                "width" to (child?.width ?: view.width),
                "height" to (child?.height ?: view.height),
            )
        }

        if (view is ViewGroup) {
            val children = ArrayList<Map<String, Any?>>(view.childCount)
            for (index in 0 until view.childCount) {
                val childNode = buildNode(view.getChildAt(index)).toMutableMap()
                childNode["childIndex"] = index
                children.add(childNode)
            }
            node["children"] = children
        }

        return node
    }

    private fun buildViewport(): Map<String, Any?> {
        val currentActivity = activity ?: return emptyMap()
        val rootView = currentActivity.window?.decorView?.rootView ?: return emptyMap()
        val metrics = rootView.resources.displayMetrics
        return mutableMapOf(
            "density" to metrics.density.toDouble(),
            "height" to rootView.height,
            "statusBarHeight" to systemBarDimension("status_bar_height"),
            "navigationBarHeight" to systemBarDimension("navigation_bar_height"),
            "width" to rootView.width,
        )
    }

    private fun buildRenderProperties(view: View): Map<String, Any?> {
        val background = serializeBackground(view.background)
        return mutableMapOf(
            "background" to background,
            "clipChildren" to (view as? ViewGroup)?.clipChildren,
            "clipToPadding" to (view as? ViewGroup)?.clipToPadding,
        )
    }

    private fun serializeBackground(background: android.graphics.drawable.Drawable?): Map<String, Any?>? {
        background ?: return null
        return when (background) {
            is ColorDrawable -> mutableMapOf(
                "type" to "solid",
                "color" to colorIntToHex(background.color),
            )

            is GradientDrawable -> mutableMapOf(
                "type" to "gradient",
                "color" to colorIntToHex(background.color?.defaultColor ?: Color.TRANSPARENT),
                "cornerRadius" to background.cornerRadius.toDouble(),
                "shape" to gradientShapeToString(background.shape),
            )

            else -> mutableMapOf(
                "type" to background.javaClass.simpleName,
            )
        }
    }

    private fun systemBarDimension(name: String): Int {
        val resourceId = context.resources.getIdentifier(name, "dimen", "android")
        if (resourceId == 0) {
            return 0
        }
        return context.resources.getDimensionPixelSize(resourceId)
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

    private fun isInputView(view: TextView): Boolean {
        val inputType = view.inputType
        return inputType and InputType.TYPE_CLASS_TEXT != 0 ||
            inputType and InputType.TYPE_CLASS_NUMBER != 0 ||
            inputType and InputType.TYPE_TEXT_VARIATION_PASSWORD != 0
    }

    private fun pxToSp(px: Float): Double {
        val metrics = context.resources.displayMetrics
        return (px / metrics.scaledDensity).toDouble()
    }

    private fun gravityToAlignment(gravity: Int): String {
        return when {
            gravity and Gravity.CENTER_HORIZONTAL == Gravity.CENTER_HORIZONTAL -> "center"
            gravity and Gravity.END == Gravity.END || gravity and Gravity.RIGHT == Gravity.RIGHT -> "end"
            else -> "start"
        }
    }

    private fun textAlignmentToString(alignment: Int): String {
        return when (alignment) {
            View.TEXT_ALIGNMENT_CENTER -> "center"
            View.TEXT_ALIGNMENT_TEXT_END, View.TEXT_ALIGNMENT_VIEW_END -> "end"
            View.TEXT_ALIGNMENT_TEXT_START, View.TEXT_ALIGNMENT_VIEW_START -> "start"
            else -> "inherit"
        }
    }

    private fun gradientShapeToString(shape: Int): String {
        return when (shape) {
            GradientDrawable.OVAL -> "oval"
            GradientDrawable.LINE -> "line"
            GradientDrawable.RING -> "ring"
            else -> "rectangle"
        }
    }
}

private fun colorIntToHex(color: Int): String {
    return String.format("#%08X", color)
}

private fun colorStateListToHex(colorStateList: ColorStateList?): String? {
    return colorStateList?.defaultColor?.let(::colorIntToHex)
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
