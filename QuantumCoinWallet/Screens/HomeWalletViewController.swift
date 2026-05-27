// HomeWalletViewController.swift
// Port of `HomeWalletFragment.java` / `home_wallet_fragment.xml` (the
// 3800-line layout with many mutually-exclusive linear layouts). iOS:
// one view controller with a `WizardStep` enum and a single child
// `UIStackView` shown at a time.
// Key rules lifted from the Android source:
// - Min password = 12 chars, no leading/trailing whitespace, confirm match.
// - Create vs Restore radio.
// - Phone backup radio writes BACKUP_ENABLED_KEY (yes=1, no=0).
// - Wallet type: Default -> keyType 3 / 32 words; Advanced -> 5 / 36.
// - Seed word length: 32 / 36 / 48 (phrase-restore only).
// - Seed verify uses BIP39Words + JsBridge.doesSeedWordExist.
// - Backup options: Cloud button shows cloud-backup-info confirmation
// before the folder picker, File button uses export-temp.
// Android reference:
// app/src/main/java/com/quantumcoinwallet/app/view/fragment/HomeWalletFragment.java
// app/src/main/res/layout/home_wallet_fragment.xml

import UIKit

public final class HomeWalletViewController: UIViewController, HomeScreenViewTypeProviding {

    public var screenViewType: ScreenViewType { .onboarding }

    public enum Step {
        case setPassword
        case createOrRestore
        case phoneBackup
        case walletType
        case seedLength
        case seedShow
        case seedVerify
        case confirmWallet
        case backupOptions
        case done
    }

    public var step: Step = .setPassword {
        didSet {
            // Re-arm the seed-reveal gate every time we leave the
            // seed-show step so the words are not auto-revealed when
            // the user comes back from elsewhere in the wizard.
            if oldValue == .seedShow && step != .seedShow {
                seedRevealed = false
            }
            render()
        }
    }

    private var chosenPassword: String = ""
    private var createNotRestore: Bool = true
    private var keyType: Int = Constants.KEY_TYPE_DEFAULT
    private var seedLength: Int = 32
    private var generatedSeed: [String] = []
    private var generatedAddress: String = ""
    private var walletIndex: Int = -1

    private var enteredRestorePhrase: [String] = []
    private var pendingWalletJson: String = ""
    private var pendingAddress: String = ""
    private var pendingSeedWords: [String] = []

    /// True once the user taps "Click here to reveal the seed words" on
    /// the seed-show step. Resets on each new `Step` so the gate re-arms
    /// if the user goes back.
    private var seedRevealed: Bool = false

    private let contentStack = UIStackView()
    /// Outer scroll view that wraps `contentStack`. Promoted to an
    /// instance property so the keyboard-avoidance observer can
    /// reach it from outside `viewDidLoad`: the bottom anchor is
    /// pinned to `view.keyboardLayoutGuide.topAnchor` so the
    /// visible content region automatically excludes the on-screen
    /// keyboard, and a `textDidBeginEditingNotification` observer
    /// scrolls the focused seed-grid cell (plus the Next button
    /// row) above the keyboard as focus auto-advances. Closes the
    /// seed-verify / restore-from-seed UX bug where the lower seed
    /// cells and Next pill sat behind the keyboard on shorter
    /// devices.
    private let scroll = UIScrollView()

    /// Hides the just-generated seed grid on
    /// `renderSeedShow` whenever the screen is being recorded /
    /// mirrored. Reset on every `render()` so the previous step's
    /// observer does not fire after the layout swap. See
    /// `ScreenCaptureGuard.swift`.
    private var seedShowCaptureGuard: ScreenCaptureGuard?

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(named: "colorBackground") ?? .systemBackground

        contentStack.axis = .vertical
        contentStack.spacing = 14
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(contentStack)
        view.addSubview(scroll)

