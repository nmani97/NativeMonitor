// NativeMonitor — your Mac's volume and brightness keys, for any external monitor.
//
// Brightness and volume go to the monitor over DDC/CI (Apple Silicon IOAVService).
// Below the monitor's lowest volume step, a Core Audio process tap (macOS 14.4+) lowers the
// sound in software: no driver, and if the app quits macOS plays sound normally again.
import AppKit
import Combine
import CoreAudio
import IOKit
import ServiceManagement
import SwiftUI

let defaults = UserDefaults.standard
let debug = ProcessInfo.processInfo.environment["NATIVEMONITOR_DEBUG"] != nil

/// State changes only, never keystrokes: ~/Library/Logs/NativeMonitor.log (reset past 1 MB).
func log(_ m: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/NativeMonitor.log")
    let line = "\(Date()) \(m)\n"
    if let h = try? FileHandle(forWritingTo: url), (try? h.seekToEnd()) ?? 0 < 1_000_000 {
        h.write(line.data(using: .utf8)!); try? h.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

// MARK: - Core Audio helpers

func addr(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
          _ el: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: el)
}

func getProp<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ initial: T) -> T? {
    var a = addr(sel), v = initial, size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr ? v : nil
}

func defaultOutput() -> AudioObjectID? {
    getProp(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0))
}

func deviceUID(_ dev: AudioObjectID) -> String? { getProp(dev, kAudioDevicePropertyDeviceUID, "" as CFString).map { $0 as String } }
func deviceName(_ dev: AudioObjectID) -> String { getProp(dev, kAudioObjectPropertyName, "" as CFString).map { $0 as String } ?? "?" }

/// A monitor's speakers: DisplayPort/HDMI audio that macOS can't set the volume of.
func isMonitorAudio(_ dev: AudioObjectID) -> Bool {
    let t = getProp(dev, kAudioDevicePropertyTransportType, UInt32(0))
    guard t == kAudioDeviceTransportTypeDisplayPort || t == kAudioDeviceTransportTypeHDMI else { return false }
    for el: UInt32 in [0, 1, 2] {
        var a = addr(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, el)
        var settable: DarwinBoolean = false
        if AudioObjectHasProperty(dev, &a), AudioObjectIsPropertySettable(dev, &a, &settable) == noErr, settable.boolValue { return false }
    }
    return true
}

// MARK: - Software volume (process tap)

// Read on the audio thread: an aligned Float, a race only shifts the change by one buffer.
nonisolated(unsafe) var currentGain: Float = 1
nonisolated(unsafe) var peakIn: Float = 0, peakOut: Float = 0, renders = 0   // NATIVEMONITOR_DEBUG stats

/// All Core Audio setup runs on `queue`: creating the first tap waits for the user's permission answer.
final class Engine {
    let queue = DispatchQueue(label: "engine")
    private var tapID = AudioObjectID(0), aggID = AudioObjectID(0), procID: AudioDeviceIOProcID?
    private var device = AudioObjectID(0)
    nonisolated(unsafe) private(set) var isRunning = false

    /// Run the tap towards `dev`, or stop it with nil.
    func want(_ dev: AudioObjectID?) {
        queue.async { [self] in
            if dev == device && isRunning { return }
            stopNow()
            if let dev { start(dev) }
        }
    }

    func stop() { queue.sync { stopNow() } }

