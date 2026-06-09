// JsEngine.swift
// Port of WebViewManager.java. Owns a single `WKWebView` that hosts
// bridge.html + quantumcoin-bundle.js and brokers every call to the JS
// side. Exactly one instance per process - enforced by `shared`.
// Android reference:
// app/src/main/java/com/quantumcoinwallet/app/bridge/WebViewManager.java

import Foundation
import Security
import WebKit

/// Callback shape used by `JsBridge` to await bridge results.
public protocol BridgeCallback: AnyObject {
    func onResult(_ json: String)
    func onError(_ message: String)
}

/// Single-process-wide WKWebView host for `bridge.html` +
/// `quantumcoin-bundle.js`.
/// - Initialization happens on the main thread (WKWebView requirement).
/// - `waitUntilReady` blocks a caller until `didFinish` fires for the
/// bundled `appassets://bridge.html` URL.
/// - Must never be invoked from the main thread via
/// `JsBridge.blockingCall` - use the async wrappers.
@MainActor
public final class JsEngine: NSObject {

    // MARK: - Public singleton

    public static let shared = JsEngine()

    // MARK: - JS interface

    /// Name of the `WKScriptMessageHandler` registered on the web content.
    /// Must match the handler string installed by
    /// `WKUserContentController.add(_:name:)` and referenced from the JS
    /// side as `window.webkit.messageHandlers.androidBridge.postMessage`.
    /// The JS side (`bridge.html`) calls through a shim named
    /// `window.AndroidBridge.*` - we install that shim as a
    /// `WKUserScript` at `.atDocumentStart` so legacy JS code continues
    /// to work unchanged.
    private static let interfaceName = "androidBridge"

    /// Custom scheme that resolves to bundled resources. Mirrors
    /// Android's `WebViewAssetLoader` + `https://appassets.androidplatform.net/`.
    private static let assetsScheme = "appassets"
    private static let bridgeURLString = "\(assetsScheme)://bridge.html"

    // MARK: - State

    private var webView: WKWebView!
    private let schemeHandler = AppAssetsSchemeHandler()
    private let pendingCallbacks = PendingCallbackStore()
    private let pendingPayloads = PendingPayloadStore()
    /// two symmetric binary channels staging arbitrary
    /// `Data` between Swift and the JS bridge:
    /// * `pendingBinaryOutbound` is filled by Swift via
    ///   `storePendingPayloadBinary` and consumed by JS via the
    ///   `appassets:///bridge-binary-pull/<rid>/<key>/<token>` XHR.
    ///   This is how Swift sends raw bytes (e.g. private key) into
    ///   the bridge without ever stringifying them.
    /// * `pendingBinaryInbound` is filled by JS via the
    ///   `appassets:///bridge-binary-push/<rid>/<key>/<token>` XHR
    ///   POST and consumed by Swift via
    ///   `consumePendingResultBinary`. This is how the JS bridge
    ///   returns raw bytes (e.g. just-decrypted private key) back
    ///   to Swift without ever stringifying them.
    /// Both stores are token-checked single-use, identical security
    /// posture to `pendingPayloads`.
    private let pendingBinaryOutbound = PendingBinaryStore()
    private let pendingBinaryInbound = PendingBinaryStore()
    private let ready = AtomicBool()
    private let readyLatch = OneShotLatch()

    /// Last navigation-failure error captured by the
    /// WKNavigationDelegate, so callers waiting on
    /// `waitUntilReady` can surface it instead of just timing
    /// out with a generic "Bridge not ready" message. Read by
    /// `lastLoadFailureDescription` and by AppDelegate's splash.
    /// Marked `nonisolated(unsafe)` because the surrounding class
    /// is `@MainActor` but the navigation-failure delegates and
    /// the splash-screen reader both access this state from
    /// outside the main-actor context. Safety is provided by
    /// `lastFailureLock` (an NSLock, value-typed and Sendable):
    /// every read and every write goes through that lock, so
    /// "unsafe" here means "the compiler cannot prove it" rather
    /// than "this code has a data race".
    private nonisolated(unsafe) let lastFailureLock = NSLock()
    private nonisolated(unsafe) var _lastFailure: String?

    // MARK: - Init

    private override init() {
        super.init()
        createWebView()
    }

    // MARK: - Public API

    /// `true` after `bridge.html` has finished loading (and the JS SDK
    /// has registered its `bridge` global).
    public var isReady: Bool { ready.value }

    /// Block the current thread until the bridge is ready or `timeout`
    /// seconds elapse. Safe to call from any thread; internally hops to
    /// the main thread only for the `WKWebView` handshake.
    /// - Returns: `true` if the bridge became ready, `false` on timeout.
    nonisolated public func waitUntilReady(timeout: TimeInterval = 30) -> Bool {
        // readyLatch is nonisolated and Sendable; no MainActor hop needed.
        return readyLatch.await(timeout: timeout)
    }

    /// Diagnostic accessor: most recent navigation failure
    /// reported by the WKNavigationDelegate, formatted for UI.
    /// Returns `nil` if no failure was recorded. Safe from any
    /// thread.
    nonisolated public var lastLoadFailureDescription: String? {
        lastFailureLock.lock(); defer { lastFailureLock.unlock() }
        return _lastFailure
    }

    /// Internal: record a navigation failure and unblock anyone
    /// waiting on `waitUntilReady` so callers fail fast instead of
    /// timing out with a generic "Bridge not ready" message.
    /// `nonisolated` because the navigation-failure delegate
    /// methods can fire from non-MainActor contexts in some
    /// WebKit error paths.
    fileprivate nonisolated func recordLoadFailure(_ description: String) {
        lastFailureLock.lock()
        _lastFailure = description
        lastFailureLock.unlock()
        readyLatch.signal()
    }

