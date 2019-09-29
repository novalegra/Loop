//
//  DoseMath.swift
//  Naterade
//
//  Created by Nathan Racklyeft on 3/8/16.
//  Copyright © 2016 Nathan Racklyeft. All rights reserved.
//

import Foundation
import HealthKit
import LoopKit


private enum InsulinCorrection {
    case inRange
    case aboveRange(min: GlucoseValue, correcting: GlucoseValue, minTarget: HKQuantity, units: Double)
    case entirelyBelowRange(correcting: GlucoseValue, minTarget: HKQuantity, units: Double)
    case suspend(min: GlucoseValue)
    
    func getTarget() -> HKQuantity? {
        switch self {
        case .aboveRange(min: _, correcting: _, minTarget: let target, units: _):
            return target
        case .entirelyBelowRange(correcting: _, minTarget: let target, units: _):
            return target
        case .inRange:
            return nil
        case .suspend:
            return nil
        }
    }
}


extension InsulinCorrection {
    /// The delivery units for the correction
    private var units: Double {
        switch self {
        case .aboveRange(min: _, correcting: _, minTarget: _, units: let units):
            return units
        case .entirelyBelowRange(correcting: _, minTarget: _, units: let units):
            return units
        case .inRange, .suspend:
            return 0
        }
    }

    /// Determines the temp basal over `duration` needed to perform the correction.
    ///
    /// - Parameters:
    ///   - scheduledBasalRate: The scheduled basal rate at the time the correction is delivered
    ///   - maxBasalRate: The maximum allowed basal rate
    ///   - duration: The duration of the temporary basal
    ///   - rateRounder: The smallest fraction of a unit supported in basal delivery
    /// - Returns: A temp basal recommendation
    fileprivate func asTempBasal(
        scheduledBasalRate: Double,
        maxBasalRate: Double,
        duration: TimeInterval,
        rateRounder: ((Double) -> Double)?
    ) -> TempBasalRecommendation {
        var rate = units / (duration / TimeInterval(hours: 1))  // units/hour
        switch self {
        case .aboveRange, .inRange, .entirelyBelowRange:
            rate += scheduledBasalRate
        case .suspend:
            break
        }

        rate = Swift.min(maxBasalRate, Swift.max(0, rate))

        rate = rateRounder?(rate) ?? rate

        return TempBasalRecommendation(
            unitsPerHour: rate,
            duration: duration
        )
    }

    private var bolusRecommendationNotice: BolusRecommendationNotice? {
        switch self {
        case .suspend(min: let minimum):
            return .glucoseBelowSuspendThreshold(minGlucose: minimum)
        case .inRange, .entirelyBelowRange:
            return nil
        case .aboveRange(min: let min, correcting: _, minTarget: let target, units: let units):
            if units > 0 && min.quantity < target {
                return .predictedGlucoseBelowTarget(minGlucose: min)
            } else {
                return nil
            }
        }
    }
    