    private func start(_ out: AudioObjectID) {
        guard let outUID = deviceUID(out) else { return }
        // Exclude ourselves, or our own output would be captured again (feedback loop).
        var pid = getpid(), me = AudioObjectID(0), size = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = addr(kAudioHardwarePropertyTranslatePIDToProcessObject)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &me)

        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: me != 0 ? [me] : [])
        desc.name = "NativeMonitor"
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped   // muted only while we play it back: a crash means normal sound
        guard AudioHardwareCreateProcessTap(desc, &tapID) == noErr else { log("audio tap refused (permission?)"); tapID = 0; return }

        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "NativeMonitor",
            kAudioAggregateDeviceUIDKey: "nativemonitor-\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        guard AudioHardwareCreateAggregateDevice(agg as CFDictionary, &aggID) == noErr else { log("aggregate device failed"); stopNow(); return }
        let err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { _, inData, _, outData, _ in
            render(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData)), UnsafeMutableAudioBufferListPointer(outData))
        }
        guard err == noErr, AudioDeviceStart(aggID, procID) == noErr else { log("audio IOProc failed"); stopNow(); return }
        device = out; isRunning = true
        log("software volume on \(deviceName(out))")
    }

    private func stopNow() {
        if let p = procID { AudioDeviceStop(aggID, p); AudioDeviceDestroyIOProcID(aggID, p); procID = nil }
        if aggID != 0 { AudioHardwareDestroyAggregateDevice(aggID); aggID = 0 }
        if tapID != 0 { AudioHardwareDestroyProcessTap(tapID); tapID = 0 }
        if isRunning { log("software volume off") }
        device = 0; isRunning = false
    }
}

/// Tap → output with gain. HAL buffers are Float32; interleaved or not on either side.
func render(_ ins: UnsafeMutableAudioBufferListPointer, _ outs: UnsafeMutableAudioBufferListPointer) {
    func channels(_ l: UnsafeMutableAudioBufferListPointer) -> [(UnsafeMutablePointer<Float>, Int, Int)] {   // (base, stride, frames)
        var r: [(UnsafeMutablePointer<Float>, Int, Int)] = []
        for b in l {
            guard let d = b.mData?.assumingMemoryBound(to: Float.self), b.mNumberChannels > 0 else { continue }
            let n = Int(b.mNumberChannels), frames = Int(b.mDataByteSize) / (4 * n)
            for c in 0..<n { r.append((d + c, n, frames)) }
        }
        return r
    }
    let src = channels(ins), dst = channels(outs), g = currentGain
    renders += 1
    for (k, o) in dst.enumerated() {
        guard !src.isEmpty, k < 2 || src.count > 2 else { for f in 0..<o.2 { o.0[f * o.1] = 0 }; continue }   // beyond stereo: silence
        let s = src[k % src.count], n = min(o.2, s.2)
        for f in 0..<n { let x = s.0[f * s.1]; o.0[f * o.1] = x * g; peakIn = max(peakIn, abs(x)); peakOut = max(peakOut, abs(x * g)) }
        for f in n..<o.2 { o.0[f * o.1] = 0 }
    }
}

// MARK: - DDC/CI (Apple Silicon)

struct Monitor {
    let id: CGDirectDisplayID
    let name: String
    let service: CFTypeRef
}

final class DDC {
    typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    typealias I2C = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    private let create: Create?, write: I2C?, read: I2C?
    private let queue = DispatchQueue(label: "ddc")
    private let lock = NSLock()
    private var pending: [String: Int] = [:]   // latest value per monitor+code: only the newest is sent
    private var busySince: Date?               // set while an I2C call runs

    /// A monitor that stops answering can leave an I2C call blocked in the kernel for good.
    /// Then every DDC call is skipped: volume falls back to software, brightness keys go back to macOS.
    var isStuck: Bool { lock.withLock { busySince.map { Date().timeIntervalSince($0) > ddcTimeout } ?? false } }

    private func i2c<T>(_ body: () -> T) -> T {
        lock.withLock { busySince = Date() }
        defer { lock.withLock { busySince = nil } }
        return body()
    }

