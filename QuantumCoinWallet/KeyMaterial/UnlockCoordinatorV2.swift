// UnlockCoordinatorV2.swift (KeyMaterial layer 4)
// End-to-end orchestration for the strongbox unlock, create, and
// persist flows. Composes layers 1, 2, and 3 to produce a typed
// `StrongboxPayload` and install it in `Strongbox.shared`. This is
// the SOLE entry point for password-driven strongbox operations -
// every screen (HomeWallet, Send, Reveal, BackupOptions,
// RestoreFlow, BlockchainNetwork, etc.) routes through the
// public facade here.
// Why this exists:
// The layered architecture confines all crypto + storage
// coordination to a single layer-4 module. Every UI call site
// sees an ergonomic, password-in / Strongbox-out API; the
// primitives (scrypt, AEAD, HKDF, slot writer, padding, MAC)
// stay encapsulated in their respective modules.
// Threading: every public method except `lock` /
// `clearSnapshot` blocks on scrypt and AES-GCM. All callers
// MUST invoke from a background queue (the existing UI
// callers already do via `Task.detached`). The MainActor
// parts (network re-apply, lock-timer reset) are wrapped by
// `unlockWithPasswordAndApplySession(...)` and dispatched on
// the main queue from inside this file.
// Unlock sequence:
// 1. AtomicSlotWriter.cleanupTempFiles
// 2. StrongboxFileCodec.readWinner // selects highest-gen
// valid slot, schedules re-mirror if only one survived.
// Returns nil for first-launch (no slot files yet).
// 3. derivedKey = PasswordKdf.deriveMainKey(password, salt)
// 4. mainKey = Aead.open(passwordWrap, derivedKey)
// -> AEAD failure surfaces as `authenticationFailed`
// (wrong password). NOT `tamperDetected` - the user
// needs the "did I mistype?" outcome.
// 5. macKey = Mac.hkdfExtractAndExpand(mainKey, kdf.salt,
// "integrity-v2", 32)
// 6. StrongboxFileCodec.verifyFileLevelMac(decoded, macKey)
// -> MAC failure surfaces as `tamperDetected` (HARD
// FAIL; user must restore from backup).
// 7. paddedPlaintext = Aead.open(strongbox, mainKey)
// -> AEAD failure surfaces as `tamperDetected` (we
// already passed the file-level MAC, so this means
// the strongbox ciphertext itself was edited - which
// the MAC scope does cover; this is defense-in-depth).
// 8. plaintext = StrongboxPadding.unpad(paddedPlaintext)
// -> reject on missing 0x80 marker.
// 9. payload = JSONDecoder().decode(StrongboxPayload, plaintext)
// 10. Strongbox.verifyChecksum(payload) // post-decrypt
// integrity check; tamperDetected on mismatch.
// 11. Strongbox.shared.installSnapshot(payload)
// The schema previously carried an optional iOS-only
// `wrap.keychainWrap` envelope for a never-shipped biometric
// unlock. The strongbox file now carries `wrap.passwordWrap`
// only and is byte-identical to the Android slot format at the
// wrap layer; the decoder rejects any extraneous `wrap.*`
// keys. If a biometric unlock UI is ever added, it should
// store its per-device wrap-key state in a sibling sidecar
// file (see `KeychainWrapSidecar.swift`) under
// `kSecAttrAccessControl = biometryCurrentSet`, never inside
// the slot envelope.
// Persist sequence:
// 1. plaintext = JSONEncoder().encode(payload, sortedKeys)
// 2. padded = StrongboxPadding.pad(plaintext)
// 3. strongbox = Aead.seal(padded, mainKey)
// 4. macKey = Mac.hkdfExtractAndExpand(mainKey, salt,
// "integrity-v2", 32)
// 5. (passwordWrap is reused; only re-encrypted if salt
// changes - not in this code path)
// 6. StrongboxFileCodec.writeNewGeneration(... currentSlot)
// -> internally computes the file-level MAC and calls
// AtomicSlotWriter.write(toInactive)
// Tradeoffs:
// - Every persist re-encrypts the entire 4 MiB strongbox and
// re-MACs the slot file. Combined with AtomicSlotWriter's
// two F_FULLFSYNC calls, a single user toggle costs < ~50
// ms of synchronous I/O on a modern iPhone. Acceptable
// given the user-driven write rate. The alternative
// (incremental write to a subset of fields) was rejected
// because it would require per-field MACs and a much more
// complex schema.
// - The `mainKey` is held in a stack `Data` for the duration
// of the closure passed to `withMainKey`; on return the
// bytes are zeroed in `defer`. The `String` form of the
// password is residual until ARC reclaims it:
// accepts that residency window because copying the password
// into a Data, dispatching the async unlock, and zeroing
// the Data on return would still leave a String copy in
// UIKit-internal text-field storage that we cannot reach.
// The defense-in-depth that matters is the brute-force
// limiter - it makes a leaked password substring
// useless against a third party because the unlock surface
// is rate-limited even with a perfect plaintext guess.
// - We DO NOT pre-derive the MAC key once and cache it. Each
// persist call re-derives via HKDF. HKDF is ~5 µs per call;
// caching a derived key in long-lived RAM would extend the
// window where compromise of process memory leaks the MAC
// forging key. The derive cost is below the noise floor of
// the AEAD seal it accompanies.

import Foundation
import UIKit

public enum UnlockCoordinatorV2Error: Error, CustomStringConvertible {
    /// Wrong password (passwordWrap AEAD tag mismatch). Counted
    /// against the brute-force lockout.
    case authenticationFailed
    /// File-level MAC mismatch, strongbox AEAD failure, padding
    /// validation failure, or post-decrypt checksum mismatch.
    /// The wallet UI MUST surface this as a dedicated "tamper
    /// detected" state distinct from "wrong password" so the
    /// user does not silently overwrite a tampered strongbox by
    /// re-creating one.
    case tamperDetected(String)
    /// Schema version mismatch on the slot file (e.g. a
    /// future v3 file produced by a newer build read by this
    /// older one). HARD FAIL with an explicit "update the app"
    /// message at the UI layer.
    case schemaVersionMismatch(found: Int)
    /// Catastrophic I/O failure on both slots. Possible causes:
    /// disk full, file system permission failure, hardware
    /// failure. Surface as a separate UI state from
    /// `tamperDetected` because the recovery path differs
    /// (retry vs restore).
    case storageUnavailable(underlying: Error)
    /// Returned when `UnlockAttemptLimiter` says
    /// the user must wait `remainingSeconds` before another
    /// unlock is permitted. UI sites MUST surface this with a
    /// "wait N seconds" message, not the generic wrong-password
    /// warning, so the user knows the dialog isn't broken.
    case tooManyAttempts(remainingSeconds: TimeInterval)
    /// Snapshot is not loaded (called a write helper while the
    /// wallet was relocked). Caller must re-prompt for the
    /// password and call `unlockWithPasswordAndApplySession`
    /// before retrying the write.
    case notUnlocked
    /// Caller asked to add a wallet but the per-strongbox slot
    /// budget is exhausted (`PrefKeys.MAX_WALLETS`).
    case tooManyWallets
    /// Generic decode / shape failure from a downstream layer
    /// that the UI should treat the same way it used to treat
    /// the historical `decodeFailed` case (e.g. an envelope from
    /// the JS bridge whose JSON shape did not match what the
    /// caller expected).
    case decodeFailed

    public var description: String {
        switch self {
            case .authenticationFailed:
            return "UnlockCoordinatorV2: authentication failed (wrong password)"
            case .tamperDetected(let m):
            return "UnlockCoordinatorV2: tamper detected (\(m))"
            case .schemaVersionMismatch(let v):
            return "UnlockCoordinatorV2: schema v=\(v); rebuild app to read"
            case .storageUnavailable(let u):
            return "UnlockCoordinatorV2: storage unavailable (\(u))"
            case .tooManyAttempts(let s):
            return "UnlockCoordinatorV2: too many attempts; wait \(Int(s))s"
            case .notUnlocked:
            return "UnlockCoordinatorV2: snapshot not loaded (relock during write)"
            case .tooManyWallets:
            return "UnlockCoordinatorV2: wallet slot budget exhausted"
            case .decodeFailed:
            return "UnlockCoordinatorV2: decode failed (downstream shape mismatch)"
        }
    }
}

public enum UnlockCoordinatorV2 {

