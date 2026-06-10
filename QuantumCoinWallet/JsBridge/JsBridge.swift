// JsBridge.swift
// Typed Swift facade over `JsEngine` that mirrors
// `QuantumCoinJSBridge.java` one-to-one. Every method preserves the
// Android contract: push vs pull transport, argument encoding, and
// return shape.
// Android reference:
// app/src/main/java/com/quantumcoinwallet/app/bridge/QuantumCoinJSBridge.java
// Rules copied from the Java source:
// - Sensitive payloads (passwords, private keys, seed phrases) use the
// pull model via `storePendingPayload` - they never appear in the
// `evaluate(...)` script string.
// - Non-sensitive primitives (chain id, address, public key) use push
// and are run through `escapeForJs` before interpolation.
// - `blockingCall(_:)` enforces a main-thread guard and timeouts.
// ## Threading note
// All blocking wrappers on this class MUST be called from a background
// queue. Calling from the main thread will trap with
// `preconditionFailure`. Use the async wrappers from UI code.
// the wallet-creation, wallet-decrypt, and signing call shapes use
// the binary channel `JsEngine.storePendingPayloadBinary` /
// `consumePendingResultBinary` for `privateKeyBytes` and
// `publicKeyBytes`. The Swift facades take and return `Data` for
// those fields so callers can `defer { result.resetBytes(in:) }`
// the moment they finish using them. The JSON envelope returned by
// the bridge handlers no longer contains the secret bytes; only
// non-secret metadata (address, seed hex, seedWords array) flows
// through the JSON path. See `bridge.html` for the JS-side
// implementation.

import Foundation

public final class JsBridge: @unchecked Sendable {

    // MARK: - Singleton

    /// Singleton handle. `JsBridge` is `@unchecked Sendable` and its
    /// `init` is non-actor, so this static is safe to access from any
    /// thread without an actor hop.
    public static let shared = JsBridge()

    public static let SCRYPT_N: Int = 262_144
    public static let SCRYPT_R: Int = 8
    public static let SCRYPT_P: Int = 1
    public static let SCRYPT_KEY_LEN: Int = 32

    private static let defaultTimeoutSeconds: TimeInterval = 30

    /// Result-wait timeout for the signing calls
    /// (`sendTransaction` / `sendTokenTransaction`). These run the
    /// CPU-heavy post-quantum signing path inside the JS bundle,
    /// which on real device hardware can take far longer than the
    /// 30s `defaultTimeoutSeconds` budget (the simulator runs on
    /// the host CPU and finishes well under it). Only the result
    /// (settle) wait uses this value; the bridge-readiness wait
    /// still uses `defaultTimeoutSeconds` since readiness is
    /// unrelated to how long a signature takes.
    private static let signingTimeoutSeconds: TimeInterval = 120

    private init() {}

    // MARK: - Push helpers

