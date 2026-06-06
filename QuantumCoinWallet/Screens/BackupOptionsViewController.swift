// BackupOptionsViewController.swift
// Full-screen Backup Options surface launched from the Wallets list
// when the user taps the blue Backup tile next to a row. Mirrors the
// chrome of `HomeWalletViewController.renderBackupOptions` (back bar +
// title + description + rule + File) so the flow visually matches the
// first-time onboarding "backup options" screen rather than appearing
// as a modal action sheet.
// Mechanics match the first-time pipeline through `BackupExporter`:
// 1. `UnlockDialogViewController` -> validate the strongbox password.
// 2. `Strongbox.seedWords(at:)` (raw seed phrase straight from
//    the unlocked snapshot — no per-wallet envelope to unwrap)
// to recover the seed phrase for the chosen wallet.
// 3. `BackupPasswordDialog` -> collect a fresh backup password.
// 4. `BackupExporter.reencryptAndExport` -> re-encrypt under the new
// password and hand off to the share sheet for the file export.
// Android references:
// WalletsFragment.onWalletExportClick (unlock first, then choose)
// HomeWalletFragment.showBackupOptionsScreen (UI parity)

import UIKit

public final class BackupOptionsViewController: UIViewController,
HomeScreenViewTypeProviding {

    public var screenViewType: ScreenViewType { .innerFragment }

    private let walletIndex: Int
    private let contentStack = UIStackView()

    public init(walletIndex: Int) {
        self.walletIndex = walletIndex
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(named: "colorBackground") ?? .systemBackground

        contentStack.axis = .vertical
        contentStack.spacing = 14
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let scroll = UIScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(contentStack)
        view.addSubview(scroll)

        NSLayoutConstraint.activate([
                scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                scroll.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
                contentStack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
                contentStack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
                contentStack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
                contentStack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
                contentStack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40)
            ])

        renderBackupOptions()

        // Apply alpha-dim press feedback to back arrow + the
        // primary action button (File).
        view.installPressFeedbackRecursive()
    }

    private func renderBackupOptions() {
        let L = Localization.shared
        let backBar = makeBackBar()
        let title = makeTitle(L.getBackupOptionsTitleByLangValues())
        let body = makeBody(L.getBackupOptionsDescriptionByLangValues())

        let file = makePrimaryButton(L.getBackupToFileByLangValues())
        file.addTarget(self, action: #selector(tapBackupFile), for: .touchUpInside)

        // No trailing "Next" / "Done" pill on this surface. The user
        // reached this screen from the already-unlocked Wallets list,
        // so the only meaningful actions are File (which has its own
        // UnlockDialog + completion hand-off) or the back arrow. The
        // post-create wallet onboarding flow
        // (`HomeWalletViewController.renderBackupOptions`) keeps its
        // Next pill because that surface still has a "continue to
        // home" step after backup.
        [backBar, title, body, makeRule(), file]
        .forEach { contentStack.addArrangedSubview($0) }
    }

    // MARK: - Actions

    @objc private func tapBackupFile() {
        runBackupFlow()
    }

    @objc private func tapBackBar() {
        (parent as? HomeViewController)?.showWallets()
    }

    // MARK: - File pipeline

    /// Step 1 of the export pipeline: present `UnlockDialogViewController`
    /// to validate the strongbox password. On success, decrypt the slot's
    /// wallet JSON to recover the seed phrase, then chain into the
    /// backup-password dialog. The unlock + scrypt + decrypt round-trip
    /// can take several seconds, so a `WaitDialogViewController` is
    /// presented over the unlock dialog with `getWaitUnlockByLangValues`
    /// while the work runs - mirroring the pattern used by
    /// `HomeWalletViewController.presentUnlockThen`. Wrong strongbox
    /// password leaves the unlock dialog up with the same inline error
    /// + cleared field UX used by `WalletsViewController.revealWallet`.
    private func runBackupFlow() {
        let dlg = UnlockDialogViewController()
        dlg.onUnlock = { [weak self, weak dlg] strongboxPassword in
            guard let self = self, let dlg = dlg else { return }
            if strongboxPassword.isEmpty {
                dlg.showOrangeError(Localization.shared.getEmptyPasswordByErrors())
                return
            }
            let wait = WaitDialogViewController(
                message: Localization.shared.getWaitUnlockByLangValues())
            dlg.present(wait, animated: true)
            let walletIndex = self.walletIndex
            Task.detached(priority: .userInitiated) { [weak self, weak dlg, weak wait] in
                var result: Result<(payload: BackupExportPayload, address: String), Error> =
                .failure(UnlockCoordinatorV2Error.decodeFailed)
                do {
                    // Unlock (or re-verify) under the user's
                    // password — re-derives mainKey, applies
                    // session, and routes failures through the
                    // shared `UnlockAttemptLimiter`. Once it
                    // returns, the wallet's raw recovery material
                    // is available directly from the unlocked
                    // snapshot; no nested per-wallet envelope to
                    // unwrap.
                    try UnlockCoordinatorV2.unlockWithPasswordAndApplySession(strongboxPassword)
                    let address = Strongbox.shared.address(forIndex: walletIndex) ?? ""
                    // Mirror Android `CloudBackupManager.encryptWallet`:
                    // wallets that carry a recoverable BIP39 phrase
                    // export via the seed-words branch; key-only
                    // wallets (`hasSeed == false`, imported via
                    // `walletFromKeys`) export via the
                    // private/public-key bytes branch. The pre-
                    // existing iOS shape conflated "no seed" with
                    // "wrong password" and threw `decodeFailed` here,
                    // which the catch surfaced as the orange
                    // wallet-password-mismatch alert even though
                    // the strongbox had just unlocked under the
                    // user's correct password.
                    let exportPayload: BackupExportPayload
                    if Strongbox.shared.hasSeed(at: walletIndex) == true,
                    let seedJoined = Strongbox.shared.seedWords(at: walletIndex),
                    !seedJoined.isEmpty {
                        let words = seedJoined.split(separator: ",").map(String.init)
                        guard !words.isEmpty else {
                            throw UnlockCoordinatorV2Error.decodeFailed
                        }
                        exportPayload = .seedWords(words)
                    } else if let priv = Strongbox.shared.privateKey(at: walletIndex),
                    let pub = Strongbox.shared.publicKey(at: walletIndex),
                    !priv.isEmpty, !pub.isEmpty {
                        exportPayload = .keys(privateKey: priv, publicKey: pub)
                    } else {
                        // Snapshot loaded but neither seed nor raw
                        // keys are present at this slot - the
                        // strongbox payload is malformed. Keep the
                        // historical `decodeFailed` so the catch
                        // routes through the wallet-password-mismatch
                        // alert; this branch is unreachable under
                        // the strongbox write invariants.
                        throw UnlockCoordinatorV2Error.decodeFailed
                    }
                    result = .success((exportPayload, address))
                } catch {
                    result = .failure(error)
                }
                let final = result
                await MainActor.run {
                    wait?.dismiss(animated: true) {
                        switch final {
                            case .success(let payload):
                            dlg?.dismiss(animated: true) {
                                self?.promptBackupPasswordAndExport(
                                    payload: payload.payload,
                                    address: payload.address)
                            }
                            case .failure(let err):
                            // Wrong-password branch: orange OK alert
                            // layered on top of the unlock dialog;
                            // typed password preserved (no
                            // `clearField`).
                            // Distinguish brute-
                            // force lockout from regular wrong-
                            // password.
                            if let uc = err as? UnlockCoordinatorV2Error,
                            case let .tooManyAttempts(seconds) = uc {
                                dlg?.showOrangeError(
                                    UnlockAttemptLimiter
                                    .userFacingLockoutMessage(
                                        remainingSeconds: seconds))
                            } else {
                                dlg?.showOrangeError(
                                    Localization.shared.getWalletPasswordMismatchByErrors())
                            }
                        }
                    }
                }
            }
        }
        present(dlg, animated: true)
    }

    /// Step 2 of the export pipeline: collect the user's chosen backup
    /// password, then delegate to `BackupExporter` for the re-encrypt
    /// + share-sheet hand-off. `payload` carries either the seed phrase
    /// (`.seedWords`) or the raw signing-key bytes (`.keys`) - the
    /// exporter picks the matching `bridge.html` branch.
    private func promptBackupPasswordAndExport(payload: BackupExportPayload,
        address: String) {
        // Pass `address` so the dialog's hidden `.username` field
        // can scope the iOS Keychain Save prompt to a per-wallet
        // slot (see `CredentialIdentifier.backupUsername(address:)`),
        // preventing this Save from overwriting another wallet's
        // backup credential or the strongbox credential.
        let dlg = BackupPasswordDialog(mode: .create(address: address))
        dlg.onSubmit = { [weak self, weak dlg] backupPwd in
            guard let self = self else { return }
            dlg?.dismiss(animated: true) { [weak self] in
                guard let self = self else { return }
                BackupExporter.reencryptAndExport(
                    payload: payload,
                    address: address,
                    backupPassword: backupPwd,
                    presenter: self)
            }
        }
        present(dlg, animated: true)
    }

    // MARK: - Small widget factory (mirrors HomeWalletViewController)

    private func makeTitle(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = Typography.boldTitle(18)
        l.numberOfLines = 0
        return l
    }

    private func makeBody(_ text: String) -> UILabel {
        let l = UILabel()
        l.text = text
        l.font = Typography.body(13)
        l.numberOfLines = 0
        return l
    }

    private func makeRule() -> UIView {
        let line = UIView()
        line.backgroundColor = (UIColor(named: "colorCommon6") ?? .label)
        .withAlphaComponent(0.2)
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    private func makeBackBar() -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let b = UIButton(type: .custom)
        let img = UIImage(named: "arrow_back_circle_outline")?
        .withRenderingMode(.alwaysTemplate)
        b.setImage(img, for: .normal)
        b.tintColor = UIColor(named: "colorCommon6") ?? .label
        b.adjustsImageWhenHighlighted = true
        b.widthAnchor.constraint(equalToConstant: 32).isActive = true
        b.heightAnchor.constraint(equalToConstant: 32).isActive = true
        b.addTarget(self, action: #selector(tapBackBar), for: .touchUpInside)

        row.addArrangedSubview(b)
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        return row
    }

    private func makePrimaryButton(_ title: String) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = Typography.mediumLabel(15)
        b.backgroundColor = UIColor(named: "colorPrimary") ?? .systemBlue
        // `colorCommon7` is white in light mode and black in dark mode.
        // Matches the convention already used by `GreenPillButton` /
        // `GrayPillButton` so the `Backup to File` title flips to black
        // in dark mode instead of staying hard-coded white against the
        // purple pill.
        b.setTitleColor(UIColor(named: "colorCommon7") ?? .white, for: .normal)
        b.layer.cornerRadius = 10
        b.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return b
    }
}