    init() {
        let h = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW)
        create = dlsym(h, "IOAVServiceCreateWithService").map { unsafeBitCast($0, to: Create.self) }
        write = dlsym(h, "IOAVServiceWriteI2C").map { unsafeBitCast($0, to: I2C.self) }
        read = dlsym(h, "IOAVServiceReadI2C").map { unsafeBitCast($0, to: I2C.self) }
    }

    /// External monitors with a DDC channel. In the registry each framebuffer is followed by its
    /// DCPAVServiceProxy; the framebuffer's vendor/product/serial identify the CGDisplay.
    func monitors() -> [Monitor] {
        guard let create else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: 16), n: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &n)
        let externals = ids.prefix(Int(n)).filter { CGDisplayIsBuiltin($0) == 0 }
        var found: [Monitor] = [], unmatched: [CFTypeRef] = []
        var it = io_iterator_t()
        guard IORegistryEntryCreateIterator(IORegistryGetRootEntry(kIOMainPortDefault), kIOServicePlane,
                                            IOOptionBits(kIORegistryIterateRecursively), &it) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(it) }
        var cls = [CChar](repeating: 0, count: 128), lastFB: [String: Any]?
        while case let e = IOIteratorNext(it), e != 0 {
            defer { IOObjectRelease(e) }
            IOObjectGetClass(e, &cls)
            switch String(cString: cls) {
            case "IOMobileFramebufferShim", "AppleCLCD2":
                let da = IORegistryEntryCreateCFProperty(e, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any]
                lastFB = da?["ProductAttributes"] as? [String: Any]
            case "DCPAVServiceProxy":
                let loc = IORegistryEntryCreateCFProperty(e, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
                guard loc == "External", let svc = create(kCFAllocatorDefault, e)?.takeRetainedValue() else { continue }
                let match = externals.first { d in
                    (lastFB?["LegacyManufacturerID"] as? Int).map { UInt32($0) } == CGDisplayVendorNumber(d)
                        && (lastFB?["ProductID"] as? Int).map { UInt32($0) } == CGDisplayModelNumber(d)
                        && ((lastFB?["SerialNumber"] as? Int).map { UInt32($0) } ?? 0) == CGDisplaySerialNumber(d)
                        && !found.contains { $0.id == d }
                }
                if let d = match { found.append(Monitor(id: d, name: screenName(d), service: svc)) } else { unmatched.append(svc) }
                lastFB = nil
            default: break
            }
        }
        // One monitor left on each side (e.g. missing EDID serial): they belong together.
        let rest = externals.filter { d in !found.contains { $0.id == d } }
        if rest.count == 1, unmatched.count == 1 { found.append(Monitor(id: rest[0], name: screenName(rest[0]), service: unmatched[0])) }
        return found
    }

    func set(_ m: Monitor, _ vcp: UInt8, _ value: Int) {
        guard !isStuck else { return }
        let key = "\(m.id)-\(vcp)"
        lock.withLock { pending[key] = value }   // never wait on `queue` here: this runs on the main thread
        queue.async { [self] in
            guard let v = lock.withLock({ pending.removeValue(forKey: key) }), let write else { return }
            var d: [UInt8] = [0x84, 0x03, vcp, UInt8(v >> 8), UInt8(v & 0xFF), 0]
            d[5] = d[0..<5].reduce(0x6E ^ 0x51, ^)
            i2c { for _ in 0..<2 { _ = write(m.service, 0x37, 0x51, &d, 6); usleep(10_000) } }   // sent twice: monitors sometimes drop one
        }
    }

    /// (current, max), or nil when the monitor doesn't answer for this code.
    func get(_ m: Monitor, _ vcp: UInt8) -> (Int, Int)? {
        guard !isStuck else { return nil }
        return withTimeout(ddcTimeout, on: queue) { [self] in i2c { readNow(m, vcp) } } ?? nil
    }

    private func readNow(_ m: Monitor, _ vcp: UInt8) -> (Int, Int)? {
        guard let write, let read else { return nil }
        var q: [UInt8] = [0x82, 0x01, vcp, 0]
        q[3] = q[0..<3].reduce(0x6E ^ 0x51, ^)
        var r = [UInt8](repeating: 0, count: 12)
        for _ in 0..<3 {
            _ = write(m.service, 0x37, 0x51, &q, 4); usleep(50_000)
            if read(m.service, 0x37, 0x51, &r, 12) == kIOReturnSuccess, r[2] == 0x02, r[3] == 0, r[4] == vcp {
                let max = Int(r[6]) << 8 | Int(r[7])
                return max > 0 ? (Int(r[8]) << 8 | Int(r[9]), max) : nil
            }
        }
        return nil
    }
}