    /// Fire-and-forget JavaScript evaluation, main-thread safe.
    /// `nonisolated` so background callers (e.g. `JsBridge.blockingCall`)
    /// can invoke without an `await`; the body hops to the main actor
    /// before touching `webView`.
    nonisolated public func evaluate(_ script: String, completion: ((Any?, Error?) -> Void)? = nil) {
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                self.webView.evaluateJavaScript(script, completionHandler: completion)
            }
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.webView.evaluateJavaScript(script, completionHandler: completion)
                }
            }
        }
    }

    /// Register a callback under `requestId`. Returns after the callback
    /// table has accepted the entry; the caller is responsible for
    /// supplying the matching `evaluate(...)` call.
    /// `nonisolated` because `pendingCallbacks` is a Sendable lock-backed
    /// store and is safe from any thread.
    nonisolated public func registerCallback(requestId: String, callback: BridgeCallback) {
        pendingCallbacks.set(callback, for: requestId)
    }

    /// Stage a JSON payload for pull-model delivery. Bounded by
    /// `PendingPayloadStore.maxEntries` to prevent runaway growth if the
    /// JS side never pulls. Atomically generates a per-request
    /// capability token, stores it alongside the payload, AND
    /// injects the token into the WebView's `window.__bridgeTokens`
    /// map so the JS-side `getPendingPayload` shim can present it
    /// in the XHR URL. See `PendingPayloadStore`.
    nonisolated public func storePendingPayload(requestId: String, json: String) throws {
        let token = try pendingPayloads.put(requestId: requestId, json: json)
        injectBridgeToken(requestId: requestId, token: token)
    }

    /// Push the per-request token into the WKWebView's per-rid
    /// token map. Called from `storePendingPayload` and synchronised
    /// onto the main actor since `WKWebView.evaluateJavaScript`
    /// requires main-thread invocation.
    nonisolated private func injectBridgeToken(requestId: String, token: String) {
        let snippet = "(window.__bridgeTokens=window.__bridgeTokens||{})"
        + "['\(requestId)']='\(token)';"
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(snippet, completionHandler: nil)
        }
    }

    /// Stage `data` for outbound (Swift -> JS) binary delivery,
    /// keyed by `(requestId, key)`. The token returned is also
    /// injected into `window.__bridgeBinaryTokens[requestId][key]`
    /// so the JS-side `pullPayloadBinary` shim can present it.
    /// Single-use: the JS XHR consumes the entry on first read,
    /// and a replay returns 404.
    nonisolated public func storePendingPayloadBinary(
        requestId: String, key: String, data: Data) throws {
        let token = try pendingBinaryOutbound.put(
            requestId: requestId, key: key, data: data)
        injectBinaryToken(direction: "out",
            requestId: requestId, key: key, token: token)
    }

    /// Consume the inbound (JS -> Swift) binary result staged by
    /// the JS `stagePendingResultBinary` helper for `(requestId,
    /// key)`. Returns nil if the slot is missing, expired, or has
    /// already been consumed. The caller is expected to wipe the
    /// returned `Data` after use via
    /// `defer { result.resetBytes(in: 0..<result.count) }`.
    /// `token` is the per-stage token Swift handed to JS at stage
    /// time; we hold both ends so the SchemeHandler check uses
    /// the same constant-time comparison path as the outbound
    /// channel.
    nonisolated public func consumePendingResultBinary(
        requestId: String, key: String) -> Data? {
        return pendingBinaryInbound.takeAny(requestId: requestId, key: key)
    }

    /// Pre-register a token for an inbound (JS -> Swift) binary
    /// slot. The caller (JsBridge facade) generates the request
    /// id, asks JsEngine to mint a token, injects it into the
    /// `window.__bridgeBinaryTokens['in'][rid][key]` map for the
    /// JS handler to read, and waits for the JS handler to POST
    /// to the matching `bridge-binary-push` URL. The
    /// SchemeHandler validates the token before storing the body
    /// in `pendingBinaryInbound`.
    nonisolated public func reserveInboundBinarySlot(
        requestId: String, key: String) throws {
        let token = try pendingBinaryInbound.reserve(
            requestId: requestId, key: key)
        injectBinaryToken(direction: "in",
            requestId: requestId, key: key, token: token)
    }

    /// Inject a per-(rid, key) binary capability token into the
    /// WKWebView's `window.__bridgeBinaryTokens` map. Direction is
    /// `"out"` for Swift -> JS pulls and `"in"` for JS -> Swift
    /// pushes; the JS shims look up by direction so a malicious
    /// rid mismatch on either side cannot reuse the other side's
    /// token.
    nonisolated private func injectBinaryToken(direction: String,
        requestId: String, key: String, token: String) {
        let snippet = """
        (function(){
        var t = window.__bridgeBinaryTokens = window.__bridgeBinaryTokens || {};
        var d = t['\(direction)'] = t['\(direction)'] || {};
        var r = d['\(requestId)'] = d['\(requestId)'] || {};
        r['\(key)'] = '\(token)';
        })();
        """
        DispatchQueue.main.async { [weak self] in
            self?.webView?.evaluateJavaScript(snippet, completionHandler: nil)
        }
    }

    /// Remove a staged payload without delivering it. Called by
    /// `JsBridge.blockingCall` on the timeout / error path so sensitive
    /// strings do not linger.
    nonisolated public func removePendingPayload(requestId: String) {
        pendingPayloads.remove(requestId)
    }

    // MARK: - Internal

    private func createWebView() {
        let config = WKWebViewConfiguration()
        // iOS 14+ replacement for the deprecated
        // `preferences.javaScriptEnabled = true`. Deployment target is
        // 15.0 (project.yml) so the older API is unreachable.
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        // mirrors WebSettings.setDomStorageEnabled(false) + MediaPlaybackRequiresUserGesture.
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = .all
        // (revised): we deliberately do NOT set
        // `limitsNavigationsToAppBoundDomains = true` here.
        // Why the previous defense-in-depth setup is wrong (design rationale :
        // Apple's WKAppBoundDomains feature (TN3171) only applies
        // to navigations using HTTP and HTTPS schemes. The wallet's
        // bundle is loaded exclusively through the custom
        // `appassets://` scheme via `WKURLSchemeHandler`, which is
        // intercepted before any networking layer and is therefore
        // not subject to the app-bound-domains policy regardless of
        // the configuration flag.
        // Worse, the prior Info.plist setup placed the literal
        // string `"appassets"` (a URL-scheme name, not a domain
        // name) inside `WKAppBoundDomains`. With strict mode
        // enabled and a malformed entry, iOS 17+ / iOS 26 silently
        // blocks the bridge load, which surfaces in the UI as
        // "Bridge not ready" after a 30-second timeout because the
        // navigation-finish delegate never fires.
        // The actual defense the design finding wanted is
        // already provided by:
        // 1. The custom-scheme-only design: there is literally
        // no http(s) navigation path inside this WebView
        // (`bridge.html` has no <script src="https://..."> or
        // <link href="https://...">; the only resource it
        // references is the local `quantumcoin-bundle.js`).
        // 2. in `AppAssetsSchemeHandler` which
        // gates every served resource against an explicit
        // bundle-resource allowlist, so even a hypothetical
        // injection cannot reach an unrelated bundle file.
        // 3. bundle-hash pin, which detects any
        // modification of the JS bundle bytes themselves.
        // If a future change ever introduces an https:// load into
        // this WebView (we currently have none), this is the
        // single line to flip back on - and the corresponding
        // `WKAppBoundDomains` array MUST contain real public-
        // suffix-list hostnames, NOT scheme names.

        let ucc = WKUserContentController()
        ucc.add(ScriptMessageBroker(owner: self), name: Self.interfaceName)
        ucc.addUserScript(Self.makeAndroidBridgeShim())
        config.userContentController = ucc

        schemeHandler.owner = self
        config.setURLSchemeHandler(schemeHandler, forURLScheme: Self.assetsScheme)

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        wv.isHidden = true
        self.webView = wv

        guard let url = URL(string: Self.bridgeURLString) else {
            assertionFailure("bad bridge URL literal")
            return
        }
        wv.load(URLRequest(url: url))
    }

    /// Shim that installs `window.AndroidBridge.*` in terms of WebKit's
    /// native `postMessage` interface. Kept 1:1 with the `@JavascriptInterface`
    /// methods exposed by `WebViewManager.java` so the JS bridge code runs
    /// unchanged.
    /// Note: `isDebug` is exposed synchronously because `bridge.html`
    /// uses it to gate `console.*` logging. On iOS we read a compile-time
    /// `#if DEBUG` via the user script so behaviour matches
    /// `BuildConfig.DEBUG` on Android.
    /// `getPendingPayload` and `onResult` / `onError` all post their
    /// payloads through the message handler and block on a generated
    /// reply id for the synchronous `getPendingPayload` case. WebKit
    /// does not support synchronous JS->native calls, so we use a
    /// short-lived `XMLHttpRequest`-free polling approach via
    /// `fetch(appassets:///bridge-payload/<id>)`. The scheme handler
    /// resolves those URLs to the staged payload.
    private static func makeAndroidBridgeShim() -> WKUserScript {
        let isDebug: String
        #if DEBUG
        isDebug = "true"
        #else
        isDebug = "false"
        #endif
        let src = """
        (function () {
            if (window.AndroidBridge) return;
            function post(name, args) {
                window.webkit.messageHandlers.\(interfaceName).postMessage({
                    m: name, args: args || []
                });
            }
            window.AndroidBridge = {
                isDebug: function () { return \(isDebug); },
                debugLog: function (msg) {
                    // DEBUG-only diagnostic channel. The JS side only
                    // calls this from `_timeLog` (gated by isDebug) with
                    // opaque label + millisecond deltas, never any
                    // payload-derived string. Routed to `Logger.debug`
                    // on the native side (which is itself a no-op in
                    // Release) so per-phase send timings reach Console
                    // even when the overall bridge call later times out.
                    post('debugLog', [String(msg || '')]);
                },
                onResult: function (requestId, jsonResult) {
                    post('onResult', [String(requestId || ''), String(jsonResult || '')]);
                },
                onError: function (requestId, error) {
                    post('onError', [String(requestId || ''), String(error || '')]);
                },
                getPendingPayload: function (requestId) {
                    // Synchronous pull via XHR against the custom scheme.
                    // The URL must include the per-request
                    // capability token that Swift injected into
                    // `window.__bridgeTokens[requestId]` when staging
                    // the payload. Without the token the SchemeHandler
                    // returns 404 and we surface an empty string,
                    // which the JS handlers treat as "payload missing".
                    try {
                        var rid = String(requestId || '');
                        var tokens = window.__bridgeTokens || {};
                        var token = String(tokens[rid] || '');
                        if (!token) return '';
                        var url = 'appassets:///bridge-payload/'
                            + encodeURIComponent(rid) + '/'
                            + encodeURIComponent(token);
                        var xhr = new XMLHttpRequest();
                        xhr.open('GET', url, false);
                        xhr.send(null);
                        if (xhr.status === 200) {
                            // Single-use token; drop after use.
                            delete tokens[rid];
                            return xhr.responseText;
                        }
                    } catch (e) {}
                    return '';
                }
            };
        })();
        """
        return WKUserScript(source: src, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    fileprivate func dispatchResult(requestId: String, json: String) {
        guard let cb = pendingCallbacks.remove(requestId) else { return }
        // Match Android: parse `{"success":true|false,"error"?,"data"?}`
        // and route to onResult/onError accordingly.
        if let data = json.data(using: .utf8),
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let ok = (obj["success"] as? Bool) ?? false
            if ok {
                cb.onResult(json)
            } else {
                cb.onError((obj["error"] as? String) ?? "Unknown bridge error")
            }
        } else {
            // Non-JSON payload - preserve Android fallback.
            cb.onResult(json)
        }
    }

    fileprivate func pullPayload(requestId: String, token: String) -> String? {
        return pendingPayloads.takeIfFresh(requestId: requestId, token: token)
    }

    /// Scheme-handler entry point for the outbound (Swift -> JS)
    /// binary channel: serve the staged bytes if the presented
    /// token matches the staged token in constant time. Single-
    /// use; the entry is removed on first read.
    fileprivate func pullBinary(requestId: String, key: String,
        token: String) -> Data? {
        return pendingBinaryOutbound.takeIfFresh(
            requestId: requestId, key: key, token: token)
    }

    /// Scheme-handler entry point for the inbound (JS -> Swift)
    /// binary channel: store the POST body under (requestId, key)
    /// if the presented token matches the reserved token. The
    /// stored entry stays until the Swift-side caller consumes it
    /// via `consumePendingResultBinary`.
    /// retained as a `fileprivate` entry point for the
    /// scheme-handler path. The script-message path uses the
    /// `pushBinaryFromMessage` wrapper below; both ultimately
    /// call the same token-checked store.
    fileprivate func pushBinary(requestId: String, key: String,
        token: String, data: Data) -> Bool {
        return pendingBinaryInbound.completeReservation(
            requestId: requestId, key: key, token: token, data: data)
    }

    /// Script-message entry point for the inbound (JS -> Swift)
    /// binary channel. Used in place of an XHR POST because
    /// `WKURLSchemeHandler` does not reliably surface POST
    /// bodies to custom-scheme handlers; the message-handler
    /// path is the documented IPC channel for JS -> native
    /// payloads.
    fileprivate func pushBinaryFromMessage(requestId: String, key: String,
        token: String, data: Data) -> Bool {
        return pendingBinaryInbound.completeReservation(
            requestId: requestId, key: key, token: token, data: data)
    }
}

