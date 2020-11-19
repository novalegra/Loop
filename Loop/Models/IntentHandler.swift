//
//  IntentHandler.swift
//  Loop
//
//  Created by Anna Quinlan on 11/19/20.
//  Copyright © 2020 LoopKit Authors. All rights reserved.
//

import Intents

class IntentHandler: INExtension {
    override func handler(for intent: INIntent) -> Any {
        if intent is EnableOverridePresetIntent {
            return OverrideIntentHandler()
        }
        return self
    }
}
