// SessionLock.swift
// Port of the idle-lock logic in `HomeActivity.java`, split into two
// independent timing policies:
// - Foreground idle relock — `UNLOCK_TIMEOUT_MS = 300_000` (5 min).
//   Resets on any UI interaction (tap / pan / long-press / text edit)
//   while the app stays in the foreground.
// - Background-return grace — `FOREGROUND_UNLOCK_GRACE_MS = 180_000`
//   (3 min). `applicationDidBecomeActive` compares only the elapsed
//   time since the last successful unlock against this window and
//   forces a mandatory relock when the user has been away longer.
//   `lastBackgroundMonotonicNanos` is still stamped for unrelated
//   lifecycle observers, but is not part of the relock decision —
//   short Safari hops / block-explorer round-trips stay unlocked.
//   Reboot detection (`now < lastUnlockMonotonicNanos` since
//   `mach_continuous_time()` resets to 0 on boot) keeps forcing a
//   relock regardless of the grace window.
// the
// elapsed-time arithmetic uses `mach_continuous_time()` (continuous
// nanoseconds since boot, including device-suspended time), NOT
// the wall-clock `CFAbsoluteTimeGetCurrent()`. The wall clock is
// user-adjustable from Settings -> General -> Date & Time. With the
// previous wall-clock implementation, two attacks survived:
//   1. Forward-then-back skew while the app is suspended. An
//      attacker advances the clock so a foreground+relock fires,
//      then resets the clock back; the next foreground sees ~0
//      elapsed and skips the relock even though hours of real
//      time have passed.
//   2. Reboot mid-suspend. With a wall-clock baseline the
//      "did the clock move backwards?" check could fire spuriously
//      from NTP corrections; with a continuous-counter baseline
//      "now < stored" can ONLY mean the device rebooted (the
//      counter resets to 0 at boot). We force a relock on that
//      branch.
// `UnlockAttemptLimiter` already uses this same primitive for the
// same reasons; this file aligns the `SessionLock` to the same
// posture. The DispatchSourceTimer used for the foreground idle
// countdown is acceptable on the wall clock - it only fires while
// the app is foregrounded, and `applicationWillResignActive`
// cancels it on suspend.
// The original implementation installed only a `UITapGestureRecognizer`
// on the key window. The comment "any UI interaction" was therefore
// misleading: a user reading a long transaction list could swipe-
// scroll for several minutes, never tap, and be relocked mid-scroll
// even though they were clearly interacting with the app. Prior reviews
// flagged this as a comment-vs-code mismatch.
// The fix here is to widen the interaction surface to match the
// comment, NOT to narrow the comment to match the code. Specifically
// we now install:
// 1. `UITapGestureRecognizer` (already present) - catches simple
// button taps, list-row selects, etc.
// 2. `UIPanGestureRecognizer` - catches scroll-view pans, swipes,
// drags, and pinch-precursors. (`UISwipeGestureRecognizer` is
// not added separately because UIKit recognises swipes as
// velocity-bounded pans; the pan recogniser fires for both.)
// 3. `UILongPressGestureRecognizer` - catches "press and hold" on
// copy menus, drag-and-drop initiations, and accessibility
// long-presses.
// 4. Notification observer on `UITextField.textDidChangeNotification`
// - catches typing into any field (search, password, recipient
// address, amount). UIKit posts this notification for every
// `UITextField` insertion / deletion regardless of where the
// field lives in the view hierarchy.
// All recognisers use `cancelsTouchesInView = false` and a
// permissive simultaneous-recognition delegate so they are
// transparent to downstream hit-testing - they observe touches but
// never absorb them. The first signal of any kind resets the timer
// via `anyInteraction`.
// Tradeoffs (truthful summary):
// * The reset surface is now broad enough that an automated
// process generating fake touches (e.g. a malicious accessibility
// service) could hold the unlock open indefinitely. This was
// already true with the tap-only implementation; widening the
// surface does not weaken the threat model meaningfully because
// the same accessibility service could synthesise a tap.
// * KVO on `UIScrollView.contentOffset` was considered but rejected:
// it would require attaching observers to every scroll view in
// the app (vs the centralised window-level pan recogniser),
// which is brittle and easy to miss in new screens. The window-
// level pan covers all current and future scroll surfaces by
// construction.
// Android reference:
// app/src/main/java/com/quantumcoinwallet/app/view/activities/HomeActivity.java

