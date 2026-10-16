// EDIDentity: give one of two identical monitors a distinct EDID serial so macOS can tell them apart.
// Apple Silicon only. The EDID is applied as a volatile override through IOAVServiceSetVirtualEDIDMode,
// so nothing is written to the monitor. The override is lost on reconnect and on wake; `watch` re-applies it.
import AppKit
import IOKit
import CoreGraphics

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> Int32
@_silgen_name("CGSCopyManagedDisplaySpaces")
func CGSCopyManagedDisplaySpaces(_ cid: Int32) -> Unmanaged<CFArray>?

@_silgen_name("IOAVServiceCreateWithService")
func IOAVServiceCreateWithService(_ alloc: CFAllocator?, _ service: io_service_t) -> Unmanaged<CFTypeRef>?
@_silgen_name("IOAVServiceCopyEDID")
func IOAVServiceCopyEDID(_ svc: CFTypeRef, _ edid: UnsafeMutablePointer<Unmanaged<CFData>?>) -> IOReturn
// mode pointing to 1 applies `edid`; (nil, nil) restores the factory EDID.
@_silgen_name("IOAVServiceSetVirtualEDIDMode")
func IOAVServiceSetVirtualEDIDMode(_ svc: CFTypeRef, _ mode: UnsafePointer<UInt32>?, _ edid: CFData?) -> IOReturn

let usage = """
usage: edidentity list
       edidentity apply --target <alphanumeric serial> [--serial <n>]
       edidentity reset --target <alphanumeric serial>
       edidentity watch --target <alphanumeric serial> [--serial <n>]

  list    show external displays with their EDID serials
  apply   override the target display's numeric serial once
  reset   restore the target display's factory EDID
  watch   stay running and re-apply whenever displays are reconnected

  --serial defaults to a value derived from the alphanumeric serial.
"""

func log(_ s: String) {
    let ts = ISO8601DateFormatter().string(from: Date())
    print("[\(ts)] \(s)")
    fflush(stdout)
}

func fail(_ s: String) -> Never {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
    exit(1)
}

struct Display {
    let service: CFTypeRef
    let edid: [UInt8]
    var alnum: String? { alnumSerial(edid) }
    var serial: UInt32 { UInt32(edid[12]) | UInt32(edid[13]) << 8 | UInt32(edid[14]) << 16 | UInt32(edid[15]) << 24 }
    var name: String? { descriptor(edid, tag: 0xFC) }
}

func descriptor(_ b: [UInt8], tag: UInt8) -> String? {
    for o in [54, 72, 90, 108] where b.count >= o + 18 {
        if b[o] == 0, b[o+1] == 0, b[o+2] == 0, b[o+3] == tag {
            let s = String(decoding: b[(o+5)..<(o+18)], as: UTF8.self)
            return s.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) }
        }
    }
    return nil
}

func alnumSerial(_ b: [UInt8]) -> String? { descriptor(b, tag: 0xFF) }

// FNV-1a, so the same alphanumeric serial always maps to the same numeric serial.
func derivedSerial(_ s: String) -> UInt32 {
    var h: UInt32 = 2166136261
    for c in s.utf8 { h = (h ^ UInt32(c)) &* 16777619 }
    return h
}

func patched(_ b: [UInt8], serial: UInt32) -> [UInt8] {
    var p = b
    for i in 0..<4 { p[12 + i] = UInt8((serial >> (8 * UInt32(i))) & 0xFF) }
    let sum = p[0..<127].reduce(0) { ($0 + Int($1)) & 0xFF }
    p[127] = UInt8((256 - sum) & 0xFF)
    return p
}

// External displays as seen by their AV services. CopyEDID returns the override while one is active.
func externalDisplays() -> [Display] {
    var it: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &it) == KERN_SUCCESS else { return [] }
    defer { IOObjectRelease(it) }
    var result: [Display] = []
    while case let svc = IOIteratorNext(it), svc != 0 {
        defer { IOObjectRelease(svc) }
        let loc = IORegistryEntryCreateCFProperty(svc, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
        guard loc == "External", let av = IOAVServiceCreateWithService(kCFAllocatorDefault, svc)?.takeRetainedValue() else { continue }
        var out: Unmanaged<CFData>?
        guard IOAVServiceCopyEDID(av, &out) == kIOReturnSuccess, let data = out?.takeRetainedValue() else { continue }
        let b = [UInt8](data as Data)
        if b.count >= 128 { result.append(Display(service: av, edid: b)) }
    }
    return result
}

func findTarget(_ alnum: String) -> Display? {
    externalDisplays().first { $0.alnum == alnum }
}

func apply(_ d: Display, serial: UInt32) -> IOReturn {
    var mode: UInt32 = 1
    return IOAVServiceSetVirtualEDIDMode(d.service, &mode, Data(patched(d.edid, serial: serial)) as CFData)
}

func hex(_ r: IOReturn) -> String { "0x" + String(UInt32(bitPattern: r), radix: 16) }

