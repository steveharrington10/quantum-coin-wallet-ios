// CloudBackupManager.swift
// Port of `CloudBackupManager.java`. Handles:
// - File backup via `UIDocumentPickerViewController(forExporting:)`.
// - Cloud backup via `UIDocumentPickerViewController(forOpening: [.folder])`,
// bookmarked under `CLOUD_BACKUP_FOLDER_URI_KEY` so subsequent
// writes do not re-prompt.
// - Restore enumeration over the cloud folder.
// - Filename format: `UTC--{yyyy-MM-dd'T'HH-mm-ss.SSS'Z'}--{address}.wallet`.
// Android reference:
// app/src/main/java/com/quantumcoinwallet/app/backup/CloudBackupManager.java

import UIKit
import UniformTypeIdentifiers

public final class CloudBackupManager: NSObject {

    public static let shared = CloudBackupManager()

    public static let fileExtension = "wallet"
    public static let fileMime = "application/octet-stream"

    private weak var folderPickerHost: UIViewController?
    private var folderPickerCompletion: ((Bool) -> Void)?
    private weak var restorePickerHost: UIViewController?
    private var restorePickerCompletion: (([URL]) -> Void)?

    /// True while a `UIDocumentPickerViewController(forExporting:)` is on
    /// screen. The shared `UIDocumentPickerDelegate` callbacks must
    /// branch on this flag *before* the folder-picker handling so an
    /// export pick does not get mis-routed into `persistBookmark` (which
    /// would silently overwrite the cloud-folder bookmark with the
    /// just-saved file's URL) and so we can show the success toast.
    private var exportPickerActive: Bool = false

    /// `WaitDialogViewController` shown the instant the user taps a
    /// backup / restore button so the brief lag while iOS spins up the
    /// `UIDocumentPickerViewController` (and, for cloud folders, scans
    /// iCloud Drive) is not invisible. The picker is presented on top
    /// of this dialog; the delegate methods below dismiss the dialog
    /// after the picker tears down.
    private var pickerLoadingDialog: WaitDialogViewController?

    /// Tracks the staging directory for the currently-
    /// in-flight export. The path is `<tmp>/qcw-backup-<8 hex>/<file>`
    /// and gets removed (recursively) by `cleanupStagedExport` from
    /// both the picker-completed and picker-cancelled paths so the
    /// encrypted-but-shareable wallet JSON does not linger in the
    /// app's tmp directory after the export finishes.
    /// design rationale: /// The pre-fix flow created `<tmp>/UTC--{ts}--{addr}.wallet`,
    /// handed it to `UIDocumentPickerViewController`, and never
    /// deleted it. The file persisted indefinitely (iOS may evict
    /// `tmp/` under disk-pressure but does not promise this; on a
    /// rarely-pressured device it survives across launches). Any app
    /// that gains ANY read access to the app sandbox - a future
    /// App-Group sibling, a misconfigured share extension, an OS-bug
    /// sandbox escape, a forensic image of the device - can read the
    /// file. Even though it is encrypted under the user's BACKUP
    /// password, the file is now an offline brute-force target where
    /// one was not intended to exist on disk past the export call.
    /// Tradeoff:
    /// The deletion is best-effort - if iOS kills the app between
    /// the picker presentation and the user's pick action, the
    /// delegate callback never fires and the file persists until
    /// the next launch. `cleanupStaleStagedExports` (called from
    /// AppDelegate at launch time) sweeps any leftover
    /// `qcw-backup-*` directory so a crashed export does not leave
    /// indefinite residue. The naming prefix `qcw-backup-` makes
    /// the sweep targeted (no risk of deleting unrelated tmp/
    /// contents).
    private var stagedExportURL: URL?
    private var stagedExportDir: URL?

    /// Naming prefix for every staging directory created by
    /// `exportWalletFile`. The launch-time sweeper enumerates `tmp/`
    /// for entries beginning with this prefix so leftover staging
    /// directories from prior crashes / kills are removed.
    private static let stagingDirPrefix = "qcw-backup-"