        // Hybrid bottom-anchor pair (see file header / Issue A in
        // the keyboard-avoidance plan):
        //   - `safeBottom` (defaultHigh) keeps the scroll view's
        //     bottom edge at the safe-area bottom when the keyboard
        //     is hidden, restoring the pre-keyboard-work layout and
        //     the home-indicator gap. Contrast with the previous
        //     `equalTo: keyboardLayoutGuide.topAnchor` which, per
        //     Apple's docs, undocks to the bottom of the *view*
        //     (not the safe area) when the keyboard is offscreen
        //     and was producing a small render artifact on iOS 15
        //     simulators below the Next button.
        //   - `kbCap` (required) hard-caps the scroll view's bottom
        //     to the keyboard top whenever the keyboard is docked,
        //     so the visible content region shrinks to exclude the
        //     keyboard. Autolayout breaks `safeBottom` in favor of
        //     `kbCap` while the keyboard is up.
        let safeBottom = scroll.bottomAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        safeBottom.priority = .defaultHigh
        let kbCap = scroll.bottomAnchor.constraint(
            lessThanOrEqualTo: view.keyboardLayoutGuide.topAnchor)
        kbCap.priority = .required
        NSLayoutConstraint.activate([
                scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                safeBottom,
                kbCap,
                contentStack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 20),
                contentStack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -20),
                contentStack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 20),
                contentStack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -20),
                contentStack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -40)
            ])

        // Bring the focused text field plus the Next button row
        // above the keyboard whenever focus moves through the seed
        // grid. Without this, `SeedChipGrid.advanceFocus(after:)`
        // can hand first-responder status to a cell that the
        // shrunken scroll region cannot reach by intrinsic content
        // size alone.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTextFieldDidBeginEditing(_:)),
            name: UITextField.textDidBeginEditingNotification,
            object: nil)

        render()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Keyboard avoidance

    /// Scroll the freshly-focused text field into view. Triggered by
    /// `UITextField.textDidBeginEditingNotification` so it covers BOTH
    /// the initial tap on a seed cell AND the auto-advance hop driven
    /// by `SeedChipGrid.advanceFocus(after:)`.
    ///
    /// Seed-grid cells (`SeedAutoCompleteTextField`) only scroll the
    /// chip plus BIP39 dropdown slack into view. Android does not
    /// yank the `ScrollView` down to the Next button when A1 is
    /// focused; unioning the field with the bottom action row hid the
    /// active chip and its suggestions on restore/verify.
    ///
    /// Password fields still union the Next row so set-password steps
    /// keep the action pill above the keyboard.
    @objc private func handleTextFieldDidBeginEditing(_ note: Notification) {
        guard let field = note.object as? UITextField,
            field.isDescendant(of: scroll) else { return }
        // Defer the scroll one runloop tick so the
        // `keyboardLayoutGuide` has applied its new top anchor
        // (the guide updates synchronously with the keyboard frame
        // notification, but autolayout has not necessarily run a
        // layout pass yet when `textDidBeginEditingNotification`
        // arrives on the very first tap of the screen). Layout
        // is force-applied below so `scroll.bounds` reflects the
        // shrunken visible region before we compute the target rect.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.view.layoutIfNeeded()
            var target = field.convert(field.bounds, to: self.scroll)
            target = target.insetBy(dx: 0, dy: -8)
            if let seedField = field as? SeedAutoCompleteTextField {
                let dropdownSlack = CGFloat(seedField.maxSuggestions) * 32 + 12
                target.size.height += dropdownSlack
            } else if let actionRow = self.contentStack.arrangedSubviews.last {
                let actionRect = actionRow.convert(actionRow.bounds, to: self.scroll)
                target = target.union(actionRect)
            }
            self.scroll.scrollRectToVisible(target, animated: true)
        }
    }

    /// Reset scroll to the top when swapping wizard steps so a prior
    /// step's content offset does not leave the first seed row off-screen.
    private func resetScrollToTop() {
        let topY = -scroll.adjustedContentInset.top
        scroll.setContentOffset(CGPoint(x: 0, y: topY), animated: false)
    }

    // MARK: - Render

    private func render() {
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        resetScrollToTop()
        seedShowCaptureGuard = nil
        switch step {
            case .setPassword: renderSetPassword()
            case .createOrRestore: renderCreateOrRestore()
            case .phoneBackup: renderPhoneBackup()
            case .walletType: renderWalletType()
            case .seedLength: renderSeedLength()
            case .seedShow:
            // Two distinct UIs share `.seedShow`: the create flow's
            // gated reveal screen, and the restore flow's manual
            // SeedChipGrid entry. Routing both through this switch
            // (instead of only through the explicit Next-handler call)
            // means a back-pop into `.seedShow` (header back from
            // confirm-wallet) lands the user on the right screen and
            // preserves their typed words via `enteredRestorePhrase`.
            if createNotRestore {
                renderSeedShow()
            } else {
                startRestoreFromPhrasePrompt()
            }
            case .seedVerify: renderSeedVerify()
            case .confirmWallet: renderConfirmWallet()
            case .backupOptions: renderBackupOptions()
            case .done: finishAndRouteHome()
        }
        // Each render swaps the entire contentStack contents, so the
        // press-feedback wiring needs to be re-applied for the freshly
        // built buttons. `enablePressFeedback` is idempotent so any
        // previously-wired surface (header back arrow, etc.) stays
        // unchanged.
        contentStack.installPressFeedbackRecursive()
    }

    // MARK: - Steps

    private func renderSetPassword() {
        let L = Localization.shared
        let title = makeTitle(L.getSetWalletPasswordByLangValues())
        let hint = makeBody(L.getUseStrongPasswordByLangValues())
        // MARK: - Keychain autofill (strongbox create-wallet)
        // Pairs `.newPassword` (twice: pw + rt) with a hidden
        // `.username` carrying `CredentialIdentifier.strongboxUsername`.
        // After the user submits this step iOS may show "Save
        // Password as QuantumCoin-<deviceSuffix>?". Saving is
        // OPT-IN: dismissing the sheet writes nothing to Keychain
        // and the wallet is still created. The Keychain account
        // name is locked to strongboxUsername so a future unlock can
        // deterministically find it; allowing per-save username
        // editing would create orphaned entries that unlock could
        // never query. User-choice override: see
        // CredentialIdentifier file header.
        let usernameField = UsernameField.make(
            CredentialIdentifier.strongboxUsername)
        let pw = makeSecureField(placeholder: L.getPasswordByLangValues(), purpose: .newPassword)
        let rt = makeSecureField(placeholder: L.getRetypePasswordByLangValues(), purpose: .newPassword)
        let err = makeErrorLabel()
        let next = makeNextButton()
        next.addAction(UIAction(handler: { [weak self] _ in
                let p = pw.text
                let r = rt.text
                if p.trimmingCharacters(in: .whitespacesAndNewlines).count < Constants.MINIMUM_PASSWORD_LENGTH {
                    err.text = L.getPasswordSpecByErrors(); err.isHidden = false; return
                }
                if p != p.trimmingCharacters(in: .whitespacesAndNewlines) {
                    err.text = L.getPasswordSpaceByErrors(); err.isHidden = false; return
                }
                if p != r {
                    err.text = L.getRetypePasswordMismatchByErrors(); err.isHidden = false; return
                }
                self?.chosenPassword = p
                // Move the phone-backup question to the very next screen
                // for fresh installs so the user answers backup once, up
                // front, before they touch any restore path. Returning
                // users (BACKUP_ENABLED_KEY already persisted) skip
                // straight to create-or-restore.
                if PrefConnect.shared.contains(PrefKeys.BACKUP_ENABLED_KEY) {
                    self?.step = .createOrRestore
                } else {
                    self?.step = .phoneBackup
                }
            }), for: .touchUpInside)
        [title, hint, usernameField, pw, rt, err, wrapPrimaryRight(next)].forEach { contentStack.addArrangedSubview($0) }
        ModalDialogViewController.focusAndShowKeyboard(pw.underlyingTextField)
    }

    private func renderCreateOrRestore() {
        let L = Localization.shared
        let back = makeBackBar()
        let title = makeTitle(L.getCreateRestoreWalletByLangValues())
        let topRule = makeRule()
        let prompt = makeBody(L.getSelectAnOptionByLangValues())
        let group = RadioGroup()
        // Tag scheme matches Android `home_wallet_fragment.xml`:
        // 1 = Create new, 0 = Restore from seed,
        // 2 = Restore from File, 3 = Restore from Cloud.
        group.addChoice(tag: 1, title: L.getCreateNewWalletByLangValues())
        group.addChoice(tag: 0, title: L.getRestoreWalletFromSeedByLangValues())
        group.addChoice(tag: 2, title: L.getRestoreFromFileByLangValues())
        group.addChoice(tag: 3, title: L.getRestoreFromCloudByLangValues())
        // Match Android `HomeWalletFragment.java:457-461` which leaves
        // both radios unchecked until the user picks one.
        let bottomRule = makeRule()
        let next = makeNextButton()
        next.addAction(UIAction(handler: { [weak self] _ in
                guard let self = self else { return }
                guard let tag = group.selectedTag else {
                    self.showSelectAnOption(); return
                }
                switch tag {
                    case 1:
                    self.createNotRestore = true
                    self.advanceAfterCreateOrRestore()
                    case 0:
                    self.createNotRestore = false
                    self.advanceAfterCreateOrRestore()
                    case 2:
                    // Restore from a single `.wallet` file (SAF / DocumentPicker).
                    // The phone-backup question has already been answered
                    // immediately after Set Wallet Password, so go straight
                    // into the file picker. Pass `chosenPassword` through
                    // to RestoreFlow so the keystore is bootstrapped with
                    // the user's chosen strongbox password rather than the
                    // per-wallet backup password.
                    self.beginRestoreFromFile()
                    case 3:
                    // Restore from cloud folder. The folder picker is
                    // re-presented every time so the user can switch
                    // folders (the previous "skip if bookmark exists" path
                    // could trap users on an empty folder forever).
                    self.beginRestoreFromCloud()
                    default:
                    break
                }
            }), for: .touchUpInside)
        [back, title, topRule, prompt, group, bottomRule, wrapPrimaryRight(next)]
        .forEach { contentStack.addArrangedSubview($0) }
    }

    /// Routes Create / Restore-from-seed forward from the
    /// create-or-restore screen. Phone Backup is now answered earlier
    /// (immediately after Set Wallet Password), so this method only
    /// branches on create vs. restore. Restore-from-seed skips
    /// `.walletType` because the default/advanced picker is only
    /// meaningful for new wallets - restore is fully determined by
    /// the seed phrase the user already has.
    private func advanceAfterCreateOrRestore() {
        step = createNotRestore ? .walletType : .seedLength
    }

    private func renderPhoneBackup() {
        let L = Localization.shared
        let back = makeBackBar()
        let title = makeTitle(L.getPhoneBackupByLangValues())
        let topRule = makeRule()
        let body = makeBody(L.getBackupPromptByLangValues())
// short-term mitigation. The
        // BACKUP_ENABLED toggle controls only the
        // `isExcludedFromBackup` resource flag on the slot
        // files, which iOS honours for iCloud Backup and
        // *unencrypted* Finder/iTunes backups. ENCRYPTED
        // Finder/iTunes backups copy the entire app container
        // regardless of the exclusion flag, so a user who
        // selects "No" intending to keep the wallet off all
        // backups still has the wallet file copied if their
        // host computer takes an encrypted backup. The wallet
        // file is itself password-encrypted, so the residual
        // exposure is bounded by the strongbox password
        // strength, but the user must understand the limit
        // before answering. The warning paragraph below makes
        // that limit visible at the choice site rather than
        // burying it in Settings.
        let warning = makeBody(L.getBackupEncryptedWarningByLangValues())
        let group = RadioGroup()
        group.addChoice(tag: 1, title: L.getYesByLangValues())
        group.addChoice(tag: 0, title: L.getNoByLangValues())
        // No default selection (mirrors Android `HomeWalletFragment.java:1213-1218`
        // which explicitly clears both radios). The Next handler shows the
        // "Please select an option" dialog until the user picks one.
        let bottomRule = makeRule()
        let next = makeNextButton()
        next.addAction(UIAction(handler: { [weak self] _ in
                guard let self = self else { return }
                guard let tag = group.selectedTag else {
                    self.showSelectAnOption(); return
                }
                // PrefConnect setters are now throwing. A
                // failed flush here downgrades to "next launch sees
                // BACKUP_ENABLED_KEY at the previous value" rather
                // than data loss; log + continue.
                do {
                    try PrefConnect.shared.writeBool(
                        PrefKeys.BACKUP_ENABLED_KEY, tag == 1)
                } catch {
                    Logger.warn(category: "PREFS_FLUSH_FAIL",
                        "BACKUP_ENABLED_KEY: \(error)")
                }
                // Re-apply the iCloud-Backup exclusion bit so the
                // toggle takes effect immediately. On a truly-fresh
                // install neither slot file exists yet, so this call
                // is a no-op; we still call it for uniformity with
                // the Settings flow and so a re-onboarding (e.g. after
                // delete-all + re-create) honours the new choice on
                // the previous-install slot files. See
                // `BackupExclusion.swift` for rationale.
                BackupExclusion.applyToStrongboxFiles()
                // Phone Backup now sits between Set Wallet Password and
                // Create-Or-Restore for fresh installs, so always advance
                // to the create-or-restore picker once the user answers.
                self.step = .createOrRestore
            }), for: .touchUpInside)
        [back, title, topRule, body, warning, group, bottomRule, wrapPrimaryRight(next)]
        .forEach { contentStack.addArrangedSubview($0) }
    }

    /// Resolve the strongbox-write password for a restore session and
    /// invoke `body` with it. During first-time onboarding the user has
    /// already typed the device password on the Set Wallet Password
    /// step (cached in `chosenPassword`), so we forward it directly.
    /// On the post-onboarding "Create or Restore Quantum Wallet" entry
    /// from the wallets list the screen is reached with an empty
    /// `chosenPassword`, so we present `UnlockDialogViewController` to
    /// collect the device password upfront and verify it via the
    /// existing `bootstrapOrUnlock` round-trip (read-only when the
    /// snapshot is already loaded). Mirrors Android
    /// `HomeWalletFragment.ensureStrongboxReadyForRestore`. Closes the
    /// silent-failure bug where the strongbox-write path was falling
    /// back to the per-file backup password (which legitimately differs
    /// from the device password) and every persist threw
    /// `authenticationFailed` after `appendWallet` had already mutated
    /// the in-memory snapshot - producing the misleading "Unable to
    /// decrypt any wallet with that password" alert followed by a
    /// ghost-wallet "already exists" toast on retry.
    private func resolveStrongboxWritePassword(_ body: @escaping (String) -> Void) {
        if !chosenPassword.isEmpty {
            body(chosenPassword)
            return
        }
        presentUnlockThen { pw in body(pw) }
    }

    /// Post-onboarding-safe entry into `RestoreFlow.restoreFromFile`.
    /// Resolves the strongbox-write password first (see
    /// `resolveStrongboxWritePassword`), then wires the completion
    /// callback and hands off to `RestoreFlow`.
    private func beginRestoreFromFile() {
        resolveStrongboxWritePassword { [weak self] pw in
            guard let self = self else { return }
            RestoreFlow.shared.onComplete = { [weak self] in
                guard let self = self,
                RestoreFlow.shared.didImportAny else { return }
                self.finishAndRouteHome()
            }
            RestoreFlow.shared.restoreFromFile(from: self,
                strongboxPassword: pw)
        }
    }

    /// Post-onboarding-safe entry into `startCloudRestore`. Resolves
    /// the strongbox-write password first, then delegates to the
    /// existing folder-picker + `runBatch` pipeline.
    private func beginRestoreFromCloud() {
        resolveStrongboxWritePassword { [weak self] pw in
            self?.startCloudRestore(strongboxPassword: pw)
        }
    }

    /// Restore-from-cloud entry. Always re-presents the folder picker
    /// so the user can pick a different folder each time; if the
    /// chosen folder has no `.wallet` files, surfaces the localized
    /// "no backups found" toast and bails out (the picker will be
    /// re-shown on the next attempt). Issue 8.
    /// `strongboxPassword` is forwarded to `RestoreFlow.runBatch` so the
    /// keystore is bootstrapped with the user's chosen strongbox password
    /// on first run instead of the per-wallet backup password.
    private func startCloudRestore(strongboxPassword: String? = nil) {
        CloudBackupManager.shared.presentFolderPicker(from: self) { [weak self] ok in
            guard let self = self, ok else { return }
            let files = CloudBackupManager.shared.listWalletFiles
            if files().isEmpty {
                Toast.showMessage(Localization.shared.getRestoreNoBackupsFoundByLangValues())
                return
            }
            RestoreFlow.shared.onComplete = { [weak self] in
                guard let self = self,
                RestoreFlow.shared.didImportAny else { return }
                self.finishAndRouteHome()
            }
            RestoreFlow.shared.runBatch(urls: files(), host: self,
                strongboxPassword: strongboxPassword)
        }
    }

    private func renderWalletType() {
        let L = Localization.shared
        let back = makeBackBar()
        let title = makeTitle(L.getSelectWalletTypeByLangValues())
        let topRule = makeRule()
        let prompt = makeBody(L.getSelectAnOptionByLangValues())
        let group = RadioGroup()
        group.addChoice(tag: Constants.KEY_TYPE_DEFAULT, title: L.getWalletTypeDefaultByLangValues())
        group.addChoice(tag: Constants.KEY_TYPE_ADVANCED, title: L.getWalletTypeAdvancedByLangValues())
        // No default selection - mirrors Android `HomeWalletFragment.java`
        // wallet-type radios that start unchecked.
        let bottomRule = makeRule()
        let next = makeNextButton()
        next.addAction(UIAction(handler: { [weak self] _ in
                guard let self = self else { return }
                guard let tag = group.selectedTag else {
                    self.showSelectAnOption(); return
                }
                self.keyType = tag
                if self.createNotRestore == true {
                    // Generate seed words but do NOT yet persist the wallet.
                    // Android `HomeWalletFragment.java:1167` only calls
                    // `saveWalletFromSeedWords` from verify-Next or
                    // skip-confirm; mirror that here so user can back out
                    // without writing to the keystore.
                    self.step = .seedShow
                    self.generateSeedWords()
                } else {
                    self.step = .seedLength
                }
            }), for: .touchUpInside)
        [back, title, topRule, prompt, group, bottomRule, wrapPrimaryRight(next)]
        .forEach { contentStack.addArrangedSubview($0) }
    }

    private func renderSeedLength() {
        let L = Localization.shared
        let back = makeBackBar()
        let title = makeTitle(L.getSelectSeedWordLengthByLangValues())
        let topRule = makeRule()
        let prompt = makeBody(L.getSelectAnOptionByLangValues())
        let group = RadioGroup()
        group.addChoice(tag: 32, title: L.getSeedLength32ByLangValues())
        group.addChoice(tag: 36, title: L.getSeedLength36ByLangValues())
        group.addChoice(tag: 48, title: L.getSeedLength48ByLangValues())
        // No default selection (parity with Android wallet-type/back-up
        // radios; user must explicitly pick a length).
        let bottomRule = makeRule()
        let next = makeNextButton()
        next.addAction(UIAction(handler: { [weak self] _ in
                guard let self = self else { return }
                guard let tag = group.selectedTag else {
                    self.showSelectAnOption(); return
                }
                self.seedLength = tag
                self.step = .seedShow
                self.startRestoreFromPhrasePrompt()
            }), for: .touchUpInside)
        [back, title, topRule, prompt, group, bottomRule, wrapPrimaryRight(next)]
        .forEach { contentStack.addArrangedSubview($0) }
    }

    private func renderSeedShow() {
        let L = Localization.shared

        if !seedRevealed {
            // Reveal-gating: mirrors Android `SeedWordsView`'s underlined
            // "5. Click here to reveal the seed words." TextView. The
            // info panel + reveal link is shown until the user taps,
            // and the entire info+reveal panel disappears once revealed
            // (Android wraps both in `linear_layout_home_seed_words`
            // and sets it to GONE in `HomeWalletFragment.java:668-669`).
            let back = makeBackBar()
            let title = makeTitle(L.getSeedWordsByLangValues())
            let info1 = makeBody(L.getSeedWordsInfo1ByLangValues())
            let info2 = makeBody(L.getSeedWordsInfo2ByLangValues())
            let info3 = makeBody(L.getSeedWordsInfo3ByLangValues())
            let info4 = makeBody(L.getSeedWordsInfo4ByLangValues())
            let reveal = makeRevealLabel(text: L.getSeedWordsShowByLangValues())
            reveal.addTarget(self, action: #selector(tapRevealSeed),
                for: .touchUpInside)
            [back, title, makeRule(), info1, info2, info3, info4, reveal].forEach {
                contentStack.addArrangedSubview($0)
            }
            return
        }

        // Words shown - panel above is hidden; render only the
        // (matching Android `linear_layout_home_seed_words_view`)
        // title + grid + copy row + Next.
        let back = makeBackBar()
        let title = makeTitle(L.getSeedWordsByLangValues())
        let grid = SeedChipGrid(words: generatedSeed, editable: false)
        // Defense-in-depth at the screen-region level - the
        // SeedChipGrid already suppresses VoiceOver
        // on itself and its descendants, but we also flag the
        // grid container as hidden so a future container/parent
        // change cannot accidentally re-expose the per-cell
        // labels through a sibling that ends up wrapping the
        // grid. See SeedChipGrid.configureAccessibility comment
        // block for the threat model.
        grid.accessibilityElementsHidden = true
        // Hide the seed grid while the screen is being captured.
        // The warning view is layered over `grid` and
        // becomes visible whenever `UIScreen.isCaptured == true`.
        let captureWarning = makeSeedCaptureWarning()
        seedShowCaptureGuard = ScreenCaptureGuard(
            protectedView: grid, host: contentStack, warningView: captureWarning)
        let copyRow = makeCopyRow { [weak self] in
            guard let self = self, !self.generatedSeed.isEmpty else { return }
            // This is the seed-phrase copy site - the most
            // sensitive pasteboard write the app ever makes. The
            // wrapper applies the centralized `Pasteboard.defaultLifetime`
            // (30 s) and opts out of Universal Clipboard via
            // `.localOnly: true` so the seed phrase
            // does NOT replicate to the user's other Apple devices.
            // The previous explicit `lifetime: 30` override is now
            // redundant; relying on the default keeps the
            // tightening uniform across every sensitive copy site.
            // See Pasteboard.swift for the full rationale.
            Pasteboard.copySensitive(
                self.generatedSeed.joined(separator: " "))
            // Feedback is the inline "Copied" label inside the row,
            // mirroring Android's `homeCopyClickListener`.
        }
        let next = makeNextButton()
        next.addAction(UIAction(handler: { [weak self] _ in self?.step = .seedVerify }), for: .touchUpInside)

        contentStack.addArrangedSubview(back)
        contentStack.addArrangedSubview(title)
        contentStack.addArrangedSubview(makeRule())
        contentStack.addArrangedSubview(grid)
        contentStack.addArrangedSubview(makeRule())
        contentStack.addArrangedSubview(copyRow)
        contentStack.addArrangedSubview(wrapPrimaryRight(next))
    }

    @objc private func tapRevealSeed() {
        seedRevealed = true
        render()
    }

    private func renderSeedVerify() {
        let L = Localization.shared
        // Skip is a tappable underlined link docked one row below the
        // rule under the title, matching Android
        // `textView_home_seed_words_edit_skip` (`textColor=#2196F3`,
        // `layout_gravity="end"`). Back lives in the standard back bar
        // shared with every other onboarding step.
        let skipLink = makeSkipLink(text: L.getSkipByLangValues())
        skipLink.addTarget(self, action: #selector(tapVerifySkip),
            for: .touchUpInside)
        let skipRow = UIStackView()
        skipRow.axis = .horizontal
        skipRow.alignment = .center
        let skipSpacer = UIView()
        skipSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        skipRow.addArrangedSubview(skipSpacer)
        skipRow.addArrangedSubview(skipLink)

        let title = makeTitle(L.getVerifySeedWordsByLangValues())
        let grid = SeedChipGrid(words: Array(repeating: "", count: generatedSeed.count),
            editable: true)
        // Defense-in-depth - same posture as the new-seed
        // display surface. The verification quiz takes
        // user input but the input IS the seed phrase, so an
        // accessibility echo of typed words has the same threat
        // surface as displaying the seed.
        grid.accessibilityElementsHidden = true
        let next = makeNextButton()
        next.addAction(UIAction(handler: { [weak self, weak grid] _ in
                guard let self = self, let grid = grid else { return }
                let entered = grid.collectWords()
                // Android `HomeWalletFragment.java:761-767` silently rejects
                // wrong words: clear the offending field, focus it, and
                // return without showing an error string. Mirror that here.
                var firstInvalid: Int? = nil
                for (i, w) in entered.enumerated() {
                    let expected = self.generatedSeed[safe: i] ?? ""
                    if !BIP39Words.exists(w) || w != expected {
                        grid.clearField(at: i)
                        if firstInvalid == nil { firstInvalid = i }
                    }
                }
                if let i = firstInvalid {
                    grid.focusField(at: i)
                    return
                }
                // Words verified - now commit the generated wallet to the
                // keystore (Android `saveWalletFromSeedWords`) and advance.
                // Routes through the unlock-prompt helper because the user
                // may have entered "Create or Restore" from the Wallets
                // list (the `.setPassword` step is skipped on that path,
                // so `chosenPassword` is empty and we need to collect the
                // strongbox password here).
                self.commitGeneratedWalletWithUnlock { [weak self] in
                    self?.step = .backupOptions
                }
            }), for: .touchUpInside)
        [makeBackBar(), title, makeRule(), skipRow, grid, makeRule(),
            wrapPrimaryRight(next)]
        .forEach { contentStack.addArrangedSubview($0) }
    }

    @objc private func tapVerifySkip() {
        // Confirm before skipping verification, matching Android
        // `confirmCancellationToSkipVerification` (`skip-verify-confirm`).
        // On Yes commit the wallet (Android only writes to keystore at
        // this point, line 792-793) then advance.
        let confirm = ConfirmDialogViewController(
            title: "",
            message: Localization.shared.getSkipVerifyConfirmByLangValues(),
            confirmText: Localization.shared.getYesByLangValues(),
            cancelText: Localization.shared.getNoByLangValues())
        confirm.onConfirm = { [weak self] in
            // Same reasoning as the verify-Next path: route through
            // the unlock-prompt helper so the Wallets-list entry can
            // collect the strongbox password before the keystore write.
            self?.commitGeneratedWalletWithUnlock { [weak self] in
                self?.step = .backupOptions
            }
        }
        present(confirm, animated: true)
    }

    private func renderConfirmWallet() {
        let L = Localization.shared
        let backBar = makeBackBar()
        let title = makeTitle(L.getConfirmWalletByLangValues())
        let body = makeBody(L.getConfirmWalletDescriptionByLangValues())
        let addressLabel = makeBody(L.getAddressByLangValues())
        let addressRow = makeAddressRow(address: pendingAddress)
        let balanceLabel = makeBody(L.getBalanceByLangValues())
        // Balance row composed of a value label on the left and a
        // refresh icon swap on the right; the swap toggles to a
        // spinner while the balance fetch is in flight and returns to
        // the icon when the task completes. Mirrors the in-place swap
        // applied to every other icon-driven refresh button.
        let balanceValue = makeBody("-")
        let refreshSwap = RefreshIconSwap(image: UIImage(named: "retry"))
        refreshSwap.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            refreshSwap.widthAnchor.constraint(equalToConstant: 32),
            refreshSwap.heightAnchor.constraint(equalToConstant: 32)
        ])
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let balanceRow = UIStackView(arrangedSubviews: [
            balanceValue, spacer, refreshSwap
        ])
        balanceRow.axis = .horizontal
        balanceRow.alignment = .center
        balanceRow.spacing = 8
        // Use makeNextButton for the back button so it sizes to its
        // intrinsic content and right-docks alongside Next, matching
        // Android `wrap_content + layout_gravity="right"` pill buttons.
        let back = makeNextButton(title: L.getBackByLangValues())
        back.addAction(UIAction(handler: { [weak self] _ in
                // Re-render the restore prompt; `.seedShow` routes there
                // for the restore branch, and `enteredRestorePhrase` is
                // carried across so the grid stays filled in.
                self?.step = .seedShow
                self?.startRestoreFromPhrasePrompt()
            }), for: .touchUpInside)
        let next = makeNextButton()
        next.addAction(UIAction(handler: { [weak self] _ in
                self?.persistPendingWalletWithUnlock()
            }), for: .touchUpInside)
        [backBar, title, makeRule(), body,
            addressLabel, addressRow,
            balanceLabel, balanceRow,
            makeRule(), wrapPrimaryRight(back, next)]
        .forEach { contentStack.addArrangedSubview($0) }
        refreshSwap.onTap = { [weak self, weak balanceValue, weak refreshSwap] in
            guard let self = self,
                  let label = balanceValue,
                  let swap = refreshSwap else { return }
            self.fetchAndShowBalance(label: label, refreshSwap: swap)
        }
        fetchAndShowBalance(label: balanceValue, refreshSwap: refreshSwap)
    }

    private func renderBackupOptions() {
        let L = Localization.shared
        let backBar = makeBackBar()
        let title = makeTitle(L.getBackupOptionsTitleByLangValues())
        let body = makeBody(L.getBackupOptionsDescriptionByLangValues())
        let cloud = makePrimaryButton(L.getBackupToCloudByLangValues())
        cloud.addTarget(self, action: #selector(tapBackupCloud), for: .touchUpInside)
        let file = makePrimaryButton(L.getBackupToFileByLangValues())
        file.addTarget(self, action: #selector(tapBackupFile), for: .touchUpInside)

        // Right-aligned purple "Next" pill, mirroring the same layout
        // on `BackupOptionsViewController` so the post-create wallet
        // backup screen and the wallets-tab backup screen match.
        let next = GreenPillButton(type: .system)
        next.setTitle(L.getNextByLangValues(), for: .normal)
        next.addTarget(self, action: #selector(tapBackupDone), for: .touchUpInside)
        next.translatesAutoresizingMaskIntoConstraints = false
        next.heightAnchor.constraint(equalToConstant: 43).isActive = true
        next.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true

        let nextRow = UIStackView()
        nextRow.axis = .horizontal
        nextRow.alignment = .center
        nextRow.distribution = .fill
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        nextRow.addArrangedSubview(spacer)
        nextRow.addArrangedSubview(next)

        [backBar, title, body, makeRule(), cloud, file, makeRule(), nextRow]
        .forEach { contentStack.addArrangedSubview($0) }
    }

    // MARK: - Actions

    /// Phase 1 of create-new-wallet: ask the JS bridge for fresh random
    /// seed words and render them on screen. Does NOT touch the
    /// keystore. Mirrors Android `HomeWalletFragment.java:1100..1166`
    /// where seed words are shown immediately but `saveWalletFromSeedWords`
    /// is deferred to the verify-Next or skip-confirm handler.
    private func generateSeedWords() {
        // No wait dialog here. The `WaitDialogViewController` only shows
        // up at `commitGeneratedWallet` (verify-Next or skip-confirm),
        // matching Android: the seed-show step reveals words straight
        // into the grid without a blocking modal. `JsBridge.createRandom`
        // is fast enough to feel instant on the seed reveal step.
        Task.detached(priority: .userInitiated) { [keyType] in
            do {
// `createRandom` returns a `WalletEnvelope` whose
                // `privateKey`/`publicKey` are `Data`. We do NOT
                // use them on this path (only the address + seed
                // words are needed for the seed-show screen) — the
                // commit step re-derives the same keys from the
                // seed via `walletFromPhrase`, deterministically.
                // Wiping the bytes here keeps the in-process copy
                // bounded to the seed-show step.
                var env = try JsBridge.shared.createRandom(keyType: keyType)
                defer {
                    env.privateKey.resetBytes(in: 0..<env.privateKey.count)
                    env.publicKey.resetBytes(in: 0..<env.publicKey.count)
                }
                let address = env.address
                let seedWords = env.seedWords ?? []
                await MainActor.run { [weak self] in
                    self?.generatedSeed = seedWords
                    self?.generatedAddress = address
                    self?.render()
                }
            } catch {
                await MainActor.run {
                    Toast.showError("\(error)")
                }
            }
        }
    }

    /// Phase 2 of create-new-wallet: encrypt the previously-generated
    /// seed words with the user's password and persist via
    /// `UnlockCoordinatorV2.appendWallet`. Runs `then` on the
    /// main actor on success.
    /// Mirrors Android `saveWalletFromSeedWords`
    /// (`HomeWalletFragment.java:1167`), which is invoked only from
    /// verify-Next (line 772) or skip-confirm-yes (line 792-793).
    /// `password` must be the user's actual strongbox password. On the
    /// first-time-onboarding path it is the value typed into
    /// `renderSetPassword` (carried via `chosenPassword`). On the
    /// "Wallets list > Create or Restore" path the set-password step
    /// is skipped, so callers route through
    /// `commitGeneratedWalletWithUnlock` to collect it via
    /// `UnlockDialogViewController` before reaching here.
    private func commitGeneratedWallet(password: String,
        then: @escaping () -> Void) {
        // Idempotency guards. Two layered checks:
        //   (a) `walletIndex >= 0` catches the same-controller
        //       re-tap (the field survives across renders) —
        //       this is the historical guard.
        //   (b) `Strongbox.index(forAddress:)` catches the
        //       case where `walletIndex` was lost (e.g. the
        //       view was rebuilt or the user re-entered via
        //       Wallets-list "Add wallet") but the strongbox
        //       already holds this address. Without (b), a
        //       back/Next on the same generated seed would
        //       silently append a second slot for the same
        //       wallet. Source of truth is the loaded snapshot.
        if walletIndex >= 0 {
            then()
            return
        }
        if Strongbox.shared.isSnapshotLoaded,
        let existing = Strongbox.shared.index(forAddress: generatedAddress) {
            walletIndex = existing
            then()
            return
        }
        let wait = WaitDialogViewController(message:
            Localization.shared.getWaitWalletSaveByLangValues())
        present(wait, animated: true)
        // Phase callback wires the wait-dialog's secondary status
        // line to the storage-layer write phase (writing -> verifying
        // -> promoting -> committed). The main "Please wait..." message
        // stays visible the entire time; "Verifying..." flashes ON
        // during the integrity-check window between F_FULLFSYNC and
        // rename, then OFF on promote. See
        // `WaitDialogViewController.setStatus` for prior reviews
        // invariant, and `AtomicSlotWriter.writeAndVerify` for the
        // closure called between writeAll and rename.
        let onPhase = makeVerifyingPhaseHandler(for: wait)
        let address = generatedAddress
        let seedWords = generatedSeed
        Task.detached(priority: .userInitiated) {
            do {
                // Re-derive the raw signing-key bytes from the
                // confirmed seed phrase. The bridge's seed -> wallet
                // derivation is deterministic so the same words
                // yield the same address + keys; we belt-and-
                // suspenders verify the derived address matches
                // what the user just confirmed before committing.
                // Holding the keys as `Data` with a `defer
                // resetBytes` wipes them as soon as `appendWallet`
                // returns; the only long-lived copy is the one
                // sealed inside the strongbox by the AEAD path.
                var env = try JsBridge.shared.walletFromPhrase(words: seedWords)
                defer {
                    env.privateKey.resetBytes(in: 0..<env.privateKey.count)
                    env.publicKey.resetBytes(in: 0..<env.publicKey.count)
                }
                if env.address.lowercased() != address.lowercased() {
                    throw UnlockCoordinatorV2Error.decodeFailed
                }
                let seedJoined = seedWords.joined(separator: ",")
                // First-launch bootstrap vs returning-user paths:
                // - First launch (no slot file): use the hardening's atomic
                //   `createNewStrongboxWithInitialWallet` so the
                //   first wallet is committed inside the SAME slot
                //   write that creates the strongbox. A power-cut
                //   between the historical pair (createNewStrongbox
                //   + appendWallet) could leave an "empty wallet"
                //   strongbox the user trusted as saved — closes
                //   a prior durability gap.
                // - Returning user (slot file present): unlock the
                //   existing strongbox and append.
                // Both paths re-derive the mainKey from the user's
                // password inside the coordinator and zero it on
                // return - the strongbox key bytes never survive
                // past the helper call.
                let idx: Int
                if !Strongbox.shared.isSnapshotLoaded,
                case .noStrongbox = UnlockCoordinatorV2.bootState() {
                    let wallet = StrongboxPayload.Wallet(
                        idx: 0,
                        address: env.address,
                        privateKey: env.privateKey,
                        publicKey: env.publicKey,
                        hasSeed: true,
                        seedWords: seedJoined)
                    try UnlockCoordinatorV2.createNewStrongboxWithInitialWallet(
                        password: password,
                        initialWallet: wallet,
                        onPhase: onPhase)
                    idx = 0
                } else {
                    try Self.bootstrapOrUnlock(password: password, onPhase: onPhase)
                    idx = try UnlockCoordinatorV2.appendWallet(
                        address: env.address,
                        privateKey: env.privateKey,
                        publicKey: env.publicKey,
                        hasSeed: true,
                        seedWords: seedJoined,
                        password: password,
                        onPhase: onPhase)
                }
                await MainActor.run { [weak self] in
                    self?.walletIndex = idx
                    do {
                        try PrefConnect.shared.writeInt(
                            PrefKeys.WALLET_CURRENT_ADDRESS_INDEX_KEY, idx)
                    } catch {
                        Logger.warn(category: "PREFS_FLUSH_FAIL",
                            "WALLET_CURRENT_ADDRESS_INDEX_KEY: \(error)")
                    }
                    wait.dismiss(animated: true) { then() }
                }
            } catch {
                let msg = Self.userFacingError(error)
                await MainActor.run {
                    wait.dismiss(animated: true) { Toast.showError(msg) }
                }
            }
        }
    }

    /// Bootstrap the strongbox on first launch (no slot file) or
    /// unlock the existing strongbox on a returning device. After
    /// this returns, `Strongbox.shared` is populated and
    /// `appendWallet` can write the first / next wallet.
    /// The decision is made from `bootState` (slot file present
    /// or not), NOT from an in-memory wallet count - the caller
    /// may run while another path has already loaded the snapshot
    /// (e.g. add-wallet from the wallets list); in that case we
    /// short-circuit because the snapshot is fresh.
    /// What it closes:
    ///   The "wrong password silently accepted" bug on the
    ///   onboarding-flow unlock dialog (post-create backup
    ///   screen Next, restore-flow add-wallet unlock prompt).
    ///   The historical shape was
    ///   `if Strongbox.shared.isSnapshotLoaded { return }` at
    ///   the very top — which short-circuited the whole helper
    ///   to "success" when the snapshot was already loaded by a
    ///   previous create / restore step. Any password the user
    ///   typed was reported as correct without ever AEAD-opening
    ///   `passwordWrap`. The user could finish onboarding with
    ///   PWD-A, tap Next on the backup screen, type PWD-B, and
    ///   be routed home — only to discover at the next cold
    ///   launch that PWD-A is the actual seal key.
    /// Why this shape (verify-on-snapshot-loaded):
    ///   When the snapshot is already loaded we MUST NOT call
    ///   `unlockWithPasswordAndApplySession` (that path
    ///   re-installs the snapshot, bumps the counter, and
    ///   re-applies the session — none of which is safe against
    ///   a live wallet). Instead we route through the new
    ///   read-only `UnlockCoordinatorV2.verifyPassword` which
    ///   AEAD-opens `passwordWrap` and signals the brute-force
    ///   limiter, but does not touch any other state.
    /// Tradeoffs:
    ///   Pays one extra scrypt (~300 ms) on the post-create
    ///   unlock prompt path. That cost is invisible next to the
    ///   wait dialog the caller already presents during
    ///   `commitGeneratedWallet` / `persistPendingWallet`.
    /// Cross-references:
    ///   - `UnlockCoordinatorV2.verifyPassword(_:)` for the
    ///     read-only validator.
    ///   - `RestoreFlow.bootstrapOrUnlock` for the matching
    ///     change on the restore side.
    ///   - `tapBackupDone` and `presentUnlockThen` are the call
    ///     sites that benefit from this fix.
    nonisolated private static func bootstrapOrUnlock(password: String,
        onPhase: UnlockCoordinatorV2.WriteVerifyPhaseCallback? = nil) throws {
        switch UnlockCoordinatorV2.bootState() {
            case .noStrongbox:
            try UnlockCoordinatorV2.createNewStrongbox(
                password: password, onPhase: onPhase)
            case .strongboxPresent:
            if Strongbox.shared.isSnapshotLoaded {
                // Snapshot already loaded by a prior step;
                // verify the password against the on-disk
                // `passwordWrap` without re-installing the
                // snapshot or bumping the rollback counter.
                try UnlockCoordinatorV2.verifyPassword(password)
            } else {
                // Cold-path unlock: derive mainKey, install
                // snapshot, apply session, bump counter — the
                // full unlock pipeline.
                try UnlockCoordinatorV2.unlockWithPasswordAndApplySession(password)
            }
            case .tampered(let why):
            throw UnlockCoordinatorV2Error.tamperDetected(why)
        }
    }

    /// Validate the user-typed password without creating a strongbox.
    ///
    /// Companion to `bootstrapOrUnlock`, used by `presentUnlockThen`
    /// where the caller only needs to know the typed password is
    /// correct before handing it back for the actual persist call —
    /// `commitGeneratedWallet` / `persistPendingWallet` will then
    /// drive the strongbox write itself, taking the atomic
    /// `createNewStrongboxWithInitialWallet` branch on a fresh
    /// install. Splitting the helpers means the unlock dialog never
    /// touches disk on a `.noStrongbox` device.
    ///
    /// Why it matters:
    ///   The historical shape called `bootstrapOrUnlock` here, which
    ///   on `.noStrongbox` writes an empty payload via
    ///   `createNewStrongbox`. If the user dismissed / backgrounded
    ///   / crashed between that write and the subsequent
    ///   `appendWallet`, the strongbox would persist on disk with
    ///   zero wallets. Cold launch would then see a slot file,
    ///   route through the mandatory unlock gate, and drop the user
    ///   into an empty wallet home — the "app created with no
    ///   wallet" bug. Skipping the create here keeps the
    ///   bootstrap+first-wallet write in a single AEAD-sealed slot
    ///   round-trip with `createNewStrongboxWithInitialWallet`, so
    ///   no empty strongbox can ever exist on disk.
    ///
    /// Behavior by bootState:
    ///   - `.noStrongbox`: no-op. There is nothing on disk to
    ///     validate against; the caller's next step will atomically
    ///     create-with-initial-wallet.
    ///   - `.strongboxPresent` + snapshot loaded: read-only
    ///     `verifyPassword` (limiter records the attempt, no
    ///     snapshot reinstall, no counter bump).
    ///   - `.strongboxPresent` + snapshot not loaded: cold-path
    ///     `unlockWithPasswordAndApplySession`. This branch is not
    ///     reachable from `presentUnlockThen` in practice (cold
    ///     launch with a slot file goes through the mandatory
    ///     unlock gate before any wizard surface), but is wired so
    ///     the helper is total over the bootState enum.
    ///   - `.tampered`: surface the tamper reason verbatim, same as
    ///     `bootstrapOrUnlock`.
    nonisolated private static func verifyOnlyIfPresent(password: String) throws {
        switch UnlockCoordinatorV2.bootState() {
            case .noStrongbox:
            return
            case .strongboxPresent:
            if Strongbox.shared.isSnapshotLoaded {
                try UnlockCoordinatorV2.verifyPassword(password)
            } else {
                try UnlockCoordinatorV2.unlockWithPasswordAndApplySession(password)
            }
            case .tampered(let why):
            throw UnlockCoordinatorV2Error.tamperDetected(why)
        }
    }

    /// Wraps `commitGeneratedWallet` with a strongbox unlock prompt for the
    /// "Wallets list > Create or Restore" entry path, where the set-
    /// password step was skipped and `chosenPassword` is empty. On the
    /// first-time-onboarding path this short-circuits to the original
    /// behavior with no extra UI. Mirrors the Android contract: the
    /// strongbox unlock at app entry suffices, but iOS still needs the
    /// cleartext password here to seal the new wallet's raw key bytes
    /// into the strongbox via `appendWallet` (which re-derives the
    /// strongbox mainKey under the same password).
    private func commitGeneratedWalletWithUnlock(then: @escaping () -> Void) {
        if !chosenPassword.isEmpty {
            commitGeneratedWallet(password: chosenPassword, then: then)
            return
        }
        presentUnlockThen { [weak self] pw in
            self?.commitGeneratedWallet(password: pw, then: then)
        }
    }

    private func startRestoreFromPhrasePrompt() {
        // Render a phrase-entry screen in-place. Reuses
        // `SeedChipGrid(editable:true)` with `seedLength` slots so the
        // user gets row labels (A1..L4), per-row colored borders and
        // BIP39 autocomplete - same as the verify screen. Android
        // hides Skip on this path (`HomeWalletFragment.java:596-598`),
        // so no Skip button here.
        let L = Localization.shared
        contentStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        resetScrollToTop()
        let back = makeBackBar()
        let title = makeTitle(L.getEnterSeedWordsByLangValues())
        let initial = enteredRestorePhrase.count == seedLength
        ? enteredRestorePhrase
        : Array(repeating: "", count: seedLength)
        let grid = SeedChipGrid(words: initial, editable: true)
        // Defense-in-depth on the restore entry surface. Same
        // threat model as new-seed display and
        // verification quiz - the typed words ARE the seed.
        grid.accessibilityElementsHidden = true
        let next = makeNextButton()
        next.addAction(UIAction(handler: { [weak self, weak grid, weak next] _ in
                guard let self = self, let grid = grid else { return }
                let entered = grid.collectWords()
                // Mirror Android's silent rejection: clear any field whose
                // entry is not a BIP39 word, focus the first invalid one,
                // and return without showing an error string.
                var firstInvalid: Int? = nil
                for (i, w) in entered.enumerated() where !BIP39Words.exists(w) {
                    grid.clearField(at: i)
                    if firstInvalid == nil { firstInvalid = i }
                }
                if let i = firstInvalid {
                    grid.focusField(at: i)
                    return
                }
                self.enteredRestorePhrase = entered
                self.deriveThenShowConfirm(entered, from: next)
            }), for: .touchUpInside)
        [back, title, makeRule(), grid, makeRule(), wrapPrimaryRight(next)]
        .forEach { contentStack.addArrangedSubview($0) }
    }

    /// Restore branch only: derive the wallet's `address` from the user's
    /// entered phrase via `walletFromPhrase`, but DO NOT persist. The
    /// `.confirmWallet` step shows the address so the user can go back
    /// and fix typos before the wallet is written to secure storage.
    /// `walletFromPhrase` only returns `{address, privateKey, publicKey}`
    /// (no seedWords) — the seed words are the user's entry, captured
    /// verbatim into `pendingSeedWords` so `persistPendingWallet` can use
    /// them as the encrypt input.
    /// We deliberately don't show a `WaitDialog` here: the previous copy
    /// ("Please wait while your wallet is saved") was misleading because
    /// nothing is being saved at this stage - the keystore write happens
    /// later in `persistPendingWallet`. `walletFromPhrase` is a fast
    /// keypair derivation (no scrypt), so disabling the originating
    /// button while the detached task runs is enough to prevent
    /// double-taps without flashing a spinner the user can't act on.
    private func deriveThenShowConfirm(_ words: [String], from button: UIButton? = nil) {
        button?.isEnabled = false
        Task.detached(priority: .userInitiated) { [weak self, weak button] in
            do {
// we only need `address` for the
                // confirm screen, but we still must zeroize
                // the binary key material so the ONLY surviving
                // copy in process memory is what
                // `encryptWalletJson` will stage from the user's
                // seed-words entry on the persist step.
                var env = try JsBridge.shared.walletFromPhrase(words: words)
                defer {
                    env.privateKey.resetBytes(in: 0..<env.privateKey.count)
                    env.publicKey.resetBytes(in: 0..<env.publicKey.count)
                }
                let address = env.address
                await MainActor.run { [weak self] in
                    self?.pendingAddress = address
                    self?.pendingSeedWords = words
                    self?.step = .confirmWallet
                }
            } catch {
                await MainActor.run {
                    button?.isEnabled = true
                    Toast.showError("\(error)")
                }
            }
        }
    }

    /// Final step of the restore branch: derive the raw signing-
    /// key bytes from the cached `pendingSeedWords` and commit
    /// the wallet (raw keys + comma-joined seed) to the
    /// strongbox via `appendWallet`, then advance to
    /// `.backupOptions`. The seed phrase is the canonical
    /// recovery material; the keys are deterministic from the
    /// phrase and held in `Data` with a `defer resetBytes` so
    /// the only long-lived copy is the one sealed inside the
    /// strongbox by the AEAD path.
    private func persistPendingWallet(password: String) {
        // Idempotency guard. The historical shape ran the
        // encrypt + bootstrap + appendWallet pipeline every
        // time the user tapped Next on `.confirmWallet`,
        // including when the user back-tapped to fix a typo
        // and re-tapped Next on the same seed. Each re-entry
        // appended a brand-new wallet slot with the same
        // seed but a different `idx`, producing 2..N
        // duplicate entries in the wallets list. Two layered
        // checks now short-circuit on a re-entry:
        //   (a) `walletIndex >= 0` catches the same-controller
        //       re-tap (the field survives across renders).
        //   (b) `Strongbox.index(forAddress:)` catches the
        //       case where `walletIndex` was lost (e.g. the
        //       view was rebuilt) but the strongbox already
        //       holds this address — the source of truth is
        //       the loaded snapshot.
        // Both branches advance to `.backupOptions` because
        // a successful prior persist is by definition the
        // state the user was trying to reach.
        if walletIndex >= 0 {
            step = .backupOptions
            return
        }
        if Strongbox.shared.isSnapshotLoaded,
        let existing = Strongbox.shared.index(forAddress: pendingAddress) {
            walletIndex = existing
            step = .backupOptions
            return
        }
        let wait = WaitDialogViewController(message:
            Localization.shared.getWaitWalletSaveByLangValues())
        present(wait, animated: true)
        // See `commitGeneratedWallet` for the rationale on the
        // phase-callback / "Verifying..." secondary status line wiring.
        let onPhase = makeVerifyingPhaseHandler(for: wait)
        let address = pendingAddress
        let seedWords = pendingSeedWords
        // Set the seed up front so the wallet home screen has it as soon
        // as we route there — even if encrypt fails, we don't lose what
        // the user just confirmed.
        generatedSeed = seedWords
        Task.detached(priority: .userInitiated) {
            do {
                // Re-derive the raw keys from the seed words.
                // Deterministic so we belt-and-suspenders compare
                // the derived address to the one the user just
                // confirmed in the previous step. Same atomic-
                // bootstrap rationale as `commitGeneratedWallet`:
                // on a fresh install (.noStrongbox) we use the
                // hardening's atomic
                // `createNewStrongboxWithInitialWallet` so a
                // power-cut never leaves an empty-wallet
                // strongbox the user has trusted as saved.
                var env = try JsBridge.shared.walletFromPhrase(words: seedWords)
                defer {
                    env.privateKey.resetBytes(in: 0..<env.privateKey.count)
                    env.publicKey.resetBytes(in: 0..<env.publicKey.count)
                }
                if env.address.lowercased() != address.lowercased() {
                    throw UnlockCoordinatorV2Error.decodeFailed
                }
                let seedJoined = seedWords.joined(separator: ",")
                let idx: Int
                if !Strongbox.shared.isSnapshotLoaded,
                case .noStrongbox = UnlockCoordinatorV2.bootState() {
                    let wallet = StrongboxPayload.Wallet(
                        idx: 0,
                        address: env.address,
                        privateKey: env.privateKey,
                        publicKey: env.publicKey,
                        hasSeed: true,
                        seedWords: seedJoined)
                    try UnlockCoordinatorV2.createNewStrongboxWithInitialWallet(
                        password: password,
                        initialWallet: wallet,
                        onPhase: onPhase)
                    idx = 0
                } else {
                    try Self.bootstrapOrUnlock(password: password, onPhase: onPhase)
                    idx = try UnlockCoordinatorV2.appendWallet(
                        address: env.address,
                        privateKey: env.privateKey,
                        publicKey: env.publicKey,
                        hasSeed: true,
                        seedWords: seedJoined,
                        password: password,
                        onPhase: onPhase)
                }
                await MainActor.run { [weak self] in
                    self?.generatedAddress = address
                    self?.walletIndex = idx
                    do {
                        try PrefConnect.shared.writeInt(
                            PrefKeys.WALLET_CURRENT_ADDRESS_INDEX_KEY, idx)
                    } catch {
                        Logger.warn(category: "PREFS_FLUSH_FAIL",
                            "WALLET_CURRENT_ADDRESS_INDEX_KEY: \(error)")
                    }
                    wait.dismiss(animated: true) { self?.step = .backupOptions }
                }
            } catch {
                let msg = Self.userFacingError(error)
                await MainActor.run {
                    wait.dismiss(animated: true) { Toast.showError(msg) }
                }
            }
        }
    }

    /// Same role as `commitGeneratedWalletWithUnlock` but for the
    /// restore-from-phrase confirm step. Falls through to
    /// `persistPendingWallet(password:)` once the strongbox password is
    /// known (either `chosenPassword` from first-time onboarding or the
    /// password the user typed into `UnlockDialogViewController`).
    private func persistPendingWalletWithUnlock() {
        if !chosenPassword.isEmpty {
            persistPendingWallet(password: chosenPassword)
            return
        }
        presentUnlockThen { [weak self] pw in
            self?.persistPendingWallet(password: pw)
        }
    }

    /// Show `UnlockDialogViewController` and validate the typed
    /// password via `verifyOnlyIfPresent`. On success, dismiss the
    /// dialog and call `then(password)` so the caller can use that
    /// exact string for `bridge.encryptWalletJson`. On failure, surface
    /// the same wrong-password UX used by the post-backup unlock prompt
    /// (`tapBackupDone`) - inline error + modal alert, password field
    /// is preserved.
    ///
    /// Validation deliberately uses `verifyOnlyIfPresent` rather than
    /// `bootstrapOrUnlock` so the dialog never writes a strongbox on a
    /// `.noStrongbox` device. The caller (`commitGeneratedWallet` /
    /// `persistPendingWallet`) is responsible for the atomic
    /// `createNewStrongboxWithInitialWallet` write that bootstraps the
    /// strongbox together with the first wallet — see
    /// `verifyOnlyIfPresent` doc for the empty-strongbox-window
    /// rationale this split closes.
    private func presentUnlockThen(_ then: @escaping (String) -> Void) {
        let dlg = UnlockDialogViewController()
        dlg.onUnlock = { [weak self, weak dlg] pw in
            guard let self = self, let dlg = dlg else { return }
            if pw.isEmpty {
                self.showEmptyPasswordError(over: dlg)
                return
            }
            let wait = WaitDialogViewController(
                message: Localization.shared.getWaitUnlockByLangValues())
            dlg.present(wait, animated: true)
            Task.detached(priority: .userInitiated) { [weak self, weak dlg, weak wait] in
                // Preserve the typed error so the
                // UI can distinguish lockout from wrong-password.
                var failure: Error? = nil
                do {
                    try Self.verifyOnlyIfPresent(password: pw)
                } catch {
                    failure = error
                }
                let err = failure
                await MainActor.run {
                    wait?.dismiss(animated: true) {
                        if err == nil {
                            dlg?.dismiss(animated: true) { then(pw) }
                        } else if let dlg = dlg {
                            self?.showUnlockError(over: dlg, error: err)
                        }
                    }
                }
            }
        }
        present(dlg, animated: true)
    }

    @objc private func tapBackupCloud() {
        // Mirror Android `startCloudBackupFromOptionsScreen`:
        // 1. show the cloud-backup info dialog,
        // 2. prompt for a fresh backup password (`BackupPasswordDialog`),
        // 3. re-encrypt the wallet with that password while showing
        // `WaitDialog`,
        // 4. write the encrypted JSON via the security-scoped folder
        // picked through `UIDocumentPickerViewController(forOpening:
        // [.folder])` - the iOS analog of Android's
        // `Intent.ACTION_OPEN_DOCUMENT_TREE`.
        let info = ConfirmDialogViewController(
            title: "",
            message: Localization.shared.getCloudBackupInfoByLangValues(),
            confirmText: Localization.shared.getOkByLangValues(),
            hideCancel: true)
        info.onConfirm = { [weak self] in self?.promptBackupPassword(target: .cloud) }
        present(info, animated: true)
    }

    @objc private func tapBackupFile() {
        // Mirror Android `startFileBackupFromOptionsScreen`:
        // 1. prompt for a backup password,
        // 2. re-encrypt while showing `WaitDialog`,
        // 3. save the encrypted JSON via
        // `UIDocumentPickerViewController(forExporting:)` - the iOS
        // analog of Android's `Intent.ACTION_CREATE_DOCUMENT`.
        promptBackupPassword(target: .file)
    }

    private func promptBackupPassword(target: BackupTarget) {
        // Pass `generatedAddress` so the dialog's hidden `.username`
        // field can scope the iOS Keychain Save prompt to a per-
        // wallet slot (see `CredentialIdentifier.backupUsername(address:)`),
        // preventing this Save from overwriting another wallet's
        // backup credential or the strongbox credential.
        let dlg = BackupPasswordDialog(mode: .create(address: generatedAddress))
        dlg.onSubmit = { [weak self, weak dlg] backupPwd in
            guard let self = self else { return }
            dlg?.dismiss(animated: true) { [weak self] in
                self?.encryptAndExportBackup(target: target, password: backupPwd)
            }
        }
        present(dlg, animated: true)
    }

    private func encryptAndExportBackup(target: BackupTarget, password: String) {
        // During fresh wallet creation `generatedSeed` is populated by
        // `generateSeedWords` / `persistPendingWallet` and survives
        // through to this point, so we can hand it directly to the
        // shared exporter without re-decrypting. Onboarding only ever
        // reaches this surface with a freshly-generated seed phrase,
        // so the `.seedWords` branch is always correct here - the
        // key-only branch is exercised exclusively from
        // `BackupOptionsViewController` for wallets imported via
        // `walletFromKeys` that never had a recoverable phrase.
        BackupExporter.reencryptAndExport(
            payload: .seedWords(generatedSeed),
            address: generatedAddress,
            backupPassword: password,
            target: target,
            presenter: self)
    }

    @objc private func tapBackupDone() {
        // Mirror Android `finishBackupAndNavigateToHome` ->
        // `requirePasswordReentryThenNavigate`: prompt the user to retype
        // the password they just set before we route home, so the
        // session begins unlocked and we confirm they still know it.
        // Validation goes through `bootstrapOrUnlock(password:)`,
        // which performs the same scrypt-derived AES-GCM decrypt that
        // Android's `SecureStorage.unlock` does (N=262144, r=8, p=1,
        // keyLen=32). We wrap it in a `WaitDialogViewController` because
        // scrypt at those parameters takes ~1s on a real device.
        let dlg = UnlockDialogViewController()
        dlg.onUnlock = { [weak self, weak dlg] pw in
            guard let self = self, let dlg = dlg else { return }
            if pw.isEmpty {
                self.showEmptyPasswordError(over: dlg)
                return
            }
            let wait = WaitDialogViewController(
                message: Localization.shared.getWaitUnlockByLangValues())
            dlg.present(wait, animated: true)
            Task.detached(priority: .userInitiated) { [weak self, weak dlg, weak wait] in
                // Keep the typed error so the UI
                // can render the lockout-specific copy.
                var failure: Error? = nil
                do {
                    try Self.bootstrapOrUnlock(password: pw)
                } catch {
                    failure = error
                }
                let err = failure
                await MainActor.run {
                    wait?.dismiss(animated: true) {
                        if err == nil {
                            dlg?.dismiss(animated: true) {
                                self?.finishAndRouteHome()
                            }
                        } else if let dlg = dlg {
                            self?.showUnlockError(over: dlg, error: err)
                        }
                    }
                }
            }
        }
        present(dlg, animated: true)
    }

    /// Empty-password error surfaced as the shared orange OK alert
    /// layered on top of the unlock dialog. Distinct from
    /// `showUnlockError` so a blank field reads as "Please enter
    /// password" instead of the wrong-password copy. Field contents
    /// are preserved and the password field is refocused once the
    /// alert is dismissed (handled by `showOrangeError`).
    private func showEmptyPasswordError(over dlg: UnlockDialogViewController) {
        dlg.showOrangeError(Localization.shared.getEmptyPasswordByErrors())
    }

    /// Wrong-password error layered as the orange "exclamation
    /// triangle + OK" alert on top of the unlock dialog. The unlock
    /// dialog stays alive underneath so the typed password is
    /// preserved (no `clearField`) and the user can fix a typo
    /// without retyping it.
    private func showUnlockError(over dlg: UnlockDialogViewController) {
        showUnlockError(over: dlg, error: nil)
    }

    /// Lockout-aware unlock-error renderer. If the
    /// failure was the rate-limiter
    /// (`UnlockCoordinatorV2Error.tooManyAttempts`) the user sees
    /// the "wait N seconds" message rather than the generic
    /// wrong-password copy - which would otherwise be confusing
    /// because the password may be correct and the gate is
    /// throttling them by design. See UnlockAttemptLimiter.
    private func showUnlockError(over dlg: UnlockDialogViewController,
        error: Error?) {
        if let uc = error as? UnlockCoordinatorV2Error,
        case let .tooManyAttempts(seconds) = uc {
            dlg.showOrangeError(
                UnlockAttemptLimiter.userFacingLockoutMessage(
                    remainingSeconds: seconds))
        } else {
            dlg.showOrangeError(
                Localization.shared.getWalletPasswordMismatchByErrors())
        }
    }

    private func finishAndRouteHome() {
        (parent as? HomeViewController)?.showMain()
    }

    // MARK: - Parse helpers

    /// Map `UnlockCoordinatorV2Error` (and other low-level errors)
    /// to a user-visible string. The most common case during
    /// commit is `authenticationFailed` from a wrong strongbox
    /// password; surface the same localized "wrong password"
    /// string the `UnlockDialogViewController` flows use rather
    /// than the bare `"\(error)"` enum-case description
    /// (`"authenticationFailed"`).
    nonisolated private static func userFacingError(_ error: Error) -> String {
        if let uc = error as? UnlockCoordinatorV2Error {
            switch uc {
                case .authenticationFailed:
                return Localization.shared.getWalletPasswordMismatchByErrors()
                case .tooManyAttempts(let s):
                return UnlockAttemptLimiter.userFacingLockoutMessage(
                    remainingSeconds: s)
                case .tamperDetected:
                // Surface the friendly "reinstall to clear" copy
                // instead of the developer-facing
                // `UnlockCoordinatorV2: tamper detected (...)`
                // description. The user has no recovery path other
                // than reinstalling the app to wipe the unreadable
                // slot files; the localized string spells that out
                // without leaking the implementation detail of
                // which slot failed which check.
                return Localization.shared.getWalletDataUnreadableByErrors()
                default:
                break
            }
        }
        return "\(error)"
    }

    /// Mirror of `HomeViewController.resolveBlockExplorerBase`:
    /// `Constants.BLOCK_EXPLORER_URL` is only populated after a network
    /// is activated by `BlockchainNetwork.activate(...)`, which the
    /// onboarding flow has not yet done. Falling back to the active
    /// network's `blockExplorerUrl` keeps the explorer button on the
    /// confirm-wallet screen working before the user finishes setup.
    private static func resolveBlockExplorerBase() -> String {
        let primary = Constants.BLOCK_EXPLORER_URL
        if !primary.isEmpty { return primary }
        return BlockchainNetworkManager.shared.active?.blockExplorerUrl ?? ""
    }

    // MARK: - Small widget factory

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
    /// Background-coloured panel sized to match the seed grid; only
    /// becomes visible when `UIScreen.isCaptured == true`. See
    /// `ScreenCaptureGuard.swift`.
    private func makeSeedCaptureWarning() -> UIView {
        let v = UIView()
        v.backgroundColor = UIColor(named: "colorBackground") ?? .systemBackground
        let label = UILabel()
        label.text = Localization.shared.getSeedHiddenForCaptureByLangValues()
        label.font = Typography.body(13)
        label.numberOfLines = 0
        label.textAlignment = .center
        label.textColor = UIColor(named: "colorCommon6") ?? .label
        label.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(label)
        NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: v.topAnchor, constant: 12),
                label.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -12),
                label.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
                label.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -16)
            ])
        return v
    }
    /// `purpose` defaults to `.existingPassword` so legacy callers
    /// stay fill-only. Pass `.newPassword` ONLY at credential-
    /// creation moments so iOS surfaces the Save Password sheet
    /// (still opt-in for the user).
    private func makeSecureField(placeholder: String,
        purpose: PasswordTextField.Purpose = .existingPassword)
    -> PasswordTextField {
        let t = PasswordTextField(purpose: purpose)
        t.placeholder = placeholder
        return t
    }
    private func makeErrorLabel() -> UILabel {
        let l = UILabel()
        l.font = Typography.body(12)
        l.textColor = .systemRed
        l.numberOfLines = 0
        l.isHidden = true
        return l
    }

    /// Underlined "Click here to reveal..." link used to gate the seed
    /// grid on the seed-show step. Mirrors Android's
    /// `textView_home_seed_words_show` (UnderlineSpan).
    /// Implemented as a UIButton so it picks up the standard
    /// `enablePressFeedback` alpha-dim treatment automatically.
    private func makeRevealLabel(text: String) -> UIButton {
        let b = UIButton(type: .system)
        b.setAttributedTitle(NSAttributedString(
                string: text,
                attributes: [
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: UIColor(named: "colorPrimary") ?? UIColor.systemBlue,
                    .font: Typography.mediumLabel(15)
                ]), for: .normal)
        b.titleLabel?.numberOfLines = 0
        // Left-align the title so it reads as a body link rather than
        // a centered button label, matching the Android TextView.
        b.contentHorizontalAlignment = .leading
        b.contentEdgeInsets = .zero
        return b
    }

    /// Underlined system-blue "Skip" link used on the verify-seed
    /// screen. Mirrors Android `textView_home_seed_words_edit_skip`
    /// (`textColor=#2196F3`, `textSize=16dp`, end-aligned).
    /// Implemented as a UIButton so it picks up the standard
    /// `enablePressFeedback` alpha-dim treatment automatically.
    private func makeSkipLink(text: String) -> UIButton {
        let b = UIButton(type: .system)
        b.setAttributedTitle(NSAttributedString(
                string: text,
                attributes: [
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .foregroundColor: UIColor.systemBlue,
                    .font: Typography.mediumLabel(16)
                ]), for: .normal)
        b.contentHorizontalAlignment = .trailing
        b.contentEdgeInsets = .zero
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    /// Copy-row beneath the seed grid: `copy_outline` icon + `#2196F3`
    /// "Copy" link + inline "Copied" label that flashes for 600ms
    /// after each tap. Matches Android's `home_wallet_fragment.xml`
    /// (lines 1993-2027) and `HomeWalletFragment.homeCopyClickListener`
    /// (lines 691-709), and matches the iOS Reveal screen's copy row.
    /// The supplied `onTap` closure handles the actual pasteboard
    /// write; it does NOT need to surface its own confirmation - the
    /// inline "Copied" label provides the feedback.
    private func makeCopyRow(onTap: @escaping () -> Void) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 4

        let icon = UIButton(type: .custom)
        let img = UIImage(named: "copy_outline")?
        .withRenderingMode(.alwaysTemplate)
        icon.setImage(img, for: .normal)
        icon.tintColor = UIColor(named: "colorCommon6") ?? .label
        icon.adjustsImageWhenHighlighted = true
        icon.widthAnchor.constraint(equalToConstant: 28).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 28).isActive = true

        let label = UIButton(type: .system)
        label.setTitle(Localization.shared.getCopyByLangValues(), for: .normal)
        label.titleLabel?.font = Typography.mediumLabel(15)
        // Android `#2196F3` on the copy link, no underline.
        label.setTitleColor(
            UIColor(red: 0x21 / 255.0, green: 0x96 / 255.0, blue: 0xF3 / 255.0, alpha: 1),
            for: .normal)
        label.contentEdgeInsets = UIEdgeInsets(top: 0, left: 4, bottom: 0, right: 0)

        let copied = UILabel()
        copied.text = Localization.shared.getCopiedByLangValues()
        copied.font = Typography.body(13)
        copied.textColor = UIColor(named: "colorCommon6") ?? .label
        copied.isHidden = true

        let flashAndCopy: () -> Void = { [weak copied] in
            onTap()
            copied?.isHidden = false
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak copied] in
                copied?.isHidden = true
            }
        }
        icon.addAction(UIAction(handler: { _ in flashAndCopy() }), for: .touchUpInside)
        label.addAction(UIAction(handler: { _ in flashAndCopy() }), for: .touchUpInside)

        row.addArrangedSubview(icon)
        row.addArrangedSubview(label)
        row.addArrangedSubview(copied)
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        return row
    }
    /// Onboarding "Next" / "Skip" / "Back" buttons. Mirrors Android's
    /// `wrap_content + layout_gravity="right"` pill button - sized to
    /// fit its title, not stretched edge-to-edge. Use
    /// `wrapPrimaryRight(_:)` when adding to the vertical content stack
    /// so the button docks to the trailing edge with a flexible spacer.
    private func makeNextButton(title: String? = nil) -> UIButton {
        let b = makePrimaryButton(title ?? Localization.shared.getNextByLangValues())
        // Hug content tightly so the button is "normal width", not the
        // full content-stack width.
        b.contentEdgeInsets = UIEdgeInsets(top: 0, left: 22, bottom: 0, right: 22)
        b.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        b.setContentCompressionResistancePriority(.required, for: .horizontal)
        return b
    }

    /// Header row with the circle-back button on the left, used as the
    /// first child of every onboarding step except the very first
    /// password step. Mirrors Android `top_linear_layout_home_wallet_id`
    /// in `home_wallet_fragment.xml`.
    private func makeBackBar() -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.heightAnchor.constraint(equalToConstant: 44).isActive = true
        row.addArrangedSubview(makeBackButton())
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        return row
    }

    /// Lone "back" image button. Used inside both `makeBackBar` and
    /// the seed-verify top-row (back ◀ ───── Skip).
    private func makeBackButton() -> UIButton {
        let b = UIButton(type: .custom)
        let img = UIImage(named: "arrow_back_circle_outline")?
        .withRenderingMode(.alwaysTemplate)
        b.setImage(img, for: .normal)
        b.tintColor = UIColor(named: "colorCommon6") ?? .label
        b.adjustsImageWhenHighlighted = true
        b.widthAnchor.constraint(equalToConstant: 32).isActive = true
        b.heightAnchor.constraint(equalToConstant: 32).isActive = true
        b.addTarget(self, action: #selector(tapBackBar), for: .touchUpInside)
        return b
    }

    /// 1pt thin rule used above radios and above the Next button on
    /// onboarding screens. Mirrors Android `line_2_shape` rendered at
    /// `alpha=0.2`.
    private func makeRule() -> UIView {
        let line = UIView()
        line.backgroundColor = (UIColor(named: "colorCommon6") ?? .label)
        .withAlphaComponent(0.2)
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    /// Standardized "Please select an option" error dialog used by the
    /// Next handlers on multi-choice steps that no longer auto-select.
    private func showSelectAnOption() {
        let L = Localization.shared
        let dlg = ConfirmDialogViewController(
            title: "",
            message: L.getSelectOptionByErrors(),
            confirmText: L.getOkByLangValues(),
            hideCancel: true)
        present(dlg, animated: true)
    }

    @objc private func tapBackBar() {
        goBackOneStep()
    }

    /// Reverse of the forward-flow router, mirroring Android's back-button
    /// behaviour in `HomeWalletFragment`. The first password screen never
    /// gets a back button (Android `firstTimeSetup` gate at line 376-401),
    /// so `step == .setPassword` is unreachable here. From
    /// `.createOrRestore`, returning users with at least one wallet pop
    /// back to the wallets list rather than the password screen.
    private func goBackOneStep() {
        switch step {
            case .setPassword:
            return
            case .createOrRestore:
            // Returning user adding a new wallet? Pop to wallets list.
            // The v2 boot state tells us whether a slot file exists
            // on disk; that is the right signal for "has the user
            // ever created a wallet?" because the snapshot may not
            // be loaded yet. First-time setup users always pass
            // through phoneBackup on the way here, so back drops
            // them onto that screen.
            if case .strongboxPresent = UnlockCoordinatorV2.bootState() {
                (parent as? HomeViewController)?.showWallets()
            } else {
                step = .phoneBackup
            }
            case .phoneBackup:
            step = .setPassword
            case .walletType:
            // Phone Backup now sits earlier in the chain, so wallet
            // type's back goes to create-or-restore unconditionally.
            step = .createOrRestore
            case .seedLength:
            // Restore path no longer visits `.walletType`, so back
            // pops to the previous real screen.
            if createNotRestore {
                step = .walletType
            } else {
                step = .createOrRestore
            }
            case .seedShow:
            // Restore branch comes through .seedLength; create branch
            // comes directly from .walletType.
            if createNotRestore {
                step = .walletType
            } else {
                step = .seedLength
            }
            case .seedVerify:
            // Re-arm the reveal gate so the words are not auto-shown.
            seedRevealed = false
            step = .seedShow
            case .confirmWallet:
            // Restore-branch only. Pop back to phrase entry.
            step = .seedShow
            case .backupOptions:
            // Already commited the wallet to the keystore at this point;
            // routing back is harmless because `commitGeneratedWallet`
            // short-circuits when `walletIndex >= 0`.
            if createNotRestore {
                step = .seedVerify
            } else {
                step = .confirmWallet
            }
            case .done:
            return
        }
    }

    /// Wrap a button row in a right-docked horizontal stack so the
    /// button sits flush to the trailing edge instead of stretching to
    /// fill the column. Mirrors Android's `layout_gravity="right"` on
    /// the Next button in `home_wallet_fragment.xml`.
    private func wrapPrimaryRight(_ buttons: UIView...) -> UIView {
        let row = UIStackView()
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 10
        let spacer = UIView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        row.addArrangedSubview(spacer)
        for b in buttons { row.addArrangedSubview(b) }
        return row
    }
    /// Confirm-Wallet address row: mono bold address on the first line,
    /// copy + open-in-block-explorer buttons on a separate line below.
    /// Previous single-row layout cramped the inline "Copied" label so
    /// the user only saw "C..."; copy feedback now uses the same Toast
    /// pattern as the seed-show copy row, which is unmissable.
    private func makeAddressRow(address: String) -> UIView {
        let value = UILabel()
        value.text = address
        value.font = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        value.numberOfLines = 0
        value.lineBreakMode = .byCharWrapping
        value.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Use the same asset glyphs as the post-unlock main wallet
        // strip (`CenterStripView.configureIcon` in
        // `Navigation/ChromeViews.swift`) so onboarding's confirm
        // screen visually matches the home view.
        let copyButton = UIButton(type: .custom)
        let copyImage = UIImage(named: "copy_outline")?
        .withRenderingMode(.alwaysTemplate)
        copyButton.setImage(copyImage, for: .normal)
        copyButton.tintColor = UIColor(named: "colorCommon6") ?? .label
        copyButton.imageView?.contentMode = .scaleAspectFit
        copyButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        copyButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        copyButton.accessibilityLabel = Localization.shared.getCopyByLangValues()
        copyButton.addAction(UIAction(handler: { _ in
                guard !address.isEmpty else { return }
                // Wallet-address copy. Lower sensitivity
                // than a seed phrase (an address is public the moment any
                // tx involving it lands on chain) but Universal Clipboard
                // replication of an address still leaks the user's identity
                // to an attacker who phishes their iCloud account, so the
                // hardened wrapper applies here too. See Pasteboard.swift.
                Pasteboard.copySensitive(address)
                Toast.showMessage(Localization.shared.getCopiedByLangValues())
            }), for: .touchUpInside)

        let exploreButton = UIButton(type: .custom)
        let exploreImage = UIImage(named: "address_explore")?
        .withRenderingMode(.alwaysTemplate)
        exploreButton.setImage(exploreImage, for: .normal)
        exploreButton.tintColor = UIColor(named: "colorCommon6") ?? .label
        exploreButton.imageView?.contentMode = .scaleAspectFit
        exploreButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        exploreButton.heightAnchor.constraint(equalToConstant: 32).isActive = true
        exploreButton.addAction(UIAction(handler: { _ in
                guard !address.isEmpty else { return }
                let base = Self.resolveBlockExplorerBase
                guard !base().isEmpty else {
                    Toast.showError(Localization.shared.getNoActiveNetworkByLangValues())
                    return
                }
                // Validated URL composition.
                if let u = UrlBuilder.blockExplorerAccountUrl(
                    base: base(), address: address) {
                    UIApplication.shared.open(u)
                }
            }), for: .touchUpInside)

        let iconRow = UIStackView(arrangedSubviews: [copyButton, exploreButton, UIView()])
        iconRow.axis = .horizontal
        iconRow.alignment = .center
        iconRow.spacing = 12

        let container = UIStackView(arrangedSubviews: [value, iconRow])
        container.axis = .vertical
        container.alignment = .fill
        container.spacing = 8
        return container
    }

    /// Populate the Confirm-Wallet balance label and swap the
    /// adjacent refresh icon for a spinner for the duration of the
    /// fetch. Mirrors Android's `getBalanceByAccount` ->
    /// `CoinUtils.formatWei` so a freshly restored, funded wallet
    /// displays a human-readable amount instead of the raw wei
    /// integer the API returns. `pendingAddress` is captured at
    /// dispatch time so a mid-flow network swap does not surprise
    /// the user by retargeting an in-flight fetch.
    private func fetchAndShowBalance(label: UILabel,
                                     refreshSwap: RefreshIconSwap) {
        let addr = pendingAddress
        guard !addr.isEmpty else {
            label.text = CoinUtils.UNKNOWN_BALANCE_PLACEHOLDER
            return
        }
        refreshSwap.setLoading(true)
        Task { @MainActor in
            do {
                let resp = try await AccountsApi.accountBalance(address: addr)
                label.text = CoinUtils.formatWei(resp.result?.balance)
            } catch {
                label.text = CoinUtils.UNKNOWN_BALANCE_PLACEHOLDER
            }
            refreshSwap.setLoading(false)
        }
    }

    private func makePrimaryButton(_ title: String) -> UIButton {
        let b = UIButton(type: .system)
        b.setTitle(title, for: .normal)
        b.titleLabel?.font = Typography.mediumLabel(15)
        b.backgroundColor = UIColor(named: "colorPrimary") ?? .systemBlue
        // `colorCommon7` is white in light mode and black in dark mode.
        // Matches the convention already used by `GreenPillButton` /
        // `GrayPillButton` so the onboarding `Next`, `Backup to Cloud`,
        // and `Backup to File` titles flip to black in dark mode
        // instead of staying hard-coded white against the purple pill.
        b.setTitleColor(UIColor(named: "colorCommon7") ?? .white, for: .normal)
        b.layer.cornerRadius = 10
        b.heightAnchor.constraint(equalToConstant: 44).isActive = true
        return b
    }
}

// MARK: - Radio group + seed grid

/// Vertical group of radio-style rows. Uses `.custom` buttons (not
/// `.system`) and disables highlight tinting so tapping a row does not
/// flash the panel - the same fix already applied to
/// `ChoiceRowButton` in `HomeStartViewController`.
public final class RadioGroup: UIStackView {
    private var choices: [(tag: Int, button: UIButton)] = []
    public var selectedTag: Int?
    public override init(frame: CGRect) {
        super.init(frame: frame); axis = .vertical; spacing = 6
    }
    required init(coder: NSCoder) { fatalError() }
    public func addChoice(tag: Int, title: String) {
        let b = UIButton(type: .custom)
        b.setTitle("◯ \(title)", for: .normal)
        b.contentHorizontalAlignment = .leading
        b.titleLabel?.font = Typography.body(15)
        b.titleLabel?.numberOfLines = 0
        b.contentEdgeInsets = UIEdgeInsets(top: 6, left: 4, bottom: 6, right: 4)
        b.adjustsImageWhenHighlighted = false
        b.setTitleColor(.label, for: .normal)
        b.setTitleColor(.label, for: .highlighted)
        b.tag = tag
        b.addTarget(self, action: #selector(tap(_:)), for: .touchUpInside)
        choices.append((tag, b))
        addArrangedSubview(b)
    }
    public func select(tag: Int) {
        selectedTag = tag
        redraw()
    }
    @objc private func tap(_ sender: UIButton) {
        selectedTag = sender.tag
        redraw()
    }
    private func redraw() {
        // Wrap the title swap in `performWithoutAnimation` so the
        // intrinsic-size relayout doesn't ripple through the parent
        // UIStackView with an animated frame change. Without this the
        // panel visibly "blinks" when the user picks a radio.
        UIView.performWithoutAnimation {
            for (tag, b) in choices {
                let text = b.title(for: .normal)?
                .replacingOccurrences(of: "◯ ", with: "")
                .replacingOccurrences(of: "● ", with: "") ?? ""
                b.setTitle((tag == selectedTag ? "● " : "◯ ") + text, for: .normal)
            }
            layoutIfNeeded()
        }
    }
}

/// 4-column seed-words grid used for both display ("show") and entry
/// ("verify" / "restore"). Each chunk of 4 cells is preceded by a
/// captions row (`A1 A2 A3 A4` etc) above the word row, mirroring
/// Android `home_wallet_fragment.xml:610-700` which puts caption
/// TextViews on a separate `LinearLayout` row above the word/chip
/// row, centered with `colorCommonSeed{Letter}` text.
/// Display mode: chip background = `colorCommonSeed{Letter}`, word
/// text = white, uppercased.
/// Editable mode: chip background = white (catalog `colorCommon7` so it
/// inverts in dark mode), text = catalog `colorCommon6`, 2pt border
/// coloured per row (`colorCommonSeed{Letter}`), BIP39 prefix-
/// autocomplete via `SeedAutoCompleteTextField`. Pressing return on
/// a chip advances first responder to the next chip - mirroring
/// Android's `imeOptions="actionNext"` chain.
public final class SeedChipGrid: UIView {

    private let words: [String]
    private let editable: Bool
    private var fields: [SeedAutoCompleteTextField] = []

    public init(words: [String], editable: Bool) {
        self.words = words; self.editable = editable
        super.init(frame: .zero)
        build()
        configureAccessibility()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// BIP39 seed words must NOT be exposed to VoiceOver as
    /// individual chip labels. A user with VoiceOver
    /// enabled in a public space would otherwise have each seed
    /// word read out loud the moment focus walks the grid.
    /// Retraction of prior position: the previous rationale
    /// exempted editable mode from VoiceOver suppression
    /// on the argument that "the user already knows what they
    /// typed". That rationale is now retracted. The threat is not
    /// "the user learns their own seed" - it is "anything the
    /// VoiceOver pipeline sees can be observed by:
    ///   * a Bluetooth/HearingAid eavesdropper within range
    ///   * an Audio Hijack-class extension on a paired Mac
    ///   * a CarPlay session forwarding the audio bus
    ///   * an over-the-shoulder observer with the device speaker
    ///     (the user may have VoiceOver on for other reasons)
    /// any of which compromises the seed in clear text bypassing
    /// every other on-device protection. The UX tradeoff is
    /// explicit: a VoiceOver-only user cannot confirm by ear what
    /// they typed, but they can still tap-to-focus and the
    /// keyboard remains fully functional. We deliberately accept
    /// that regression on the four seed-bearing surfaces
    /// (reveal, new-seed display, verification quiz, restore
    /// entry) because the alternative - audible seed
    /// disclosure - is unrecoverable.
    /// Mitigation: each non-editable seed chip's label has
    /// `isAccessibilityElement = false` (set in `chip(text:index:)`
    /// below); the grid as a whole exposes one summary element
    /// that says "Seed phrase is displayed on screen. Use the
    /// Copy button to copy it.". The editable branch (verify /
    /// restore screens) keeps normal accessibility because the
    /// user is actively typing into those fields - VoiceOver must
    /// be able to read the field caption (A1, B2, ...) to guide
    /// keyboard input. Editable fields contain user-entered text,
    /// not a freshly-generated secret being displayed.
    private func configureAccessibility() {
        // Editable mode is no longer short-circuited. Both
        // branches receive the same suppression posture: the
        // grid container is NOT an accessibility element, and the
        // accessibilityElementsHidden flag prevents VoiceOver from
        // walking into the per-cell labels or text fields. The
        // per-cell text fields ALSO carry isAccessibilityElement =
        // false (set in `chip(text:index:)`) so no descendant can
        // re-expose itself even if a future container layout
        // change exposes the inner views directly.
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        accessibilityLabel = nil
        accessibilityTraits = []
        // The summary element kept the non-editable surface from
        // looking blank under VoiceOver inspector. With
        // accessibilityElementsHidden set, the grid disappears
        // from the accessibility tree entirely - which is the
        // intended outcome. The screen title (set by the parent
        // controller) and the surrounding instruction labels are
        // still announced, so the user is told "Verify your seed
        // phrase" / "Your seed phrase" / etc. without any per-word
        // disclosure.
        _ = editable
        accessibilityElementsHidden = true
    }

    private func build() {
        let grid = UIStackView()
        grid.axis = .vertical
        // Tight spacing within each (caption + word) pair, looser between
        // adjacent pairs - implemented by using a single vertical stack
        // with a small spacing and adding the captions row directly
        // before each word row.
        grid.spacing = 4
        grid.translatesAutoresizingMaskIntoConstraints = false
        addSubview(grid)
        NSLayoutConstraint.activate([
                grid.topAnchor.constraint(equalTo: topAnchor),
                grid.bottomAnchor.constraint(equalTo: bottomAnchor),
                grid.leadingAnchor.constraint(equalTo: leadingAnchor),
                grid.trailingAnchor.constraint(equalTo: trailingAnchor)
            ])

        let columns = 4
        var i = 0
        while i < words.count {
            // Caption row first.
            let captionRow = UIStackView()
            captionRow.axis = .horizontal
            captionRow.spacing = 6
            captionRow.distribution = .fillEqually
            for c in 0..<columns where i + c < words.count {
                captionRow.addArrangedSubview(captionLabel(for: i + c))
            }
            grid.addArrangedSubview(captionRow)

            // Word row second.
            let wordRow = UIStackView()
            wordRow.axis = .horizontal
            wordRow.spacing = 6
            wordRow.distribution = .fillEqually
            for c in 0..<columns where i + c < words.count {
                wordRow.addArrangedSubview(chip(text: words[i + c], index: i + c))
            }
            grid.addArrangedSubview(wordRow)

            // A small spacer row to give the next caption-row group some
            // breathing room. Android uses `layout_marginBottom="5dp"`
            // on each caption + word; we collapse that into one spacer.
            let spacer = UIView()
            spacer.heightAnchor.constraint(equalToConstant: 4).isActive = true
            grid.addArrangedSubview(spacer)

            i += columns
        }
    }

    /// Caption label `A1`..`L4` rendered above the word cell row.
    /// Centered, 11pt, tinted `colorCommonSeed{Letter}` (block colour),
    /// matching Android `textView_home_seed_words_view_caption_*`.
    /// Row H is a dark-mode special case: `colorCommonSeedH` is pure
    /// `#000000` in BOTH light and dark variants of the asset (Android
    /// parity), so painting the H1..H4 captions with that asset would
    /// render invisible black text against the near-black backdrop in
    /// dark mode. Swap the H row to `colorCommon6` (black light /
    /// white dark) so the captions stay legible in either appearance;
    /// every other row keeps its vivid block colour because that
    /// already contrasts against both light and dark backgrounds.
    /// `UILabel.textColor` is trait-aware, so the swap reacts
    /// automatically when the user toggles dark mode at runtime.
    private func captionLabel(for index: Int) -> UILabel {
        let letter = Self.letter(for: index)
        let column = (index % 4) + 1
        let l = UILabel()
        l.text = "\(letter)\(column)"
        l.font = Typography.body(11)
        l.textAlignment = .center
        let captionColor: UIColor =
            (letter == "H"
             ? (UIColor(named: "colorCommon6") ?? .label)
             : (UIColor(named: "colorCommonSeed\(letter)") ?? .label))
        l.textColor = captionColor
        return l
    }

    private func chip(text: String, index: Int) -> UIView {
        let letter = Self.letter(for: index)
        let rowColor = UIColor(named: "colorCommonSeed\(letter)") ?? .systemGray5

        let container: UIView
        if editable {
            if letter == "H" {
                // Dark-mode special case for the all-black H row.
                // `colorCommonSeedH` is `#000000` in BOTH variants
                // (Android parity), so a `ShapeFactory.roundedRect`
                // stroke painted with that asset disappears against
                // the dark page backdrop in dark mode. Instead use
                // `colorCommon6` (black light / white dark) and a
                // tiny `_DynamicBorderRoundedRect` subclass that
                // re-resolves `layer.borderColor` on every trait
                // collection change - `CALayer.borderColor` is a
                // `CGColor` snapshot and would not otherwise update
                // when the user toggles appearance at runtime. The
                // hard-coded white fill + black foreground (set in
                // the editable text-field branch below) is preserved
                // in BOTH appearances so this cell stays
                // visually identical to the Android editable seed
                // chip; only the border swaps.
                let v = _DynamicBorderRoundedRect()
                v.backgroundColor = .white
                v.layer.cornerRadius = 8
                v.layer.borderWidth = 2
                v.layer.masksToBounds = true
                v.dynamicBorderColor = UIColor(named: "colorCommon6") ?? .label
                container = v
            } else {
                // Hard-coded white fill + 2pt coloured border per
                // row, mirroring Android's `bg_seed_edit_*_curve`
                // (fill white, stroke colorCommonSeed*). Intentionally
                // NOT using `colorCommon7` here so the editable cell
                // stays white in dark mode (Android parity); flipping
                // the fill to black would clash with the colourful
                // borders. Non-H rows use a fixed vivid stroke that
                // already reads against either appearance, so a plain
                // `ShapeFactory.roundedRect` snapshot border is fine.
                container = ShapeFactory.roundedRect(
                    fill: .white, cornerRadius: 8,
                    stroke: rowColor, strokeWidth: 2)
            }
        } else {
            container = ShapeFactory.roundedRect(fill: rowColor, cornerRadius: 8)
        }
        container.heightAnchor.constraint(equalToConstant: 32).isActive = true

        if editable {
            let tf = SeedAutoCompleteTextField()
            tf.text = text.uppercased()
            tf.textAlignment = .center
            tf.font = Typography.mono(13)
            // Hard-coded black to pair with the hard-coded white fill
            // above (Android parity); using `colorCommon6` would flip
            // the text to white in dark mode and disappear against the
            // white cell.
            tf.textColor = .black
            tf.borderStyle = .none
            tf.returnKeyType = .next
            tf.delegate = self
            tf.translatesAutoresizingMaskIntoConstraints = false
            // Each editable seed cell MUST NOT be a VoiceOver
            // element. Sighted users still tap-to-focus
            // and the keyboard works normally; VoiceOver simply
            // does not enumerate or echo the typed letters. See
            // the comment block above `configureAccessibility()`
            // for the threat model and the explicit UX tradeoff.
            // The container is also marked hidden so a descendant-
            // walker cannot reach the field that way.
            tf.isAccessibilityElement = false
            tf.accessibilityElementsHidden = true
            tf.accessibilityLabel = nil
            container.isAccessibilityElement = false
            container.accessibilityElementsHidden = true
            container.addSubview(tf)
            NSLayoutConstraint.activate([
                    tf.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
                    tf.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
                    tf.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
                    tf.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4)
                ])
            fields.append(tf)
            tf.tag = fields.count - 1
            tf.onCommit = { [weak self] _ in self?.advanceFocus(after: tf) }
        } else {
            let label = UILabel()
            label.text = text.uppercased() // mirrors Android `toUpperCase`
            label.textAlignment = .center
            label.font = Typography.mono(13)
            // Hard-coded white to match Android's `bg_seed_view_*_curve`
            // foreground in both light and dark mode. The chip's
            // background uses `colorCommonSeed*` which now stays the
            // same vivid colour in both traits, so flipping the
            // foreground to black via `colorCommon7` in dark mode
            // would lose contrast on the coloured block.
            label.textColor = .white
            // Do NOT expose individual seed words to VoiceOver.
            // The parent SeedChipGrid carries a single
            // summary element instead. Suppress the chip cell
            // and its container.
            label.isAccessibilityElement = false
            container.isAccessibilityElement = false
            container.accessibilityElementsHidden = true
            label.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(label)
            NSLayoutConstraint.activate([
                    label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                    label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                    label.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 4),
                    label.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -4)
                ])
        }
        return container
    }

    public func collectWords() -> [String] {
        fields.map { ($0.text ?? "").trimmingCharacters(in: .whitespaces).lowercased() }
    }

    /// Empty a single field - used to silently reject a wrong word on
    /// the verify / restore screens (Android's `setText("")` behavior).
    public func clearField(at index: Int) {
        guard fields.indices.contains(index) else { return }
        fields[index].text = ""
    }

    /// Move keyboard focus to a specific chip. Used after silent-clear
    /// so the user is dropped back into the offending field.
    @discardableResult
    public func focusField(at index: Int) -> Bool {
        guard fields.indices.contains(index) else { return false }
        return fields[index].becomeFirstResponder()
    }

    fileprivate func advanceFocus(after current: UITextField) {
        let i = current.tag
        if fields.indices.contains(i + 1) {
            fields[i + 1].becomeFirstResponder()
        } else {
            current.resignFirstResponder()
        }
    }

    private static func letter(for i: Int) -> String {
        let letters = ["A","B","C","D","E","F","G","H","I","J","K","L"]
        return letters[i / 4 % letters.count]
    }
}