    // MARK: - Mutation serialization (durability fix)
    // ------------------------------------------------------------------
    // What it closes:
    //   Every public mutator below (`createNewStrongbox`,
    //   `createNewStrongboxWithInitialWallet`, `persistSnapshot`,
    //   `appendWallet`, `replaceNetworks`, `setCurrentWallet`,
    //   `setActiveNetwork`,
    //   `setAdvancedSigning`, `setCameraPermissionAskedOnce`,
    //   `setCloudBackupFolderUri`, `lock`) reads the winning
    //   slot, decides the new payload, installs it into
    //   `Strongbox.shared`, and writes the inactive slot. Without
    //   serialization, two concurrent mutators (a "Save Network"
    //   `Task.detached` racing a relock from `SessionLock`, or a
    //   double-tap "Add Wallet" while a previous append is still
    //   in flight) can interleave their three logical steps in
    //   any order, producing:
    //     - A persist that thinks it is bumping generation N+1
    //       but races with another persist that already bumped it;
    //       the second persist's write to the same slot then
    //       silently overwrites the first.
    //     - A relock that runs between install and persist of
    //       another flow, leaving the strongbox cleared and the
    //       persist throwing `notUnlocked`. The user sees a
    //       confusing "snapshot not loaded" error but the on-disk
    //       slot file is unchanged so retrying works — UNLESS the
    //       interleaving was the other way (relock between read-
    //       winner and the subsequent install), in which case the
    //       persist installs the OLDER snapshot over the NEWER one.
    //     - A `setCurrentWallet` racing an `appendWallet` that
    //       reads the snapshot before the append's install lands.
    //       The two persists then write conflicting payloads at
    //       the same generation; the second one wins on disk and
    //       the first append is silently dropped.
    //   This is (compound
    //   mutation race) — corroborated by multiple reviewers.
    // Why this shape (NSRecursiveLock):
    //   Higher-level mutators (`appendWallet`, `replaceNetworks`,
    //   `setCurrentWallet`, etc.) call into `persistSnapshot`.
    //   Both layers acquire `mutationLock`; NSRecursiveLock allows
    //   the SAME thread to re-enter the critical section without
    //   deadlock, which is what we want here. A non-recursive
    //   primitive (NSLock or DispatchQueue.sync) would force
    //   either:
    //     a) A two-tier API (public + locked-internal) that
    //        doubles the surface area for review, OR
    //     b) Hand-rolled "is this thread inside the queue?"
    //        gymnastics with `dispatch_get_specific`.
    //   NSRecursiveLock keeps the public API exactly one entry
    //   per intent and makes the critical section trivially
    //   reviewable: every public mutator opens with `_mutationLock.lock()`
    //   and closes with `defer { _mutationLock.unlock() }`.
    // Tradeoffs:
    //   The mutator pipeline (read winner -> derive -> seal ->
    //   write -> verify -> bump counter) holds the lock for the
    //   full ~300-500 ms scrypt + AEAD + flash-write cost. A
    //   second user tap that reaches a different mutator waits
    //   that long. This is the explicit serialisation the fix
    //   exists to provide; a "drop the lock around the slow
    //   work" optimisation would re-open the race.
    //   Another tradeoff: a relock from `SessionLock` ALSO goes
    //   through this lock so a relock during a persist waits
    //   for the persist to finish. That is correct: relocking
    //   mid-persist would let the persist install the snapshot,
    //   the relock clear it, and then the persist's own install
    //   call (via the higher-level mutator) write the OLD snapshot
    //   back into a freshly-locked Strongbox — defeating the
    //   relock. Waiting briefly is the right behaviour.
    // Cross-references:
    //   - a prior durability gap (compound mutation race) — closed.
    //   - a prior race condition (data race on shared mutable state) —
    //     reinforced by serialising the lock-and-clear path too.
    //   - `SessionLock.applicationDidEnterBackground` and the idle-
    //     timer relock both call into `lock()`, which now hops onto
    //     this lock so they coordinate with in-flight persists.
    // ------------------------------------------------------------------
    nonisolated(unsafe) private static let _mutationLock = NSRecursiveLock()

    /// Closure invoked by the codec when a slot write transitions
    /// between phases. Forwarded from `AtomicSlotWriter.writeAndVerify`
    /// so a UI caller can update a "Verifying..." secondary status
    /// line on the wait dialog without the codec depending on UI
    /// types. The callback is invoked at most once per phase, in
    /// order, on the writer's thread. UI sites MUST hop to MainActor
    /// inside the callback.
    public typealias WriteVerifyPhaseCallback = (AtomicSlotWriter.WriteVerifyPhase) -> Void

    // MARK: - Bootstrap (first launch)

    /// Result of `readSlots`. Returned to the UI before any
    /// password is collected so the launch path can choose
    /// between "show unlock dialog" (file present) and "show
    /// create-wallet flow" (no file).
    public enum BootState {
        /// No slot files exist. First launch on a fresh
        /// install or post-delete-all. UI shows the create-
        /// wallet flow.
        case noStrongbox
        /// Slot file present and structurally valid up to the
        /// pre-MAC trial. UI shows the unlock dialog.
        case strongboxPresent
        /// Both slots are corrupt. UI shows the disaster-
        /// recovery flow ("restore from .wallet backup").
        case tampered(String)
    }

    /// Determine the launch-time state without prompting for a
    /// password. Safe to call from any thread; performs only
    /// I/O and JSON parse, no scrypt.
    public static func bootState() -> BootState {
        do {
            guard try StrongboxFileCodec.readWinner() != nil else {
                return .noStrongbox
            }
            return .strongboxPresent
        } catch StrongboxFileCodec.Error.bothSlotsInvalid {
            return .tampered("both slots invalid")
        } catch {
            return .tampered(String(describing: error))
        }
    }

    // MARK: - Unlock (path 1, password)

    /// Attempt a v2 password unlock. On success, installs the
    /// decrypted `StrongboxPayload` into `Strongbox.shared` and returns
    /// the slot the winning state was read from (so subsequent
    /// `persist` calls can write to the OTHER slot).
    /// MUST be called from a background queue (scrypt is
    /// expensive).
    /// the `UnlockAttemptLimiter` pre-check + `recordFailure` /
    /// `recordSuccess` bookkeeping is owned by THIS function so
    /// every password-bound unlock surface (cold-launch unlock,
    /// re-lock dialog, Reveal, Backup, etc.) is rate-limited
    /// without depending on the call site to remember to wire
    /// the limiter in. The previous design left the bookkeeping
    /// to `unlockWithPasswordAndApplySession`, which the Send
    /// path used to bypass. Centralising here makes
    /// "limiter is engaged" a code-level invariant rather than a
    /// per-call-site contract that future contributors might
    /// forget.
    public static func unlockWithPassword(_ password: String) throws -> AtomicSlotWriter.Slot {
        // Limiter pre-check. Doing this BEFORE the slot-file
        // read AND BEFORE scrypt means a malicious in-process
        // automation harness cannot keep paying CPU cost while
        // in lockout, AND the user gets immediate feedback
        // rather than waiting ~300 ms for scrypt to resolve.
        switch UnlockAttemptLimiter.currentDecision() {
            case .lockedFor(let remaining):
            throw UnlockCoordinatorV2Error.tooManyAttempts(remainingSeconds: remaining)
            case .allowed:
            break
        }

        // the durability fix: read BOTH slots (winner first, runner-up
        // second) so that a corrupt-but-pre-MAC-valid winner
        // can be transparently bypassed for a recoverable older
        // slot. Without this, the user would see
        // `tamperDetected` and lose access even when an older
        // valid slot is sitting on disk one position away.
        // See .
        let candidates: [StrongboxFileCodec.DecodedFile]
        do {
            candidates = try StrongboxFileCodec.readCandidates()
        } catch let e as StrongboxFileCodec.Error {
            switch e {
                case .bothSlotsInvalid:
                throw UnlockCoordinatorV2Error.tamperDetected("both slots invalid")
                case .schemaVersionMismatch(let v):
                throw UnlockCoordinatorV2Error.schemaVersionMismatch(found: v)
                case .malformedJson(let m), .missingField(let m):
                throw UnlockCoordinatorV2Error.tamperDetected("decode: \(m)")
                case .macInvalid:
                throw UnlockCoordinatorV2Error.tamperDetected("mac invalid")
            }
        } catch {
            throw UnlockCoordinatorV2Error.storageUnavailable(underlying: error)
        }
        guard !candidates.isEmpty else {
            // No strongbox yet; caller should branch to the
            // create-wallet flow rather than calling this.
            throw UnlockCoordinatorV2Error.tamperDetected("no slot file present")
        }

        // Try winner first. On `authenticationFailed` (wrong
        // password OR corrupt passwordWrap envelope) AND on
        // `tamperDetected` (MAC mismatch / strongbox AEAD fail
        // / unpad fail / decode fail / checksum fail / rollback)
        // we silently try the runner-up (older slot) before
        // surfacing the failure. Limiter accounting happens at
        // the end after both candidates have been considered.
        var sawAuthFailedOnly = true
        var lastError: UnlockCoordinatorV2Error?
        for (idx, decoded) in candidates.enumerated() {
            do {
                let attempt = try attemptUnlockSingle(
                    decoded: decoded, password: password)
                // SUCCESS — install snapshot, advance counter,
                // record limiter success.
                Strongbox.shared.installSnapshot(attempt.payload)
                do {
                    try KeychainGenerationCounter.bump(to: decoded.generation)
                } catch {
                    Logger.debug(
                        category: "STRONGBOX_ROLLBACK_COUNTER_BUMP_FAIL",
                        "unlock-time bump failed: \(error)")
                }
                UnlockAttemptLimiter.recordSuccess(channel: .strongboxUnlock)
                if idx > 0 {
                    // Older-slot fallback: surface the
                    // single-slot redundancy state so the next
                    // unlock dialog can warn the user to create
                    // a fresh backup. The re-mirror codepath
                    // (the durability fix) will eventually restore the
                    // redundant pair on disk; until then the
                    // banner stays up.
                    StrongboxRedundancyState.shared.markSingleSlot()
                    Logger.warn(category: "STRONGBOX_OLDER_SLOT_FALLBACK",
                        "winner gen=\(candidates[0].generation) failed; recovered from gen=\(decoded.generation)")
                }
                return pickSlotMatching(decoded: decoded)
            } catch UnlockCoordinatorV2Error.authenticationFailed {
                lastError = .authenticationFailed
            } catch let e as UnlockCoordinatorV2Error {
                sawAuthFailedOnly = false
                lastError = e
            }
        }

        // All candidates exhausted.
        if sawAuthFailedOnly {
            // Both candidates returned authenticationFailed —
            // canonical wrong-password signal. Count exactly
            // ONE failure against the limiter even though we
            // tried both candidates; the user only entered one
            // password and we don't want to amplify rate-
            // limiting against the same input.
            UnlockAttemptLimiter.recordFailure(channel: .strongboxUnlock)
            throw UnlockCoordinatorV2Error.authenticationFailed
        }
        // At least one candidate failed with a non-auth failure
        // (MAC, AEAD on strongbox, unpad, decode, checksum,
        // rollback). Treat as tamper; this is NOT counted
        // against the limiter (a corrupt slot is not user-
        // driven and must not be punished).
        if let e = lastError { throw e }
        // Defensive default; unreachable.
        throw UnlockCoordinatorV2Error.tamperDetected("unlock exhausted candidates")
    }

