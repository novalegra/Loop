//
//  BolusViewController.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 3/11/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import UIKit
import LocalAuthentication
import LoopKit
import LoopKitUI
import HealthKit
import LoopCore
import LoopUI


private extension RefreshContext {
    static let all: Set<RefreshContext> = [.glucose, .targets]
}

final class BolusViewController: ChartsTableViewController, IdentifiableClass, UITextFieldDelegate {
    private enum Row: Int {
        case chart = 0
        case carbEntry
        case notice
        case date
        case model
        case recommended
        case entry
    }

    private let maximumDateFutureInterval = TimeInterval(hours: 4)

    override func viewDidLoad() {
        super.viewDidLoad()
        // This gets rid of the empty space at the top.
        tableView.tableHeaderView = UIView(frame: CGRect(x: 0, y: 0, width: tableView.bounds.size.width, height: 0.01))

        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 44
        tableView.register(DateAndDurationTableViewCell.nib(), forCellReuseIdentifier: DateAndDurationTableViewCell.className)

        glucoseChart.glucoseDisplayRange = HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 60)...HKQuantity(unit: .milligramsPerDeciliter, doubleValue: 200)

        notificationObservers += [
            NotificationCenter.default.addObserver(forName: .LoopDataUpdated, object: deviceManager.loopManager, queue: nil) { [weak self] note in
                let context = note.userInfo?[LoopDataManager.LoopUpdateContextKey] as! LoopDataManager.LoopUpdateContext.RawValue
                DispatchQueue.main.async {
                    switch LoopDataManager.LoopUpdateContext(rawValue: context) {
                    case .preferences?:
                        self?.refreshContext.formUnion([.status, .targets])
                    case .glucose?:
                        self?.refreshContext.update(with: .glucose)
                    default:
                        break
                    }

                    self?.reloadData(animated: true)
                }
            }
        ]
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        let spellOutFormatter = NumberFormatter()
        spellOutFormatter.numberStyle = .spellOut

        let amount = bolusRecommendation?.amount ?? 0
        bolusAmountTextField.accessibilityHint = String(format: NSLocalizedString("Recommended Bolus: %@ Units", comment: "Accessibility hint describing recommended bolus units"), spellOutFormatter.string(from: amount) ?? "0")
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        // Reposition footer view if necessary
        if tableView.contentSize.height != lastContentHeight {
            lastContentHeight = tableView.contentSize.height
            tableView.tableFooterView = nil

            let footerSize = footerView.systemLayoutSizeFitting(CGSize(width: tableView.frame.size.width, height: UIView.layoutFittingCompressedSize.height))
            footerView.frame.size = footerSize
            tableView.tableFooterView = footerView
        }
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()

        if !visible {
            refreshContext = RefreshContext.all
        }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        refreshContext.update(with: .size(size))