// MARK: - WKNavigationDelegate

extension JsEngine: WKNavigationDelegate {
    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView.url?.absoluteString == Self.bridgeURLString {
            ready.value = true
            readyLatch.signal()
            // Fire-and-forget WASM warm-up: pay the one-time Go-WASM
            // module compile + runtime + PQC-keygen cost now, off the
            // critical path, so the user's first transaction does not
            // absorb WASM bring-up on top of signing. The JS handler is
            // best-effort and swallows its own errors; no callback is
            // registered, so the result is discarded.
            webView.evaluateJavaScript("_warmup()", completionHandler: nil)
        }
    }

    /// Failure during the initial / provisional phase of a
    /// navigation - this is what fires when the bridge URL itself
    /// cannot be loaded (e.g. WKURLSchemeHandler rejected the
    /// request, the resource file is missing, App-Bound-Domains
    /// blocks the load, or the scheme is not registered).
    /// Without this delegate the prior implementation silently
    /// waited the full `waitUntilReady` timeout (30 s by default)
    /// and then surfaced the generic "Bridge not ready" message,
    /// which made first-launch failures very hard to diagnose.
    /// We now record the underlying error and signal the latch
    /// immediately so callers fail fast and surface the real
    /// reason on the splash screen.
    public func webView(_ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error) {
// the URL is intentionally NOT included in
        // the surfaced message. The full
        // `appassets:///bridge.html` path leaks the WKWebView
        // scheme handler shape into a user-facing splash error,
        // which gives an attacker the exact internal namespace
        // to probe for additional handlers. The (domain, code)
        // pair from the underlying NSError plus a generic
        // localized description is enough to triage; the
        // resource path stays in `Logger.debug`-level logging
        // for engineering diagnosis only.
        let nsError = error as NSError
        let message = "Bridge load failed (provisional): "
        + "\(nsError.domain)#\(nsError.code) "
        + "\(error.localizedDescription)"
        recordLoadFailure(message)
        Logger.debug(category: "BRIDGE_LOAD_FAILED_PROVISIONAL",
            "url=\(webView.url?.absoluteString ?? Self.bridgeURLString)")
    }

    /// Failure after the document has started loading. Same
    /// behaviour as the provisional failure: record + unblock the
    /// readiness latch.
    public func webView(_ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error) {
        let nsError = error as NSError
        let message = "Bridge load failed (post-provisional): "
        + "\(nsError.domain)#\(nsError.code) "
        + "\(error.localizedDescription)"
        recordLoadFailure(message)
        Logger.debug(category: "BRIDGE_LOAD_FAILED_POST",
            "url=\(webView.url?.absoluteString ?? Self.bridgeURLString)")
    }

    /// Web-content process termination (OOM, crash, sandbox
    /// violation). Treat as a fatal load failure.
    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        recordLoadFailure("Bridge web-content process terminated unexpectedly.")
    }
}

