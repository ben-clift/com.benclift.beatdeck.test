package es.manifold.sidedeck

import android.annotation.SuppressLint
import android.app.Presentation
import android.content.Context
import android.graphics.Color
import android.hardware.display.DisplayManager
import android.os.Bundle
import android.view.Display
import android.view.WindowManager
import android.webkit.JavascriptInterface
import android.webkit.WebView

/**
 * The visuals on a second screen (an HDMI or USB-C projector, or a wireless
 * display), while the phone keeps the DJ controls. It loads the same MilkDrop
 * page the Booth uses, so the settings and the music levels are sent to it
 * with the same JavaScript.
 */
class ProjectorPresentation(context: Context, display: Display) : Presentation(context, display) {
    private var web: WebView? = null

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        window?.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val w = WebView(context)
        w.setBackgroundColor(Color.BLACK)
        w.settings.javaScriptEnabled = true
        w.settings.mediaPlaybackRequiresUserGesture = false
        w.settings.allowFileAccess = true
        // The page reports progress through Md.postMessage; nothing needs it here.
        w.addJavascriptInterface(object {
            @JavascriptInterface
            fun postMessage(@Suppress("UNUSED_PARAMETER") m: String) {}
        }, "Md")
        w.loadUrl("file:///android_asset/flutter_assets/assets/milkdrop/index.html")
        web = w
        setContentView(w)
    }

    fun run(js: String) {
        web?.evaluateJavascript(js, null)
    }

    override fun onStop() {
        web?.destroy()
        web = null
        super.onStop()
    }

    companion object {
        private var current: ProjectorPresentation? = null

        /** Screens that can show a presentation (HDMI, wireless display). */
        fun displays(context: Context): List<Display> {
            val dm = context.getSystemService(Context.DISPLAY_SERVICE) as DisplayManager
            return dm.getDisplays(DisplayManager.DISPLAY_CATEGORY_PRESENTATION).toList()
        }

        /** Shows the visuals on the first second screen. Returns its name, or null if there is none. */
        fun start(context: Context): String? {
            stop()
            val d = displays(context).firstOrNull() ?: return null
            return try {
                val p = ProjectorPresentation(context, d)
                p.show()
                current = p
                d.name
            } catch (_: Exception) {
                current = null
                null
            }
        }

        fun stop() {
            try {
                current?.dismiss()
            } catch (_: Exception) {
            }
            current = null
        }

        /** True while the picture is showing on a second screen. */
        fun active(): Boolean = current?.isShowing == true

        fun js(code: String) {
            current?.run(code)
        }
    }
}