        super.viewWillTransition(to: size, with: coordinator)
    }
    
    override func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        tableView.endEditing(false)
        tableView.beginUpdates()
        hideDatePickerCells(excluding: indexPath)
        return indexPath
    }
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?) {
        switch segue.destination {
        case let vc as InsulinModelSettingsViewController:
            vc.deviceManager = deviceManager
            vc.insulinModel = enteredBolusInsulinModel ?? deviceManager.loopManager.insulinModelSettings?.model

            if let insulinSensitivitySchedule = deviceManager.loopManager.insulinSensitivitySchedule {
                vc.insulinSensitivitySchedule = insulinSensitivitySchedule
            }

            vc.delegate = self
        default:
            break
        }
        
        super.prepare(for: segue, sender: sender)
        
        bolusAmountTextField.resignFirstResponder()
    }

    // MARK: - State

    enum Configuration {
        case manualCorrection
        case newCarbEntry(NewCarbEntry)
        case updatedCarbEntry(from: StoredCarbEntry, to: NewCarbEntry)
        case logging
    }

    var configuration: Configuration = .manualCorrection {
        didSet {
            switch configuration {
            case .manualCorrection:
                title = NSLocalizedString("Bolus", comment: "Title text for bolus screen (manual correction)")
            case .newCarbEntry, .updatedCarbEntry:
                title = NSLocalizedString("Meal Bolus", comment: "Title text for bolus screen following a carb entry")
            case .logging:
                 title = NSLocalizedString("Log Dose", comment: "Title text for logging a dose")
                isLoggingDose = true
            }
        }
    }
    
    var isLoggingDose: Bool = false

    var doseDate: Date? {
        didSet {
            predictionRecomputation?.cancel()
            recomputePrediction()
        }
    }

    var originalCarbEntry: StoredCarbEntry? {
        switch configuration {
        case .manualCorrection, .logging:
            return nil
        case .newCarbEntry:
            return nil
        case .updatedCarbEntry(from: let entry, to: _):
            return entry
        }
    }

    private var potentialCarbEntry: NewCarbEntry? {
        switch configuration {
        case .manualCorrection, .logging:
            return nil
        case .newCarbEntry(let entry):
            return entry
        case .updatedCarbEntry(from: _, to: let entry):
            return entry
        }
    }

    var selectedDefaultAbsorptionTimeEmoji: String?

    var glucoseUnit: HKUnit = .milligramsPerDeciliter

    private var computedInitialBolusRecommendation = false

    var bolusRecommendation: BolusRecommendation? = nil {
        didSet {
            let amount = bolusRecommendation?.amount ?? 0
            recommendedBolusAmountLabel?.text = bolusUnitsFormatter.string(from: amount)

            updateNotice()
            let wasNoticeRowHidden = oldValue?.notice == nil
            let isNoticeRowHidden = bolusRecommendation?.notice == nil
            if wasNoticeRowHidden != isNoticeRowHidden {
                tableView.reloadRows(at: [IndexPath(row: Row.notice.rawValue, section: 0)], with: .automatic)
            }

            if computedInitialBolusRecommendation,
                bolusRecommendation?.amount != oldValue?.amount,
                bolusAmountTextField.text?.isEmpty == false
            {
                bolusAmountTextField.text?.removeAll()

                let alert = UIAlertController(
                    title: NSLocalizedString("Bolus Recommendation Updated", comment: "Alert title for an updated bolus recommendation"),
                    message: NSLocalizedString("The bolus recommendation has updated. Please reconfirm the bolus amount.", comment: "Alert message for an updated bolus recommendation"),
                    preferredStyle: .alert
                )

                let acknowledgeChange = UIAlertAction(title: NSLocalizedString("OK", comment: "Button text to acknowledge an updated bolus recommendation alert"), style: .default) { _ in }
                alert.addAction(acknowledgeChange)

                present(alert, animated: true)
            }
        }
    }

    var maxBolus: Double = 25

    private(set) var bolus: Double?

    private(set) var updatedCarbEntry: NewCarbEntry?

    private var refreshContext = RefreshContext.all

    private let glucoseChart = PredictedGlucoseChart()

    private var chartStartDate: Date {
        get { charts.startDate }
        set {
            if newValue != chartStartDate {
                refreshContext = RefreshContext.all
            }

            charts.startDate = newValue
        }
    }

    private var eventualGlucoseDescription: String?

    private(set) lazy var footerView: SetupTableFooterView = {
        let footerView = SetupTableFooterView(frame: .zero)
        footerView.primaryButton.addTarget(self, action: #selector(confirmCarbEntryAndBolus(_:)), for: .touchUpInside)
        return footerView
    }()

    private var lastContentHeight: CGFloat = 0

    override func createChartsManager() -> ChartsManager {
        ChartsManager(colors: .default, settings: .default, charts: [glucoseChart], traitCollection: traitCollection)
    }

    override func glucoseUnitDidChange() {
        refreshContext = RefreshContext.all
    }

    override func reloadData(animated: Bool = false) {
        updateChartDateRange()
        redrawChart()

        guard active && visible && !refreshContext.isEmpty else {
            return
        }

        let reloadGroup = DispatchGroup()
        if self.refreshContext.remove(.glucose) != nil {
            reloadGroup.enter()
            self.deviceManager.loopManager.glucoseStore.getCachedGlucoseSamples(start: self.chartStartDate) { (values) -> Void in
                self.glucoseChart.setGlucoseValues(values)
                reloadGroup.leave()
            }
        }

        _ = self.refreshContext.remove(.status)
        reloadGroup.enter()
        self.deviceManager.loopManager.getLoopState { (manager, state) in
            let enteredBolus = DispatchQueue.main.sync { self.enteredBolus }

            let predictedGlucoseIncludingPendingInsulin: [PredictedGlucoseValue]
            do {
                predictedGlucoseIncludingPendingInsulin = try state.predictGlucose(using: .all, potentialBolus: enteredBolus, potentialCarbEntry: self.potentialCarbEntry, replacingCarbEntry: self.originalCarbEntry, includingPendingInsulin: true)
            } catch {
                self.refreshContext.update(with: .status)
                predictedGlucoseIncludingPendingInsulin = []
            }

            self.glucoseChart.setPredictedGlucoseValues(predictedGlucoseIncludingPendingInsulin)

            if let lastPoint = self.glucoseChart.predictedGlucosePoints.last?.y {
                self.eventualGlucoseDescription = String(describing: lastPoint)
            } else {
                self.eventualGlucoseDescription = nil
            }

            if self.refreshContext.remove(.targets) != nil {
                self.glucoseChart.targetGlucoseSchedule = manager.settings.glucoseTargetRangeSchedule
                self.glucoseChart.scheduleOverride = manager.settings.scheduleOverride
            }

            if self.glucoseChart.scheduleOverride?.hasFinished() == true {
                self.glucoseChart.scheduleOverride = nil
            }

            let maximumBolus = manager.settings.maximumBolus
            let bolusRecommendation = try? state.recommendBolus(forPrediction: predictedGlucoseIncludingPendingInsulin)

            DispatchQueue.main.async {
                if let maxBolus = maximumBolus {
                    self.maxBolus = maxBolus
                }

                self.bolusRecommendation = bolusRecommendation
                self.computedInitialBolusRecommendation = true
            }

            reloadGroup.leave()
        }

        reloadGroup.notify(queue: .main) {
            self.updateDeliverButtonState()
            self.redrawChart()
        }
    }

    private func updateChartDateRange() {
        let settings = deviceManager.loopManager.settings

        // How far back should we show data? Use the screen size as a guide.
        let availableWidth = (refreshContext.newSize ?? self.tableView.bounds.size).width - self.charts.fixedHorizontalMargin

        let totalHours = floor(Double(availableWidth / settings.minimumChartWidthPerHour))
        let futureHours = ceil((deviceManager.loopManager.insulinModelSettings?.model.effectDuration ?? .hours(4)).hours)
        let historyHours = max(settings.statusChartMinimumHistoryDisplay.hours, totalHours - futureHours)

        let date = Date(timeIntervalSinceNow: -TimeInterval(hours: historyHours))
        let chartStartDate = Calendar.current.nextDate(after: date, matching: DateComponents(minute: 0), matchingPolicy: .strict, direction: .backward) ?? date
        if charts.startDate != chartStartDate {
            refreshContext.formUnion(RefreshContext.all)
        }
        charts.startDate = chartStartDate
        charts.maxEndDate = chartStartDate.addingTimeInterval(.hours(totalHours))
        charts.updateEndDate(charts.maxEndDate)
    }

    private func redrawChart() {
        charts.invalidateChart(atIndex: 0)
        charts.prerender()

        tableView.beginUpdates()
        for case let cell as ChartTableViewCell in tableView.visibleCells {
            cell.reloadChart()

            if let indexPath = tableView.indexPath(for: cell) {
                self.tableView(tableView, updateSubtitleFor: cell, at: indexPath)
            }
        }
        tableView.endUpdates()
    }

    private var isBolusRecommended: Bool {
        bolusRecommendation != nil && bolusRecommendation!.amount > 0
    }

    private func updateDeliverButtonState() {
        let deliverText = NSLocalizedString("Deliver", comment: "The button text to initiate a bolus")

        if isLoggingDose {
            footerView.primaryButton.setTitle(NSLocalizedString("Log Dose", comment: "The button text to log an insulin dose not given by the pump"), for: .normal)
            footerView.primaryButton.isEnabled = enteredBolusAmount != nil && enteredBolusAmount! > 0
            footerView.primaryButton.tintColor = .systemBlue
        } else if potentialCarbEntry == nil {
            footerView.primaryButton.setTitle(deliverText, for: .normal)
            footerView.primaryButton.isEnabled = enteredBolusAmount != nil && enteredBolusAmount! > 0
        } else {
            if enteredBolusAmount == nil || enteredBolusAmount! == 0 {
                footerView.primaryButton.setTitle(NSLocalizedString("Save without Bolusing", comment: "The button text to save a carb entry without bolusing"), for: .normal)
                footerView.primaryButton.tintColor = isBolusRecommended ? .alternateBlue : .systemBlue
            } else {
                footerView.primaryButton.setTitle(deliverText, for: .normal)
                footerView.primaryButton.tintColor = .systemBlue
            }
        }
    }

    // MARK: - IBOutlets

    @IBOutlet weak var recommendedBolusAmountLabel: UILabel? {
        didSet {
            let amount = bolusRecommendation?.amount ?? 0
            recommendedBolusAmountLabel?.text = bolusUnitsFormatter.string(from: amount)
        }
    }

    @IBOutlet weak var noticeLabel: UILabel? {
        didSet {
            updateNotice()
        }
    }

    @IBOutlet weak var insulinModelLabel: UILabel! {
        didSet {
            updateInsulinModelLabel()
        }
    }

    override func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
        switch Row(rawValue: indexPath.row)! {
        case .carbEntry where potentialCarbEntry == nil:
            return 0
        case .notice where bolusRecommendation?.notice == nil:
            return 0
        case .model where !isLoggingDose:
            return 0
        case .date where !isLoggingDose:
            return 0
        case .recommended where isLoggingDose:
            return 0
        default:
            return super.tableView(tableView, heightForRowAt: indexPath)
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        switch Row(rawValue: indexPath.row)! {
        case .carbEntry where potentialCarbEntry != nil:
            navigationController?.popViewController(animated: true)
        case .recommended:
            acceptRecommendedBolus()
        default:
            break
        }
        
        tableView.endUpdates()
        tableView.deselectRow(at: indexPath, animated: true)
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = Row(rawValue: indexPath.row)
        switch row {
        case .date:
            let cell = tableView.dequeueReusableCell(withIdentifier: DateAndDurationTableViewCell.className) as! DateAndDurationTableViewCell

           cell.titleLabel.text = NSLocalizedString("Date", comment: "Title of the bolus dose date picker cell")
           cell.datePicker.isEnabled = true
           cell.datePicker.datePickerMode = .dateAndTime
           cell.datePicker.maximumDate = Date(timeIntervalSinceNow: maximumDateFutureInterval)
           cell.datePicker.minuteInterval = 1
           cell.date = Date()
           cell.delegate = self

           return cell
        default:
            return super.tableView(tableView, cellForRowAt: indexPath)
        }
    }
            
    override func tableView(_ tableView: UITableView, willDisplay cell: UITableViewCell, forRowAt indexPath: IndexPath) {
        let row = Row(rawValue: indexPath.row)
        switch row {
        case .carbEntry:
            guard let entry = potentialCarbEntry else {
                return
            }

            let cell = cell as! PotentialCarbEntryTableViewCell
            let unit = HKUnit.gram()
            let carbText = carbFormatter.string(from: entry.quantity.doubleValue(for: unit), unit: unit.unitString)

            if let carbText = carbText, let foodType = entry.foodType ?? selectedDefaultAbsorptionTimeEmoji {
                cell.valueLabel?.text = String(
                    format: NSLocalizedString("%1$@: %2$@", comment: "Formats (1: carb value) and (2: food type)"),
                    carbText, foodType
                )
            } else {
                cell.valueLabel?.text = carbText
            }

            let startTime = timeFormatter.string(from: entry.startDate)
            if  let absorptionTime = entry.absorptionTime,
                let duration = absorptionFormatter.string(from: absorptionTime)
            {
                cell.dateLabel?.text = String(
                    format: NSLocalizedString("%1$@ + %2$@", comment: "Formats (1: carb start time) and (2: carb absorption duration)"),
                    startTime, duration
                )
            } else {
                cell.dateLabel?.text = startTime
            }
        case .chart:
            let cell = cell as! ChartTableViewCell
            cell.contentView.layoutMargins.left = tableView.separatorInset.left
            cell.chartContentView.chartGenerator = { [weak self] (frame) in
                return self?.charts.chart(atIndex: 0, frame: frame)?.view
            }

            cell.titleLabel?.text?.removeAll()
            cell.subtitleLabel?.textColor = UIColor.secondaryLabelColor
            self.tableView(tableView, updateSubtitleFor: cell, at: indexPath)
            cell.selectionStyle = .none

            cell.addGestureRecognizer(charts.gestureRecognizer!)
        case .recommended:
            cell.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: NSLocalizedString("AcceptRecommendedBolus", comment: "Action to copy the recommended Bolus value to the actual Bolus Field"), target: self, selector: #selector(BolusViewController.acceptRecommendedBolus))
            ]
        default:
            break
        }
    }

    private func tableView(_ tableView: UITableView, updateSubtitleFor cell: ChartTableViewCell, at indexPath: IndexPath) {
        assert(Row(rawValue: indexPath.row) == .chart)

        if let eventualGlucose = eventualGlucoseDescription {
            cell.subtitleLabel?.text = String(format: NSLocalizedString("Eventually %@", comment: "The subtitle format describing eventual glucose. (1: localized glucose value description)"), eventualGlucose)
        } else {
            cell.subtitleLabel?.text?.removeAll()
        }
    }

    @objc func acceptRecommendedBolus() {
        bolusAmountTextField?.text = recommendedBolusAmountLabel?.text
        bolusAmountTextField?.resignFirstResponder()

        updateDeliverButtonState()
        predictionRecomputation?.cancel()
        recomputePrediction()
    }
    
    @IBOutlet weak var bolusAmountTextField: UITextField! {
        didSet {
            bolusAmountTextField.addTarget(self, action: #selector(bolusAmountChanged), for: .editingChanged)
        }
    }

    private var enteredBolusAmount: Double? {
        guard let text = bolusAmountTextField?.text, let amount = bolusUnitsFormatter.number(from: text)?.doubleValue else {
            return nil
        }

        return amount >= 0 ? amount : nil
    }
    
    var enteredBolusInsulinModel: InsulinModel? {
        didSet {
            updateInsulinModelLabel()
            predictionRecomputation?.cancel()
            recomputePrediction()
        }
    }
    
    // ANNA TODO: refactor
    var enteredBolusInsulinModelSetting: InsulinModelSettings? {
        if let model = enteredBolusInsulinModel {
            return InsulinModelSettings(model: model)
        }
        return nil
    }

    private var enteredBolus: DoseEntry? {
        guard let amount = enteredBolusAmount else {
            return nil
        }

        return DoseEntry(type: .bolus, startDate: doseDate ?? Date(), value: amount, unit: .units, insulinModelSetting: enteredBolusInsulinModelSetting)
    }

    private var predictionRecomputation: DispatchWorkItem?

    @objc private func bolusAmountChanged() {
        updateDeliverButtonState()

        predictionRecomputation?.cancel()
        let predictionRecomputation = DispatchWorkItem(block: recomputePrediction)
        self.predictionRecomputation = predictionRecomputation
        let recomputeDelayMS = 300
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(recomputeDelayMS), execute: predictionRecomputation)
    }

    private func recomputePrediction() {
        deviceManager.loopManager.getLoopState { [weak self] manager, state in
            guard let self = self else { return }
            let enteredBolus = DispatchQueue.main.sync { self.enteredBolus }
            if let prediction = try? state.predictGlucose(using: .all, potentialBolus: enteredBolus, potentialCarbEntry: self.potentialCarbEntry, replacingCarbEntry: self.originalCarbEntry, includingPendingInsulin: true) {
                self.glucoseChart.setPredictedGlucoseValues(prediction)

                if let lastPoint = self.glucoseChart.predictedGlucosePoints.last?.y {
                    self.eventualGlucoseDescription = String(describing: lastPoint)
                } else {
                    self.eventualGlucoseDescription = nil
                }

                DispatchQueue.main.async {
                    self.redrawChart()
                }
            }
        }
    }

    // MARK: - Actions
   
    @objc private func confirmCarbEntryAndBolus(_ sender: Any) {
        bolusAmountTextField.resignFirstResponder()

        guard let bolus = enteredBolusAmount, let amountString = bolusUnitsFormatter.string(from: bolus) else {
            setBolusAndClose(0)
            return
        }

        guard bolus <= maxBolus else {
            let alert = UIAlertController(
                title: NSLocalizedString("Exceeds Maximum Bolus", comment: "The title of the alert describing a maximum bolus validation error"),
                message: String(format: NSLocalizedString("The maximum bolus amount is %@ Units", comment: "Body of the alert describing a maximum bolus validation error. (1: The localized max bolus value)"), bolusUnitsFormatter.string(from: maxBolus) ?? ""),
                preferredStyle: .alert)

            let action = UIAlertAction(title: NSLocalizedString("com.loudnate.LoopKit.errorAlertActionTitle", value: "OK", comment: "The title of the action used to dismiss an error alert"), style: .default)
            alert.addAction(action)
            alert.preferredAction = action

            present(alert, animated: true)
            return
        }

        let context = LAContext()

        if context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil) {
            // The authentication reason should change if a dose is being logged
            let localizedReason = isLoggingDose ? String(format: NSLocalizedString("Authenticate to log %@ Units", comment: "The message displayed during a device authentication prompt for logging an insulin dose"), amountString) : String(format: NSLocalizedString("Authenticate to Bolus %@ Units", comment: "The message displayed during a device authentication prompt for bolus specification"), amountString)

            context.evaluatePolicy(.deviceOwnerAuthentication,
                                   localizedReason: localizedReason,
                                   reply: { (success, error) in
                if success {
                    DispatchQueue.main.async {
                        self.setBolusAndClose(bolus)
                    }
                }
            })
        } else {
            setBolusAndClose(bolus)
        }
    }

    private func setBolusAndClose(_ bolus: Double) {
        self.updatedCarbEntry = potentialCarbEntry
        self.bolus = bolus

        self.performSegue(withIdentifier: "close", sender: nil)
    }

    @objc private func cancel() {
        dismiss(animated: true)
    }

    private lazy var carbFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        return formatter
    }()

    private lazy var absorptionFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.collapsesLargestUnit = true
        formatter.unitsStyle = .abbreviated
        formatter.allowsFractionalUnits = true
        formatter.allowedUnits = [.hour, .minute]
        return formatter
    }()

    private lazy var timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private lazy var bolusUnitsFormatter: NumberFormatter = {
        let numberFormatter = NumberFormatter()

        numberFormatter.maximumSignificantDigits = 3
        numberFormatter.minimumFractionDigits = 1

        return numberFormatter
    }()

    private func updateNotice() {
        if let notice = bolusRecommendation?.notice {
            noticeLabel?.text = "⚠ \(notice.description(using: glucoseUnit))"
        } else {
            noticeLabel?.text = nil
        }
    }
    
    private func updateInsulinModelLabel() {
        switch enteredBolusInsulinModel {
        case let model as WalshInsulinModel:
            insulinModelLabel?.text = model.title
        case let model as ExponentialInsulinModelPreset:
            insulinModelLabel?.text = model.title
        default:
            break
        }
    }

    // MARK: - UITextFieldDelegate

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()

        return true
    }
}

