//
//  SettingsHeaderFooterView.swift
//  AltStore
//
//  Created by Riley Testut on 8/31/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import UIKit

import Roxas

class SettingsHeaderFooterView: UITableViewHeaderFooterView
{
    @IBOutlet var primaryLabel: UILabel!
    @IBOutlet var secondaryLabel: UILabel!
    @IBOutlet var button: UIButton!
        
    @IBOutlet private var stackView: UIStackView!
    
    override func awakeFromNib()
    {
        super.awakeFromNib()
        
        // Fixed, deterministic margins. Inheriting the table's margins (preservesSuperviewLayoutMargins)
        // picked up the iPad *readable-width* inset on some layout passes but not others, so headers and
        // footers drifted between x≈35, x≈365 (the readable inset) and even the far right. Pinning them
        // keeps every section's text flush left, in line with the row text, at any width.
        self.contentView.preservesSuperviewLayoutMargins = false
        self.contentView.insetsLayoutMarginsFromSafeArea = false
        self.contentView.layoutMargins = UIEdgeInsets(top: 0, left: 35, bottom: 0, right: 35)
        self.primaryLabel.textAlignment = .left
        self.secondaryLabel.textAlignment = .left
        
        self.stackView.translatesAutoresizingMaskIntoConstraints = false
        self.contentView.addSubview(self.stackView)
        
        NSLayoutConstraint.activate([self.stackView.leadingAnchor.constraint(equalTo: self.contentView.layoutMarginsGuide.leadingAnchor),
                                     self.stackView.trailingAnchor.constraint(equalTo: self.contentView.layoutMarginsGuide.trailingAnchor),
                                     self.stackView.topAnchor.constraint(equalTo: self.contentView.layoutMarginsGuide.topAnchor),
                                     self.stackView.bottomAnchor.constraint(equalTo: self.contentView.layoutMarginsGuide.bottomAnchor)])
    }
}
