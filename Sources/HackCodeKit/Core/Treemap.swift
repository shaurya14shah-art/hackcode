import Foundation
import CoreGraphics

/// Squarified treemap layout (Bruls, Huizing & van Wijk): tiles with areas proportional to values and aspect ratios
/// kept close to 1, so sizes compare at a glance.
public enum Treemap {
    /// Returns one rect per value (same order). Zero/negative values get `.zero`.
    public static func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
        var result = Array(repeating: CGRect.zero, count: values.count)
        let order = values.indices.filter { values[$0] > 0 && values[$0].isFinite }.sorted { values[$0] > values[$1] }
        let total = order.reduce(0) { $0 + values[$1] }
        guard total > 0, rect.width > 0, rect.height > 0 else { return result }
        let scale = Double(rect.width * rect.height) / total
        let areas = order.map { values[$0] * scale }

        var free = rect
        var row: [Int] = []          // indices into `areas`
        var i = 0

        func worst(_ sum: Double, _ mx: Double, _ mn: Double, _ side: Double) -> Double {
            guard sum > 0, mn > 0 else { return .infinity }
            return max(side * side * mx / (sum * sum), (sum * sum) / (side * side * mn))
        }

        func layout(_ row: [Int], last: Bool) {
            let sum = row.reduce(0) { $0 + areas[$1] }
            guard sum > 0 else { return }
            if free.width >= free.height {
                // Column on the left.
                let w = last ? free.width : min(free.width, CGFloat(sum / Double(free.height)))
                var y = free.minY
                for (k, a) in row.enumerated() {
                    let h = k == row.count - 1 ? free.maxY - y : CGFloat(areas[a] / Double(w))
                    result[order[a]] = CGRect(x: free.minX, y: y, width: w, height: max(0, h))
                    y += h
                }
                free = CGRect(x: free.minX + w, y: free.minY, width: max(0, free.width - w), height: free.height)
            } else {
                // Row along the top.
                let h = last ? free.height : min(free.height, CGFloat(sum / Double(free.width)))
                var x = free.minX
                for (k, a) in row.enumerated() {
                    let w = k == row.count - 1 ? free.maxX - x : CGFloat(areas[a] / Double(h))
                    result[order[a]] = CGRect(x: x, y: free.minY, width: max(0, w), height: h)
                    x += w
                }
                free = CGRect(x: free.minX, y: free.minY + h, width: free.width, height: max(0, free.height - h))
            }
        }

        var sum = 0.0, mx = 0.0, mn = Double.infinity
        while i < areas.count {
            let side = Double(min(free.width, free.height))
            let a = areas[i]
            if row.isEmpty || worst(sum + a, max(mx, a), min(mn, a), side) <= worst(sum, mx, mn, side) {
                row.append(i)
                sum += a; mx = max(mx, a); mn = min(mn, a)
                i += 1
            } else {
                layout(row, last: false)
                row = []; sum = 0; mx = 0; mn = .infinity
            }
        }
        if !row.isEmpty { layout(row, last: true) }
        return result
    }
}
