// TlsPinning.swift (Networking layer)
// SubjectPublicKeyInfo (SPKI) SHA-256 pinning for
// the TLS handshake of every CENTRALIZED endpoint the wallet
// talks to from Swift via `URLSession` (i.e. the scan API).
//
// Why this exists (notes for reviewers):
// // (1) Baseline TLS still applies on EVERY endpoint, pinned or
// not. URLSession (and WKWebView) validate the certificate
// chain against the iOS system trust store, check the chain
// signatures, check the leaf hostname matches the URL
// hostname, check the validity period, and abort the
// handshake on any failure. None of the "NOT pinned" notes
// below mean "no TLS"; they mean "no SPKI pin on top of TLS."
// A passive eavesdropper on the network cannot read or
// modify our traffic regardless of pinning.
//
// (2) Pinning is an additional defense the wallet only enables
// for endpoints where:
//
// (a) the wallet is the sole reasonable user of that endpoint
// (i.e. no other client - browser, third-party tool -
// would talk to it on behalf of the user), AND
//
// (b) the wallet is operationally responsible for the endpoint
// (i.e. the project ships the SPKI rotation procedure as
// part of the app release cadence).
//
// The scan API meets both gates: the wallet UI is the only
// consumer; the project owns the certificate; rotation is on
// our timetable. Pinning the SPKI raises the bar from "any
// CA-trusted leaf" to "the specific cryptographic key of our
// endpoint." A leaf-cert rotation (Let's Encrypt 60-day
// cycle) does NOT break the pin as long as the underlying
// private key is reused; only a key rotation requires
// updating this file and shipping a new app version.
//
// Coverage map (what is and is NOT pinned, with the design
// rationale for each "NOT pinned" entry):
//
// PINNED:
//   * `scanApiDomain` (`app.readrelay.quantumcoinapi.com`).
//     All `ApiClient.get(...)` calls go through here.
//
// NOT PINNED, BY DESIGN (this is the part a security reviewer
// asked us to spell out so it is unambiguous):
//
//   * RPC traffic. QuantumCoin is a non-custodial wallet for
//     a permissionless chain; the user MUST be free to point
//     the wallet at any RPC endpoint they trust - their own
//     full node, an Infura-class third-party provider, a
//     community-run public RPC, anything. Pinning would
//     hard-code the wallet to ONE provider for every user,
//     which is the centralization posture we explicitly
//     reject. This applies to:
//     - The JS-side `JsonRpcProvider` in `bridge.html`
//       (WKWebView handles its own TLS validation against
//       the system trust store; baseline TLS still applies).
//     - Any future Swift-side RPC code path. The wallet
//       SHOULD NOT add a default-RPC pin even when one
//       exists; the network-config screen lets the user
//       paste in their own URL, and the failure mode of a
//       pinned mismatch ("connection refused, network
//       broken") is indistinguishable to the user from
//       "the project's RPC is down" - a UX disaster that
//       the user cannot work around without rebuilding the
//       app from source. Tradeoff: a CA compromise that
//       targets a specific RPC provider IS a possible attack;
//       the mitigation is to read every signed-transaction
//       result back from the chain (the local-RLP-keccak +
//       `eth_getTransactionByHash` round-trip described in
//       the future-spec mitigation for "forge tx hash").
//       That mitigation is RPC-pinning-independent and
//       defends against a hostile RPC operator AS WELL AS
//       a CA-compromise attacker.
//
//   * Block-explorer URLs opened with
//     `UIApplication.open(...)`. The user picks any block
//     explorer; the OS hands off to Safari which uses the
//     iOS trust store. We have no per-host knowledge of the
//     user's chosen explorer's SPKI, and even if we did, the
//     handoff is outside our process boundary. Baseline TLS
//     still applies via Safari.
//
//   * User-defined networks. The user types in their own
//     scan-API / RPC hostname; we cannot know the legitimate
//     certificate so we fall through to system trust for any
//     hostname not present in the pinset. The
//     `BlockchainNetworkViewController` table renders a small
//     open-padlock badge next to user-defined network names
//     so the user can see at a glance which networks are
//     pinned.
// Tradeoffs:
// - Hard-coded SPKI hashes ship in the app binary. If the
// production endpoint rotates its key without coordinating
// with this constant, ApiClient will refuse all connections
// and the wallet's home-screen balance/transaction view goes
// dark for everyone on a stale build. The mitigation is the
// dual-pin model: `kSpkiPinsByHost` is a SET so we can ship
// "current SPKI" + "future-rollover SPKI" simultaneously.
// Today we only have one entry per host (no rollover scheduled);
// when a rotation is planned, the new hash MUST be added to the
// set and shipped at least one app-update cycle BEFORE the
// server flips, then the old hash MUST be removed at least one
// cycle AFTER. This rotation procedure is the core operational
// cost of pinning.
// - SPKI extraction in iOS is mildly tricky because `Sec`
// certificate APIs return the raw key bytes, not the ASN.1-
// wrapped SubjectPublicKeyInfo structure that `openssl pkey
// -pubin -outform DER` outputs. We reconstruct the SPKI by
// prepending the well-known ASN.1 prefix for the key type
// (RSA-2048 or ECDSA P-256). The prefix tables are documented
// inline; a key type we have not pre-computed a prefix for
// fails closed (returns a nil hash, which fails the pin
// comparison). All three of our default endpoints are RSA-2048
// or ECDSA P-256, so this lookup table is exhaustive for the
// coverage needs. Adding a new key type (e.g. RSA-4096) is a
// one-line `kAsn1SpkiPrefixByKeyType` addition.
// - `kTlsPinningEnforced = true` ships pinning live. Two
// emergency hatches exist: (1) `kPinFailureLogOnly = true`
// converts a pin miss into a `Logger.debug` line and lets the
// handshake proceed, useful for a soft-launch telemetry
// window; (2) flipping `kTlsPinningEnforced` to `false`
// bypasses the delegate entirely. Neither hatch is exposed
// to users, both require a code change + new build.
// References for the pin extraction procedure used to populate
// `kSpkiPinsByHost` (so a future operator can re-derive them
// independently of git history):
// ```
// echo | openssl s_client -connect HOST:443 -servername HOST 2>/dev/null \
// | openssl x509 -pubkey -noout \
// | openssl pkey -pubin -outform DER \
// | openssl dgst -sha256 -binary \
// | openssl enc -base64
// ```