extension BolusViewController {
    static func instance() -> BolusViewController {
        let storyboard = UIStoryboard(name: "Main", bundle: nil)
        return storyboard.instantiateViewController(withIdentifier: className) as! BolusViewController
    }
}

extension BolusViewController: InsulinModelSettingsViewControllerDelegate {
    func insulinModelSettingsViewControllerDidChangeValue(_ controller: InsulinModelSettingsViewController) {
        guard let model = controller.insulinModel else {
            return
        }
        
        self.enteredBolusInsulinModel = model
    }
}

extension UIColor {
    static var alternateBlue: UIColor {
        if #available(iOS 13.0, *) {
            return UIColor(dynamicProvider: { traitCollection in
                traitCollection.userInterfaceStyle == .dark
                    ? UIColor(red: 50 / 255, green: 148 / 255, blue: 255 / 255, alpha: 1.0)
                    : UIColor(red: 0 / 255, green: 97 / 255, blue: 204 / 255, alpha: 1.0)
            })
        } else {
            return UIColor(red: 50 / 255, green: 148 / 255, blue: 255 / 255, alpha: 1.0)
        }
    }
}

extension BolusViewController: DatePickerTableViewCellDelegate {
    func datePickerTableViewCellDidUpdateDate(_ cell: DatePickerTableViewCell) {
        guard let row = tableView.indexPath(for: cell)?.row else { return }

        switch Row(rawValue: row) {
        case .date?:
            doseDate = cell.date
        default:
            break
        }
    }
}