    /// Determines the microbolus needed to perform the correction if BGs are predicted
    /// to be above range
    /// - Parameters:
    ///   - date: The date at which the super-microbolus (SMB) would apply, defaults to now
    ///   - pendingInsulin: The number of units expected to be delivered, but not yet reflected in the correction
    ///   - naiveEventualBG: The predicted eventual BG based on IOB
    ///   - minIOBPredBG: The lowest predicted BG measurement after the insulin has peaked in a prediction that incorporates insulin and momentum effects
    ///   - lastBolusTime: The start time of the most recently given bolus dose
    ///   - maxBasalRate: The maximum basal rate to return
    ///   - userSetMaxBolus: The maximum bolus to return
    ///   - iob: The current IOB
    ///   - cob: The current COB
    ///   - sensitivity: The current insulin sensitivity
    ///   - carbRatio: The current carb ratio
    ///   - scheduledbasalRate: The current scheduled basal rate
    ///   - maxSMBMinutes: The maximum minutes of basal insulin that can be given as a SMB
    ///   - maxUAMSMBMinutes: The maximum minutes of basal insulin that can be given as a SMB when there has likely been an unannounced meal (UAM)
    /// - Returns: The recommended temporary basal rate and SMB
    fileprivate func asMicrobolus(
        at date: Date = Date(),
        pendingInsulin: Double,
        naiveEventualBG: HKQuantity,
        minIOBPredBG: HKQuantity,
        lastBolusTime: Date?,
        maxBasalRate: Double,
        userSetMaxBolus: Double,
        iob: Double,
        cob: Double,
        sensitivity: HKQuantity,
        carbRatio: Double,
        scheduledBasalRate: Double,
        rateRounder: ((Double) -> Double)?,
        maxSMBMinutes: Double = 30,
        maxUAMSMBMinutes: Double = 30
        ) -> (TempBasalRecommendation?, BolusRecommendation)? {

        switch self {
            case .aboveRange:
                break
            
            default:
                return nil
        }

        let insulinReq = self.units - pendingInsulin
        let mealtimeInsulinReq = cob / carbRatio
        var maxBolus:Double
        // if the IOB is likely due to a meal, use "max_uam_smb_minutes"-worth,
        // otherwise use "max_smb_minutes"-worth
        if iob > mealtimeInsulinReq && iob > 0 {
            maxBolus = min(userSetMaxBolus, scheduledBasalRate * maxUAMSMBMinutes / 60)
        } else {
            maxBolus = min(userSetMaxBolus, scheduledBasalRate * maxUAMSMBMinutes / 60)
        }
        
        // bolus half of the required correction up to the max bolus, rounding down in 0.1 U increments
        let microbolus = floor(min(insulinReq / 2, maxBolus) * 10) / 10
    
        // if there is insulin required but not enough for a microbolus, set a temp basal rate instead
        if insulinReq > 0 && microbolus < 0.1 {
            return nil
        }
        
        let target = self.getTarget()
        let unit = HKUnit.milligramsPerDeciliter
        guard let smbTarget = target, let lastBolusTime = lastBolusTime else {
            return nil
        }

        let worstCaseRequiredInsulin = (
            smbTarget.doubleValue(for: unit) - (
                max(0, naiveEventualBG.doubleValue(for: unit)) - max(0, minIOBPredBG.doubleValue(for: unit))
            ) / 2
        ) / sensitivity.doubleValue(for:unit)
        
        // the required duration must be between 0 and 60 minutes, inclusive
        var requiredDuration = min(60, max(round(60 * worstCaseRequiredInsulin / scheduledBasalRate), 0))
        var smbLowTemp:Double
        
        // if required duration is less than 30 minutes, set a non-zero low temp
        if requiredDuration < 30 {
            smbLowTemp = min(maxBasalRate, scheduledBasalRate * requiredDuration / 30)
            requiredDuration = 30
        } else {
            smbLowTemp = 0
        }
        
        let lastBolusAge = date.timeIntervalSince(lastBolusTime)
        // continue with the current temp rate if there was a recent bolus
        if lastBolusAge.minutes <= 3 {
            return nil // TODO: figure out how to send signal to continue current temp
        }
        
        if requiredDuration > 0 {
            return (
                TempBasalRecommendation(
                    unitsPerHour: rateRounder?(smbLowTemp) ?? smbLowTemp,
                    duration: requiredDuration
                ),
                BolusRecommendation(
                    amount: microbolus, // this was already pre-rounded during computation
                    pendingInsulin: pendingInsulin,
                    notice: bolusRecommendationNotice
                )
            )
        } else {
            return nil // if no zero-temp is required, set a high temp instead
        }
    }

    /// Determines the bolus needed to perform the correction
    ///
    /// - Parameters:
    ///   - pendingInsulin: The number of units expected to be delivered, but not yet reflected in the correction
    ///   - maxBolus: The maximum allowable bolus value in units
    ///   - volumeRounder: The smallest fraction of a unit supported in bolus delivery
    /// - Returns: A bolus recommendation
    fileprivate func asBolus(
        pendingInsulin: Double,
        maxBolus: Double,
        volumeRounder: ((Double) -> Double)?
    ) -> BolusRecommendation {
        var units = self.units - pendingInsulin
        units = Swift.min(maxBolus, Swift.max(0, units))
        units = volumeRounder?(units) ?? units

        return BolusRecommendation(
            amount: units,
            pendingInsulin: pendingInsulin,
            notice: bolusRecommendationNotice
        )
    }
}


struct TempBasalRecommendation: Equatable {
    let unitsPerHour: Double
    let duration: TimeInterval

    /// A special command which cancels any existing temp basals
    static var cancel: TempBasalRecommendation {
        return self.init(unitsPerHour: 0, duration: 0)
    }
}