// Online displays that the Dock has not given a Space. Such a display shows windows but no
// wallpaper or menu bar; it happens when the identity changes while macOS is still waking up.
func displaysWithoutSpaces() -> [String] {
    let managed = CGSCopyManagedDisplaySpaces(CGSMainConnectionID())?.takeRetainedValue() as? [[String: Any]] ?? []
    let withSpaces = Set(managed.compactMap { m -> String? in
        guard let spaces = m["Spaces"] as? [Any], !spaces.isEmpty else { return nil }
        return m["Display Identifier"] as? String
    })
    // With "Displays have separate Spaces" off, the Dock reports one entry for all displays.
    if withSpaces.contains("Main") && managed.count == 1 { return [] }
    var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &n)
    return ids.prefix(Int(n)).compactMap { id in
        guard let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        let s = CFUUIDCreateString(nil, u) as String
        return withSpaces.contains(s) || (CGDisplayIsMain(id) != 0 && withSpaces.contains("Main")) ? nil : s
    }
}

// Watch mode: apply when the target is connected with a different serial, once the display
// configuration has been quiet for `settle` seconds. The quiet period counts from the last change,
// not from wake, so it only adds `settle` on top of however long macOS takes to bring displays back.
// Never more than 3 times in 2 minutes, so a display that rejects the override cannot cause a flicker loop.
let settle: TimeInterval = 1.5
var lastChange = Date.distantPast
var burstStart: Date?
var burstEvents = 0
var recentApplies: [Date] = []
var watchTarget = ""
var watchSerial: UInt32 = 0

func check() {
    guard Date().timeIntervalSince(lastChange) >= settle else { return }
    // Log how long the last burst of display changes took, to tune `settle` from real wakes.
    let burst = burstStart.map { String(format: " (after %d changes over %.1fs)", burstEvents, lastChange.timeIntervalSince($0)) } ?? ""
    burstStart = nil; burstEvents = 0
    guard let d = findTarget(watchTarget), d.serial != watchSerial else { return }
    recentApplies = recentApplies.filter { Date().timeIntervalSince($0) < 120 }
    guard recentApplies.count < 3 else { log("skip: applied 3 times in 2 minutes"); return }
    recentApplies.append(Date())
    log("apply \(watchTarget): serial \(d.serial) -> \(watchSerial): \(hex(apply(d, serial: watchSerial)))\(burst)")
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { verify(retry: true) }
}

// If the Dock missed the new display, restore the factory EDID; check() re-applies it after the
// configuration settles again, which the Dock then picks up as a normal connect.
func verify(retry: Bool) {
    let missing = displaysWithoutSpaces()
    guard !missing.isEmpty else { return }
    log("display without Spaces: \(missing.joined(separator: ", "))")
    guard retry, let d = findTarget(watchTarget) else { return }
    log("reset \(watchTarget) to retry: \(hex(IOAVServiceSetVirtualEDIDMode(d.service, nil, nil)))")
}

func changed() {
    lastChange = Date()
    if burstStart == nil { burstStart = lastChange }
    burstEvents += 1
    DispatchQueue.main.asyncAfter(deadline: .now() + settle + 0.1) { check() }
}

// MARK: - CLI

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { print(usage); exit(0) }
args.removeFirst()

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}

let target = option("--target")
let serialArg: UInt32? = option("--serial").map {
    guard let n = UInt32($0) else { fail("--serial must be a 32-bit unsigned integer") }
    return n
}

func requireTarget() -> String {
    guard let t = target else { fail("--target is required\n\n" + usage) }
    return t
}

switch command {
case "list":
    var ids = [CGDirectDisplayID](repeating: 0, count: 16); var n: UInt32 = 0
    CGGetOnlineDisplayList(16, &ids, &n)
    print("macOS serials: \(ids.prefix(Int(n)).map { CGDisplaySerialNumber($0) })")
    for d in externalDisplays() {
        print("\(d.name ?? "?")  alphanumeric=\(d.alnum ?? "-")  serial=\(d.serial)")
    }
    let missing = displaysWithoutSpaces()
    if !missing.isEmpty { print("displays without Spaces (no wallpaper/menu bar): \(missing.joined(separator: ", "))") }

case "apply":
    let t = requireTarget()
    guard let d = findTarget(t) else { fail("display \(t) not found") }
    let s = serialArg ?? derivedSerial(t)
    print("apply \(t): serial \(d.serial) -> \(s): \(hex(apply(d, serial: s)))")

case "reset":
    let t = requireTarget()
    guard let d = findTarget(t) else { fail("display \(t) not found") }
    print("reset \(t): \(hex(IOAVServiceSetVirtualEDIDMode(d.service, nil, nil)))")

case "watch":
    watchTarget = requireTarget()
    watchSerial = serialArg ?? derivedSerial(watchTarget)
    log("watch \(watchTarget) -> serial \(watchSerial)")
    // A background NSApplication keeps a WindowServer connection whose events deliver the
    // reconfiguration callbacks; a bare run loop does not get them.
    NSApplication.shared.setActivationPolicy(.prohibited)
    CGDisplayRegisterReconfigurationCallback({ _, _, _ in
        DispatchQueue.main.async { changed() }
    }, nil)
    // Displays come back one by one after wake; treat wake itself as a change so we wait it out.
    NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in changed() }
    NSWorkspace.shared.notificationCenter.addObserver(
        forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { _ in changed() }
    // Fallback in case a callback is missed; it is only an IORegistry lookup.
    Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in check() }
    check()
    NSApplication.shared.run()

default:
    print(usage)
    exit(command == "-h" || command == "--help" ? 0 : 1)
}
