// RestoreSummaryDialogViewController.swift
// Post-cloud-restore summary card. Mirrors Android's
// `HomeWalletFragment.showRestoreSummaryDialog` (lines 3430-3516)
// point-for-point — same columns, same row order, same chrome.
// Two-column TableLayout-equivalent (Status | Address) wrapped in a
// `UIScrollView` so long restore batches scroll instead of pushing
// the card past the screen edge. Header row in bold; body rows
// render the address in 12pt monospace so 64-char QuantumCoin
// addresses are visually aligned and copyable-by-eye.
// Row order: restored → alreadyExists → skipped, matching Android
// lines 3468-3478. The dialog is non-cancelable (swipe-down /
// back-tap blocked) and exposes a single OK button — the user has
// to acknowledge the outcome before returning to the wizard /
// wallets screen.
// Empty-state policy: same as Android. We do not insert an empty-
// state placeholder row; an empty body simply renders the header
// row and nothing else. This is intentional so the caller can
// always present the dialog without first guarding on "is there
// anything to show".
// Android reference:
// app/src/main/java/com/quantumcoin/app/view/fragment/HomeWalletFragment.java
// (showRestoreSummaryDialog + buildSummaryRow)

import UIKit

public final class RestoreSummaryDialogViewController: ModalDialogViewController {

    public var onClose: (() -> Void)?

    private let restored: [String]
    private let alreadyExists: [String]
    private let skipped: [String]

    private let titleLabel = UILabel()
    private let scroll = UIScrollView()
    private let table = UIStackView()
    private let okButton = GreenPillButton(type: .system)

    public init(restored: [String], alreadyExists: [String], skipped: [String]) {
        self.restored = restored
        self.alreadyExists = alreadyExists
        self.skipped = skipped
        super.init(nibName: nil, bundle: nil)
        // iOS analog of Android's `setCancelable(false)`. With this set,
        // a swipe-down on the sheet handle (iPad/large-form-factor
        // presentation styles) won't auto-dismiss the modal; the only
        // way out is the OK button. The dim background also ignores
        // taps because `ModalDialogViewController` doesn't install a
        // tap-to-dismiss gesture on the scrim.
        isModalInPresentation = true
    }

    required init?(coder: NSCoder) { fatalError() }

