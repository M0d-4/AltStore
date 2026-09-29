//
//  UpdatesViewController.swift
//  AltStore
//
//  Shows updates for installed apps (found in the user's sources) and lets the user install them,
//  or ignore a specific update - one at a time (long press) or several at once (Select).
//

import UIKit
import CoreData
import Combine

import AltStoreCore
import Roxas

import Nuke

final class UpdatesViewController: UICollectionViewController
{
    private enum Section: Int, CaseIterable
    {
        case available
        case ignored

        var title: String {
            switch self
            {
            case .available: return NSLocalizedString("Available Updates", comment: "")
            case .ignored: return NSLocalizedString("Ignored Updates", comment: "")
            }
        }
    }

    private var dataSource: UICollectionViewDiffableDataSource<Section, NSManagedObjectID>!
    private var fetchedResultsController: NSFetchedResultsController<InstalledApp>!
    private var cancellables = Set<AnyCancellable>()

    private var icons = [URL: UIImage]()
    private var updating = Set<NSManagedObjectID>()

    private var placeholderLabel = UILabel()
    private var ignoreSelectedItem: UIBarButtonItem!
    private var updateAllItem: UIBarButtonItem!
    private var selectItem: UIBarButtonItem!

    private var context: NSManagedObjectContext { DatabaseManager.shared.viewContext }