// MARK: - Script message broker

/// Receives raw `postMessage` payloads from `window.webkit` and routes
/// `onResult` / `onError` into `JsEngine`. Kept as a separate object to
/// avoid a retain cycle with `WKUserContentController`.
private final class ScriptMessageBroker: NSObject, WKScriptMessageHandler {
    weak var owner: JsEngine?

    init(owner: JsEngine) { self.owner = owner; super.init() }

    func userContentController(_ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
        let method = body["m"] as? String
        else { return }
        guard let owner = owner else { return }
// the `pushBinary` route accepts a
        // mixed-type args array (`[String, String, String, [NSNumber]]`)
        // because the JS side passes a numeric array as the
        // last element. The other routes (`onResult`,
        // `onError`) keep the original all-`String` shape.
        if method == "pushBinary" {
            guard let rawArgs = body["args"] as? [Any],
            rawArgs.count >= 4,
            let rid = rawArgs[0] as? String,
            let key = rawArgs[1] as? String,
            let token = rawArgs[2] as? String,
            let bytes = rawArgs[3] as? [NSNumber]
            else { return }
            var data = Data(count: bytes.count)
            for (i, n) in bytes.enumerated() {
                data[i] = n.uint8Value
            }
            MainActor.assumeIsolated {
                _ = owner.pushBinaryFromMessage(
                    requestId: rid, key: key, token: token, data: data)
            }
            // Wipe the local Data; it has been copied into
            // `pendingBinaryInbound` if the token validated.
            data.resetBytes(in: 0..<data.count)
            return
        }
        guard let args = body["args"] as? [String] else { return }
        switch method {
            case "debugLog":
            // Diagnostic-only timing line from the JS send path.
            // `Logger.debug` compiles to a no-op in Release, so this
            // route is inert outside DEBUG builds.
            guard let line = args.first else { return }
            Logger.debug(category: "BRIDGE_TIMING", line)
            case "onResult":
            guard args.count >= 2 else { return }
            MainActor.assumeIsolated {
                owner.dispatchResult(requestId: args[0], json: args[1])
            }
            case "onError":
            // Android side pipes this through `onResult` with success:false;
            // we preserve that behaviour for parity.
            guard args.count >= 2 else { return }
            let envelope = "{\"success\":false,\"error\":\(JSONEncoder.stringLiteral(args[1]))}"
            MainActor.assumeIsolated {
                owner.dispatchResult(requestId: args[0], json: envelope)
            }
            default: break
        }
    }
}