extension SeedChipGrid: UITextFieldDelegate {
    public func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        advanceFocus(after: textField)
        return true
    }
}

/// Tiny `UIView` whose `layer.borderColor` tracks an asset-catalog
/// `UIColor` across trait-collection (light / dark) changes.
/// `CALayer.borderColor` stores a raw `CGColor`, which is a snapshot
/// of whatever the resolving trait collection produced at assignment
/// time and does NOT update when the user toggles dark mode at
/// runtime. Plain `view.layer.borderColor = uiColor.cgColor` is fine
/// for static colours but breaks for dynamic asset colours like
/// `colorCommon6` (black light / white dark). This subclass fixes
/// that by holding the source `UIColor` and re-resolving it inside
/// `traitCollectionDidChange(_:)`. Used by `SeedChipGrid` for the
/// all-black H seed row's editable border so the stroke flips from
/// black to white when the user enters dark mode.
fileprivate final class _DynamicBorderRoundedRect: UIView {
    var dynamicBorderColor: UIColor? {
        didSet { refreshBorder() }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        refreshBorder()
    }

    private func refreshBorder() {
        layer.borderColor = dynamicBorderColor?
            .resolvedColor(with: traitCollection).cgColor
    }
}

fileprivate extension Array {
    subscript(safe i: Int) -> Element? { (i >= 0 && i < count) ? self[i] : nil }
}
