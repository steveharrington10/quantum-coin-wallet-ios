// PrefConnect.swift (Layer 1 - UI-pref storage primitive)
// Lightweight JSON pref-file backing store for the small set of
// flags the app needs to read BEFORE the user has typed their
// password (and the strongbox is therefore still locked). Backed
// by `Application Support/DP_QUANTUM_COIN_WALLET_APP_PREF.json`.
// Why this exists:
// The wallet's authoritative state - addresses, encrypted seed
// envelopes, custom networks, the user's "phone backup" /
// "advanced signing" / "camera permission asked" flags - lives
// in `Strongbox.shared` and is persisted via `AtomicSlotWriter`
// under the v2 file codec. Strongbox content is encrypted under
// a scrypt-derived key and never decryptable without the user's
// password.
// That gives us a chicken-and-egg problem for a small set of
// facts the app needs to know AT BOOT, before the user has had
// a chance to unlock:
// - Whether the user has accepted the EULA (gate the splash).
// - Which language to render the splash + unlock dialog in.
// - Which blockchain network to bootstrap the JS bridge with
// (the v2 strongbox holds the user's customised network
// list, but the bundled MAINNET resource is the boot-time
// default before the unlock has happened).
// - The current-wallet pointer (so the wallets list opens to
// the right row when the user unlocks). This is an INDEX
// into the strongbox; on its own it tells an attacker no
// more than "the user has at least one wallet", which the
// presence of the slot file already tells them.
// - The user's "phone backup" toggle, so we can apply
// `isExcludedFromBackupKey` to the slot files BEFORE the
// strongbox is unlocked (see BackupExclusion.swift).
// - The user's "advanced signing" toggle, read pre-unlock by
// transaction-review screens that need to render fee
// defaults before any network call.
// - The user's chosen backup folder URI for `.wallet`
// exports (bookmark resolution must run before the user
// unlocks because the import / restore-from-folder flows
// happen pre-unlock on a fresh install).
// - The "camera permission asked once" flag, used to gate
// the system permission prompt that runs from the QR
// picker entry on the Send screen.
// Every other piece of wallet-meaningful state is FORBIDDEN in
// this file. The invariant is enforced both by code review and
// by the grep-style invariant test in `StrongboxLayerTests`.
// In particular this file is NOT allowed to know about:
// - Wallet addresses (those live in the encrypted strongbox).
// - Encrypted seed envelopes.
// - Custom blockchain networks.
// - Any keys with prefixes `SECURE_*`, `WALLET_*` (other
// than the explicit allowlist below), `MaxWalletIndex`,
// `BLOCKCHAIN_NETWORK_LIST`, `INDEX_ADDRESS`,
// `ADDRESS_INDEX`, or anything that would let a forensic
// reader enumerate the user's wallet count or addresses
// from the on-disk pref file alone.
// Historical note: an earlier version of this file held the
// v1 keystore (encrypted main key, encrypted strongbox blob,
// plaintext address maps, plaintext network list). That
// surface is gone; the v2 strongbox is the single source of
// truth, and this file's API is restricted to the UI pref
// allowlist above.
// Durability discipline (durability fix plan):
// `flushLocked` mirrors the AtomicSlotWriter discipline:
// open(O_WRONLY|O_CREAT|O_TRUNC) -> writeAll -> setProtection
// -> F_FULLFSYNC the data fd -> rename .tmp into place ->
// F_FULLFSYNC the parent directory. This closes the durability gap
// (a power loss between the .atomic-rename and the journal
// flush losing every pref-file write since the last flush).
// Public setters (`writeString`, `writeInt`, `writeBool`,
// `remove`, `removeIfPresent`, `clearAll`) are THROWING; every
// call site must `try` and explicitly handle / log a flush
// failure rather than silently dropping it. The protection
// class on the data file is `completeUntilFirstUserAuthentication`
// (intentionally weaker than the strongbox slot's `complete`
// because pref values must be readable BEFORE the user has
// typed their password — the EULA-accepted flag, the language
// pick, and the active-wallet index are all read on the
// splash, before the unlock dialog appears). The slot files
// themselves remain `complete`; the weaker class only applies
// to this small allowlist of UI prefs.
// Corrupt-file handling (durability fix plan):
// `init` distinguishes "file missing" (fresh install) from
// "file present-but-unparseable" (silent NAND corruption,
// process killed mid-write before the hardening landed, etc). The
// missing case is treated as a fresh install (memo := empty);
// the corrupt case renames the bad file aside as
// `*.corrupt.<unixtimestamp>` so the next setter call cannot
// silently overwrite it. Closes the durability gap.

import Foundation
import Darwin

