import Cocoa
import Darwin

let a = NSApplication.shared
a.setActivationPolicy(.accessory)

// MARK: - Localization
// Detect system language and use Spanish if available, otherwise English
let isSpanish = Locale.current.language.languageCode?.identifier == "es"

struct L10n {
    static let autodetect = isSpanish ? "Autodetección" : "Auto-detect"
    static let interface = isSpanish ? "Interfaz" : "Interface"
    static let show = isSpanish ? "Mostrar" : "Show"
    static let download = isSpanish ? "Descarga" : "Download"
    static let upload = isSpanish ? "Subida" : "Upload"
    static let publicIP = "IP"
    static let uptime = "Uptime"
    static let quit = isSpanish ? "Salir" : "Quit"
    static let wifi = "Wi-Fi"
    static let ethernetAdapter = isSpanish ? "Adaptador Ethernet" : "Ethernet Adapter"
}

// MARK: - Status Item
let s = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

/// Formats stats for display in menu bar using tabular digits to prevent layout shifts
/// Uses San Francisco with monospaced digits so width stays constant (e.g., 8% -> 10% doesn't jump)
func formatStats(cpu: Double, ram: Double, gpu: Double, down: Double, up: Double) -> NSAttributedString {
    let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    let attrs: [NSAttributedString.Key: Any] = [.font: font]
    
    var parts: [String] = []
    if showCPU { parts.append(String(format: "CPU %3.0f%%", cpu)) }
    if showGPU { parts.append(String(format: "GPU %3.0f%%", gpu)) }
    if showRAM { parts.append(String(format: "RAM %3.0f%%", ram)) }
    if showDown { parts.append(String(format: "↓%6.2fMb", down)) }
    if showUp { parts.append(String(format: "↑%6.2fMb", up)) }
    if showIP { parts.append("IP \(publicIP)") }
    if showUptime { parts.append("Up \(getUptime())") }
    
    let text = parts.joined(separator: "  ")
    return NSAttributedString(string: text.isEmpty ? "Ordino" : text, attributes: attrs)
}

s.button?.attributedTitle = formatStats(cpu: 0, ram: 0, gpu: 0, down: 0, up: 0)

// MARK: - State Variables
var lastIn: UInt64 = 0
var lastOut: UInt64 = 0
var selectedInterface = "auto" // "auto" picks interface with most traffic
var lastBytesByInterface: [String: (inBytes: UInt64, outBytes: UInt64)] = [:]
var prevCpuInfo: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?

// Visibility options
var showCPU = true
var showGPU = true
var showRAM = true
var showDown = true
var showUp = true
var showIP = false
var showUptime = false

// Public IP cache (updated every 5 minutes)
var publicIP = "..."
var lastIPUpdate: Date?

// MARK: - GPU Cache
// Cache GPU value to avoid blocking main thread with ioreg process every tick
let gpuQueue = DispatchQueue(label: "ordino.gpu", qos: .utility)
var gpuUsageCached: Double = 0

// MARK: - System Stats Functions

/// Returns CPU usage percentage by comparing tick counts between calls
/// Based on host_processor_info() - same approach used by Activity Monitor
func getCPU() -> Double {
    var numCPUs: natural_t = 0
    var cpuInfo: processor_info_array_t?
    var numCpuInfo: mach_msg_type_number_t = 0
    
    let err = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUs, &cpuInfo, &numCpuInfo)
    guard err == KERN_SUCCESS, let info = cpuInfo else { return 0 }
    
    var totalUser: UInt64 = 0
    var totalSystem: UInt64 = 0
    var totalIdle: UInt64 = 0
    var totalNice: UInt64 = 0
    
    for i in 0..<Int(numCPUs) {
        let offset = Int(CPU_STATE_MAX) * i
        totalUser += UInt64(info[offset + Int(CPU_STATE_USER)])
        totalSystem += UInt64(info[offset + Int(CPU_STATE_SYSTEM)])
        totalIdle += UInt64(info[offset + Int(CPU_STATE_IDLE)])
        totalNice += UInt64(info[offset + Int(CPU_STATE_NICE)])
    }
    
    vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(numCpuInfo) * vm_size_t(MemoryLayout<integer_t>.size))
    
    var cpuUsage: Double = 0
    if let prev = prevCpuInfo {
        let userDiff = totalUser - prev.user
        let systemDiff = totalSystem - prev.system
        let idleDiff = totalIdle - prev.idle
        let niceDiff = totalNice - prev.nice
        let total = userDiff + systemDiff + idleDiff + niceDiff
        if total > 0 {
            cpuUsage = Double(userDiff + systemDiff + niceDiff) / Double(total) * 100
        }
    }
    prevCpuInfo = (totalUser, totalSystem, totalIdle, totalNice)
    return cpuUsage
}

