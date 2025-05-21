//
//  Item.swift
//  random-player
//
//  Created by 강동호 on 5/21/25.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
