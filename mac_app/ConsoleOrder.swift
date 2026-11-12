import Foundation

struct ConsoleReorderPlan {
    let ids: [String]
    let frames: [CGRect]
    let source: Int
    var destination: Int
    private let spacing: CGFloat

    init?(sourceID: String, ids: [String], frames: [String: CGRect], spacing: CGFloat = 18) {
        guard Set(ids).count == ids.count, let source = ids.firstIndex(of: sourceID),
              spacing.isFinite, spacing >= 0 else { return nil }
        var frozen = [CGRect]()
        for id in ids {
            guard let frame = frames[id], frame.size.height > 0,
                  [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height,
                   frame.minY, frame.midY, frame.maxY].allSatisfy({ $0.isFinite }) else { return nil }
            frozen.append(frame)
        }
        self.ids = ids; self.frames = frozen; self.source = source
        destination = source; self.spacing = spacing
    }

    var sourceID: String { ids[source] }
    var targetID: String? { destination == source ? nil : ids[destination] }
    var landingOffset: CGFloat {
        if destination > source { return frames[destination].maxY - frames[source].maxY }
        return frames[destination].minY - frames[source].minY
    }

    mutating func update(centerY: CGFloat) {
        guard centerY.isFinite else { return }
        var closest = destination
        // 槽位在开始拖动时冻结；等距时保留当前目标，避免让位后反向抖动。
        for index in frames.indices where abs(frames[index].midY - centerY) < abs(frames[closest].midY - centerY) {
            closest = index
        }
        destination = closest
    }

    func displacement(for id: String) -> CGFloat {
        guard let index = ids.firstIndex(of: id), index != source else { return 0 }
        let distance = frames[source].height + spacing
        if source < index && index <= destination { return -distance }
        if destination <= index && index < source { return distance }
        return 0
    }
}
