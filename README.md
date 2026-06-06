# Quantum Coin Wallet — iOS

[![Platform: iOS 15+](https://img.shields.io/badge/platform-iOS%2015%2B-blue)](https://developer.apple.com/ios/)
[![Swift: 5.9](https://img.shields.io/badge/swift-5.9-orange)](https://swift.org)
[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

> **Android counterpart:** the sibling [Quantum Coin Android wallet](https://github.com/quantumcoinproject/quantum-coin-wallet-android)
> is kept feature-parity with this iOS client. Both share the same
> JavaScript SDK bundle byte-for-byte and the same `en_us.json`
> localization catalog as the canonical reference; the v=3 strongbox
> file format is byte-portable in both directions (see
> [Cross-platform interoperability](#cross-platform-interoperability)
> for the seeded vector contract).

Native iOS client for the [Quantum Coin](https://quantumcoin.org)
post-quantum blockchain. Quantum Coin is a Layer-1 quantum-resistant
blockchain that combines NIST-standardized post-quantum signature
schemes — **ML-DSA (FIPS 204)** and **SLH-DSA (FIPS 205)** — with
**ML-KEM (FIPS 203)** for node-to-node key establishment, all under
a deposit-weighted BFT consensus with immediate deterministic
finality. See the
[quantum-resistance whitepaper](https://quantumcoin.org/whitepapers/Quantum-Coin-Blockchain-Quantum-Resistance-Whitepaper.html)
and [consensus whitepaper](https://quantumcoin.org/whitepapers/Quantum-Coin-Blockchain-Consensus-Whitepaper.html)
for the protocol-level rationale.

This repository hosts the **iOS** wallet. It is a feature-parity port
of the [Quantum Coin Android wallet](https://github.com/quantumcoinproject/quantum-coin-wallet-android)
and shares the same JavaScript SDK bundle byte-for-byte, so every
signed transaction is reproducible across both clients.

> **Status:** beta. The mainnet RPC is configured at
> `https://public.rpc.quantumcoinapi.com` (chain id `123123`). See
> [`Resources/blockchain_networks.json`](QuantumCoinWallet/Resources/blockchain_networks.json).

> **This software is not an investment opportunity, an investment
> contract, or a security of any type.** See the
> [Quantum Coin homepage](https://quantumcoin.org) for the project's
> charter and decentralization-first stance.

---

## Table of contents

- [Feature list](#feature-list)
- [Security & durability features](#security--durability-features)
- [Strongbox cryptographic specification](#strongbox-cryptographic-specification)
- [Cross-platform interoperability](#cross-platform-interoperability)
- [SDKs and dependencies](#sdks-and-dependencies)
- [Architecture overview](#architecture-overview)
- [Repository layout](#repository-layout)
- [Build and run](#build-and-run)
- [Testing](#testing)
- [Threat model & non-goals](#threat-model--non-goals)
- [License](#license)
- [Further reading](#further-reading)

---

## Feature list

### Wallet management

- **Multiple wallets per install.** Stored in a single
  layered-encrypted strongbox; each wallet is addressable via the
  Wallets screen (`Screens/WalletsViewController.swift`).
- **New wallet creation** with a 32-word seed phrase (
  `QuantumCoinSDK.Wallet.createRandom` →
  `SeedWordsSDK.getWordListFromSeedArray`). Seed verification quiz
  is enforced before the wallet is persisted.
- **Restore from seed words** with BIP39-style prefix
  auto-completion (`Components/SeedAutoCompleteTextField.swift`,
  word list mirrored in `JsBridge/BIP39Words.swift`).
- **Restore from `.wallet` backup file** — single file or a folder
  of files; batched password prompt walks through every wallet in
  the picked location (`Backup/RestoreFlow.swift`).
- **Reveal seed words** (gated by tap-to-reveal +
  voice-over / accessibility lockout, see
  `Screens/RevealWalletViewController.swift`).
- **Delete wallet / delete all** with explicit confirm dialogs.

### Live balance / token refresh

- **Pull-to-refresh on the main wallet** kicks off a fresh page-1
  token fetch on the home screen and broadcasts a
  `walletHomeRefreshRequested` notification so the address strip
  reissues a manual native balance fetch
  (`Screens/HomeMainViewController.swift`,
  `Navigation/HomeViewController.swift`).
- **Refresh-icon swap** — every icon-driven refresh affordance
  hides the icon and shows a small spinner in the same slot
  while the work is in flight, then swaps back when the request
  resolves. Used on the address strip, the account-transactions
  top bar, and the onboarding confirm-wallet balance row
  (`Components/RefreshIconSwap.swift`).
- **Confirm-wallet balance loader** — the onboarding confirm
  step kicks off the balance fetch automatically with the
  refresh icon in spinner mode; tapping the icon re-fires the
  fetch (`Screens/HomeWalletViewController.swift`).
- **Preserve-on-error UX (Android-parity)** — refresh failures
  never blank previously-displayed data. Auto-refresh failures
  are silent; only user-initiated refreshes surface a
  `MessageInformationDialogViewController.error` dialog
  (`Screens/HomeMainViewController.swift`,
  `Screens/AccountTransactionsViewController.swift`).
- **Default balance is `-`** — `CoinUtils.formatWei(nil)`
  returns a single `-` (rather than `0`) so a fresh wallet
  with no successful fetch yet shows the placeholder rather
  than a misleading zero balance
  (`Utilities/CoinUtils.swift`).
- **Jittered auto-refresh cadence** — each tick samples a fresh
  uniformly-random interval in `7…15s` while foregrounded and
  `60…120s` while backgrounded, so the public RPC never sees a
  predictable polling rhythm
  (`Navigation/HomeViewController.swift`).
- **Background balance-change notifications** — after the first
  successful unlock we request `UNUserNotificationCenter`
  authorization; subsequent ticks compare to the last seen
  balance per address and post a local notification whenever the
  value changes while `UIApplication.shared.applicationState !=
  .active` (matches Android `HomeActivity.notificationThread`)
  (`Notifications/BalanceChangeNotifier.swift`).

### Sending and receiving

- **Send native QC** via the SDK's
  `wallet.sendTransaction({to, value, gasLimit, signingContext})`
  (matches Android byte-for-byte; see
  [JS SDK boundaries](#sdks-and-dependencies) below).
- **Send tokens (ERC-20-style)** via
  `IERC20.connect(contract, wallet).transfer(...)`. Token list is
  partitioned into **Tokens** (recognized) and **Unrecognized
  Tokens** tabs; impersonator filter blocks any token whose
  symbol or name resembles a stablecoin unless the contract is
  on the recognized allow-list (`Models/RecognizedTokens.swift`,
  `Models/StablecoinImpersonatorFilter.swift`).
- **Transaction review dialog** with checksum-cased addresses,
  fee summary, and explicit contract-address row for token sends
  (`Dialogs/TransactionReviewDialogViewController.swift`).
- **QR-code scanning** for recipient addresses via the system
  camera (`Components/QRScannerViewController.swift`,
  `NSCameraUsageDescription` declared in `Info.plist`).
- **Receive screen** with a `quantumcoin:` URI QR code and a
  centred copy-to-clipboard control
  (`Screens/ReceiveViewController.swift`).

### Network configuration

- **Mainnet preconfigured** at chain id `123123` and the public
  RPC endpoint
  (`Resources/blockchain_networks.json`).
- **Custom network support** — the user can add and switch between
  networks; the active network is captured at "Review" time and
  re-asserted at "Submit" time so a network switch in the middle
  of the signing flow aborts rather than producing a mis-bound
  transaction (`Networking/NetworkConfig.swift`).
- **Duplicate-network-name warning** — Add Network rejects a
  trim+case-insensitive duplicate of an existing network name
  with the Android-verbatim `network-duplicate-name` message
  (`"A network named "<NAME>" already exists."`); persistence
  does not happen and the user dismisses the dialog with OK
  (`Screens/BlockchainNetworkViewController.swift`).
- **Validation copy is localized.** Every `tapAdd` validation
  error (RPC must be https, invalid hosts, name format,
  network-id, secure-storage-unavailable, add-success) flows
  through `Localization.shared.get*ByErrors()` accessors so
  future locale changes ship via `en_us.json`, identical to
  Android.

### Backup and restore

- **File backup** via `UIDocumentPickerViewController(forExporting:)`
  — wallet is re-encrypted under a user-supplied backup password
  (independent of the unlock password), then handed to the picker.
- **Restore from folder** enumerates `.wallet` files in a
  user-picked folder (the picker reopens at the last-used folder via
  a remembered security-scoped bookmark) and runs the same
  batched-decrypt loop the file restore uses
  (`Backup/RestoreFlow.swift`).
- **Cross-platform backup compatibility.** Per-wallet exported
  `.wallet` files are produced by the shared
  `quantumcoin-bundle.js` `Wallet.encryptSync` call on both
  platforms, so a `.wallet` file written by the iOS wallet can be
  restored by the Android wallet (and vice versa) using the same
  backup password. The whole-strongbox slot
  (`Application Support/DP_QUANTUM_COIN_WALLET_APP_PREF.{A|B}.json`)
  is **also** portable in v=3 — copying it to the Android app's
  `getFilesDir()/strongbox/` directory preserves the encrypted
  bytes, and the Android wallet unlocks it with the same wallet
  password. See the [Cross-platform
  interoperability](#cross-platform-interoperability) section
  for the per-byte parity contract.

### Localization and accessibility

- English (`en_us`) localization with 230+ keys
  (`Resources/en_us.json`,
  `Localization/Localization.swift`). The `errors` catalog is
  in **full byte-identity parity** with the Android wallet's
  `app/src/main/res/raw/en_us.json` (every Android error key is
  present on iOS with the same English text); the
  `langValues` catalog matches Android verbatim. The only
  iOS-only keys are `emptyPassword` (shown when the user
  submits an empty unlock field; Android has no equivalent
  state) and `wallet-data-unreadable` (the friendly
  tamper-detected message surfaced on a hard strongbox read
  failure).
- VoiceOver / accessibility deliberately disabled on the four
  seed-handling surfaces (reveal, new-seed, verify, restore) so
  the seed words are never read aloud (`Screens/HomeWalletViewController.swift`).
- Dark mode with a small palette of semantic colors; primary
  buttons invert foreground in dark mode for contrast.

---

## Security & durability features

This is a high-value-asset wallet — every defense below has a
dedicated design-notes comment in its source file with the threat
it closes, the design rationale, and the tradeoff the team
accepted.

### Key material and signing

- **AES-256-GCM** for every encrypted-at-rest blob, in a single
  Swift owner so there is one review surface for AEAD usage
  (`Crypto/Aead.swift`).
- **scrypt KDF** at `N=2^18, r=8, p=1, keyLen=32` — runs inside the
  shared JS bundle so the Android and iOS wallets derive identical
  keys for identical passwords. Min-bound enforced at the bridge
  boundary so a future debug-weakened call fails loud
  (`Crypto/PasswordKdf.swift`, `Resources/bridge.html` `scryptDerive`).
- **Brute-force lockout** with a stair-step backoff
  (typo-tolerant for the first four attempts; 30s, 60s, 2 min,
  5 min cap). Counter lives in Keychain
  (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`) so it survives
  pref-file deletion (`Security/UnlockAttemptLimiter.swift`).
- **Tamper gate** — multi-signal jailbreak / debugger-attached /
  Mach-O-instrumentation detector. Requires ≥2 independent
  jailbreak signals before flagging; debugger-in-Release and
  runtime-tamper are hard signals. The signing chokepoint
  (`JsBridge.sendTransaction`) calls `assertSafeToSign()` before
  the private key reaches the bridge
  (`Security/TamperGate.swift`, `Security/TamperGatePolicy.swift`).
- **JS bundle SHA-256 pin** — the bundle owns every signing
  primitive, so its bytes are hashed at build time, embedded in a
  Swift `[UInt8]`, re-hashed at runtime, and the bridge refuses to
  initialize on mismatch (`scripts/embed_bundle_hash.sh`,
  `JsBridge/BundleIntegrity.swift`).
- **Binary key channel** between Swift and JS — private/public
  key bytes stage as `Uint8Array` via a synchronous custom-scheme
  XHR rather than base64 strings, so JS can `.fill(0)` them after
  use (string-pool residency would otherwise prevent zeroization)
  (`Resources/bridge.html` `pullPayloadBinary` /
  `JsEngine.PendingBinaryStore`).
- **TLS pinning** on the centralized scan API only. RPC endpoints
  are deliberately **not** pinned — the wallet is non-custodial
  and the user must be free to choose any RPC node (full node,
  Infura-class third party, community RPC). Pinning the RPC would
  hard-code centralization that the project explicitly rejects.
  Baseline TLS chain validation still applies on every endpoint
  (`Networking/TlsPinning.swift`).
- **TLS 1.3 minimum floor** on every in-process project-owned
  outbound HTTPS endpoint:
  - Scan API (`URLSession`): the singleton session in
    `Data/ApiClient.swift` sets
    `tlsMinimumSupportedProtocolVersion = .TLSv13`. A server that
    only speaks TLS 1.2 fails the handshake at connect time
    rather than downgrading; the floor applies to every host
    this session ever talks to.
  - Bundled MAINNET RPC (`WKWebView` `JsonRpcProvider`):
    `Info.plist` `NSAppTransportSecurity.NSExceptionDomains`
    carries entries for `app.readrelay.quantumcoinapi.com` and
    `public.rpc.quantumcoinapi.com` with
    `NSExceptionMinimumTLSVersion = TLSv1.3`. ATS per-domain
    floors apply to both `URLSession` and `WKWebView` HTTPS
    loads, which is the only iOS-side lever for the WKWebView
    RPC path.
  - User-defined custom RPC URLs are unknown at build time and
    cannot carry an ATS entry, so they fall through to the
    platform ATS default (TLS 1.2 minimum). The Android sibling
    `TlsPinning.java` has the identical WebView limitation.
  - Block-explorer URLs (`quantumscan.com`) are opened via
    `UIApplication.open(...)` (Safari hand-off) and never
    traverse the app's in-process TLS stack; baseline TLS via
    Safari still applies, and an ATS entry for that host would
    be a no-op (intentionally absent).
  - `tlsMaximumSupportedProtocolVersion` is left at the
    system-chosen default; no cipher-suite restriction API is
    called. Cipher curation is the OS's job, and freezing the
    suite list would risk excluding future PQC-bundled AEADs.

### Storage durability

- **Two-slot rotating writer** for the strongbox file, so a power
  cut between rename and journal-flush still leaves a valid
  previous-good slot (`Storage/AtomicSlotWriter.swift`).
- **`fcntl(F_FULLFSYNC)`** on every persisted file so bytes reach
  the storage media, not just the page cache. iOS's `fsync` does
  not guarantee media-level flush.
- **Verify-before-promote** — after `F_FULLFSYNC`, the writer
  re-reads the staged bytes uncached, hands them to a
  schema-aware deep-verify closure, and only then renames the
  `.tmp` into place. Catches NAND bit-flips, encoder bugs, and
  stale-key MAC mismatches.
- **File-level MAC** with a UI-block hash binding so an attacker
  who swaps slot files' UI prefs cannot re-bind them under the
  original MAC (`Schema/StrongboxFileCodec.swift`).
- **`.completeFileProtection`** on every file the wallet writes.
- **`isExcludedFromBackupKey`** wired through a layered
  `BackupExclusion` so the user's "phone backup" toggle decides
  whether wallet files participate in iCloud / iTunes backups
  (`Backup/BackupExclusion.swift`).

### UI hardening

- **App-switcher snapshot redaction** — opaque branded overlay is
  added in `applicationWillResignActive` so the iOS-captured app
  switcher card never contains seed words, balances, or addresses
  (`UX/SnapshotRedactor.swift`).
- **Pasteboard auto-expiry** for copied seed phrases (30s
  countdown; cleared on view-disappear) (`UX/Pasteboard.swift`).
- **Screen-capture guard** on the seed-reveal screen
  (`Security/ScreenCaptureGuard.swift`).
- **Token impersonation defenses** — recognized-token allow-list
  by **contract address** (not name/symbol), plus a stablecoin
  impersonator hard-suppressor that blocks any token whose label
  resembles `USDT` / `USDC` / `Tether` / etc. unless its contract
  is on the allow-list (`Models/RecognizedTokens.swift`,
  `Models/StablecoinImpersonatorFilter.swift`).
- **Network-snapshot capture at Review time** — the chain id and
  RPC endpoint the user confirmed are re-asserted at Submit time;
  a network switch mid-flight aborts rather than producing a
  mis-bound EIP-155 signature (`Networking/NetworkConfig.swift`).

### Defense layering recap

Each layer below independently raises an attacker's cost; they
combine multiplicatively, not additively:

| Layer | Mechanism |
| --- | --- |
| Storage  | Two-slot rotation + `F_FULLFSYNC` + verify-before-promote |
| Schema   | File-level MAC binds wraps + payload + UI-block hash |
| Crypto   | AES-256-GCM AEAD + scrypt-derived 32-byte keys |
| Unlock   | scrypt cost + Keychain-backed brute-force lockout |
| Runtime  | Tamper gate + JS bundle SHA-256 pin |
| UI       | Snapshot redaction + pasteboard expiry + impersonator filter |
| Network  | TLS chain validation on all + TLS 1.3 floor on every in-process project-owned host + SPKI pin on scan API |

---

## Strongbox cryptographic specification

This section is the byte-level specification of the on-disk
wallet store. It documents the v=3 portable schema that iOS and
Android both write and read byte-for-byte. The authoritative
source is the code; every constant quoted below is a direct
citation from the cited files, and the same constants appear in
the Android sibling repo's
[`STORAGE_LAYERED_MODEL.md`](https://github.com/quantumcoinproject/quantum-coin-wallet-android/blob/main/STORAGE_LAYERED_MODEL.md).

### 1. Layered model

The strongbox is built as five disjoint layers. Each layer
knows about the layer immediately below it and about nothing
above it; cross-layer leakage is enforced by review and by
invariant tests in `QuantumCoinWalletTests/StrongboxLayerTests.swift`.

| Layer | Responsibility | Source |
| --- | --- | --- |
| L1 — Storage | Two-slot atomic-rotate with deep verify | `QuantumCoinWallet/Storage/AtomicSlotWriter.swift` |
| L2 — Schema | Outer file envelope, file-level MAC, padding | `QuantumCoinWallet/Schema/StrongboxFileCodec.swift`, `QuantumCoinWallet/Schema/StrongboxPadding.swift` |
| L3 — Crypto | AES-256-GCM, HMAC-SHA-256, HKDF-SHA-256, scrypt | `QuantumCoinWallet/Crypto/Aead.swift`, `QuantumCoinWallet/Crypto/Mac.swift`, `QuantumCoinWallet/Crypto/PasswordKdf.swift` |
| L4 — Unlock coordinator | scrypt → unwrap mainKey → install snapshot; re-derive per write; zeroize | `QuantumCoinWallet/KeyMaterial/UnlockCoordinatorV2.swift` |
| L5 — Strongbox accessor | In-memory typed snapshot, inner checksum, per-wallet wire codec | `QuantumCoinWallet/Strongbox/Strongbox.swift`, `QuantumCoinWallet/Strongbox/StrongboxPayload.swift`, `QuantumCoinWallet/Strongbox/WalletEntryCodec.swift` |

### 2. On-disk slot layout (L1)

| Item | Value |
| --- | --- |
| Number of slots | 2 (`enum Slot { case a, b }`) |
| Directory | `FileManager.url(for: .applicationSupportDirectory, …)` |
| Filenames | `DP_QUANTUM_COIN_WALLET_APP_PREF.A.json`, `…B.json` |
| Staging filename | `…A.json.tmp` / `…B.json.tmp` |
| File protection class | `FileProtectionType.complete` (data inaccessible while device is locked) |
| Persisted-data flush | `fcntl(fd, F_FULLFSYNC)` (media-level barrier, not just `fsync`) |
| Parent-directory flush | `fcntl(dirFd, F_FULLFSYNC)` after `rename(2)` |
| Verify-before-promote | Re-read staged bytes with `Data(contentsOf:options:[.uncached])`; caller-supplied `verify` closure runs MAC verify, AEAD-open, depad, JSON decode, and a byte-by-byte canonical re-encode equality check before the rename |
| Winner selection on read | Both slots decoded; the highest `generation` integer that passes L2 verification wins; the loser remains as the rollback source |

### 3. Outer file envelope (L2)

The slot file is a single canonical UTF-8 JSON object. There
are no fixed binary offsets at the slot layer — the schema is
identified by the integer `v` field and the bound bytes are the
canonical JSON encoding (`JSONSerialization` with `.sortedKeys`)
of the MAC-scope keys.

```jsonc
{
  "v": 3,
  "generation": <Int>,                        // monotonic, +1 per write
  "kdf": {
    "algorithm": "scrypt",
    "salt": "<base64, 32 bytes>",             // generated at strongbox bootstrap
    "params": { "N": 262144, "r": 8, "p": 1, "keyLen": 32 }
  },
  "wrap": {
    "passwordWrap": {                         // AEAD-seal of mainKey under scrypt-derived KEK
      "alg": "AES-GCM",
      "iv":  "<base64, 12 bytes>",
      "ct":  "<base64, 32 bytes (mainKey ciphertext)>",
      "tag": "<base64, 16 bytes>"
    }
    // No other keys permitted. Any future biometric-unlock
    // state must live in a sibling sidecar file (see
    // `KeyMaterial/KeychainWrapSidecar.swift`) so the slot file
    // remains byte-portable with the Android implementation.
  },
  "strongbox": {                              // AEAD-seal of padded payload under mainKey
    "alg": "AES-GCM",
    "iv":  "<base64, 12 bytes>",
    "ct":  "<base64, 4 194 304 bytes>",      // exactly the padding bucket size
    "tag": "<base64, 16 bytes>"
  },
  "uiBlockHash": "<base64, 32 bytes>",        // SHA-256 of canonical(ui)
  "mac":         "<base64, 32 bytes>",        // HMAC-SHA-256 over MAC scope
  "ui": { /* opaque UI prefs, post-MAC, bound via uiBlockHash */ }
}
```

**MAC scope.** Let `M` = `JSONSerialization(opts:[.sortedKeys])`
of `{v, generation, kdf, wrap, strongbox, uiBlockHash}`. Then
`mac = HMAC-SHA-256(macKey, M)`. The `ui` key is **not** in `M`;
its content is bound indirectly via `uiBlockHash =
SHA-256(canonical(ui))` (the canonical encoding of an empty
object yields the two-byte string `{}`).

This split exists so the small UI-state preferences (which
mutate during normal use) do not require a fresh MAC compute on
every change while still being authenticated against the slot.

### 4. Cryptographic primitives (L3)

| Primitive | Parameters | Source |
| --- | --- | --- |
| AEAD | AES-256-GCM. Nonce 12 bytes, random per seal (`SecureRandom.bytes(12)`). Tag 16 bytes. AAD: empty | `Crypto/Aead.swift`, backed by `CryptoKit.AES.GCM` |
| KDF | scrypt with `N = 262144 (2^18)`, `r = 8`, `p = 1`, `dkLen = 32`. Salt 32 bytes generated by `SecureRandom.bytes(32)` at strongbox bootstrap, persisted in `kdf.salt`, then reused for the lifetime of the strongbox | `Crypto/PasswordKdf.swift` → bridge `scryptDerive` |
| File MAC | HMAC-SHA-256 (32-byte tag) | `Crypto/Mac.swift` |
| MAC-key derivation | `macKey = HKDF-SHA-256(IKM = mainKey, salt = kdf.salt, info = "integrity-v2", L = 32)` via Apple CryptoKit `HKDF<SHA256>`. Android uses BouncyCastle `HKDFBytesGenerator` (RFC 5869, FIPS 140-2 certified) to achieve byte-exact cross-platform compatibility | constant `StrongboxFileCodec.macInfoLabel` |

`mainKey` is a fresh 32-byte value produced once at strongbox
bootstrap by `SecureRandom.bytes(32)`. It is stored only inside
the `passwordWrap` envelope. There is no Keychain-resident copy.

### 5. Two-key hierarchy and key-lifetime contract

```
password ──scrypt(salt, N,r,p,32)──► derivedKey (32 B)  (KEK)
derivedKey ──AES-256-GCM-open(passwordWrap)──► mainKey (32 B)
mainKey ──HKDF(salt=kdf.salt, info="integrity-v2", L=32)──► macKey
mainKey ──HKDF(salt=nil, info="strongbox-payload-checksum-v3", L=32)──► checksumKey
mainKey ──AES-256-GCM-open(strongbox)──► paddedPlaintext (4 194 304 B)
unpad(7816-4) ──► canonicalJSON(StrongboxPayload)
```

**Lifetime invariants.**

- `derivedKey` is materialised inside `attemptUnlockSingle` and
  every call to `persistSnapshot`. It is wiped via
  `defer { derivedKey.resetBytes(in: 0..<derivedKey.count) }` in
  the same scope (`UnlockCoordinatorV2.swift`).
- `mainKey` is materialised on each unlock and on each persist.
  It is wiped in the same `defer` block. It is **never** stored
  on a stored property after the function exits.
- `passwordWrap` envelope is reused verbatim across writes — the
  user's password is not rotated by `persistSnapshot`. (A
  password change goes through a separate dedicated path that
  re-seals `mainKey` under the new KEK and bumps `generation`.)
- `kdf.salt` is fixed for the lifetime of the strongbox (it is
  the salt that defines the KEK address space); the storage
  cost of full salt rotation is one full payload re-seal.

**Why the indirection.** Decoupling the password from `mainKey`
means a future cipher-suite or salt rotation can happen without
touching the user's password and without re-encrypting the
4 MiB payload. The HKDF separation between `mainKey` and
`macKey` is RFC-5869 standard practice.

### 6. Padding (L2)

| Item | Value |
| --- | --- |
| Bucket size | `StrongboxPadding.bucketSize = 4_194_304` (4 MiB) |
| Scheme | ISO/IEC 7816-4: `plaintext ‖ 0x80 ‖ 0x00*` until the bucket is full |
| Pad precondition | `plaintext.count < bucketSize` (one byte must remain for the `0x80` marker) |
| Unpad | Walk from the last byte skipping `0x00`; the next byte must equal `0x80` and is the boundary marker; the prefix is the original plaintext |

The bucket size is fixed and ciphertext-length-leakage is the
threat it closes: an attacker who can read the slot file (e.g.
exfiltrated cloud backup) sees `4 194 304 + 16` ciphertext+tag
bytes regardless of how many wallets are stored. With the JS
SDK's Dilithium-class private keys at ≈7.5 KiB raw and public
keys at ≈2.5 KiB raw, 4 MiB lets a typical install hold on the
order of several hundred wallets without re-bucketing.

### 7. Plaintext payload (L5)

After AEAD-open and unpad, the inner buffer is a UTF-8 JSON
encoding of `StrongboxPayload` with the following normative
shape. The shape is unified across iOS and Android: same field
names, same ordering rules, same encoding of the per-wallet
binary blobs. Canonical sorted keys are used for the inner
checksum compute; the AEAD seal does not require a canonical
encoding because the AEAD tag commits to the byte sequence.

```jsonc
{
  "v": 3,
  "wallets": {                                // String → String map
    "0": "<base64(WalletEntryCodec blob, see §8)>",
    "1": "<base64…>",
    …
  },
  "currentWalletIndex": <Int>,                // index into `wallets[*].idx`
  "customNetworks": [ /* user-added BlockchainNetwork rows */ ],
  "activeNetworkIndex": <Int>,                // 0 = bundled MAINNET; >0 = customNetworks[i-1]
  "cloudBackupFolderUri": "<security-scoped bookmark URI string>",
  "advancedSigning": <Bool>,
  "cameraPermissionAskedOnce": <Bool>,
  "secureItems": { "<key>": "<opaque value>", ... },
  "checksum": "<base64, 32 bytes (keyed HMAC of canonical sans-checksum)>"
}
```

**Backup-enabled toggle is OS-level, not part of the encrypted
payload.** The user-facing "Allow OS backup" preference lives in
`UserDefaults` under `PrefConnect.backupEnabledKey`, never inside
the strongbox. The OS backup agent (iCloud / Finder snapshot
exclusion via `BackupExclusion.swift`) runs **before** the wallet
is unlocked, so the toggle must be readable without the password.
Storing it in `UserDefaults` is the canonical state — there is no
mirror in the encrypted payload to disagree with it.

**Inner checksum.** `checksum =
base64(HMAC-SHA-256(checksumKey, canonical(payload-sans-checksum)))`,
where `checksumKey = HKDF-SHA-256(IKM = mainKey, salt = nil,
info = "strongbox-payload-checksum-v3", L = 32)`. The
canonical encoder uses sorted keys, UTF-8, no whitespace, and
does not escape forward slashes, matching Android's TreeMap
canonicalizer byte-for-byte. Defense-in-depth: the AEAD tag is
the primary integrity guarantee; the keyed checksum surfaces
partial-decrypt or post-decrypt memory-corruption bugs
(`Strongbox.swift`).

**Bundled MAINNET is not in the payload.** The bundled MAINNET
chain config is loaded from
`QuantumCoinWallet/Resources/blockchain_networks.json` at every
`applyDecryptedConfig` call and prepended to `customNetworks`,
so the resource is the canonical source for the default chain
and the per-strongbox file size is unaffected by the default
config.

### 8. Per-wallet wire (`WalletEntryCodec`, big-endian)

Each entry inside `wallets[<idxStr>]` is a base64-wrapped
length-prefixed binary blob with the following layout. **All
multi-byte integers are big-endian.** This format is shared
byte-for-byte with the Android wallet — see
`QuantumCoinWallet/Strongbox/WalletEntryCodec.swift`
(`testWireFormatSpecExactBytes` in
`QuantumCoinWalletTests/WalletEntryCodecTests.swift` pins the
exact bytes).

| Offset | Field | Width | Encoding |
| --- | --- | --- | --- |
| 0 | `wireVersion` | 1 byte (`UInt8`) | constant `0x01` |
| 1 | `flags` | 1 byte (`UInt8`) | bit 0 (`0x01`) = `hasSeed`; remaining bits reserved (must be 0) |
| 2 | `addressLen` | 2 bytes (`UInt16` BE) | UTF-8 byte length of the address |
| 4 | `address` | `addressLen` bytes | UTF-8, EIP-55 mixed case, includes the leading `"0x"` |
| 4+addressLen | `privateKeyLen` | 4 bytes (`UInt32` BE) | byte length of the raw signing key |
| … | `privateKey` | `privateKeyLen` bytes | raw bytes (Dilithium-class, ≈7.5 KiB on Quantum Coin) |
| … | `publicKeyLen` | 4 bytes (`UInt32` BE) | byte length of the raw verifying key |
| … | `publicKey` | `publicKeyLen` bytes | raw bytes |
| … | `seedLen` | 4 bytes (`UInt32` BE) | UTF-8 byte length of the comma-joined seed phrase, or 0 |
| … | `seedWords` | `seedLen` bytes | UTF-8, comma-joined (`"abandon,ability,…"`); empty when `hasSeed = false` |

The whole blob is then `Data.base64EncodedString()`-wrapped so
it can sit as a JSON string value inside `wallets`.

**Why a binary codec.** A naive `wallets[idx] = JSON({address,
privateKey: hex, publicKey: hex, seedWords: [...]})` shape
exploded the per-entry size once Dilithium-class keys arrived
(hex doubles, JSON quoting plus base64 inside JSON triples), and
the strongbox bucket was repeatedly overflowing. The binary
codec shaves the per-entry overhead to one base64 wrap and
length-prefixes raw bytes directly, so a 4 MiB bucket
comfortably holds ≥256 wallets with PQC keys.

### 9. Generation counter and rollback resistance

| Item | Value |
| --- | --- |
| In-slot field | `generation` integer in the outer JSON (incremented by exactly +1 per `writeNewGeneration`) |
| Out-of-band binding | `KeychainGenerationCounter` (high-water value persisted in a Keychain generic-password item, accessible `WhenUnlockedThisDeviceOnly`, `kSecAttrSynchronizable = false`). Service `…strongbox-rollback`, account `generation-v1` |
| On unlock | `attemptUnlockSingle` rejects the slot if `slotGeneration < storedGeneration` |
| Heal-forward | A first-launch device with no Keychain counter seeds its counter from the slot's `generation` so a fresh restore-from-backup is accepted; subsequent rollback attempts are rejected |

### 10. Brute-force lockout

State lives in a Keychain generic-password item, JSON-encoded
`{count: Int, lastFailureMonotonicNanos: UInt64}`,
`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`,
`kSecAttrSynchronizable = false`. Schedule: counts <5 → no
delay; 5 → 30 s; 6 → 60 s; 7 → 120 s; ≥8 capped at 300 s. The
limiter is consulted at strongbox-unlock and at backup-decrypt.
Source: `QuantumCoinWallet/Security/UnlockAttemptLimiter.swift`.

### 11. Out-of-strongbox metadata (`PrefConnect`)

The non-secret app preferences live in
`Application Support/DP_QUANTUM_COIN_WALLET_APP_PREF.json`,
managed by `QuantumCoinWallet/Storage/PrefConnect.swift`. The
allowlist is enumerated in `PrefKeys`:

| Key | Reason it is here, not in the strongbox |
| --- | --- |
| `EULA_ACCEPTED` | Must be readable before any password is collected |
| `LANGUAGE_CODE` | Localizes the unlock dialog itself |
| `WALLET_CURRENT_ADDRESS_INDEX_KEY` | Reads pre-unlock so the home screen can render the right wallet skeleton; mirrors the in-payload `currentWalletIndex` post-unlock |
| `BLOCKCHAIN_NETWORK_ID_INDEX_KEY` | Same rationale for the network strip |
| `CLOUD_BACKUP_FOLDER_URI_KEY` | Mirrors the in-payload `cloudBackupFolderUri` so the picker survives reinstall |
| `BACKUP_ENABLED_KEY` | Drives `NSURLIsExcludedFromBackupKey` before any unlock |
| `ADVANCED_SIGNING_ENABLED_KEY` | Mirrors the payload field; used pre-unlock for the splash UI |
| `CAMERA_PERMISSION_ASKED_ONCE` | Idempotency flag for the iOS permission dialog |

Anything that names, locates, or enumerates wallets is **not**
in `PrefConnect`; it lives only in the encrypted payload.

### 12. iCloud / Finder backup exclusion

`QuantumCoinWallet/Backup/BackupExclusion.swift` sets
`URLResourceValues.isExcludedFromBackup` on every slot file
according to `PrefConnect.BACKUP_ENABLED_KEY`. The flag is
re-applied after every slot promote so a `rename(2)` that
replaces the inode does not silently re-include the file.

> **Limitation.** Encrypted Finder/iTunes backups copy the entire
> sandbox regardless of `isExcludedFromBackup`. The strongbox
> file is itself password-encrypted, so the residual exposure is
> bounded by the strongbox-password strength, but the
> `BackupExclusion` doc comments and the in-app warning surface
> this caveat to the user.

### 13. Cloud `.wallet` per-wallet envelope (separate from the slot)

The user-facing **per-wallet backup file** (`UTC--<timestamp>--<addr>.wallet`)
is a different format. It is produced and consumed by the
shared `QuantumCoinSDK.Wallet.encryptSync` /
`Wallet.decryptSync` calls in `quantumcoin-bundle.js`, called
from `QuantumCoinWallet/JsBridge/JsBridge.swift`. It is a
Web3-Secret-Storage-style JSON blob (scrypt KDF, AES + MAC,
address-bound) keyed by a user-supplied **backup password** that
is collected separately from the strongbox password and may
legitimately differ. The `.wallet` envelope is byte-equivalent
across iOS and Android (both call the same JS SDK), which is
why the per-wallet backup file format **is** cross-platform
restorable. See
[`Backup/CloudBackupManager.swift`](QuantumCoinWallet/Backup/CloudBackupManager.swift)
for the file naming and folder enumeration; the JSON shape itself
is owned by the SDK package.

### 14. Cross-platform parity test vectors

The binding portability contract is the seeded vector suite:

- iOS: `QuantumCoinWalletTests/StrongboxPortabilityVectorTests.swift`
  (plus the dedicated `StrongboxPaddingTests`,
  `StrongboxPayloadV3Tests`, `StrongboxFileCodecScryptValidationTests`,
  `WalletEntryCodecTests`, and
  `DeterministicSecureRandomSourceTests` ports).
- Android: `app/src/test/java/com/quantumcoin/app/strongbox/StrongboxPortabilityVectorTest.java`
- Shared seed note: `tests/fixtures/strongbox-v3-vectors/INDEX.md`

The tests derive inputs at runtime with
`SHAKE256(seed || UTF8(label), outputLength)`, then assert the
same small expected outputs on both platforms. The suite covers
SHAKE-256 seed expansion, public RFC HMAC/HKDF vectors, SHA-256,
HMAC-SHA-256, HKDF null-salt behavior, AES-256-GCM with injected
nonce, `WalletEntryCodec`, canonical `StrongboxPayload` bytes,
the keyed inner checksum, and 4 MiB ISO/IEC 7816-4 padding. Large
payload JSON and full slot blobs are generated from the seed
inside the tests rather than checked into the repository.

---

## Cross-platform interoperability

Whole strongbox slot files are portable in v=3. Copying
`DP_QUANTUM_COIN_WALLET_APP_PREF.A.json` or
`DP_QUANTUM_COIN_WALLET_APP_PREF.B.json` between the iOS
`Application Support/` directory and Android
`getFilesDir()/strongbox/` preserves the encrypted bytes; the
receiver unlocks it with the same wallet password and rebuilds its
platform-local state around it.

Per-wallet `.wallet` backup files remain portable too because both
apps use the same JavaScript SDK encryption envelope.

### How portability is enforced

The v=3 slot contract deliberately makes every byte-affecting choice
match across iOS and Android:

- Outer envelope `v = 3`; canonical JSON uses sorted keys, UTF-8, no whitespace, and no slash escaping.
- scrypt parameters match: `N = 262144`, `r = 8`, `p = 1`, `keyLen = 32`, salt = 32 bytes.
- AEAD matches: AES-256-GCM, 12-byte nonce, 16-byte tag, empty AAD.
- File MAC matches: `HMAC-SHA-256(HKDF(mainKey, salt=kdf.salt, info="integrity-v2", L=32), canonical(mac-scope envelope))`.
- Payload schema matches: `v`, `wallets`, `currentWalletIndex`, `customNetworks`, `activeNetworkIndex`, `cloudBackupFolderUri`, `advancedSigning`, `cameraPermissionAskedOnce`, `secureItems`, `checksum`.
- Inner checksum matches: `HMAC-SHA-256(HKDF(mainKey, salt=nil, info="strongbox-payload-checksum-v3", L=32), canonical(payload-sans-checksum))`.
- Per-wallet entries match via `WalletEntryCodec` big-endian length-prefixed binary blobs.
- Padding matches: ISO/IEC 7816-4 to exactly 4 MiB.

### Platform-local fields

`cloudBackupFolderUri` is carried as an opaque platform-local string.
iOS stores a security-scoped bookmark shape; Android stores a SAF URI.
A cross-platform importer should clear or re-prompt for this value after
reading the portable slot. Generation counters and brute-force lockout
state are also platform-local: a fresh device heals its counter forward
from the slot generation after the slot itself verifies.

The slot file itself carries exactly
`wrap = { passwordWrap }` and **no other keys**; iOS decoders
hard-reject any slot whose `wrap` object contains extraneous
fields. If a future biometric-unlock UI is added on iOS, its
per-device wrap-key state must live in a sibling sidecar file
(see [`QuantumCoinWallet/KeyMaterial/KeychainWrapSidecar.swift`](QuantumCoinWallet/KeyMaterial/KeychainWrapSidecar.swift))
so the slot file stays byte-identical to the Android
implementation; the slot envelope is reserved for the
cross-platform shared contract.

### Post-quantum key exchange

In TLS 1.3 the cipher suite is decoupled from the key exchange:
suites name only the AEAD + hash, and key exchange is negotiated
independently via the `supported_groups` extension (NamedGroup).
Recent iOS versions advertise the hybrid group `X25519MLKEM768`
(FIPS 203 ML-KEM-768 + X25519, IETF
`draft-ietf-tls-hybrid-design`) at the CoreTLS layer by default;
older iOS versions negotiate classical groups (`X25519`,
`secp256r1`). Refer to Apple's release notes for the current
OS-version threshold. When both the OS and the server advertise
the hybrid group it is negotiated automatically and the handshake
becomes harvest-now-decrypt-later resistant for the rest of that
connection.

The wallet does nothing to either enable or inhibit PQ — it lets
the OS negotiate, mirroring the Android sibling's "let Conscrypt
pick" posture documented in `TlsPinning.java`. The Swift
`URLSession` for the scan API does not cap
`tlsMaximumSupportedProtocolVersion` and no cipher-suite
restriction API is called, so future Apple- or Conscrypt-shipped
PQC primitives (e.g. a further hybrid group, a PQC-bundled AEAD)
are picked up without an app update. Pinning a TLS 1.3 minimum
floor does NOT inhibit PQ because PQ lives in the key-exchange
layer, not the AEAD layer.

### Wallet capacity

Both wallets honour `MAX_WALLETS = 128` for the maximum number
of stored wallets in a single strongbox. The 4 MiB padding
bucket comfortably fits this many wallets with Dilithium-class
post-quantum keys. The capacity is intentionally mirrored on
both platforms so a portable v=3 slot cannot exceed the cap on
either side.

### Ported test suite

Every Android strongbox test under
`app/src/test/java/com/quantumcoin/app/strongbox/` has a Swift
counterpart under [`QuantumCoinWalletTests/`](QuantumCoinWalletTests),
sharing the same 32-byte seed and SHAKE-256 expansion contract
documented in
[`tests/fixtures/strongbox-v3-vectors/INDEX.md`](tests/fixtures/strongbox-v3-vectors/INDEX.md):

| Android source | Swift port |
| --- | --- |
| `DeterministicSecureRandomSource.java` | [`DeterministicSecureRandomSource.swift`](QuantumCoinWalletTests/DeterministicSecureRandomSource.swift) |
| `DeterministicSecureRandomSourceTest.java` | [`DeterministicSecureRandomSourceTests.swift`](QuantumCoinWalletTests/DeterministicSecureRandomSourceTests.swift) |
| `StrongboxPaddingTest.java` | [`StrongboxPaddingTests.swift`](QuantumCoinWalletTests/StrongboxPaddingTests.swift) |
| `WalletEntryCodecTest.java` | [`WalletEntryCodecTests.swift`](QuantumCoinWalletTests/WalletEntryCodecTests.swift) |
| `StrongboxFileCodecScryptValidationTest.java` | [`StrongboxFileCodecScryptValidationTests.swift`](QuantumCoinWalletTests/StrongboxFileCodecScryptValidationTests.swift) |
| `StrongboxPayloadV3Test.java` | [`StrongboxPayloadV3Tests.swift`](QuantumCoinWalletTests/StrongboxPayloadV3Tests.swift) |
| `StrongboxPortabilityVectorTest.java` | [`StrongboxPortabilityVectorTests.swift`](QuantumCoinWalletTests/StrongboxPortabilityVectorTests.swift) |

Both suites read the same pinned digests (SHA-256 of canonical
inner JSON, SHA-256 of `WalletEntryCodec` blobs, HMAC tags,
HKDF-derived checksum keys, AES-GCM ciphertext digests with
injected nonces); a regression on either platform fails the
corresponding test in lockstep.

### v=2 historical note

Before v=3, raw slot-file copying did not work because the plaintext
payload schemas and inner-checksum schemes diverged. That divergence is
resolved by the v=3 unified schema and by the seeded parity tests in
§14 of the strongbox specification.

---

## SDKs and dependencies

The iOS wallet has **zero CocoaPods / Carthage / SwiftPM
dependencies**. Every external piece of code ships in either:

- **Apple frameworks** linked from the iOS SDK
  (`UIKit`, `WebKit`, `CryptoKit`, `Security`, `Foundation`,
  `UniformTypeIdentifiers`), or
- **A single bundled JavaScript file** (`quantumcoin-bundle.js`,
  ≈12.3 MiB, MIT-licensed) loaded into a `WKWebView`.

That single file exposes **two** browser globals the bridge
consumes:

| Global | Purpose | Used in iOS |
| --- | --- | --- |
| `QuantumCoinSDK` | Wallet construction, address helpers, JSON-RPC provider, IERC20 contract helper, scrypt KDF, AEAD wallet envelopes | `Resources/bridge.html` (~36 callsites) |
| `SeedWordsSDK` | BIP39-style seed-word lookup tables | `Resources/bridge.html` (4 callsites — `getWordListFromSeedArray`, `getAllSeedWords`, `doesSeedWordExist`) |

Both globals are produced upstream from two distinct SDK packages:

| Upstream SDK | Repository | Role in the bundle |
| --- | --- | --- |
| `quantumcoin.js` | <https://github.com/quantumcoinproject/quantumcoin.js> | The ethers.js-compatible wrapper that exposes the high-level `Wallet` / `JsonRpcProvider` / `IERC20` surface this wallet calls (`wallet.sendTransaction`, `token.transfer`, `wallet.getSigningContext`, `wallet.populateTransaction`). |
| `quantum-coin-js-sdk` | <https://github.com/quantumcoinproject/quantum-coin-js-sdk> | The lower-level Quantum Coin JS SDK (npm: `quantum-coin-js-sdk`) that `quantumcoin.js` builds on. Provides the chain-specific primitives (post-quantum signing, encrypted-wallet JSON envelope, scrypt KDF). |

The iOS wallet only ever consumes the **curated `quantumcoin-bundle.js`** —
**no Swift code reaches into either upstream package directly**.
Adding a new SDK symbol means re-exporting it from the bundle, not
pulling an upstream package into iOS, so the SHA-256 pin and the
Android-iOS parity contract stay meaningful.

The bundle is byte-identical to the one shipped by the Android
wallet's `webview-sdk-bundle`, which is the canonical re-export
point. The current bundle was built against the following pinned
npm versions:

| npm package | Pinned version |
| --- | --- |
| [`quantumcoin`](https://www.npmjs.com/package/quantumcoin) | `7.0.12` |
| [`seed-words`](https://www.npmjs.com/package/seed-words) | `^1.0.2` |
| [`quantum-coin-js-sdk`](https://www.npmjs.com/package/quantum-coin-js-sdk) | `1.0.35` |

### Native frameworks used

| Framework | Used for |
| --- | --- |
| `UIKit` | Every screen, every dialog |
| `WebKit` | The single in-process `WKWebView` that hosts `bridge.html` (`JsBridge/JsEngine.swift`) |
| `CryptoKit` | AES-256-GCM seal/open, SHA-256 (`Crypto/Aead.swift`, `JsBridge/BundleIntegrity.swift`) |
| `Security` | Keychain (brute-force lockout counter, legacy wrap-key cleanup) |
| `Foundation` | `URLSession`, file I/O, JSON, `URLBookmarkData` for cloud folders |
| `UniformTypeIdentifiers` | Custom `org.quantumcoin.wallet` UTI for `.wallet` backup files |

### Build tooling

- **[XcodeGen](https://github.com/yonaskolb/XcodeGen)** ≥ 2.38.0
  generates `QuantumCoinWallet.xcodeproj` from
  [`project.yml`](project.yml). The `.xcodeproj` is intentionally
  **not** committed.
- **`shasum -a 256`** (BSD, ships with macOS) used by
  `scripts/embed_bundle_hash.sh` at build time.

---

## Architecture overview

```
┌───────────────────────────────────────────────────────────────────┐
│                          UIKit screens                            │
│   HomeWallet / HomeMain / Send / Receive / Wallets / Settings /   │
│   Transactions / RevealWallet / BlockchainNetwork / BackupOptions │
└───────────────────────────┬───────────────────────────────────────┘
                            │
┌───────────────────────────▼───────────────────────────────────────┐
│                     Strongbox accessor (L5)                       │
│        Strongbox/Strongbox.swift — single in-mem snapshot         │
└───────────────────────────┬───────────────────────────────────────┘
                            │
┌───────────────────────────▼───────────────────────────────────────┐
│                  Unlock coordinator (L4)                          │
│   scrypt → AEAD open → install snapshot;  password is never       │
│   cached — re-derived per write                                   │
└──────────────┬────────────────────────────────────┬───────────────┘
               │                                    │
┌──────────────▼─────────────────┐  ┌───────────────▼───────────────┐
│   Crypto primitives (L3)       │  │   Schema codec (L2)           │
│   Aead, Mac, PasswordKdf,      │  │   StrongboxFileCodec,         │
│   SecureRandom                 │  │   StrongboxPadding            │
└──────────────┬─────────────────┘  └───────────────┬───────────────┘
               │                                    │
               │            ┌───────────────────────▼───────────────┐
               │            │   Storage primitive (L1)              │
               │            │   AtomicSlotWriter (two-slot,         │
               │            │   F_FULLFSYNC, verify-before-promote) │
               │            └───────────────────────────────────────┘
               │
┌──────────────▼─────────────────┐  ┌───────────────────────────────┐
│      JsBridge (Swift)          │◄─┤    bridge.html (WKWebView)    │
│   JsEngine, JsBridge,          │  │    quantumcoin-bundle.js      │
│   BundleIntegrity              │  │    (QuantumCoinSDK +          │
└────────────────────────────────┘  │     SeedWordsSDK globals)     │
                                    └───────────────────────────────┘
```

The strict layering is enforced by the storage / crypto / bridge
separation in code review and by invariant tests in
`QuantumCoinWalletTests/StrongboxLayerTests.swift`. The only
structurally-permitted writers of wallet-meaningful state are
the `Strongbox.shared` accessor and the `UnlockCoordinatorV2`
re-encrypt path; a stray `PrefConnect` write of a wallet field
is caught by a grep-based invariant test.

---

## Repository layout

```
.
├── LICENSE                            MIT
├── project.yml                        XcodeGen project spec
├── scripts/
│   └── embed_bundle_hash.sh           Build-time SHA-256 pin
└── QuantumCoinWallet/
    ├── AppDelegate.swift              Boot + tamper gate
    ├── Info.plist                     UIFileSharingEnabled = false, etc.
    ├── QuantumCoinWallet.entitlements
    ├── Assets.xcassets                App icon + brand colors
    ├── LaunchScreen.storyboard
    │
    ├── Backup/                        File / cloud backup + restore
    ├── Components/                    Reusable views (PillButton, QRScanner…)
    ├── Crypto/                        Aead, Mac, PasswordKdf, SecureRandom
    ├── Data/                          ApiClient, BlockchainNetwork, ApiModels
    ├── Diagnostics/                   Logger
    ├── Dialogs/                       UIKit dialogs (Unlock, Review, Wait…)
    ├── Generated/                     BundleHash_Generated.swift (auto)
    ├── JsBridge/                      JsEngine, JsBridge, BundleIntegrity
    ├── KeyMaterial/                   Key envelopes, key-type helpers, KeychainWrapSidecar
    ├── Localization/                  Localization.shared accessor
    ├── Models/                        RecognizedTokens, StablecoinImpersonatorFilter
    ├── Navigation/                    UINavigationController helpers
    ├── Networking/                    NetworkConfig (actor), TlsPinning, UrlBuilder
    ├── Notifications/                 BalanceChangeNotifier (background balance pings)
    ├── Resources/
    │   ├── bridge.html                JS bridge (the only HTML the WKWebView loads)
    │   ├── quantumcoin-bundle.js      The single JS SDK bundle (SHA-256 pinned)
    │   ├── quantumcoin-bundle.js.LICENSE.txt
    │   ├── blockchain_networks.json   Bundled MAINNET network seed
    │   └── en_us.json                 230+ localization keys
    ├── Schema/                        StrongboxFileCodec (v=3 portable), StrongboxPadding
    ├── Screens/                       11 top-level screens
    ├── Security/                      TamperGate, ScreenCaptureGuard, UnlockAttemptLimiter
    ├── Session/                       Idle relock + foreground/background tracking
    ├── Storage/                       AtomicSlotWriter (L1), PrefConnect (UI prefs)
    ├── Strongbox/                     Strongbox accessor (L5), payload, redundancy, WalletEntryCodec
    ├── Theme/                         Color tokens, typography
    ├── UX/                            SnapshotRedactor, Pasteboard
    └── Utilities/                     Constants, helpers
└── QuantumCoinWalletTests/            v=3 strongbox parity + bridge + UX suites
```

The bundled `quantumcoin-bundle.js` is currently ~12 MiB and the
`en_us.json` catalog carries 230+ keys. Hard counts (source
files, tests, lines of HTML) drift quickly with each port from
the Android-parity reference and are intentionally not pinned in
this README.

---

## Build and run

### Prerequisites

- macOS with Xcode 17 or newer (iOS 17+ SDK).
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`.
- Apple Developer account if you intend to run on a physical device.

### Generate, build, run

```bash
git clone https://github.com/quantumcoinproject/quantum-coin-wallet-ios.git
cd quantum-coin-wallet-ios
xcodegen generate
open QuantumCoinWallet.xcodeproj
```

Pick the **QuantumCoinWallet** scheme and a destination
(simulator or physical device). The first build runs the
`embed_bundle_hash.sh` pre-build script, which writes
`QuantumCoinWallet/Generated/BundleHash_Generated.swift` so the
SHA-256 of `quantumcoin-bundle.js` is embedded in the Swift
binary. **The generated file is gitignored** — every build
regenerates it, so an out-of-date hash is impossible by
construction.

### Command-line build

```bash
xcodegen generate
xcodebuild \
  -project QuantumCoinWallet.xcodeproj \
  -scheme QuantumCoinWallet \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -configuration Debug build
```

### Updating the JS bundle

`quantumcoin-bundle.js` is built upstream by the Android wallet's
[`webview-sdk-bundle/`](https://github.com/quantumcoinproject/quantum-coin-wallet-android/tree/main/webview-sdk-bundle).
Drop the new bundle into
`QuantumCoinWallet/Resources/quantumcoin-bundle.js`; the next
build regenerates `BundleHash_Generated.swift` automatically.

---

## Testing

```bash
xcodebuild \
  -project QuantumCoinWallet.xcodeproj \
  -scheme QuantumCoinWallet \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  test
```

The test target lives in
[`QuantumCoinWalletTests/`](QuantumCoinWalletTests). It contains
the following suites, all ported one-for-one from the Android
strongbox + bridge test suites where applicable:

| Suite | Coverage |
| --- | --- |
| `JsBridgeContractTests` | Live `WKWebView` boot + `bridge.createRandom` round-trip; pins the JSON envelope shape between Swift and the JS bundle |
| `StrongboxLayerTests` | v=3 schema invariants — outer envelope, file MAC scope, payload canonical-bytes byte-for-byte parity with Android, inner-checksum HMAC keying, ISO/IEC 7816-4 4 MiB padding, layer-isolation (no `PrefConnect` writes of wallet fields) |
| `StrongboxPaddingTests` | ISO/IEC 7816-4 padding round trip + boundary tests (Android-parity port) |
| `StrongboxFileCodecScryptValidationTests` | scrypt N/r/p/keyLen min-bound rejection on decode (Android-parity port) |
| `StrongboxPayloadV3Tests` | v=3 schema version, default fields, canonical-bytes stability, mutation detection, `backupEnabled` omission (Android-parity port) |
| `StrongboxPortabilityVectorTests` | Seeded SHAKE-256 cross-platform vector suite: pinned digests for SHA-256, HMAC, HKDF, AES-GCM with injected nonce, WalletEntry + Payload canonicalization, padding bucket (Android-parity port) |
| `WalletEntryCodecTests` | Big-endian length-prefixed wire format for per-wallet entries; pins the exact byte layout (`testWireFormatSpecExactBytes`) shared with Android `WalletEntryCodecTest` |
| `DeterministicSecureRandomSourceTests` | Replayable byte-sequence randomness helper used by the seeded vector ports (Android-parity port) |
| `SecurityFixesTests` | Password-verification, lockout-schedule, tamper-gate classifier, scrypt-min-bound unlock guard |
| `TokenFilteringAndLockoutTests` | `RecognizedTokens.isRecognized`, `StablecoinImpersonatorFilter.filter`, `UnlockAttemptLimiter` 5-minute cap, contract-address row in the review dialog, localization-key smoke check |
| `LocalizationTests` | `en_us.json` key presence and accessor wiring (incl. the Android-parity error catalog and the iOS-only `emptyPassword` / `wallet-data-unreadable` keys) |
| `ApiDecodingTests` | Scan-API JSON shapes against captured fixtures |

`StrongboxPortabilityFixtures.swift` and
`StrongboxSlotJsonFixtures.swift` are shared test-only support
files (deterministic SHAKE-256 expander, vector-builder helpers,
and minimal slot-JSON skeletons). They are not test suites of
their own.

---

## Threat model & non-goals

### In scope

- **Lost or stolen device.** Sandbox isolation, complete file
  protection, brute-force lockout, snapshot redaction,
  pasteboard expiry, idle relock.
- **Hostile RPC.** Local-first transaction signing inside the
  bundled SDK; the user can verify the locally-derived hash on
  any block explorer.
- **Token impersonation.** Recognized-contract allow-list +
  stablecoin-name hard-suppressor.
- **JS bundle tamper / re-sign.** Build-time SHA-256 pin embedded
  in the code-signed Swift binary; runtime re-hash; refuse-to-init
  on mismatch.
- **Jailbreak / debugger / Mach-O instrumentation.** Multi-signal
  tamper gate at the signing chokepoint.
- **Power loss / sudden app kill mid-write.** Two-slot rotation,
  `F_FULLFSYNC`, verify-before-promote.

### Explicit non-goals

- **TLS pinning on RPC.** The wallet is non-custodial and the user
  picks the RPC. Pinning would impose centralization. Baseline
  TLS chain validation still applies. The bundled MAINNET RPC
  host additionally gets a TLS 1.3 minimum-version floor via
  per-domain ATS (see "Security & durability features"); the SPKI
  pin itself stays off RPC. See `Networking/TlsPinning.swift` for
  the full coverage map.
- **TLS 1.3 floor on user-defined custom RPC URLs.** iOS does not
  expose a per-`WKWebView` minimum-TLS API and the wallet cannot
  enumerate user-typed hostnames at build time, so a user-defined
  RPC host that only speaks TLS 1.2 still connects (the platform
  ATS default applies). The Android sibling has the identical
  WebView limitation; lifting the floor for arbitrary
  user-supplied hosts would require routing RPC through Swift
  `URLSession`, which is a structural change.
- **Defending an unlocked, jailbroken, attacker-owned device with
  a Frida-class hook injected before the wallet binary loads.**
  The tamper gate raises cost; it does not claim to be impassable.
- **Custodial recovery.** There is no remote escrow of seed phrases
  or unlock passwords. Lost seed = lost wallet. The backup flow
  (file or iCloud Drive) is the only recovery path.
- **Investment, custody, or financial advice of any kind.**

---

## License

[MIT](LICENSE) — see the file for details.

The bundled `quantumcoin-bundle.js` and its embedded
third-party libraries are MIT-licensed (see
[`QuantumCoinWallet/Resources/quantumcoin-bundle.js.LICENSE.txt`](QuantumCoinWallet/Resources/quantumcoin-bundle.js.LICENSE.txt)).

---

## Further reading

- **Project home:** <https://quantumcoin.org>
- **FAQ:** <https://quantumcoin.org/faq.html>
- **Quantum-resistance whitepaper:**
  <https://quantumcoin.org/whitepapers/Quantum-Coin-Blockchain-Quantum-Resistance-Whitepaper.html>
- **Consensus whitepaper:**
  <https://quantumcoin.org/whitepapers/Quantum-Coin-Blockchain-Consensus-Whitepaper.html>
- **Quantum Coin Go node (open source):**
  <https://github.com/quantumcoinproject/quantum-coin-go>
- **Android wallet (parity reference):**
  <https://github.com/quantumcoinproject/quantum-coin-wallet-android>
- **`quantumcoin.js` (ethers.js-compatible wrapper SDK):**
  <https://github.com/quantumcoinproject/quantumcoin.js>
- **`quantum-coin-js-sdk` (lower-level upstream SDK, npm package):**
  <https://github.com/quantumcoinproject/quantum-coin-js-sdk>
- **Block explorer:** <https://quantumscan.com>
- **JSON-RPC API docs:** <https://apidoc.quantumcoin.org>
- **Community:** <https://discord.gg/bbbMPyzJTM>
