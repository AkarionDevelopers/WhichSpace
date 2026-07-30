import Cocoa

// MARK: - Display Names

/// Resolves the CGS display identifiers used throughout the app to the names
/// macOS shows for the same monitors ("PB248", "Built-in Retina Display").
///
/// CGS reports each display as the string form of its display UUID, which is
/// exactly what `CGDisplayCreateUUIDFromDisplayID` produces for an `NSScreen`,
/// so the two sides join on that value. Identifiers with no attached screen
/// (a disconnected display still holding Spaces, or the `Main` fallback
/// `SpaceSnapshotService` uses) fall back to a positional name.
@MainActor
enum DisplayNames {
    /// The display's macOS name, or "Display N" using its 1-based position in
    /// the caller's display list.
    static func name(forDisplay displayID: String, position: Int) -> String {
        screen(forDisplay: displayID)?.localizedName
            ?? String(format: Localization.labelDisplayNumber, position)
    }

    private static func screen(forDisplay displayID: String) -> NSScreen? {
        NSScreen.screens.first { uuid(for: $0) == displayID }
    }

    /// The display UUID string for a screen, matching the identifiers in
    /// `CGSCopyManagedDisplaySpaces`.
    static func uuid(for screen: NSScreen) -> String? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
        else {
            return nil
        }
        return CFUUIDCreateString(nil, uuid) as String?
    }
}

// MARK: - Display Space Provider Protocol

/// Protocol for abstracting CGS display space functions for testability
protocol DisplaySpaceProvider: Sendable {
    // swiftlint:disable:next discouraged_optional_collection
    func copyManagedDisplaySpaces() -> [NSDictionary]?
    func copyActiveMenuBarDisplayIdentifier() -> String?
    func fullscreenOwnerPIDs(forSpaceIDs spaceIDs: [Int]) -> [Int: pid_t]
    func spacesWithWindows(forSpaceIDs spaceIDs: [Int]) -> Set<Int>
    func spaces(forWindowIDs windowIDs: [UInt32]) -> [UInt32: Int]
}

// MARK: - CGSDisplaySpaceProvider

/// Default implementation using the actual CGS/SLS functions
struct CGSDisplaySpaceProvider: DisplaySpaceProvider {
    private let conn: Int32

    init() {
        conn = _CGSDefaultConnection()
    }

    // swiftlint:disable:next discouraged_optional_collection
    func copyManagedDisplaySpaces() -> [NSDictionary]? {
        guard let result = CGSCopyManagedDisplaySpaces(conn) else {
            return nil
        }
        return result.takeRetainedValue() as? [NSDictionary]
    }

    func copyActiveMenuBarDisplayIdentifier() -> String? {
        guard let result = CGSCopyActiveMenuBarDisplayIdentifier(conn) else {
            return nil
        }
        return result.takeRetainedValue() as String
    }

    func spacesWithWindows(forSpaceIDs spaceIDs: [Int]) -> Set<Int> {
        // Get all windows (not just on-screen) to detect windows on other spaces
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        // Collect all qualifying window IDs
        var windowIDs: [Int] = []

        for window in windowList {
            // Filter to regular windows (layer 0) - skip menu bar, dock, etc.
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0 else {
                continue
            }

            // Skip windows that are too small (likely utility/overlay windows)
            guard let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let width = bounds["Width"] as? Double,
                  let height = bounds["Height"] as? Double,
                  width > 5, height > 5
            else {
                continue
            }

            if let windowNumber = window[kCGWindowNumber as String] as? Int {
                windowIDs.append(windowNumber)
            }
        }

        guard !windowIDs.isEmpty else {
            return []
        }

        // Single batch call to get all spaces for all windows
        // Selector 0x7 = all spaces the windows are on
        guard let result = SLSCopySpacesForWindows(conn, 0x7, windowIDs as CFArray) else {
            return []
        }
        let spaces = result.takeRetainedValue() as? [Int] ?? []

        let spaceIDSet = Set(spaceIDs)
        return Set(spaces).intersection(spaceIDSet)
    }

    /// Maps each window to the Space it lives on, one CGS call per window so
    /// the association survives (`SLSCopySpacesForWindows` flattens a batch
    /// into an unordered union). Callers pass a handful of editor windows,
    /// not the whole window list.
    func spaces(forWindowIDs windowIDs: [UInt32]) -> [UInt32: Int] {
        var result: [UInt32: Int] = [:]
        for windowID in windowIDs {
            guard let spaces = SLSCopySpacesForWindows(conn, 0x7, [windowID] as CFArray),
                  let spaceID = (spaces.takeRetainedValue() as? [Int])?.first
            else {
                continue
            }
            result[windowID] = spaceID
        }
        return result
    }

    /// Maps each fullscreen space ID to the PID of the app whose window lives on it.
    /// Windows are grouped by owning app (front-to-back) so each app needs one
    /// batched space query, and the walk stops once every space is resolved.
    func fullscreenOwnerPIDs(forSpaceIDs spaceIDs: [Int]) -> [Int: pid_t] {
        guard !spaceIDs.isEmpty else {
            return [:]
        }
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let windowList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }

        var windowsByPID: [pid_t: [Int]] = [:]
        var orderedPIDs: [pid_t] = []
        for window in windowList {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let windowNumber = window[kCGWindowNumber as String] as? Int,
                  let ownerPID = window[kCGWindowOwnerPID as String] as? pid_t
            else {
                continue
            }
            if windowsByPID[ownerPID] == nil {
                orderedPIDs.append(ownerPID)
            }
            windowsByPID[ownerPID, default: []].append(windowNumber)
        }

        var unresolved = Set(spaceIDs)
        var owners: [Int: pid_t] = [:]
        for pid in orderedPIDs {
            guard !unresolved.isEmpty else {
                break
            }
            guard let windowNumbers = windowsByPID[pid],
                  let result = SLSCopySpacesForWindows(conn, 0x7, windowNumbers as CFArray)
            else {
                continue
            }
            let spaces = result.takeRetainedValue() as? [Int] ?? []
            for spaceID in spaces where unresolved.contains(spaceID) {
                owners[spaceID] = pid
                unresolved.remove(spaceID)
            }
        }
        return owners
    }
}