    init()
    {
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.headerMode = .supplementary
        configuration.backgroundColor = .clear
        super.init(collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration))
    }

    required init?(coder: NSCoder)
    {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad()
    {
        super.viewDidLoad()

        self.title = NSLocalizedString("Updates", comment: "")
        self.navigationController?.view.tintColor = .altPrimary
        self.collectionView.backgroundColor = .altBackground
        self.collectionView.allowsMultipleSelectionDuringEditing = true
        self.collectionView.alwaysBounceVertical = true

        self.prepareDataSource()
        self.prepareNavigationItems()
        self.preparePlaceholder()

        let refreshControl = UIRefreshControl(frame: .zero, primaryAction: UIAction { [weak self] _ in self?.refreshSources() })
        self.collectionView.refreshControl = refreshControl

        let request = InstalledApp.supportedUpdatesFetchRequest()
        request.sortDescriptors = [NSSortDescriptor(keyPath: \InstalledApp.name, ascending: true)]
        request.returnsObjectsAsFaults = false
        self.fetchedResultsController = NSFetchedResultsController(fetchRequest: request, managedObjectContext: self.context, sectionNameKeyPath: nil, cacheName: nil)
        self.fetchedResultsController.delegate = self
        try? self.fetchedResultsController.performFetch()

        AppManager.shared.$updateSourcesResult
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
            .store(in: &self.cancellables)

        NotificationCenter.default.addObserver(self, selector: #selector(UpdatesViewController.ignoredUpdatesDidChange), name: IgnoredUpdatesManager.didChangeNotification, object: nil)

        self.reload()
    }

    override func viewWillAppear(_ animated: Bool)
    {
        super.viewWillAppear(animated)
        self.reload()
    }

    @objc private func ignoredUpdatesDidChange()
    {
        self.reload()
    }

    // MARK: - Setup

    private func prepareDataSource()
    {
        let cellRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, NSManagedObjectID> { [weak self] cell, indexPath, objectID in
            guard let self, let app = self.installedApp(for: objectID) else { return }
            self.configure(cell, with: app)
        }

        self.dataSource = UICollectionViewDiffableDataSource<Section, NSManagedObjectID>(collectionView: self.collectionView) { collectionView, indexPath, objectID in
            collectionView.dequeueConfiguredReusableCell(using: cellRegistration, for: indexPath, item: objectID)
        }

        let headerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] header, _, indexPath in
            guard let self, let section = self.dataSource.sectionIdentifier(for: indexPath.section) else { return }
            var content = UIListContentConfiguration.groupedHeader()
            content.text = section.title
            header.contentConfiguration = content
        }

        self.dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: headerRegistration, for: indexPath)
        }
    }

    private func prepareNavigationItems()
    {
        self.selectItem = UIBarButtonItem(title: NSLocalizedString("Select", comment: ""), style: .plain, target: self, action: #selector(UpdatesViewController.toggleSelecting))
        self.updateAllItem = UIBarButtonItem(title: NSLocalizedString("Update All", comment: ""), style: .plain, target: self, action: #selector(UpdatesViewController.updateAll))
        self.ignoreSelectedItem = UIBarButtonItem(title: NSLocalizedString("Ignore", comment: ""), style: .plain, target: self, action: #selector(UpdatesViewController.ignoreSelected))

        self.navigationItem.leftBarButtonItem = self.updateAllItem
        self.navigationItem.rightBarButtonItem = self.selectItem
    }

    private func preparePlaceholder()
    {
        self.placeholderLabel.text = NSLocalizedString("All Apps Are Up to Date", comment: "")
        self.placeholderLabel.textColor = .secondaryLabel
        self.placeholderLabel.font = .preferredFont(forTextStyle: .title3)
        self.placeholderLabel.textAlignment = .center
        self.placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        self.collectionView.backgroundView = {
            let view = UIView()
            view.addSubview(self.placeholderLabel)
            NSLayoutConstraint.activate([self.placeholderLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
                                         self.placeholderLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)])
            return view
        }()
    }

    // MARK: - Data

    private func installedApp(for objectID: NSManagedObjectID) -> InstalledApp?
    {
        try? self.context.existingObject(with: objectID) as? InstalledApp
    }

    private func reload()
    {
        guard self.isViewLoaded, let fetched = self.fetchedResultsController?.fetchedObjects else { return }

        let ignoredIdentifiers = Set(IgnoredUpdatesManager.shared.ignoredBundleIdentifiers())
        let available = fetched.filter { !ignoredIdentifiers.contains($0.bundleIdentifier) }
        let ignored = fetched.filter { ignoredIdentifiers.contains($0.bundleIdentifier) }

        var snapshot = NSDiffableDataSourceSnapshot<Section, NSManagedObjectID>()
        if !available.isEmpty
        {
            snapshot.appendSections([.available])
            snapshot.appendItems(available.map { $0.objectID }, toSection: .available)
        }
        if !ignored.isEmpty
        {
            snapshot.appendSections([.ignored])
            snapshot.appendItems(ignored.map { $0.objectID }, toSection: .ignored)
        }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        self.dataSource.apply(snapshot, animatingDifferences: self.view.window != nil)

        self.placeholderLabel.isHidden = !fetched.isEmpty
        self.updateAllItem.isEnabled = !available.isEmpty
        self.selectItem.isEnabled = !fetched.isEmpty

        // Badge on the tab = updates the user hasn't ignored.
        self.navigationController?.tabBarItem.badgeValue = available.isEmpty ? nil : String(available.count)
        self.updateIgnoreItemState()
    }

    private func configure(_ cell: UICollectionViewListCell, with app: InstalledApp)
    {
        var content = UIListContentConfiguration.subtitleCell()
        content.text = app.name

        let installedVersion = app.localizedVersion
        let newVersion = app.storeApp?.latestSupportedVersion?.localizedVersion ?? "?"
        content.secondaryText = String(format: NSLocalizedString("Installed: %@\nUpdate to: %@", comment: ""), installedVersion, newVersion)
        content.secondaryTextProperties.numberOfLines = 0
        content.secondaryTextProperties.color = .secondaryLabel

        content.imageProperties.maximumSize = CGSize(width: 56, height: 56)
        content.imageProperties.reservedLayoutSize = CGSize(width: 56, height: 56)
        content.imageProperties.cornerRadius = 12.6
        content.image = UIImage(systemName: "app.fill")
        content.imageProperties.tintColor = .tertiaryLabel

        if let iconURL = app.storeApp?.iconURL
        {
            if let icon = self.icons[iconURL]
            {
                content.image = icon
                content.imageProperties.tintColor = nil
            }
            else
            {
                let objectID = app.objectID
                ImagePipeline.shared.loadImage(with: iconURL) { [weak self] result in
                    guard let self, case .success(let response) = result else { return }
                    DispatchQueue.main.async {
                        self.icons[iconURL] = response.image
                        var snapshot = self.dataSource.snapshot()
                        if snapshot.itemIdentifiers.contains(objectID)
                        {
                            snapshot.reconfigureItems([objectID])
                            self.dataSource.apply(snapshot, animatingDifferences: false)
                        }
                    }
                }
            }
        }

        cell.contentConfiguration = content

        var accessories: [UICellAccessory] = [.multiselect(displayed: .whenEditing)]

        let isIgnored = IgnoredUpdatesManager.shared.isIgnored(app)
        if isIgnored
        {
            accessories.append(.label(text: NSLocalizedString("Ignored", comment: "")))
        }

        let button = PillButton(type: .system)
        button.frame = CGRect(x: 0, y: 0, width: 76, height: 28)
        button.setTitle(NSLocalizedString("UPDATE", comment: ""), for: .normal)
        button.tintColor = app.storeApp?.tintColor ?? .altPrimary
        button.isIndicatingActivity = self.updating.contains(app.objectID)
        if self.updating.contains(app.objectID) { button.setTitle(nil, for: .normal) }
        let objectID = app.objectID
        button.addAction(UIAction { [weak self] _ in self?.update(objectID) }, for: .primaryActionTriggered)
        accessories.append(.customView(configuration: .init(customView: button, placement: .trailing(displayed: .whenNotEditing))))

        cell.accessories = accessories
        cell.backgroundConfiguration = .listGroupedCell()
    }

    // MARK: - Actions

    private func update(_ objectID: NSManagedObjectID)
    {
        guard let app = self.installedApp(for: objectID) else { return }

        if let progress = AppManager.shared.installationProgress(for: app)
        {
            progress.cancel()
            return
        }

        self.updating.insert(objectID)
        self.reload()

        AppManager.shared.update(app, presentingViewController: self) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.updating.remove(objectID)

                switch result
                {
                case .success: break
                case .failure(OperationError.cancelled): break
                case .failure(let error):
                    let toastView = ToastView(error: error)
                    toastView.opensErrorLog = true
                    toastView.show(in: self)
                }

                self.reload()
            }
        }
    }

    @objc private func updateAll()
    {
        let ignored = Set(IgnoredUpdatesManager.shared.ignoredBundleIdentifiers())
        let ids = (self.fetchedResultsController.fetchedObjects ?? []).filter { !ignored.contains($0.bundleIdentifier) }.map { $0.objectID }
        guard !ids.isEmpty else { return }

        // Run one after another so the account/authentication steps don't collide.
        func next(_ remaining: ArraySlice<NSManagedObjectID>)
        {
            guard let objectID = remaining.first, let app = self.installedApp(for: objectID) else { return }
            self.updating.insert(objectID)
            self.reload()

            AppManager.shared.update(app, presentingViewController: self) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.updating.remove(objectID)
                    self.reload()

                    switch result
                    {
                    case .failure(OperationError.cancelled): return // Stop the batch.
                    case .failure(let error):
                        let toastView = ToastView(error: error)
                        toastView.opensErrorLog = true
                        toastView.show(in: self)
                    case .success: break
                    }

                    next(remaining.dropFirst())
                }
            }
        }

        next(ids[...])
    }

    private func setIgnored(_ ignore: Bool, for apps: [InstalledApp])
    {
        if ignore { IgnoredUpdatesManager.shared.ignore(apps) } else { IgnoredUpdatesManager.shared.unignore(apps) }
        self.reload()
    }

    private var selectedApps: [InstalledApp] {
        (self.collectionView.indexPathsForSelectedItems ?? []).compactMap { indexPath in
            self.dataSource.itemIdentifier(for: indexPath).flatMap { self.installedApp(for: $0) }
        }
    }

    @objc private func toggleSelecting()
    {
        self.setEditing(!self.isEditing, animated: true)
    }

    override func setEditing(_ editing: Bool, animated: Bool)
    {
        super.setEditing(editing, animated: animated)
        self.collectionView.isEditing = editing

        self.selectItem.title = editing ? NSLocalizedString("Done", comment: "") : NSLocalizedString("Select", comment: "")
        self.selectItem.style = editing ? .done : .plain
        self.navigationItem.leftBarButtonItem = editing ? self.ignoreSelectedItem : self.updateAllItem
        self.updateIgnoreItemState()
    }

    private func updateIgnoreItemState()
    {
        guard self.ignoreSelectedItem != nil else { return }
        let selected = self.selectedApps
        self.ignoreSelectedItem.isEnabled = !selected.isEmpty

        // If everything selected is already ignored, the button un-ignores.
        let allIgnored = !selected.isEmpty && selected.allSatisfy { IgnoredUpdatesManager.shared.isIgnored($0) }
        self.ignoreSelectedItem.title = allIgnored ? NSLocalizedString("Stop Ignoring", comment: "") : NSLocalizedString("Ignore", comment: "")
    }

    @objc private func ignoreSelected()
    {
        let selected = self.selectedApps
        guard !selected.isEmpty else { return }

        let allIgnored = selected.allSatisfy { IgnoredUpdatesManager.shared.isIgnored($0) }
        self.setIgnored(!allIgnored, for: selected)
        self.setEditing(false, animated: true)
    }

    private func refreshSources()
    {
        AppManager.shared.updateAllSources { [weak self] result in
            DispatchQueue.main.async {
                self?.collectionView.refreshControl?.endRefreshing()
                self?.reload()

                if case .failure(let error) = result, let self
                {
                    let toastView = ToastView(error: error)
                    toastView.show(in: self)
                }
            }
        }
    }
}