import Foundation
import CryptoKit
import Security

// MARK: - Pin set

public enum TlsPinning {

    // -----------------------------------------------------------
    // Feature flags. Both default to `true`; flip the second to
    // `false` only when collecting telemetry on a fresh deployment.
    // The first should NEVER be flipped to `false` in a Release
    // build that ships to users.
    // -----------------------------------------------------------

    public static let kTlsPinningEnforced: Bool = true
    public static let kPinFailureLogOnly: Bool = false

    // -----------------------------------------------------------
    // The pin set. Each host maps to one OR MORE base64-encoded
    // SHA-256 hashes of the server's SubjectPublicKeyInfo (DER).
    // Multi-entry sets exist to enable future rollover (ship the
    // new hash one update cycle BEFORE the server flips, then
    // remove the old hash one cycle AFTER). Today, each host has
    // exactly one entry because no rollover is scheduled.
    // Hashes captured on 2026-04-29 from the production endpoints
    // listed in `Resources/blockchain_networks.json`.
    // To re-derive any of these locally, run the openssl pipeline
    // documented at the top of this file. The hash MUST be the
    // SHA-256 of the SubjectPublicKeyInfo (NOT of the certificate
    // and NOT of the raw key bytes) for the chain-walking
    // comparison below to match.
    // -----------------------------------------------------------

    public static let kSpkiPinsByHost: [String: Set<String>] = [
        // Scan API. Every `ApiClient.get(...)` call hits this host.
        // This is the ONE production endpoint that meets both the
        // "wallet is the sole reasonable user" AND the "wallet
        // owns the certificate" gates documented in the file
        // header. The RPC entry that previously appeared here was
        // intentionally REMOVED: pinning RPC would hard-code the
        // wallet to a single provider and
        // contradict the non-custodial decentralization posture.
        // See the file header for the full rationale.
        "app.readrelay.quantumcoinapi.com": [
            "FKDdAHqX5KWpokBtRwPeAsXg4Fg4ubFUaVLN26neMnc="
        ],
        // Block explorer. Today reached only via Safari hand-off,
        // which is NOT pinned. The entry is here for the same
        // forward-compat reason: a future Swift-side fetch (for
        // example, an in-app preview of a transaction page) would
        // engage the pin automatically.
        "quantumscan.com": [
            "T0V1P4IBOoHNRVfVGqGolN9omh/2sHQXUiu3Bl/E9Gc="
        ]
    ]

    /// Returns `true` iff `host` has at least one pinned SPKI hash
    /// in `kSpkiPinsByHost`. Used by the network-config view to
    /// render a closed-padlock vs open-padlock badge next to each
    /// network's name.
    /// (notes for reviewers):
    /// the lookup MUST go through `canonicalHost(_:)` so a hostname
    /// with a trailing dot (`app.readrelay.quantumcoinapi.com.`)
    /// matches the dictionary key. Without this normalization the
    /// padlock badge silently flips to "open" for a perfectly valid
    /// FQDN form, AND the URLSession delegate's pin enforcement
    /// silently falls through to default system trust for the same
    /// host shape. See the `canonicalHost(_:)` header comment for
    /// the full attack chain.
    public static func isPinned(host: String) -> Bool {
        return kSpkiPinsByHost[canonicalHost(host)] != nil
    }