/// Errors thrown by the PrefConnect flush pipeline. Each variant
/// carries enough context (path + errno) to debug a flush
/// regression without exposing wallet-meaningful state.
public enum PrefConnectError: Error, CustomStringConvertible {
    case openFailed(path: String, errno: Int32)
    case writeFailed(path: String, errno: Int32)
    case syncFailed(path: String, errno: Int32)
    case dirSyncFailed(path: String, errno: Int32)
    case renameFailed(from: String, to: String, errno: Int32)
    case protectionClassFailed(path: String, underlying: String)
    case encodeFailed(underlying: String)

    public var description: String {
        switch self {
            case .openFailed(let p, let e):
            return "PrefConnect: open(\(p)) failed errno=\(e)"
            case .writeFailed(let p, let e):
            return "PrefConnect: write(\(p)) failed errno=\(e)"
            case .syncFailed(let p, let e):
            return "PrefConnect: F_FULLFSYNC(\(p)) failed errno=\(e)"
            case .dirSyncFailed(let p, let e):
            return "PrefConnect: F_FULLFSYNC(dir \(p)) failed errno=\(e)"
            case .renameFailed(let f, let t, let e):
            return "PrefConnect: rename(\(f) -> \(t)) failed errno=\(e)"
            case .protectionClassFailed(let p, let u):
            return "PrefConnect: setAttributes(\(p)) failed: \(u)"
            case .encodeFailed(let u):
            return "PrefConnect: JSON encode failed: \(u)"
        }
    }
}

/// Allowlisted preference keys. A key NOT in this enum has no
/// business in `PrefConnect` and any attempt to write one is a
/// review-blocker. The grep-style invariant test in
/// `StrongboxLayerTests` enforces the negative space (no
/// `SECURE_*` / `WALLET_*` keys leak into this file).
public enum PrefKeys {
    /// Wall-clock max wallets the strongbox is willing to host.
    /// Used by `UnlockCoordinatorV2.appendWallet` and not a
    /// preference per se; lives here so the Android-parity
    /// constant has one home.
    public static let MAX_WALLETS = 128

    // MARK: - UI / boot prefs (all readable PRE-unlock)

    /// Has the user accepted the EULA on first launch?
    public static let EULA_ACCEPTED = "EULA_ACCEPTED"
    /// User-chosen UI language code (e.g. `"en_us"`).
    public static let LANGUAGE_CODE = "LANGUAGE_CODE"

    /// Currently-selected wallet index. An integer offset into
    /// the strongbox `wallets` array, NOT an address.
    public static let WALLET_CURRENT_ADDRESS_INDEX_KEY = "WALLET_CURRENT_ADDRESS_INDEX_KEY"

    /// Boot-time blockchain network selection. The bundled
    /// MAINNET network is loaded from
    /// `Resources/blockchain_networks.json`; this pref records
    /// which entry in that bundled list (or, post-unlock, in
    /// the user's customised list) is the active one.
    public static let BLOCKCHAIN_NETWORK_ID_INDEX_KEY = "BLOCKCHAIN_NETWORK_ID_INDEX_KEY"

    /// User-chosen iCloud Drive folder URI for `.wallet`
    /// exports. Bookmark-resolved by `CloudBackupManager`.
    public static let CLOUD_BACKUP_FOLDER_URI_KEY = "CLOUD_BACKUP_FOLDER_URI"

    /// User toggle: include strongbox slot files in iCloud
    /// Backup / unencrypted Finder backups? Read pre-unlock by
    /// `BackupExclusion.applyToStrongboxFiles` so the file-
    /// resource flag can be re-applied before the user unlocks.
    public static let BACKUP_ENABLED_KEY = "BACKUP_ENABLED"

    /// User toggle: bump the gas price 30x for "fast inclusion"
    /// signing. Read pre-unlock by the transaction-review
    /// screen so the displayed fee matches what will be signed.
    public static let ADVANCED_SIGNING_ENABLED_KEY = "ADVANCED_SIGNING_ENABLED"

    /// One-shot flag set after the camera permission prompt has
    /// been shown to the user. Lets the Send screen's QR entry
    /// distinguish "first-time prompt" from "user previously
    /// declined" (UI copy differs).
    public static let CAMERA_PERMISSION_ASKED_ONCE = "CAMERA_PERMISSION_ASKED_ONCE"
}

public final class PrefConnect {

    // MARK: - Singleton

    public static let shared = PrefConnect()

    // MARK: - Storage

    private let queue = DispatchQueue(label: "pref-connect", qos: .userInitiated)
    private let fileURL: URL
    private var memo: [String: Any]