let ddcTimeout: TimeInterval = 2

/// Runs `body` on `queue`; nil if it hasn't finished within `seconds` (it keeps running in the background).
func withTimeout<T>(_ seconds: TimeInterval, on queue: DispatchQueue, _ body: @escaping () -> T) -> T? {
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result: T?
    queue.async { result = body(); done.signal() }
    return done.wait(timeout: .now() + seconds) == .success ? result : nil
}

func screenName(_ id: CGDirectDisplayID) -> String {
    NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }?.localizedName ?? "Display \(id)"
}

// MARK: - State

let steps: Float = 16
/// Lowest steps done in software, below the monitor's own lowest volume (often too loud as a first step).
let softSteps: Float = 4
/// Shape of the monitor volume ramp (1 = linear); tune with: defaults write io.github.nmani97.NativeMonitor ddcCurve -float x
let ddcCurve = defaults.object(forKey: "ddcCurve") as? Float ?? 1

/// Level 0…1 → (monitor volume 0…max, software gain, software needed).
func mapping(_ l: Float, muted: Bool, max: Int?) -> (ddc: Int, gain: Float, soft: Bool) {
    guard let max else { return (0, muted ? 0 : l * l * l, true) }   // monitor can't set its volume: all in software
    if muted || l <= 0 { return (0, 0, false) }
    let t = softSteps / steps
    if l < t { let x = l / t; return (1, x * x * x, true) }   // cubic ≈ how loudness is heard, down to silence
    let x = (l - t) / (1 - t)
    return (1 + Int((Float(max - 1) * pow(x, ddcCurve)).rounded()), 1, false)
}

/// Where the volume keys go: the monitor whose speakers play the sound.
struct AudioTarget {
    let device: AudioObjectID
    let monitor: Monitor?
    let volumeMax: Int?   // nil: no DDC volume, software only
}

let ddc = DDC()
let engine = Engine()
var monitors: [Monitor] = []
var brightness: [CGDirectDisplayID: (value: Float, max: Int)] = [:]
var target: AudioTarget?
var level: Float = defaults.object(forKey: "level") as? Float ?? 0.5
var muted = false

func applyLevel() {
    level = min(max(level, 0), 1)
    let m = mapping(level, muted: muted, max: target?.volumeMax)
    currentGain = m.gain   // gain first: going up, no jump before the tap stops
    engine.want(target != nil && m.soft ? target!.device : nil)
    if let t = target, let mon = t.monitor, t.volumeMax != nil { ddc.set(mon, 0x62, m.ddc) }
    defaults.set(level, forKey: "level")
}

/// Re-read monitors and the sound output (DDC reads are slow: off the main thread).
func refresh() {
    DispatchQueue.global().async {
        let mons = ddc.monitors()
        var lum: [CGDirectDisplayID: (Float, Int)] = [:]
        for m in mons { if let (v, mx) = ddc.get(m, 0x10) { lum[m.id] = (Float(v) / Float(mx), mx) } }
        var t: AudioTarget?
        if let out = defaultOutput(), out != 0, isMonitorAudio(out) {
            let name = deviceName(out)
            let mon = mons.first { $0.name == name } ?? (mons.count == 1 ? mons[0] : nil)
            t = AudioTarget(device: out, monitor: mon, volumeMax: mon.flatMap { ddc.get($0, 0x62)?.1 })
        }
        DispatchQueue.main.async {
            monitors = mons
            brightness = lum.mapValues { (value: $0.0, max: $0.1) }
            target = t
            log("monitors: \(mons.map { "\($0.name) [brightness \(lum[$0.id] != nil ? "ok" : "no")]" }.joined(separator: ", ")); "
                + "sound: \(t.map { "\(deviceName($0.device)) [volume \($0.volumeMax != nil ? "monitor + software" : "software")]" } ?? "not a monitor")")
            applyLevel()
        }
    }
}