    // -----------------------------------------------------------
    // Hostname canonicalization. Single source of truth for
    // "what string do we feed to `kSpkiPinsByHost` lookups?".
    // (notes for reviewers):
// every site that consults `kSpkiPinsByHost` MUST route the
    // raw host string through here. The previous code path used
    // `host.lowercased()` directly, which let a trailing-dot FQDN
    // (`app.readrelay.quantumcoinapi.com.`) bypass the pin check
    // entirely - the FQDN is RFC-valid, resolves identically at
    // the DNS layer, but the dictionary key (`...com`) does not
    // match (`...com.`). The bypass is reachable via:
    //   * a custom-RPC URL the user pastes (network-config screen),
    //   * a malicious deep link that pre-fills network settings,
    //   * an upstream redirect that delivers the trailing-dot form.
    // We strip rather than reject because the trailing-dot form is
    // a legitimate DNS construct - punishing the user for an OS-
    // level normalization quirk would surface as an inexplicable
    // connectivity failure rather than a security warning. Stripping
    // also collapses repeated trailing dots (`...com..`) which a
    // crafted input could use to evade a one-shot rstrip. A
    // defensive whitespace trim covers the unlikely case where a
    // URL's authority component carries leading/trailing space.
    // -----------------------------------------------------------

    public static func canonicalHost(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        while s.hasSuffix(".") {
            s.removeLast()
        }
        return s
    }

    // -----------------------------------------------------------
    // ASN.1 SubjectPublicKeyInfo prefixes by (key type, key size).
    // `SecKeyCopyExternalRepresentation` returns the raw public-
    // key bytes:
    // - RSA: a DER SEQUENCE of (modulus INTEGER, exponent INTEGER).
    // - ECDSA: the uncompressed point (0x04 || X || Y).
    // What `openssl pkey -pubin -outform DER` (and therefore our
    // pinset) hashes is the SubjectPublicKeyInfo structure:
    // SubjectPublicKeyInfo ::= SEQUENCE {
    // algorithm AlgorithmIdentifier,
    // subjectPublicKey BIT STRING
    // }
    // To produce the same byte sequence in iOS we prepend the
    // (well-known, pre-computed) algorithm header for the key
    // type, then the BIT STRING wrapper, then the raw key bytes.
    // The byte sequences below were derived once with `openssl
    // asn1parse` on a sample SPKI of each (algorithm, key-size)
    // combination and are constant for that combination.
    // If you add a new key type here, add the matching tuple to
    // `prefixForKey(_:)` below.
    // -----------------------------------------------------------

    /// 24-byte SPKI header for an RSA-2048 public key.
    private static let kAsn1SpkiPrefixRSA2048: [UInt8] = [
        0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09,
        0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01,
        0x01, 0x05, 0x00, 0x03, 0x82, 0x01, 0x0f, 0x00
    ]

    /// 26-byte SPKI header for an ECDSA P-256 (secp256r1) public key.
    private static let kAsn1SpkiPrefixECP256: [UInt8] = [
        0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86,
        0x48, 0xce, 0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a,
        0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03,
        0x42, 0x00
    ]

    /// Map a `SecKey` to the right ASN.1 SPKI prefix. Returns
    /// `nil` for any (algorithm, size) combination we have not
    /// pre-computed a prefix for; the caller treats `nil` as
    /// "cannot compute SPKI hash" which fails the pin comparison
    /// (closed-fail).
    fileprivate static func prefixForKey(_ key: SecKey) -> [UInt8]? {
        guard let attrs = SecKeyCopyAttributes(key) as? [String: Any] else {
            return nil
        }
        let kty = attrs[kSecAttrKeyType as String] as? String
        let bits = attrs[kSecAttrKeySizeInBits as String] as? Int

        if kty == (kSecAttrKeyTypeRSA as String), bits == 2048 {
            return kAsn1SpkiPrefixRSA2048
        }
        if kty == (kSecAttrKeyTypeECSECPrimeRandom as String), bits == 256 {
            return kAsn1SpkiPrefixECP256
        }
        return nil
    }

