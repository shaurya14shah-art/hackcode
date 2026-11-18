import SwiftUI

class MatrixRainEngine {
    struct Column {
        var x: CGFloat
        var y: CGFloat
        var chars: [String]
        var speed: CGFloat
    }
    
    var columns: [Column] = []
    private var lastUpdate: TimeInterval = 0
    private var initializedForSize: CGSize = .zero
    
    func update(in size: CGSize, at date: Date) {
        let now = date.timeIntervalSinceReferenceDate
        if lastUpdate == 0 { lastUpdate = now }
        let dt = now - lastUpdate
        lastUpdate = now
        
        // Prevent huge jumps if the app was backgrounded
        let clampedDt = min(dt, 0.1)
        
        if initializedForSize != size {
            let columnCount = Int(size.width / 20)
            columns = (0..<columnCount).map { i in
                let chars = generateChars()
                return Column(
                    x: CGFloat(i) * 20 + 10,
                    y: CGFloat.random(in: -size.height...0),
                    chars: chars,
                    speed: CGFloat.random(in: 200...600)
                )
            }
            initializedForSize = size
        }
        
        for i in columns.indices {
            columns[i].y += columns[i].speed * CGFloat(clampedDt)
            
            if Int.random(in: 0...10) > 8 {
                let replaceIndex = Int.random(in: 0..<columns[i].chars.count)
                columns[i].chars[replaceIndex] = String(MatrixRainView.randomChar())
            }
            
            if columns[i].y > size.height {
                columns[i].chars = generateChars()
                let newHeight = CGFloat(columns[i].chars.count * 20)
                columns[i].y = -newHeight - CGFloat.random(in: 50...250)
                columns[i].speed = CGFloat.random(in: 200...600)
            }
        }
    }
    
    private func generateChars() -> [String] {
        let length = Int.random(in: 10...30)
        return (0..<length).map { _ in String(MatrixRainView.randomChar()) }
    }
}

struct MatrixRainView: View {
    var isWorking: Bool
    var themeColor: Color = .green
    @State private var engine = MatrixRainEngine()
    
    var body: some View {
        TimelineView(.animation) { timelineContext in
            Canvas { context, size in
                engine.update(in: size, at: timelineContext.date)
                
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
                
                let font = Font.system(size: 16, weight: .bold, design: .monospaced)
                
                for column in engine.columns {
                    let charCount = column.chars.count
                    for (index, char) in column.chars.enumerated() {
                        let yPos = column.y + CGFloat(index) * 20
                        
                        // Culling: don't draw characters that are off-screen
                        if yPos < -20 || yPos > size.height + 20 {
                            continue
                        }
                        
                        let isHead = (index == charCount - 1)
                        var resolvedColor: Color
                        
                        if isHead {
                            resolvedColor = isWorking ? .white : themeColor
                        } else {
                            let opacityRatio = Double(index) / Double(charCount)
                            resolvedColor = isWorking 
                                ? themeColor.opacity(opacityRatio) 
                                : themeColor.opacity(opacityRatio * 0.5)
                        }
                        
                        let text = Text(char)
                            .font(font)
                            .foregroundColor(resolvedColor)
                        
                        context.draw(text, at: CGPoint(x: column.x, y: yPos))
                    }
                }
            }
            .ignoresSafeArea()
        }
    }
    
    static func randomChar() -> Character {
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789@#$%^&*()_+{}|[]\\;':\",./<>?`~"
        return chars.randomElement() ?? "0"
    }
}