extension TempBasalRecommendation {
    /// Equates the recommended rate with another rate
    ///
    /// - Parameter unitsPerHour: The rate to compare
    /// - Returns: Whether the rates are equal within Double precision
    private func matchesRate(_ unitsPerHour: Double) -> Bool {
        return abs(self.unitsPerHour - unitsPerHour) < .ulpOfOne
    }

    /// Determines whether the recommendation is necessary given the current state of the pump
    ///
    /// - Parameters:
    ///   - date: The date the recommendation would be delivered
    ///   - scheduledBasalRate: The scheduled basal rate at `date`
    ///   - lastTempBasal: The previously set temp basal
    ///   - continuationInterval: The duration of time before an ongoing temp basal should be continued with a new command
    ///   - scheduledBasalRateMatchesPump: A flag describing whether `scheduledBasalRate` matches the scheduled basal rate of the pump.
    ///                                    If `false` and the recommendation matches `scheduledBasalRate`, the temp will be recommended
    ///                                    at the scheduled basal rate rather than recommending no temp.
    /// - Returns: A temp basal recommendation
    func ifNecessary(
        at date: Date,
        scheduledBasalRate: Double,
        lastTempBasal: DoseEntry?,
        continuationInterval: TimeInterval,
        scheduledBasalRateMatchesPump: Bool
    ) -> TempBasalRecommendation? {
        // Adjust behavior for the currently active temp basal
        if let lastTempBasal = lastTempBasal,
            lastTempBasal.type == .tempBasal,
            lastTempBasal.endDate > date
        {
            /// If the last temp basal has the same rate, and has more than `continuationInterval` of time remaining, don't set a new temp
            if matchesRate(lastTempBasal.unitsPerHour),
                lastTempBasal.endDate.timeIntervalSince(date) > continuationInterval {
                return nil
            } else if matchesRate(scheduledBasalRate), scheduledBasalRateMatchesPump {
                // If our new temp matches the scheduled rate of the pump, cancel the current temp
                return .cancel
            }
        } else if matchesRate(scheduledBasalRate), scheduledBasalRateMatchesPump {
            // If we recommend the in-progress scheduled basal rate of the pump, do nothing
            return nil
        }

        return self
    }
}


/// Computes a total insulin amount necessary to correct a glucose differential at a given sensitivity
///
/// - Parameters:
///   - fromValue: The starting glucose value
///   - toValue: The desired glucose value
///   - effectedSensitivity: The sensitivity, in glucose-per-insulin-unit
/// - Returns: The insulin correction in units
private func insulinCorrectionUnits(fromValue: Double, toValue: Double, effectedSensitivity: Double) -> Double? {
    guard effectedSensitivity > 0 else {
        return nil
    }

    let glucoseCorrection = fromValue - toValue

    return glucoseCorrection / effectedSensitivity
}

/// Computes a target glucose value for a correction, at a given time during the insulin effect duration
///
/// - Parameters:
///   - percentEffectDuration: The percent of time elapsed of the insulin effect duration
///   - minValue: The minimum (starting) target value
///   - maxValue: The maximum (eventual) target value
/// - Returns: A target value somewhere between the minimum and maximum
private func targetGlucoseValue(percentEffectDuration: Double, minValue: Double, maxValue: Double) -> Double {
    // The inflection point in time: before it we use minValue, after it we linearly blend from minValue to maxValue
    let useMinValueUntilPercent = 0.5

    guard percentEffectDuration > useMinValueUntilPercent else {
        return minValue
    }

    guard percentEffectDuration < 1 else {
        return maxValue
    }

    let slope = (maxValue - minValue) / (1 - useMinValueUntilPercent)
    return minValue + slope * (percentEffectDuration - useMinValueUntilPercent)
}


extension Collection where Element: GlucoseValue {

