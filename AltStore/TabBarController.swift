//
//  TabBarController.swift
//  AltStore
//
//  Created by Riley Testut on 9/19/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import UIKit
import AltStoreCore

extension TabBarController
{
    private enum Tab: Int, CaseIterable
    {
        case sources
        case updates   // Added in code; Browse was merged into Sources. (News was removed.)
        case myApps
        case settings
    }
}

class TabBarController: UITabBarController
{
    private var initialSegue: (identifier: String, sender: Any?)?
    
    private var _viewDidAppear = false
    
    private var sourcesViewController: SourcesViewController!
    private var updatesViewController: UpdatesViewController!
    
    required init?(coder aDecoder: NSCoder)
    {
        super.init(coder: aDecoder)
        
        NotificationCenter.default.addObserver(self, selector: #selector(TabBarController.openPatreonSettings(_:)), name: AppDelegate.openPatreonSettingsDeepLinkNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(TabBarController.importApp(_:)), name: AppDelegate.importAppDeepLinkNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(TabBarController.presentSources(_:)), name: AppDelegate.addSourceDeepLinkNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(TabBarController.openErrorLog(_:)), name: ToastView.openErrorLogNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(TabBarController.openBrowseTab(_:)), name: AppDelegate.searchDeepLinkNotification, object: nil) // Search now lives in the Sources tab.
        NotificationCenter.default.addObserver(self, selector: #selector(TabBarController.viewApp(_:)), name: AppDelegate.viewAppDeepLinkNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(TabBarController.exportCertificate(_:)), name: AppDelegate.exportCertificateDeepLinkNotification, object: nil)
    }
    
    override func viewDidLoad() 
    {
        super.viewDidLoad()
        
        // Updates tab is created in code, right after Sources.
        let updatesViewController = UpdatesViewController()
        let updatesNavigationController = ForwardingNavigationController(rootViewController: updatesViewController)
        updatesNavigationController.navigationBar.prefersLargeTitles = true
        updatesNavigationController.tabBarItem = UITabBarItem(title: NSLocalizedString("Updates", comment: ""), image: UIImage(systemName: "arrow.down.circle"), selectedImage: UIImage(systemName: "arrow.down.circle.fill"))
        updatesNavigationController.tabBarItem.badgeColor = .altPrimary
        self.updatesViewController = updatesViewController
        
        var controllers = self.viewControllers ?? []
        controllers.insert(updatesNavigationController, at: min(Tab.updates.rawValue, controllers.count))
        self.setViewControllers(controllers, animated: false)
        
        // Load now so the Updates badge is correct before the tab is ever opened.
        updatesViewController.loadViewIfNeeded()
        
        let sourcesNavigationController = self.viewControllers![Tab.sources.rawValue] as! UINavigationController
        self.sourcesViewController = sourcesNavigationController.viewControllers.first as? SourcesViewController
        
        if UIDevice.current.userInterfaceIdiom == .pad, #available(iOS 18, *)
        {
            // Native iPad navigation: tabs become a sidebar tiled beside the content. iPhone keeps the bottom tab bar.
            self.mode = .tabSidebar
            self.sidebar.isHidden = false
        }
        
        // My Apps is the default tab on launch.
        self.select(.myApps)
    }
    
    /// Selects a tab. With the iPad sidebar active, tabs must be looked up by identity, not index.
    private func select(_ tab: Tab)
    {
        guard let viewControllers = self.viewControllers, viewControllers.indices.contains(tab.rawValue) else { return }
        let viewController = viewControllers[tab.rawValue]
        
        if #available(iOS 18, *), let uiTab = self.tabs.first(where: { $0.viewController === viewController })
        {
            self.selectedTab = uiTab
        }
        else
        {
            self.selectedIndex = tab.rawValue
        }
    }
    
    override func viewDidAppear(_ animated: Bool)
    {
        super.viewDidAppear(animated)
        
        _viewDidAppear = true
        
        if let (identifier, sender) = self.initialSegue
        {
            self.initialSegue = nil
            self.performSegue(withIdentifier: identifier, sender: sender)
        }
        else if let patchedApps = UserDefaults.standard.patchedApps, !patchedApps.isEmpty
        {
            // Check if we need to finish installing untethered jailbreak.
            let activeApps = InstalledApp.fetchActiveApps(in: DatabaseManager.shared.viewContext)
            guard let patchedApp = activeApps.first(where: { patchedApps.contains($0.bundleIdentifier) }) else { return }
            
            self.performSegue(withIdentifier: "finishJailbreak", sender: patchedApp)
        }
        
        self.promptForPairingFileIfNeeded()
    }
    
    /// First launch without a pairing file: bring up the Pairing File screen (instead of the old “Connect to AltServer” setup).
    private func promptForPairingFileIfNeeded()
    {
        guard self.presentedViewController == nil else { return }
        guard !PairingFileManager.shared.refresh().isPresent else { return }
        guard !UserDefaults.standard.bool(forKey: "didPromptForPairingFile") else { return }
        
        UserDefaults.standard.set(true, forKey: "didPromptForPairingFile")
        
        let pairingViewController = PairingFileViewController()
        let navigationController = UINavigationController(rootViewController: pairingViewController)
        navigationController.modalPresentationStyle = .formSheet
        self.present(navigationController, animated: true)
    }
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?)
    {
        guard let identifier = segue.identifier else { return }
        
        switch identifier
        {
        case "finishJailbreak":
            guard let installedApp = sender as? InstalledApp else { return }
            
            let navigationController = segue.destination as! UINavigationController
            
            let patchViewController = navigationController.viewControllers.first as! PatchViewController
            patchViewController.installedApp = installedApp
            patchViewController.completionHandler = { [weak self] _ in
                self?.dismiss(animated: true, completion: nil)
            }
            
        default: break
        }
    }
    
    override func performSegue(withIdentifier identifier: String, sender: Any?)
    {
        guard _viewDidAppear else {
            self.initialSegue = (identifier, sender)
            return
        }
        
        super.performSegue(withIdentifier: identifier, sender: sender)
    }
}

extension TabBarController
{
    @objc func presentSources(_ sender: Any)
    {
        if let presentedViewController = self.presentedViewController
        {
            presentedViewController.dismiss(animated: true) {
                self.presentSources(sender)
            }
            
            return
        }
                
        if let notification = (sender as? Notification), let sourceURL = notification.userInfo?[AppDelegate.addSourceDeepLinkURLKey] as? URL
        {
            self.loadViewIfNeeded() // Initialize sourcesViewController
            self.sourcesViewController?.deepLinkSourceURL = sourceURL
        }
        
        self.select(.sources)
    }
}

private extension TabBarController
{
    @objc func openPatreonSettings(_ notification: Notification)
    {
        self.select(.settings)
    }
    
