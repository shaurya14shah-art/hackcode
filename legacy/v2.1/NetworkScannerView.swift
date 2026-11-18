import SwiftUI

struct NetworkScannerView: View {
    @StateObject private var scanner = NetworkScanner()
    @State private var selectedDevice: NetworkDevice? = nil
    
    var body: some View {
        VStack(spacing: 0) {
            // Scan Controls Header
            scanControlsBar
            
            Divider().frame(height: 1).background(Color.cyan.opacity(0.3))
            
            // Main Content: Device List + Detail
            HSplitView {
                deviceListView
                    .frame(minWidth: 350)
                
                VStack(spacing: 0) {
                    NetworkTopologyView(devices: scanner.session.devices, selectedDevice: $selectedDevice)
                        .frame(minHeight: 200)
                    
                    Divider().background(Color.cyan.opacity(0.2))
                    
                    deviceDetailView
                        .frame(minHeight: 200)
                }
                .frame(minWidth: 350)
            }
            
            Divider().frame(height: 1).background(Color.cyan.opacity(0.3))
            
            // Scan Log
            scanLogView
                .frame(minHeight: 100, maxHeight: 180)
        }
        .background(Color.black.opacity(0.85))
        .environment(\.colorScheme, .dark)
    }
    
    // MARK: - Scan Controls
    
    private var scanControlsBar: some View {
        HStack(spacing: 16) {
            Text("NET.SCAN")
                .font(.system(.subheadline, design: .monospaced).bold())
                .foregroundColor(.cyan)
            
            Text("//")
                .foregroundColor(.cyan.opacity(0.3))
            
            Text(scanner.session.scanPhase)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.cyan.opacity(0.7))
            
            Spacer()
            
            if scanner.session.isScanning {
                // Progress
                HStack(spacing: 8) {
                    ProgressView(value: scanner.session.progress)
                        .progressViewStyle(LinearProgressViewStyle(tint: .cyan))
                        .frame(width: 120)
                    
                    Text("\(Int(scanner.session.progress * 100))%")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.cyan)
                }
                
                Button(action: { scanner.cancelScan() }) {
                    Text("[ CANCEL ]")
                        .font(.system(.caption, design: .monospaced).bold())
                        .foregroundColor(.red)
                }
                .buttonStyle(PlainButtonStyle())
            } else {
                Text("\(scanner.session.devices.count) DEVICES")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.cyan.opacity(0.5))
                
                Button(action: {
                    Task { await scanner.startScan() }
                }) {
                    Text("[ SCAN NETWORK ]")
                        .font(.system(.caption, design: .monospaced).bold())
                        .foregroundColor(.cyan)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .overlay(Rectangle().stroke(Color.cyan.opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.9))
    }
    
    // MARK: - Device List
    
    private var deviceListView: some View {
        VStack(spacing: 0) {
            // Column headers
            HStack {
                Text("STATUS")
                    .frame(width: 60, alignment: .leading)
                Text("IP ADDRESS")
                    .frame(width: 130, alignment: .leading)
                Text("HOSTNAME")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("PORTS")
                    .frame(width: 50, alignment: .trailing)
            }
            .font(.system(.caption2, design: .monospaced).bold())
            .foregroundColor(.cyan.opacity(0.5))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.5))
            
            Divider().background(Color.cyan.opacity(0.2))
            
            if scanner.session.devices.isEmpty && !scanner.session.isScanning {
                VStack(spacing: 8) {
                    Image(systemName: "wifi.router")
                        .font(.system(size: 36))
                        .foregroundColor(.cyan.opacity(0.2))
                    Text("NO DEVICES DISCOVERED")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.cyan.opacity(0.3))
                    Text("Click SCAN NETWORK to begin")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.cyan.opacity(0.2))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(scanner.session.devices) { device in
                            deviceRow(device)
                                .onTapGesture {
                                    selectedDevice = device
                                }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .border(Color.cyan.opacity(0.2), width: 1)
    }
    