    /// For a collection of glucose prediction, determine the least amount of insulin delivered at
    /// `date` to correct the predicted glucose to the middle of `correctionRange` at the time of prediction.
    ///
    /// - Parameters:
    ///   - correctionRange: The schedule of glucose values used for correction
    ///   - date: The date the insulin correction is delivered
    ///   - suspendThreshold: The glucose value below which only suspension is returned
    ///   - sensitivity: The insulin sensitivity at the time of delivery
    ///   - model: The insulin effect model
    /// - Returns: A correction value in units, if one could be calculated
    private func insulinCorrection(
        to correctionRange: GlucoseRangeSchedule,
        at date: Date,
        suspendThreshold: HKQuantity,
        sensitivity: HKQuantity,
        model: InsulinModel
    ) -> InsulinCorrection? {
        var minGlucose: GlucoseValue?
        var eventualGlucose: GlucoseValue?
        var correctingGlucose: GlucoseValue?
        var minCorrectionUnits: Double?

        // Only consider predictions within the model's effect duration
        let validDateRange = DateInterval(start: date, duration: model.effectDuration)

        let unit = correctionRange.unit
        let sensitivityValue = sensitivity.doubleValue(for: unit)
        let suspendThresholdValue = suspendThreshold.doubleValue(for: unit)

        // For each prediction above target, determine the amount of insulin necessary to correct glucose based on the modeled effectiveness of the insulin at that time
        for prediction in self {
            guard validDateRange.contains(prediction.startDate) else {
                continue
            }

            // If any predicted value is below the suspend threshold, return immediately
            guard prediction.quantity >= suspendThreshold else {
                return .suspend(min: prediction)
            }

            // Update range statistics
            if minGlucose == nil || prediction.quantity < minGlucose!.quantity {
                minGlucose = prediction
            }
            eventualGlucose = prediction

            let predictedGlucoseValue = prediction.quantity.doubleValue(for: unit)
            let time = prediction.startDate.timeIntervalSince(date)

            // Compute the target value as a function of time since the dose started
            let targetValue = targetGlucoseValue(
                percentEffectDuration: time / model.effectDuration,
                minValue: suspendThresholdValue, 
                maxValue: correctionRange.quantityRange(at: prediction.startDate).averageValue(for: unit)
            )

            // Compute the dose required to bring this prediction to target:
            // dose = (Glucose Δ) / (% effect × sensitivity)

            let percentEffected = 1 - model.percentEffectRemaining(at: time)
            let effectedSensitivity = percentEffected * sensitivityValue
            guard let correctionUnits = insulinCorrectionUnits(
                fromValue: predictedGlucoseValue,
                toValue: targetValue,
                effectedSensitivity: effectedSensitivity
            ), correctionUnits > 0 else {
                continue
            }

            // Update the correction only if we've found a new minimum
            guard minCorrectionUnits == nil || correctionUnits < minCorrectionUnits! else {
                continue
            }

            correctingGlucose = prediction
            minCorrectionUnits = correctionUnits
        }

        guard let eventual = eventualGlucose, let min = minGlucose else {
            return nil
        }

        // Choose either the minimum glucose or eventual glucose as the correction delta
        let minGlucoseTargets = correctionRange.quantityRange(at: min.startDate)
        let eventualGlucoseTargets = correctionRange.quantityRange(at: eventual.startDate)

        // Treat the minimum glucose when both are below range
        if min.quantity < minGlucoseTargets.lowerBound &&
            eventual.quantity < eventualGlucoseTargets.lowerBound
        {
            let time = min.startDate.timeIntervalSince(date)
            // For time = 0, assume a small amount effected. This will result in large (negative) unit recommendation rather than no recommendation at all.
            let percentEffected = Swift.max(.ulpOfOne, 1 - model.percentEffectRemaining(at: time))

            guard let units = insulinCorrectionUnits(
                fromValue: min.quantity.doubleValue(for: unit),
                toValue: minGlucoseTargets.averageValue(for: unit),
                effectedSensitivity: sensitivityValue * percentEffected
            ) else {
                return nil
            }

            return .entirelyBelowRange(
                correcting: min,
                minTarget: minGlucoseTargets.lowerBound,
                units: units
            )
        } else if eventual.quantity > eventualGlucoseTargets.upperBound,
            let minCorrectionUnits = minCorrectionUnits, let correctingGlucose = correctingGlucose
        {
            return .aboveRange(
                min: min,
                correcting: correctingGlucose,
                minTarget: eventualGlucoseTargets.lowerBound,
                units: minCorrectionUnits
            )
        } else {
            return .inRange
        }
    }