// MARK: - Collection view

extension UpdatesViewController
{
    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath)
    {
        if self.isEditing
        {
            self.updateIgnoreItemState()
            return
        }

        collectionView.deselectItem(at: indexPath, animated: true)

        guard let objectID = self.dataSource.itemIdentifier(for: indexPath),
              let storeApp = self.installedApp(for: objectID)?.storeApp else { return }

        let appViewController = AppViewController.makeAppViewController(app: storeApp)
        self.navigationController?.pushViewController(appViewController, animated: true)
    }

    override func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath)
    {
        if self.isEditing { self.updateIgnoreItemState() }
    }

    override func collectionView(_ collectionView: UICollectionView, shouldBeginMultipleSelectionInteractionAt indexPath: IndexPath) -> Bool
    {
        return true
    }

    override func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration?
    {
        guard !self.isEditing,
              let objectID = self.dataSource.itemIdentifier(for: indexPath),
              let app = self.installedApp(for: objectID) else { return nil }

        return UIContextMenuConfiguration(identifier: indexPath as NSIndexPath, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }

            let isIgnored = IgnoredUpdatesManager.shared.isIgnored(app)

            let update = UIAction(title: NSLocalizedString("Update", comment: ""), image: UIImage(systemName: "arrow.down.circle")) { _ in
                self.update(objectID)
            }

            let ignore = UIAction(title: isIgnored ? NSLocalizedString("Stop Ignoring This Update", comment: "") : NSLocalizedString("Ignore This Update", comment: ""),
                                  image: UIImage(systemName: isIgnored ? "bell" : "bell.slash")) { _ in
                self.setIgnored(!isIgnored, for: [app])
            }

            let select = UIAction(title: NSLocalizedString("Select Multiple…", comment: ""), image: UIImage(systemName: "checkmark.circle")) { _ in
                self.setEditing(true, animated: true)
                self.collectionView.selectItem(at: indexPath, animated: true, scrollPosition: [])
                self.updateIgnoreItemState()
            }

            return UIMenu(children: [update, ignore, select])
        }
    }
}

