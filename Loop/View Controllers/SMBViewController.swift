//
//  SMBViewController.swift
//  LoopKitUI
//
//  Created by Anna Quinlan on 11/13/19.
//  Copyright © 2019 LoopKit Authors. All rights reserved.
//

import UIKit
import HealthKit
import LoopKit
import LoopKitUI


public protocol SMBViewControllerDelegate: AnyObject {
    func SMBViewControllerDidUpdatePresets(_ vc: SMBViewController)
}

public final class SMBViewController: UITableViewController {
    
    public weak var delegate: SMBViewControllerDelegate?
    
    public var enableSMBWithCOB: Bool {
        didSet {
            delegate?.SMBViewControllerDidUpdatePresets(self)
        }
    }
    
    public var enableSMBWithCarbs: Bool {
        didSet {
            delegate?.SMBViewControllerDidUpdatePresets(self)
        }
    }
    public var alwaysEnableSMB: Bool {
        didSet {
            delegate?.SMBViewControllerDidUpdatePresets(self)
        }
    }
    
    fileprivate enum Section: Int, CaseIterable {
        case cob
        case carbs
        case alwaysEnable
    }
    
    private var sections: [Section] = Section.allCases
    
    init(enableSMBWithCOB: Bool, enableSMBAfterCarbs: Bool, enableSMBAlways: Bool) {
        self.enableSMBWithCOB = enableSMBWithCOB
        self.enableSMBWithCarbs = enableSMBAfterCarbs
        self.alwaysEnableSMB = enableSMBAlways
        
        super.init(style: .grouped)
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    public override func viewDidLoad() {
        super.viewDidLoad()

        title = NSLocalizedString("Super-Microbolus Settings", comment: "The title text for the super-microbolus settings screen")
        
        tableView.cellLayoutMarginsFollowReadableWidth = true
        tableView.register(SwitchTableViewCell.self, forCellReuseIdentifier: SwitchTableViewCell.className)

    }
    
    public override func numberOfSections(in tableView: UITableView) -> Int {
        return sections.count
    }
    
    public override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return 1
    }
    
    public override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch sections[indexPath.section] {
        case .cob:
            let switchCell = tableView.dequeueReusableCell(withIdentifier: SwitchTableViewCell.className, for: indexPath) as! SwitchTableViewCell
            
            switchCell.switch?.isOn = enableSMBWithCOB
            switchCell.textLabel?.text = NSLocalizedString("Enable with COB", comment: "The title text for the supermicrobolus setting with carbs on board")
            
            switchCell.switch?.addTarget(self, action: #selector(enableSMBWithCOBChanged(_:)), for: .valueChanged)
            
            return switchCell
            
        case .carbs:
            let switchCell = tableView.dequeueReusableCell(withIdentifier: SwitchTableViewCell.className, for: indexPath) as! SwitchTableViewCell
            
            switchCell.switch?.isOn = enableSMBWithCarbs
            switchCell.textLabel?.text = NSLocalizedString("Enable with Carbs", comment: "The title text for the supermicrobolus setting after carbs have been consumed")
            
            switchCell.switch?.addTarget(self, action: #selector(enableSMBWithCarbsChanged(_:)), for: .valueChanged)
            
            return switchCell
        case .alwaysEnable:
            let switchCell = tableView.dequeueReusableCell(withIdentifier: SwitchTableViewCell.className, for: indexPath) as! SwitchTableViewCell
            
            switchCell.switch?.isOn = alwaysEnableSMB
            switchCell.textLabel?.text = NSLocalizedString("Always Enable", comment: "The title text for the supermicrobolus setting where supermicroboluses are always allowed")
            
            switchCell.switch?.addTarget(self, action: #selector(alwaysEnableSMBChanged(_:)), for: .valueChanged)
            
            return switchCell
        }
    }
    
    public override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Section(rawValue: section)! {
        case .cob:
            return NSLocalizedString("Enables super-microbolus (SMB) when carbs on board (COB) is a positive value.", comment: "The description shown on the enable supermicrobolus with carbs on board switch.")
        case .carbs:
            return NSLocalizedString("Enables super-microbolus (SMB) for 6 hours after carbs, even with zero carbs on board (COB).", comment: "The description shown on the enable supermicrobolus with carbs switch.")
        case .alwaysEnable:
            return NSLocalizedString("Enables super-microbolus (SMB) to be always on. Please use this setting with caution.", comment: "The description shown on the always enable supermicrobolus switch.")
        }
    }
    
    public override func viewWillDisappear(_ animated: Bool) {
        delegate?.SMBViewControllerDidUpdatePresets(self)
        super.viewWillDisappear(animated)
    }
    
    @objc private func enableSMBWithCOBChanged(_ sender: UISwitch) {
        enableSMBWithCOB = sender.isOn
        // loopDataManager.loop() TODO: would this be desireable behavior?
        
    }
    
    @objc private func enableSMBWithCarbsChanged(_ sender: UISwitch) {
        enableSMBWithCarbs = sender.isOn
        // loopDataManager.loop() TODO: would this be desireable behavior?
        
    }
    
    @objc private func alwaysEnableSMBChanged(_ sender: UISwitch) {
        alwaysEnableSMB = sender.isOn
        // loopDataManager.loop() TODO: would this be desireable behavior?
        
    }
    
}

