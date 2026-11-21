import Foundation
import SwiftData

@Model
final class WaterRecord {
    var id: UUID
    var amountML: Int
    var timestamp: Date
    
    init(amountML: Int, timestamp: Date = Date(), id: UUID = UUID()) {
        self.id = id
        self.amountML = amountML
        self.timestamp = timestamp
    }
}