import Darwin
import UIKit

public final class SessionLock {

    public static let shared = SessionLock()

    /// `mach_continuous_time()` reading converted to nanoseconds.
    /// `0` is the sentinel "never recorded".
    private var lastUnlockMonotonicNanos: UInt64 = 0
    /// Same monotonic clock as `lastUnlockMonotonicNanos`. `0` is
    /// the sentinel "not currently backgrounded".
    private var lastBackgroundMonotonicNanos: UInt64 = 0
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue.main
    private var installed = false

    private init() {}

    public func start() {
        guard !installed else { return }
        installed = true
        installInteractionHook()
        restartIdleTimer()
    }

    public func markUnlockedNow() {
        lastUnlockMonotonicNanos = Self.monotonicNanos()
        // Reset the "went to background at" stamp so a subsequent
        // resume doesn't compare against an old value taken before
        // the user just unlocked.
        lastBackgroundMonotonicNanos = 0
        restartIdleTimer()
    }

    public func applicationDidBecomeActive() {
        if !Strongbox.shared.isSnapshotLoaded {
            // Snapshot is cleared. Two cases:
            // 1. Cold launch / splash: HomeViewController is not the
            // rootVC yet, so `presentUnlockGate` -> `findHomeViewController`
            // returns nil and this is a safe no-op. The dedicated
            // cold-launch gate inside HomeViewController.routeInitialScreen
            // remains the path that prompts here.
            // 2. Past-splash relock: a previous `lockAndPresent`
            // ran (idle timer or >5min background resume),
            // cleared the snapshot, but its `present(...)` was
            // dropped by UIKit (e.g. raced a stale modal's
            // dismiss). Without this re-attempt the user sees
            // a blank shell with no unlock dialog until the
            // next idle-timer cycle fires after they happen to
            // tap. Re-dispatching `presentUnlockGate` here gets
            // them prompted on the very next foreground.
            // `presentUnlockGate` already short-circuits if the
            // dialog is mid-flight, so the cold-launch race is also
            // safe - at worst we no-op a second time.
            // We deliberately consult the v2 boot state (slot file
            // present?) rather than an in-memory wallet count,
            // because a returning user with an existing strongbox
            // is in case 1 BEFORE they have unlocked - the snapshot
            // is empty but the slot file is on disk, and the gate
            // must still surface.
            if case .strongboxPresent = UnlockCoordinatorV2.bootState() {
                DispatchQueue.main.async { [weak self] in
                    self?.presentUnlockGate()
                }
            }
            return
        }

        let now = Self.monotonicNanos()
        // Background-return grace window: compare the elapsed time
        // since the user's last successful unlock against
        // `FOREGROUND_UNLOCK_GRACE_MS` (3 min). Returning from any
        // app switch within that window keeps the session unlocked;
        // crossing it presents the mandatory unlock dialog.
        //
        // `mach_continuous_time()` keeps counting through device
        // suspend, so `elapsedSinceUnlockMs` already observes the
        // full real-world elapsed time even when the device was
        // asleep — no separate "elapsed since background" check is
        // needed.
        //
        // Reboot detection: the `now < lastUnlockMonotonicNanos`
        // branch fires only after a power cycle (the monotonic
        // counter resets to 0 on boot, so a stored value larger
        // than `now` is the only way to read the clock backwards).
        // Force a relock there so an attacker cannot bypass the
        // gate by power-cycling a suspended device.
        //
        // Both checks are guarded by `lastUnlockMonotonicNanos > 0`.
        // The sentinel `0` means "never recorded" — which should be
        // unreachable on the snapshot-loaded branch once every
        // snapshot-installing path stamps `markUnlockedNow()` (see
        // `UnlockCoordinatorV2.unlockWithPasswordAndApplySession`,
        // `createNewStrongbox`, `createNewStrongboxWithInitialWallet`),
        // but the guard keeps the helper defensive against future
        // call sites that install a snapshot without stamping.
        let elapsedSinceUnlockMs = Self.elapsedMillis(
            from: lastUnlockMonotonicNanos, to: now)
        let exceededGrace = lastUnlockMonotonicNanos > 0
        && elapsedSinceUnlockMs
            > UInt64(Constants.FOREGROUND_UNLOCK_GRACE_MS)
        let rebooted = lastUnlockMonotonicNanos > 0
        && now < lastUnlockMonotonicNanos

        if exceededGrace || rebooted {
            lockAndPresent()
        } else {
            // Within grace - keep the foreground idle countdown
            // running so the user is re-locked after
            // `UNLOCK_TIMEOUT_MS` of inactivity (independent 5-min
            // policy from the 3-min background-return window).
            restartIdleTimer()
        }
    }

