// RestoreFlow.swift
// Coordinates restore-from-file and restore-from-cloud-folder flows.
// Mirrors the Android `WalletsFragment.runBatchedRestorePass` loop:
// * Load every candidate file up front (URL + JSON + address).
// * Show one BackupPasswordDialog listing all pending addresses.
// * On OK, present a WaitDialog with an updatable address line and
// "[CURRENT] of [TOTAL]" progress, then run the decrypt loop.
// * After the pass:
// - If every wallet decrypted (or was a duplicate), dismiss the
// dialog, surface a single "already exists" toast for any
// duplicates, and finish.
// - If some wallets decrypted, dismiss + re-open the dialog with
// the shrunken pending list.
// - If no wallet decrypted, surface a modal "try a different
// password" dialog and re-enable the password dialog WITHOUT
// clearing the typed password.
// Persists wallets through `UnlockCoordinatorV2.appendWallet`, which
// updates `Strongbox.shared` in place so the wallet list / main strip /
// Receive screen all show the imported wallet without a relaunch.
// Android references:
// app/src/main/java/com/quantumcoinwallet/app/view/fragment/WalletsFragment.java
// app/src/main/java/com/quantumcoinwallet/app/view/fragment/HomeWalletFragment.java

import Foundation
import UIKit

public final class RestoreFlow {

    public static let shared = RestoreFlow()
    private init() {}

    /// Optional callback fired when a batch (single or multi-file)
    /// finishes - either because the user worked through every wallet
    /// or cancelled the remaining ones. The caller can use this to
    /// route to the wallet home screen, similar to Android's
    /// `WalletsFragment.onRestoreCompleted`.
    public var onComplete: (() -> Void)?

    /// Set to `true` when at least one wallet imported successfully in
    /// the current batch. Cleared when a new batch starts. Lets the
    /// onComplete callback decide whether to route home or stay put.
    public private(set) var didImportAny: Bool = false

    private struct Candidate {
        let url: URL
        let json: String
        let address: String
    }

    private enum DecryptOutcome {
        case imported
        case alreadyExists
        case failed
    }

    /// First-time-setup callers (`HomeWalletViewController`) pass the
    /// password the user typed on Set Wallet Password. The strongbox gets
    /// unlocked / bootstrapped with this password rather than the
    /// per-wallet backup password, so the user keeps their chosen
    /// strongbox password after restore. Cleared on every new batch so a
    /// post-onboarding "Add wallet" path doesn't accidentally inherit
    /// it.
    private var strongboxPassword: String?

    // MARK: - Per-batch summary state
    //
    // Per-batch tallies that drive the post-restore summary dialog.
    // Populated by `runDecryptPass` and `dlg.onCancel`; consumed by
    // `presentSummaryAndFinish`; reset by `runBatch` on entry and by
    // `finishBatch` on exit so a follow-up batch starts clean.
    // Mirrors Android `runBatchedRestorePass` (`restored`,
    // `alreadyExists`, `skipped` arrays threaded through every pass)
    // — see `HomeWalletFragment.showRestoreSummaryDialog`.
    private var restoredAddresses: [String] = []
    private var alreadyExistsAddresses: [String] = []
    private var skippedAddresses: [String] = []

    /// Weak handle to the presenter view controller for the current
    /// batch. Stored so paths that need to present the final summary
    /// dialog (cancel, all-done, post-decrypt completion) can do so
    /// without re-threading `host` through every callback chain. The
    /// presenter is the same VC the caller passed into `runBatch`
    /// / `restoreFromFile` / `restoreFromCloudFolder`; weak so we do
    /// not artificially extend its lifetime once the batch is over.
    private weak var currentHost: UIViewController?

    // MARK: - Public entry points

    /// Restore from one or more `.wallet` files picked via the system
    /// file picker. Mirrors Android `startRestoreFromFileFlow`.
    public func restoreFromFile(from host: UIViewController,
        strongboxPassword: String? = nil) {
        CloudBackupManager.shared.presentRestorePicker(from: host) { [weak self, weak host] urls in
            guard let self = self, let host = host, !urls.isEmpty else { return }
            self.runBatch(urls: urls, host: host, strongboxPassword: strongboxPassword)
        }
    }

