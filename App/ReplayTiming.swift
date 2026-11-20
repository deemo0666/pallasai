import Foundation

struct ReplayTiming {
    struct Span {
        let start: Double
        let answer: Double
        let end: Double
    }
    let rows: [Span]
    let duration: Double
    let turnEnds: [Int: Double]
    let footerAfter: [Int: Int]
    let turnForRow: [Int?]

    init(events: [ReplayEvent]) {
        var spans: [Span] = []
        var sourceEnd = 0.0
        var screenEnd = 0.0
        var previousStamp = 0.0
        var turnDeadline: Double?
        var turnEnd = 0.0
        var total = 0.0
        var owners: [Int?] = []
        var ends: [Int: Double] = [:], lastRow: [Int: Int] = [:], turnIndex: Int?
        for (index, event) in events.enumerated() {
            let stamp = Double(event.time) * 0.001
            let length = event.duration.map { Double($0) * 0.001 }
            let gap = stamp - sourceEnd
            let previousStart = spans.last?.start ?? 0
            let start: Double
            if spans.isEmpty { start = 0 }
            else if gap < 0 { start = previousStart + min(0.4, max(0.12, stamp - previousStamp)) }
            else {
                let ceiling = event.kind == "turn" || event.kind == "user" ? 0.9 : 1.6
                start = max(previousStart, screenEnd + min(ceiling, min(gap, 0.5) + max(0, gap - 0.5) * 0.2))
            }
            var think = 0.0, run = 0.0
            switch event.kind {
            case "reply":
                let body = Double(event.text.unicodeScalars.count)
                let reason = Double(event.detail.unicodeScalars.count)
                let count = max(1, body + reason)
                let recorded = length ?? count / 80
                if reason > 0 { think = min(2.4, max(0.6, recorded * reason / count)) }
                if body > 0 { run = max(0.3, min(6, max(body / 500, min(body / 30, recorded * body / count)))) }
            case "tool":
                run = length.map { min(2.5, max(0.25, min(0.3, $0) + max(0, $0 - 0.3) * 0.15)) } ?? 0.4
            default: break
            }
            let finish = start + think + run
            spans.append(Span(start: start, answer: start + think, end: finish))
            previousStamp = stamp
            if event.kind == "turn" {
                turnIndex = index
                turnDeadline = length.map { stamp + $0 }
                turnEnd = start
            } else {
                let originalDuration = event.kind == "tool" || event.kind == "reply" ? (length ?? 0) : 0
                sourceEnd = max(sourceEnd, stamp + originalDuration)
                screenEnd = max(screenEnd, finish)
            }
            if let turnIndex, let deadline = turnDeadline, stamp <= deadline {
                turnEnd = max(turnEnd, finish)
                ends[turnIndex] = turnEnd + 0.15
                lastRow[turnIndex] = index
                owners.append(turnIndex)
                total = max(total, turnEnd + 0.15)
            } else { owners.append(nil) }
            total = max(total, finish)
        }
        rows = spans
        duration = total
        turnEnds = ends
        turnForRow = owners
        footerAfter = Dictionary(uniqueKeysWithValues: lastRow.map { ($0.value, $0.key) })
    }
}