    public func applicationWillResignActive() {
        timer?.cancel()
        // Stamp on the same monotonic clock applicationDidBecomeActive
        // reads so a long suspend cannot smuggle past the budget.
        // `mach_continuous_time()` keeps counting while the device
        // is asleep, so a screen-off-overnight foreground-resume
        // observes the full elapsed time even if the foreground
        // idle DispatchSourceTimer never fired.
        lastBackgroundMonotonicNanos = Self.monotonicNanos()
    }

    // MARK: - Monotonic clock

    /// Return the current `mach_continuous_time()` reading converted
    /// to nanoseconds. `mach_continuous_time()` keeps counting while
    /// the device is asleep (unlike `mach_absolute_time()`), so an
    /// attacker cannot extend the elapsed-time window by locking
    /// the device. The conversion uses `mach_timebase_info` to
    /// handle architectures where 1 mach tick != 1 ns; on modern
    /// A-series chips numer == denom == 1 and the conversion is a
    /// no-op.
    /// this primitive is a copy of `UnlockAttemptLimiter.monotonicNanos()`
    /// with the same overflow-safe split arithmetic for non-1:1
    /// timebases.
    private static func monotonicNanos() -> UInt64 {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let ticks = mach_continuous_time()
        if info.numer == info.denom {
            return ticks
        }
        let numer = UInt64(info.numer)
        let denom = UInt64(info.denom)
        let high = ticks >> 32
        let low = ticks & 0xFFFFFFFF
        return ((high * numer / denom) << 32) + (low * numer / denom)
    }

    /// Compute elapsed milliseconds between two `monotonicNanos()`
    /// readings. Returns 0 if `to <= from` (the reboot case is
    /// handled by the explicit `now < lastUnlockMonotonicNanos`
    /// branch in `applicationDidBecomeActive`).
    private static func elapsedMillis(from: UInt64, to: UInt64) -> UInt64 {
        guard to > from else { return 0 }
        return (to - from) / 1_000_000
    }

    // MARK: - Internals

