//
//  IgnoredUpdatesManager.swift
//  AltStore
//
//  Remembers which app updates the user chose to ignore. An ignore is tied to the exact
//  version that was available, so it expires automatically when an even newer version appears.
//

import Foundation
import CoreData

import AltStoreCore

final class IgnoredUpdatesManager
{
    static let shared = IgnoredUpdatesManager()
    static let didChangeNotification = Notification.Name("io.altstore.IgnoredUpdatesManager.didChange")

    private let defaultsKey = "ignoredAppUpdates"

    /// bundleIdentifier -> version that was ignored.
    private var ignored: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }

    /// Version string of the update that's currently offered for this app.
    static func availableVersion(for installedApp: InstalledApp) -> String?
    {
        installedApp.storeApp?.latestSupportedVersion?.version
    }

    func isIgnored(_ installedApp: InstalledApp) -> Bool
    {
        guard let version = Self.availableVersion(for: installedApp) else { return false }
        return self.ignored[installedApp.bundleIdentifier] == version
    }

    func ignore(_ installedApps: [InstalledApp])
    {
        var ignored = self.ignored
        for app in installedApps
        {
            guard let version = Self.availableVersion(for: app) else { continue }
            ignored[app.bundleIdentifier] = version
        }
        self.ignored = ignored
        self.post()
    }

    func unignore(_ installedApps: [InstalledApp])
    {
        var ignored = self.ignored
        for app in installedApps { ignored[app.bundleIdentifier] = nil }
        self.ignored = ignored
        self.post()
    }

    /// Bundle identifiers whose currently available update is ignored. Drops stale entries first.
    func ignoredBundleIdentifiers(in context: NSManagedObjectContext = DatabaseManager.shared.viewContext) -> [String]
    {
        var result: [String] = []
        var remaining = self.ignored
        guard !remaining.isEmpty else { return [] }

        context.performAndWait {
            let fetchRequest = InstalledApp.fetchRequest() as NSFetchRequest<InstalledApp>
            fetchRequest.predicate = NSPredicate(format: "%K IN %@", #keyPath(InstalledApp.bundleIdentifier), Array(remaining.keys))
            fetchRequest.returnsObjectsAsFaults = false

            let apps = (try? context.fetch(fetchRequest)) ?? []
            let known = Set(apps.map { $0.bundleIdentifier })

            for app in apps
            {
                if Self.availableVersion(for: app) == remaining[app.bundleIdentifier]
                {
                    result.append(app.bundleIdentifier)
                }
                else
                {
                    remaining[app.bundleIdentifier] = nil // A newer version came out, so the ignore expired.
                }
            }

            for key in remaining.keys where !known.contains(key) { remaining[key] = nil } // App uninstalled.
        }

        if remaining != self.ignored { self.ignored = remaining }
        return result
    }

    /// Predicate that hides ignored updates from an InstalledApp fetch request.
    func excludingIgnoredPredicate() -> NSPredicate
    {
        let identifiers = self.ignoredBundleIdentifiers()
        return NSPredicate(format: "NOT (%K IN %@)", #keyPath(InstalledApp.bundleIdentifier), identifiers)
    }

    private func post()
    {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }
}