    private func deviceRow(_ device: NetworkDevice) -> some View {
        HStack {
            // Status indicator
            Circle()
                .fill(device.isLocalHost ? Color.green : (device.isGateway ? Color.yellow : Color.cyan))
                .frame(width: 8, height: 8)
                .frame(width: 60, alignment: .leading)
            
            Text(device.ipAddress)
                .frame(width: 130, alignment: .leading)
                .foregroundColor(.white)
            
            HStack(spacing: 4) {
                Text(device.hostname)
                    .foregroundColor(.cyan.opacity(0.8))
                if device.isGateway {
                    Text("GW")
                        .font(.system(.caption2, design: .monospaced).bold())
                        .foregroundColor(.black)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.yellow)
                }
                if device.isLocalHost {
                    Text("YOU")
                        .font(.system(.caption2, design: .monospaced).bold())
                        .foregroundColor(.black)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.green)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            
            Text("\(device.openPorts.count)")
                .frame(width: 50, alignment: .trailing)
                .foregroundColor(device.openPorts.isEmpty ? .cyan.opacity(0.3) : .cyan)
        }
        .font(.system(.caption, design: .monospaced))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(selectedDevice?.id == device.id ? Color.cyan.opacity(0.15) : Color.clear)
        .border(selectedDevice?.id == device.id ? Color.cyan.opacity(0.4) : Color.clear, width: 1)
    }
    
    // MARK: - Device Detail Panel
    
    private var deviceDetailView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let device = selectedDevice {
                // Device info header
                VStack(alignment: .leading, spacing: 8) {
                    Text(device.hostname.uppercased())
                        .font(.system(.headline, design: .monospaced).bold())
                        .foregroundColor(.cyan)
                    
                    HStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("IP").font(.system(.caption2, design: .monospaced)).foregroundColor(.cyan.opacity(0.5))
                            Text(device.ipAddress).font(.system(.caption, design: .monospaced)).foregroundColor(.white)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("MAC").font(.system(.caption2, design: .monospaced)).foregroundColor(.cyan.opacity(0.5))
                            Text(device.macAddress).font(.system(.caption, design: .monospaced)).foregroundColor(.white)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("VENDOR").font(.system(.caption2, design: .monospaced)).foregroundColor(.cyan.opacity(0.5))
                            Text(device.vendor).font(.system(.caption, design: .monospaced)).foregroundColor(.white)
                        }
                    }
                }
                .padding(16)
                .background(Color.black.opacity(0.5))
                
                Divider().background(Color.cyan.opacity(0.2))
                
                // Open ports list
                Text("OPEN PORTS (\(device.openPorts.count))")
                    .font(.system(.caption, design: .monospaced).bold())
                    .foregroundColor(.cyan)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 4)
                
                if device.openPorts.isEmpty {
                    Text("No open ports detected")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.cyan.opacity(0.3))
                        .padding(16)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(device.openPorts) { port in
                                HStack {
                                    Circle()
                                        .fill(Color.cyan)
                                        .frame(width: 6, height: 6)
                                    Text("\(port.port)")
                                        .foregroundColor(.white)
                                        .frame(width: 60, alignment: .leading)
                                    Text(port.service)
                                        .foregroundColor(.cyan.opacity(0.8))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text("OPEN")
                                        .foregroundColor(.green)
                                        .frame(width: 50, alignment: .trailing)
                                }
                                .font(.system(.caption, design: .monospaced))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
                
                Spacer()
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: 36))
                        .foregroundColor(.cyan.opacity(0.15))
                    Text("SELECT A DEVICE")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.cyan.opacity(0.3))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .border(Color.cyan.opacity(0.2), width: 1)
    }
    
    // MARK: - Scan Log
    
    private var scanLogView: some View {
        VStack(spacing: 0) {
            HStack {
                Text("SCAN LOG")
                    .font(.system(.caption2, design: .monospaced).bold())
                    .foregroundColor(.cyan)
                Spacer()
                
                if scanner.session.isScanning {
                    Circle()
                        .fill(Color.cyan)
                        .frame(width: 6, height: 6)
                        .opacity(0.8)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.black.opacity(0.9))
            .border(Color.cyan.opacity(0.1), width: 1)
            
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(Array(scanner.scanLog.enumerated()), id: \.offset) { index, log in
                            Text(log)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.cyan.opacity(0.7))
                                .id(index)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                }
                .onChange(of: scanner.scanLog.count) { _, _ in
                    if !scanner.scanLog.isEmpty {
                        withAnimation {
                            proxy.scrollTo(scanner.scanLog.count - 1, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .border(Color.cyan.opacity(0.2), width: 1)
    }
}