func monitorUnderMouse() -> Monitor? {
    guard let s = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }),
          let id = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { return nil }
    return monitors.first { $0.id == id && brightness[id] != nil }
}

// MARK: - On-screen display

final class HUD {
    private let panel: NSPanel, track = CALayer(), fill = CALayer(), icon = NSImageView()
    private var hideWork: DispatchWorkItem?

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .screenSaver; panel.isOpaque = false; panel.backgroundColor = .clear; panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        let v = NSVisualEffectView(frame: panel.contentView!.bounds)
        v.material = .hudWindow; v.state = .active; v.wantsLayer = true
        // maskImage rounds cleanly at any scale (cornerRadius on this material was jagged on 1x screens)
        v.maskImage = NSImage(size: NSSize(width: 37, height: 37), flipped: false) { r in
            NSColor.black.setFill(); NSBezierPath(roundedRect: r, xRadius: 18, yRadius: 18).fill(); return true
        }
        v.maskImage?.capInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        icon.frame = NSRect(x: 60, y: 70, width: 80, height: 80); icon.contentTintColor = .labelColor
        // Drawn with layers: NSProgressIndicator doesn't redraw in an inactive app's panel.
        track.frame = CGRect(x: 25, y: 30, width: 150, height: 8); track.cornerRadius = 4
        track.backgroundColor = NSColor.white.withAlphaComponent(0.2).cgColor
        fill.frame = CGRect(x: 0, y: 0, width: 0, height: 8); fill.cornerRadius = 4; fill.backgroundColor = NSColor.white.cgColor
        track.addSublayer(fill); v.addSubview(icon); v.layer?.addSublayer(track); panel.contentView = v
    }

    func show(_ symbol: String, _ value: Float) {
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 56, weight: .regular))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        fill.frame.size.width = track.bounds.width * CGFloat(value)
        CATransaction.commit()
        if let s = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
            panel.setFrameOrigin(NSPoint(x: s.frame.midX - 100, y: s.frame.minY + s.frame.height * 0.14))
        }
        panel.alphaValue = 1; panel.orderFrontRegardless(); panel.invalidateShadow()
        hideWork?.cancel()
        let w = DispatchWorkItem { [panel] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.4; panel.animator().alphaValue = 0 }) { panel.orderOut(nil) }
        }
        hideWork = w; DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: w)
    }
}

let hud = HUD()

// MARK: - Keyboard

func handleKey(_ code: Int, fine: Bool) {
    let step = 1 / steps / (fine ? 4 : 1)
    func next(_ v: Float, up: Bool) -> Float { min(max((v / step).rounded() * step + (up ? step : -step), 0), 1) }
    switch code {
    case 2, 3:   // NX_KEYTYPE_BRIGHTNESS_UP / DOWN
        guard let m = monitorUnderMouse(), let b = brightness[m.id] else { return }
        let v = next(b.value, up: code == 2)
        brightness[m.id] = (v, b.max)
        ddc.set(m, 0x10, Int((v * Float(b.max)).rounded()))
        hud.show(v == 0 ? "sun.min" : "sun.max.fill", v)
        return
    case 0, 1: muted = false; level = next(level, up: code == 0)   // NX_KEYTYPE_SOUND_UP / DOWN
    case 7: muted.toggle()                                          // NX_KEYTYPE_MUTE
    default: return
    }
    applyLevel()
    hud.show(muted || level == 0 ? "speaker.slash.fill" : level < 0.34 ? "speaker.wave.1.fill" : level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill",
             muted ? 0 : level)
}

