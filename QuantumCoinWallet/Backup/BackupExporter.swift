// BackupExporter.swift
// Shared helper used by both first-time onboarding
// (`HomeWalletViewController.encryptAndExportBackup`) and the
// Wallets-list backup flow (`BackupOptionsViewController`). Given a
// plaintext seed-phrase, an address, and a backup password, encrypts
// the wallet via `JsBridge` and hands it off to `CloudBackupManager`
// for the file export.
// Lifting this out into a single function ensures the two callers stay
// in lockstep: any change to the encryption envelope shape, error
// messaging, or wait-dialog wording happens in one place rather than
// drifting between onboarding and Wallets-list.
// Android references:
// HomeWalletFragment.startFileBackupFromOptionsScreen

import UIKit

/// Recovery material handed to `BackupExporter.reencryptAndExport`.
/// Mirrors the two-branch shape of Android
/// `CloudBackupManager.encryptWallet`: if the wallet has a seed
/// phrase, the export rides the `seedWords` branch of
/// `bridge.html#encryptWalletJson`; if it is a key-only wallet
/// (`hasSeed == false`, no recoverable BIP39 phrase) the raw
/// signing-key bytes are staged on the binary channel and the
/// bridge rides the `fromBinaryKeys` branch. Both branches
/// produce an interoperable `.wallet` envelope.
public enum BackupExportPayload {
    case seedWords([String])
    case keys(privateKey: Data, publicKey: Data)
}

public enum BackupExporter {

    /// Re-encrypt the wallet's recovery material under
    /// `backupPassword` and hand the result off to
    /// `CloudBackupManager.exportWalletFile` (share-sheet file export).
    /// Presents a `WaitDialog` while the bridge runs and a toast /
    /// error toast on completion. All UI work happens on the main
    /// actor; the encryption itself runs on a detached task because the
    /// JS bridge `encryptWalletJson` blocks on a `WKWebView` round-trip.
    public static func reencryptAndExport(
        payload: BackupExportPayload,
        address: String,
        backupPassword: String,
        presenter: UIViewController
    ) {
        switch payload {
            case .seedWords(let words):
            guard !words.isEmpty else {
                Toast.showError(Localization.shared.getBackupFailedByLangValues())
                return
            }
            case .keys(let priv, let pub):
            guard !priv.isEmpty, !pub.isEmpty else {
                Toast.showError(Localization.shared.getBackupFailedByLangValues())
                return
            }
        }
        let wait = WaitDialogViewController(
            message: Localization.shared.getWaitWalletSaveByLangValues())
        presenter.present(wait, animated: true)

        Task.detached(priority: .userInitiated) { [weak presenter, weak wait] in
            var encryptedJson: String? = nil
            do {
                switch payload {
                    case .seedWords(let words):
                    let walletInputJson = encodeWalletInput(seedWords: words)
                    let envelope = try JsBridge.shared.encryptWalletJson(
                        walletInputJson: walletInputJson, password: backupPassword)
                    encryptedJson = extractEncryptedJson(envelope)
                    case .keys(let priv, let pub):
                    // Take local mutable copies so the `defer`
                    // can zeroize them the moment the bridge call
                    // returns. The bridge itself zeroes the
                    // staged binary slots in its `finally`
                    // handler (bridge.html lines 670-672); this
                    // wipe covers the Swift-side residue.
                    var privCopy = priv
                    var pubCopy = pub
                    defer {
                        privCopy.resetBytes(in: 0..<privCopy.count)
                        pubCopy.resetBytes(in: 0..<pubCopy.count)
                    }
                    let envelope = try JsBridge.shared.encryptWalletJson(
                        privateKey: privCopy, publicKey: pubCopy,
                        password: backupPassword)
                    encryptedJson = extractEncryptedJson(envelope)
                }
            } catch {
                encryptedJson = nil
            }
            let resultJson = encryptedJson
            await MainActor.run {
                wait?.dismiss(animated: true) {
                    guard let presenter = presenter, let json = resultJson else {
                        Toast.showError(Localization.shared.getBackupFailedByLangValues())
                        return
                    }
                    CloudBackupManager.shared.exportWalletFile(
                        address: address, walletJson: json, from: presenter)
                }
            }
        }
    }

    // MARK: - Bridge envelope helpers

    /// JSON-encode the `walletInput` payload that
    /// `bridge.html#encryptWalletJson` expects for the seed-words
    /// branch. The matching key-bytes branch lives behind the
    /// `JsBridge.encryptWalletJson(privateKey:publicKey:password:)`
    /// overload, which stages the bytes on the binary channel and
    /// sets `walletInput` to the `{"fromBinaryKeys":true}`
    /// discriminator directly — so this helper is only invoked
    /// from `.seedWords` payloads.
    static func encodeWalletInput(seedWords: [String]) -> String {
        let walletInput: [String: Any] = ["seedWords": seedWords]
        guard let data = try? JSONSerialization.data(withJSONObject: walletInput),
        let json = String(data: data, encoding: .utf8)
        else { return "{}" }
        return json
    }

    /// Extract the already-encrypted wallet JSON from `encryptWalletJson`'s
    /// bridge envelope. The bridge returns the payload under the key `json`
    /// (see bridge.html lines 375 / 383). The bridge sometimes returns the
    /// payload as a JSON-string and sometimes as a nested object (depending
    /// on platform); accept both shapes so the caller always gets a string.
    static func extractEncryptedJson(_ envelope: String) -> String? {
        guard let data = envelope.data(using: .utf8),
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let inner = obj["data"] as? [String: Any]
        else { return nil }
        if let s = inner["json"] as? String { return s }
        if let o = inner["json"] as? [String: Any],
        let d = try? JSONSerialization.data(withJSONObject: o),
        let s = String(data: d, encoding: .utf8) { return s }
        return nil
    }

    /// Note: previously this file exposed
    /// `extractSeedWords(fromDecryptEnvelope:)` and
    /// `extractRecoveredAddress(fromDecryptEnvelope:)` which parsed
    /// `JsBridge.decryptWalletJson`'s legacy JSON envelope.
    /// That helper was moved into `JsBridge.WalletEnvelope`
    /// (a Swift struct with `Data`-typed key material), so callers
    /// now read `.seedWords` / `.address` directly off the
    /// envelope without parsing JSON, and the binary key bytes
    /// can be `resetBytes`-zeroized as soon as they leave scope.
}