    private init() {
        let fm = FileManager.default
        let support = try! fm.url(for: .applicationSupportDirectory,
            in: .userDomainMask, appropriateFor: nil, create: true)
        self.fileURL = support.appendingPathComponent("DP_QUANTUM_COIN_WALLET_APP_PREF.json")
        // Distinguish "file missing" (treated as a fresh install,
        // empty memo) from "file present but unparseable" (treated
        // as a corrupt pref file we MUST NOT silently overwrite).
        // What it closes:
        //   . The historical
        //   shape silently produced an empty memo for both cases;
        //   the corrupt-but-overwritable case is the dangerous one
        //   because the next `writeXxx` would replace the corrupt
        //   file with a near-empty pref file, losing every previous
        //   setting (EULA acceptance, language code, current wallet
        //   index, network selection, backup-enabled toggle).
        // Why this shape:
        //   On corrupt we rename the bad file aside as
        //   `<basename>.corrupt.<unix-ts>` so a forensic tool can
        //   still extract the previously-accepted values
        //   (EULA_ACCEPTED, LANGUAGE_CODE, etc.). The next launch
        //   sees no pref file and treats it as a first launch,
        //   which is recoverable from user input. Silently
        //   overwriting a corrupt pref file is not.
        // Tradeoffs:
        //   The quarantined file accumulates per-corruption — an
        //   adversary that can write to the app container could
        //   spam corrupt files to fill the disk. The threat model
        //   already assumes such an attacker can trash storage at
        //   will; we accept the bound in exchange for forensic
        //   recovery.
        if FileManager.default.fileExists(atPath: fileURL.path) {
            if let data = try? Data(contentsOf: fileURL),
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                self.memo = obj
            } else {
                // Quarantine the corrupt file so the next writeXxx
                // doesn't silently overwrite a previously-accepted
                // EULA / language / network selection.
                let stamp = Int(Date().timeIntervalSince1970)
                let quarantine = fileURL.appendingPathExtension("corrupt.\(stamp)")
                do {
                    try FileManager.default.moveItem(at: fileURL, to: quarantine)
                    Logger.warn(category: "PREFS_CORRUPT_QUARANTINED",
                        "moved corrupt prefs file to \(quarantine.lastPathComponent)")
                } catch {
                    // If the quarantine rename itself fails the
                    // best we can do is start with an empty memo
                    // and log; the next writeXxx will overwrite
                    // the file. Log so the regression is
                    // observable in DEBUG.
                    Logger.warn(category: "PREFS_CORRUPT_QUARANTINE_FAIL",
                        "could not quarantine corrupt prefs: \(error)")
                }
                self.memo = [:]
            }
        } else {
            self.memo = [:]
        }
    }

    // MARK: - Typed getters / setters

    public func readString(_ key: String, default def: String = "") -> String {
        queue.sync { (memo[key] as? String) ?? def }
    }

    public func writeString(_ key: String, _ value: String) throws {
        try queue.sync {
            memo[key] = value
            try flushLocked()
        }
    }

    public func readInt(_ key: String, default def: Int = -1) -> Int {
        queue.sync {
            if let n = memo[key] as? Int { return n }
            if let s = memo[key] as? String, let n = Int(s) { return n }
            return def
        }
    }

    public func writeInt(_ key: String, _ value: Int) throws {
        try queue.sync {
            memo[key] = value
            try flushLocked()
        }
    }

    public func readBool(_ key: String, default def: Bool = false) -> Bool {
        queue.sync { (memo[key] as? Bool) ?? def }
    }

    public func writeBool(_ key: String, _ value: Bool) throws {
        try queue.sync {
            memo[key] = value
            try flushLocked()
        }
    }

    public func remove(_ key: String) throws {
        try queue.sync {
            memo.removeValue(forKey: key)
            try flushLocked()
        }
    }

    /// Remove `key` only if it exists. Avoids a flush when the key
    /// is already absent.
    @discardableResult
    public func removeIfPresent(_ key: String) throws -> Bool {
        try queue.sync {
            guard memo[key] != nil else { return false }
            memo.removeValue(forKey: key)
            try flushLocked()
            return true
        }
    }

    public func contains(_ key: String) -> Bool {
        queue.sync { memo[key] != nil }
    }

    public func clearAll() throws {
        try queue.sync {
            memo.removeAll()
            try flushLocked()
        }
    }

    // MARK: - Internal

    /// Durably write the in-memory `memo` to `fileURL`. Mirrors the
    /// AtomicSlotWriter discipline (open + writeAll + setProtection +
    /// F_FULLFSYNC data + rename + F_FULLFSYNC parent dir) instead
    /// of relying on `Data.write(to:options: [.atomic])`, which only
    /// renames at the metadata level and leaves the rename in the
    /// journal until a subsequent flush event. A power cut between
    /// rename-completed and journal-flushed under the old shape
    /// could lose every pref-file write since the last flush —
    /// including `WALLET_CURRENT_ADDRESS_INDEX_KEY`,
    /// `BLOCKCHAIN_NETWORK_ID_INDEX_KEY`, `BACKUP_ENABLED_KEY`, etc.
    /// What it closes:
    ///   (PrefConnect power-
    ///   loss data loss).
    /// Why this shape:
    ///   Mirrors `AtomicSlotWriter.write` so a future maintainer
    ///   reading both files sees the same six-step sequence
    ///   (open / writeAll / setProtection / F_FULLFSYNC data /
    ///   rename / F_FULLFSYNC parent dir). The protection class is
    ///   intentionally `completeUntilFirstUserAuthentication` (NOT
    ///   the strongbox slot's `complete`) because pref values must
    ///   be readable PRE-unlock by the launch path (EULA acceptance,
    ///   language code, backup-enabled toggle, current network).
    /// Tradeoffs:
    ///   F_FULLFSYNC adds ~5-30 ms per pref write on modern iPhones
    ///   (~200 ms on older devices). The pref file changes once per
    ///   user toggle / network switch / wallet-index change, so the
    ///   cost is below user perception.
    /// Cross-references:
    ///   - `AtomicSlotWriter.swift` for the matching F_FULLFSYNC
    ///     pattern on the strongbox slot files.
    ///   - .
    private func flushLocked() throws {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: memo,
                options: [.sortedKeys, .prettyPrinted])
        } catch {
            throw PrefConnectError.encodeFailed(
                underlying: String(describing: error))
        }
        let tmpURL = fileURL.appendingPathExtension("tmp")
        let openFlags = O_WRONLY | O_CREAT | O_TRUNC
        let mode: mode_t = 0o600
        let fd = tmpURL.path.withCString { open($0, openFlags, mode) }
        guard fd >= 0 else {
            throw PrefConnectError.openFailed(path: tmpURL.path, errno: errno)
        }
        do {
            try writeAll(fd: fd, data: data, label: tmpURL.path)
            // Pin the protection class explicitly so the pref file
            // is unreadable to forensic tools BEFORE the first
            // unlock after boot. `.completeUntilFirstUserAuthentication`
            // is the right class for pre-unlock-readable data.
            do {
                try FileManager.default.setAttributes(
                    [FileAttributeKey.protectionKey:
                            FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: tmpURL.path)
            } catch {
                close(fd)
                throw PrefConnectError.protectionClassFailed(
                    path: tmpURL.path,
                    underlying: String(describing: error))
            }
            // F_FULLFSYNC the data file. Forces bytes from the
            // page cache to the device controller (vs `fsync`
            // which only goes to OS cache on iOS).
            if fcntl(fd, F_FULLFSYNC) == -1 {
                let e = errno
                close(fd)
                throw PrefConnectError.syncFailed(path: tmpURL.path, errno: e)
            }
            close(fd)
        } catch {
            close(fd)
            throw error
        }

        let renameStatus = tmpURL.path.withCString { tmpC in
            fileURL.path.withCString { finalC in
                rename(tmpC, finalC)
            }
        }
        if renameStatus != 0 {
            throw PrefConnectError.renameFailed(
                from: tmpURL.path, to: fileURL.path, errno: errno)
        }

        // F_FULLFSYNC parent directory. The rename updated a
        // directory entry; without this the entry sits in the
        // journal indefinitely. On power loss the new file's data
        // blocks would be orphaned and the parent directory would
        // still point at the OLD inode (or no inode if this was
        // the first write).
        let dirURL = fileURL.deletingLastPathComponent()
        let dirFd = dirURL.path.withCString { open($0, O_RDONLY) }
        if dirFd >= 0 {
            defer { close(dirFd) }
            if fcntl(dirFd, F_FULLFSYNC) == -1 {
                throw PrefConnectError.dirSyncFailed(
                    path: dirURL.path, errno: errno)
            }
        }
    }

    /// Loop on POSIX `write(2)` until every byte is committed or an
    /// I/O error surfaces. Same discipline as `AtomicSlotWriter`.
    private func writeAll(fd: Int32, data: Data, label: String) throws {
        var offset = 0
        let total = data.count
        while offset < total {
            let written = data.withUnsafeBytes {
                (raw: UnsafeRawBufferPointer) -> Int in
                guard let base = raw.baseAddress else { return -1 }
                return Darwin.write(fd, base.advanced(by: offset), total - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                throw PrefConnectError.writeFailed(path: label, errno: errno)
            }
            if written == 0 {
                throw PrefConnectError.writeFailed(path: label, errno: EIO)
            }
            offset += written
        }
    }
}