    /// Attempt the full unlock pipeline against a SINGLE decoded
    /// candidate. Returns the decrypted payload on success.
    /// Throws `.authenticationFailed` for wrong-password (or
    /// corrupt passwordWrap envelope), `.tamperDetected` for any
    /// other failure (MAC mismatch / strongbox AEAD / unpad /
    /// decode / checksum / rollback), or `.storageUnavailable` for
    /// scrypt I/O hiccups.
    /// What it closes:
    ///   . Extracting the
    ///   per-candidate attempt out of `unlockWithPassword` makes
    ///   the older-slot fallback a clean loop rather than a deeply
    ///   nested do/catch.
    /// Why this shape (no side effects, no limiter / Strongbox
    /// install):
    ///   The caller decides whether to install the payload,
    ///   advance the counter, and signal the limiter. Keeping this
    ///   helper side-effect-free lets the caller iterate over
    ///   multiple candidates without worrying about partial state.
    private static func attemptUnlockSingle(
        decoded: StrongboxFileCodec.DecodedFile,
        password: String
    ) throws -> (payload: StrongboxPayload, decoded: StrongboxFileCodec.DecodedFile) {
        // Defense-in-depth: the codec already rejects sub-minimum
        // kdf params at decode, but if a future caller ever
        // bypasses `StrongboxFileCodec.decodeOnly` (e.g., a unit
        // test or a migration tool that constructs `DecodedFile`
        // directly) this guard keeps us from running scrypt with
        // weakened cost. Mirrored on Android at
        // `UnlockCoordinator.deriveKeyViaScrypt`.
        let p = decoded.kdfParams
        if p.N < JsBridge.SCRYPT_N || p.r < JsBridge.SCRYPT_R
            || p.p < JsBridge.SCRYPT_P || p.keyLen < JsBridge.SCRYPT_KEY_LEN {
            throw UnlockCoordinatorV2Error.tamperDetected(
                "scrypt parameters below documented minimum (got N=\(p.N),r=\(p.r),p=\(p.p),keyLen=\(p.keyLen))")
        }
        // Step 1: derive scrypt key from password + on-disk salt.
        // design note: scrypt is the brute-force cost ceiling.
        // If an attacker has the slot file in hand they MUST
        // pay scrypt(N=262144, r=8, p=1) per password guess.
        // On modern hardware that is ~300 ms per guess on a
        // single thread; the attacker can pipeline but cannot
        // short-circuit.
        var derivedKey: Data
        do {
            derivedKey = try PasswordKdf.deriveMainKey(
                password: password,
                saltBase64: decoded.kdfSalt.base64EncodedString())
        } catch {
            throw UnlockCoordinatorV2Error.storageUnavailable(underlying: error)
        }
        defer { derivedKey.resetBytes(in: 0..<derivedKey.count) }

        // Step 2: unwrap mainKey from passwordWrap. AEAD failure
        // here is the canonical "wrong password" signal -
        // distinct from the tamperDetected paths below. We do
        // NOT signal the limiter here; the caller decides after
        // exhausting all candidates.
        var mainKey: Data
        do {
            mainKey = try Aead.open(
                decoded.passwordWrap.legacyEnvelopeJson(),
                keyBytes: derivedKey)
        } catch AeadError.authenticationFailed {
            throw UnlockCoordinatorV2Error.authenticationFailed
        } catch {
            throw UnlockCoordinatorV2Error.tamperDetected("passwordWrap aead: \(error)")
        }
        defer { mainKey.resetBytes(in: 0..<mainKey.count) }

        // Step 3: derive the MAC key from mainKey + salt and
        // verify the file-level MAC. On mismatch we hard-fail
        // (the caller can fall back to the older slot).
        let macKey = Mac.hkdfExtractAndExpand(
            inputKeyMaterial: mainKey,
            salt: decoded.kdfSalt,
            info: StrongboxFileCodec.macInfoLabel,
            length: StrongboxFileCodec.macKeyByteCount)
        do {
            try StrongboxFileCodec.verifyFileLevelMac(decoded, macKey: macKey)
        } catch {
            throw UnlockCoordinatorV2Error.tamperDetected("file-level mac: \(error)")
        }

        // Step 4: open the inner strongbox.
        let paddedPlaintext: Data
        do {
            paddedPlaintext = try Aead.open(
                decoded.strongbox.legacyEnvelopeJson(),
                keyBytes: mainKey)
        } catch {
            throw UnlockCoordinatorV2Error.tamperDetected("strongbox aead: \(error)")
        }

        // Step 5: strip fixed-size 4 MiB padding.
        let plaintext: Data
        do {
            plaintext = try StrongboxPadding.unpad(paddedPlaintext)
        } catch {
            throw UnlockCoordinatorV2Error.tamperDetected("padding: \(error)")
        }

        // Step 6: decode the typed payload and verify the
        // inner checksum.
        let payload: StrongboxPayload
        do {
            // Opt-out of URL rewriting on the strongbox decode path
            // so on-disk bytes round-trip without mutation. See
            // `BlockchainNetwork.init(from:)` for the contract.
            let strongboxDecoder = JSONDecoder()
            strongboxDecoder.userInfo[.blockchainNetworkRewriteUrls] = false
            payload = try strongboxDecoder.decode(StrongboxPayload.self, from: plaintext)
        } catch {
            throw UnlockCoordinatorV2Error.tamperDetected("payload decode: \(error)")
        }
        guard Strongbox.verifyChecksum(of: payload, mainKey: mainKey) else {
            throw UnlockCoordinatorV2Error.tamperDetected("payload checksum mismatch")
        }

        // Step 6b: anti-rollback gate. See the original step-6b
        // comment block kept on the caller side for the
        // KeychainGenerationCounter rationale.
        let storedCounter = (try? KeychainGenerationCounter.read())
        if let counter = storedCounter {
            if decoded.generation < counter {
                throw UnlockCoordinatorV2Error.tamperDetected(
                    "rollback: disk_gen=\(decoded.generation) < counter=\(counter)")
            }
        }

        return (payload, decoded)
    }

    // MARK: - Read-only password verification