    /// Escape a string so it can be safely embedded inside a single-
    /// quoted JS literal. Covers backslash, single quote, NUL, CR, LF,
    /// and U+2028 / U+2029. 1:1 with `QuantumCoinJSBridge.escapeForJs`.
    static func escapeForJs(_ s: String?) -> String {
        guard let s else { return "" }
        var out = ""
        out.reserveCapacity(s.count + 8)
        for u in s.unicodeScalars {
            switch u {
                case "\\": out.append("\\\\")
                case "'": out.append("\\'")
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
        return out
    }

    // MARK: - Blocking (background-thread) API

    @discardableResult
    public func initialize(chainId: Int, rpcEndpoint: String) throws -> String {
        try blockingCall { cb, rid in
            _ = JsEngine.shared
            let js = "bridge.initialize('\(rid)', \(chainId), '\(Self.escapeForJs(rpcEndpoint))')"
            JsEngine.shared.registerCallback(requestId: rid, callback: cb)
            JsEngine.shared.evaluate(js)
        }
    }

    @discardableResult
    public func initializeOffline() throws -> String {
        try blockingCall { cb, rid in
            JsEngine.shared.registerCallback(requestId: rid, callback: cb)
            JsEngine.shared.evaluate("bridge.initializeOffline('\(rid)')")
        }
    }

    @discardableResult
    public func createRandomSeed(keyType: Int) throws -> String {
        try blockingCall { cb, rid in
            JsEngine.shared.registerCallback(requestId: rid, callback: cb)
            JsEngine.shared.evaluate("bridge.createRandomSeed('\(rid)', \(keyType))")
        }
    }

    /// Wallet metadata + binary key material returned by
    /// `createRandom`, `walletFromSeed`, `walletFromPhrase`,
    /// `walletFromKeys`. Callers MUST zero out `privateKey` and
    /// `publicKey` via `defer { result.privateKey.resetBytes(...) }`
    /// the moment they finish using them. `seed` (hex) and
    /// `seedWords` are display-bound metadata that the UI surfaces
    /// to the user; they live as String / [String] by design (see
    /// `bridge.html`'s decryptWalletJson handler comment for the
    /// rationale).
    public struct WalletEnvelope {
        public var address: String
        public var seed: String?
        public var seedWords: [String]?
        public var privateKey: Data
        public var publicKey: Data
    }

    public func createRandom(keyType: Int) throws -> WalletEnvelope {
        try walletEnvelopeCall(handler: "createRandom",
            args: "\(keyType)",
            stagePayload: nil,
            stageBinary: nil)
    }

    public func walletFromSeed(seedArray: [Int]) throws -> WalletEnvelope {
        try walletEnvelopeCall(handler: "walletFromSeed",
            args: nil,
            stagePayload: ["seedArray": seedArray],
            stageBinary: nil)
    }

    public func walletFromPhrase(words: [String]) throws -> WalletEnvelope {
        try walletEnvelopeCall(handler: "walletFromPhrase",
            args: nil,
            stagePayload: ["words": words],
            stageBinary: nil)
    }

    public func walletFromKeys(privKey: Data, pubKey: Data) throws -> WalletEnvelope {
        try walletEnvelopeCall(handler: "walletFromKeys",
            args: nil,
            stagePayload: nil,
            stageBinary: [("privKey", privKey), ("pubKey", pubKey)])
    }

    @discardableResult
    public func sendTransaction(privKey: Data, pubKey: Data,
        toAddress: String, valueWei: String,
        gasLimit: String, rpcEndpoint: String,
        chainId: Int, advancedSigningEnabled: Bool) throws -> String {
        // Tamper-gate chokepoint. MUST be the
        // first call inside this function so a hostile signing
        // request never reaches `storePendingPayload` (which would
        // copy the private key into the bridge's pull-payload
        // map). On a debugger-attached Release build or a tampered
        // bundle we throw; on a jailbroken device we throw unless
        // the user already accepted the disclosure dialog at
        // launch. See `Security/TamperGatePolicy.swift` for the
        // full policy and tradeoff write-up.
        try TamperGatePolicy.shared.assertSafeToSign()
        Self.debugProbeRpcLatency(endpoint: rpcEndpoint, chainId: chainId)
        return try blockingCall(settleTimeout: Self.signingTimeoutSeconds,
            label: "sendTransaction", rpcEndpoint: rpcEndpoint) { cb, rid in
            // Stage the secret bytes on the binary channel
            // (NOT in the JSON payload). The JSON envelope carries
            // only the non-secret signing context.
            try JsEngine.shared.storePendingPayloadBinary(
                requestId: rid, key: "privKey", data: privKey)
            try JsEngine.shared.storePendingPayloadBinary(
                requestId: rid, key: "pubKey", data: pubKey)
            let payload: [String: Any] = [
                "to": toAddress,
                "value": valueWei,
                "gasLimit": gasLimit,
                "rpcEndpoint": rpcEndpoint,
                "chainId": chainId,
                "advancedSigning": advancedSigningEnabled
            ]
            let json = try Self.jsonString(payload)
            JsEngine.shared.registerCallback(requestId: rid, callback: cb)
            try JsEngine.shared.storePendingPayload(requestId: rid, json: json)
            JsEngine.shared.evaluate("bridge.sendTransaction('\(rid)')")
        }
    }

    @discardableResult
    public func sendTokenTransaction(privKey: Data, pubKey: Data,
        contractAddress: String, toAddress: String,
        amountWei: String, gasLimit: String,
        rpcEndpoint: String, chainId: Int,
        advancedSigningEnabled: Bool) throws -> String {
        // See the matching comment on
        // `sendTransaction`. The same chokepoint applies to the
        // ERC-20-style token path because the same private key
        // signs both transaction kinds.
        try TamperGatePolicy.shared.assertSafeToSign()
        Self.debugProbeRpcLatency(endpoint: rpcEndpoint, chainId: chainId)
        return try blockingCall(settleTimeout: Self.signingTimeoutSeconds,
            label: "sendTokenTransaction", rpcEndpoint: rpcEndpoint) { cb, rid in
            try JsEngine.shared.storePendingPayloadBinary(
                requestId: rid, key: "privKey", data: privKey)
            try JsEngine.shared.storePendingPayloadBinary(
                requestId: rid, key: "pubKey", data: pubKey)
            let payload: [String: Any] = [
                "contract": contractAddress,
                "to": toAddress,
                "amount": amountWei,
                "gasLimit": gasLimit,
                "rpcEndpoint": rpcEndpoint,
                "chainId": chainId,
                "advancedSigning": advancedSigningEnabled
            ]
            let json = try Self.jsonString(payload)
            JsEngine.shared.registerCallback(requestId: rid, callback: cb)
            try JsEngine.shared.storePendingPayload(requestId: rid, json: json)
            JsEngine.shared.evaluate("bridge.sendTokenTransaction('\(rid)')")
        }
    }

    /// Internal helper used by every wallet-creation handler that
    /// returns a freshly-instantiated SDK wallet (`createRandom`,
    /// `walletFromSeed`, `walletFromPhrase`, `walletFromKeys`).
    /// Reserves the inbound binary slots BEFORE invoking JS, runs
    /// the handler, then consumes the binary slots keyed by the
    /// same rid and assembles the typed `WalletEnvelope`.
    private func walletEnvelopeCall(handler: String,
        args: String?,
        stagePayload: [String: Any]?,
        stageBinary: [(String, Data)]?) throws -> WalletEnvelope {
        // Generate the rid up-front so the binary-slot consume
        // step (after `blockingCall`) can read from the same key.
        let rid = UUID().uuidString.lowercased()
        let envelopeJson = try blockingCallWithExplicitRid(
            requestId: rid) { cb in
                try JsEngine.shared.reserveInboundBinarySlot(
                    requestId: rid, key: "privateKey")
                try JsEngine.shared.reserveInboundBinarySlot(
                    requestId: rid, key: "publicKey")
                if let stageBinary = stageBinary {
                    for (key, data) in stageBinary {
                        try JsEngine.shared.storePendingPayloadBinary(
                            requestId: rid, key: key, data: data)
                    }
                }
                if let stagePayload = stagePayload {
                    let json = try Self.jsonString(stagePayload)
                    try JsEngine.shared.storePendingPayload(
                        requestId: rid, json: json)
                }
                JsEngine.shared.registerCallback(requestId: rid, callback: cb)
                let argsTail = args.map { ", \($0)" } ?? ""
                JsEngine.shared.evaluate("bridge.\(handler)('\(rid)'\(argsTail))")
            }
        guard let data = envelopeJson.data(using: .utf8),
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let inner = obj["data"] as? [String: Any]
        else {
            throw JsEngineError.callFailed(
                "wallet envelope JSON shape unexpected")
        }
        let address = (inner["address"] as? String) ?? ""
        let seed = inner["seed"] as? String
        let seedWords = inner["seedWords"] as? [String]
        guard let priv = JsEngine.shared.consumePendingResultBinary(
            requestId: rid, key: "privateKey")
        else {
            throw JsEngineError.callFailed(
                "wallet envelope missing privateKey binary")
        }
        guard let pub = JsEngine.shared.consumePendingResultBinary(
            requestId: rid, key: "publicKey")
        else {
            var p = priv
            p.resetBytes(in: 0..<p.count)
            throw JsEngineError.callFailed(
                "wallet envelope missing publicKey binary")
        }
        return WalletEnvelope(
            address: address,
            seed: (seed?.isEmpty == false) ? seed : nil,
            seedWords: seedWords,
            privateKey: priv,
            publicKey: pub)
    }

    @discardableResult
    public func isValidAddress(_ address: String) throws -> String {
        try blockingCall { cb, rid in
            JsEngine.shared.registerCallback(requestId: rid, callback: cb)
            JsEngine.shared.evaluate("bridge.isValidAddress('\(rid)', '\(Self.escapeForJs(address))')")
        }
    }

    @discardableResult
    public func computeAddress(pubKeyBase64: String) throws -> String {
        try blockingCall { cb, rid in
            JsEngine.shared.registerCallback(requestId: rid, callback: cb)
            JsEngine.shared.evaluate("bridge.computeAddress('\(rid)', '\(Self.escapeForJs(pubKeyBase64))')")
        }
    }

    /// Return the mixed-case checksum form of
    /// `address` (delegates to the JS bundle's `getChecksumAddress`
    /// helper). The review dialog displays the recipient and From
    /// wallet in this form so a typo in a single hex digit
    /// changes many letter cases - giving the user a strong
    /// visual cue before they type "I agree".
    /// Falls back to the lowercased input if the bundle's
    /// helper is unavailable (older bundles); the fallback is
    /// documented inside `bridge.html`'s `getChecksumAddress`
    /// body.
    @discardableResult
    public func getChecksumAddress(_ address: String) throws -> String {
        try blockingCall { cb, rid in
            JsEngine.shared.registerCallback(requestId: rid, callback: cb)
            JsEngine.shared.evaluate(
                "bridge.getChecksumAddress('\(rid)', '\(Self.escapeForJs(address))')")
        }
    }

    @discardableResult
    public func encryptWalletJson(walletInputJson: String, password: String) throws -> String {
        try blockingCall { cb, rid in
            let payload: [String: Any] = [
                "walletInput": walletInputJson,
                "password": password
            ]
            let json = try Self.jsonString(payload)
            JsEngine.shared.registerCallback(requestId: rid, callback: cb)
            try JsEngine.shared.storePendingPayload(requestId: rid, json: json)
            JsEngine.shared.evaluate("bridge.encryptWalletJson('\(rid)')")
        }
    }

    /// Encrypts the wallet directly from raw signing-key bytes
    /// instead of a seed phrase. Used for the key-only wallet
    /// category (no recoverable BIP39 phrase) so the export
    /// flow stays in lockstep with the Android sibling, where
    /// `CloudBackupManager.encryptWallet` switches to the
    /// `{privateKey, publicKey}` branch whenever the wallet's
    /// stored `seed` field is empty. The bytes are staged on
    /// the binary channel (NOT in the JSON envelope) and the
    /// `walletInput` JSON carries only the `fromBinaryKeys`
    /// discriminator that `bridge.html#encryptWalletJson`
    /// inspects (see the `input.fromBinaryKeys === true`
    /// branch). The bridge zeroes the staged byte slots in its
    /// own `finally` block; callers should still `resetBytes`
    /// any locally-held copy of the key material as soon as
    /// this call returns.
    @discardableResult
    public func encryptWalletJson(privateKey: Data, publicKey: Data,
        password: String) throws -> String {
        try blockingCall { cb, rid in
            try JsEngine.shared.storePendingPayloadBinary(
                requestId: rid, key: "privKey", data: privateKey)
            try JsEngine.shared.storePendingPayloadBinary(
                requestId: rid, key: "pubKey", data: publicKey)
            let payload: [String: Any] = [
                "walletInput": "{\"fromBinaryKeys\":true}",
                "password": password
            ]
            let json = try Self.jsonString(payload)
            JsEngine.shared.registerCallback(requestId: rid, callback: cb)
            try JsEngine.shared.storePendingPayload(requestId: rid, json: json)
            JsEngine.shared.evaluate("bridge.encryptWalletJson('\(rid)')")
        }
    }

    public func decryptWalletJson(walletJson: String,
        password: String) throws -> WalletEnvelope {
        let rid = UUID().uuidString.lowercased()
        let envelopeJson = try blockingCallWithExplicitRid(
            requestId: rid) { cb in
                try JsEngine.shared.reserveInboundBinarySlot(
                    requestId: rid, key: "privateKey")
                try JsEngine.shared.reserveInboundBinarySlot(
                    requestId: rid, key: "publicKey")
                let payload: [String: Any] = [
                    "walletJson": walletJson,
                    "password": password
                ]
                let json = try Self.jsonString(payload)
                JsEngine.shared.registerCallback(requestId: rid, callback: cb)
                try JsEngine.shared.storePendingPayload(requestId: rid, json: json)
                JsEngine.shared.evaluate("bridge.decryptWalletJson('\(rid)')")
            }
        guard let data = envelopeJson.data(using: .utf8),
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let inner = obj["data"] as? [String: Any]
        else {
            throw JsEngineError.callFailed(
                "decryptWalletJson envelope JSON shape unexpected")
        }
        let address = (inner["address"] as? String) ?? ""
        let seed = inner["seed"] as? String
        let seedWords = inner["seedWords"] as? [String]
        guard let priv = JsEngine.shared.consumePendingResultBinary(
            requestId: rid, key: "privateKey")
        else {
            throw JsEngineError.callFailed(
                "decryptWalletJson missing privateKey binary")
        }
        guard let pub = JsEngine.shared.consumePendingResultBinary(
            requestId: rid, key: "publicKey")
        else {
            var p = priv
            p.resetBytes(in: 0..<p.count)
            throw JsEngineError.callFailed(
                "decryptWalletJson missing publicKey binary")
        }
        return WalletEnvelope(
            address: address,
            seed: (seed?.isEmpty == false) ? seed : nil,
            seedWords: seedWords,
            privateKey: priv,
            publicKey: pub)
    }

    @discardableResult
    public func getAllSeedWords() throws -> String {
        try blockingCall { cb, rid in
            JsEngine.shared.registerCallback(requestId: rid, callback: cb)
            JsEngine.shared.evaluate("bridge.getAllSeedWords('\(rid)')")
        }
    }

    @discardableResult
    public func doesSeedWordExist(_ word: String) throws -> String {
        try blockingCall { cb, rid in
            JsEngine.shared.registerCallback(requestId: rid, callback: cb)
            JsEngine.shared.evaluate("bridge.doesSeedWordExist('\(rid)', '\(Self.escapeForJs(word))')")
        }
    }

    /// scrypt-derive via the JS bundle. Returns the raw bridge envelope -
    /// callers should decode the nested `data.key` base64.
    /// both the Swift caller and the JS handler enforce a
    /// minimum bound on the scrypt parameters. Belt-and-braces:
    /// the Swift `precondition` makes weakening at a Swift call
    /// site a build / test crash; the JS `bridge.html` guard
    /// rejects out-of-bound parameters that somehow reach the JS
    /// engine (e.g. via a future bridge surface that does not
    /// route through this Swift wrapper). The thresholds are the
    /// OWASP / RFC 7914 floors:
    /// * N >= 16384 (2^14)
    /// * r >= 8
    /// * p >= 1
    /// * keyLen >= 16 bytes (128-bit security floor)
    /// The default values in this build (SCRYPT_N = 262_144 = 2^18)
    /// far exceed these floors; the bound check exists to keep the
    /// floor unbreakable, not to enforce the (much higher) actual
    /// production values.
    @discardableResult
    public func scryptDerive(password: String, saltBase64: String,
        N: Int = SCRYPT_N, r: Int = SCRYPT_R,
        p: Int = SCRYPT_P, keyLen: Int = SCRYPT_KEY_LEN) throws -> String {
        precondition(N >= 16384,
            "scrypt N must be >= 16384 (got \(N))")
        precondition(r >= 8,
            "scrypt r must be >= 8 (got \(r))")
        precondition(p >= 1,
            "scrypt p must be >= 1 (got \(p))")
        precondition(keyLen >= 16,
            "scrypt keyLen must be >= 16 bytes (got \(keyLen))")
        return try blockingCall { cb, rid in
            let payload: [String: Any] = [
                "password": password,
                "salt": saltBase64,
                "N": N,
                "r": r,
                "p": p,
                "keyLen": keyLen
            ]
            let json = try Self.jsonString(payload)
            JsEngine.shared.registerCallback(requestId: rid, callback: cb)
            try JsEngine.shared.storePendingPayload(requestId: rid, json: json)
            JsEngine.shared.evaluate("bridge.scryptDerive('\(rid)')")
        }
    }

    // MARK: - Internals

    private func blockingCall(settleTimeout: TimeInterval = defaultTimeoutSeconds,
        label: String = "",
        rpcEndpoint: String? = nil,
        _ body: (BridgeCallback, String) throws -> Void) throws -> String {
        let requestId = UUID().uuidString.lowercased()
        return try blockingCallWithExplicitRid(requestId: requestId,
            settleTimeout: settleTimeout, label: label,
            rpcEndpoint: rpcEndpoint) { cb in
            try body(cb, requestId)
        }
    }

    /// Variant of `blockingCall` that accepts an externally-generated
    /// `requestId`. Used by the wallet-envelope helpers so
    /// the Swift facade can reserve the inbound binary slots under
    /// the same rid the JS handler will stage them under.
    /// `settleTimeout` controls only the result wait; the bridge-
    /// readiness wait always uses `defaultTimeoutSeconds`.
    /// `label` is a diagnostic tag (e.g. `"sendTransaction"`) used in
    /// the timing log AND, on timeout, in the user-facing error so the
    /// alert names the handler that stalled. Empty by default so the
    /// non-signing call sites stay generic. The value is just a handler
    /// name plus an elapsed-seconds number, so it carries no payload-
    /// derived data.
    /// `rpcEndpoint`, when supplied (the signing call sites pass it),
    /// turns the timeout path self-diagnosing: on a stall we run a
    /// bounded reachability probe against that endpoint and append the
    /// result to the thrown error. This distinguishes "RPC endpoint
    /// unreachable from this device/network" (the dominant
    /// works-in-simulator-hangs-on-device cause) from "endpoint
    /// reachable but the signing/broadcast itself stalled", surfaced
    /// directly in the user's alert without needing `Logger.debug`
    /// (a no-op in Release).
    private func blockingCallWithExplicitRid(requestId: String,
        settleTimeout: TimeInterval = defaultTimeoutSeconds,
        label: String = "",
        rpcEndpoint: String? = nil,
        body: (BridgeCallback) throws -> Void) throws -> String {
        precondition(!Thread.isMainThread,
            "Blocking bridge call must not be invoked on the main thread")

        if !JsEngine.shared.waitUntilReady(timeout: Self.defaultTimeoutSeconds) {
            throw JsEngineError.bridgeNotReady
        }

        let settle = SettlingCallback()
        do {
            try body(settle)
        } catch {
            JsEngine.shared.removePendingPayload(requestId: requestId)
            throw error
        }
        let started = Date()
        guard let outcome = settle.waitUntilSettled(timeout: settleTimeout) else {
            JsEngine.shared.removePendingPayload(requestId: requestId)
            // Build the timeout diagnostic once and surface it BOTH in
            // the DEBUG-only timing log AND in the thrown error, so the
            // user-facing alert carries the handler name / elapsed /
            // budget without anyone needing to pull `Logger.debug`
            // output (which is a no-op in Release).
            let elapsed = Date().timeIntervalSince(started)
            let tag = label.isEmpty ? "bridge call" : label
            var diagnostic = "\(tag) did not respond within "
                + String(format: "%.0f", settleTimeout) + "s "
                + "(waited " + String(format: "%.1f", elapsed) + "s)"
            // A signing stall is almost always the RPC round-trips
            // inside the send (populate nonce/gas, then broadcast),
            // not the local signing. Probe the endpoint so the alert
            // says whether the device could reach it at all.
            if let endpoint = rpcEndpoint, !endpoint.isEmpty {
                diagnostic += ". " + Self.probeRpcReachability(endpoint: endpoint)
            }
            Logger.debug(category: "BRIDGE_TIMING", "TIMED OUT: \(diagnostic)")
            throw JsEngineError.timeout(diagnostic)
        }
        if !label.isEmpty {
            let elapsed = Date().timeIntervalSince(started)
            Logger.debug(category: "BRIDGE_TIMING",
                "\(label) settled in " + String(format: "%.1f", elapsed) + "s")
        }
        switch outcome {
            case .success(let json):
            return json
            case .failure(let message):
            JsEngine.shared.removePendingPayload(requestId: requestId)
            throw JsEngineError.callFailed(message)
        }
    }

    /// DEBUG-only diagnostic: measure how long a single `eth_chainId`
    /// JSON-RPC round-trip to the configured node takes FROM THE
    /// DEVICE, independent of the WebView/WASM path. This isolates
    /// "is the RPC endpoint slow/unreachable from this device" from
    /// "is the on-device PQC signing slow". Fired fire-and-forget on a
    /// background queue so it never adds latency to the signing call,
    /// and compiled out entirely in Release (`Logger.debug` is a
    /// no-op and the whole body is `#if DEBUG`). The probe sends no
    /// secret material - only the standard `eth_chainId` request.
    private static func debugProbeRpcLatency(endpoint: String, chainId: Int) {
        #if DEBUG
        guard let url = URL(string: endpoint) else { return }
        DispatchQueue.global(qos: .utility).async {
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 30
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(
                "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_chainId\",\"params\":[]}"
                    .utf8)
            let started = Date()
            let sem = DispatchSemaphore(value: 0)
            let task = URLSession.shared.dataTask(with: req) { _, response, error in
                let elapsed = Date().timeIntervalSince(started)
                if let error = error {
                    Logger.debug(category: "BRIDGE_TIMING",
                        "rpcProbe(eth_chainId) failed after "
                        + String(format: "%.1f", elapsed) + "s: \(error)")
                } else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                    Logger.debug(category: "BRIDGE_TIMING",
                        "rpcProbe(eth_chainId) http=\(code) in "
                        + String(format: "%.2f", elapsed) + "s")
                }
                sem.signal()
            }
            task.resume()
            _ = sem.wait(timeout: .now() + 31)
        }
        #endif
    }

    /// Bounded JSON-RPC reachability check, run ONLY on the signing
    /// timeout path (never on the happy path), to tell the user — in
    /// the alert itself — whether the device could reach the configured
    /// RPC endpoint. This separates "endpoint unreachable from this
    /// device/network" (works in simulator, hangs on device) from
    /// "endpoint reachable but the broadcast/signing stalled". Sends
    /// only the standard `eth_chainId` request, so no secret material
    /// leaves the device. The returned string is host-only (never the
    /// full URL, which may carry an API key in its path) and safe to
    /// show in a user-facing alert. Bounded by `timeout`, so it adds at
    /// most a few seconds to an error path that has already waited the
    /// full signing budget. NOTE: this uses the native URLSession
    /// stack, not the WebView's; a "reachable" result here with a
    /// WebView stall points at a WebView-level issue (CORS/ATS),
    /// whereas "unreachable" points at device network / endpoint.
    private static func probeRpcReachability(endpoint: String,
        timeout: TimeInterval = 12) -> String {
        let host = URL(string: endpoint)?.host ?? endpoint
        guard let url = URL(string: endpoint) else {
            return "RPC endpoint \(host): invalid URL"
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(
            "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_chainId\",\"params\":[]}"
                .utf8)
        let started = Date()
        let sem = DispatchSemaphore(value: 0)
        var status = "RPC endpoint \(host): status unknown"
        let task = URLSession.shared.dataTask(with: req) { _, response, error in
            let elapsed = Date().timeIntervalSince(started)
            if let error = error {
                let ns = error as NSError
                status = "RPC endpoint \(host): unreachable "
                    + "(\(ns.domain)#\(ns.code) after "
                    + String(format: "%.1f", elapsed) + "s)"
            } else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                status = "RPC endpoint \(host): reachable "
                    + "(HTTP \(code) in "
                    + String(format: "%.1f", elapsed) + "s)"
            }
            sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + timeout + 1) == .timedOut {
            task.cancel()
            status = "RPC endpoint \(host): unreachable (probe timed out after "
                + String(format: "%.0f", timeout) + "s)"
        }
        return status
    }

    /// Minimal JSON serializer that keeps key order stable (the Android
    /// side uses `JSONObject`, which is unordered, so the iOS side can
    /// produce any key order - but we want deterministic output for
    /// tests).
    private static func jsonString(_ obj: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Private settling callback

private final class SettlingCallback: BridgeCallback {
    enum Outcome { case success(String); case failure(String) }

    private let sem = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var outcome: Outcome?

    func onResult(_ json: String) {
        lock.lock(); if outcome == nil { outcome = .success(json) }; lock.unlock()
        sem.signal()
    }

    func onError(_ message: String) {
        lock.lock(); if outcome == nil { outcome = .failure(message) }; lock.unlock()
        sem.signal()
    }

    func waitUntilSettled(timeout: TimeInterval) -> Outcome? {
        let wait = sem.wait(timeout: .now() + timeout)
        lock.lock(); defer { lock.unlock() }
        if wait == .timedOut { return nil }
        return outcome
    }
}

// MARK: - Async/await convenience wrappers

public extension JsBridge {
    @inlinable
    func initializeAsync(chainId: Int, rpcEndpoint: String) async throws -> String {
        try await withDetachedThrowing { try JsBridge.shared.initialize(chainId: chainId, rpcEndpoint: rpcEndpoint) }
    }

    @inlinable
    func initializeOfflineAsync() async throws -> String {
        try await withDetachedThrowing { try JsBridge.shared.initializeOffline() }
    }

    @inlinable
    func createRandomSeedAsync(keyType: Int) async throws -> String {
        try await withDetachedThrowing { try JsBridge.shared.createRandomSeed(keyType: keyType) }
    }

    @inlinable
    func createRandomAsync(keyType: Int) async throws -> WalletEnvelope {
        try await withDetachedThrowing { try JsBridge.shared.createRandom(keyType: keyType) }
    }

    @inlinable
    func walletFromSeedAsync(seedArray: [Int]) async throws -> WalletEnvelope {
        try await withDetachedThrowing { try JsBridge.shared.walletFromSeed(seedArray: seedArray) }
    }

    @inlinable
    func walletFromPhraseAsync(words: [String]) async throws -> WalletEnvelope {
        try await withDetachedThrowing { try JsBridge.shared.walletFromPhrase(words: words) }
    }

    @inlinable
    func walletFromKeysAsync(privKey: Data, pubKey: Data) async throws -> WalletEnvelope {
        try await withDetachedThrowing {
            try JsBridge.shared.walletFromKeys(privKey: privKey, pubKey: pubKey)
        }
    }

    @inlinable
    func isValidAddressAsync(_ address: String) async throws -> String {
        try await withDetachedThrowing { try JsBridge.shared.isValidAddress(address) }
    }

    @inlinable
    func computeAddressAsync(pubKeyBase64: String) async throws -> String {
        try await withDetachedThrowing { try JsBridge.shared.computeAddress(pubKeyBase64: pubKeyBase64) }
    }

    @inlinable
    func getChecksumAddressAsync(_ address: String) async throws -> String {
        try await withDetachedThrowing { try JsBridge.shared.getChecksumAddress(address) }
    }

    @inlinable
    func encryptWalletJsonAsync(walletInputJson: String, password: String) async throws -> String {
        try await withDetachedThrowing {
            try JsBridge.shared.encryptWalletJson(walletInputJson: walletInputJson, password: password)
        }
    }

    @inlinable
    func decryptWalletJsonAsync(walletJson: String,
        password: String) async throws -> WalletEnvelope {
        try await withDetachedThrowing {
            try JsBridge.shared.decryptWalletJson(walletJson: walletJson, password: password)
        }
    }

    @inlinable
    func getAllSeedWordsAsync() async throws -> String {
        try await withDetachedThrowing { try JsBridge.shared.getAllSeedWords() }
    }

    @inlinable
    func doesSeedWordExistAsync(_ word: String) async throws -> String {
        try await withDetachedThrowing { try JsBridge.shared.doesSeedWordExist(word) }
    }

    @inlinable
    func sendTransactionAsync(privKey: Data, pubKey: Data,
        toAddress: String, valueWei: String,
        gasLimit: String, rpcEndpoint: String,
        chainId: Int, advancedSigningEnabled: Bool) async throws -> String {
        try await withDetachedThrowing {
            try JsBridge.shared.sendTransaction(privKey: privKey, pubKey: pubKey,
                toAddress: toAddress, valueWei: valueWei,
                gasLimit: gasLimit, rpcEndpoint: rpcEndpoint,
                chainId: chainId, advancedSigningEnabled: advancedSigningEnabled)
        }
    }

    @inlinable
    func sendTokenTransactionAsync(privKey: Data, pubKey: Data,
        contractAddress: String, toAddress: String,
        amountWei: String, gasLimit: String,
        rpcEndpoint: String, chainId: Int,
        advancedSigningEnabled: Bool) async throws -> String {
        try await withDetachedThrowing {
            try JsBridge.shared.sendTokenTransaction(privKey: privKey, pubKey: pubKey,
                contractAddress: contractAddress, toAddress: toAddress,
                amountWei: amountWei, gasLimit: gasLimit,
                rpcEndpoint: rpcEndpoint, chainId: chainId,
                advancedSigningEnabled: advancedSigningEnabled)
        }
    }

    @inlinable
    func scryptDeriveAsync(password: String, saltBase64: String,
        N: Int = SCRYPT_N, r: Int = SCRYPT_R,
        p: Int = SCRYPT_P, keyLen: Int = SCRYPT_KEY_LEN) async throws -> String {
        try await withDetachedThrowing {
            try JsBridge.shared.scryptDerive(password: password, saltBase64: saltBase64,
                N: N, r: r, p: p, keyLen: keyLen)
        }
    }
}

// MARK: - Detached thread helper

/// The blocking wrappers require a background thread. `await`-ing them
/// directly from the main actor would trap; wrap every call in a
/// detached task on a global QoS queue.
@usableFromInline
func withDetachedThrowing<T: Sendable>(_ body: @Sendable @escaping () throws -> T) async throws -> T {
    try await Task.detached(priority: .userInitiated) {
        try body()
    }.value
}