    private func restartIdleTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(Constants.UNLOCK_TIMEOUT_MS))
        t.setEventHandler { [weak self] in
            self?.lockAndPresent()
        }
        t.resume()
        timer = t
    }

    private func lockAndPresent() {
        timer?.cancel()
        // route the relock through `UnlockCoordinatorV2.lock()`
        // (rather than `Strongbox.shared.clearSnapshot()` directly) so
        // the relock waits behind any in-flight `persistSnapshot` /
        // `appendWallet` / `setActiveNetwork` mutator. The coordinator's
        // `lock()` takes the same `_mutationLock` (NSRecursiveLock) as
        // every mutator, so a relock kicked off by the idle timer or a
        // >5min foreground-resume can never clear the snapshot in the
        // middle of a write pipeline. See the security findings doc
        // a prior durability gap (relock-during-persist).
        UnlockCoordinatorV2.lock()
        // No wallet configured yet? Just drop the snapshot -
        // there's nothing for the user to unlock. Onboarding will set
        // a password when they create or import their first wallet,
        // and the cold-launch gate (`HomeViewController.routeInitialScreen`)
        // already gates that flow on the v2 boot state. Skipping
        // the dialog here fixes the bug where a long-foregrounded
        // brand-new install (no wallet ever created) would prompt for
        // an unlock password it doesn't have.
        // We check `bootState` rather than an in-memory wallet
        // count because the snapshot was just cleared - the only
        // surviving signal is whether a slot file exists on disk.
        guard case .strongboxPresent = UnlockCoordinatorV2.bootState() else { return }
        guard !Strongbox.shared.isSnapshotLoaded else { return }
        // Defer the actual present to the next runloop tick so any
        // in-flight scene-activation transition (we get here from
        // `applicationDidBecomeActive`) has finished. UIKit silently
        // drops modal presentations issued during a transition,
        // which is the bug that left the user looking at a blank
        // home strip with no unlock dialog after a >5min background.
        DispatchQueue.main.async {
            self.presentUnlockGate()
        }
    }

    /// Walk to the app's `HomeViewController` and route through its
    /// public relock entry. `HomeViewController.relockAndPresentUnlock`
    /// dismisses any leftover modal, blanks the address strip, and
    /// presents the same cold-launch unlock dialog the very first
    /// `routeInitialScreen` uses - so the wrong-password / wait /
    /// `showMain` UX matches the rest of the app exactly.
    private func presentUnlockGate() {
        guard let scene = UIApplication.shared.connectedScenes
        .compactMap({ $0 as? UIWindowScene }).first,
        let window = scene.keyWindow ?? scene.windows.first,
        let home = Self.findHomeViewController(under: window.rootViewController)
        else { return }
        // Already in a relock prompt? Nothing to do.
        if home.presentedViewController is UnlockDialogViewController { return }
        home.relockAndPresentUnlock()
    }

    /// Walk the presentation chain looking for the app's
    /// `HomeViewController`. Returns nil on cold-launch / splash
    /// states where it isn't the rootVC yet (those screens haven't
    /// unlocked the strongbox, so the relock dialog isn't relevant).
    private static func findHomeViewController(
        under root: UIViewController?) -> HomeViewController? {
        var node = root
        while let cur = node {
            if let home = cur as? HomeViewController { return home }
            node = cur.presentedViewController
        }
        return nil
    }

    private func installInteractionHook() {
        // Install three pass-through gesture
        // recognisers on the key window so every user interaction
        // (tap / pan / long-press) resets the idle timer. All use
        // `cancelsTouchesInView = false` so they are transparent to
        // downstream hit-testing. A permissive delegate allows
        // simultaneous recognition with any other recogniser
        // (including UITableView's / UIScrollView's internal pan).
        // Also subscribe to UITextField textDidChange so typing
        // counts as activity even if the user never lifts their
        // finger to trigger a tap / pan recognition.
        DispatchQueue.main.async {
            guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first,
            let window = scene.keyWindow ?? scene.windows.first else { return }

            let tap = UITapGestureRecognizer(
                target: self, action: #selector(self.anyInteraction))
            tap.cancelsTouchesInView = false
            tap.delegate = PassThroughGestureDelegate.shared
            window.addGestureRecognizer(tap)

            let pan = UIPanGestureRecognizer(
                target: self, action: #selector(self.anyInteraction))
            pan.cancelsTouchesInView = false
            pan.delegate = PassThroughGestureDelegate.shared
            // Accept any number of touches so two-finger scrolls etc
            // also count.
            pan.minimumNumberOfTouches = 1
            pan.maximumNumberOfTouches = Int.max
            window.addGestureRecognizer(pan)

            let press = UILongPressGestureRecognizer(
                target: self, action: #selector(self.anyInteraction))
            press.cancelsTouchesInView = false
            press.delegate = PassThroughGestureDelegate.shared
            // Standard short long-press threshold; we just need the
            // .began edge to fire to reset the timer.
            press.minimumPressDuration = 0.4
            window.addGestureRecognizer(press)

            NotificationCenter.default.addObserver(
                self,
                selector: #selector(self.anyInteraction),
                name: UITextField.textDidChangeNotification,
                object: nil)
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(self.anyInteraction),
                name: UITextView.textDidChangeNotification,
                object: nil)
        }
    }

    @objc private func anyInteraction() {
        restartIdleTimer()
    }
}

private final class PassThroughGestureDelegate: NSObject, UIGestureRecognizerDelegate {
    static let shared = PassThroughGestureDelegate()
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
