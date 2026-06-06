// Localization.swift
// Port of `JsonInteract.java` + `JsonViewModel.java`. Reads the bundled
// `en_us.json` and exposes getters with identical method names so call
// sites ported from Android compile unchanged.
// Android reference:
// app/src/main/java/com/quantumcoinwallet/app/interact/JsonInteract.java
// app/src/main/java/com/quantumcoinwallet/app/viewmodel/JsonViewModel.java
// Note: en_us.json contains deliberate typo keys (e.g.
// `set-wallet-passowrd`). Do NOT "fix" them here - do the lookup by the
// exact key string, matching the Android field name.

import Foundation

public final class Localization {

    // MARK: - Shared instance

    public static let shared: Localization = {
        guard let url = Bundle.main.url(forResource: "en_us", withExtension: "json") else {
            assertionFailure("en_us.json missing from bundle")
            return Localization(root: [:])
        }
        do {
            let data = try Data(contentsOf: url)
            let obj = (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            return Localization(root: obj)
        } catch {
            assertionFailure("failed to parse en_us.json: \(error)")
            return Localization(root: [:])
        }
    }()

    // MARK: - Storage

    private let root: [String: Any]
    private let lang: [String: Any]
    private let errs: [String: Any]

    private init(root: [String: Any]) {
        self.root = root
        self.lang = (root["langValues"] as? [String: Any]) ?? [:]
        self.errs = (root["errors"] as? [String: Any]) ?? [:]
    }

    // MARK: - Helpers

    private func langString(_ key: String) -> String {
        (lang[key] as? String) ?? ""
    }

    private func errString(_ key: String) -> String {
        (errs[key] as? String) ?? ""
    }

    // MARK: - Info / quiz

    public func getInfoStep() -> String { (root["infoStep"] as? String) ?? "" }
    public func getInfoList() -> [[String: String]] {
        guard let arr = root["info"] as? [[String: Any]] else { return [] }
        return arr.map { step in
            var out: [String: String] = [:]
            for (k, v) in step { if let s = v as? String { out[k] = s } }
            return out
        }
    }
    public func getQuizStep() -> String { (root["quizStep"] as? String) ?? "" }
    public func getQuizWrongAnswer() -> String { (root["quizWrongAnswer"] as? String) ?? "" }
    public func getQuizNoChoice() -> String { (root["quizNoChoice"] as? String) ?? "" }
    public func getQuiz() -> [[String: Any]] { (root["quiz"] as? [[String: Any]]) ?? [] }

    // MARK: - langValues getters (alphabetical, parity with JsonInteract.java)

    public func getTitleByLangValues() -> String { langString("title") }
    public func getNextByLangValues() -> String { langString("next") }
    public func getOkByLangValues() -> String { langString("ok") }
    public func getCancelByLangValues() -> String { langString("cancel") }
    public func getCloseByLangValues() -> String { langString("close") }
    public func getSendByLangValues() -> String { langString("send") }
    public func getReceiveByLangValues() -> String { langString("receive") }
    public func getTransactionsByLangValues() -> String { langString("transactions") }
    public func getCopyByLangValues() -> String { langString("copy") }
    public func getBalanceByLangValues() -> String { langString("balance") }
    public func getCompletedTransactionsByLangValues() -> String { langString("completed-transactions") }
    public func getPendingTransactionsByLangValues() -> String { langString("pending-transactions") }
    public func getWalletsByLangValues() -> String { langString("wallets") }
    public func getSettingsByLangValues() -> String { langString("settings") }
    public func getUnlockByLangValues() -> String { langString("unlock") }
    public func getUnlockWalletByLangValues() -> String { langString("unlock-wallet") }
    public func getSelectNetworkByLangValues() -> String { langString("select-network") }
    public func getEnterAPasswordByLangValues() -> String { langString("enter-a-password") }
    public func getPasswordByLangValues() -> String { langString("password") }
    /// Typo preserved - the JSON entry is `set-wallet-passowrd`.
    public func getSetWalletPasswordByLangValues() -> String { langString("set-wallet-passowrd") }
    public func getUseStrongPasswordByLangValues() -> String { langString("use-strong-password") }
    public func getRetypePasswordByLangValues() -> String { langString("retype-password") }
    public func getRetypeThePasswordByLangValues() -> String { langString("retype-the-password") }
    public func getCreateRestoreWalletByLangValues() -> String { langString("create-restore-wallet") }
    public func getSelectAnOptionByLangValues() -> String { langString("select-an-option") }
    public func getCreateNewWalletByLangValues() -> String { langString("create-new-wallet") }
    public func getRestoreWalletFromSeedByLangValues() -> String { langString("restore-wallet-from-seed") }
    public func getSeedWordsByLangValues() -> String { langString("seed-words") }
    public func getSeedWordsInfo1ByLangValues() -> String { langString("seed-words-info-1") }
    public func getSeedWordsInfo2ByLangValues() -> String { langString("seed-words-info-2") }
    public func getSeedWordsInfo3ByLangValues() -> String { langString("seed-words-info-3") }
    public func getSeedWordsInfo4ByLangValues() -> String { langString("seed-words-info-4") }
    public func getSeedWordsShowByLangValues() -> String { langString("seed-words-show") }
    public func getVerifySeedWordsByLangValues() -> String { langString("verify-seed-words") }
    public func getWaitWalletSaveByLangValues() -> String { langString("waitWalletSave") }
    public func getWaitWalletOpenByLangValues() -> String { langString("waitWalletOpen") }
    public func getWaitUnlockByLangValues() -> String { langString("waitUnlock") }
    public func getWaitOpeningPickerByLangValues() -> String { langString("wait-opening-picker") }
    /// Secondary status string shown by `WaitDialogViewController.setStatus`
    /// during the integrity-check window of a strongbox slot write.
    /// The wait dialog's primary "Please wait..." message stays visible
    /// the entire time; the secondary slot toggles to "Verifying..."
    /// during the verify pass and clears on promote.
    public func getStatusVerifyingByLangValues() -> String { langString("status-verifying") }
    /// Banner shown by the unlock dialog when
    /// `StrongboxRedundancyState.singleSlot` is true (the previous
    /// unlock or re-mirror pass observed only one valid slot file
    /// and recovered from a backup slot). The user is gently
    /// nudged to create a fresh `.wallet` backup soon, so a second
    /// silent corruption does not destroy the last good copy.
    public func getStrongboxDegradedBannerByLangValues() -> String {
        langString("strongbox-degraded-banner")
    }
    public func getDpscanByLangValues() -> String { langString("dpscan") }
    public func getAddressByLangValues() -> String { langString("address") }
    public func getCoinsByLangValues() -> String { langString("coins") }
    public func getRevealSeedByLangValues() -> String { langString("reveal-seed") }
    public func getNetworksByLangValues() -> String { langString("networks") }
    public func getIdByLangValues() -> String { langString("id") }
    public func getNameByLangValues() -> String { langString("name") }
    public func getScanApiUrlByLangValues() -> String { langString("scan-api-url") }
    public func getRpcEndpointByLangValues() -> String { langString("rpc-endpoint") }
    public func getBlockExplorerUrlByLangValues() -> String { langString("block-explorer-url") }
    public func getAddNetworkByLangValues() -> String { langString("add-network") }
    public func getNoActiveNetworkByLangValues() -> String { langString("no-active-network") }
    public func getHelpByLangValues() -> String { langString("help") }
    public func getBlockExplorerTitleByLangValues() -> String { langString("block-explorer-title") }
    public func getAddByLangValues() -> String { langString("add") }
    public func getEnterNetworkJsonByLangValues() -> String { langString("enter-network-json") }
    public func getNetworkByLangValues() -> String { langString("network") }
    public func getEnterQuantumWalletPasswordByLangValues() -> String { langString("enter-quantum-wallet-password") }
    public func getAddressToSendByLangValues() -> String { langString("address-to-send") }
    public func getQuantityToSendByLangValues() -> String { langString("quantity-to-send") }
    public func getReceiveCoinsByLangValues() -> String { langString("receive-coins") }
    public func getSendOnlyByLangValues() -> String { langString("send-only") }
    public func getInOutByLangValues() -> String { langString("inout") }
    public func getNoMoreTransactionsByLangValues() -> String { langString("no-more-transactions") }
    public func getFromByLangValues() -> String { langString("from") }
    public func getToByLangValues() -> String { langString("to") }
    public func getHashByLangValues() -> String { langString("hash") }
    public func getSelectWalletTypeByLangValues() -> String { langString("select-wallet-type") }
    public func getWalletTypeDefaultByLangValues() -> String { langString("wallet-type-default") }
    public func getWalletTypeAdvancedByLangValues() -> String { langString("wallet-type-advanced") }
    public func getSelectSeedWordLengthByLangValues() -> String { langString("select-seed-word-length") }
    public func getSeedLength32ByLangValues() -> String { langString("seed-length-32") }
    public func getSeedLength36ByLangValues() -> String { langString("seed-length-36") }
    public func getSeedLength48ByLangValues() -> String { langString("seed-length-48") }
    public func getCopiedByLangValues() -> String { langString("copied") }
    public func getSkipByLangValues() -> String { langString("skip") }
    public func getSkipVerifyConfirmByLangValues() -> String { langString("skip-verify-confirm") }
    public func getYesByLangValues() -> String { langString("yes") }
    public func getNoByLangValues() -> String { langString("no") }
    public func getErrorOccurredByLangValues() -> String { langString("errorOccurred") }
    public func getErrorTitleByLangValues() -> String { langString("errorTitle") }
    public func getSigningByLangValues() -> String { langString("signing") }
    public func getAdvancedSigningOptionByLangValues() -> String { langString("advanced-signing-option") }
    public func getAdvancedSigningDescriptionByLangValues() -> String { langString("advanced-signing-description") }
    public func getEnabledByLangValues() -> String { langString("enabled") }
    public func getDisabledByLangValues() -> String { langString("disabled") }
    public func getBackupByLangValues() -> String { langString("backup") }
    public func getBackupPromptByLangValues() -> String { langString("backup-prompt") }
    public func getBackupDescriptionByLangValues() -> String { langString("backup-description") }
    public func getBackupEncryptedWarningByLangValues() -> String { langString("backup-encrypted-warning") }
    public func getSeedAccessibilitySummaryByLangValues() -> String { langString("seed-accessibility-summary") }
    public func getSeedHiddenForCaptureByLangValues() -> String { langString("seed-hidden-for-capture") }
    public func getAddressChecksumWarningByLangValues() -> String { langString("address-checksum-warning") }
    public func getPhoneBackupByLangValues() -> String { langString("phone-backup") }
    public func getBackupSavedByLangValues() -> String { langString("backup-saved") }
    public func getBackupSubmittedCloudTitleByLangValues() -> String { langString("backup-submitted-cloud-title") }
    public func getBackupSubmittedCloudMessageByLangValues() -> String { langString("backup-submitted-cloud-message") }
    public func getBackupFailedByLangValues() -> String { langString("backup-failed") }
    public func getBackupPasswordByLangValues() -> String { langString("backup-password") }
    public func getConfirmBackupPasswordByLangValues() -> String { langString("confirm-backup-password") }
    public func getRestoreFromFolderByLangValues() -> String { langString("restore-from-folder") }
    public func getRestoreFromFileByLangValues() -> String { langString("restore-from-file") }
    public func getRestoreDecryptFailedByLangValues() -> String { langString("restore-decrypt-failed") }
    public func getRestoreEnterDifferentPasswordByLangValues() -> String { langString("restore-enter-different-password") }
    public func getRestoreNoBackupsFoundByLangValues() -> String { langString("restore-no-backups-found") }
    public func getRestorePasswordPromptRemainingByLangValues() -> String { langString("restore-password-prompt-remaining") }
    public func getRestoreSummaryStatusColumnByLangValues() -> String { langString("restore-summary-status-column") }
    public func getRestoreSummaryAddressColumnByLangValues() -> String { langString("restore-summary-address-column") }
    public func getRestoreSummaryStatusRestoredByLangValues() -> String { langString("restore-summary-status-restored") }
    public func getRestoreSummaryStatusSkippedByLangValues() -> String { langString("restore-summary-status-skipped") }
    public func getRestoreSummaryStatusAlreadyExistsByLangValues() -> String { langString("restore-summary-status-already-exists") }
    public func getRestoreTryDifferentPasswordByLangValues() -> String { langString("restore-try-different-password") }
    public func getRestoreStrongboxWriteFailedByLangValues() -> String { langString("restore-strongbox-write-failed") }
    public func getRestoreProgressOfByLangValues() -> String { langString("restore-progress-of") }
    public func getRestorePartialProgressByLangValues() -> String { langString("restore-partial-progress") }
    /// Wait-dialog message shown during the multi-wallet decrypt phase
    /// of the cloud-restore batch flow (`RestoreFlow.runDecryptPass`).
    /// Distinct from `waitWalletOpen` because the batch decrypt of N
    /// wallets stacks scrypt cost across slots and can run for many
    /// minutes on weak devices, whereas the single-wallet wording
    /// promises "up to a minute".
    public func getRestoreWalletsDecryptingByLangValues() -> String {
        langString("restore-wallets-decrypting")
    }
    public func getCameraPermissionDeniedByLangValues() -> String { langString("camera-permission-denied") }
    public func getCloudBackupInfoByLangValues() -> String { langString("cloud-backup-info") }
    public func getBackupToFileByLangValues() -> String { langString("backup-to-file") }
    public func getBackupDoneByLangValues() -> String { langString("backup-done") }
    public func getBackupSavedShortByLangValues() -> String { langString("backup-saved-short") }
    public func getBackupOptionsTitleByLangValues() -> String { langString("backup-options-title") }
    public func getBackupOptionsDescriptionByLangValues() -> String { langString("backup-options-description") }
    public func getEnterBackupPasswordTitleByLangValues() -> String { langString("enter-backup-password-title") }
    public func getWalletAlreadyExistsDetailedByLangValues() -> String { langString("wallet-already-exists-detailed") }
    public func getNoTransactionsByLangValues() -> String { langString("no-transactions") }
    public func getTokensByLangValues() -> String { langString("tokens") }
    /// Segmented-control "Tokens" tab on the home screen. Displays
    /// only token rows whose contract is in the binary-pinned
    /// `RecognizedTokens` allow-list.
    public func getTokensTabByLangValues() -> String { langString("tokens-tab") }
    /// Segmented-control "Unrecognized Tokens" tab on the home
    /// screen. Displays token rows that survived the stablecoin-
    /// impersonator filter but whose contract is NOT in
    /// `RecognizedTokens`.
    public func getUnrecognizedTokensTabByLangValues() -> String { langString("unrecognized-tokens-tab") }
    /// Send screen toggle row label. When the user flips this
    /// switch ON, the Send asset picker also surfaces
    /// unrecognized (but non-impersonator) tokens.
    public func getShowUnrecognizedTokensByLangValues() -> String { langString("show-unrecognized-tokens") }
    /// Transaction-review dialog header for the dedicated
    /// contract-address row, rendered below the asset
    /// (symbol/name) row whenever a token send is being
    /// reviewed. Native sends omit the row.
    public func getContractAddressByLangValues() -> String { langString("contract-address") }
    public func getNoTokensByLangValues() -> String { langString("no-tokens") }
    public func getContractByLangValues() -> String { langString("contract") }
    public func getSymbolByLangValues() -> String { langString("symbol") }
    public func getDecimalsByLangValues() -> String { langString("decimals") }
    public func getAssetToSendByLangValues() -> String { langString("asset-to-send") }
    public func getWhatIsBeingSentByLangValues() -> String { langString("what-is-being-sent") }
    public func getFromAddressByLangValues() -> String { langString("from-address") }
    public func getToAddressByLangValues() -> String { langString("to-address") }
    public func getSendQuantityByLangValues() -> String { langString("send-quantity") }
    /// Chain-id suffix shown next to the network name in the
    /// review dialog so the user can disambiguate two networks
    /// that share a display name. The chain-id displayed is the
    /// same value pin in the `NetworkSnapshot` and
    /// re-assert at submit time. See
    /// `TransactionReviewDialogViewController` for the rendering.
    public func getChainIdSuffixByLangValues() -> String { langString("chain-id-suffix") }
    /// Tamper-gate dialog labels. Each accessor
    /// has an English fallback in `TamperGatePolicy` so a missing
    /// or mistranslated entry never strips the safety message
    /// (matches the pattern).
    public func getTamperJailbreakTitleByLangValues() -> String { langString("tamper-jailbreak-title") }
    public func getTamperJailbreakMessageByLangValues() -> String { langString("tamper-jailbreak-message") }
    public func getTamperContinueAtRiskByLangValues() -> String { langString("tamper-continue-at-risk") }
    public func getTamperQuitByLangValues() -> String { langString("tamper-quit") }
    public func getTamperIgnoreAndResumeByLangValues() -> String { langString("tamper-ignore-and-resume") }
    public func getTamperJailbreakBannerByLangValues() -> String { langString("tamper-jailbreak-banner") }
    public func getTamperDebuggerTitleByLangValues() -> String { langString("tamper-debugger-title") }
    public func getTamperDebuggerMessageByLangValues() -> String { langString("tamper-debugger-message") }
    public func getTamperDebuggerBannerByLangValues() -> String { langString("tamper-debugger-banner") }
    public func getTamperRuntimeTitleByLangValues() -> String { langString("tamper-runtime-title") }
    public func getTamperRuntimeMessageByLangValues() -> String { langString("tamper-runtime-message") }
    public func getTamperRuntimeBannerByLangValues() -> String { langString("tamper-runtime-banner") }
    public func getReviewTransactionPromptByLangValues() -> String { langString("review-transaction-prompt") }
    public func getTypeIAgreeToConfirmPrefixByLangValues() -> String { langString("type-i-agree-to-confirm") }
    public func getTypeIAgreeToConfirmSuffixByLangValues() -> String { langString("type-i-agree-to-confirm-suffix") }
    public func getIAgreeLiteralByLangValues() -> String { langString("i-agree-literal") }
    public func getMustAgreeToSubmitByLangValues() -> String { langString("must-agree-to-submit") }
    public func getDecryptingWalletByLangValues() -> String { langString("decrypting-wallet") }
    public func getSubmittingTransactionByLangValues() -> String { langString("submitting-transaction") }
    public func getTransactionSentByLangValues() -> String { langString("transaction-sent") }
    public func getTransactionIdByLangValues() -> String { langString("transaction-id") }
    public func getTransactionMessageExitsByLangValues() -> String { langString("transaction-message-exits") }
    public func getBackByLangValues() -> String { langString("back") }
    public func getConfirmWalletByLangValues() -> String { langString("confirm-wallet") }
    public func getConfirmWalletDescriptionByLangValues() -> String { langString("confirm-wallet-description") }
    public func getEnterSeedWordsByLangValues() -> String { langString("enter-seed-words") }
    /// Title shown in the system notification that fires when the
    /// polled balance changes between background ticks.
    public func getNotificationTitleByLangValues() -> String { langString("notification-title") }
    /// Body prefix appended with the new formatted balance in the
    /// background balance-change notification.
    public func getNotificationDescriptionByLangValues() -> String { langString("notification-description") }
    /// Android-channel concepts retained in the catalog for parity
    /// even though iOS does not expose user-visible notification
    /// channels.
    public func getNotificationChannelNameByLangValues() -> String { langString("notification-channel-name") }
    public func getNotificationChannelDescriptionByLangValues() -> String { langString("notification-channel-description") }

    // MARK: - errors getters

    public func getSelectOptionByErrors() -> String { errString("selectOption") }
    public func getRetypePasswordMismatchByErrors() -> String { errString("retypePasswordMismatch") }
    public func getPasswordSpecByErrors() -> String { errString("passwordSpec") }
    public func getPasswordSpaceByErrors() -> String { errString("passwordSpace") }
    public func getWalletPasswordMismatchByErrors() -> String { errString("walletPasswordMismatch") }
    public func getInvalidNetworkJsonByErrors() -> String { errString("invalidNetworkJson") }
    public func getEnterAmountByErrors() -> String { errString("enterAmount") }
    public func getQuantumAddrByErrors() -> String { errString("quantumAddr") }
    public func getWalletPasswordNotSetByErrors() -> String { errString("wallet-password-not-set") }
    public func getEmptyPasswordByErrors() -> String { errString("emptyPassword") }
    /// Friendly user-facing copy for `UnlockCoordinatorV2Error.tamperDetected`.
    /// Replaces the developer-facing description so the user sees a
    /// readable explanation when stale / structurally-invalid
    /// strongbox slot files (typically left over from a previous
    /// build on dev simulators) prevent a brand-new wallet from being
    /// created. No automatic recovery is offered - the user reinstalls
    /// the app to wipe the unreadable bytes, then retries.
    public func getWalletDataUnreadableByErrors() -> String { errString("wallet-data-unreadable") }
    /// Lockout copy reused across the password retry screens; the
    /// matching Android entries live in
    /// `app/src/main/res/raw/en_us.json`. `[SECONDS]` / `[MINUTES]`
    /// placeholders are filled in by the caller.
    public func getUnlockTooManyAttemptsSecondsByErrors() -> String { errString("unlock-too-many-attempts-seconds") }
    public func getUnlockTooManyAttemptsOneMinuteByErrors() -> String { errString("unlock-too-many-attempts-one-minute") }
    public func getUnlockTooManyAttemptsMinutesByErrors() -> String { errString("unlock-too-many-attempts-minutes") }
    /// "Add Network" validation copy. Mirrors the Android
    /// `BlockchainNetworkAddFragment.*` ViewModel accessors so the
    /// English text is identical between the two platforms.
    public func getNetworkRpcMustBeHttpsByErrors() -> String { errString("network-rpc-must-be-https") }
    public func getNetworkRpcInvalidHostByErrors() -> String { errString("network-rpc-invalid-host") }
    public func getNetworkScanInvalidHostByErrors() -> String { errString("network-scan-invalid-host") }
    public func getNetworkExplorerInvalidHostByErrors() -> String { errString("network-explorer-invalid-host") }
    public func getNetworkNameFormatByErrors() -> String { errString("network-name-format") }
    public func getNetworkIdPositiveIntegerByErrors() -> String { errString("network-id-positive-integer") }
    /// Used by the duplicate-name warning shown when the user tries
    /// to add a network whose `name` matches an existing entry.
    /// `[NAME]` placeholder is filled in by the caller.
    public func getNetworkDuplicateNameByErrors() -> String { errString("network-duplicate-name") }
    public func getNetworkSecureStorageUnavailableByErrors() -> String { errString("network-secure-storage-unavailable") }
    public func getNetworkAddSuccessByErrors() -> String { errString("network-add-success") }
    /// Generic fallback used by the reveal-wallet flow when the user
    /// password decrypts the slot but key derivation does not yield a
    /// usable wallet entry.
    public func getRevealWalletErrorGenericByErrors() -> String { errString("reveal-wallet-error-generic") }
}