// MARK: - Scheme handler

/// Resolves `appassets://bridge.html` and `appassets://quantumcoin-bundle.js`
/// to files in the main bundle's `Resources` directory, and resolves
/// `appassets:///bridge-payload/<requestId>` to the staged JSON payload.
/// Mirrors Android's `WebViewAssetLoader` one-to-one.
/// hardening:
/// 1. **Explicit bundle-resource allowlist (`bundleAllowlist`).** The
/// previous implementation accepted any filename and forwarded it to
/// `Bundle.main.url(forResource:)`. That made any bundle resource
/// (Info.plist, embedded.mobileprovision, image assets, future
/// developer-added files) reachable via a URL of the shape
/// `appassets://bridge.html/<name>`. With WKAppBoundDomains in place
/// the surface is small today, but defense-in-depth means
/// the scheme handler should serve only the two files the JS bundle
/// legitimately needs: `bridge.html` and `quantumcoin-bundle.js`.
/// Anything else returns the same `.fileDoesNotExist` error path
/// that a genuinely-missing resource produces, so the response does
/// NOT leak the existence of a denied resource versus a missing one.
/// 2. **Scoped `Access-Control-Allow-Origin`.** Synchronous XHR from
/// `bridge.html` to `appassets:///bridge-payload/<id>` originally
/// required `Access-Control-Allow-Origin: *`. The `*` wildcard
/// allowed any document loaded into the WebView (a hypothetical
/// future bug or a navigation hijack) to read the staged payloads,
/// which contain the most sensitive material the bridge ever sees:
/// passwords, derived keys, private keys in transit between Swift
/// and JS. Restricting the header to `appassets://bridge.html`
/// means only documents from the bridge's exact origin can read
/// payloads. Combined with 's `WKAppBoundDomains`, the only
/// document that can EVER load in this WebView is `bridge.html`
/// itself, so this is effectively a no-op today - but it is the
/// correct CORS posture for any future change.
/// 3. **Why not return 403 on a denied path?** Returning a distinct
/// "denied" status would let an attacker enumerate the allowlist
/// vs the bundle's actual file set (path X returns 403 ->
/// "resource exists but is restricted"; path Y returns 404 ->
/// "resource does not exist"). Returning `.fileDoesNotExist` for
/// both makes the responses indistinguishable.
private final class AppAssetsSchemeHandler: NSObject, WKURLSchemeHandler {

    /// Explicit allowlist of bundle filenames the JS
    /// bridge is allowed to load. Anything else is treated as
    /// "resource does not exist" (see class doc point 3).
    /// Adding a new bundle resource that the JS bundle needs to load
    /// requires adding it to this set in code review - which is the
    /// intended verification gate. The set is small and stable.
    private static let bundleAllowlist: Set<String> = [
        "bridge.html",
        "quantumcoin-bundle.js",
    ]

    /// Scoped CORS origin. Replaces the prior `*`
    /// wildcard. The bridge.html document is the ONLY origin that ever
    /// runs inside this WebView (enforced by + WKAppBoundDomains);
    /// any XHR that is not from this exact origin should not be able to
    /// read staged payloads.
    private static let allowedCorsOrigin = "appassets://bridge.html"

    weak var owner: JsEngine?

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        // Binary channels.
        if url.path.hasPrefix("/bridge-binary-pull/") {
            // Outbound (Swift -> JS) binary fetch. URL shape:
            // appassets:///bridge-binary-pull/<rid>/<key>/<token>
            let comps = url.pathComponents.filter { $0 != "/" }
            guard comps.count >= 4,
            comps[comps.count - 4] == "bridge-binary-pull" else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            let rawRid = comps[comps.count - 3]
            let rawKey = comps[comps.count - 2]
            let rawToken = comps[comps.count - 1]
            let reqId = rawRid.removingPercentEncoding ?? rawRid
            let key = rawKey.removingPercentEncoding ?? rawKey
            let token = rawToken.removingPercentEncoding ?? rawToken
            let staged = MainActor.assumeIsolated {
                owner?.pullBinary(requestId: reqId, key: key, token: token)
            }
            guard let body = staged else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            respond(task: urlSchemeTask, url: url,
                body: body, mime: "application/octet-stream")
            return
        }
        if url.path.hasPrefix("/bridge-binary-push/") {
            // Inbound (JS -> Swift) binary push. URL shape:
            // appassets:///bridge-binary-push/<rid>/<key>/<token>
            let comps = url.pathComponents.filter { $0 != "/" }
            guard comps.count >= 4,
            comps[comps.count - 4] == "bridge-binary-push" else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            let rawRid = comps[comps.count - 3]
            let rawKey = comps[comps.count - 2]
            let rawToken = comps[comps.count - 1]
            let reqId = rawRid.removingPercentEncoding ?? rawRid
            let key = rawKey.removingPercentEncoding ?? rawKey
            let token = rawToken.removingPercentEncoding ?? rawToken
            let body = urlSchemeTask.request.httpBody
                ?? readStreamedBody(urlSchemeTask.request) ?? Data()
            let ok = MainActor.assumeIsolated {
                owner?.pushBinary(requestId: reqId, key: key,
                    token: token, data: body) ?? false
            }
            guard ok else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            respond(task: urlSchemeTask, url: url,
                body: Data("ok".utf8), mime: "text/plain")
            return
        }
        if url.path.hasPrefix("/bridge-payload/") {
            // JS-side pull of a staged payload. URL shape:
            // appassets:///bridge-payload/<requestId>/<token>
// the previous URL shape was
            // `appassets:///bridge-payload/<requestId>` with no
            // capability check, relying on WebKit's CORS
            // enforcement for the custom scheme to keep
            // unrelated documents from reading staged payloads.
            // CORS for custom schemes is not formally specified
            // by WebKit, so we now require a per-request
            // capability token in the URL path. The token is
            // generated when Swift stages the payload, injected
            // into `window.__bridgeTokens` for the JS shim, and
            // verified here. A missing or mismatched token
            // returns the same `.fileDoesNotExist` error as a
            // missing payload so the response shape does not
            // leak which arm rejected.
            let comps = url.pathComponents.filter { $0 != "/" }
            // Expect: ["bridge-payload", "<rid>", "<token>"]
            guard comps.count >= 3, comps[comps.count - 3] == "bridge-payload" else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            let rawRid = comps[comps.count - 2]
            let rawToken = comps[comps.count - 1]
            let reqId = rawRid.removingPercentEncoding ?? rawRid
            let token = rawToken.removingPercentEncoding ?? rawToken
            let staged = MainActor.assumeIsolated {
                owner?.pullPayload(requestId: reqId, token: token)
            }
            guard let body = staged else {
                urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                return
            }
            respond(task: urlSchemeTask, url: url,
                body: Data(body.utf8), mime: "text/plain")
            return
        }

