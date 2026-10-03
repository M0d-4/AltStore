//
//  AppExtensionSelection.swift
//  AltStore
//
//

import SwiftUI
import UIKit

import AltStoreCore
import AltSign

enum AppExtensionsPrompt
{
    /// Asks what to do with the app's extensions, then removes the ones the user doesn't want.
    /// Throws `OperationError.cancelled` if the user cancels.
    @MainActor
    @discardableResult
    static func present(for application: ALTApplication, from presenter: UIViewController) async throws -> Bool
    {
        let extensions = application.appExtensions
        guard !extensions.isEmpty else { return false }

        let decision = try await self.askForDecision(application: application, extensions: extensions, presenter: presenter)

        switch decision
        {
        case .keepAll(let useMainProfile): return useMainProfile
        case .removeAll: try self.remove(Array(extensions), from: application)
        case .removeSelected(let selection): try self.remove(Array(selection), from: application)
        }
        
        return false
    }

    private enum Decision
    {
        case keepAll(useMainProfile: Bool)
        case removeAll
        case removeSelected(Set<ALTApplication>)
    }

    @MainActor
    private static func askForDecision(application: ALTApplication, extensions: Set<ALTApplication>, presenter: UIViewController) async throws -> Decision
    {
        let firstSentence: String
        if UserDefaults.standard.activeAppLimitIncludesExtensions
        {
            firstSentence = NSLocalizedString("Non-developer Apple IDs are limited to 3 active apps and app extensions.", comment: "")
        }
        else
        {
            firstSentence = NSLocalizedString("Non-developer Apple IDs are limited to creating 10 App IDs per week.", comment: "")
        }

        let countText = String(format: NSLocalizedString("“%@” has %@ app extension(s).", comment: ""), application.name, NSNumber(value: extensions.count))
        let message = firstSentence + " " + NSLocalizedString("Would you like to remove this app's extensions so they don't count towards your limit?", comment: "") + "\n\n" + countText

        // Present on top of whatever is currently visible.
        var topViewController = presenter
        while let presented = topViewController.presentedViewController { topViewController = presented }

        return try await withCheckedThrowingContinuation { continuation in
            let alertController = UIAlertController(title: NSLocalizedString("App Contains Extensions", comment: ""), message: message, preferredStyle: .alert)

            alertController.addAction(UIAlertAction(title: UIAlertAction.cancel.title, style: UIAlertAction.cancel.style) { _ in
                continuation.resume(throwing: OperationError.cancelled)
            })
            alertController.addAction(UIAlertAction(title: NSLocalizedString("Keep App Extensions (Use Main Profile)", comment: ""), style: .default) { _ in
                continuation.resume(returning: .keepAll(useMainProfile: true))
            })
            alertController.addAction(UIAlertAction(title: NSLocalizedString("Keep App Extensions (Register App ID for Each Extension)", comment: ""), style: .default) { _ in
                continuation.resume(returning: .keepAll(useMainProfile: false))
            })
            alertController.addAction(UIAlertAction(title: NSLocalizedString("Remove App Extensions", comment: ""), style: .destructive) { _ in
                continuation.resume(returning: .removeAll)
            })

            if extensions.count > 1
            {
                // New: pick exactly which extensions to keep.
                alertController.addAction(UIAlertAction(title: NSLocalizedString("Choose App Extensions", comment: ""), style: .default) { _ in
                    let chooser = AppExtensionChooserHostingController(extensions: extensions) { result in
                        switch result
                        {
                        case .some(let toRemove): continuation.resume(returning: .removeSelected(toRemove))
                        case .none: continuation.resume(throwing: OperationError.cancelled)
                        }
                    }

                    let navigationController = UINavigationController(rootViewController: chooser)
                    navigationController.modalPresentationStyle = .formSheet
                    topViewController.present(navigationController, animated: true)
                })
            }

            topViewController.present(alertController, animated: true)
        }
    }

    // MARK: - Removal

    static func remove(_ extensionsToRemove: [ALTApplication], from application: ALTApplication) throws
    {
        guard !extensionsToRemove.isEmpty else { return }

        for appExtension in extensionsToRemove
        {
            try FileManager.default.removeItem(at: appExtension.fileURL)
        }

        let removedPaths = Set(extensionsToRemove.map { "PlugIns/" + $0.fileURL.lastPathComponent })

        let scInfoURL = application.fileURL.appendingPathComponent("SC_Info")
        let manifestPlistURL = scInfoURL.appendingPathComponent("Manifest.plist")

        if let manifestPlist = NSMutableDictionary(contentsOf: manifestPlistURL),
           let sinfReplicationPaths = manifestPlist["SinfReplicationPaths"] as? [String]
        {
            // Only drop the paths belonging to the extensions we removed (the ones that are kept still need theirs).
            let replacementPaths = sinfReplicationPaths.filter { path in
                !removedPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") })
            }
            manifestPlist["SinfReplicationPaths"] = replacementPaths
            try manifestPlist.write(to: manifestPlistURL)
        }
    }
}

// MARK: - Chooser UI

final class AppExtensionChooserModel: ObservableObject
{
    /// Extensions the user wants to REMOVE. Ticked rows are kept.
    @Published var removed = Set<ALTApplication>()
}

struct AppExtensionChooserView: View
{
    let extensions: [ALTApplication]

    @ObservedObject var model: AppExtensionChooserModel

    var body: some View {
        List {
            Section {
                ForEach(extensions, id: \.self) { item in
                    SwiftUI.Button {
                        if model.removed.contains(item) { model.removed.remove(item) } else { model.removed.insert(item) }
                    } label: {
                        HStack {
                            Text(item.bundleIdentifier)
                                .foregroundStyle(.primary)
                            Spacer()
                            if !model.removed.contains(item)
                            {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(.rect)
                    }
                }
            } footer: {
                Text("Ticked extensions are kept. Unticked extensions are removed before the app is installed.")
            }
        }
    }
}

final class AppExtensionChooserHostingController: UIHostingController<AppExtensionChooserView>
{
    private var completion: ((Set<ALTApplication>?) -> Void)?
    private let model: AppExtensionChooserModel

    init(extensions: Set<ALTApplication>, completion: @escaping (Set<ALTApplication>?) -> Void)
    {
        let model = AppExtensionChooserModel()
        self.model = model
        self.completion = completion

        let sorted = extensions.sorted { $0.bundleIdentifier < $1.bundleIdentifier }
        super.init(rootView: AppExtensionChooserView(extensions: sorted, model: model))
    }

    @MainActor required dynamic init?(coder aDecoder: NSCoder)
    {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad()
    {
        super.viewDidLoad()

        self.title = NSLocalizedString("App Extensions", comment: "")
        self.navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.finish(with: nil)
        })
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.finish(with: self?.model.removed ?? [])
        })
        self.isModalInPresentation = true
    }

    private func finish(with selection: Set<ALTApplication>?)
    {
        let completion = self.completion
        self.completion = nil
        self.dismiss(animated: true) { completion?(selection) }
    }
}
