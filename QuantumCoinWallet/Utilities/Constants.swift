// Constants.swift
// Port of the static fields on `GlobalMethods.java` that are used by UI
// code. Kept in a narrowly-scoped enum so the auto-completion hits are
// obvious at call sites.
// Android reference:
// app/src/main/java/com/quantumcoinwallet/app/utils/GlobalMethods.java

import Foundation

public enum Constants {

    // MARK: - Block explorer URL templates

    public static let BLOCK_EXPLORER_TX_HASH_URL = "/txn/{txhash}"
    public static let BLOCK_EXPLORER_ACCOUNT_TRANSACTION_URL = "/account/{address}/txn/page"

    // MARK: - External links

    public static let DP_DOCS_URL = "https://quantumcoin.org/"

    // MARK: - Security / UX

    public static let MINIMUM_PASSWORD_LENGTH: Int = 12
    public static let UNLOCK_TIMEOUT_MS: Int = 300_000 // 5 minutes

    /// Background-return grace window. The mandatory unlock dialog
    /// is presented on `applicationDidBecomeActive` only when the
    /// elapsed time since the last successful unlock exceeds this
    /// threshold; returning from Safari, the block explorer, or any
    /// app-switch within the window keeps the session unlocked.
    ///
    /// Independent of `UNLOCK_TIMEOUT_MS`: the 5-minute foreground
    /// idle timer still relocks after `UNLOCK_TIMEOUT_MS` of no user
    /// interaction while the app stays in the foreground. This
    /// 3-minute window only governs the snapshot-loaded branch of
    /// `SessionLock.applicationDidBecomeActive`. Reboot detection
    /// (`now < lastUnlockMonotonicNanos`) keeps forcing a relock
    /// regardless of the grace window.
    public static let FOREGROUND_UNLOCK_GRACE_MS: Int = 180_000 // 3 minutes

    // MARK: - Wallet types / seed-length buckets

    /// keyType 3 = default (32 seed words).
    public static let KEY_TYPE_DEFAULT: Int = 3
    /// keyType 5 = advanced (36 seed words).
    public static let KEY_TYPE_ADVANCED: Int = 5

    // MARK: - Network / active-session mutable state

// these four mirrors are the legacy "any-thread read" path used
    // by UI surfaces (address-strip explorer button, network name
    // label, token-row contract link, etc.). The CANONICAL source
    // for any signing-correctness comparison is
    // `NetworkConfig.shared` (an actor) plus the
    // `NetworkSnapshot` that signing call sites capture at "Review"
    // tap and re-assert at "Submit" time. See `NetworkConfig.swift`.
    // The mirrors used to be declared `public nonisolated(unsafe)
    // static var` and were mutated from background threads
    // (`BlockchainNetworkManager.applyActive` runs in a detached
    // task) while UI threads concurrently read them. Swift's
    // `String` value type carries an internal buffer pointer that
    // is NOT atomic on assignment; concurrent read-while-write is
    // a documented data race that is undefined behaviour - in
    // practice memory corruption and crash under load.
    // The fix is to gate every mutation and every read through a
    // single `NSLock`. Callers continue to write `Constants.SCAN_API_URL
    // = ...` and read `let s = Constants.SCAN_API_URL`; only the
    // implementation moved behind a lock. Tradeoff: each access
    // pays one lock acquire/release - cheap and contention-free
    // for the read pattern (a handful of accesses per UI event
    // versus many millions per second the lock could service).
    // For call sites that need all four values atomically together
    // (e.g. composing a deep link or a deterministic signing
    // context), use `Constants.networkSnapshot()` so a mid-flight
    // network switch cannot tear across the four reads.

    private static let _networkLock = NSLock()
    nonisolated(unsafe) private static var _SCAN_API_URL: String = ""
    nonisolated(unsafe) private static var _RPC_ENDPOINT_URL: String = ""
    nonisolated(unsafe) private static var _BLOCK_EXPLORER_URL: String = ""
    nonisolated(unsafe) private static var _CHAIN_ID: Int = 0

    /// Updated by `BlockchainNetworkManager.setActive(...)` after a
    /// network switch so every screen sees the same base URL.
    public static var SCAN_API_URL: String {
        get { _networkLock.lock(); defer { _networkLock.unlock() }; return _SCAN_API_URL }
        set { _networkLock.lock(); defer { _networkLock.unlock() }; _SCAN_API_URL = newValue }
    }
    public static var RPC_ENDPOINT_URL: String {
        get { _networkLock.lock(); defer { _networkLock.unlock() }; return _RPC_ENDPOINT_URL }
        set { _networkLock.lock(); defer { _networkLock.unlock() }; _RPC_ENDPOINT_URL = newValue }
    }
    public static var BLOCK_EXPLORER_URL: String {
        get { _networkLock.lock(); defer { _networkLock.unlock() }; return _BLOCK_EXPLORER_URL }
        set { _networkLock.lock(); defer { _networkLock.unlock() }; _BLOCK_EXPLORER_URL = newValue }
    }
    public static var CHAIN_ID: Int {
        get { _networkLock.lock(); defer { _networkLock.unlock() }; return _CHAIN_ID }
        set { _networkLock.lock(); defer { _networkLock.unlock() }; _CHAIN_ID = newValue }
    }

    /// Atomic snapshot of all four network mirrors. Use this when
    /// composing a deep link, a deterministic signing context, or
    /// any other value that must observe the four mirrors
    /// consistently (i.e. all from the same network configuration,
    /// not a torn mix from mid-flight `setActive` updates).
    /// Signing-correctness paths should still go through the
    /// canonical `NetworkConfig.shared` actor + `NetworkSnapshot`
    /// re-assertion at submit time; this snapshot covers the
    /// non-signing readers that previously did four independent
    /// `Constants.*` reads.
    public static func networkSnapshot() -> (
        scanApiUrl: String,
        rpcEndpoint: String,
        blockExplorerUrl: String,
        chainId: Int
    ) {
        _networkLock.lock()
        defer { _networkLock.unlock() }
        return (
            scanApiUrl: _SCAN_API_URL,
            rpcEndpoint: _RPC_ENDPOINT_URL,
            blockExplorerUrl: _BLOCK_EXPLORER_URL,
            chainId: _CHAIN_ID
        )
    }
}