        // Bundled resource. Two URL shapes are possible because WebKit
        // resolves relative `<script src=...>` against the document URL:
        // - `appassets://bridge.html` (host-only, initial load)
        // - `appassets://bridge.html/quantumcoin-bundle.js` (relative resolution)
        // - `appassets:///quantumcoin-bundle.js` (root-relative, hypothetical)
        // Prefer the last path component when present, else the host.
        let trimmed = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let filename: String
        if !trimmed.isEmpty {
            filename = url.lastPathComponent
        } else if let host = url.host, !host.isEmpty {
            filename = host
        } else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }
        // Gate on the explicit allowlist BEFORE the
        // bundle lookup. The miss path returns the same error code as a
        // genuinely-absent file so an attacker cannot probe the allowlist
        // (see class doc point 3).
        guard Self.bundleAllowlist.contains(filename) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        // (defense-in-depth): verify the JS bundle
        // hash before serving its bytes to the WKWebView. The
        // primary verification fires in `AppDelegate.application(_:
        // didFinishLaunchingWithOptions:)` at boot - this serving-
        // time check catches the (theoretical) case where the on-
        // disk bytes change between boot and bundle load. The
        // verifier caches its result so this is a single map lookup
        // on the second-and-later calls. We only verify the JS
        // bundle here, not bridge.html, because the JS bundle is
        // the one that owns signing primitives; bridge.html is a
        // small router whose tamper window is captured by
        // + WKAppBoundDomains.
        if filename == BundleIntegrity.bundleResourceName + "."
        + BundleIntegrity.bundleResourceExtension {
            do {
                try BundleIntegrity.verifyOrFail()
            } catch {
                urlSchemeTask.didFailWithError(URLError(.dataNotAllowed))
                return
            }
        }
        guard let bundleURL = Bundle.main.url(forResource: filename, withExtension: nil) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        do {
            let data = try Data(contentsOf: bundleURL)
            let mime: String
            if filename.hasSuffix(".html") { mime = "text/html" }
            else if filename.hasSuffix(".js") { mime = "application/javascript" }
            else { mime = "application/octet-stream" }
            respond(task: urlSchemeTask, url: url, body: data, mime: mime)
        } catch {
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        // Nothing to cancel; all reads are synchronous.
    }

    /// Drain a streamed request body (XHR `send(Blob)` arrives via
    /// `httpBodyStream` rather than `httpBody` on some WebKit
    /// versions). Bounded read - we cap at 1 MiB so a hostile JS
    /// caller can't pin Swift memory by streaming an unbounded
    /// body.
    private func readStreamedBody(_ request: URLRequest) -> Data? {
        guard let stream = request.httpBodyStream else { return nil }
        var data = Data()
        let cap = 1 * 1024 * 1024
        let bufferSize = 8 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        stream.open()
        defer { stream.close() }
        while stream.hasBytesAvailable {
            let n = stream.read(buffer, maxLength: bufferSize)
            if n <= 0 { break }
            data.append(buffer, count: n)
            if data.count > cap {
                return nil
            }
        }
        return data
    }

    private func respond(task: WKURLSchemeTask, url: URL, body: Data, mime: String) {
        let resp = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": mime,
                "Content-Length": String(body.count),
                // Scoped to bridge.html origin (was `*`).
                // Bridge.html is the only document that ever loads in
                // this WebView under + WKAppBoundDomains, so this
                // is effectively a no-op today, but is the correct CORS
                // posture for any future change. See class-level doc.
                "Access-Control-Allow-Origin": Self.allowedCorsOrigin,
            ]
        )!
        task.didReceive(resp)
        task.didReceive(body)
        task.didFinish()
    }
}

// MARK: - Helpers

/// Small thread-safe mutable bool. `WKWebView` is MainActor-isolated but
/// the ready flag is read from background threads as part of
/// `waitUntilReady`, which is why we need an explicit lock here.
private final class AtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}

/// One-shot latch used to signal bridge readiness across threads.
/// Replacement for Android's `CountDownLatch(1)`.
/// Uses `NSCondition` rather than `DispatchSemaphore` so a single
/// `signal` releases EVERY pending waiter via `broadcast`. The
/// original `DispatchSemaphore` flavour would only wake one of N
/// concurrent `waitUntilReady` callers, so a second waiter (e.g. the
/// `BlockchainNetworkManager.applyActive` Task.detached racing with
/// the AppDelegate's `loadSeedsThreadEquivalent` task) would park
/// for the full timeout even though `bridge.html` had already loaded.
private final class OneShotLatch: @unchecked Sendable {
    private let cond = NSCondition()
    private var signaled = false

    func signal() {
        cond.lock()
        if !signaled {
            signaled = true
            cond.broadcast()
        }
        cond.unlock()
    }

    func await(timeout: TimeInterval) -> Bool {
        cond.lock()
        defer { cond.unlock() }
        if signaled { return true }
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !signaled {
            if !cond.wait(until: deadline) { return signaled }
        }
        return true
    }
}

/// Pending callback registry. Thread-safe.
private final class PendingCallbackStore: @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: BridgeCallback] = [:]

    func set(_ cb: BridgeCallback, for id: String) {
        lock.lock(); map[id] = cb; lock.unlock()
    }

    func remove(_ id: String) -> BridgeCallback? {
        lock.lock(); defer { lock.unlock() }
        return map.removeValue(forKey: id)
    }
}