    @objc func importApp(_ notification: Notification)
    {
        self.select(.myApps)
    }
    
    @objc func openErrorLog(_ notification: Notification)
    {
        self.select(.settings)
    }
    
    @objc func openBrowseTab(_ notification: Notification)
    {
        self.select(.sources)
        
        if let query = notification.userInfo?[AppDelegate.searchDeepLinkQueryKey] as? String
        {
            self.sourcesViewController.loadViewIfNeeded()
            self.sourcesViewController.navigationController?.popToRootViewController(animated: false)
            
            guard let searchController = self.sourcesViewController.navigationItem.searchController else { return }
            searchController.searchBar.text = query
            
            // Slight delay to ensure the search controller is actually presented (YOLO).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                searchController.isActive = true
                searchController.searchResultsUpdater?.updateSearchResults(for: searchController)
            }
        }
    }
    
    @objc func viewApp(_ notification: Notification)
    {
        self.select(.sources)
        
        if let presentedViewController = self.presentedViewController
        {
            presentedViewController.dismiss(animated: true) {
                self.viewApp(notification)
            }
            
            return
        }
        
        guard let storeApp = notification.userInfo?[AppDelegate.viewAppDeepLinkStoreAppKey] as? StoreApp else { return }
        
        let appViewController = AppViewController.makeAppViewController(app: storeApp)
        self.sourcesViewController.navigationController?.pushViewController(appViewController, animated: true)
    }
    
    @objc func exportCertificate(_ notification: Notification)
    {
        self.select(.settings)
    }
}