/// Returns RAM usage percentage using vm_statistics64
/// Calculates: (active + wired + compressed) / total
func getRAM() -> Double {
    var stats = vm_statistics64()
    var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &stats) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }
    
    let pageSize = UInt64(vm_kernel_page_size)
    let active = UInt64(stats.active_count) * pageSize
    let inactive = UInt64(stats.inactive_count) * pageSize
    let wired = UInt64(stats.wire_count) * pageSize
    let compressed = UInt64(stats.compressor_page_count) * pageSize
    // More stable: don't subtract "inactive" (can fluctuate and doesn't equal free)
    _ = inactive
    let used = active + wired + compressed
    
    var size: UInt64 = 0
    var sizeLen = MemoryLayout<UInt64>.size
    sysctlbyname("hw.memsize", &size, &sizeLen, nil, 0)
    
    return Double(used) / Double(size) * 100
}

/// Returns GPU usage percentage by parsing ioreg output
/// Note: May return 0 on some systems where GPU stats aren't exposed
func getGPU() -> Double {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/ioreg")
    task.arguments = ["-r", "-d", "1", "-c", "IOAccelerator", "-n", "gpu-parent"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8) {
            for line in output.components(separatedBy: "\n") {
                if line.contains("PerformanceStatistics") || line.contains("Device Utilization") || line.contains("GPU Activity") {
                    let parts = line.components(separatedBy: "=")
                    if parts.count >= 2 {
                        let numStr = parts[1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "%", with: "").replacingOccurrences(of: "\"", with: "")
                        if let val = Double(numStr), val <= 100 {
                            return val
                        }
                    }
                }
            }
        }
    } catch {}
    return 0
}

/// Fetches public IP from ip.me (Proton/Swiss privacy-focused service)
/// Cached for 5 minutes to avoid excessive requests
func fetchPublicIP() {
    // Only update every 5 minutes
    if let lastUpdate = lastIPUpdate, Date().timeIntervalSince(lastUpdate) < 300 {
        return
    }
    
    guard let url = URL(string: "https://ip.me") else { return }
    
    var request = URLRequest(url: url)
    request.setValue("curl/7.64.1", forHTTPHeaderField: "User-Agent")
    request.timeoutInterval = 10
    
    let task = URLSession.shared.dataTask(with: request) { data, response, error in
        guard let data = data,
              let ip = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !ip.isEmpty else {
            return
        }
        DispatchQueue.main.async {
            publicIP = ip
            lastIPUpdate = Date()
        }
    }
    task.resume()
}

/// Returns system uptime as formatted string (e.g., "2d 5h" or "5h 23m")
/// Uses sysctl to get boot time
func getUptime() -> String {
    var boottime = timeval()
    var size = MemoryLayout<timeval>.size
    var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
    
    guard sysctl(&mib, 2, &boottime, &size, nil, 0) == 0 else {
        return "?"
    }
    
    let bootDate = Date(timeIntervalSince1970: Double(boottime.tv_sec))
    let uptime = Date().timeIntervalSince(bootDate)
    
    let days = Int(uptime) / 86400
    let hours = (Int(uptime) % 86400) / 3600
    let minutes = (Int(uptime) % 3600) / 60
    
    if days > 0 {
        return "\(days)d \(hours)h"
    } else {
        return "\(hours)h \(minutes)m"
    }
}

// MARK: - Network Functions
// Network byte reading uses getifaddrs() with if_data structure
// Same approach used by Stats app (github.com/exelban/stats)

/// Returns list of network interfaces with traffic (filters out virtual/unused)
func getInterfaces() -> [(name: String, label: String)] {
    var interfaces: [(name: String, label: String)] = []
    var ifap: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifap) == 0 else { return interfaces }
    var seen: Set<String> = []
    var ptr = ifap
    while ptr != nil {
        let iface = ptr!.pointee
        let name = String(cString: iface.ifa_name)
        if iface.ifa_addr.pointee.sa_family == UInt8(AF_LINK), !seen.contains(name) {
            // Only en* interfaces (physical network)
            if name.hasPrefix("en"), let num = Int(name.dropFirst(2)), num >= 0, num <= 9 {
                // Only show interfaces with traffic (filters virtual/unused)
                let (inBytes, outBytes) = getBytes(for: name)
                if inBytes > 0 || outBytes > 0 {
                    seen.insert(name)
                    let label: String
                    if name == "en0" {
                        label = "\(L10n.wifi) (\(name))"
                    } else {
                        label = "\(L10n.ethernetAdapter) (\(name))"
                    }
                    interfaces.append((name: name, label: label))
                }
            }
        }
        ptr = iface.ifa_next
    }
    freeifaddrs(ifap)
    return interfaces.sorted { $0.name < $1.name }
}