    /// Recommends a temporary basal rate to conform a glucose prediction timeline to a correction range
    ///
    /// Returns nil if the normal scheduled basal, or active temporary basal, is sufficient.
    ///
    /// - Parameters:
    ///   - correctionRange: The schedule of correction ranges
    ///   - date: The date at which the temp basal would be scheduled, defaults to now
    ///   - suspendThreshold: A glucose value causing a recommendation of no insulin if any prediction falls below
    ///   - sensitivity: The schedule of insulin sensitivities
    ///   - model: The insulin absorption model
    ///   - basalRates: The schedule of basal rates
    ///   - maxBasalRate: The maximum allowed basal rate
    ///   - lastTempBasal: The previously set temp basal
    ///   - rateRounder: Closure that rounds recommendation to nearest supported rate. If nil, no rounding is performed
    ///   - isBasalRateScheduleOverrideActive: A flag describing whether a basal rate schedule override is in progress
    ///   - duration: The duration of the temporary basal
    ///   - continuationInterval: The duration of time before an ongoing temp basal should be continued with a new command
    /// - Returns: The recommended temporary basal rate and duration
    func recommendedTempBasal(
        to correctionRange: GlucoseRangeSchedule,
        at date: Date = Date(),
        suspendThreshold: HKQuantity?,
        sensitivity: InsulinSensitivitySchedule,
        model: InsulinModel,
        basalRates: BasalRateSchedule,
        maxBasalRate: Double,
        lastTempBasal: DoseEntry?,
        rateRounder: ((Double) -> Double)? = nil,
        isBasalRateScheduleOverrideActive: Bool = false,
        duration: TimeInterval = .minutes(30),
        continuationInterval: TimeInterval = .minutes(11)
    ) -> TempBasalRecommendation? {
        let correction = self.insulinCorrection(
            to: correctionRange,
            at: date,
            suspendThreshold: suspendThreshold ?? correctionRange.quantityRange(at: date).lowerBound,
            sensitivity: sensitivity.quantity(at: date),
            model: model
        )

        let scheduledBasalRate = basalRates.value(at: date)
        var maxBasalRate = maxBasalRate

        // TODO: Allow `highBasalThreshold` to be a configurable setting
        if case .aboveRange(min: let min, correcting: _, minTarget: let highBasalThreshold, units: _)? = correction,
            min.quantity < highBasalThreshold
        {
            maxBasalRate = scheduledBasalRate
        }

        let temp = correction?.asTempBasal(
            scheduledBasalRate: scheduledBasalRate,
            maxBasalRate: maxBasalRate,
            duration: duration,
            rateRounder: rateRounder
        )

        return temp?.ifNecessary(
            at: date,
            scheduledBasalRate: scheduledBasalRate,
            lastTempBasal: lastTempBasal,
            continuationInterval: continuationInterval,
            scheduledBasalRateMatchesPump: !isBasalRateScheduleOverrideActive
        )
    }

    /// Recommends a bolus to conform a glucose prediction timeline to a correction range
    ///
    /// - Parameters:
    ///   - correctionRange: The schedule of correction ranges
    ///   - date: The date at which the bolus would apply, defaults to now
    ///   - suspendThreshold: A glucose value causing a recommendation of no insulin if any prediction falls below
    ///   - sensitivity: The schedule of insulin sensitivities
    ///   - model: The insulin absorption model
    ///   - pendingInsulin: The number of units expected to be delivered, but not yet reflected in the correction
    ///   - maxBolus: The maximum bolus to return
    ///   - volumeRounder: Closure that rounds recommendation to nearest supported bolus volume. If nil, no rounding is performed
    /// - Returns: A bolus recommendation
    func recommendedBolus(
        to correctionRange: GlucoseRangeSchedule,
        at date: Date = Date(),
        suspendThreshold: HKQuantity?,
        sensitivity: InsulinSensitivitySchedule,
        model: InsulinModel,
        pendingInsulin: Double,
        maxBolus: Double,
        volumeRounder: ((Double) -> Double)? = nil
    ) -> BolusRecommendation {
        guard let correction = self.insulinCorrection(
            to: correctionRange,
            at: date,
            suspendThreshold: suspendThreshold ?? correctionRange.quantityRange(at: date).lowerBound,
            sensitivity: sensitivity.quantity(at: date),
            model: model
        ) else {
            return BolusRecommendation(amount: 0, pendingInsulin: pendingInsulin)
        }

        var bolus = correction.asBolus(
            pendingInsulin: pendingInsulin,
            maxBolus: maxBolus,
            volumeRounder: volumeRounder
        )

        // Handle the "current BG below target" notice here
        // TODO: Don't assume in the future that the first item in the array is current BG
        if case .predictedGlucoseBelowTarget? = bolus.notice,
            let first = first, first.quantity < correctionRange.quantityRange(at: first.startDate).lowerBound
        {
            bolus.notice = .currentGlucoseBelowTarget(glucose: first)
        }

        return bolus
    }
    