/// Pending payload registry with size cap + TTL. Mirrors
/// `WebViewManager.pendingPayloads` and its L-02 sweeping guarantees.
/// each
/// staged payload also carries a per-request capability token
/// (32 random bytes, hex-encoded) generated at staging time. The
/// JS-side `appassets:///bridge-payload/<rid>/<token>` XHR must
/// present the matching token, otherwise the SchemeHandler returns
/// `.fileDoesNotExist`. WebKit's CORS enforcement for custom
/// schemes is not formally specified, so we cannot rely
/// on `Access-Control-Allow-Origin` alone to keep an unrelated
/// document (or a future bug that loads a non-bridge document into
/// the same WebView) from reading the staged payloads. The
/// capability token closes that gap by making the per-request URL
/// itself unguessable. The token is single-use - `takeIfFresh`
/// removes the entry on first read, so a replayed XHR returns nil.
private final class PendingPayloadStore: @unchecked Sendable {
    private struct Entry {
        let json: String
        let token: String
        let enqueuedAt: TimeInterval
    }
    private let lock = NSLock()
    private var map: [String: Entry] = [:]

    static let maxEntries = 64
    private static let ttl: TimeInterval = 60

    /// Stage `json` for `requestId` and return the freshly-minted
    /// per-request capability token. Callers are expected to
    /// inject the token into the JS engine's per-rid token map
    /// (see `JsEngine.storePendingPayload(...)`).
    func put(requestId: String, json: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        sweepExpiredLocked()
        if map.count >= Self.maxEntries {
            throw JsEngineError.pendingPayloadMapFull
        }
        let token = try Self.generateToken()
        map[requestId] = Entry(
            json: json, token: token, enqueuedAt: Self.now())
        return token
    }

    /// Single-use, token-checked pull. Returns the staged JSON
    /// only if (a) `requestId` is staged, (b) the staged entry
    /// has not expired, and (c) the presented `token` matches
    /// the staged token in constant time. On any mismatch the
    /// entry is left in place so a future legitimate pull can
    /// still succeed (the SchemeHandler will surface the same
    /// `.fileDoesNotExist` for both "not staged" and "wrong
    /// token", so the response shape does not leak which arm
    /// failed).
    func takeIfFresh(requestId: String, token: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let entry = map[requestId] else { return nil }
        if Self.now() - entry.enqueuedAt > Self.ttl {
            map.removeValue(forKey: requestId)
            return nil
        }
        guard Self.constantTimeEquals(entry.token, token) else {
            return nil
        }
        map.removeValue(forKey: requestId)
        return entry.json
    }

    func remove(_ requestId: String) {
        lock.lock(); _ = map.removeValue(forKey: requestId); lock.unlock()
    }

    private func sweepExpiredLocked() {
        let now = Self.now()
        map = map.filter { now - $0.value.enqueuedAt <= Self.ttl }
    }

    private static func now() -> TimeInterval { CFAbsoluteTimeGetCurrent() }

    /// 32 random bytes hex-encoded. The capability token is opaque
    /// to JS; only the SchemeHandler ever inspects it.
    /// the
    /// token is the gate that prevents a same-origin JS error from
    /// pulling a different request's payload off the staging map.
    /// We MUST refuse to issue a token if the OS RNG fails - the
    /// previous implementation `precondition(status == errSecSuccess)`
    /// crashed the entire app, which is "the safest possible default"
    /// in spirit but in practice nukes any in-flight unlock dialog,
    /// any partially-typed seed phrase, etc. Routing through
    /// `SecureRandom.bytes(32)` lets the call site bubble the failure
    /// up as `JsEngineError.tokenGenerationFailed(OSStatus)`, which
    /// the SchemeHandler maps to a fail-closed bridge response (the
    /// pending entry is never staged so no payload can leak).
    private static func generateToken() throws -> String {
        do {
            let bytes = try SecureRandom.bytes(32)
            return bytes.map { String(format: "%02x", $0) }.joined()
        } catch let SecureRandom.Error.osStatus(status) {
            throw JsEngineError.tokenGenerationFailed(status)
        } catch {
            throw JsEngineError.tokenGenerationFailed(errSecInternalError)
        }
    }

    /// Constant-time string-equals over the raw UTF-8 bytes. The
    /// capability tokens are fixed-length hex strings so the
    /// short-circuit on length is benign.
    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        guard aBytes.count == bBytes.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<aBytes.count {
            diff |= aBytes[i] ^ bBytes[i]
        }
        return diff == 0
    }
}

public enum JsEngineError: Error, CustomStringConvertible {
    case pendingPayloadMapFull
    case pendingBinaryMapFull
    case bridgeNotReady
    case timeout
    case callFailed(String)
    /// The OS RNG (`SecRandomCopyBytes`) refused to produce a
    /// capability token. Callers MUST treat this as a fail-closed
    /// bridge call - no entry is staged, so no payload can be
    /// pulled. The raw `OSStatus` is preserved for forensic
    /// triage. See `PendingPayloadStore.generateToken()`.
    case tokenGenerationFailed(OSStatus)

    public var description: String {
        switch self {
            case .pendingPayloadMapFull: return "pending payload map full; refusing to stage new entry"
            case .pendingBinaryMapFull: return "pending binary map full; refusing to stage new entry"
            case .bridgeNotReady: return "Bridge WebView did not become ready in time"
            case .timeout: return "Bridge call timed out"
            case .callFailed(let m): return "Bridge call failed: \(m)"
            case .tokenGenerationFailed(let s): return "OS RNG failed to mint bridge capability token (OSStatus=\(s))"
        }
    }
}