    private override init() { super.init() }

    // MARK: - Filename

    /// Build a backup filename of the shape
    /// `UTC--{yyyy-MM-dd'T'HH-mm-ss.SSS'Z'}--{addressHex}.wallet`.
    /// path-traversal hardening (notes):
    /// `address` flows into a filesystem path via
    /// `URL.appendingPathComponent`. If it contains `/`, `\`, `..`,
    /// NUL, control characters, or whitespace, those characters
    /// become path separators or are otherwise filename-injurious -
    /// producing files in the parent directory, escaping the temp
    /// sandbox, or overwriting unrelated state. The function
    /// therefore validates `address` against `QuantumCoinAddress.isValid`
    /// FIRST. On invalid input it falls back to a CSPRNG-derived
    /// placeholder ("invalid-<8 hex bytes>") so the function still
    /// returns a usable filename rather than throwing - which keeps
    /// the API shape unchanged and surfaces the failure as a
    /// "wrong filename" rather than a crash. The fallback contains
    /// no attacker-controlled bytes by construction.
    /// All call sites that use the returned value SHOULD additionally
    /// pre-validate (`guard QuantumCoinAddress.isValid(addr) else { ... }`)
    /// so the user sees a clear error rather than a placeholder
    /// filename. The placeholder is the floor-of-safety, not the
    /// happy path.
    public static func buildFilename(address: String) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd'T'HH-mm-ss.SSS'Z'"
        df.timeZone = TimeZone(identifier: "UTC")
        let ts = df.string(from: Date())
        let hex: String
        if QuantumCoinAddress.isValid(address) {
            hex = Self.stripHexPrefix(address)
        } else {
            // Path-traversal / filename-injection floor of safety.
            // Reaching this branch means a caller forgot to pre-validate;
            // we return a benign placeholder rather than splatting
            // attacker input into a file path.
            hex = "invalid-\(Self.shortRandomHex)"
        }
        return "UTC--\(ts)--\(hex).\(fileExtension)"
    }

    private static func stripHexPrefix(_ s: String) -> String {
        s.hasPrefix("0x") ? String(s.dropFirst(2)) : s
    }

    /// `byteCount * 2` hex characters from the SecureRandom
    /// wrapper. Used by `buildFilename` (4-byte fallback suffix
    /// on validation failure) and `exportWalletFile` (8-byte
    /// staging-dir suffix). On RNG failure (extremely rare)
    /// falls back to a timestamp-derived value rather than
    /// zeros so two near-instant calls do not collide on the
    /// same filename.
    /// Routed through the throwing
    /// `SecureRandom.byteArray(_:)` wrapper. The bytes here are
    /// not secret (they only suffix an on-device tempfile name)
    /// so on RNG failure we degrade to a timestamp-based tag
    /// rather than aborting the backup. The decision to swallow
    /// the throw lives at this call site, in plain sight, so a
    /// reviewer can verify it without reading
    /// `Crypto/SecureRandom.swift`. Direct calls to
    /// `SecRandomCopyBytes` are forbidden anywhere outside that
    /// file (build-blocking lint).
    private static func shortRandomHex(byteCount: Int = 4) -> String {
        let n = max(1, byteCount)
        var bytes: [UInt8]
        if let drawn = try? SecureRandom.byteArray(n) {
            bytes = drawn
        } else {
            bytes = [UInt8](repeating: 0, count: n)
            let now = UInt64(Date.timeIntervalSinceReferenceDate * 1000)
            withUnsafeBytes(of: now.littleEndian) { buf in
                for (i, b) in buf.enumerated() where i < bytes.count { bytes[i] = b }
            }
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Extract the file's self-declared `address` field.
    /// hardening: this is UNTRUSTED INPUT. Even though
    /// the file was just chosen by the user via the document picker,
    /// the file's contents are attacker-controlled (the user might
    /// have downloaded a malicious `.wallet` from any source). The
    /// extracted value is therefore validated with
    /// `QuantumCoinAddress.isValid` BEFORE being returned, so any
    /// downstream consumer that forgets to pre-validate still sees a
    /// shape-valid address (or `nil`).
    /// The extracted value is the file's CLAIM about which address it
    /// holds. The CLAIM is not trusted as identity - `RestoreFlow`
    /// re-derives the address from the recovered key (see /// RestoreFlow.swift) and rejects the restore on mismatch. The
    /// shape check here is purely the path-traversal floor.
    public static func extractAddress(fromEncryptedJson json: String) -> String? {
        guard let data = json.data(using: .utf8),
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let raw = obj["address"] as? String
        else { return nil }
        let prefixed = raw.hasPrefix("0x") ? raw : "0x" + raw
        // Reject before forwarding. The fallback is
        // `nil`, which the caller (RestoreFlow.loadCandidate) already
        // treats as "this file is not a valid candidate".
        return QuantumCoinAddress.normalized(prefixed)
    }

    // MARK: - File export (one-shot)

    public func exportWalletFile(address: String, walletJson: String, from vc: UIViewController) {
        // (notes):
        // primary defense is the entry path - `RestoreFlow` /
        // `BackupExporter` should never call this with an address
        // that fails `QuantumCoinAddress.isValid`. We re-validate here
        // as defense-in-depth so a future call site that forgets to
        // pre-validate cannot land an attacker-controlled string
        // into `tmp/` via path-component injection.
        guard QuantumCoinAddress.isValid(address) else {
            Toast.showError(Localization.shared.getBackupFailedByLangValues())
            return
        }

        // Stage the file inside a CSPRNG-named
        // subdirectory of `tmp/` so leftover files from a previous
        // export-then-killed flow do not collide with this one and
        // so the staged path is not enumerable by any sibling app
        // that knows the address-and-timestamp shape. The visible
        // filename inside the picker keeps its
        // `UTC--{ts}--{addr}.wallet` shape (so the user sees the
        // expected name when iOS asks where to save), which is
        // achieved by putting the random component in the parent
        // directory rather than the leaf name.
        let stagingDirName = Self.stagingDirPrefix + Self.shortRandomHex(byteCount: 8)
        let stagingDir = FileManager.default.temporaryDirectory
        .appendingPathComponent(stagingDirName, isDirectory: true)
        let tmp = stagingDir.appendingPathComponent(
            Self.buildFilename(address: address))
        do {
            try FileManager.default.createDirectory(
                at: stagingDir,
                withIntermediateDirectories: true,
                // Writing under
                // `.completeFileProtection` means the file is
                // unreadable while the device is locked. The
                // user already had to unlock the device to start
                // an export, so this is the strongest available
                // protection class without breaking the flow.
                attributes: [.protectionKey: FileProtectionType.complete])
            try Data(walletJson.utf8).write(
                to: tmp,
                options: [.atomic, .completeFileProtection])
        } catch {
            // Best-effort cleanup if directory was partially created.
            try? FileManager.default.removeItem(at: stagingDir)
            Toast.showError(Localization.shared.getBackupFailedByLangValues())
            return
        }
        // Track for `cleanupStagedExport`. Both completion paths
        // (didPick + cancelled) call cleanup; the launch-time sweeper
        // is the safety net for app-killed-mid-export.
        stagedExportURL = tmp
        stagedExportDir = stagingDir

        let picker = UIDocumentPickerViewController(forExporting: [tmp])
        // Wire the delegate so we hear about save / cancel and can show
        // the completion toast. Without this the picker dismisses
        // silently and any success path is invisible to the user.
        picker.delegate = self
        exportPickerActive = true
        presentPicker(picker, from: vc)
    }

    /// Delete the staged export directory.
    /// Idempotent - safe to call from both the success and cancel
    /// paths. Errors are intentionally swallowed because the launch-
    /// time sweeper (`cleanupStaleStagedExports`) is the secondary
    /// safety net.
    private func cleanupStagedExport() {
        if let dir = stagedExportDir {
            try? FileManager.default.removeItem(at: dir)
        }
        stagedExportURL = nil
        stagedExportDir = nil
    }

    /// Launch-time sweeper. The picker delegates
    /// reliably fire when the app is alive, but if iOS killed the
    /// app between `exportWalletFile` and the user's pick (memory
    /// pressure, force-quit, OS update reboot), the staging
    /// directory persists. This sweeper enumerates every
    /// `qcw-backup-*` directory inside `tmp/` and removes it.
    /// Called from `AppDelegate.application(_:didFinishLaunchingWithOptions:)`.
    /// Safe to call from any thread; the operation is read+rm on tmp
    /// only, which is the app's own sandboxed directory.
    public func cleanupStaleStagedExports() {
        let tmpDir = FileManager.default.temporaryDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: tmpDir, includingPropertiesForKeys: nil
        ) else { return }
        for entry in entries
        where entry.lastPathComponent.hasPrefix(Self.stagingDirPrefix) {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    // MARK: - Folder picker (persisted bookmark)

    public func presentFolderPicker(from vc: UIViewController,
        completion: @escaping (Bool) -> Void) {
        folderPickerHost = vc
        folderPickerCompletion = completion
        // iOS analog of Android's `Intent.ACTION_OPEN_DOCUMENT_TREE`.
        // We can't relabel the system "Open" button (Apple's HIG), but
        // we can make the picker land somewhere familiar (the user's
        // Documents directory; iCloud Drive is one tap away from the
        // sidebar) and surface file extensions so the user can confirm
        // they're inside a real folder rather than picking a file.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        // Prefer iCloud Drive's well-known on-device root so users land
        // straight in their iCloud folder; fall back to the app's
        // Documents directory when iCloud is not signed in (e.g. on
        // Simulator or new devices). UIKit silently ignores an
        // unreachable directoryURL, so the existence check is purely
        // to avoid a no-op assignment.
        // This fallback uses the app's *own* sandbox
        // Documents/ as a starting display directory for the picker
        // ONLY. Documents/ continues to exist inside the sandbox for
        // this purpose; what does is set
        // `UIFileSharingEnabled = false` and
        // `LSSupportsOpeningDocumentsInPlace = false` so the
        // directory is not exposed to iTunes / Finder / Files.
        // The picker can still navigate to / from it; an external
        // observer (USB sync, file-provider sandbox) cannot.
        // Prefer the last-used backup folder (persisted security-scoped
        // bookmark) so the restore picker reopens where the user last
        // saved/restored, matching Android's `EXTRA_INITIAL_URI` seeded
        // from the shared `CLOUD_BACKUP_FOLDER_URI` pref. Fall back to
        // iCloud Drive / Documents when no bookmark resolves.
        let fm = FileManager.default
        if let remembered = resolveBookmark() {
            picker.directoryURL = remembered
        } else {
            let iCloud = URL(
                fileURLWithPath: "/var/mobile/Library/Mobile Documents/com~apple~CloudDocs",
                isDirectory: true)
            if fm.fileExists(atPath: iCloud.path) {
                picker.directoryURL = iCloud
            } else if let docs = try? fm.url(
                for: .documentDirectory, in: .userDomainMask,
                appropriateFor: nil, create: false) {
                picker.directoryURL = docs
            }
        }
        picker.delegate = self
        presentPicker(picker, from: vc)
    }

    /// Cloud-backup outcome enum returned from `writeWalletFile`.
    /// Replaces the previous `URL?` return shape so the caller
    /// can distinguish:
    /// What it closes
    ///   The historical caller fired the green "backup saved"
    ///   toast immediately after `writeWalletFile` returned a
    ///   non-nil URL, even when the destination was an iCloud
    ///   Drive folder where the LOCAL write completed but the
    ///   iCloud upload had not yet started (let alone
    ///   finished). The iOS file-coordinator hands the URL back
    ///   to the app the moment the local file is written; iCloud
    ///   Drive's File Provider extension then performs the
    ///   asynchronous network upload in the background. A user
    ///   who saw the green toast and immediately uninstalled the
    ///   app, lost the device, or suffered a power loss could end
    ///   up with the toast having lied — the on-device file would
    ///   be the only durable copy and any local failure would
    ///   take the backup with it. The new enum surfaces this
    ///   distinction so the caller can present a modal
    ///   "submitted, not yet uploaded" dialog for iCloud
    ///   destinations and the existing toast for local
    ///   destinations.
    /// Why this shape
    ///   - Three cases (local-completed, cloud-submitted, failed)
    ///     instead of a `Bool isCloud` flag because the failure
    ///     path is part of the same control flow and folding it
    ///     into either bucket would force the caller to special-
    ///     case the URL == nil pathway again.
    ///   - The URL is carried inside the success cases so the
    ///     caller can format the user-visible message
    ///     ("Submitted to: <folder>/<file>") without re-querying
    ///     the file system.
    /// Tradeoffs
    ///   - The detection heuristic (`URLResourceKey.isUbiquitousItemKey`)
    ///     can fail to populate on an unusual file provider; we
    ///     fail safe by treating a missing key as `local` (no
    ///     iCloud-warning dialog). The alternative — assume
    ///     iCloud — would surface the warning dialog on every
    ///     non-iCloud Files-app target and train the user to
    ///     dismiss it.
    /// Cross-references
    ///   - `BackupExporter.reencryptAndExport`: switches on this
    ///     outcome and routes the iCloud branch through the
    ///     `BackupSubmittedToCloudDialog`.
    ///   - `BackupSubmittedToCloudDialog`: the modal that the
    ///     `submittedToCloud` outcome triggers.
    public enum BackupWriteOutcome {
        /// The destination is local (Files app, external drive,
        /// app sandbox folder). The local write is fully
        /// completed; the existing green success toast is the
        /// correct user signal.
        case completedLocal(URL)
        /// The destination is an iCloud Drive URL. The local
        /// staging file write has been verified, but iCloud
        /// upload is asynchronous and has NOT yet completed.
        /// Callers MUST surface a distinct user-visible signal
        /// (modal dialog) so the user does not assume a
        /// fully-durable backup yet exists.
        case submittedToCloud(URL)
        /// The write failed (no folder bookmark, write threw,
        /// byte-compare mismatch). An error toast was already
        /// shown by the writer.
        case failed
    }

    /// Write `walletJson` into the user's cloud-folder bookmark.
    /// Returns a `BackupWriteOutcome` enum so the caller can
    /// distinguish the three end states (see the `BackupWriteOutcome`
    /// doc comment for the design rationale).
    /// What it closes:
    ///   The historical shape was a fire-and-forget
    ///   `Data.write(to: options: [.atomic])` followed by an
    ///   immediate success toast. That gave the user a green
    ///   "backup saved" signal without ever observing whether the
    ///   bytes that landed on disk match the bytes the JS bridge
    ///   produced. A silent NAND bit-flip during the write window,
    ///   a partial filesystem write on a near-full iCloud Drive,
    ///   or a security-scoped-resource race with the iCloud daemon
    ///   could each leave a corrupt `.wallet` file the user will
    ///   only discover at restore time — by which point the
    ///   strongbox may have moved on and the original seed is gone.
    /// Why this shape (uncached re-read + byte-compare):
    ///   `[.atomic]` does the rename-in-place, but it does NOT
    ///   read the staged bytes back. We re-read with `[.uncached]`
    ///   so the read goes through the OS's page-cache flush
    ///   boundary (the same discipline `AtomicSlotWriter` uses for
    ///   the on-device strongbox) and byte-compare against the
    ///   bytes the JS bridge produced. On mismatch we delete the
    ///   corrupt file (best-effort) and return `.failed` so the
    ///   caller surfaces the error toast instead of the success path.
    /// Tradeoffs:
    ///   Adds one uncached re-read + Data == Data over the
    ///   .wallet file (typically a few KiB). User-perceived
    ///   backup latency goes up by ~5-50 ms on iCloud Drive
    ///   targets. Acceptable — the alternative is a silent
    ///   "restored backup is corrupt" surprise.
    /// Cross-references:
    ///   - `AtomicSlotWriter.writeAndVerifyBytes` for the same
    ///     discipline applied to the on-device strongbox slot
    ///     files (which already byte-compare via the codec's
    ///     deep-verify closure).
    public func writeWalletFile(address: String,
        walletJson: String) -> BackupWriteOutcome {
        guard let folderURL = resolveBookmark() else {
            Toast.showError(Localization.shared.getBackupFailedByLangValues())
            return .failed
        }
        let ok = folderURL.startAccessingSecurityScopedResource()
        defer { if ok { folderURL.stopAccessingSecurityScopedResource() } }
        let file = folderURL.appendingPathComponent(Self.buildFilename(address: address))
        let expected = Data(walletJson.utf8)
        do {
            try expected.write(to: file, options: [.atomic])
            // Read-back-and-byte-compare. [.uncached] forces the
            // OS to traverse the page-cache flush boundary so an
            // in-cache copy that didn't actually land on flash
            // surfaces as a short / zero read here, not at restore
            // time on another device.
            let staged = try Data(contentsOf: file, options: [.uncached])
            guard staged == expected else {
                // Best-effort cleanup so we don't leave a corrupt
                // .wallet file the user might later try to restore.
                try? FileManager.default.removeItem(at: file)
                Toast.showError(Localization.shared.getBackupFailedByLangValues())
                return .failed
            }
// detect whether the destination URL is
            // iCloud-managed by querying the
            // `URLResourceKey.isUbiquitousItemKey` resource value.
            // The `URLResourceValues.isUbiquitousItem` accessor
            // returns `true` for any item managed by the iCloud
            // file provider (iCloud Drive, plus third-party
            // ubiquity providers). On a missing / unsupported
            // attribute we fail SAFE to `false` so non-iCloud
            // destinations (local Files app, external drive,
            // app sandbox folder) keep the existing success-toast
            // behaviour. The dialog is reserved for cases where
            // we have positive evidence the destination is
            // iCloud-managed; if we don't know, we don't warn.
            let resKeys: Set<URLResourceKey> = [.isUbiquitousItemKey]
            let isUbiquitous: Bool
            do {
                let values = try file.resourceValues(forKeys: resKeys)
                isUbiquitous = values.isUbiquitousItem ?? false
            } catch {
                isUbiquitous = false
            }
            return isUbiquitous ? .submittedToCloud(file) : .completedLocal(file)
        } catch {
            Toast.showError(Localization.shared.getBackupFailedByLangValues())
            return .failed
        }
    }

    public func listWalletFiles() -> [URL] {
        guard let folderURL = resolveBookmark() else { return [] }
        let ok = folderURL.startAccessingSecurityScopedResource()
        defer { if ok { folderURL.stopAccessingSecurityScopedResource() } }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension.lowercased() == Self.fileExtension }
    }

    public func presentRestorePicker(from vc: UIViewController,
        completion: @escaping ([URL]) -> Void) {
        restorePickerHost = vc
        restorePickerCompletion = completion
        let types: [UTType] = [
            UTType(filenameExtension: "wallet") ?? .data,
            .data
        ]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        presentPicker(picker, from: vc)
    }

    // MARK: - Picker presentation with loader

    /// Show a `WaitDialogViewController` immediately on `host`, then
    /// present `picker` on top once the wait dialog finishes its
    /// presentation animation. `UIDocumentPickerViewController(forOpening:
    /// [.folder])` and the export / restore pickers all take a
    /// noticeable beat to spin up (especially when iCloud Drive is
    /// being scanned), and the user previously saw nothing at all
    /// during that gap. The wait dialog stays parked underneath the
    /// picker for the duration; the `UIDocumentPickerDelegate` callbacks
    /// dismiss it after the picker tears down so the host VC is
    /// restored to a clean state.
    private func presentPicker(_ picker: UIDocumentPickerViewController,
        from host: UIViewController) {
        let wait = WaitDialogViewController(
            message: Localization.shared.getWaitOpeningPickerByLangValues())
        pickerLoadingDialog = wait
        host.present(wait, animated: true) { [weak wait] in
            guard let wait = wait else { return }
            wait.present(picker, animated: true)
        }
    }

    /// Tear down the loading wait dialog after the picker dismisses.
    /// `animated: false` because the picker has already played its own
    /// dismissal animation; animating the wait dialog out would briefly
    /// re-expose its scrim and look like a flash.
    private func dismissPickerLoadingDialog() {
        guard let wait = pickerLoadingDialog else { return }
        pickerLoadingDialog = nil
        wait.dismiss(animated: false)
    }

    // MARK: - Bookmark persistence

    private func resolveBookmark() -> URL? {
        let b64 = PrefConnect.shared.readString(PrefKeys.CLOUD_BACKUP_FOLDER_URI_KEY)
        guard !b64.isEmpty, let data = Data(base64Encoded: b64) else { return nil }
        var stale = false
        let url = try? URL(resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale)
        if stale { return nil }
        return url
    }

    private func persistBookmark(_ url: URL) {
// the original was
        // `let ok = url.startAccessingSecurityScopedResource`
        // which captures the *method reference* WITHOUT
        // invoking it. The defer then called
        // `ok()`, meaning the resource was started in the
        // defer (right before stop) and never actually
        // accessed during the bookmark read. iCloud / external
        // provider URLs returned from UIDocumentPicker MUST
        // have `startAccessingSecurityScopedResource()`
        // invoked synchronously before any read (per Apple's
        // file-coordinator contract); without this, providers
        // such as iCloud Drive return EPERM on `bookmarkData`
        // and the cloud-folder bookmark silently fails to
        // persist. The corrected pattern starts the access
        // immediately and stops it in the defer.
        let started = url.startAccessingSecurityScopedResource()
        defer {
            if started {
                url.stopAccessingSecurityScopedResource()
            }
        }
        guard let data = try? url.bookmarkData(options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil) else { return }
        do {
            try PrefConnect.shared.writeString(
                PrefKeys.CLOUD_BACKUP_FOLDER_URI_KEY,
                data.base64EncodedString())
        } catch {
            Logger.warn(category: "PREFS_FLUSH_FAIL",
                "CLOUD_BACKUP_FOLDER_URI: \(error)")
        }
    }
}

extension CloudBackupManager: UIDocumentPickerDelegate {

    public func documentPicker(_ controller: UIDocumentPickerViewController,
        didPickDocumentsAt urls: [URL]) {
        // Tear down the loader BEFORE running completion callbacks so
        // any follow-on UI (toast, batched-restore wait dialog, etc.)
        // presents from a clean host VC instead of stacking on top of
        // the soon-to-be-dismissed loader.
        dismissPickerLoadingDialog()
        // Branch on `exportPickerActive` *first*. Without this the
        // export's destination URL would fall through to the
        // folder-picker branch below and `persistBookmark(url)` would
        // overwrite the cloud-folder bookmark with the just-saved
        // file's URL, breaking subsequent cloud writes.
        if exportPickerActive {
            exportPickerActive = false
            if let url = urls.first {
                Toast.showMessage(Self.formatBackupSavedMessage(forURL: url))
            } else {
                Toast.showMessage(Localization.shared.getBackupSavedShortByLangValues())
            }
            // Remove the staged file from `tmp/`
            // now that the user has either saved a copy elsewhere
            // or otherwise consumed the export. Best-effort; the
            // launch-time sweeper handles any path that bypasses
            // this delegate (e.g. iOS killed the app mid-export).
            cleanupStagedExport()
            return
        }
        if controller.allowsMultipleSelection {
            restorePickerCompletion?(urls)
            restorePickerCompletion = nil
            return
        }
        // Folder picker
        guard let url = urls.first else {
            folderPickerCompletion?(false); folderPickerCompletion = nil; return
        }
        persistBookmark(url)
        folderPickerCompletion?(true)
        folderPickerCompletion = nil
    }

    public func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        dismissPickerLoadingDialog()
        if exportPickerActive {
            exportPickerActive = false
            // Cancelled exports leave a staged file
            // in `tmp/` that the user explicitly chose NOT to save.
            // Removing it on cancel is more important than on success
            // (success means a copy reached its destination; cancel
            // means the staged file is the ONLY copy and lingering
            // it would silently retain data the user said no to).
            cleanupStagedExport()
            return
        }
        folderPickerCompletion?(false); folderPickerCompletion = nil
        restorePickerCompletion?([]); restorePickerCompletion = nil
    }

    // MARK: - Toast formatting

    /// Substitute `[FOLDER]` / `[FILENAME]` placeholders in the
    /// `backup-saved` localized template with the destination URL's
    /// parent-directory name and file name. Used by both the
    /// file-export delegate path and the cloud-folder write path so
    /// the two toasts read identically.
    static func formatBackupSavedMessage(forURL url: URL) -> String {
        let folder = url.deletingLastPathComponent().lastPathComponent
        let filename = url.lastPathComponent
        return Localization.shared.getBackupSavedByLangValues()
        .replacingOccurrences(of: "[FOLDER]", with: folder)
        .replacingOccurrences(of: "[FILENAME]", with: filename)
    }

    /// Substitute `[FOLDER]` / `[FILENAME]` placeholders in the
    /// `backup-submitted-cloud-message` localized template with
    /// the destination URL's parent-directory name and file name.
    /// What it closes:
    ///   The previous green success toast for cloud destinations
    ///   used the same wording as the local-export toast, which
    ///   incorrectly suggested the backup was already durably
    ///   stored in iCloud. The local write completes
    ///   synchronously, but the iCloud upload happens
    ///   asynchronously through the iOS File Provider extension
    ///   and may still be in flight (or queued) when the toast
    ///   appears. A user who acts on the false success signal —
    ///   uninstalls the app, wipes the device, suffers a power
    ///   loss / loses the device — can be left with no
    ///   recoverable backup.
    /// Why this shape:
    ///   Building this as a static helper on
    ///   `CloudBackupManager` keeps the two formatters
    ///   (local-saved vs cloud-submitted) co-located so future
    ///   localization changes stay in one place. The dialog
    ///   text explicitly tells the user the upload is NOT yet
    ///   complete and instructs them to keep the device powered
    ///   on / connected and to verify in the Files app.
    /// Tradeoffs:
    ///   The longer message text is intentionally verbose so
    ///   the user understands the semantics ("submitted, not
    ///   yet uploaded") rather than just dismissing a generic
    ///   "OK" prompt.
    /// Cross-references:
    ///   - `BackupExporter.reencryptAndExport` — switches on
    ///     the `BackupWriteOutcome` enum and routes the
    ///     `submittedToCloud` case through this formatter +
    ///     `MessageInformationDialogViewController`.
    static func formatBackupSubmittedToCloudMessage(forURL url: URL) -> String {
        let folder = url.deletingLastPathComponent().lastPathComponent
        let filename = url.lastPathComponent
        return Localization.shared.getBackupSubmittedCloudMessageByLangValues()
        .replacingOccurrences(of: "[FOLDER]", with: folder)
        .replacingOccurrences(of: "[FILENAME]", with: filename)
    }
}