nonisolated(unsafe) var eventTap: CFMachPort?

let tapCallback: CGEventTapCallBack = { _, type, cgEvent, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = eventTap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(cgEvent)
    }
    guard let e = NSEvent(cgEvent: cgEvent), e.type == .systemDefined, e.subtype.rawValue == 8 else { return Unmanaged.passUnretained(cgEvent) }
    let code = (e.data1 & 0xFFFF0000) >> 16, down = ((e.data1 & 0xFF00) >> 8) == 0xA
    let ours = [0, 1, 7].contains(code) ? target != nil : [2, 3].contains(code) ? monitorUnderMouse() != nil : false
    if debug && down { log("key \(code) ours=\(ours) mouse=\(monitorUnderMouse()?.name ?? "-") screens=\(NSScreen.screens.map { $0.localizedName })") }
    guard ours else { return Unmanaged.passUnretained(cgEvent) }   // built-in display, AirPods…: macOS handles it
    if down { handleKey(code, fine: e.modifierFlags.contains([.option, .shift])) }
    return nil   // swallowed: macOS no longer shows its "not available" symbol
}

func installKeyTap() -> Bool {
    guard eventTap == nil else { return true }
    guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                    eventsOfInterest: CGEventMask(1 << 14), callback: tapCallback, userInfo: nil) else { return false }   // 14 = system-defined
    eventTap = t
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
    log("keyboard control on")
    return true
}

// MARK: - Welcome window