extension UpdatesViewController: NSFetchedResultsControllerDelegate
{
    func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>)
    {
        self.reload()
    }
}

// MARK: - Multi-select picker

/// Lets the user tick several apps whose currently available update should be ignored.
/// Apps that are already ignored start out ticked; un-ticking them stops ignoring.
final class IgnoreUpdatesPickerViewController: UITableViewController
{
    private let apps: [InstalledApp]
    private var selected: Set<String>

    init(apps: [InstalledApp])
    {
        self.apps = apps
        self.selected = Set(apps.filter { IgnoredUpdatesManager.shared.isIgnored($0) }.map { $0.bundleIdentifier })
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder)
    {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad()
    {
        super.viewDidLoad()

        self.title = NSLocalizedString("Ignore Updates", comment: "")
        self.tableView.backgroundColor = .altBackground
        self.navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(IgnoreUpdatesPickerViewController.cancel))
        self.navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(IgnoreUpdatesPickerViewController.done))
    }

    @objc private func cancel()
    {
        self.dismiss(animated: true)
    }

    @objc private func done()
    {
        let toIgnore = self.apps.filter { self.selected.contains($0.bundleIdentifier) }
        let toRestore = self.apps.filter { !self.selected.contains($0.bundleIdentifier) }
        IgnoredUpdatesManager.shared.unignore(toRestore)
        IgnoredUpdatesManager.shared.ignore(toIgnore)
        self.dismiss(animated: true)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int
    {
        self.apps.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String?
    {
        NSLocalizedString("Tick the apps whose current update you want to ignore. A newer update will show up again.", comment: "")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell
    {
        let app = self.apps[indexPath.row]
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)

        var content = cell.defaultContentConfiguration()
        content.text = app.name
        content.secondaryText = String(format: NSLocalizedString("%@ → %@", comment: ""), app.localizedVersion, app.storeApp?.latestSupportedVersion?.localizedVersion ?? "?")
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        cell.accessoryType = self.selected.contains(app.bundleIdentifier) ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath)
    {
        tableView.deselectRow(at: indexPath, animated: true)

        let id = self.apps[indexPath.row].bundleIdentifier
        if self.selected.contains(id) { self.selected.remove(id) } else { self.selected.insert(id) }
        tableView.reloadRows(at: [indexPath], with: .none)
    }
}
