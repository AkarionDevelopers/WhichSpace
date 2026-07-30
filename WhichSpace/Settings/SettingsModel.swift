import AppKit
import Defaults
import SwiftUI

/// Binding layer between the SwiftUI settings panes and `DefaultsStore`.
///
/// Writes go through the store's memoizing subscript, so `mutationCount`
/// bumps and the renderer's icon cache key stays correct; the status bar then
/// refreshes via the existing `Defaults.updates` observers in AppDelegate.
/// Reads register a SwiftUI dependency on `tick`, the sole observable stored
/// property, so panes re-render on any store change - including external ones
/// (AppleScript, `defaults write`, the status menu) while the window is open.
@MainActor
@Observable
final class SettingsModel {
    /// Bumped on every write and on observed external changes; binding
    /// getters read it to register a SwiftUI observation dependency
    private(set) var tick = 0

    @ObservationIgnored private let store: DefaultsStore
    @ObservationIgnored private var launchAtLogin: LaunchAtLoginProvider
    @ObservationIgnored private let isProcessTrusted: () -> Bool
    @ObservationIgnored private var observationTask: Task<Void, Never>?

    init(
        store: DefaultsStore,
        launchAtLogin: LaunchAtLoginProvider,
        isProcessTrusted: @escaping () -> Bool = { Accessibility.isTrusted }
    ) {
        self.store = store
        self.launchAtLogin = launchAtLogin
        self.isProcessTrusted = isProcessTrusted
    }

    // MARK: - Bindings

    /// A binding for any store property, routed through the memoizing subscript.
    func binding<V>(_ keyPath: ReferenceWritableKeyPath<DefaultsStore, V>) -> Binding<V> {
        Binding(
            get: { [self] in
                _ = tick
                return store[keyPath: keyPath]
            },
            set: { [self] in
                store[keyPath: keyPath] = $0
                tick += 1
            }
        )
    }

    /// A tick-registered read for pane code that derives row enablement from
    /// other settings.
    func value<V>(_ keyPath: KeyPath<DefaultsStore, V>) -> V {
        _ = tick
        return store[keyPath: keyPath]
    }

    // MARK: - Displays

    /// A connected display, identified the way the renderer keys preferences.
    struct DisplayOption: Identifiable, Equatable {
        let displayID: String
        let name: String

        var id: String { displayID }
    }

    /// Connected displays in physical left-to-right order, so the rows read
    /// like the desk they describe. Screens whose display UUID is unavailable
    /// are skipped: without it there is no key to store a preference under.
    var connectedDisplays: [DisplayOption] {
        _ = tick
        let screens = NSScreen.screens.sorted { $0.frame.origin.x < $1.frame.origin.x }
        return screens.enumerated().compactMap { position, screen in
            guard let displayID = DisplayNames.uuid(for: screen) else {
                return nil
            }
            return DisplayOption(
                displayID: displayID,
                name: DisplayNames.name(forDisplay: displayID, position: position + 1)
            )
        }
    }

    /// A binding for one display's presentation. Writes prune `.full` rather
    /// than storing it, so the dictionary only ever holds real deviations from
    /// the default.
    func presentationBinding(for displayID: String) -> Binding<DisplayPresentation> {
        Binding(
            get: { [self] in
                _ = tick
                return store.presentation(forDisplay: displayID)
            },
            set: { [self] presentation in
                var presentations = store.displayPresentations
                if presentation == .full {
                    presentations.removeValue(forKey: displayID)
                } else {
                    presentations[displayID] = presentation
                }
                store.displayPresentations = presentations
                tick += 1
            }
        )
    }

    /// `showAllSpaces` and `showAllDisplays` route through their
    /// `SettingsConstraints` setters so any future coupling between the two
    /// keys applies to writes from the panes.
    var showAllSpacesBinding: Binding<Bool> {
        Binding(
            get: { [self] in
                _ = tick
                return store.showAllSpaces
            },
            set: { [self] in
                SettingsConstraints.setShowAllSpaces($0, store: store)
                tick += 1
            }
        )
    }

    var showAllDisplaysBinding: Binding<Bool> {
        Binding(
            get: { [self] in
                _ = tick
                return store.showAllDisplays
            },
            set: { [self] in
                SettingsConstraints.setShowAllDisplays($0, store: store)
                tick += 1
            }
        )
    }

    /// Whether accessibility permission is currently granted. Reading `tick`
    /// first lets `requestAccessibility` refresh dependent UI on a grant.
    var accessibilityGranted: Bool {
        _ = tick
        return isProcessTrusted()
    }

    /// A gated binding for `clickToSwitchSpaces`: enabling without
    /// accessibility permission leaves the store unchanged, and the tick bump
    /// re-reads the getter so the toggle visibly snaps back off.
    var clickToSwitchSpacesBinding: Binding<Bool> {
        Binding(
            get: { [self] in
                _ = tick
                return store.clickToSwitchSpaces
            },
            set: { [self] in
                SettingsConstraints.setClickToSwitchSpaces(
                    $0, store: store, isProcessTrusted: isProcessTrusted
                )
                tick += 1
            }
        )
    }

    /// A gated binding for a scroll-switching axis; same snap-back contract
    /// as `clickToSwitchSpacesBinding`.
    func scrollSwitchingBinding(axis: ReferenceWritableKeyPath<DefaultsStore, Bool>) -> Binding<Bool> {
        Binding(
            get: { [self] in
                _ = tick
                return store[keyPath: axis]
            },
            set: { [self] in
                SettingsConstraints.setScrollSwitching(
                    $0, axis: axis, store: store, isProcessTrusted: isProcessTrusted
                )
                tick += 1
            }
        )
    }

    /// The haptic slider position: 0 when feedback is off, else the stored
    /// intensity. Writing 0 disables feedback but preserves the last
    /// intensity, so re-enabling restores the previous strength.
    var scrollHapticIntensityBinding: Binding<Double> {
        Binding(
            get: { [self] in
                _ = tick
                return store.scrollHapticFeedback ? Double(store.scrollHapticIntensity) : 0
            },
            set: { [self] in
                let intensity = Int($0)
                store.scrollHapticFeedback = intensity > 0
                if intensity > 0 {
                    store.scrollHapticIntensity = intensity
                }
                tick += 1
            }
        )
    }

    /// Prompts for accessibility permission; the tick bump on grant clears
    /// the permission banner and re-enables gated toggles live.
    func requestAccessibility() {
        Accessibility.requestPermission { [weak self] in
            self?.tick += 1
        }
    }

    /// Launch at Login is not a store key: it reads SMAppService state live
    /// through the provider, which can change externally in System Settings.
    var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { [self] in
                _ = tick
                return launchAtLogin.isEnabled
            },
            set: { [self] in
                launchAtLogin.isEnabled = $0
                tick += 1
            }
        )
    }

    // MARK: - External Change Observation

    /// Starts re-rendering panes on defaults changes made outside this model.
    /// Called when the settings window opens; stopped on close so the stream
    /// does not outlive the window.
    func startObserving() {
        stopObserving()
        let keys = store.allKeys
        observationTask = Task { [weak self] in
            for await _ in Defaults.updates(keys, initial: false) {
                self?.tick += 1
            }
        }
    }

    func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
    }
}