struct WelcomeView: View {
    @State private var trusted = AXIsProcessTrusted()
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    let close: () -> Void
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Text("NativeMonitor").font(.largeTitle.bold())
                    Text("Your Mac's volume and brightness keys, for your external monitor.").foregroundStyle(.secondary)
                }
            }

            GroupBox {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: trusted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(trusted ? .green : .orange).font(.title2)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(trusted ? "Keyboard access is on" : "Allow keyboard access").font(.headline)
                        Text("NativeMonitor needs Accessibility access to receive the volume and brightness keys. "
                             + "In System Settings, turn on NativeMonitor in the list.").font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if !trusted {
                        Button("Open Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                        }
                    }
                }.padding(6)
            }

            GroupBox {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                    row("speaker.wave.2.fill", "Volume keys", "Change the monitor's volume, when the sound plays on the monitor.")
                    row("sun.max.fill", "Brightness keys", "Change the brightness of the monitor under your mouse pointer.")
                    row("speaker.slash.fill", "Mute key", "Mute and unmute the monitor.")
                    row("option", "⌥ Option + ⇧ Shift + key", "Smaller steps, like on a Mac display.")
                }.padding(6).frame(maxWidth: .infinity, alignment: .leading)
            }

            Text("At the three lowest volume steps, macOS shows a purple dot in the menu bar: NativeMonitor is lowering "
                 + "the sound itself, below the monitor's own minimum. Nothing is recorded or sent anywhere.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            Toggle("Open at login", isOn: $openAtLogin)
                .onChange(of: openAtLogin) { _, on in
                    do { try on ? SMAppService.mainApp.register() : SMAppService.mainApp.unregister() }
                    catch { openAtLogin = SMAppService.mainApp.status == .enabled }
                }

            HStack {
                Button("Quit NativeMonitor") { NSApp.terminate(nil) }
                Spacer()
                Text("Open NativeMonitor again to see this window.").font(.footnote).foregroundStyle(.secondary)
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 560)
        .onReceive(timer) { _ in trusted = AXIsProcessTrusted() }
    }

    private func row(_ symbol: String, _ title: String, _ text: String) -> some View {
        GridRow {
            Image(systemName: symbol).frame(width: 22).foregroundStyle(.tint)
            Text(title).fontWeight(.semibold)
            Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - App

final class App: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ n: Notification) {
        log("start \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? ""), accessibility=\(AXIsProcessTrusted())")
        if !installKeyTap() {
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { t in if installKeyTap() { t.invalidate() } }
        }
        if !defaults.bool(forKey: "welcomed") {
            defaults.set(true, forKey: "welcomed")
            try? SMAppService.mainApp.register()   // open at login by default; the switch is in the window
            showWelcome()
        } else if !AXIsProcessTrusted() {
            showWelcome()
        }

        refresh()
        var a = addr(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &a, .main) { _, _ in refresh() }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in refresh() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            engine.stop(); refresh()
        }
        if debug {
            Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                log(String(format: "stats tap=%d renders=%d peakIn=%.4f peakOut=%.5f gain=%.5f", engine.isRunning ? 1 : 0, renders, peakIn, peakOut, currentGain))
                peakIn = 0; peakOut = 0; renders = 0
            }
        }
    }

    /// Opening the app again (Finder, Launchpad, Spotlight) shows the window: it's the only UI.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool { showWelcome(); return false }
    func applicationWillTerminate(_ n: Notification) { engine.stop() }

    func showWelcome() {
        if window == nil {
            let w = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "NativeMonitor"; w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: WelcomeView { [weak w] in w?.close() })
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Command line: --selftest, --monitors

if CommandLine.arguments.contains("--selftest") {
    // Mixing: stereo interleaved in → two mono buffers out, with gain.
    var inBuf: [Float] = [1, -1, 0.5, -0.5]
    var outL = [Float](repeating: 9, count: 2), outR = [Float](repeating: 9, count: 2)
    currentGain = 0.5
    inBuf.withUnsafeMutableBufferPointer { ip in outL.withUnsafeMutableBufferPointer { lp in outR.withUnsafeMutableBufferPointer { rp in
        let inl = AudioBufferList.allocate(maximumBuffers: 1)
        inl[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 16, mData: ip.baseAddress)
        let outl = AudioBufferList.allocate(maximumBuffers: 2)
        outl[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 8, mData: lp.baseAddress)
        outl[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 8, mData: rp.baseAddress)
        render(inl, outl)
    }}}
    precondition(outL == [0.5, 0.25] && outR == [-0.5, -0.25], "mix: \(outL) \(outR)")
    // Volume ramp: silence → software below the monitor's step 1 → monitor volume, no gap or jump.
    precondition(mapping(0, muted: false, max: 100) == (0, 0, false) && mapping(0.8, muted: true, max: 100).ddc == 0)
    precondition(mapping(1 / 16, muted: false, max: 100) == (1, 1 / 64, true))
    precondition(mapping(softSteps / steps, muted: false, max: 100) == (1, 1, false))
    precondition(mapping(1, muted: false, max: 100) == (100, 1, false) && mapping(1, muted: false, max: 64).ddc == 64)
    let ddcs = stride(from: softSteps / steps, through: 1, by: 1 / 64).map { mapping($0, muted: false, max: 100).ddc }
    precondition(zip(ddcs, ddcs.dropFirst()).allSatisfy { $0 <= $1 }, "monitor volume not monotonic")
    // Monitor without DDC volume: everything in software, mute included.
    precondition(mapping(0.5, muted: false, max: nil) == (0, 0.125, true) && mapping(0.5, muted: true, max: nil).gain == 0)
    // A hung call gives up after the timeout instead of blocking forever.
    let t0 = Date()
    precondition(withTimeout(0.2, on: DispatchQueue(label: "t")) { sleep(2); return 1 } == nil && Date().timeIntervalSince(t0) < 1)
    precondition(withTimeout(1, on: DispatchQueue(label: "t2")) { 7 } == 7)
    print("selftest OK"); exit(0)
}

if CommandLine.arguments.contains("--monitors") {
    for m in ddc.monitors() {
        let f = { (c: UInt8) in ddc.get(m, c).map { "\($0.0)/\($0.1)" } ?? "no" }
        print("\(m.name) (display \(m.id)): brightness \(f(0x10)), volume \(f(0x62))")
    }
    exit(0)
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
