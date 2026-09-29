//
//  PairingFileViewController.swift
//  AltStore
//
//  Replaces the old “Remote AltServer” screen + first-run “Connect to AltServer” setup.
//

import UIKit
import UniformTypeIdentifiers

import AltStoreCore

final class PairingFileViewController: UITableViewController
{
    /// Present the Files app right away when no pairing file exists.
    var promptsForFileWhenMissing = true

    /// Called after the pairing file changed (added or deleted).
    var changeHandler: (() -> Void)?

    private enum Section: Int, CaseIterable
    {
        case status
        case actions
        case delete
    }

    private var status: PairingFileManager.Status = .missing
    private var hasPromptedThisSession = false
    private var isPresentingPicker = false

    init()
    {
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder)
    {
        super.init(style: .insetGrouped)
    }

    override func viewDidLoad()
    {
        super.viewDidLoad()

        self.title = NSLocalizedString("Pairing File", comment: "")
        self.navigationItem.largeTitleDisplayMode = .never
        self.tableView.backgroundColor = .altBackground

        if self.presentingViewController != nil, self.navigationController?.viewControllers.first === self
        {
            self.navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(PairingFileViewController.close))
        }

        NotificationCenter.default.addObserver(self, selector: #selector(PairingFileViewController.reload), name: PairingFileManager.didChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(PairingFileViewController.reload), name: UIApplication.didBecomeActiveNotification, object: nil)

        self.reload()
    }

    override func viewDidAppear(_ animated: Bool)
    {
        super.viewDidAppear(animated)

        self.promptIfNeeded()
    }

    @objc private func close()
    {
        self.dismiss(animated: true)
    }

    @objc private func reload()
    {
        self.status = PairingFileManager.shared.refresh()
        self.tableView.reloadData()
    }

    /// When there is no pairing file (never added, or just deleted), bring up the Files app.
    private func promptIfNeeded()
    {
        guard self.promptsForFileWhenMissing, !self.status.isPresent, !self.hasPromptedThisSession, self.presentedViewController == nil else { return }

        self.hasPromptedThisSession = true
        self.presentFilePicker()
    }

    private func presentFilePicker()
    {
        guard !self.isPresentingPicker else { return }
        self.isPresentingPicker = true

        let types: [UTType] = [.propertyList, .mobiledevicepairing, .xml, .data]

        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        self.present(picker, animated: true)
    }

    private func confirmDelete()
    {
        let alertController = UIAlertController(title: NSLocalizedString("Delete Pairing File?", comment: ""),
                                                message: NSLocalizedString("AltStore won’t be able to install or refresh apps on this device until you add a new pairing file.", comment: ""),
                                                preferredStyle: .actionSheet)
        alertController.addAction(UIAlertAction(title: NSLocalizedString("Delete Pairing File", comment: ""), style: .destructive) { [weak self] _ in
            guard let self else { return }
            PairingFileManager.shared.deletePairingFile()
            self.changeHandler?()
            self.reload()

            // No pairing file anymore, so ask for a new one right away.
            DispatchQueue.main.async { self.presentFilePicker() }
        })
        alertController.addAction(.cancel)

        if let popover = alertController.popoverPresentationController
        {
            popover.sourceView = self.tableView
            popover.sourceRect = self.tableView.rectForRow(at: IndexPath(row: 0, section: Section.delete.rawValue))
        }

        self.present(alertController, animated: true)
    }

    private func showAnisetteServer()
    {
        let hostingController = RemoteAltServerView.makeViewController()
        self.navigationController?.pushViewController(hostingController, animated: true)
    }
}

extension PairingFileViewController
{
    override func numberOfSections(in tableView: UITableView) -> Int
    {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int
    {
        switch Section(rawValue: section)!
        {
        case .status: return 1
        case .actions: return 2
        case .delete: return self.status.isPresent ? 1 : 0
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String?
    {
        switch Section(rawValue: section)!
        {
        case .status:
            if self.status.isPresent
            {
                return NSLocalizedString("AltStore uses this file to install and refresh apps directly on this device, without a computer.", comment: "")
            }
            return NSLocalizedString("No pairing file found. Add the .plist pairing file created by iloader, or use “Place Pairing File” in iloader with AltStore selected.", comment: "")
        case .actions, .delete: return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell
    {
        let cell = UITableViewCell(style: .value1, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()

        switch Section(rawValue: indexPath.section)!
        {
        case .status:
            content.text = NSLocalizedString("Pairing File", comment: "")
            switch self.status
            {
            case .missing:
                content.secondaryText = NSLocalizedString("Not Found", comment: "")
                content.image = UIImage(systemName: "xmark.circle.fill")
                content.imageProperties.tintColor = .systemRed
            case .present(let source):
                content.secondaryText = NSLocalizedString("Detected", comment: "") + " · " + source.localizedName
                content.image = UIImage(systemName: "checkmark.circle.fill")
                content.imageProperties.tintColor = .systemGreen
            }
            cell.selectionStyle = .none

        case .actions:
            if indexPath.row == 0
            {
                content.text = self.status.isPresent ? NSLocalizedString("Replace with .plist Pairing File…", comment: "") : NSLocalizedString("Add .plist Pairing File…", comment: "")
                content.image = UIImage(systemName: "doc.badge.plus")
                content.imageProperties.tintColor = .altPrimary
            }
            else
            {
                content.text = NSLocalizedString("Anisette Server", comment: "")
                content.image = UIImage(systemName: "server.rack")
                content.imageProperties.tintColor = .altPrimary
                cell.accessoryType = .disclosureIndicator
            }

        case .delete:
            content.text = NSLocalizedString("Delete Pairing File", comment: "")
            content.textProperties.color = .systemRed
            content.textProperties.alignment = .center
        }

        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath)
    {
        tableView.deselectRow(at: indexPath, animated: true)

        switch Section(rawValue: indexPath.section)!
        {
        case .status: break
        case .actions:
            if indexPath.row == 0 { self.presentFilePicker() } else { self.showAnisetteServer() }
        case .delete: self.confirmDelete()
        }
    }
}

extension PairingFileViewController: UIDocumentPickerDelegate
{
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL])
    {
        self.isPresentingPicker = false
        guard let url = urls.first else { return }

        do
        {
            try PairingFileManager.shared.importPairingFile(from: url)
            self.changeHandler?()
            self.reload()
        }
        catch
        {
            let alertController = UIAlertController(title: NSLocalizedString("Unable to Add Pairing File", comment: ""), message: error.localizedDescription, preferredStyle: .alert)
            alertController.addAction(UIAlertAction(title: NSLocalizedString("Try Again", comment: ""), style: .default) { [weak self] _ in self?.presentFilePicker() })
            alertController.addAction(.cancel)
            self.present(alertController, animated: true)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController)
    {
        self.isPresentingPicker = false
    }
}