/// Returns bytes in/out for a specific interface
func getBytes(for interfaceName: String) -> (UInt64, UInt64) {
    var ifap: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifap) == 0 else { return (0,0) }
    var i: UInt64 = 0
    var o: UInt64 = 0
    var ptr = ifap
    while ptr != nil {
        let iface = ptr!.pointee
        let name = String(cString: iface.ifa_name)
        if iface.ifa_addr.pointee.sa_family == UInt8(AF_LINK) && name == interfaceName {
            let data = unsafeBitCast(iface.ifa_data, to: UnsafeMutablePointer<if_data>.self)
            i = UInt64(data.pointee.ifi_ibytes)
            o = UInt64(data.pointee.ifi_obytes)
            break
        }
        ptr = iface.ifa_next
    }
    freeifaddrs(ifap)
    return (i, o)
}

/// Picks interface with most traffic in last interval (for auto mode)
func pickAutoInterface() -> String {
    let ifaces = getInterfaces().map { $0.name }
    var best: (name: String, delta: UInt64) = (name: ifaces.first ?? "en0", delta: 0)
    for name in ifaces {
        let (i, o) = getBytes(for: name)
        let prev = lastBytesByInterface[name] ?? (inBytes: i, outBytes: o)
        let dIn = i > prev.inBytes ? i - prev.inBytes : 0
        let dOut = o > prev.outBytes ? o - prev.outBytes : 0
        let delta = dIn + dOut
        if delta > best.delta {
            best = (name: name, delta: delta)
        }
    }
    return best.name
}

/// Returns bytes for selected interface (or auto-detected one)
func getSelectedBytes() -> (inBytes: UInt64, outBytes: UInt64, interfaceName: String) {
    let name = (selectedInterface == "auto") ? pickAutoInterface() : selectedInterface
    let (i, o) = getBytes(for: name)
    return (i, o, name)
}

// MARK: - Menu Handler
class MenuHandler: NSObject {
    @objc func selectInterface(_ sender: NSMenuItem) {
        selectedInterface = sender.representedObject as! String
        lastIn = 0
        lastOut = 0
        lastBytesByInterface.removeAll()
        let sel = getSelectedBytes()
        lastIn = sel.inBytes
        lastOut = sel.outBytes
        // Initialize delta cache for auto mode
        for iface in getInterfaces().map({ $0.name }) {
            let (i, o) = getBytes(for: iface)
            lastBytesByInterface[iface] = (i, o)
        }
        updateMenu()
    }
    
    @objc func toggleCPU() { showCPU.toggle(); updateMenu() }
    @objc func toggleGPU() { showGPU.toggle(); updateMenu() }
    @objc func toggleRAM() { showRAM.toggle(); updateMenu() }
    @objc func toggleDown() { showDown.toggle(); updateMenu() }
    @objc func toggleUp() { showUp.toggle(); updateMenu() }
    @objc func toggleIP() { 
        showIP.toggle()
        if showIP { fetchPublicIP() }
        updateMenu()
    }
    @objc func toggleUptime() { showUptime.toggle(); updateMenu() }
}

let handler = MenuHandler()
let m = NSMenu()

