//
//  ExponentialInsulinModelPreset.swift
//  Loop
//
//  Copyright © 2017 LoopKit Authors. All rights reserved.
//

import LoopKit

public enum ExponentialInsulinModelPreset: String {
    case humalogNovologAdult
    case humalogNovologChild
    case fiasp
}


// MARK: - Model generation
extension ExponentialInsulinModelPreset {
    var actionDuration: TimeInterval {
        switch self {
        case .humalogNovologAdult:
            return .minutes(360)
        case .humalogNovologChild:
            return .minutes(360)
        case .fiasp:
            return .minutes(360)
        }
    }

    var peakActivity: TimeInterval {
        switch self {
        case .humalogNovologAdult:
            return .minutes(75)
        case .humalogNovologChild:
            return .minutes(65)
        case .fiasp:
            return .minutes(55)
        }
    }
    
    var effectDelay: TimeInterval {
        switch self {
        case .humalogNovologAdult:
            return .minutes(10)
        case .humalogNovologChild:
            return .minutes(10)
        case .fiasp:
            return .minutes(10)
        }
    }

    var model: InsulinModel {
        return ExponentialInsulinModel(actionDuration: actionDuration, peakActivityTime: peakActivity, delay: effectDelay)
    }
}


extension ExponentialInsulinModelPreset: InsulinModel {
    public var effectDuration: TimeInterval {
        return model.effectDuration
    }
    
    public var delay: TimeInterval {
        return model.delay
    }

    public func percentEffectRemaining(at time: TimeInterval) -> Double {
        return model.percentEffectRemaining(at: time)
    }

    public func isEqualTo(other: InsulinModel?) -> Bool {
        if let other = other as? ExponentialInsulinModelPreset {
            // TODO: this is bad style (sigh)
            // they're both insulinmodelpresets
            let currentModel = model as! ExponentialInsulinModel
            return currentModel.actionDuration == other.actionDuration && currentModel.peakActivityTime == other.peakActivity && currentModel.delay == other.effectDelay
        }
        if let other = other as? ExponentialInsulinModel {
            return model.isEqualTo(other: other)
        }
        return false
    }
    
    public func getExponentialModel() -> InsulinModel {
        return model
    }
}


extension ExponentialInsulinModelPreset: CustomDebugStringConvertible {
    public var debugDescription: String {
        return "\(self.rawValue)(\(String(reflecting: model))"
    }
}