    /// Validate `password` against the on-disk strongbox WITHOUT
    /// touching the in-memory snapshot, the rollback counter, or
    /// the redundancy state. Used by post-create / post-restore
    /// unlock prompts (e.g. the "Next" pill on the backup screen)
    /// where the snapshot is already loaded but we still need
    /// proof that the user knows the strongbox password before
    /// routing them home or re-encrypting under that password.
    /// What it closes:
    ///   The "wrong password silently accepted" bug in the
    ///   onboarding-flow unlock dialog. The historical
    ///   `bootstrapOrUnlock` helper short-circuited with
    ///   `if Strongbox.shared.isSnapshotLoaded { return }`, so any
    ///   password the user typed AFTER the first-launch save was
    ///   reported as correct without ever AEAD-opening
    ///   `passwordWrap`. A user could finish onboarding with
    ///   PWD-A, tap Next on the backup screen, type PWD-B, and
    ///   be routed home — only to discover at the next cold
    ///   launch that PWD-B does not unlock the wallet (because
    ///   the on-disk seal is still under PWD-A) and PWD-A is the
    ///   one they think is wrong. `verifyPassword` is the
    ///   primitive every "validate-only" caller now goes through.
    /// Why this shape (read-only, side-effect-free):
    ///   `unlockWithPassword` is the right call when the snapshot
    ///   is NOT loaded — it installs the snapshot, bumps the
    ///   counter, and applies the session. None of that is safe
    ///   when the snapshot is ALREADY loaded with the user's
    ///   live wallet: re-installing would replay the snapshot
    ///   over itself (benign but wasteful), bumping the counter
    ///   against the disk generation could trigger spurious
    ///   anti-rollback rejections on later persists, and applying
    ///   the session would re-emit `networkConfigDidChange`
    ///   notifications that UI listeners would treat as a
    ///   network switch. `verifyPassword` does the ONE thing the
    ///   caller actually needs: prove the password unwraps
    ///   `passwordWrap`, then return. Limiter bookkeeping IS
    ///   performed because this is a brute-force surface
    ///   identical to the unlock dialog (a malicious caller
    ///   inside the app could otherwise loop on it without ever
    ///   tripping the lockout).
    /// Tradeoffs:
    ///   Pays one scrypt (~300 ms on modern iPhones) per
    ///   verification call. Acceptable — the only callers are
    ///   user-tappable confirm buttons. Caller MUST be on a
    ///   background queue.
    /// Cross-references:
    ///   - `unlockWithPassword` for the fully-loaded counterpart
    ///     used when no snapshot is in memory yet.
    ///   - `HomeWalletViewController.bootstrapOrUnlock` and
    ///     `RestoreFlow.bootstrapOrUnlock` for the call sites that
    ///     route through this method when the snapshot is loaded.
    ///   - `UnlockAttemptLimiter` for the shared brute-force
    ///     limiter (channel `.strongboxUnlock`).
    public static func verifyPassword(_ password: String) throws {
        // Mutation-lock around the whole pipeline so a concurrent
        // mutator (e.g. an idle-timer relock running through
        // `lock()`) cannot interleave between the readWinner +
        // AEAD-open. NSRecursiveLock so a caller that already
        // holds the lock (e.g. a future composite mutator) does
        // not deadlock on re-entry.
        _mutationLock.lock()
        defer { _mutationLock.unlock() }

        // Limiter pre-check, mirroring `unlockWithPassword` and
        // `persistSnapshot`. Doing this BEFORE the slot read +
        // scrypt means a locked-out caller fails fast rather
        // than burning ~300 ms per try.
        switch UnlockAttemptLimiter.currentDecision() {
            case .lockedFor(let remaining):
            throw UnlockCoordinatorV2Error.tooManyAttempts(remainingSeconds: remaining)
            case .allowed:
            break
        }

        let decoded: StrongboxFileCodec.DecodedFile
        do {
            guard let d = try StrongboxFileCodec.readWinner() else {
                // No slot file present. The expected callers
                // always run AFTER a successful create (so a
                // slot file MUST exist) — surfacing this as
                // tamperDetected is correct because it means
                // someone removed the file out from under us.
                throw UnlockCoordinatorV2Error.tamperDetected("verifyPassword: no slot file")
            }
            decoded = d
        } catch let e as UnlockCoordinatorV2Error {
            throw e
        } catch let e as StrongboxFileCodec.Error {
            switch e {
                case .bothSlotsInvalid:
                throw UnlockCoordinatorV2Error.tamperDetected("verifyPassword: both slots invalid")
                case .schemaVersionMismatch(let v):
                throw UnlockCoordinatorV2Error.schemaVersionMismatch(found: v)
                case .malformedJson(let m), .missingField(let m):
                throw UnlockCoordinatorV2Error.tamperDetected("verifyPassword decode: \(m)")
                case .macInvalid:
                throw UnlockCoordinatorV2Error.tamperDetected("verifyPassword mac invalid")
            }
        } catch {
            throw UnlockCoordinatorV2Error.storageUnavailable(underlying: error)
        }

        var derivedKey: Data
        do {
            derivedKey = try PasswordKdf.deriveMainKey(
                password: password,
                saltBase64: decoded.kdfSalt.base64EncodedString())
        } catch {
            throw UnlockCoordinatorV2Error.storageUnavailable(underlying: error)
        }
        defer { derivedKey.resetBytes(in: 0..<derivedKey.count) }

        do {
            // AEAD-open then immediately wipe. We do NOT use
            // `mainKey` for anything here — verification is the
            // entire purpose of this method.
            var mainKey = try Aead.open(
                decoded.passwordWrap.legacyEnvelopeJson(),
                keyBytes: derivedKey)
            mainKey.resetBytes(in: 0..<mainKey.count)
        } catch AeadError.authenticationFailed {
            // Wrong password — limiter increments mirror the
            // unlock dialog so an attacker that finds this
            // surface cannot bypass the rate limit by switching
            // entry points.
            UnlockAttemptLimiter.recordFailure(channel: .strongboxUnlock)
            throw UnlockCoordinatorV2Error.authenticationFailed
        } catch {
            // Any other AEAD failure (corrupt envelope, etc.)
            // is tamper, not auth failure — same mapping as
            // `attemptUnlockSingle`'s passwordWrap branch.
            throw UnlockCoordinatorV2Error.tamperDetected(
                "verifyPassword passwordWrap: \(error)")
        }

        // Confirmed-correct password — reset the limiter as the
        // unlock dialog does. This means a successful verify on
        // the backup screen also clears any prior failed
        // attempts from the same session.
        UnlockAttemptLimiter.recordSuccess(channel: .strongboxUnlock)
    }

    // MARK: - First-time strongbox creation

    /// Create a brand-new v2 strongbox. Generates a fresh 16-byte
    /// salt, a fresh 32-byte mainKey, wraps mainKey under the
    /// scrypt-derived key from `password`, builds an empty
    /// `StrongboxPayload`, and writes both slots so the next read
    /// has redundancy from the start.
    /// MUST be called from a background queue.
    /// the residual-slot guard at the top is defense-in-depth. The
    /// canonical caller (`bootstrapOrUnlock`) only invokes this
    /// helper after `bootState() == .noStrongbox`, so the guard
    /// is defense-in-depth for a future caller that might skip
    /// the bootState check (e.g. a "factory reset" UI flow that
    /// forgets to delete the slot files first). Without the
    /// guard, calling `createNewStrongbox` against an existing
    /// wallet would silently destroy the recoverable data: the
    /// fresh write to slot A would shadow the previous slot
    /// (higher generation, different MAC key), the user would
    /// lose access to their previous funds, and there would be
    /// no error to surface. The guard makes that mistake a
    /// loud `tamperDetected` instead of a silent loss.
    /// `onPhase`: optional callback invoked by the codec / writer
    /// at each phase transition (writing -> verifying -> promoting
    /// -> committed). The same callback is invoked by BOTH slot
    /// writes (slot B at gen 1, then slot A at gen 1); the UI
    /// caller should treat repeated `.verifying`s as "still
    /// verifying" rather than "double-verifying". See
    /// `WriteVerifyPhaseCallback` for the threading contract.
    public static func createNewStrongbox(password: String,
        onPhase: WriteVerifyPhaseCallback? = nil) throws {
        // the durability fix mutation serialisation entry point. See the
        // `_mutationLock` static-property comment for the full
        // rationale; the lock holds across the entire residual
        // slot guard + key derivation + sealing + slot writes +
        // counter bump + install pipeline so a concurrent mutator
        // (e.g. SessionLock relock or a double-tap "Add Wallet")
        // cannot race this initial bootstrap.
        _mutationLock.lock()
        defer { _mutationLock.unlock() }
        // Defense-in-depth residual-slot guard.
        // We re-run the readWinner trial here even though the
        // canonical caller already did it via `bootState()`;
        // a future contributor who adds a new caller to this
        // function MUST get a loud failure rather than a
        // silent strongbox overwrite. The check uses the
        // codec's `readWinner()` (returns nil only when both
        // slots are absent), which is the same semantics as
        // `bootState()`.
        do {
            if try StrongboxFileCodec.readWinner() != nil {
                throw UnlockCoordinatorV2Error.tamperDetected(
                    "createNewStrongbox: refusing to overwrite existing slot files")
            }
        } catch StrongboxFileCodec.Error.bothSlotsInvalid {
            // Both slots present but invalid. We DO NOT silently
            // overwrite either - the user should go through the
            // explicit disaster-recovery flow ("restore from
            // .wallet backup") rather than have this call drop
            // their potentially-recoverable encrypted state.
            throw UnlockCoordinatorV2Error.tamperDetected(
                "createNewStrongbox: both slots invalid; refuse to overwrite")
        } catch let e as UnlockCoordinatorV2Error {
            throw e
        } catch {
            // Any other read failure (storage permission, disk
            // I/O) is also a "do not overwrite" signal - we
            // cannot prove the disk is empty.
            throw UnlockCoordinatorV2Error.storageUnavailable(underlying: error)
        }

        // Step 1: generate fresh salt + mainKey via SecureRandom
        // (throwing wrapper; never silently zero). v=3 uses a
        // 32-byte scrypt salt for cross-platform parity with
        // Android (whose generator has always emitted 32 bytes).
        // No KDF cost change; just more salt entropy.
        var salt: Data
        var mainKey: Data
        do {
            salt = try SecureRandom.bytes(32)
            mainKey = try SecureRandom.bytes(32)
        } catch {
            throw UnlockCoordinatorV2Error.storageUnavailable(underlying: error)
        }
        defer { mainKey.resetBytes(in: 0..<mainKey.count) }

        // Step 2: derive scrypt key, wrap mainKey under it.
        var derivedKey: Data
        do {
            derivedKey = try PasswordKdf.deriveMainKey(
                password: password,
                saltBase64: salt.base64EncodedString())
        } catch {
            throw UnlockCoordinatorV2Error.storageUnavailable(underlying: error)
        }
        defer { derivedKey.resetBytes(in: 0..<derivedKey.count) }

        let passwordWrapEnv: StrongboxFileCodec.AeadEnvelope
        do {
            passwordWrapEnv = try sealToEnvelope(mainKey, key: derivedKey)
        } catch {
            throw UnlockCoordinatorV2Error.storageUnavailable(underlying: error)
        }

        // Step 3: build empty payload; stamp keyed checksum;
        // pad to bucket; AEAD-seal under mainKey.
        let payload = Strongbox.stampChecksum(
            of: Strongbox.emptySnapshot(), mainKey: mainKey)
        let payloadBytes: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            payloadBytes = try encoder.encode(payload)
        } catch {
            throw UnlockCoordinatorV2Error.storageUnavailable(underlying: error)
        }
        let paddedBytes: Data
        do {
            paddedBytes = try StrongboxPadding.pad(payloadBytes)
        } catch {
            throw UnlockCoordinatorV2Error.storageUnavailable(underlying: error)
        }
        let strongboxEnv: StrongboxFileCodec.AeadEnvelope
        do {
            strongboxEnv = try sealToEnvelope(paddedBytes, key: mainKey)
        } catch {
            throw UnlockCoordinatorV2Error.storageUnavailable(underlying: error)
        }

        // Step 4: derive MAC key.
        let macKey = Mac.hkdfExtractAndExpand(
            inputKeyMaterial: mainKey,
            salt: salt,
            info: StrongboxFileCodec.macInfoLabel,
            length: StrongboxFileCodec.macKeyByteCount)

        let kdfParams = StrongboxFileCodec.KdfParams(
            N: JsBridge.SCRYPT_N,
            r: JsBridge.SCRYPT_R,
            p: JsBridge.SCRYPT_P,
            keyLen: JsBridge.SCRYPT_KEY_LEN)

