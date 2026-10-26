import Foundation
import ObjectiveC

/// Spec A6: content-process termination. cordova-ios handles `webViewWebContentProcessDidTerminate:`
/// privately in `CDVWebViewEngine` (it reloads), so the hook swizzles that method: report, then
/// run Cordova's original. Unsupported API, so it's gated on the tested major (8), the
/// `EdgeRumIosWebViewHook` kill switch, and the class + selector + signature still being there.
enum WebViewHook {
    static let selector = NSSelectorFromString("webViewWebContentProcessDidTerminate:")
    private static let lock = NSLock()
    private static var hooked = Set<ObjectIdentifier>()

    /// - Returns: true when the hook is on (installed now or before); false → use `PageWatch`.
    @discardableResult
    static func install(_ cls: AnyClass?, cordovaMajor: Int, enabled: Bool, onTerminate: @escaping () -> Void) -> Bool {
        guard enabled, cordovaMajor == 8, let cls, let method = class_getInstanceMethod(cls, selector),
              let types = method_getTypeEncoding(method),
              // `v@:@` with offsets stripped: void, self, _cmd, the WKWebView.
              String(cString: types).filter({ !$0.isNumber }) == "v@:@" else { return false }
        lock.lock(); defer { lock.unlock() }
        guard hooked.insert(ObjectIdentifier(cls)).inserted else { return true }
        typealias Original = @convention(c) (AnyObject, Selector, AnyObject?) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let replacement: @convention(block) (AnyObject, AnyObject?) -> Void = { engine, webView in
            onTerminate()
            original(engine, selector, webView)
        }
        method_setImplementation(method, imp_implementationWithBlock(replacement))
        return true
    }
}

/// Spec A6 fallback, when the hook is off: a page load with no clean shutdown (`pagehide`, sent by
/// JS as a `markPhase`) since the previous load in this process means the content process died
/// and Cordova reloaded the page. Cordova's recovery reloads the same document, so a load of a
/// different one (fragment aside) is a navigation, not a death. Worker queue only.
// ponytail: a same-page reload whose pagehide never reached native still reads as a death;
// inference is the labelled best effort (`webview.detected_by=inference`).
struct PageWatch {
    private var page: String?
    private var clean = false

    /// A page finished loading at `url`. - Returns: true when the previous page died uncleanly.
    mutating func loaded(_ url: URL?) -> Bool {
        var c = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        c?.fragment = nil
        let doc = c?.string ?? ""
        defer {
            page = doc
            clean = false
        }
        return page == doc && !clean
    }

    mutating func hidden() {
        clean = true
    }
}
