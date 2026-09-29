//
//
//  PairingFileManager.swift
//  AltStore
//
//  Detects, imports and deletes the device pairing file.
//
//

import Foundation
import CryptoKit

import AltStoreCore

final class PairingFileManager
{
    static let shared = PairingFileManager()

    static let didChangeNotification = Notification.Name("io.altstore.PairingFileManager.didChange")

    static let documentsFileNames = ["ALTPairingFile.mobiledevicepairing", "pairingFile.plist", "rp_pairing_file.plist"]

    enum Source
    {
        case documents   // Placed by iloader (or copied in manually).
        case imported    // Added through the Files app.
        case bundled     // Bundled by AltServer.
        case unknown

        var localizedName: String {
            switch self
            {
            case .documents: return NSLocalizedString("Placed by iloader", comment: "")
            case .imported: return NSLocalizedString("Added manually", comment: "")
            case .bundled: return NSLocalizedString("Installed with AltServer", comment: "")
            case .unknown: return NSLocalizedString("Saved on this device", comment: "")
            }
        }
    }

    enum Status
    {
        case missing
        case present(Source)

        var isPresent: Bool {
            if case .present = self { return true }
            return false
        }
    }

    enum ImportError: LocalizedError
    {
        case unreadable
        case invalid

        var errorDescription: String? {
            switch self
            {
            case .unreadable: return NSLocalizedString("The pairing file couldn’t be read.", comment: "")
            case .invalid: return NSLocalizedString("This isn’t a valid pairing file. Make sure to choose the .plist file created by iloader or StikDebug (iOS 17.4 or later).", comment: "")
            }
        }
    }

    private let sourceKey = "pairingFileSource"

    private var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private var canonicalURL: URL {
        documentsURL.appendingPathComponent(Self.documentsFileNames[0])
    }

    private var storedSource: Source {
        get {
            switch UserDefaults.standard.string(forKey: sourceKey)
            {
            case "documents": return .documents
            case "imported": return .imported
            case "bundled": return .bundled
            default: return .unknown
            }
        }
        set {
            let value: String?
            switch newValue
            {
            case .documents: value = "documents"
            case .imported: value = "imported"
            case .bundled: value = "bundled"
            case .unknown: value = nil
            }
            UserDefaults.standard.set(value, forKey: sourceKey)
        }
    }

    // MARK: - Status

    /// Looks for a file placed in Documents (by iloader etc.) and adopts it, then reports what we have.
    @discardableResult
    func refresh() -> Status
    {
        self.adoptDocumentsFileIfNeeded()

        guard Keychain.shared.devicePairingFile != nil else { return .missing }
        return .present(self.storedSource)
    }

    var status: Status { self.refresh() }

    // MARK: - Detect

    /// Adopts a pairing file that was dropped into Documents. A newly placed file always wins over the stored one,
    /// because the device only trusts its most recent pairing record.
    func adoptDocumentsFileIfNeeded()
    {
        let fileManager = FileManager.default

        for name in Self.documentsFileNames
        {
            let url = documentsURL.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: url.path), let data = try? Data(contentsOf: url) else { continue }

            let hash = Self.hash(of: data)
            if hash == UserDefaults.standard.string(forKey: "adoptedDocumentsPairingFileHash"), Keychain.shared.devicePairingFile != nil
            {
                return // Already adopted this exact file.
            }

            guard (try? Self.validate(data)) != nil else
            {
                Logger.sideload.error("Ignoring invalid pairing file found in Documents (\(name, privacy: .public)).")
                continue
            }

            Keychain.shared.devicePairingFile = data
            UserDefaults.standard.set(hash, forKey: "adoptedDocumentsPairingFileHash")
            self.storedSource = .documents
            self.markConfigured()

            Logger.sideload.notice("Adopted pairing file placed in Documents (\(name, privacy: .public)).")
            return
        }
    }

    // MARK: - Import

    /// Imports a .plist (or .mobiledevicepairing) file, e.g. one the user picked in the Files app.
    func importPairingFile(from url: URL) throws
    {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer { if didStartAccessing { url.stopAccessingSecurityScopedResource() } }

        guard let data = try? Data(contentsOf: url) else { throw ImportError.unreadable }
        try self.importPairingFile(data: data, source: .imported)
    }

    func importPairingFile(data: Data, source: Source) throws
    {
        try Self.validate(data)

        Keychain.shared.devicePairingFile = data
        self.storedSource = source

        try? data.write(to: canonicalURL, options: .atomic)
        UserDefaults.standard.set(Self.hash(of: data), forKey: "adoptedDocumentsPairingFileHash")

        self.markConfigured()
    }

    // MARK: - Delete

    func deletePairingFile()
    {
        let fileManager = FileManager.default
        for name in Self.documentsFileNames
        {
            try? fileManager.removeItem(at: documentsURL.appendingPathComponent(name))
        }

        Keychain.shared.devicePairingFile = nil
        UserDefaults.standard.removeObject(forKey: "adoptedDocumentsPairingFileHash")
        self.storedSource = .unknown

        // Don't re-adopt the copy AltServer bundled into the app, or the delete would be undone.
        UserDefaults.shared.ignoresBundledPairingFile = true
        UserDefaults.shared.prefersRemoteAltServer = false

        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    // MARK: - Helpers

    private func markConfigured()
    {
        // With a pairing file, apps are installed on-device instead of through AltServer.
        UserDefaults.shared.prefersRemoteAltServer = true
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    @discardableResult
    static func validate(_ data: Data) throws -> [String: Any]
    {
        guard let record = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else { throw ImportError.invalid }

        // Same requirement as OnDeviceClient: an RP-pairing record (iOS 17.4+) with a private key.
        guard record["private_key"] != nil else { throw ImportError.invalid }
        return record
    }

    private static func hash(of data: Data) -> String
    {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