/// Builds the menu with localized strings
func updateMenu() {
    m.removeAllItems()
    
    // Interface submenu
    let interfaceItem = NSMenuItem(title: L10n.interface, action: nil, keyEquivalent: "")
    let interfaceSubmenu = NSMenu()
    
    let autoItem = NSMenuItem(title: L10n.autodetect, action: #selector(MenuHandler.selectInterface(_:)), keyEquivalent: "")
    autoItem.target = handler
    autoItem.representedObject = "auto"
    if selectedInterface == "auto" { autoItem.state = .on }
    interfaceSubmenu.addItem(autoItem)
    
    interfaceSubmenu.addItem(NSMenuItem.separator())
    
    for iface in getInterfaces() {
        let item = NSMenuItem(title: iface.label, action: #selector(MenuHandler.selectInterface(_:)), keyEquivalent: "")
        item.target = handler
        item.representedObject = iface.name
        if selectedInterface == iface.name {
            item.state = .on
        }
        interfaceSubmenu.addItem(item)
    }
    
    interfaceItem.submenu = interfaceSubmenu
    m.addItem(interfaceItem)
    
    // Visibility submenu
    let showItem = NSMenuItem(title: L10n.show, action: nil, keyEquivalent: "")
    let showSubmenu = NSMenu()
    
    let cpuItem = NSMenuItem(title: "CPU", action: #selector(MenuHandler.toggleCPU), keyEquivalent: "")
    cpuItem.target = handler
    cpuItem.state = showCPU ? .on : .off
    showSubmenu.addItem(cpuItem)
    
    let gpuItem = NSMenuItem(title: "GPU", action: #selector(MenuHandler.toggleGPU), keyEquivalent: "")
    gpuItem.target = handler
    gpuItem.state = showGPU ? .on : .off
    showSubmenu.addItem(gpuItem)
    
    let ramItem = NSMenuItem(title: "RAM", action: #selector(MenuHandler.toggleRAM), keyEquivalent: "")
    ramItem.target = handler
    ramItem.state = showRAM ? .on : .off
    showSubmenu.addItem(ramItem)
    
    showSubmenu.addItem(NSMenuItem.separator())
    
    let downItem = NSMenuItem(title: L10n.download, action: #selector(MenuHandler.toggleDown), keyEquivalent: "")
    downItem.target = handler
    downItem.state = showDown ? .on : .off
    showSubmenu.addItem(downItem)
    
    let upItem = NSMenuItem(title: L10n.upload, action: #selector(MenuHandler.toggleUp), keyEquivalent: "")
    upItem.target = handler
    upItem.state = showUp ? .on : .off
    showSubmenu.addItem(upItem)
    
    showSubmenu.addItem(NSMenuItem.separator())
    
    let ipItem = NSMenuItem(title: L10n.publicIP, action: #selector(MenuHandler.toggleIP), keyEquivalent: "")
    ipItem.target = handler
    ipItem.state = showIP ? .on : .off
    showSubmenu.addItem(ipItem)
    
    let uptimeItem = NSMenuItem(title: L10n.uptime, action: #selector(MenuHandler.toggleUptime), keyEquivalent: "")
    uptimeItem.target = handler
    uptimeItem.state = showUptime ? .on : .off
    showSubmenu.addItem(uptimeItem)
    
    showItem.submenu = showSubmenu
    m.addItem(showItem)
    
    m.addItem(NSMenuItem.separator())
    let quitItem = NSMenuItem(title: L10n.quit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    m.addItem(quitItem)
}

// MARK: - Initialization
_ = getCPU() // First call to initialize prevCpuInfo

// Initialize network cache
for iface in getInterfaces().map({ $0.name }) {
    let (i, o) = getBytes(for: iface)
    lastBytesByInterface[iface] = (i, o)
}
let sel0 = getSelectedBytes()
lastIn = sel0.inBytes
lastOut = sel0.outBytes
updateMenu()
s.menu = m

func getGpuCached() -> Double {
    gpuQueue.sync { gpuUsageCached }
}

// MARK: - Timers

// GPU updater (every 3s) in background to avoid blocking main thread
let gpuTimer = DispatchSource.makeTimerSource(queue: gpuQueue)
gpuTimer.schedule(deadline: .now(), repeating: .seconds(3), leeway: .milliseconds(250))
gpuTimer.setEventHandler {
    let val = getGPU()
    gpuUsageCached = val
}
gpuTimer.resume()

// Main timer (1s) for CPU/RAM/NET and updating status item
var lastAutoInterface = ""
let mainTimer = DispatchSource.makeTimerSource(queue: .main)
mainTimer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(200))
mainTimer.setEventHandler {
    let cpu = getCPU()
    let ram = getRAM()
    let gpu = getGpuCached()
    
    // Refresh public IP if enabled (cached for 5 min)
    if showIP { fetchPublicIP() }

    let sel = getSelectedBytes()
    let currentInterface = sel.interfaceName
    let i = sel.inBytes
    let o = sel.outBytes

    var downMbps: Double = 0
    var upMbps: Double = 0

    if selectedInterface == "auto" {
        // In auto mode, use per-interface cache to avoid jumps when switching
        let prev = lastBytesByInterface[currentInterface] ?? (inBytes: i, outBytes: o)
        downMbps = i > prev.inBytes ? Double(i - prev.inBytes) * 8 / 1_000_000 : 0
        upMbps = o > prev.outBytes ? Double(o - prev.outBytes) * 8 / 1_000_000 : 0
        
        // Update cache for all interfaces
        for iface in getInterfaces().map({ $0.name }) {
            let (bi, bo) = getBytes(for: iface)
            lastBytesByInterface[iface] = (bi, bo)
        }
    } else {
        // Manual mode: use lastIn/lastOut
        downMbps = i > lastIn ? Double(i - lastIn) * 8 / 1_000_000 : 0
        upMbps = o > lastOut ? Double(o - lastOut) * 8 / 1_000_000 : 0
        lastIn = i
        lastOut = o
    }
    
    // Filter absurd values (>10 Gbps = counter error)
    if downMbps > 10000 { downMbps = 0 }
    if upMbps > 10000 { upMbps = 0 }
    
    s.button?.attributedTitle = formatStats(cpu: cpu, ram: ram, gpu: gpu, down: downMbps, up: upMbps)
}
mainTimer.resume()

a.run()