    public override func viewDidLoad() {
        super.viewDidLoad()
        let L = Localization.shared

        // Title: reuse the existing `restore-from-cloud` key
        // ("Restore from Cloud") to match Android — there is no
        // dedicated `restore-summary-title` key on either platform
        // and adding one would diverge the two clients' copy.
        titleLabel.text = L.getRestoreFromCloudByLangValues()
        titleLabel.font = Typography.boldTitle(17)
        titleLabel.textAlignment = .center

        // Header row (Status | Address) in bold. Localized via
        // `restore-summary-status-column` / `restore-summary-address-
        // column`. The header row uses the same horizontal stack
        // structure as the body rows so the column widths line up.
        let statusCol = L.getRestoreSummaryStatusColumnByLangValues()
        let addressCol = L.getRestoreSummaryAddressColumnByLangValues()
        let headerRow = Self.makeRow(
            status: statusCol.isEmpty ? "Status" : statusCol,
            address: addressCol.isEmpty ? "Address" : addressCol,
            statusFont: Typography.boldTitle(14),
            addressFont: Typography.boldTitle(14),
            verticalPadding: 0,
            headerBottomPadding: 8)

        // Body table: vertical stack of row-stacks. `spacing: 0` keeps
        // the rows tight; per-row vertical padding (`verticalPadding`)
        // approximates Android's `pad * 0.25f` top + bottom insets.
        table.axis = .vertical
        table.alignment = .fill
        table.spacing = 0
        table.translatesAutoresizingMaskIntoConstraints = false
        table.addArrangedSubview(headerRow)

        let restoredLabel = nonEmpty(
            L.getRestoreSummaryStatusRestoredByLangValues(), "Restored")
        let alreadyExistsLabel = nonEmpty(
            L.getRestoreSummaryStatusAlreadyExistsByLangValues(), "Already exists")
        let skippedLabel = nonEmpty(
            L.getRestoreSummaryStatusSkippedByLangValues(), "Skipped")

        for addr in restored {
            table.addArrangedSubview(Self.makeRow(
                    status: restoredLabel, address: addr))
        }
        for addr in alreadyExists {
            table.addArrangedSubview(Self.makeRow(
                    status: alreadyExistsLabel, address: addr))
        }
        for addr in skipped {
            table.addArrangedSubview(Self.makeRow(
                    status: skippedLabel, address: addr))
        }

        // Scroll the body table so long batches don't push the card
        // past the screen. The 320pt cap matches the same "tall
        // enough to be useful, short enough to leave room for the
        // OK button on small phones" budget used by the
        // `BackupPasswordDialog` address list.
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(table)
        let preferredHeight = scroll.heightAnchor
        .constraint(equalTo: table.heightAnchor)
        preferredHeight.priority = .defaultHigh
        NSLayoutConstraint.activate([
                table.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
                table.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
                table.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
                table.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
                table.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
                scroll.heightAnchor.constraint(lessThanOrEqualToConstant: 320),
                preferredHeight
            ])

        // OK button mirrors the primary action in every other dialog
        // (see `BackupPasswordDialog`, `ConfirmDialogViewController`):
        // green pill, 43pt tall, with a flexible leading spacer
        // pushing it to the trailing edge of the button row so it
        // reads as the canonical "acknowledge and dismiss" affordance.
        okButton.setTitle(L.getOkByLangValues(), for: .normal)
        okButton.addTarget(self, action: #selector(tapOK), for: .touchUpInside)
        okButton.heightAnchor.constraint(equalToConstant: 43).isActive = true
        okButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 96).isActive = true
        let leadingSpacer = UIView()
        leadingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        leadingSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let buttonRow = UIStackView(arrangedSubviews: [leadingSpacer, okButton])
        buttonRow.axis = .horizontal
        buttonRow.spacing = 0
        buttonRow.alignment = .center
        buttonRow.distribution = .fill

        let stack = UIStackView(arrangedSubviews: [titleLabel, scroll, buttonRow])
        stack.axis = .vertical
        stack.spacing = 14
        stack.alignment = .fill
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
                stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -20),
                stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
                stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
                card.widthAnchor.constraint(equalToConstant: 340)
            ])

        view.installPressFeedbackRecursive()
    }

    /// Build a single status-address row. Used for the bold header
    /// row (pass `statusFont`/`addressFont` and `headerBottomPadding`)
    /// and for every body row (pass the defaults).
    /// Column geometry mirrors Android `TableLayout.setStretchAll
    /// Columns(true)` + `setColumnShrinkable(1, true)`: the status
    /// column hugs its text (intrinsic width), the address column
    /// takes the remaining space and compresses when the row width
    /// is tight — same visual result as the Android dialog on
    /// narrow phones.
    private static func makeRow(status: String, address: String,
        statusFont: UIFont = Typography.body(14),
        addressFont: UIFont = UIFont.monospacedSystemFont(ofSize: 12,
            weight: .regular),
        verticalPadding: CGFloat = 4,
        headerBottomPadding: CGFloat = 0) -> UIStackView {
        let statusLabel = UILabel()
        statusLabel.text = status
        statusLabel.font = statusFont
        statusLabel.numberOfLines = 1
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let addressLabel = UILabel()
        addressLabel.text = address
        addressLabel.font = addressFont
        addressLabel.numberOfLines = 1
        addressLabel.lineBreakMode = .byTruncatingMiddle
        addressLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addressLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [statusLabel, addressLabel])
        row.axis = .horizontal
        row.alignment = .firstBaseline
        row.distribution = .fill
        // 16pt gap between the status word and the address column
        // matches Android's `pad` right-padding on the status text view.
        row.spacing = 16
        row.isLayoutMarginsRelativeArrangement = true
        let bottom = headerBottomPadding > 0 ? headerBottomPadding : verticalPadding
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: verticalPadding,
            leading: 0,
            bottom: bottom,
            trailing: 0)
        return row
    }

    private func nonEmpty(_ s: String, _ fallback: String) -> String {
        s.isEmpty ? fallback : s
    }

    @objc private func tapOK() {
        dismiss(animated: true) { [onClose] in onClose?() }
    }
}