    /// Enumerate the persisted cloud folder, feed every `.wallet` file
    /// through the batch-restore flow.
    public func restoreFromCloudFolder(from host: UIViewController,
        strongboxPassword: String? = nil) {
        let files = CloudBackupManager.shared.listWalletFiles
        if files().isEmpty {
            Toast.showMessage(Localization.shared.getRestoreNoBackupsFoundByLangValues())
            return
        }
        runBatch(urls: files(), host: host, strongboxPassword: strongboxPassword)
    }

    /// Run the batched restore pass over a pre-resolved set of URLs.
    /// Used by `restoreFromFile`, `restoreFromCloudFolder`, and the
    /// `HomeWalletViewController.startCloudRestore` entry that
    /// re-presents the folder picker every time.
    public func runBatch(urls: [URL], host: UIViewController,
        strongboxPassword: String? = nil) {
        didImportAny = false
        // Reset per-batch summary tallies and stash the host BEFORE we
        // start dispatching dialogs; every later branch (cancel,
        // all-done, lockout pre-check) reads from these in addition to
        // the closure-captured `host` parameter.
        restoredAddresses.removeAll(keepingCapacity: false)
        alreadyExistsAddresses.removeAll(keepingCapacity: false)
        skippedAddresses.removeAll(keepingCapacity: false)
        currentHost = host
        self.strongboxPassword = (strongboxPassword?.isEmpty == false) ? strongboxPassword : nil

        // Build candidates while collecting per-file failure reasons so
        // the user gets a useful message instead of the generic "no
        // backup files found" toast when something specific went wrong
        // (cloud file not yet downloaded, wrong file type picked,
        // unreadable JSON, address shape rejected, etc.).
        var candidates: [Candidate] = []
        var failures: [(name: String, reason: String)] = []
        for url in urls {
            switch loadCandidateDetailed(from: url) {
                case .success(let c):
                candidates.append(c)
                case .failure(let reason):
                failures.append((name: url.lastPathComponent, reason: reason))
            }
        }

        if candidates.isEmpty {
            // Surface the most informative failure we have rather than
            // the generic "no backup files found" toast. The generic
            // message remains the fallback when the picker really did
            // hand us an empty URL list (`urls.isEmpty`) or when the
            // failure reason itself is empty.
            let message: String
            if let first = failures.first {
                if failures.count == 1 {
                    message = "Cannot use \"\(first.name)\": \(first.reason)"
                } else {
                    let extra = failures.count - 1
                    message = "Cannot use \"\(first.name)\" "
                    + "(and \(extra) other file\(extra == 1 ? "" : "s")): "
                    + first.reason
                }
            } else {
                message = Localization.shared.getRestoreNoBackupsFoundByLangValues()
            }
            Toast.showMessage(message)
            finishBatch()
            return
        }
        presentBatchDialog(pending: candidates, host: host)
    }

    // MARK: - Internals

    /// Detailed loader: returns either a `Candidate` or a
    /// human-readable failure reason. Callers choose whether to
    /// aggregate the reasons into a UI message.
    /// Failure modes covered explicitly:
    /// * `.icloud` placeholder URL: an iCloud Drive file the user
    /// selected before iOS finished downloading it. The picker
    /// hands us the placeholder URL; reading it returns no bytes.
    /// We detect this via `URLResourceValues.isUbiquitousItem`
    /// and trigger a synchronous download (`startDownloadingUbiq
    /// uitousItem`) before re-trying the read. The user sees
    /// "downloading…" briefly via the existing wait dialog
    /// rather than a confusing "no backup files" toast.
    /// * Security-scoped resource access denied: the picker URL
    /// requires a `startAccessingSecurityScopedResource` bracket
    /// to be readable. We surface a specific message so the
    /// user knows to re-pick from a location the app can read.
    /// * `NSFileCoordinator` is required for files in iCloud
    /// Drive / Files-app provider extensions. Plain
    /// `Data(contentsOf:)` may race with the provider's own
    /// coordinated writes and return EBUSY / ENOENT silently.
    /// We coordinate every read through `NSFileCoordinator` so
    /// these reads succeed on first try.
    /// * Bad JSON / missing `address` / address fails the
    /// `^0x[0-9a-fA-F]{64}$` shape check (32-byte QuantumCoin
    /// addresses; the previous `{40}` figure was a stale carry-over
    /// from a 20-byte scheme):
    /// each surfaced with its own message so a user who picked
    /// a non-`.wallet` file by accident knows to re-pick.
    private enum CandidateLoadResult {
        case success(Candidate)
        case failure(String)
    }

