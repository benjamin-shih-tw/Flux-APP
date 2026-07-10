import Foundation
import SwiftData

@Model
final class WaterRecord {
    var id: UUID
    var amountML: Int
    var timestamp: Date
    
    init(amountML: Int, timestamp: Date = Date()) {
        self.id = UUID()
        self.amountML = amountML
        self.timestamp = timestamp
    }
}