    /// Recommends a supermicrobolus and a zero (or near-zero) temp to ensure safety
    ///
    /// Returns nil if microbolus cannot be delivered (last bolus was too recent, not predicted to be high, etc) and a temp basal/recommended bolus should instead be calculated
    ///
    /// - Parameters:
    ///   - minIOBPredBG: The lowest predicted BG measurement after the insulin has peaked in a prediction that incorporates insulin and momentum effects
    ///   - correctionRange: schedule of correction ranges
    ///   - date: The date at which the super-microbolus (SMB) would apply, defaults to now
    ///   - suspendThreshold: A glucose value causing a recommendation of no insulin if any prediction falls below
    ///   - sensitivities: The schedule of insulin sensitivities
    ///   - model: The insulin absorption model
    ///   - pendingInsulin: The number of units expected to be delivered, but not yet reflected in the correction
    ///   - carbRatios: The schedule of carb ratios
    ///   - basalRates: The schedule of basal rates
    ///   - iob: The current IOB
    ///   - cob: The current COB
    ///   - maxBasalRate: The maximum basal rate to return
    ///   - maxBolus: The maximum bolus to return
    ///   - lastBolus: The dose entry of the most recently given bolus dose
    ///   - maxSMBMinutes: The maximum minutes of basal insulin that can be given as a SMB
    ///   - maxUAMSMBMinutes: The maximum minutes of basal insulin that can be given as a SMB when there has likely been an unannounced meal (UAM)
    /// - Returns: The recommended temporary basal rate and SMB
    func recommendedSuperMicrobolus(
        minIOBPredBG: HKQuantity,
        to correctionRange: GlucoseRangeSchedule,
        at date: Date = Date(),
        suspendThreshold: HKQuantity?,
        sensitivities: InsulinSensitivitySchedule,
        model: InsulinModel,
        pendingInsulin: Double,
        carbRatios: CarbRatioSchedule,
        basalRates: BasalRateSchedule,
        iob: Double,
        cob: Double,
        maxBasalRate: Double,
        maxBolus: Double,
        lastBolusTime: Date?,
        lastTempBasal: DoseEntry?,
        maxSMBMinutes: Double,
        maxUAMSMBMinutes: Double,
        rateRounder: ((Double) -> Double)? = nil,
        isBasalRateScheduleOverrideActive: Bool = false,
        continuationInterval: TimeInterval = .minutes(11)
        ) -> (TempBasalRecommendation?, BolusRecommendation)? {
        let sensitivity = sensitivities.quantity(at: date)
        let correction = self.insulinCorrection(
            to: correctionRange,
            at: date,
            suspendThreshold: suspendThreshold ?? correctionRange.quantityRange(at: date).lowerBound,
            sensitivity: sensitivity,
            model: model
        )
        
        let carbRatio = carbRatios.value(at: date)
        let scheduledBasalRate = basalRates.value(at: date)
        
        let unit = correctionRange.unit
        let naiveEventualBG = HKQuantity(unit: unit, doubleValue: (self.first?.quantity.doubleValue(for: unit))! - iob * sensitivity.doubleValue(for: unit))
        
        
        let recommendation = correction?.asMicrobolus(
            at: date,
            pendingInsulin: pendingInsulin,
            naiveEventualBG: naiveEventualBG,
            minIOBPredBG: minIOBPredBG,
            lastBolusTime: lastBolusTime,
            maxBasalRate: maxBasalRate,
            userSetMaxBolus: maxBolus,
            iob: iob,
            cob: cob,
            sensitivity: sensitivity,
            carbRatio: carbRatio,
            scheduledBasalRate: scheduledBasalRate,
            rateRounder: rateRounder,
            maxSMBMinutes: maxSMBMinutes,
            maxUAMSMBMinutes: maxUAMSMBMinutes
        )
        
        if let recommendation = recommendation {
            let temp = recommendation.0?.ifNecessary(
                at: date,
                scheduledBasalRate: scheduledBasalRate,
                lastTempBasal: lastTempBasal,
                continuationInterval: continuationInterval,
                scheduledBasalRateMatchesPump: !isBasalRateScheduleOverrideActive
            )
            let newRecommendation = (temp, recommendation.1)
            return newRecommendation
        }
        
        return recommendation
    }

}