        // Step 4a (the durability fix): reset+bump the anti-rollback counter
        // BEFORE the slot writes happen. The previous ordering
        // wrote both slots first and bumped the counter after; a
        // force-kill / OS reboot between the slot writes and the
        // counter bump would leave the user with a fresh wallet
        // on disk plus a stale residual counter from a previous
        // (now-deleted) wallet on this device — and the unlock-
        // time rollback gate (`disk_gen=1 < counter=N`) would
        // trigger a false `tamperDetected` and lock the user out
        // of a wallet they just created. Reordering the counter
        // bump to happen FIRST means a force-kill in this window
        // leaves "counter set to 1, no slot files yet" which
        // re-enters the create flow on the next launch — and
        // `bumpFresh(to: 1)` is idempotent so the re-attempt is
        // a no-op on the counter side. Closes the durability gap.
// `bumpFresh` is delete-then-add as a single Keychain
        // transaction — see `KeychainGenerationCounter.bumpFresh`
        // for why this replaces the historical `reset() + bump`
        // pair (the split version was a do/catch that swallowed
        // a `reset()` throw and skipped the bump silently;
        // `bumpFresh` collapses both into one transactional call
        // whose only failure mode the caller has to handle).
        // Closes the durability gap.
        do {
            try KeychainGenerationCounter.bumpFresh(to: 1)
        } catch {
            // The counter is the brick line. We MUST surface a
            // bumpFresh failure rather than silently continuing
            // and then writing slot files at generation 1 that
            // cannot survive their next unlock.
            throw UnlockCoordinatorV2Error.storageUnavailable(underlying: error)
        }

        do {
            // Write to .B (so currentSlot = .A means "next write
            // goes to .B"). For the very first write we call
            // with currentSlot = .B so writeNewGeneration writes
            // to .A; that establishes A as generation 1.
            // mainKey + payload threaded into the codec so the
            // deep-verify closure can AEAD-open the just-sealed
            // strongbox envelope and byte-compare the round-trip
            // before letting the rename promote the slot. See the
            // codec's writeNewGeneration docstring for the eight-
            // step verify rationale.
            try StrongboxFileCodec.writeNewGeneration(
                generation: 1,
                kdfSalt: salt,
                kdfParams: kdfParams,
                passwordWrap: passwordWrapEnv,
                strongbox: strongboxEnv,
                macKey: macKey,
                mainKey: mainKey,
                expectedPayload: payload,
                uiBlock: [:],
                currentSlot: .B,
                onPhase: onPhase)
            // Mirror to slot B at generation 0 so a power-cut
            // before the next write still leaves us with a
            // valid (older but consistent) state to fall back
            // on. Actually we re-write generation 1 to B too,
            // so both slots start at the same generation; the
            // tie-breaker rule (>= picks A) gives a stable
            // winner.
            try StrongboxFileCodec.writeNewGeneration(
                generation: 1,
                kdfSalt: salt,
                kdfParams: kdfParams,
                passwordWrap: passwordWrapEnv,
                strongbox: strongboxEnv,
                macKey: macKey,
                mainKey: mainKey,
                expectedPayload: payload,
                uiBlock: [:],
                currentSlot: .A,
                onPhase: onPhase)
        } catch {
            throw UnlockCoordinatorV2Error.storageUnavailable(underlying: error)
        }

        // Step 5: install the empty snapshot so the UI sees a
        // freshly-unlocked wallet.
        Strongbox.shared.installSnapshot(payload)

