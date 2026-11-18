import SwiftUI

struct NetworkTopologyView: View {
    let devices: [NetworkDevice]
    @Binding var selectedDevice: NetworkDevice?
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("NETWORK TOPOLOGY")
                    .font(.system(.caption2, design: .monospaced).bold())
                    .foregroundColor(.cyan)
                Spacer()
                Text("\(devices.count) NODES")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.cyan.opacity(0.5))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.9))
            .border(Color.cyan.opacity(0.1), width: 1)
            
            GeometryReader { geometry in
                let size = geometry.size
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = min(size.width, size.height) * 0.35
                let nonGatewayDevices = devices.filter { !$0.isGateway }
                let gateway = devices.first(where: { $0.isGateway })
                
                Canvas { context, canvasSize in
                    let gatewayPos = CGPoint(x: center.x, y: center.y - radius * 0.3)
                    
                    // Draw connections
                    for (index, _) in nonGatewayDevices.enumerated() {
                        let angle = (2 * .pi * Double(index) / max(1, Double(nonGatewayDevices.count))) - .pi / 2
                        let nodePos = CGPoint(
                            x: center.x + radius * cos(angle),
                            y: center.y + radius * sin(angle) + radius * 0.15
                        )
                        
                        // Line to gateway
                        var path = Path()
                        path.move(to: gatewayPos)
                        path.addLine(to: nodePos)
                        context.stroke(path, with: .color(.cyan.opacity(0.15)), lineWidth: 1)
                    }
                    
                    // Draw device nodes
                    for (index, device) in nonGatewayDevices.enumerated() {
                        let angle = (2 * .pi * Double(index) / max(1, Double(nonGatewayDevices.count))) - .pi / 2
                        let nodePos = CGPoint(
                            x: center.x + radius * cos(angle),
                            y: center.y + radius * sin(angle) + radius * 0.15
                        )
                        
                        let nodeColor: Color = device.isLocalHost ? .green : (
                            device.openPorts.count > 3 ? .red : .cyan
                        )
                        let isSelected = selectedDevice?.id == device.id
                        let nodeSize: CGFloat = isSelected ? 14 : 10
                        
                        // Node circle
                        let nodeRect = CGRect(x: nodePos.x - nodeSize/2, y: nodePos.y - nodeSize/2, width: nodeSize, height: nodeSize)
                        context.fill(Path(ellipseIn: nodeRect), with: .color(nodeColor))
                        
                        // Glow for selected
                        if isSelected {
                            let glowRect = CGRect(x: nodePos.x - nodeSize, y: nodePos.y - nodeSize, width: nodeSize * 2, height: nodeSize * 2)
                            context.fill(Path(ellipseIn: glowRect), with: .color(nodeColor.opacity(0.2)))
                        }
                        
                        // Port dots
                        for (portIdx, _) in device.openPorts.prefix(6).enumerated() {
                            let portAngle = (2 * .pi * Double(portIdx) / 6.0)
                            let portPos = CGPoint(
                                x: nodePos.x + 16 * cos(portAngle),
                                y: nodePos.y + 16 * sin(portAngle)
                            )
                            let dotRect = CGRect(x: portPos.x - 2, y: portPos.y - 2, width: 4, height: 4)
                            context.fill(Path(ellipseIn: dotRect), with: .color(.cyan.opacity(0.4)))
                        }
                        
                        // Label
                        let label = device.isLocalHost ? "YOU" : device.ipAddress.components(separatedBy: ".").last ?? ""
                        context.draw(Text(label)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(nodeColor.opacity(0.8)),
                            at: CGPoint(x: nodePos.x, y: nodePos.y + nodeSize + 8)
                        )
                    }
                    
                    // Draw gateway node (larger)
                    if gateway != nil {
                        let gwSize: CGFloat = 18
                        let gwRect = CGRect(x: gatewayPos.x - gwSize/2, y: gatewayPos.y - gwSize/2, width: gwSize, height: gwSize)
                        context.fill(Path(ellipseIn: gwRect), with: .color(.yellow))
                        
                        // Gateway glow
                        let glowRect = CGRect(x: gatewayPos.x - gwSize, y: gatewayPos.y - gwSize, width: gwSize * 2, height: gwSize * 2)
                        context.fill(Path(ellipseIn: glowRect), with: .color(.yellow.opacity(0.15)))
                        
                        context.draw(Text("GATEWAY")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundColor(.yellow.opacity(0.8)),
                            at: CGPoint(x: gatewayPos.x, y: gatewayPos.y + gwSize + 8)
                        )
                    }
                }
            }
        }
        .border(Color.cyan.opacity(0.2), width: 1)
    }
}