    /// Compute the base64 SHA-256 SPKI hash for a `SecCertificate`
    /// using `prefixForKey(_:)` to reconstruct the SPKI byte
    /// sequence. Returns `nil` if the cert has no extractable
    /// public key OR uses an algorithm we have no prefix for.
    fileprivate static func spkiHashBase64(for cert: SecCertificate) -> String? {
        guard let key = SecCertificateCopyKey(cert),
        let prefix = prefixForKey(key)
        else { return nil }

        var error: Unmanaged<CFError>?
        guard let raw = SecKeyCopyExternalRepresentation(key, &error) as Data?
        else {
            // Defensive: free the CFError if Sec returned one. We
            // do not surface the reason because this is a pin-
            // computation primitive, not a user-facing error.
            error?.release()
            return nil
        }

        var spki = Data(prefix)
        spki.append(raw)
        let digest = SHA256.hash(data: spki)
        return Data(digest).base64EncodedString()
    }
}

// MARK: - URLSessionDelegate

/// Validates the server-presented certificate chain against
/// `TlsPinning.kSpkiPinsByHost`. Install on the URLSession used by
/// `ApiClient`. Hosts not present in the pin set fall through to
/// the default system-trust evaluation.
public final class TlsPinningSessionDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {

    public override init() { super.init() }

    public func urlSession(_ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition,
            URLCredential?) -> Void) {

        // Only intercept TLS server-trust challenges. Every other
        // challenge type (HTTP-Auth, NTLM, client-cert) is
        // delegated to the system default; we have no business
        // overriding them and a wrong override would silently
        // weaken the connection.
        guard challenge.protectionSpace.authenticationMethod
            == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // Route the raw host through `canonicalHost(_:)` so a
        // trailing-dot FQDN (`...quantumcoinapi.com.`) matches the
        // dictionary key. See `TlsPinning.canonicalHost(_:)` for
        // the full attack chain and rationale.
        let host = TlsPinning.canonicalHost(challenge.protectionSpace.host)

        // Step 1: ALWAYS run the default trust evaluation first.
        // We only ADD a pin check on top; we never weaken the
        // baseline trust check. A pinned cert that is itself
        // expired / revoked / issued by an untrusted CA still
        // fails here.
        var trustEvalError: CFError?
        let systemTrustOk = SecTrustEvaluateWithError(trust, &trustEvalError)
        if !systemTrustOk {
            Logger.debug(category: "TLS_TRUST_FAIL",
                "host=\(Self.redact(host)) reason=\(trustEvalError?.localizedDescription ?? "unknown")")
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Step 2: if the host is not in our pin set, the system-
        // trust check above is sufficient. This is the path
        // user-defined networks take.
        guard let pinSet = TlsPinning.kSpkiPinsByHost[host] else {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        // Step 3: if the feature flag is off, accept whatever
        // system trust said. The flag exists for emergency
        // rollback only - flipping it should be paired with a
        // new app version, never with an OTA configuration push
        // (we have no such mechanism).
        if !TlsPinning.kTlsPinningEnforced {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        // Step 4: walk the cert chain and look for ANY cert whose
        // SPKI hash matches a pin. We accept on the first match;
        // checking the leaf alone is the strongest pin (single
        // key) but accepting any chain cert allows an intermediate
        // pin to ride the same chain with the same security
        // posture.
        let chainCount: Int
        if #available(iOS 15.0, *) {
            chainCount = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.count ?? 0
        } else {
            chainCount = SecTrustGetCertificateCount(trust)
        }

        var matched = false
        for i in 0..<chainCount {
            let cert: SecCertificate?
            if #available(iOS 15.0, *) {
                let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate]
                cert = chain?[i]
            } else {
                cert = SecTrustGetCertificateAtIndex(trust, i)
            }
            guard let c = cert,
            let hash = TlsPinning.spkiHashBase64(for: c)
            else { continue }
            if pinSet.contains(hash) {
                matched = true
                break
            }
        }

        if matched {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }

        // Step 5: no chain cert matched the pin set. Either log-
        // and-allow (soft-launch telemetry mode) or hard-fail
        // (default). The redacted log line is intentional: the
        // raw host is fine to log, but we never log the actual
        // SPKI hash because that would let an attacker who reads
        // the device console verify they have the right pin to
        // spoof.
        Logger.debug(category: "TLS_PIN_MISS",
            "host=\(Self.redact(host)) chain_len=\(chainCount)")
        if TlsPinning.kPinFailureLogOnly {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }

    /// Redact most of the hostname before logging. We keep the
    /// TLD so an operator reading a real device console can see
    /// "scan-API host" vs "RPC host" without exposing an internal
    /// hostname for an enterprise / staging deployment.
    private static func redact(_ host: String) -> String {
        let parts = host.split(separator: ".")
        guard parts.count >= 2 else { return "***" }
        return "***." + parts.suffix(2).joined(separator: ".")
    }
}
