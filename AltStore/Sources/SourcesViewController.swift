//
//  SourcesViewController.swift
//  AltStore
//
//  Created by Riley Testut on 3/17/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

import UIKit
import CoreData

import AltStoreCore
import Roxas

import Nuke

private extension UIAction.Identifier
{
    static let showDetails = UIAction.Identifier("io.altstore.showDetails")
    static let showError = UIAction.Identifier("io.altstore.showError")
}

class SourcesViewController: UICollectionViewController
{
    var deepLinkSourceURL: URL? {
        didSet {
            self.handleAddSourceDeepLink()
        }
    }
    
    // One section per group: "All Sources" first, then a section for every source.
    // Every section has a header row (the section's root) with the apps as its children,
    // so each one can be minimised on its own.
    fileprivate enum Item: Hashable
    {
        case allSourcesHeader
        case sourceHeader(NSManagedObjectID)
        case app(section: String, id: NSManagedObjectID)
    }
    
    fileprivate static let allSourcesSectionID = "io.altstore.sources.all"
    
    private var dataSource: UICollectionViewDiffableDataSource<String, Item>!
    private var sourcesController: NSFetchedResultsController<Source>!
    private var appsController: NSFetchedResultsController<StoreApp>!
    
    private var expandedSections: Set<String> = [SourcesViewController.allSourcesSectionID]
    private var currentSectionIDs: [String] = []
    private var searchText: String = ""
    private var pendingReload = false
    
    private var sourceCount = 0
    
    private var placeholderLabel: UILabel!
    private var searchController: UISearchController!

    private var _viewDidAppear = false
    private weak var _installingApp: StoreApp?
    
    override func viewDidLoad()
    {
        super.viewDidLoad()
        
        self.title = NSLocalizedString("Sources", comment: "")
        
        self.collectionView.collectionViewLayout = self.makeLayout()
        self.navigationController?.view.tintColor = .altPrimary
        
        self.collectionView.allowsSelectionDuringEditing = false
        self.collectionView.backgroundColor = .altBackground
        self.collectionView.alwaysBounceVertical = true
        
        let refreshControl = UIRefreshControl(frame: .zero, primaryAction: UIAction { [weak self] _ in
            self?.updateSources()
        })
        self.collectionView.refreshControl = refreshControl
        
        self.placeholderLabel = UILabel()
        self.placeholderLabel.translatesAutoresizingMaskIntoConstraints = false
        self.placeholderLabel.text = NSLocalizedString("Add a source to see apps here.", comment: "")
        self.placeholderLabel.textColor = .secondaryLabel
        self.placeholderLabel.font = UIFont.preferredFont(forTextStyle: .title3)
        self.placeholderLabel.textAlignment = .center
        self.placeholderLabel.numberOfLines = 0
        
        let backgroundView = UIView(frame: .zero)
        backgroundView.backgroundColor = .altBackground
        backgroundView.addSubview(self.placeholderLabel)
        self.collectionView.backgroundView = backgroundView
        NSLayoutConstraint.activate([
            self.placeholderLabel.centerXAnchor.constraint(equalTo: backgroundView.centerXAnchor),
            self.placeholderLabel.centerYAnchor.constraint(equalTo: backgroundView.centerYAnchor),
            self.placeholderLabel.leadingAnchor.constraint(greaterThanOrEqualTo: backgroundView.leadingAnchor, constant: 30),
            self.placeholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: backgroundView.trailingAnchor, constant: -30),
        ])
        
        self.searchController = UISearchController(searchResultsController: nil)
        self.searchController.obscuresBackgroundDuringPresentation = false
        self.searchController.searchResultsUpdater = self
        self.searchController.searchBar.placeholder = NSLocalizedString("Search Apps", comment: "")
        self.navigationItem.searchController = self.searchController
        self.navigationItem.hidesSearchBarWhenScrolling = true
        self.definesPresentationContext = true

        self.navigationItem.rightBarButtonItem = self.editButtonItem
        