/// Pending binary registry. Identical token-checked single-use posture
/// to `PendingPayloadStore`, but stores `Data` instead of `String` and
/// keys by `(requestId, key)` so a single requestId can stage multiple
/// independent binary slots (e.g. the wallet decrypt handler stages
/// `privateKey` AND `publicKey` for the same rid).
/// the reason
/// this store exists separately from `PendingPayloadStore` is the
/// "data ever stringified" question. Strings in Swift / JS are
/// immutable: once a private key is base64-encoded into a `String` it
/// lives in V8's string pool / Swift's heap until GC, and cannot be
/// zeroized in place. This store keeps the raw bytes in `Data` (Swift)
/// and `Uint8Array` (JS) end-to-end, so callers can call
/// `Data.resetBytes(in:)` / `Uint8Array.fill(0)` to wipe the buffer
/// the moment the byte-consuming operation completes.
private final class PendingBinaryStore: @unchecked Sendable {
    private struct Entry {
        var data: Data?            // nil means "reserved, not yet pushed"
        let token: String
        let enqueuedAt: TimeInterval
    }
    private let lock = NSLock()
    private var map: [Slot: Entry] = [:]

    private struct Slot: Hashable {
        let requestId: String
        let key: String
    }

    static let maxEntries = 64
    private static let ttl: TimeInterval = 60

    /// Stage `data` for `(requestId, key)` immediately. Returns
    /// the freshly-minted token. Used by the outbound (Swift -> JS)
    /// channel.
    func put(requestId: String, key: String, data: Data) throws -> String {
        lock.lock(); defer { lock.unlock() }
        sweepExpiredLocked()
        if map.count >= Self.maxEntries {
            throw JsEngineError.pendingBinaryMapFull
        }
        let token = try Self.generateToken()
        map[Slot(requestId: requestId, key: key)] = Entry(
            data: data, token: token, enqueuedAt: Self.now())
        return token
    }

    /// Reserve a `(requestId, key)` slot for an inbound push from
    /// the JS side. The caller must announce the reservation to JS
    /// (via `injectBinaryToken(direction: "in", ...)`) so the JS
    /// handler can present the matching token in its push URL. The
    /// slot stays empty (`data == nil`) until JS POSTs.
    func reserve(requestId: String, key: String) throws -> String {
        lock.lock(); defer { lock.unlock() }
        sweepExpiredLocked()
        if map.count >= Self.maxEntries {
            throw JsEngineError.pendingBinaryMapFull
        }
        let token = try Self.generateToken()
        map[Slot(requestId: requestId, key: key)] = Entry(
            data: nil, token: token, enqueuedAt: Self.now())
        return token
    }

    /// Token-checked single-use pull (outbound, Swift -> JS).
    /// Removes the entry on success.
    func takeIfFresh(requestId: String, key: String, token: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        let slot = Slot(requestId: requestId, key: key)
        guard let entry = map[slot] else { return nil }
        if Self.now() - entry.enqueuedAt > Self.ttl {
            map.removeValue(forKey: slot)
            return nil
        }
        guard Self.constantTimeEquals(entry.token, token) else { return nil }
        guard let data = entry.data else { return nil }
        map.removeValue(forKey: slot)
        return data
    }

    /// Token-checked single-shot push (inbound, JS -> Swift).
    /// Stores `data` only if the slot was reserved with a matching
    /// token; the entry stays until a Swift consumer calls
    /// `takeAny(...)`.
    func completeReservation(requestId: String, key: String,
        token: String, data: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let slot = Slot(requestId: requestId, key: key)
        guard let entry = map[slot] else { return false }
        if Self.now() - entry.enqueuedAt > Self.ttl {
            map.removeValue(forKey: slot)
            return false
        }
        guard Self.constantTimeEquals(entry.token, token) else { return false }
        // Reservation must still be empty; reject double-push.
        guard entry.data == nil else { return false }
        map[slot] = Entry(data: data, token: entry.token,
            enqueuedAt: entry.enqueuedAt)
        return true
    }

    /// Token-less Swift-side consumer. The JS side already proved
    /// it knows the token at push time; the Swift consumer (which
    /// is in-process and doesn't traverse the URL) doesn't need
    /// to re-prove. Removes the entry on success.
    func takeAny(requestId: String, key: String) -> Data? {
        lock.lock(); defer { lock.unlock() }
        let slot = Slot(requestId: requestId, key: key)
        guard let entry = map[slot] else { return nil }
        guard let data = entry.data else { return nil }
        map.removeValue(forKey: slot)
        return data
    }

    private func sweepExpiredLocked() {
        let now = Self.now()
        map = map.filter { now - $0.value.enqueuedAt <= Self.ttl }
    }

    private static func now() -> TimeInterval { CFAbsoluteTimeGetCurrent() }

    /// 32 random bytes hex-encoded. Same posture as
    /// `PendingPayloadStore.generateToken`; see that helper's
    /// comment block for the full rationale.
    private static func generateToken() throws -> String {
        do {
            let bytes = try SecureRandom.bytes(32)
            return bytes.map { String(format: "%02x", $0) }.joined()
        } catch let SecureRandom.Error.osStatus(status) {
            throw JsEngineError.tokenGenerationFailed(status)
        } catch {
            throw JsEngineError.tokenGenerationFailed(errSecInternalError)
        }
    }

    private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        guard aBytes.count == bBytes.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<aBytes.count {
            diff |= aBytes[i] ^ bBytes[i]
        }
        return diff == 0
    }
}

// MARK: - Micro JSON string helper

fileprivate extension JSONEncoder {
    /// Quick, allocation-free string literal encoder used only for the
    /// error envelope constructed in `ScriptMessageBroker`. Escapes the
    /// exact same characters that `QuantumCoinJSBridge.escapeForJs`
    /// escapes on Android.
    static func stringLiteral(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
                case "\\": out.append("\\\\")
                case "\"": out.append("\\\"")
                case "\u{0000}": out.append("\\u0000")
                case "\n": out.append("\\n")
                case "\r": out.append("\\r")
                case "\t": out.append("\\t")
                case "\u{0008}": out.append("\\b")
                case "\u{000C}": out.append("\\f")
                case "\u{2028}": out.append("\\u2028")
                case "\u{2029}": out.append("\\u2029")
                default:
                if u.value < 0x20 {
                    out.append(String(format: "\\u%04x", u.value))
                } else {
                    out.append(Character(u))
                }
            }
        }
        out.append("\"")
        return out
    }
}

// Private constant copy so the shim can reference a raw literal with
// the same name.
private let interfaceName = "androidBridge"