        // Stamp the SessionLock "last unlocked at" clock so
        // `applicationDidBecomeActive` does not treat a mid-
        // onboarding background return as a >grace-window elapsed
        // event (the sentinel `0` would compute an effectively
        // infinite elapsed and force-relock on every foreground
        // resume between create and first wallet append).
        // Dispatched on the main queue to match the convention used
        // by `unlockWithPasswordAndApplySession` and because
        // SessionLock's internal mutations expect the main thread.
        DispatchQueue.main.async {
            SessionLock.shared.markUnlockedNow()
        }
    }

    // MARK: - First-time strongbox creation with initial wallet

    /// Combined first-launch bootstrap: creates a brand-new strongbox
    /// with `initialWallet` already inside the payload. Equivalent to
    /// `createNewStrongbox` + `appendWallet` but cheaper (one scrypt,
    /// one AEAD seal, two slot writes instead of four) AND atomic —
    /// the post-create in-memory + on-disk state never goes through
    /// an "empty-wallet" intermediate that a power-cut between the
    /// two calls would freeze in place.
    /// What it closes:
    ///   — the failure mode
    ///   where a fresh-install power-cut between `createNewStrongbox`
    ///   and `appendWallet` left the user with a strongbox they had
    ///   typed a password for, but no wallets in it.
    /// Why this shape:
    ///   We bake the first wallet directly into the initial
    ///   `StrongboxPayload` rather than installing an empty snapshot
    ///   first. Both slot writes commit a payload that already holds
    ///   the user's first wallet, so a power-cut at any point
    ///   between gen-1 slot A write and gen-1 slot B write leaves
    ///   either:
    ///     (a) no slot files (next launch shows new-wallet flow,
    ///         user re-enters seed they had backed up),
    ///     (b) one slot file with the wallet present (next launch
    ///         unlocks normally, deep-verify confirms integrity).
    ///   Both are recoverable; the historical "empty wallet
    ///   intermediate" is not.
    /// Tradeoffs:
    ///   The caller must derive the raw signing-key bytes (via
    ///   `JsBridge.walletFromPhrase` or `walletFromKeys`) BEFORE
    ///   this call, since we take a fully-formed
    ///   `StrongboxPayload.Wallet`. The alternative (do the JS
    ///   bridge derivation inside this function) would couple
    ///   layer 4 to the JS bridge, which we deliberately avoid.
    /// Cross-references:
    ///   - `Strongbox.snapshotWithInitialWallet` for the snapshot
    ///     builder we hand to the codec.
    ///   - .
    ///   - `createNewStrongbox(password:)` for the empty-wallet
    ///     variant retained for tests and the (now legacy) code
    ///     paths that create an empty strongbox first.
    public static func createNewStrongboxWithInitialWallet(
        password: String,
        initialWallet: StrongboxPayload.Wallet,
        onPhase: WriteVerifyPhaseCallback? = nil) throws {
        // Mutation serialisation - same lock as createNewStrongbox.
        _mutationLock.lock()
        defer { _mutationLock.unlock() }
        // Defense-in-depth residual-slot guard - same as
        // createNewStrongbox.
        do {
            if try StrongboxFileCodec.readWinner() != nil {
                throw UnlockCoordinatorV2Error.tamperDetected(
                    "createNewStrongboxWithInitialWallet: refusing to overwrite existing slot files")
            }
        } catch StrongboxFileCodec.Error.bothSlotsInvalid {
            throw UnlockCoordinatorV2Error.tamperDetected(
                "createNewStrongboxWithInitialWallet: both slots invalid; refuse to overwrite")
        } catch let e as UnlockCoordinatorV2Error {
            throw e
        } catch {
            throw UnlockCoordinatorV2Error.storageUnavailable(underlying: error)
        }

        // v=3: 32-byte scrypt salt for byte-equivalent parity
        // with Android's generator. Same KDF cost.
        var salt: Data
        var mainKey: Data
        do {
            salt = try SecureRandom.bytes(32)
            mainKey = try SecureRandom.bytes(32)
        } catch {
            throw UnlockCoordinatorV2Error.storageUnavailable(underlying: error)
        }
        defer { mainKey.resetBytes(in: 0..<mainKey.count) }

        var derivedKey: Data
        do {
            derivedKey = try PasswordKdf.deriveMainKey(
                password: password,
                saltBase64: salt.base64EncodedString())
        } catch {
            throw UnlockCoordinatorV2Error.storageUnavailable(underlying: error)
        }
        defer { derivedKey.resetBytes(in: 0..<derivedKey.count) }

        let passwordWrapEnv: StrongboxFileCodec.AeadEnvelope
        do {
            passwordWrapEnv = try sealToEnvelope(mainKey, key: derivedKey)
        } catch {
            throw UnlockCoordinatorV2Error.storageUnavailable(underlying: error)
        }

        // Build the payload with the initial wallet already inside,
        // then stamp the v=3 keyed-HMAC checksum.
        // Closes the durability gap: a power cut between the historical
        // createNewStrongbox + appendWallet pair could leave an
        // empty-wallet intermediate that the user trusted as
        // "wallet saved".
        let payload = Strongbox.stampChecksum(
            of: Strongbox.snapshotWithInitialWallet(initialWallet),
            mainKey: mainKey)
        let payloadBytes: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            payloadBytes = try encoder.encode(payload)
        } catch {
            throw UnlockCoordinatorV2Error.storageUnavailable(underlying: error)
        }
        let paddedBytes: Data
        do {
            paddedBytes = try StrongboxPadding.pad(payloadBytes)
        } catch {
            throw UnlockCoordinatorV2Error.storageUnavailable(underlying: error)
        }
        let strongboxEnv: StrongboxFileCodec.AeadEnvelope
        do {
            strongboxEnv = try sealToEnvelope(paddedBytes, key: mainKey)
        } catch {
            throw UnlockCoordinatorV2Error.storageUnavailable(underlying: error)
        }

        let macKey = Mac.hkdfExtractAndExpand(
            inputKeyMaterial: mainKey,
            salt: salt,
            info: StrongboxFileCodec.macInfoLabel,
            length: StrongboxFileCodec.macKeyByteCount)

        let kdfParams = StrongboxFileCodec.KdfParams(
            N: JsBridge.SCRYPT_N,
            r: JsBridge.SCRYPT_R,
            p: JsBridge.SCRYPT_P,
            keyLen: JsBridge.SCRYPT_KEY_LEN)

        // Counter-before-slots ordering (the durability fix). The bumpFresh
        // resets any residual stale counter from a prior install
        // before the slot writes happen, so a force-kill between the
        // counter set and the slot writes leaves us with "counter
        // set to 1, no slot files yet" — strictly better than
        // today's "slots exist but counter says they're rolled back"
        // (which would brick the wallet on next unlock).
        do {
            try KeychainGenerationCounter.bumpFresh(to: 1)
        } catch {
            Logger.warn(category: "STRONGBOX_ROLLBACK_COUNTER_BUMP_FAIL",
                "create-with-wallet bumpFresh failed: \(error)")
        }

        do {
            try StrongboxFileCodec.writeNewGeneration(
                generation: 1,
                kdfSalt: salt,
                kdfParams: kdfParams,
                passwordWrap: passwordWrapEnv,
                strongbox: strongboxEnv,
                macKey: macKey,
                mainKey: mainKey,
                expectedPayload: payload,
                uiBlock: [:],
                currentSlot: .B,
                onPhase: onPhase)
            try StrongboxFileCodec.writeNewGeneration(
                generation: 1,
                kdfSalt: salt,
                kdfParams: kdfParams,
                passwordWrap: passwordWrapEnv,
                strongbox: strongboxEnv,
                macKey: macKey,
                mainKey: mainKey,
                expectedPayload: payload,
                uiBlock: [:],
                currentSlot: .A,
                onPhase: onPhase)
        } catch {
            throw UnlockCoordinatorV2Error.storageUnavailable(underlying: error)
        }

        Strongbox.shared.installSnapshot(payload)

        // Stamp the SessionLock "last unlocked at" clock for the
        // same reason as `createNewStrongbox` — the atomic
        // bootstrap+wallet path lands the user on the post-create
        // wizard with a loaded snapshot, and without this stamp the
        // sentinel `0` would make every subsequent
        // `applicationDidBecomeActive` compute an effectively
        // infinite elapsed window and force-relock the user.
        DispatchQueue.main.async {
            SessionLock.shared.markUnlockedNow()
        }
    }

    // MARK: - Persist (any post-unlock mutation)

    /// Persist a new `StrongboxPayload` to the inactive slot,
    /// bumping the generation counter. Caller MUST have
    /// already installed the new snapshot in `Strongbox.shared`
    /// (so any concurrent reader sees the new state immediately
    /// while the slow I/O is in flight).
    /// MUST be called from a background queue.
    /// `password` is required because the layer-4 contract is
    /// "every write re-derives the mainKey from the password
    /// and zeros it on return" - a long-lived cache of mainKey
    /// would extend the in-RAM exposure window for compromise.
    /// The cost is the per-write scrypt (~300 ms); user-driven
    /// writes are rare enough that the UX is unaffected.
    /// Layer 4 alternative: a future PR could add a short-
    /// lived (1-2 second) mainKey cache so a burst of writes
    /// (e.g. add wallet + set as current + record in network
    /// list) only pays scrypt once. For now we accept the
    /// straightforward-and-safe single-derivation cost.
    /// the `UnlockAttemptLimiter` pre-check + `recordFailure` /
    /// `recordSuccess` bookkeeping is owned by THIS function so
    /// every password-bound write surface (Network add / switch,
    /// Wallets append, settings toggles, backup-folder picker,
    /// camera-permission flag) is rate-limited without depending
    /// on the call site to remember to wire the limiter in. The
    /// previous design left the bookkeeping to call sites,
    /// which the Network add / switch flows did not perform.
    /// Centralising here makes "limiter is
    /// engaged" a code-level invariant rather than a per-call-
    /// site contract that future contributors might forget.
    /// `onPhase`: optional callback forwarded to the codec /
    /// writer at each phase transition. UI sites that present a
    /// `WaitDialogViewController` use this to update the
    /// "Verifying..." secondary status line during the
    /// integrity-check window between F_FULLFSYNC and rename.
    /// See `WriteVerifyPhaseCallback` for the threading contract.
    public static func persistSnapshot(_ payload: StrongboxPayload,
        password: String,
        onPhase: WriteVerifyPhaseCallback? = nil) throws {
        // the durability fix mutation serialisation entry point. See the
        // `_mutationLock` static-property comment for the full
        // rationale. NSRecursiveLock so that the wallet/network/
        // setFlag higher-level mutators (which already take the
        // lock) can re-enter persistSnapshot without deadlock.
        _mutationLock.lock()
        defer { _mutationLock.unlock() }
        // Limiter pre-check before paying scrypt cost. Mirrors
        // `unlockWithPassword`'s pre-check rationale - even
        // though `persistSnapshot` is reached only post-snapshot-
        // load (so the strongbox unlock already paid scrypt
        // recently), the persist path re-derives the mainKey
        // from the user-typed password every call and therefore
        // is its own brute-force surface for any UI that
        // collects the password.
        switch UnlockAttemptLimiter.currentDecision() {
            case .lockedFor(let remaining):
            throw UnlockCoordinatorV2Error.tooManyAttempts(remainingSeconds: remaining)
            case .allowed:
            break
        }

        let decoded: StrongboxFileCodec.DecodedFile
        do {
            guard let d = try StrongboxFileCodec.readWinner() else {
                throw UnlockCoordinatorV2Error.tamperDetected("persist: no slot file present")
            }
            decoded = d
        } catch {
            throw UnlockCoordinatorV2Error.storageUnavailable(underlying: error)
        }

        var derivedKey: Data
        do {
            derivedKey = try PasswordKdf.deriveMainKey(
                password: password,
                saltBase64: decoded.kdfSalt.base64EncodedString())
        } catch {
            throw UnlockCoordinatorV2Error.storageUnavailable(underlying: error)
        }
        defer { derivedKey.resetBytes(in: 0..<derivedKey.count) }

        var mainKey: Data
        do {
            mainKey = try Aead.open(
                decoded.passwordWrap.legacyEnvelopeJson(),
                keyBytes: derivedKey)
        } catch AeadError.authenticationFailed {
            // Wrong password on a persist call: same
            // brute-force counter as the unlock dialog. Storage
            // / corruption failures are not user-driven and
            // must not be punished (the user could be trying
            // to recover from a tampered file with the password
            // they actually know).
            UnlockAttemptLimiter.recordFailure(channel: .strongboxUnlock)
            throw UnlockCoordinatorV2Error.authenticationFailed
        } catch {
            throw UnlockCoordinatorV2Error.tamperDetected("persist passwordWrap: \(error)")
        }
        defer { mainKey.resetBytes(in: 0..<mainKey.count) }

        // Stamp the keyed inner-payload checksum (HMAC-SHA-256
        // under HKDF(mainKey, salt=nil, "strongbox-payload-
        // checksum-v3", 32)). Replaces any placeholder set by
        // the snapshot builder. Encoding for AEAD seal happens
        // immediately after so the checksum and the byte-
        // sequence the verifier sees are derived from the same
        // canonical payload bytes.
        let stamped = Strongbox.stampChecksum(of: payload, mainKey: mainKey)

        // Encode + pad + seal new strongbox.
        let plaintext: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            plaintext = try encoder.encode(stamped)
        } catch {
            throw UnlockCoordinatorV2Error.storageUnavailable(underlying: error)
        }
        let padded: Data
        do {
            padded = try StrongboxPadding.pad(plaintext)
        } catch {
            throw UnlockCoordinatorV2Error.storageUnavailable(underlying: error)
        }
        let newStrongboxEnv: StrongboxFileCodec.AeadEnvelope
        do {
            newStrongboxEnv = try sealToEnvelope(padded, key: mainKey)
        } catch {
            throw UnlockCoordinatorV2Error.storageUnavailable(underlying: error)
        }

        let macKey = Mac.hkdfExtractAndExpand(
            inputKeyMaterial: mainKey,
            salt: decoded.kdfSalt,
            info: StrongboxFileCodec.macInfoLabel,
            length: StrongboxFileCodec.macKeyByteCount)

        let newGeneration = decoded.generation + 1
        do {
            // mainKey + payload threaded into the codec so the
            // deep-verify closure can re-decrypt + byte-compare
            // the just-written slot before promoting it. See the
            // codec's writeNewGeneration docstring for the eight-
            // step verify rationale.
            try StrongboxFileCodec.writeNewGeneration(
                generation: newGeneration,
                kdfSalt: decoded.kdfSalt,
                kdfParams: decoded.kdfParams,
                passwordWrap: decoded.passwordWrap,
                // Always write nil. The on-disk field is
                // retained as Optional for forward
                // read-compat with old slot files, but new
                // writes never re-emit a per-device wrap. See
                // the file header step-12 deletion comment.
                strongbox: newStrongboxEnv,
                macKey: macKey,
                mainKey: mainKey,
                expectedPayload: stamped,
                uiBlock: [:],
                currentSlot: pickSlotMatching(decoded: decoded),
                onPhase: onPhase)
        } catch {
            throw UnlockCoordinatorV2Error.storageUnavailable(underlying: error)
        }

        // Bump the anti-rollback counter AFTER the slot's
        // atomic rename + F_FULLFSYNC succeeds. This ordering
        // is critical for power-loss safety: a crash between
        // the disk write and the counter bump leaves
        // `disk_gen > counter`, which is benign (the next
        // unlock just bumps the counter forward). The
        // opposite ordering (bump first, then write) would
        // leave `disk_gen < counter` after a crash and would
        // trigger a false rollback rejection on the next
        // unlock, bricking the wallet for a legitimate user.
        // See `KeychainGenerationCounter` for the full
        // rationale.
        do {
            try KeychainGenerationCounter.bump(to: newGeneration)
        } catch {
            // Best-effort: a Keychain hiccup must not poison
            // the persist (the on-disk write already
            // committed). The counter is one-way monotonic;
            // a missed bump just narrows the rollback window
            // for one generation. The next persist will
            // re-bump.
            Logger.debug(category: "STRONGBOX_ROLLBACK_COUNTER_BUMP_FAIL",
                "persist-time bump failed: \(error)")
        }

        // Limiter reset on confirmed-correct password. Done
        // at the very end so a write failure between AEAD
        // success and here is treated as storageUnavailable
        // (which does not reset the counter) rather than a
        // successful persist.
        UnlockAttemptLimiter.recordSuccess(channel: .strongboxUnlock)
    }

    // MARK: - Lock

    /// Drop the in-memory snapshot AND the bundled-MAINNET reset on
    /// the network manager so a future read while locked sees the
    /// same shape it would on a cold launch (no custom networks
    /// visible). Idempotent. Safe to call from any thread; the
    /// network-manager hop is explicitly main-actor confined.
    /// `lock` is the canonical name; `clearSnapshot` is kept
    /// as an alias so historical call sites that imported the
    /// "clear" verb continue to compile.
    public static func lock() {
        // route the lock through `_mutationLock` so a
        // SessionLock relock running concurrently with an in-flight
        // persist waits for the persist to finish rather than racing
        // it. Without this, the relock could clear the snapshot
        // between the persist's `installSnapshot(payload)` and the
        // `persistSnapshot` call (or between `persistSnapshot`'s
        // read-winner and write), leaving the user with a
        // freshly-locked Strongbox plus a slot file that already
        // committed a payload they thought was relocked. See
        // .
        _mutationLock.lock()
        defer { _mutationLock.unlock() }
        Strongbox.shared.clearSnapshot()
        DispatchQueue.main.async {
            BlockchainNetworkManager.shared.resetToBundled()
        }
    }

    /// Alias retained for symmetry with the historical KeyStore
    /// `clearMetadata` API.
    public static func clearSnapshot() {
        lock()
    }

    // MARK: - Caller-friendly facade (replaces the legacy KeyStore)

    /// Wraps `unlockWithPassword(_:)` with the SessionLock
    /// timestamping and BlockchainNetwork re-apply that every UI
    /// unlock site needs.
    /// the brute-force `UnlockAttemptLimiter` bookkeeping
    /// (pre-check, recordFailure on auth failure, recordSuccess
    /// on success) is owned by `unlockWithPassword` itself - see
    /// the rationale on that function. This wrapper does NOT
    /// repeat that work; doing so would double-count failures
    /// and mask the centralised invariant.
    /// Storage / I/O failures are NOT counted against the
    /// limiter (a corrupt slot file isn't user-driven); the
    /// inner `unlockWithPassword` already enforces this.
    /// MUST be called from a background queue (scrypt is
    /// expensive). Returns the slot the winning state was read
    /// from so the next persist can target the OTHER slot.
    @discardableResult
    public static func unlockWithPasswordAndApplySession(_ password: String) throws -> AtomicSlotWriter.Slot {
        let slot = try unlockWithPassword(password)

        // SessionLock + network re-apply. Dispatch onto the
        // main actor because the network manager mutates UI-
        // observable state and posts a `networkConfigDidChange`
        // notification that screens listen to on the main queue.
        let networksSnapshot = Strongbox.shared.customNetworks
        let activeIndexSnapshot = Strongbox.shared.activeNetworkIndex
        DispatchQueue.main.async {
            SessionLock.shared.markUnlockedNow()
            BlockchainNetworkManager.shared.applyDecryptedConfig(
                customNetworks: networksSnapshot,
                activeIndex: activeIndexSnapshot)
        }
        return slot
    }

    // MARK: - Rate-limited sensitive operation wrapper

    /// Wrap a password-bound operation that is NOT the strongbox
    /// unlock or persist (which are self-limited) but that uses
    /// the same user password through a different scrypt+AEAD
    /// path (e.g. cloud `.wallet` import in `RestoreFlow`, where
    /// the file's per-export envelope is sealed under a
    /// user-supplied backup password and a wrong guess MUST
    /// count toward the shared lockout).
    /// before this helper existed, callers ran the password-
    /// dependent decrypt directly in their unlock dialog's
    /// onUnlock callback, paying the limiter NO attention - that
    /// made each such surface an open password oracle against
    /// the user password. Routing every such call through this
    /// helper makes the brute-force-limit engagement a code-
    /// level invariant for those surfaces too.
    /// On `op` success the shared counter is reset; on any
    /// thrown error the counter is incremented. Reasoning for
    /// the conservative "any error" treatment: the underlying
    /// JS bridge throws an opaque error string for both wrong-
    /// password and corrupt-envelope outcomes, and we cannot
    /// distinguish them. False positives (locking out a user
    /// holding a corrupt file) are bounded by the same
    /// stair-stepped backoff that protects the unlock dialog;
    /// false negatives would re-open the password oracle on
    /// the Send path, which is the worse failure mode.
    /// Throws `tooManyAttempts(remainingSeconds:)` on lockout.
    /// MUST be called from a background queue (the inner `op`
    /// is expected to do scrypt or a blocking JS bridge call).
    public static func runRateLimited<T>(
        channel: UnlockAttemptLimiter.Channel = .strongboxUnlock,
        op: () throws -> T) throws -> T {
        switch UnlockAttemptLimiter.currentDecision() {
            case .lockedFor(let remaining):
            throw UnlockCoordinatorV2Error.tooManyAttempts(remainingSeconds: remaining)
            case .allowed:
            break
        }
        let result: T
        do {
            result = try op()
        } catch {
            UnlockAttemptLimiter.recordFailure(channel: channel)
            throw error
        }
        UnlockAttemptLimiter.recordSuccess(channel: channel)
        return result
    }

    // MARK: - Wallet mutations (atomic: install + persist)
    // Each helper below is the v2-equivalent of one of the
    // historical KeyStore APIs. They follow the same pattern:
    // 1. Build the new payload via a `Strongbox.snapshotBy*`
    // builder. The builder validates the snapshot is loaded
    // and recomputes the inner checksum.
    // 2. Install the new payload into `Strongbox.shared` so any
    // reader on any thread sees the new state immediately
    // (well before the slow disk I/O of the persist call
    // finishes).
    // 3. Call `persistSnapshot(_:password:)` to seal + write to
    // the inactive slot. The user's password is required
    // because layer 4 re-derives mainKey on every write -
    // see the file header for the no-long-lived-mainKey
    // rationale.
    // If the persist throws, the speculative in-memory install is
    // rolled back to the prior snapshot so a failed write never
    // leaves a ghost entry behind. Without the rollback the
    // restore-retry path (RestoreFlow.tryDecryptAndStore) would
    // misclassify a subsequent retry as ".alreadyExists" via the
    // dedupe gate on `Strongbox.shared.addressToIndex`, surfacing
    // the misleading "already exists" toast and stranding the
    // wallet in memory with no on-disk record.

    /// Append a freshly-created wallet to the strongbox. Build a
    /// new payload that includes the wallet, install it in
    /// `Strongbox.shared`, and persist to the inactive slot.
    /// Returns the assigned `idx`.
    /// `onPhase`: optional callback forwarded to `persistSnapshot`
    /// for UI-side "Verifying..." status updates.
    @discardableResult
    public static func appendWallet(address: String,
        privateKey: Data,
        publicKey: Data,
        hasSeed: Bool,
        seedWords: String,
        password: String,
        onPhase: WriteVerifyPhaseCallback? = nil) throws -> Int {
        // the durability fix mutation serialisation. The lock holds across
        // read-from-Strongbox + payload build + install + persist
        // so a concurrent mutator cannot interleave into the
        // pipeline. NSRecursiveLock so the inner persistSnapshot
        // can re-enter on the same thread without deadlock.
        _mutationLock.lock()
        defer { _mutationLock.unlock() }
        guard Strongbox.shared.isSnapshotLoaded else {
            throw UnlockCoordinatorV2Error.notUnlocked
        }
        let next = Strongbox.shared.maxWalletIndex + 1
        if next >= PrefKeys.MAX_WALLETS {
            throw UnlockCoordinatorV2Error.tooManyWallets
        }
        let wallet = StrongboxPayload.Wallet(
            idx: next,
            address: address,
            privateKey: privateKey,
            publicKey: publicKey,
            hasSeed: hasSeed,
            seedWords: hasSeed ? seedWords : "")
        let payload: StrongboxPayload
        do {
            payload = try Strongbox.shared.snapshotByAppendingWallet(wallet)
        } catch {
            throw UnlockCoordinatorV2Error.notUnlocked
        }
        // Capture the prior snapshot BEFORE the speculative install
        // so a persist failure can roll the in-memory state back to
        // the previous-good shape. Holding the mutation lock for
        // the full capture + install + persist window means no
        // concurrent reader can observe an intermediate state and
        // no concurrent mutator can install a different snapshot
        // between our capture and our rollback.
        let priorSnapshot = Strongbox.shared.snapshotOrNil
        Strongbox.shared.installSnapshot(payload)
        do {
            try persistSnapshot(payload, password: password, onPhase: onPhase)
        } catch {
            // Roll back the speculative install. The prior snapshot
            // is guaranteed non-nil here by the `isSnapshotLoaded`
            // guard above plus the mutation lock; the
            // `clearSnapshot` branch is defensive belt-and-braces
            // for the invariant-violating "loaded then unloaded
            // under the lock" race that the lock itself rules out.
            if let priorSnapshot = priorSnapshot {
                Strongbox.shared.installSnapshot(priorSnapshot)
            } else {
                Strongbox.shared.clearSnapshot()
            }
            throw error
        }
        return next
    }

    /// Replace the user-added networks list and active-network
    /// offset atomically.
    public static func replaceNetworks(_ networks: [BlockchainNetwork],
        activeIndex: Int,
        password: String,
        onPhase: WriteVerifyPhaseCallback? = nil) throws {
        // the durability fix mutation serialisation; see static-property
        // comment on `_mutationLock`.
        _mutationLock.lock()
        defer { _mutationLock.unlock() }
        guard Strongbox.shared.isSnapshotLoaded else {
            throw UnlockCoordinatorV2Error.notUnlocked
        }
        let payload: StrongboxPayload
        do {
            payload = try Strongbox.shared.snapshotByChangingNetworks(
                networks, activeIndex: activeIndex)
        } catch {
            throw UnlockCoordinatorV2Error.notUnlocked
        }
        Strongbox.shared.installSnapshot(payload)
        try persistSnapshot(payload, password: password, onPhase: onPhase)
    }

    /// Switch the active wallet.
    public static func setCurrentWallet(idx: Int, password: String,
        onPhase: WriteVerifyPhaseCallback? = nil) throws {
        // the durability fix mutation serialisation; see static-property
        // comment on `_mutationLock`.
        _mutationLock.lock()
        defer { _mutationLock.unlock() }
        guard Strongbox.shared.isSnapshotLoaded else {
            throw UnlockCoordinatorV2Error.notUnlocked
        }
        let payload: StrongboxPayload
        do {
            payload = try Strongbox.shared.snapshotByChangingCurrentWallet(to: idx)
        } catch {
            throw UnlockCoordinatorV2Error.notUnlocked
        }
        Strongbox.shared.installSnapshot(payload)
        try persistSnapshot(payload, password: password, onPhase: onPhase)
    }

    /// Switch the active network without touching the custom-
    /// networks list. v2 equivalent of the historical "set
    /// active network index" path.
    public static func setActiveNetwork(idx: Int, password: String,
        onPhase: WriteVerifyPhaseCallback? = nil) throws {
        // the durability fix mutation serialisation; see static-property
        // comment on `_mutationLock`.
        _mutationLock.lock()
        defer { _mutationLock.unlock() }
        guard Strongbox.shared.isSnapshotLoaded else {
            throw UnlockCoordinatorV2Error.notUnlocked
        }
        let payload: StrongboxPayload
        do {
            payload = try Strongbox.shared.snapshotByChangingActiveNetwork(to: idx)
        } catch {
            throw UnlockCoordinatorV2Error.notUnlocked
        }
        Strongbox.shared.installSnapshot(payload)
        try persistSnapshot(payload, password: password, onPhase: onPhase)
    }

    // No `setBackupEnabled` helper by design. The backup-enabled
    // toggle does not live inside the encrypted payload; toggling
    // it is a pure UserDefaults pref write (see
    // `BackupExclusion.swift`) so the OS backup agent can read it
    // pre-unlock without ever needing the wallet password. There
    // is no in-strongbox copy to keep in sync.

    /// Flip the `advancedSigning` user toggle inside the
    /// strongbox.
    public static func setAdvancedSigning(_ enabled: Bool, password: String,
        onPhase: WriteVerifyPhaseCallback? = nil) throws {
        try setFlag(password: password, onPhase: onPhase) { sb in
            try sb.snapshotByChangingFlag(advancedSigning: enabled)
        }
    }

    /// Flip the `cameraPermissionAskedOnce` flag inside the
    /// strongbox.
    public static func setCameraPermissionAskedOnce(_ asked: Bool, password: String,
        onPhase: WriteVerifyPhaseCallback? = nil) throws {
        try setFlag(password: password, onPhase: onPhase) { sb in
            try sb.snapshotByChangingFlag(cameraPermissionAskedOnce: asked)
        }
    }

    /// Replace the user's chosen iCloud Drive folder URI for
    /// `.wallet` exports.
    public static func setCloudBackupFolderUri(_ uri: String, password: String,
        onPhase: WriteVerifyPhaseCallback? = nil) throws {
        try setFlag(password: password, onPhase: onPhase) { sb in
            try sb.snapshotByChangingFlag(cloudBackupFolderUri: uri)
        }
    }

    /// Insert (or overwrite) `value` at `key` in the v=3
    /// `secureItems` map. Mirrors Android
    /// `SecureStorage.setSecureItem(key, value, password)`.
    /// The map is part of the strongbox plaintext so the
    /// AEAD seal is the only encryption layer.
    public static func setSecureItem(key: String, value: String, password: String,
        onPhase: WriteVerifyPhaseCallback? = nil) throws {
        try setFlag(password: password, onPhase: onPhase) { sb in
            try sb.snapshotBySettingSecureItem(key, value: value)
        }
    }

    /// Remove `key` from the v=3 `secureItems` map, if
    /// present. No-op when absent. Mirrors Android
    /// `SecureStorage.removeSecureItem(key, password)`.
    public static func removeSecureItem(key: String, password: String,
        onPhase: WriteVerifyPhaseCallback? = nil) throws {
        try setFlag(password: password, onPhase: onPhase) { sb in
            try sb.snapshotByRemovingSecureItem(key)
        }
    }

    private static func setFlag(password: String,
        onPhase: WriteVerifyPhaseCallback? = nil,
        build: (Strongbox) throws -> StrongboxPayload) throws {
        // the durability fix mutation serialisation; see static-property
        // comment on `_mutationLock`. The lock holds across the
        // build callback so two concurrent flag flips cannot
        // interleave their (read-shared-Strongbox + build new
        // payload + install + persist) pipelines.
        _mutationLock.lock()
        defer { _mutationLock.unlock() }
        guard Strongbox.shared.isSnapshotLoaded else {
            throw UnlockCoordinatorV2Error.notUnlocked
        }
        let payload: StrongboxPayload
        do {
            payload = try build(Strongbox.shared)
        } catch {
            throw UnlockCoordinatorV2Error.notUnlocked
        }
        Strongbox.shared.installSnapshot(payload)
        try persistSnapshot(payload, password: password, onPhase: onPhase)
    }

    // MARK: - Internals

    /// Seal `data` under `key` and re-parse the resulting
    /// envelope into the structured `AeadEnvelope` value used
    /// by `StrongboxFileCodec`. The intermediate JSON envelope is
    /// the same shape as the legacy v1 wallet record; this
    /// adapter exists so layer-2 fields can be reconstructed
    /// without duplicating the seal logic from `Aead.swift`.
    private static func sealToEnvelope(_ data: Data, key: Data) throws -> StrongboxFileCodec.AeadEnvelope {
        let envJson = try Aead.seal(data, keyBytes: key)
        guard let envBytes = envJson.data(using: .utf8),
        let obj = (try? JSONSerialization.jsonObject(with: envBytes)) as? [String: Any],
        let cipherB64 = obj["cipherText"] as? String,
        let ivB64 = obj["iv"] as? String,
        let combined = Data(base64Encoded: cipherB64),
        let iv = Data(base64Encoded: ivB64),
        combined.count > 16
        else {
            throw AeadError.envelopeEncodeFailed
        }
        let tagStart = combined.count - 16
        let ct = combined.prefix(tagStart)
        let tag = combined.suffix(16)
// the `alg` literal is "AES-GCM" exactly,
        // matching the canonical schema invariant enforced by
        // `StrongboxFileCodec.AeadEnvelope.expectedAlg`. A
        // typo here (e.g. the historical `AES-GC` mistake) is
        // now caught at decode time by the
        // `decodeEnvelope` validator AND on first read by the
        // codec's strict-alg gate, so the same mistake cannot
        // silently land in a written slot file.
        return StrongboxFileCodec.AeadEnvelope(
            alg: StrongboxFileCodec.AeadEnvelope.expectedAlg,
            iv: iv,
            ct: ct,
            tag: tag)
    }

    /// Determine which slot a `DecodedFile` was read from. The
    /// codec doesn't carry that information back so we re-read
    /// each slot's bytes and compare. Used so `persist` can
    /// write to the OTHER slot.
    /// NOTE: the slot rotation invariant is "next write goes
    /// to the slot we did NOT just read from". The
    /// `currentSlot:` parameter to `writeNewGeneration` is
    /// "the slot the winner came from" - the codec writes to
    /// `currentSlot.other`. So we hand back the winning slot
    /// here.
    private static func pickSlotMatching(decoded: StrongboxFileCodec.DecodedFile) -> AtomicSlotWriter.Slot {
        // Defaults to `.A` if neither slot reads cleanly (e.g.
        // we just ran `createNewStrongbox` which wrote both); the
        // tie-breaker rule in `readWinner` is `>=` so .A wins
        // on tie.
        let aBytes = (try? AtomicSlotWriter.shared.read(slot: .A)) ?? nil
        let bBytes = (try? AtomicSlotWriter.shared.read(slot: .B)) ?? nil
        if aBytes != nil && bBytes == nil { return .A }
        if bBytes != nil && aBytes == nil { return .B }
        // Both present: the higher-generation slot is the
        // winner. Re-decode each to compare; cheap because
        // we're just JSON-parsing the top-level `generation`
        // field, no AEAD or MAC.
        if let aGen = topLevelGeneration(aBytes), let bGen = topLevelGeneration(bBytes) {
            return aGen >= bGen ? .A : .B
        }
        return .A
    }

    private static func topLevelGeneration(_ bytes: Data?) -> Int? {
        guard let bytes = bytes,
        let obj = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
        let g = obj["generation"] as? Int
        else { return nil }
        return g
    }

    // `tryRegenerateKeychainWrap` was deleted along with the
    // per-device wrap-key infrastructure that
    // it managed. Rationale lives in the file header above
    // step 12. If a biometric unlock UI is ever added, design
    // the storage primitive against
    // `kSecAttrAccessControl = biometryCurrentSet` so a coerced
    // enrollment invalidates the wrap, rather than re-introducing
    // the unconditional Keychain entry that this removal walked
    // back.
}