        self.prepareDataSource()
        self.prepareControllers()
        
        NotificationCenter.default.addObserver(self, selector: #selector(SourcesViewController.showInstallingAppToastView(_:)), name: AppManager.willInstallAppFromNewSourceNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(SourcesViewController.appManagerDidChange(_:)), name: AppManager.didFetchSourceNotification, object: nil)
        
        self.reload()
    }
    
    override func viewDidAppear(_ animated: Bool)
    {
        super.viewDidAppear(animated)
        
        self._viewDidAppear = true
        self.handleAddSourceDeepLink()
    }
    
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator)
    {
        super.viewWillTransition(to: size, with: coordinator)
        
        // Keep the grid in sync with the sidebar/tab-bar toggle and Slide Over/Stage Manager resizes,
        // which change our width without a full rotation - animate the relayout so rows don't "pop".
        coordinator.animate(alongsideTransition: { _ in
            self.collectionView.collectionViewLayout.invalidateLayout()
            self.view.layoutIfNeeded()
        })
    }
}

// MARK: - Setup

private extension SourcesViewController
{
    func makeLayout() -> UICollectionViewLayout
    {
        return UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            var configuration = UICollectionLayoutListConfiguration(appearance: .grouped)
            configuration.showsSeparators = false
            configuration.backgroundColor = .clear
            
            configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
                guard let self, let item = self.dataSource?.itemIdentifier(for: indexPath),
                      case .sourceHeader(let objectID) = item,
                      let source = try? DatabaseManager.shared.viewContext.existingObject(with: objectID) as? Source
                else { return nil }
                
                var actions: [UIContextualAction] = []
                
                if source.identifier != Source.altStoreIdentifier
                {
                    // Prevent users from removing AltStore source.
                    let removeAction = UIContextualAction(style: .destructive, title: NSLocalizedString("Remove", comment: "")) { _, _, completion in
                        self.remove(source, completionHandler: completion)
                    }
                    removeAction.image = UIImage(systemName: "trash.fill")
                    actions.append(removeAction)
                }
                
                if let error = source.error
                {
                    let viewErrorAction = UIContextualAction(style: .normal, title: NSLocalizedString("View Error", comment: "")) { _, _, completion in
                        self.present(error)
                        completion(true)
                    }
                    viewErrorAction.backgroundColor = .systemYellow
                    viewErrorAction.image = UIImage(systemName: "exclamationmark.circle.fill")
                    actions.append(viewErrorAction)
                }
                
                let config = UISwipeActionsConfiguration(actions: actions)
                config.performsFirstActionWithFullSwipe = false
                return config
            }
            
            let section = NSCollectionLayoutSection.list(using: configuration, layoutEnvironment: environment)
            
            if environment.traitCollection.horizontalSizeClass == .regular
            {
                // iPad: keep rows in a comfortable, centered column instead of stretching edge to edge.
                section.contentInsetsReference = .readableContent
            }
            