    private func loadCandidateDetailed(from url: URL) -> CandidateLoadResult {
// the original
        // `let ok = url.startAccessingSecurityScopedResource`
        // captures the method reference WITHOUT invoking it,
        // and the defer's `ok()` then started the resource
        // right before stopping it. As a result, the read of
        // an iCloud / external-provider URL below would
        // silently fail with EPERM (and the user would see the
        // confusing "no backup files were present" toast for
        // a file picked from iCloud Drive). Calling the method
        // immediately and capturing the Bool fixes the bracket.
        let started = url.startAccessingSecurityScopedResource()
        defer {
            if started {
                url.stopAccessingSecurityScopedResource()
            }
        }

        // Step 1: trigger an iCloud download if this URL is a
        // not-yet-materialised cloud placeholder. We are explicit about
        // the placeholder case because the bare `Data(contentsOf:)`
        // would silently succeed with the placeholder bytes (or fail
        // with a permission error) and the user would never know the
        // file just needed a moment.
        if let resVals = try? url.resourceValues(forKeys: [
                .isUbiquitousItemKey,
                .ubiquitousItemDownloadingStatusKey
            ]),
        resVals.isUbiquitousItem == true,
        let status = resVals.ubiquitousItemDownloadingStatus,
        status != .current {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            // Brief poll: up to ~3 seconds for the small wallet file.
            // We do not block the caller forever - if the download is
            // genuinely slow we surface a "still downloading" message
            // so the user re-tries in a moment.
            let deadline = Date().addingTimeInterval(3.0)
            while Date() < deadline {
                if let r = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
                r.ubiquitousItemDownloadingStatus == .current {
                    break
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            if let r = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
            r.ubiquitousItemDownloadingStatus != .current {
                return .failure("File is still downloading from iCloud. Wait a moment, then re-pick.")
            }
        }

        // Step 2: coordinated read. `NSFileCoordinator` is the right
        // primitive for picker URLs because the document provider
        // owns the file lifecycle and our process is just a guest.
        var readError: NSError?
        var data: Data?
        var coordinationError: Error?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        coordinator.coordinate(readingItemAt: url,
            options: [.withoutChanges],
            error: &readError) { coordinatedURL in
            do {
                data = try Data(contentsOf: coordinatedURL)
            } catch {
                coordinationError = error
            }
        }
        if let coordErr = readError {
            return .failure("Cannot read file: \(coordErr.localizedDescription)")
        }
        if let dataErr = coordinationError {
            return .failure("Cannot read file: \(dataErr.localizedDescription)")
        }
        guard let bytes = data else {
            return .failure("Cannot read file (empty result).")
        }
        if bytes.isEmpty {
            return .failure("File is empty.")
        }

        // Step 3: UTF-8 decode + shape validation.
        guard let json = String(data: bytes, encoding: .utf8) else {
            return .failure("File is not valid UTF-8 text.")
        }
        // `extractAddress` runs the strict regex
        // (`^0x[0-9a-fA-F]{64}$`) and returns nil on shape failure,
        // so any address that survives is safe to use as a filesystem
        // path component. Identity-binding (does the recovered key
        // really derive this address?) is enforced separately in
        // `tryDecryptAndStore` after the JS bridge decrypts the file
        // - the second half of the fix.
        guard let address = CloudBackupManager.extractAddress(fromEncryptedJson: json) else {
            return .failure("File is not a valid wallet backup (missing or malformed address).")
        }
        return .success(Candidate(url: url, json: json, address: address))
    }

    /// Compatibility shim retained for any internal caller that
    /// only needs the optional return shape. New code should call
    /// `loadCandidateDetailed` so failure reasons can surface to UI.
    private func loadCandidate(from url: URL) -> Candidate? {
        switch loadCandidateDetailed(from: url) {
            case .success(let c): return c
            case .failure: return nil
        }
    }

    private func finishBatch() {
        let cb = onComplete
        // Clear the callback first so a re-entrant onComplete that
        // immediately starts another flow doesn't fire again on the
        // way back out of this stack.
        onComplete = nil
        strongboxPassword = nil
        // Drop per-batch summary state so a follow-up batch (the same
        // session can run multiple — onboarding-then-add-wallet, or
        // wallets-screen restore after a previous restore failed)
        // starts from a clean slate. `currentHost` is also cleared so
        // any stray late callback that reads it sees nil and no-ops
        // instead of presenting on a stale presenter.
        restoredAddresses.removeAll(keepingCapacity: false)
        alreadyExistsAddresses.removeAll(keepingCapacity: false)
        skippedAddresses.removeAll(keepingCapacity: false)
        currentHost = nil
        cb?()
    }

    /// Build and present the post-restore summary dialog, then route
    /// through `finishBatch()` once the user dismisses it. Mirrors
    /// Android `HomeWalletFragment.showRestoreSummaryDialog`. If the
    /// host has been torn down (weak ref nil'd) we skip the dialog
    /// and finish immediately — there is no presenter we can safely
    /// attach to, and the alternative is leaking the batch state.
    /// Not marked `@MainActor` because every call site is already on
    /// the main thread (the dialog dismissal completion handlers and
    /// `dlg.onCancel` all fire on main), and forcing the annotation
    /// would require sprinkling `Task { @MainActor in ... }`
    /// wrappers at non-isolated callers like the password-dialog
    /// cancel closure for no real safety gain — `present(_:)` would
    /// trap immediately on a non-main caller anyway.
    private func presentSummaryAndFinish() {
        guard let host = currentHost else {
            finishBatch()
            return
        }
        let dlg = RestoreSummaryDialogViewController(
            restored: restoredAddresses,
            alreadyExists: alreadyExistsAddresses,
            skipped: skippedAddresses)
        dlg.onClose = { [weak self] in self?.finishBatch() }
        host.present(dlg, animated: true)
    }

    private func presentBatchDialog(pending: [Candidate], host: UIViewController) {
        let mode: BackupPasswordDialog.Mode = pending.count == 1
        ? .restoreSingle(address: pending[0].address)
        : .restoreBatch(remainingAddresses: pending.map(\.address))
        let dlg = BackupPasswordDialog(mode: mode)
        dlg.onSubmit = { [weak self, weak host, weak dlg] password in
            guard let self = self, let host = host, let dlg = dlg else { return }
            self.runDecryptPass(pending: pending, password: password,
                host: host, dialog: dlg)
        }
        dlg.onCancel = { [weak self] in
            // Mark every wallet still waiting on a password as Skipped
            // so the post-restore summary attributes them correctly
            // (matches Android `runBatchedRestorePass` lines 2864-2870
            // where the cancel branch loops pending → skipped). The
            // password dialog has already dismissed itself by the time
            // this fires, so the summary presents directly on the
            // host VC.
            guard let self = self else { return }
            for c in pending {
                self.skippedAddresses.append(c.address)
            }
            self.presentSummaryAndFinish()
        }
        host.present(dlg, animated: true)
    }

    private func runDecryptPass(pending: [Candidate], password: String,
        host: UIViewController, dialog: BackupPasswordDialog) {
        let L = Localization.shared
        // Limiter pre-check is now done ONCE per password submission
        // (not once per wallet inside the loop). A locked-out caller
        // never reaches the wait dialog or scrypt loop — instead we
        // show the canonical lockout copy on the password dialog and
        // let the user wait it out without burning ~300 ms of scrypt
        // per wallet only to be rejected at the end. Matches Android
        // `runBatchedRestorePass` policy: one limiter event per OK
        // tap, regardless of how many `.wallet` files are in the
        // batch. See `UnlockAttemptLimiter` header for the shared-
        // counter rationale.
        switch UnlockAttemptLimiter.currentDecision() {
            case .lockedFor(let remaining):
            let msg = UnlockAttemptLimiter
                .userFacingLockoutMessage(remainingSeconds: remaining)
            showRestoreError(over: dialog, message: msg) {
                dialog.reEnable(withError: nil)
            }
            return
            case .allowed:
            break
        }
        let wait = WaitDialogViewController(
            message: L.getRestoreWalletsDecryptingByLangValues())
        let progressTemplate = L.getRestoreProgressOfByLangValues()
        // Phase callback wires the wait-dialog's secondary status
        // line to "Verifying..." during the integrity-check window
        // of each per-wallet strongbox slot write. The "N of M"
        // progressLabel and the per-wallet detailLabel keep their
        // own roles; the secondary status slot toggles independently.
        // See `WaitDialogViewController.setStatus`.
        let onPhase = makeVerifyingPhaseHandler(for: wait)
        // Present the wait overlay on top of the password dialog so
        // both stay visible during the pass (matching Android's
        // `WaitDialog.showWithDetails` behavior, which leaves the
        // password dialog underneath).
        dialog.present(wait, animated: true) {
            Task.detached(priority: .userInitiated) {
                var stillPending: [Candidate] = []
                var alreadyExisting: [Candidate] = []
                var importedThisPass: [Candidate] = []
                let total = pending.count
                for (i, c) in pending.enumerated() {
                    await MainActor.run {
                        wait.setDetail(c.address)
                        wait.setProgress(progressTemplate
                            .replacingOccurrences(of: "[CURRENT]", with: "\(i + 1)")
                            .replacingOccurrences(of: "[TOTAL]", with: "\(total)"))
                    }
                    switch self.tryDecryptAndStore(candidate: c, password: password,
                        onPhase: onPhase) {
                        case .imported:
                        importedThisPass.append(c)
                        await MainActor.run { self.didImportAny = true }
                        case .alreadyExists:
                        alreadyExisting.append(c)
                        case .failed:
                        stillPending.append(c)
                    }
                }
                // Record exactly one limiter event per password
                // submission. Any success at all (a single wallet
                // decrypted with this password) is treated as a
                // confirmed-correct password and zeros the counter;
                // only an all-failure pass (no imports, no dupes
                // because dupes would have come from a previously
                // confirmed-correct password too) increments it.
                // The pure-duplicates case (all entries already in
                // the strongbox, nothing newly imported and nothing
                // failed) does NOT count toward the limiter in
                // either direction — the password was never
                // actually exercised against ciphertext.
                if !importedThisPass.isEmpty {
                    UnlockAttemptLimiter.recordSuccess(channel: .backupDecrypt)
                } else if !stillPending.isEmpty {
                    UnlockAttemptLimiter.recordFailure(channel: .backupDecrypt)
                }
                await MainActor.run {
                    // Promote the per-pass tallies into the per-batch
                    // summary state before handing off to the dialog
                    // glue, so the cancel / all-done / partial-progress
                    // branches all see the same authoritative arrays.
                    for c in importedThisPass {
                        self.restoredAddresses.append(c.address)
                    }
                    for c in alreadyExisting {
                        self.alreadyExistsAddresses.append(c.address)
                    }
                    self.handlePassResult(pending: pending,
                        stillPending: stillPending,
                        alreadyExisting: alreadyExisting,
                        host: host,
                        dialog: dialog,
                        wait: wait)
                }
            }
        }
    }

    /// Decrypt + persist a single candidate. Returns:
    /// - `.imported` on success (keystore entry written + KeyStore
    /// address-index map updated so the wallet appears in the UI).
    /// - `.alreadyExists` if the address is already present in the
    /// in-memory `Strongbox.shared.addressToIndex` map. Treated as a
    /// successful step so the dialog doesn't re-prompt forever, but
    /// surfaced separately in the post-pass toast.
    /// - `.failed` for wrong password / JS bridge / keystore errors,
    /// so the caller keeps the candidate in the pending list for a
    /// retry.
    private func tryDecryptAndStore(candidate: Candidate,
        password: String,
        onPhase: UnlockCoordinatorV2.WriteVerifyPhaseCallback? = nil) -> DecryptOutcome {
        // Skip already-imported wallets up front so we don't waste a
        // scrypt cycle and don't pollute the keystore with duplicate
        // slots. Mirrors Android `walletAlreadyExists` short-circuit.
        // The strongbox may not be unlocked yet (onboarding cloud-restore
        // path) - in that case the address-to-index map is empty and
        // we let the dedupe check fall through; the duplicate is then
        // caught after the strongbox unlock rebuilds the map below.
        if Strongbox.shared.isSnapshotLoaded,
        Strongbox.shared.index(forAddress: candidate.address) != nil {
            return .alreadyExists
        }
        // Limiter accounting (pre-check + record on success/failure)
        // is performed once per password submission in
        // `runDecryptPass`, NOT once per wallet here. Counting per
        // wallet poisoned the shared limiter on the FIRST wrong-
        // password tap against any batch of ≥5 `.wallet` files,
        // which bled into the strongbox unlock dialog (same shared
        // counter) and produced the bogus "too many failed
        // attempts" symptom on first-time setup and on the 2nd
        // password prompt of a multi-pass restore. See the file
        // header comments on `UnlockAttemptLimiter` for the
        // shared-counter rationale.

        do {
            // Decrypt the cloud `.wallet` blob with the backup
            // password to (a) verify the password is correct and
            // (b) recover the raw signing-key bytes + seed phrase
            // so we can persist them directly into the strongbox.
            // The strongbox stores raw bytes (no nested per-
            // wallet envelope), so there is no re-encrypt step:
            // `appendWallet` seals the keys under the user's
            // strongbox password as part of the strongbox-wide
            // AEAD, exactly like a fresh wallet creation.
            // The keys are held as `Data` and zeroized via the
            // `defer` once `appendWallet` has copied them into
            // the snapshot.
            var envelope = try JsBridge.shared.decryptWalletJson(
                walletJson: candidate.json, password: password)
            defer {
                envelope.privateKey.resetBytes(in: 0..<envelope.privateKey.count)
                envelope.publicKey.resetBytes(in: 0..<envelope.publicKey.count)
            }

// integrity check on the file's
            // self-declared address. The JS bridge derives the address
            // from the recovered private key; that derived value is
            // an INDEPENDENT source of truth from the file's outer-
            // JSON `address` field (which `loadCandidate` extracted as
            // `candidate.address`).
            // If the two disagree, the file is lying about which key
            // it contains. The most plausible reason for that is a
            // crafted `.wallet` file where the outer JSON declares
            // victim address V but the inner ciphertext decrypts to
            // attacker-controlled key K. Without this check the
            // restore would persist V into the wallet metadata while
            // the actual signing key is K, producing a "send from V"
            // UI that signs with K and either fails (best case) or
            // successfully transfers to the attacker on a different
            // chain ID (worst case).
            // This check is layered on top of the shape check that
            // `QuantumCoinAddress.isValid` performed at extraction time:
            // shape check defeats path-traversal, identity check
            // defeats signing-target spoofing.
            // On mismatch we throw `decodeFailed`, which is the same
            // error class as wrong password / corrupt file - the
            // outcome from the user's perspective is "this backup
            // file did not import" without leaking which dimension
            // failed (which would itself be a side channel about
            // attacker techniques).
            let recoveredRaw = envelope.address
            let prefixed = recoveredRaw.hasPrefix("0x") ? recoveredRaw : "0x" + recoveredRaw
            guard let recovered = QuantumCoinAddress.normalized(prefixed),
            recovered.lowercased() == candidate.address.lowercased()
            else {
                throw UnlockCoordinatorV2Error.decodeFailed
            }

            // Build the seed payload mirroring the Android sibling
            // (HomeWalletFragment.java around line 3266): prefer the
            // seed-words array when present, fall back to the
            // single-string `seed` field when the array is empty,
            // and accept the empty string when neither is present.
            // The last case is the key-only category (Android v4
            // imported-by-keys wallets, ports of `walletFromKeys`)
            // where the backup file carries privateKey/publicKey
            // bytes but no recoverable BIP39 phrase. The historical
            // iOS shape threw `decodeFailed` when the array was
            // empty and the outer batch flow then surfaced the
            // generic "Unable to decrypt any wallet with that
            // password" alert - misleading because the password
            // had already been verified by the bridge before the
            // seed shape was even inspected. Now the strongbox
            // entry is written with `hasSeed = false`, the
            // reveal-seed / backup-by-seed surfaces handle the
            // missing-seed case via the existing `hasSeed`
            // accessor, and send / sign flows continue to use the
            // raw key bytes unchanged.
            let seedJoined: String
            if let words = envelope.seedWords, !words.isEmpty {
                seedJoined = words.joined(separator: ",")
            } else if let seed = envelope.seed, !seed.isEmpty {
                seedJoined = seed
            } else {
                seedJoined = ""
            }
            let hasSeed = !seedJoined.isEmpty
            // The strongbox password used for strongbox writes is
            // either:
            // - Onboarding (fresh install) cloud-restore path: the
            // user's chosen strongbox password from Set Wallet
            // Password (passed in via `strongboxPassword`).
            // Falling back to the backup password would silently
            // swap the unlock password.
            // - Post-onboarding ("add another wallet") path: the
            // backup password matches the strongbox password by
            // contract, so `strongboxPassword` is nil and we
            // use `password` directly.
            // The strongbox API requires the user's password on
            // every write (mainKey is never cached across
            // operations), so we resolve it once up-front and
            // forward it to bootstrapOrUnlock + appendWallet.
            let strongboxWritePw: String
            if let chosen = strongboxPassword, !chosen.isEmpty {
                strongboxWritePw = chosen
            } else {
                strongboxWritePw = password
            }
            // Persist the recovered raw bytes into the strongbox
            // under the STRONGBOX password. There is no nested
            // per-wallet envelope: the strongbox AEAD is the only
            // encryption layer, so the wallet's key material is
            // sealed under the strongbox password as part of the
            // payload-wide write. Send / Reveal / Backup all read
            // the raw bytes back out of the unlocked snapshot
            // without a second password round.
            let idx: Int
            if !Strongbox.shared.isSnapshotLoaded,
            case .noStrongbox = UnlockCoordinatorV2.bootState() {
                // Single-wallet restore on a fresh install: use
                // the hardening's atomic createNewStrongboxWithInitialWallet
                // so the strongbox + first wallet land in the same
                // slot write. Closes the durability gap — a power-cut
                // between the historical createNewStrongbox +
                // appendWallet pair could leave an empty-wallet
                // strongbox the user trusted as restored.
                let wallet = StrongboxPayload.Wallet(
                    idx: 0,
                    address: candidate.address,
                    privateKey: envelope.privateKey,
                    publicKey: envelope.publicKey,
                    hasSeed: hasSeed,
                    seedWords: seedJoined)
                try UnlockCoordinatorV2.createNewStrongboxWithInitialWallet(
                    password: strongboxWritePw,
                    initialWallet: wallet,
                    onPhase: onPhase)
                idx = 0
            } else {
                if !Strongbox.shared.isSnapshotLoaded {
                    try Self.bootstrapOrUnlock(password: strongboxWritePw,
                        onPhase: onPhase)
                    // The strongbox was just unlocked, so the
                    // address-index map now reflects whatever was
                    // already on disk. Re-check the dedupe gate
                    // here because we couldn't run it up-top while
                    // locked - importing a wallet that's already
                    // a slot would silently create a duplicate.
                    if Strongbox.shared.index(forAddress: candidate.address) != nil {
                        return .alreadyExists
                    }
                }
                idx = try UnlockCoordinatorV2.appendWallet(
                    address: candidate.address,
                    privateKey: envelope.privateKey,
                    publicKey: envelope.publicKey,
                    hasSeed: hasSeed,
                    seedWords: seedJoined,
                    password: strongboxWritePw,
                    onPhase: onPhase)
            }
            // Update the current-wallet pointer so the wallets list
            // / main strip / Receive screen open to the imported
            // wallet without a relaunch. Throwing setter;
            // a flush failure here downgrades to "next launch opens
            // the previous wallet" — recoverable, not fatal.
            do {
                try PrefConnect.shared.writeInt(
                    PrefKeys.WALLET_CURRENT_ADDRESS_INDEX_KEY, idx)
            } catch {
                Logger.warn(category: "PREFS_FLUSH_FAIL",
                    "WALLET_CURRENT_ADDRESS_INDEX_KEY: \(error)")
            }
            // Limiter accounting is done once per password
            // submission in `runDecryptPass` (see the note at the
            // top of this method). We deliberately do NOT call
            // recordSuccess here, since one OK tap that decrypts
            // 5 wallets must count as a single success against
            // the shared brute-force counter — not 5.
            return .imported
        } catch {
            // Limiter accounting is done once per password
            // submission in `runDecryptPass` (see the note at the
            // top of this method). Returning `.failed` lets the
            // caller tally up all-passed / all-failed / partial
            // for this pass and record exactly one limiter event
            // accordingly.
            return .failed
        }
    }

    /// Bootstrap the strongbox on first launch (no slot file) or
    /// unlock the existing strongbox on a returning device. Used
    /// from the restore path before `appendWallet` so the
    /// post-restore strongbox is consistent regardless of whether
    /// the user is restoring onto a fresh install or adding a
    /// recovered wallet to an existing strongbox.
    /// What it closes:
    ///   The "wrong password silently accepted" bug on the
    ///   restore-from-seed onboarding path. The historical shape
    ///   was `if Strongbox.shared.isSnapshotLoaded { return }` at
    ///   the very top — which short-circuited to "success" when
    ///   the snapshot was already loaded by a previous restore
    ///   step. Re-entering the restore flow with a different
    ///   password (or going back-then-Next from the confirmWallet
    ///   step) silently re-sealed the next slot under a
    ///   mismatched password, bricking the wallet.
    /// Why this shape (verify-on-snapshot-loaded):
    ///   When the snapshot is already loaded we route through
    ///   the read-only `UnlockCoordinatorV2.verifyPassword` which
    ///   AEAD-opens `passwordWrap` and signals the brute-force
    ///   limiter, but does not re-install the snapshot or bump
    ///   the rollback counter (both of which are unsafe against
    ///   a live wallet — see verifyPassword's docstring).
    /// Cross-references:
    ///   - `UnlockCoordinatorV2.verifyPassword(_:)`.
    ///   - `HomeWalletViewController.bootstrapOrUnlock` for the
    ///     matching change on the new-wallet side.
    private static func bootstrapOrUnlock(password: String,
        onPhase: UnlockCoordinatorV2.WriteVerifyPhaseCallback? = nil) throws {
        switch UnlockCoordinatorV2.bootState() {
            case .noStrongbox:
            try UnlockCoordinatorV2.createNewStrongbox(
                password: password, onPhase: onPhase)
            case .strongboxPresent:
            if Strongbox.shared.isSnapshotLoaded {
                // Snapshot loaded by a previous restore step;
                // verify the password against the on-disk
                // `passwordWrap` without re-installing the
                // snapshot or bumping the rollback counter.
                try UnlockCoordinatorV2.verifyPassword(password)
            } else {
                try UnlockCoordinatorV2.unlockWithPasswordAndApplySession(password)
            }
            case .tampered(let why):
            throw UnlockCoordinatorV2Error.tamperDetected(why)
        }
    }

    @MainActor
    private func handlePassResult(pending: [Candidate],
        stillPending: [Candidate],
        alreadyExisting: [Candidate],
        host: UIViewController,
        dialog: BackupPasswordDialog,
        wait: WaitDialogViewController) {
        wait.dismiss(animated: true) {
            if stillPending.isEmpty {
                // Every wallet was processed (imported or skipped as
                // duplicate). Close the dialog, then present the
                // summary card before finishing the batch. The
                // summary doubles as the duplicate notice that the
                // older toast-only flow surfaced, so the toast is no
                // longer needed on this branch — the summary lists
                // duplicates under the "Already exists" status.
                dialog.dismiss(animated: true) {
                    self.presentSummaryAndFinish()
                }
            } else if stillPending.count + alreadyExisting.count == pending.count
            && stillPending.count == pending.count {
                // No wallet decrypted with this password (no duplicates
                // either). Keep the password dialog up, show a modal
                // error, then re-enable the dialog so the user can fix
                // one character and retry without losing their typed
                // password.
                self.showRestoreError(
                    over: dialog,
                    message: Localization.shared.getRestoreTryDifferentPasswordByLangValues()
                ) {
                    dialog.reEnable(withError: nil)
                }
            } else {
                // Partial success - dismiss the dialog, optionally
                // surface duplicates, then re-open the dialog with the
                // shrunken pending list (Android opens a fresh dialog
                // each pass too).
                dialog.dismiss(animated: true) {
                    self.surfaceDuplicates(alreadyExisting)
                    self.presentBatchDialog(pending: stillPending, host: host)
                }
            }
        }
    }

    /// Single combined toast for all wallets that the user already had
    /// in the keystore. Mirrors Android `wallet-already-exists-detailed`
    /// (`The wallet with following address already exists:\n[ADDRESS]`).
    private func surfaceDuplicates(_ duplicates: [Candidate]) {
        guard !duplicates.isEmpty else { return }
        let template = Localization.shared.getWalletAlreadyExistsDetailedByLangValues()
        let joined = duplicates.map(\.address).joined(separator: "\n")
        let message = template.replacingOccurrences(of: "[ADDRESS]", with: joined)
        Toast.showMessage(message)
    }

    private func showRestoreError(over presenter: UIViewController,
        message: String,
        onOK: @escaping () -> Void) {
        let dlg = ConfirmDialogViewController(
            title: Localization.shared.getErrorTitleByLangValues(),
            message: message,
            confirmText: Localization.shared.getOkByLangValues(),
            cancelText: "",
            hideCancel: true)
        dlg.onConfirm = onOK
        presenter.present(dlg, animated: true)
    }
}