            return section
        }
    }
    
    func prepareDataSource()
    {
        let allSourcesRegistration = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, indexPath, item in
            guard let self else { return }
            
            var content = UIListContentConfiguration.valueCell()
            content.text = NSLocalizedString("All Sources", comment: "")
            content.textProperties.font = UIFont.preferredFont(forTextStyle: .headline)
            content.secondaryText = self.appCountText(for: self.allApps.count)
            content.image = UIImage(systemName: "square.stack.3d.up.fill")
            content.imageProperties.tintColor = .altPrimary
            cell.contentConfiguration = content
            cell.accessories = [.outlineDisclosure(options: .init(style: .header))]
            
            var background = UIBackgroundConfiguration.listGroupedCell()
            background.backgroundColor = .clear
            cell.backgroundConfiguration = background
        }
        
        let sourceRegistration = UICollectionView.CellRegistration<AppBannerCollectionViewCell, Item> { [weak self] cell, indexPath, item in
            guard let self, case .sourceHeader(let objectID) = item,
                  let source = try? DatabaseManager.shared.viewContext.existingObject(with: objectID) as? Source else { return }
            self.configure(sourceCell: cell, for: source)
        }
        
        let appRegistration = UICollectionView.CellRegistration<AppBannerCollectionViewCell, Item> { [weak self] cell, indexPath, item in
            guard let self, case .app(let sectionID, let objectID) = item,
                  let app = try? DatabaseManager.shared.viewContext.existingObject(with: objectID) as? StoreApp else { return }
            self.configure(appCell: cell, for: app, showSourceIcon: sectionID == Self.allSourcesSectionID)
        }
        
        self.dataSource = UICollectionViewDiffableDataSource<String, Item>(collectionView: self.collectionView) { collectionView, indexPath, item in
            switch item
            {
            case .allSourcesHeader: return collectionView.dequeueConfiguredReusableCell(using: allSourcesRegistration, for: indexPath, item: item)
            case .sourceHeader: return collectionView.dequeueConfiguredReusableCell(using: sourceRegistration, for: indexPath, item: item)
            case .app: return collectionView.dequeueConfiguredReusableCell(using: appRegistration, for: indexPath, item: item)
            }
        }
        
        self.dataSource.sectionSnapshotHandlers.willExpandItem = { [weak self] item in
            guard let self, let sectionID = self.sectionID(containing: item) else { return }
            self.expandedSections.insert(sectionID)
        }
        self.dataSource.sectionSnapshotHandlers.willCollapseItem = { [weak self] item in
            guard let self, let sectionID = self.sectionID(containing: item) else { return }
            self.expandedSections.remove(sectionID)
        }
    }
    
    func prepareControllers()
    {
        let sourceRequest = Source.fetchRequest() as NSFetchRequest<Source>
        sourceRequest.returnsObjectsAsFaults = false
        sourceRequest.sortDescriptors = [NSSortDescriptor(keyPath: \Source.name, ascending: true),
                                         // Can't sort by URLs or else app will crash.
                                         NSSortDescriptor(keyPath: \Source.identifier, ascending: true)]
        self.sourcesController = NSFetchedResultsController(fetchRequest: sourceRequest, managedObjectContext: DatabaseManager.shared.viewContext, sectionNameKeyPath: nil, cacheName: nil)
        self.sourcesController.delegate = self
        
        let appRequest = StoreApp.fetchRequest() as NSFetchRequest<StoreApp>
        appRequest.returnsObjectsAsFaults = false
        appRequest.predicate = StoreApp.visibleAppsPredicate
        appRequest.sortDescriptors = [NSSortDescriptor(keyPath: \StoreApp.name, ascending: true),
                                      NSSortDescriptor(keyPath: \StoreApp.bundleIdentifier, ascending: true),
                                      NSSortDescriptor(keyPath: \StoreApp.sourceIdentifier, ascending: true)]
        self.appsController = NSFetchedResultsController(fetchRequest: appRequest, managedObjectContext: DatabaseManager.shared.viewContext, sectionNameKeyPath: nil, cacheName: nil)
        self.appsController.delegate = self
        
        try? self.sourcesController.performFetch()
        try? self.appsController.performFetch()
    }
    
    func sectionID(containing item: Item) -> String?
    {
        switch item
        {
        case .allSourcesHeader: return Self.allSourcesSectionID
        case .sourceHeader(let objectID):
            guard let source = try? DatabaseManager.shared.viewContext.existingObject(with: objectID) as? Source else { return nil }
            return source.identifier
        case .app(let section, _): return section
        }
    }
    
    var allApps: [StoreApp] { self.filteredApps(self.appsController?.fetchedObjects ?? []) }
    
    func filteredApps(_ apps: [StoreApp]) -> [StoreApp]
    {
        let query = self.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return apps }
        
        return apps.filter { app in
            [app.name, app.subtitle, app.developerName, app.bundleIdentifier].contains { ($0 ?? "").localizedCaseInsensitiveContains(query) }
        }
    }
    
    func appCountText(for count: Int) -> String
    {
        if #available(iOS 15, *)
        {
            let attributedOutput = AttributedString(localized: "^[\(count) app](inflect: true)")
            return String(attributedOutput.characters)
        }
        
        return "\(count)"
    }
    
    // MARK: Reloading
    
    func reload()
    {
        guard self.isViewLoaded else { return }
        
        let sources = self.sourcesController.fetchedObjects ?? []
        self.sourceCount = sources.count
        
        let apps = self.allApps
        let isSearching = !self.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        
        let appsBySource = Dictionary(grouping: apps, by: { $0.sourceIdentifier ?? "" })
        
        // While searching, only show sources that have matching apps.
        let visibleSources = sources.filter { !isSearching || !(appsBySource[$0.identifier] ?? []).isEmpty }
        
        var sectionIDs = [Self.allSourcesSectionID]
        sectionIDs.append(contentsOf: visibleSources.map { $0.identifier })
        
        if sectionIDs != self.currentSectionIDs
        {
            var snapshot = NSDiffableDataSourceSnapshot<String, Item>()
            snapshot.appendSections(sectionIDs)
            self.dataSource.apply(snapshot, animatingDifferences: false)
            self.currentSectionIDs = sectionIDs
        }
        
        // All Sources
        var allSnapshot = NSDiffableDataSourceSectionSnapshot<Item>()
        allSnapshot.append([.allSourcesHeader])
        allSnapshot.append(apps.map { Item.app(section: Self.allSourcesSectionID, id: $0.objectID) }, to: .allSourcesHeader)
        if isSearching || self.expandedSections.contains(Self.allSourcesSectionID) { allSnapshot.expand([.allSourcesHeader]) }
        self.dataSource.apply(allSnapshot, to: Self.allSourcesSectionID, animatingDifferences: false)
        
        // Each source
        for source in visibleSources
        {
            let header = Item.sourceHeader(source.objectID)
            var snapshot = NSDiffableDataSourceSectionSnapshot<Item>()
            snapshot.append([header])
            snapshot.append((appsBySource[source.identifier] ?? []).map { Item.app(section: source.identifier, id: $0.objectID) }, to: header)
            if isSearching || self.expandedSections.contains(source.identifier) { snapshot.expand([header]) }
            self.dataSource.apply(snapshot, to: source.identifier, animatingDifferences: false)
        }
        
        // Refresh contents of visible rows (app counts, install buttons, last updated…).
        var mainSnapshot = self.dataSource.snapshot()
        mainSnapshot.reconfigureItems(mainSnapshot.itemIdentifiers)
        self.dataSource.apply(mainSnapshot, animatingDifferences: false)
        
        self.update()
    }
    
    func update()
    {
        self.placeholderLabel.isHidden = self.sourceCount > 0
        
        if self.sourceCount < 2
        {
            self.setEditing(false, animated: true)
            self.editButtonItem.isEnabled = false
        }
        else
        {
            self.editButtonItem.isEnabled = true
        }
    }
    
    @objc func appManagerDidChange(_ notification: Notification)
    {
        self.scheduleReload()
    }
    
    func scheduleReload()
    {
        guard !self.pendingReload else { return }
        self.pendingReload = true
        
        DispatchQueue.main.async {
            self.pendingReload = false
            self.reload()
        }
    }
    
    func updateSources()
    {
        AppManager.shared.updateAllSources { result in
            DispatchQueue.main.async {
                self.collectionView.refreshControl?.endRefreshing()
                
                guard case .failure(let error) = result, self.sourceCount > 0 else { return }
                
                let toastView = ToastView(error: error)
                toastView.show(in: self)
            }
        }
    }
    
    // MARK: Cell configuration
    
    func configure(sourceCell cell: AppBannerCollectionViewCell, for source: Source)
    {
        cell.layoutMargins.top = 5
        cell.layoutMargins.bottom = 5
        cell.layoutMargins.left = self.view.layoutMargins.left
        cell.layoutMargins.right = self.view.layoutMargins.right
        
        cell.bannerView.configure(for: source)
        
        cell.bannerView.iconImageView.image = nil
        cell.bannerView.iconImageView.isIndicatingActivity = true
        
        let appCount = (self.appsController.fetchedObjects ?? []).filter { $0.sourceIdentifier == source.identifier }.count
        
        UIView.performWithoutAnimation {
            cell.bannerView.button.removeTarget(nil, action: nil, for: .primaryActionTriggered)
            cell.bannerView.button.removeAction(identifiedBy: .showDetails, for: .primaryActionTriggered)
            cell.bannerView.button.removeAction(identifiedBy: .showError, for: .primaryActionTriggered)
            
            if let error = source.error
            {
                let image = UIImage(systemName: "exclamationmark")?.withTintColor(.white, renderingMode: .alwaysOriginal)
                
                cell.bannerView.button.setImage(image, for: .normal)
                cell.bannerView.button.setTitle(nil, for: .normal)
                cell.bannerView.button.tintColor = .systemYellow.withAlphaComponent(0.75)
                
                cell.bannerView.button.addAction(UIAction(identifier: .showError) { [weak self] _ in
                    self?.present(error)
                }, for: .primaryActionTriggered)
            }
            else
            {
                cell.bannerView.button.setImage(nil, for: .normal)
                cell.bannerView.button.setTitle(appCount.description, for: .normal)
                cell.bannerView.button.tintColor = .white.withAlphaComponent(0.2)
                
                cell.bannerView.button.addAction(UIAction(identifier: .showDetails) { [weak self] _ in
                    self?.showSourceDetails(for: source)
                }, for: .primaryActionTriggered)
            }
        }
        
        let dateText: String
        if let lastUpdatedDate = source.lastUpdatedDate
        {
            dateText = Date().relativeDateString(since: lastUpdatedDate, dateFormatter: Date.shortDateFormatter)
        }
        else
        {
            dateText = NSLocalizedString("Never", comment: "")
        }
        
        let text = String(format: NSLocalizedString("Last Updated: %@", comment: ""), dateText)
        cell.bannerView.subtitleLabel.text = text
        cell.bannerView.subtitleLabel.numberOfLines = 1
        
        cell.bannerView.accessibilityLabel = source.name + "\n" + text + ".\n" + self.appCountText(for: appCount)
        
        var accessories: [UICellAccessory] = []
        if source.identifier != Source.altStoreIdentifier
        {
            accessories.append(.delete(displayed: .whenEditing))
        }
        accessories.append(.outlineDisclosure(options: .init(style: .cell)))
        cell.accessories = accessories
        
        cell.bannerView.accessibilityTraits.remove(.button)
        
        if let imageURL = source.effectiveIconURL
        {
            ImagePipeline.shared.loadImage(with: imageURL, progress: nil) { result in
                DispatchQueue.main.async {
                    cell.bannerView.iconImageView.isIndicatingActivity = false
                    
                    switch result
                    {
                    case .success(let response):
                        cell.bannerView.iconImageView.image = response.image
                        cell.bannerView.iconImageView.backgroundColor = .clear
                    case .failure(let error):
                        Logger.main.error("Failed to load source icon: \(error.localizedDescription, privacy: .public)")
                    }
                }
            }
        }
        else
        {
            cell.bannerView.iconImageView.isIndicatingActivity = false
        }
        
        // Make sure refresh button is correct size.
        cell.layoutIfNeeded()
    }
    
    func configure(appCell cell: AppBannerCollectionViewCell, for app: StoreApp, showSourceIcon: Bool)
    {
        cell.layoutMargins.top = 4
        cell.layoutMargins.bottom = 4
        cell.layoutMargins.left = self.view.layoutMargins.left + 20 // Indent apps under their header.
        cell.layoutMargins.right = self.view.layoutMargins.right
        
        cell.accessories = []
        
        cell.bannerView.button.isIndicatingActivity = false
        cell.bannerView.configure(for: app, showSourceIcon: showSourceIcon)
        cell.bannerView.tintColor = app.tintColor ?? .altPrimary
        
        cell.bannerView.iconImageView.image = nil
        cell.bannerView.iconImageView.isIndicatingActivity = true
        
        cell.bannerView.button.removeTarget(nil, action: nil, for: .primaryActionTriggered)
        cell.bannerView.button.addTarget(self, action: #selector(SourcesViewController.performAppAction(_:)), for: .primaryActionTriggered)
        cell.bannerView.button.activityIndicatorView.style = .medium
        cell.bannerView.button.activityIndicatorView.color = .white
        
        ImagePipeline.shared.loadImage(with: app.iconURL, progress: nil) { result in
            DispatchQueue.main.async {
                cell.bannerView.iconImageView.isIndicatingActivity = false
                
                switch result
                {
                case .success(let response):
                    cell.bannerView.iconImageView.image = response.image
                    cell.bannerView.iconImageView.backgroundColor = .clear
                case .failure(let error):
                    Logger.main.debug("Failed to load app icon. \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        
        cell.layoutIfNeeded()
    }
    
    @IBSegueAction
    func makeSourceDetailViewController(_ coder: NSCoder, sender: Any?) -> UIViewController?
    {
        guard let source = sender as? Source else { return nil }
        
        let sourceDetailViewController = SourceDetailViewController(source: source, coder: coder)
        return sourceDetailViewController
    }
    
    @IBAction
    func unwindFromAddSource(_ segue: UIStoryboardSegue)
    {
    }
}

// MARK: - Apps

private extension SourcesViewController
{
    @objc func performAppAction(_ sender: PillButton)
    {
        let point = self.collectionView.convert(sender.center, from: sender.superview)
        guard let indexPath = self.collectionView.indexPathForItem(at: point),
              let item = self.dataSource.itemIdentifier(for: indexPath),
              case .app(_, let objectID) = item,
              let app = try? DatabaseManager.shared.viewContext.existingObject(with: objectID) as? StoreApp
        else { return }
        
        if let installedApp = app.installedApp, !installedApp.isUpdateAvailable
        {
            UIApplication.shared.open(installedApp.openAppURL)
        }
        else
        {
            self.install(app, item: item)
        }
    }
    
    func install(_ app: StoreApp, item: Item)
    {
        let previousProgress = AppManager.shared.installationProgress(for: app)
        guard previousProgress == nil else {
            previousProgress?.cancel()
            return
        }
        
        Task<Void, Never>(priority: .userInitiated) { @MainActor in
            if let installedApp = app.installedApp, installedApp.isUpdateAvailable
            {
                AppManager.shared.update(installedApp, presentingViewController: self, completionHandler: finish(_:))
            }
            else
            {
                await AppManager.shared.installAsync(app, presentingViewController: self, completionHandler: finish(_:))
            }
            
            self.reconfigure(app)
        }
        
        @MainActor
        func finish(_ result: Result<InstalledApp, Error>)
        {
            DispatchQueue.main.async {
                switch result
                {
                case .failure(OperationError.cancelled): break // Ignore
                case .failure(let error):
                    let toastView = ToastView(error: error)
                    toastView.opensErrorLog = true
                    toastView.show(in: self)
                    
                case .success: print("Installed app:", app.bundleIdentifier)
                }
                
                self.reconfigure(app)
            }
        }
    }
    
    /// Refreshes every row (All Sources + the app's own source) showing this app.
    func reconfigure(_ app: StoreApp)
    {
        var snapshot = self.dataSource.snapshot()
        let items = snapshot.itemIdentifiers.filter {
            if case .app(_, let id) = $0 { return id == app.objectID }
            return false
        }
        guard !items.isEmpty else { return }
        
        snapshot.reconfigureItems(items)
        UIView.performWithoutAnimation {
            self.dataSource.apply(snapshot, animatingDifferences: false)
        }
    }
}

private extension SourcesViewController
{
    func handleAddSourceDeepLink()
    {
        guard let url = self.deepLinkSourceURL, self._viewDidAppear else { return }
        
        // Only handle deep link once.
        self.deepLinkSourceURL = nil
        
        self.navigationItem.leftBarButtonItem?.isIndicatingActivity = true
        
        func finish(_ result: Result<Void, Error>)
        {
            DispatchQueue.main.async {
                switch result
                {
                case .success: break
                case .failure(OperationError.cancelled): break
                    
                case .failure(var error as SourceError):
                    let title = String(format: NSLocalizedString("“%@” could not be added to AltStore.", comment: ""), error.$source.name)
                    error.errorTitle = title
                    self.present(error)
                    
                case .failure(let error as NSError):
                    self.present(error.withLocalizedTitle(NSLocalizedString("Unable to Add Source", comment: "")))
                }
                
                self.navigationItem.leftBarButtonItem?.isIndicatingActivity = false
            }
        }
        
        let context = DatabaseManager.shared.persistentContainer.newBackgroundSavingViewContext()
        AppManager.shared.fetchSource(sourceURL: url, managedObjectContext: context) { (result) in
            do
            {
                // Use @Managed before calling perform() to keep
                // strong reference to source.managedObjectContext.
                @Managed var source = try result.get()
                
                DispatchQueue.main.async {
                    self.showSourceDetails(for: source)
                }
                
                finish(.success(()))
            }
            catch
            {
                finish(.failure(error))
            }
        }
    }

    func present(_ error: Error)
    {
        if let transitionCoordinator = self.transitionCoordinator
        {
            transitionCoordinator.animate(alongsideTransition: nil) { _ in
                self.present(error)
            }
            
            return
        }
        
        let nsError = error as NSError
        let title = nsError.localizedTitle // OK if nil.
        let message = [nsError.localizedDescription, nsError.localizedDebugDescription, nsError.localizedRecoverySuggestion].compactMap { $0 }.joined(separator: "\n\n")
        
        let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alertController.addAction(.ok)
        self.present(alertController, animated: true, completion: nil)
    }
    
    func remove(_ source: Source, completionHandler: ((Bool) -> Void)? = nil)
    {
        Task<Void, Never> {
            do
            {
                try await AppManager.shared.remove(source, presentingViewController: self)
                
                completionHandler?(true)
            }
            catch is CancellationError
            {
                completionHandler?(false)
            }
            catch
            {
                completionHandler?(false)
                
                self.present(error)
            }
        }
    }
    
    func showSourceDetails(for source: Source)
    {
        var source = source
        
        if source.managedObjectContext != DatabaseManager.shared.viewContext
        {
            let predicate = NSPredicate(format: "%K == %@", #keyPath(Source.identifier), source.identifier)
            if let localSource = Source.first(satisfying: predicate, in: DatabaseManager.shared.viewContext)
            {
                // This source exists locally, so show local version instead.
                source = localSource
            }
        }
        
        self.performSegue(withIdentifier: "showSourceDetails", sender: source)
    }
    
    @objc func showInstallingAppToastView(_ notification: Notification)
    {
        guard let app = notification.object as? StoreApp else { return }
        self._installingApp = app
        
        let text = String(format: NSLocalizedString("Downloading %@…", comment: ""), app.name)        
        let toastView = ToastView(text: text, detailText: NSLocalizedString("Tap to view progress.", comment: ""))
        toastView.addTarget(self, action: #selector(SourcesViewController.showAppDetail), for: .touchUpInside)
        toastView.show(in: self)
    }
    
    @objc func showAppDetail()
    {
        guard let app = self._installingApp else { return }
        self._installingApp = nil
        
        let appViewController = AppViewController.makeAppViewController(app: app)
        self.navigationController?.pushViewController(appViewController, animated: true)
    }
}

// MARK: - Selection & menus

extension SourcesViewController
{
    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath)
    {
        self.collectionView.deselectItem(at: indexPath, animated: true)
        
        guard let item = self.dataSource.itemIdentifier(for: indexPath) else { return }
        
        switch item
        {
        case .allSourcesHeader, .sourceHeader:
            // Tapping a header minimises / expands its section.
            guard let sectionID = self.sectionID(containing: item) else { return }
            
            var snapshot = self.dataSource.snapshot(for: sectionID)
            if snapshot.isExpanded(item) { snapshot.collapse([item]) } else { snapshot.expand([item]) }
            self.dataSource.apply(snapshot, to: sectionID, animatingDifferences: true)
            
        case .app(_, let objectID):
            guard let app = try? DatabaseManager.shared.viewContext.existingObject(with: objectID) as? StoreApp else { return }
            let appViewController = AppViewController.makeAppViewController(app: app)
            self.navigationController?.pushViewController(appViewController, animated: true)
        }
    }
    
    override func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration?
    {
        guard let item = self.dataSource.itemIdentifier(for: indexPath), case .sourceHeader(let objectID) = item,
              let source = try? DatabaseManager.shared.viewContext.existingObject(with: objectID) as? Source else { return nil }
        
        return UIContextMenuConfiguration(identifier: indexPath as NSIndexPath, previewProvider: nil) { _ in
            var actions = [UIAction(title: NSLocalizedString("View Source Details", comment: ""), image: UIImage(systemName: "info.circle")) { _ in
                self.showSourceDetails(for: source)
            }]
            
            if source.identifier != Source.altStoreIdentifier
            {
                actions.append(UIAction(title: NSLocalizedString("Remove Source", comment: ""), image: UIImage(systemName: "trash"), attributes: .destructive) { _ in
                    self.remove(source)
                })
            }
            
            return UIMenu(children: actions)
        }
    }
}

extension SourcesViewController: UISearchResultsUpdating
{
    func updateSearchResults(for searchController: UISearchController)
    {
        self.searchText = searchController.searchBar.text ?? ""
        self.reload()
    }
}

extension SourcesViewController: NSFetchedResultsControllerDelegate
{
    func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>)
    {
        self.scheduleReload()
    }
}

@available(iOS 17, *)
#Preview(traits: .portrait) {
    DatabaseManager.shared.startForPreview()
    
    let storyboard = UIStoryboard(name: "Sources", bundle: nil)
    let sourcesViewController = storyboard.instantiateInitialViewController()!
    
    let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
    context.performAndWait {
        _ = Source.make(name: "OatmealDome's AltStore Source",
                        identifier: "me.oatmealdome.altstore",
                        sourceURL: URL(string: "https://altstore.oatmealdome.me")!,
                        context: context)
        
        _ = Source.make(name: "UTM Repository",
                        identifier: "com.utmapp.repos.UTM",
                        sourceURL: URL(string: "https://alt.getutm.app")!,
                        context: context)
        
        _ = Source.make(name: "Flyinghead",
                        identifier: "com.flyinghead.source",
                        sourceURL: URL(string: "https://flyinghead.github.io/flycast-builds/altstore.json")!,
                        context: context)
        
        _ = Source.make(name: "Provenance",
                        identifier: "org.provenance-emu.AltStore",
                        sourceURL: URL(string: "https://provenance-emu.com/apps.json")!,
                        context: context)
        
        _ = Source.make(name: "PojavLauncher Repository",
                        identifier: "dev.crystall1ne.repos.PojavLauncher",
                        sourceURL: URL(string: "http://alt.crystall1ne.dev")!,
                        context: context)
        
        try! context.save()
    }
    
    AppManager.shared.fetchSources { result in
        do
        {
            let (_, context) = try result.get()
            try context.save()
        }
        catch
        {
            print("Preview failed to fetch sources:", error)
        }
    }
    
    return sourcesViewController
}
