// WiZard — open-source macOS menu bar app for controlling WiZ bulbs over UDP.
// Mirrors the protocol and ~/.wizctl.json config of the `w` CLI.
//
// Features:
//   • State rows in the menu (3 built-ins: Cool / Warm / Nightlight, plus any
//     number of user states — white temp, RGB color, or WiZ scenes) + Off.
//   • Preferences window (⌘,): live lightbulb preview drawn in-app, state
//     editor (create / edit / delete / reset), one-click WiZ scene presets
//     (Party/disco, Fireplace, Ocean, …), and bulb rename / switch / discovery.

import AppKit
import Darwin

// Launchd-launched processes get default SIGPIPE handling; a connected-UDP send
// after an ICMP error can raise it and kill the app. Ignore it.
signal(SIGPIPE, SIG_IGN)

let WIZ_PORT: UInt16 = 38899
let CONFIG_PATH = NSString("~/").expandingTildeInPath + ".wizctl.json"
let MENU_WIDTH: CGFloat = 300
let OFF_ID = "builtin:off"

// MARK: - Config (same file as `w`; extra keys are preserved by the CLI)

func loadConfig() -> [String: Any] {
    if let data = FileManager.default.contents(atPath: CONFIG_PATH),
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
        return obj
    }
    return ["ip": "192.168.29.194", "mac": "cc4085624856"]
}

func saveConfig(_ cfg: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys])
    else { return }
    try? data.write(to: URL(fileURLWithPath: CONFIG_PATH), options: .atomic)
}

// MARK: - UDP helpers (blocking; call from a background queue)

func makeAddr(_ ip: String, _ port: UInt16) -> sockaddr_in? {
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    let ok = ip.withCString { inet_pton(AF_INET, $0, &addr.sin_addr) }
    return ok == 1 ? addr : nil
}

func connectSock(_ fd: Int32, to addr: inout sockaddr_in) -> Bool {
    withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
        }
    }
}

func ipString(_ addr: inout sockaddr_in) -> String {
    var host = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    inet_ntop(AF_INET, &addr.sin_addr, &host, socklen_t(INET_ADDRSTRLEN))
    return String(cString: host)
}

func request(_ ip: String, payload: [String: Any], timeoutMs: Int32 = 300,
             attempts: Int = 2) -> [String: Any]? {
    guard var addr = makeAddr(ip, WIZ_PORT) else { return nil }
    guard let raw = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
    for _ in 0..<attempts {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: 0, tv_usec: timeoutMs * 1000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        guard connectSock(fd, to: &addr) else { continue }
        let sent = raw.withUnsafeBytes { send(fd, $0.baseAddress, raw.count, 0) }
        guard sent == raw.count else { continue }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = recv(fd, &buf, buf.count, 0)
        guard n > 0 else { continue }
        if let obj = (try? JSONSerialization.jsonObject(with: Data(buf.prefix(n)))) as? [String: Any],
           let result = obj["result"] as? [String: Any] {
            return result
        }
    }
    return nil
}

func localIP() -> String? {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var probe = sockaddr_in()
    probe.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    probe.sin_family = sa_family_t(AF_INET)
    probe.sin_port = UInt16(9).bigEndian
    let ok = "192.168.29.1".withCString { inet_pton(AF_INET, $0, &probe.sin_addr) }
    guard ok == 1, connectSock(fd, to: &probe) else { return nil }
    var name = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let r = withUnsafeMutablePointer(to: &name) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
    }
    guard r == 0 else { return nil }
    return ipString(&name)
}

func collect(fd: Int32, until deadline: Date, into found: inout [String: [String: Any]]) {
    while Date() < deadline {
        var from = sockaddr_in()
        var fromlen = socklen_t(MemoryLayout<sockaddr_in>.size)
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = withUnsafeMutablePointer(to: &from) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(fd, &buf, buf.count, 0, $0, &fromlen)
            }
        }
        guard n > 0 else { continue }
        let ip = ipString(&from)
        if let obj = (try? JSONSerialization.jsonObject(with: Data(buf.prefix(n)))) as? [String: Any],
           let result = obj["result"] as? [String: Any] {
            found[ip] = result
        }
    }
}

/// Broadcast first, then one /24 unicast sweep — same strategy as `w`.
func discover() -> [(ip: String, result: [String: Any])] {
    var found: [String: [String: Any]] = [:]
    guard let query = try? JSONSerialization.data(
        withJSONObject: ["id": 90, "method": "getPilot", "params": [String: Any]()]) else { return [] }
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { return [] }
    defer { close(fd) }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &one, socklen_t(MemoryLayout<Int32>.size))

    func sendAll(_ targets: [String]) {
        for ip in targets {
            guard var a = makeAddr(ip, WIZ_PORT) else { continue }
            withUnsafeMutablePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { p in
                    _ = query.withUnsafeBytes {
                        sendto(fd, $0.baseAddress, query.count, 0, p, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }

    // Phase 1: broadcast
    var tv = timeval(tv_sec: 0, tv_usec: 100_000)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    sendAll(["255.255.255.255"])
    collect(fd: fd, until: Date().addingTimeInterval(0.55), into: &found)

    // Phase 2: /24 sweep, only if broadcast was swallowed
    if found.isEmpty {
        let me = localIP() ?? "192.168.29.82"
        let parts = me.split(separator: ".")
        if parts.count == 4 {
            let prefix = parts[0...2].joined(separator: ".")
            var targets: [String] = []
            for i in 1...254 { targets.append("\(prefix).\(i)") }
            tv = timeval(tv_sec: 0, tv_usec: 80_000)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            sendAll(targets)
            collect(fd: fd, until: Date().addingTimeInterval(0.65), into: &found)
        }
    }
    return found.map { (ip: $0.key, result: $0.value) }.sorted { $0.ip < $1.ip }
}

// MARK: - States

/// The three built-in ON states. Defaults are hardcoded; overrides are stored
/// in config. Off is not a Mode, just a special state id.
enum Mode: String, CaseIterable {
    case cool, warm, night

    var defaultParams: [String: Any] {
        switch self {
        case .cool:  return ["temp": 6500, "dimming": 100]
        case .warm:  return ["temp": 3500, "dimming": 70]
        case .night: return ["sceneId": 14, "dimming": 100]
        }
    }

    var title: String {
        switch self {
        case .cool:  return "Cool"
        case .warm:  return "Warm"
        case .night: return "Nightlight"
        }
    }

    var id: String { "builtin:\(rawValue)" }
}

/// Uniform model for one state (built-in, custom, or off).
struct StateEntry {
    let id: String
    let name: String
    let params: [String: Any]   // without "state"; applied with state:true
    let isBuiltin: Bool

    static func off() -> StateEntry {
        StateEntry(id: OFF_ID, name: "Off", params: ["state": false], isBuiltin: true)
    }
}

// MARK: - WiZ scene presets (sbidy/pywizlight scene mapping)

struct ScenePreset {
    let id: Int
    let name: String
    let color: NSColor
}

let SCENE_PRESETS: [ScenePreset] = {
    func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
        NSColor(calibratedRed: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }
    return [
        ScenePreset(id: 1,  name: "Ocean",        color: c(46, 100, 254)),
        ScenePreset(id: 2,  name: "Romance",      color: c(242, 105, 157)),
        ScenePreset(id: 3,  name: "Sunset",       color: c(255, 116, 64)),
        ScenePreset(id: 4,  name: "Party",        color: c(190, 84, 255)),
        ScenePreset(id: 5,  name: "Fireplace",    color: c(242, 88, 26)),
        ScenePreset(id: 6,  name: "Cozy",         color: c(255, 184, 118)),
        ScenePreset(id: 7,  name: "Forest",       color: c(54, 190, 90)),
        ScenePreset(id: 8,  name: "Pastel",       color: c(219, 180, 240)),
        ScenePreset(id: 9,  name: "Wake-up",      color: c(255, 190, 140)),
        ScenePreset(id: 10, name: "Bedtime",      color: c(96, 118, 216)),
        ScenePreset(id: 11, name: "Warm white",   color: c(255, 199, 143)),
        ScenePreset(id: 12, name: "Daylight",     color: c(255, 250, 233)),
        ScenePreset(id: 13, name: "Cool white",   color: c(233, 242, 255)),
        ScenePreset(id: 14, name: "Night light",  color: c(242, 116, 40)),
        ScenePreset(id: 15, name: "Focus",        color: c(240, 247, 255)),
        ScenePreset(id: 16, name: "Relax",        color: c(255, 224, 185)),
        ScenePreset(id: 17, name: "True colors",  color: c(255, 255, 255)),
        ScenePreset(id: 18, name: "TV time",      color: c(230, 168, 92)),
        ScenePreset(id: 19, name: "Plant growth", color: c(205, 82, 205)),
        ScenePreset(id: 20, name: "Spring",       color: c(158, 230, 143)),
        ScenePreset(id: 21, name: "Summer",       color: c(255, 230, 106)),
        ScenePreset(id: 22, name: "Fall",         color: c(242, 143, 54)),
        ScenePreset(id: 23, name: "Deep dive",    color: c(28, 90, 216)),
        ScenePreset(id: 24, name: "Jungle",       color: c(43, 155, 78)),
        ScenePreset(id: 25, name: "Mojito",       color: c(143, 230, 92)),
        ScenePreset(id: 26, name: "Club",         color: c(157, 92, 242)),
        ScenePreset(id: 27, name: "Christmas",    color: c(230, 54, 54)),
        ScenePreset(id: 28, name: "Halloween",    color: c(242, 118, 15)),
        ScenePreset(id: 29, name: "Candlelight",  color: c(255, 176, 92)),
        ScenePreset(id: 30, name: "Golden white", color: c(255, 210, 130)),
        ScenePreset(id: 31, name: "Pulse",        color: c(230, 105, 205)),
        ScenePreset(id: 32, name: "Steampunk",    color: c(194, 155, 92)),
        ScenePreset(id: 33, name: "Diwali",       color: c(255, 191, 66)),
        ScenePreset(id: 34, name: "White",        color: c(255, 255, 255)),
        ScenePreset(id: 35, name: "Alarm",        color: c(255, 255, 255)),
        ScenePreset(id: 36, name: "Snowy sky",    color: c(206, 230, 255)),
    ]
}()

func scenePreset(id: Int) -> ScenePreset? {
    SCENE_PRESETS.first { $0.id == id }
}

// MARK: State helpers (pure)

/// Capture the interesting parts of a pilot snapshot (white temp, scene, or RGB,
/// plus dimming) so it can be stored as a state.
func captureSnapshot(from pilot: [String: Any]?) -> [String: Any]? {
    guard let pilot, (pilot["state"] as? Bool) != false else { return nil }
    var snap: [String: Any] = [:]
    // NOTE: pilots keep reporting stale r/g/b (and temp) while in scene mode,
    // so sceneId must win when non-zero — otherwise a scene look like
    // Nightlight captures as RGB and never matches the saved preset.
    if let sc = pilot["sceneId"] as? Int, sc != 0 {
        snap["sceneId"] = sc
    } else if let r = pilot["r"] as? Int, let g = pilot["g"] as? Int, let b = pilot["b"] as? Int {
        snap["r"] = r; snap["g"] = g; snap["b"] = b
    } else if let sc = pilot["sceneId"] as? Int, sc != 0 {
        snap["sceneId"] = sc
    } else if let t = pilot["temp"] as? Int, t != 0 {
        snap["temp"] = t
    } else {
        return nil
    }
    if let d = pilot["dimming"] as? Int { snap["dimming"] = max(10, min(100, d)) }
    return snap
}

/// True when two param dicts hold the same values (order-independent).
/// Used to avoid storing a builtin override identical to its default.
func paramsEqual(_ a: [String: Any], _ b: [String: Any]) -> Bool {
    (a as NSDictionary).isEqual(to: b)
}

/// Blend an RGB color toward white (amount 0…1).
func lightened(_ color: NSColor, amount: CGFloat) -> NSColor {
    guard let c = color.usingColorSpace(.deviceRGB) else { return color }
    return NSColor(calibratedRed: c.redComponent + (1 - c.redComponent) * amount,
                   green: c.greenComponent + (1 - c.greenComponent) * amount,
                   blue: c.blueComponent + (1 - c.blueComponent) * amount, alpha: 1)
}

func darkened(_ color: NSColor, amount: CGFloat) -> NSColor {
    guard let c = color.usingColorSpace(.deviceRGB) else { return color }
    return NSColor(calibratedRed: c.redComponent * (1 - amount),
                   green: c.greenComponent * (1 - amount),
                   blue: c.blueComponent * (1 - amount), alpha: 1)
}

/// Color for a row's swatch dot / bulb preview.
func swatchColor(for params: [String: Any]) -> NSColor {
    if let r = params["r"] as? Int, let g = params["g"] as? Int, let b = params["b"] as? Int {
        return NSColor(calibratedRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                       blue: CGFloat(b) / 255, alpha: 1)
    }
    if let sc = params["sceneId"] as? Int, let preset = scenePreset(id: sc) {
        return preset.color
    }
    if params["sceneId"] != nil {
        return NSColor(calibratedRed: 0.98, green: 0.55, blue: 0.22, alpha: 1)  // unknown scene
    }
    if let t = params["temp"] as? Int {   // white: lerp amber → ice blue
        let f = CGFloat(max(2200, min(6500, t)) - 2200) / CGFloat(6500 - 2200)
        return NSColor(calibratedRed: 1.0 - 0.55 * f, green: 0.70 + 0.04 * f,
                       blue: 0.36 + 0.64 * f, alpha: 1)
    }
    return .secondaryLabelColor
}

/// Right-aligned detail text for a row.
func detailText(for params: [String: Any]) -> String {
    var parts: [String] = []
    if let r = params["r"] as? Int, let g = params["g"] as? Int, let b = params["b"] as? Int {
        parts.append(String(format: "#%02X%02X%02X", r, g, b))
    }
    if let sc = params["sceneId"] as? Int {
        parts.append(scenePreset(id: sc)?.name ?? "scene \(sc)")
    }
    if let t = params["temp"] as? Int { parts.append("\(t) K") }
    // Scenes always run at 100% — showing it is just noise.
    if params["sceneId"] == nil, let d = params["dimming"] as? Int { parts.append("\(d)%") }
    return parts.joined(separator: " · ")
}

// MARK: - Custom views

/// Small colored status dot.
final class DotView: NSView {
    var color: NSColor = .systemGreen { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        color.setFill()
        NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
    }
}

/// A menu state row: swatch + title + right-aligned detail + checkmark, with
/// hover highlight and a filled style when selected. Whole row is clickable.
final class ModeButton: NSButton {
    var selected = false { didSet { needsDisplay = true; checkIcon.isHidden = !selected } }
    var hovered = false { didSet { needsDisplay = true } }
    var stateId = ""
    var swatch = NSColor.controlAccentColor
    var swatchIsRing = false
    var detailText = "" { didSet { detailField.stringValue = detailText } }

    let titleField: NSTextField
    let detailField: NSTextField
    let checkIcon: NSImageView
    let savedDot: DotView

    override init(frame frameRect: NSRect) {
        titleField = NSTextField(labelWithString: "")
        detailField = NSTextField(labelWithString: "")
        checkIcon = NSImageView()
        savedDot = DotView(frame: NSRect(x: MENU_WIDTH - 34, y: 12.5, width: 6, height: 6))
        super.init(frame: frameRect)

        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        titleField.frame = NSRect(x: 34, y: 7, width: 130, height: 17)
        titleField.font = .systemFont(ofSize: 13, weight: .medium)
        titleField.lineBreakMode = .byTruncatingTail
        addSubview(titleField)

        detailField.frame = NSRect(x: 166, y: 9, width: 96, height: 14)
        detailField.font = .systemFont(ofSize: 10.5)
        detailField.textColor = .secondaryLabelColor
        detailField.alignment = .right
        detailField.lineBreakMode = .byTruncatingHead
        addSubview(detailField)

        let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .bold)
        checkIcon.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg)
        checkIcon.contentTintColor = .controlAccentColor
        checkIcon.frame = NSRect(x: MENU_WIDTH - 24, y: 8, width: 14, height: 14)
        checkIcon.isHidden = true
        addSubview(checkIcon)

        savedDot.color = .systemOrange
        savedDot.toolTip = "Customized"
        savedDot.isHidden = true
        addSubview(savedDot)
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.options.contains(.mouseEnteredAndExited) {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func hitTest(_ point: NSPoint) -> NSView? { self }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 6, dy: 1.5)
        if selected {
            NSColor.controlAccentColor.withAlphaComponent(0.16).setFill()
            NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        } else if hovered {
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: box, xRadius: 8, yRadius: 8).fill()
        }
        let center = NSPoint(x: 20, y: bounds.midY)
        let r: CGFloat = 6
        let path = NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r))
        if swatchIsRing {
            path.lineWidth = 1.5
            NSColor.secondaryLabelColor.setStroke()
            path.stroke()
        } else {
            swatch.setFill()
            path.fill()
        }
    }
}

/// Menu header: status dot, bulb name, and ip / status line. Click re-polls.
final class HeaderView: NSView {
    weak var delegate: Refreshable?
    let dot = DotView(frame: NSRect(x: 16, y: 18, width: 8, height: 8))
    let nameField: NSTextField
    let subField: NSTextField

    override init(frame frameRect: NSRect) {
        nameField = NSTextField(labelWithString: "Bulb")
        subField = NSTextField(labelWithString: "")
        super.init(frame: frameRect)

        nameField.frame = NSRect(x: 32, y: 21, width: MENU_WIDTH - 40, height: 17)
        nameField.font = .systemFont(ofSize: 13, weight: .semibold)
        addSubview(nameField)

        subField.frame = NSRect(x: 32, y: 7, width: MENU_WIDTH - 44, height: 13)
        subField.font = .systemFont(ofSize: 10.5)
        subField.textColor = .secondaryLabelColor
        addSubview(subField)
        addSubview(dot)

        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    @objc func clicked() {
        delegate?.refreshRequested()
    }
}

protocol Refreshable: AnyObject { func refreshRequested() }

/// Diffused radial glow: concentric fills from weak outermost to strong center.
func drawSoftGlow(center: NSPoint, radius: CGFloat, color: NSColor, maxAlpha: CGFloat, steps: Int = 48) {
    for i in (0..<steps).reversed() {
        let r = radius * CGFloat(i + 1) / CGFloat(steps)
        let a = maxAlpha * pow(1 - CGFloat(i) / CGFloat(steps), 2.2)
        color.withAlphaComponent(a).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)).fill()
    }
}

/// A drawn lightbulb (styled after antontemchenko/css-light-bulb): circular
/// glass with a top reflection, shoulder neck, rounded collar, screw cap and
/// contact tip. When on, the glass takes the state's color and a large soft
/// halo diffuses into the panel; when off, a blurred ground shadow sits below.
final class BulbPreviewView: NSView {
    var displayColor: NSColor = .white
    var isOn = false
    var brightness: CGFloat = 0.7     // 0.1…1

    func show(state: StateEntry?) {
        guard let s = state, s.id != OFF_ID else {
            isOn = false
            needsDisplay = true
            return
        }
        isOn = true
        displayColor = swatchColor(for: s.params)
        brightness = CGFloat((s.params["dimming"] as? Int) ?? 100) / 100
        needsDisplay = true
    }

    func show(working color: NSColor, isOn on: Bool, dimming: Int) {
        isOn = on
        displayColor = color
        brightness = CGFloat(max(10, min(100, dimming))) / 100
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Panel behind everything
        let panel = NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 4), xRadius: 14, yRadius: 14)
        NSColor.labelColor.withAlphaComponent(0.045).setFill()
        panel.fill()

        let cx = bounds.midX
        let R: CGFloat = 58                      // glass radius
        let glassCy = bounds.midY + 48           // glass center
        let glass = NSBezierPath(ovalIn: NSRect(x: cx - R, y: glassCy - R, width: 2 * R, height: 2 * R))

        let collarW: CGFloat = 66, collarH: CGFloat = 38
        let collarTop = glassCy - R - 4
        let collarRect = NSRect(x: cx - collarW / 2, y: collarTop - collarH, width: collarW, height: collarH)
        let screwW: CGFloat = 52, screwH: CGFloat = 36
        let screwRect = NSRect(x: cx - screwW / 2, y: collarRect.minY + 5 - screwH, width: screwW, height: screwH)

        // Ground shadow under the base when off (hidden while lit, like the CSS lamp)
        if !isOn {
            NSGraphicsContext.current?.saveGraphicsState()
            let t = NSAffineTransform()
            t.translateX(by: cx, yBy: screwRect.minY - 8)
            t.scaleX(by: 1.0, yBy: 0.18)
            t.concat()
            drawSoftGlow(center: NSPoint(x: 0, y: 0), radius: 62, color: .black, maxAlpha: 0.32)
            NSGraphicsContext.current?.restoreGraphicsState()
        }

        // Diffused light: a large soft halo spilling out of the glass
        if isOn {
            let dim = 0.55 + 0.45 * brightness
            drawSoftGlow(center: NSPoint(x: cx, y: glassCy), radius: 150,
                         color: displayColor, maxAlpha: 0.26 * dim)
            drawSoftGlow(center: NSPoint(x: cx, y: glassCy), radius: 96,
                         color: displayColor, maxAlpha: 0.30 * dim)
        }

        // Shoulder / neck (drawn first, the glass overlaps its top)
        let neck = NSBezierPath()
        let neckTop = glassCy - R * 0.42
        let neckBotW = collarW - 6
        neck.move(to: NSPoint(x: cx - neckBotW / 2, y: collarTop + 2))
        neck.line(to: NSPoint(x: cx - R * 0.55, y: neckTop))
        neck.line(to: NSPoint(x: cx + R * 0.55, y: neckTop))
        neck.line(to: NSPoint(x: cx + neckBotW / 2, y: collarTop + 2))
        neck.close()
        (isOn ? displayColor : NSColor(calibratedWhite: 0.74, alpha: 1)).setFill()
        neck.fill()

        // Glass
        if isOn {
            if let g = NSGradient(colors: [lightened(displayColor, amount: 0.05 + 0.15 * brightness), displayColor]) {
                g.draw(in: glass, angle: 270)
            }
        } else {
            NSColor(calibratedWhite: 0.80, alpha: 1).setFill()
            glass.fill()
        }

        // Glass reflection: white fading from the top (the CSS :after overlay)
        NSGraphicsContext.current?.saveGraphicsState()
        glass.addClip()
        let reflRect = NSRect(x: cx - R, y: glassCy, width: 2 * R, height: R)
        if let g = NSGradient(colors: [NSColor.white.withAlphaComponent(isOn ? 0.50 : 0.65),
                                       NSColor.white.withAlphaComponent(0)]) {
            g.draw(in: reflRect, angle: 270)
        }
        NSGraphicsContext.current?.restoreGraphicsState()

        // Collar: square top corners, rounded bottom, darker toward the bottom
        let collar = NSBezierPath()
        collar.move(to: NSPoint(x: collarRect.minX, y: collarRect.maxY))
        collar.line(to: NSPoint(x: collarRect.maxX, y: collarRect.maxY))
        collar.line(to: NSPoint(x: collarRect.maxX, y: collarRect.minY + 14))
        collar.appendArc(withCenter: NSPoint(x: collarRect.maxX - 14, y: collarRect.minY + 14),
                         radius: 14, startAngle: 0, endAngle: 270, clockwise: true)
        collar.line(to: NSPoint(x: collarRect.minX + 14, y: collarRect.minY))
        collar.appendArc(withCenter: NSPoint(x: collarRect.minX + 14, y: collarRect.minY + 14),
                         radius: 14, startAngle: 270, endAngle: 180, clockwise: true)
        collar.close()
        let collarColor = isOn ? displayColor : NSColor(calibratedWhite: 0.74, alpha: 1)
        if let g = NSGradient(colors: [collarColor, darkened(collarColor, amount: 0.30)]) {
            g.draw(in: collar, angle: 270)
        }

        // Screw cap (stays gray, like the reference)
        let screw = NSBezierPath()
        screw.move(to: NSPoint(x: screwRect.minX, y: screwRect.maxY))
        screw.line(to: NSPoint(x: screwRect.maxX, y: screwRect.maxY))
        screw.line(to: NSPoint(x: screwRect.maxX, y: screwRect.minY + 16))
        screw.appendArc(withCenter: NSPoint(x: screwRect.maxX - 16, y: screwRect.minY + 16),
                        radius: 16, startAngle: 0, endAngle: 270, clockwise: true)
        screw.line(to: NSPoint(x: screwRect.minX + 16, y: screwRect.minY))
        screw.appendArc(withCenter: NSPoint(x: screwRect.minX + 16, y: screwRect.minY + 16),
                        radius: 16, startAngle: 270, endAngle: 180, clockwise: true)
        screw.close()
        if let g = NSGradient(colors: [NSColor(calibratedWhite: 0.60, alpha: 1),
                                       NSColor(calibratedWhite: 0.44, alpha: 1)]) {
            g.draw(in: screw, angle: 270)
        }

        // Contact tip
        let tip = NSBezierPath()
        tip.move(to: NSPoint(x: cx - 13, y: screwRect.minY + 3))
        tip.line(to: NSPoint(x: cx + 13, y: screwRect.minY + 3))
        tip.line(to: NSPoint(x: cx + 7, y: screwRect.minY - 9))
        tip.line(to: NSPoint(x: cx - 7, y: screwRect.minY - 9))
        tip.close()
        NSColor(calibratedWhite: 0.30, alpha: 1).setFill()
        tip.fill()
    }
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate, Refreshable {
    var statusItem: NSStatusItem!
    var menu: NSMenu!
    var modeButtons: [String: ModeButton] = [:]
    var rowItems: [NSMenuItem] = []
    var header: HeaderView!
    var slider: NSSlider!
    var pctLabel: NSTextField!
    var sliderItem: NSMenuItem!
    var sliderSep: NSMenuItem!
    var saveAsItem: NSMenuItem!

    var cfg = loadConfig()
    var currentId: String?        // selected state id, e.g. "builtin:warm"
    var busy = false
    var online: Bool?             // nil = unknown
    var statusMessage: String?
    var lastPilot: [String: Any]?
    var pendingDim: DispatchWorkItem?

    var bulbIP: String? { cfg["ip"] as? String }
    var bulbMAC: String? { cfg["mac"] as? String }

    var aliases: [String: String] {
        get { cfg["aliases"] as? [String: String] ?? [:] }
        set { cfg["aliases"] = newValue }
    }
    var overrides: [String: [String: Any]] {
        get { cfg["overrides"] as? [String: [String: Any]] ?? [:] }
        set { cfg["overrides"] = newValue }
    }
    var customs: [[String: Any]] {
        get { cfg["states"] as? [[String: Any]] ?? [] }
        set { cfg["states"] = newValue }
    }
    var bulbs: [String: String] {
        get { cfg["bulbs"] as? [String: String] ?? [:] }
        set { cfg["bulbs"] = newValue }
    }

    // MARK: State list

    func effectiveParams(for mode: Mode) -> [String: Any] {
        overrides[mode.rawValue] ?? mode.defaultParams
    }

    func allStates() -> [StateEntry] {
        let hidden = Set(cfg["hiddenBuiltin"] as? [String] ?? [])
        var list: [StateEntry] = []
        for m in Mode.allCases where !hidden.contains(m.rawValue) {
            list.append(StateEntry(id: m.id, name: m.title,
                                   params: effectiveParams(for: m), isBuiltin: true))
        }
        for (i, c) in customs.enumerated() {
            let name = c["name"] as? String ?? "Preset \(i + 1)"
            let params = c["params"] as? [String: Any] ?? [:]
            list.append(StateEntry(id: "custom:\(i)", name: name, params: params, isBuiltin: false))
        }
        return list
    }

    func stateById(_ id: String) -> StateEntry? {
        if id == OFF_ID { return .off() }
        return allStates().first { $0.id == id }
    }

    /// Match a getPilot result to a state id. WiZ pilots always carry `sceneId`
    /// (0 in white/color mode) and may report stale fields, so match on the
    /// state's kind and only when the pilot actually is in that kind of mode.
    func currentStateId(from pilot: [String: Any]?) -> String? {
        guard let pilot else { return nil }
        if (pilot["state"] as? Bool) == false { return OFF_ID }
        let pScene = pilot["sceneId"] as? Int ?? 0
        let pr = pilot["r"] as? Int
        let pg = pilot["g"] as? Int
        let pb = pilot["b"] as? Int
        let pilotIsColor = pr != nil && pg != nil && pb != nil
        for s in allStates() where s.id != OFF_ID {
            let p = s.params
            if let sc = p["sceneId"] as? Int {
                if pScene != 0 && sc == pScene { return s.id }
            } else if let r = p["r"] as? Int, let g = p["g"] as? Int, let b = p["b"] as? Int {
                if pilotIsColor, pr == r, pg == g, pb == b { return s.id }
            } else if let t = p["temp"] as? Int {
                if !pilotIsColor && pScene == 0, (pilot["temp"] as? Int) == t { return s.id }
            }
        }
        return nil
    }

    /// True when the pilot snapshot is effectively identical to an existing
    /// preset (same kind, same defining field, same dimming).
    func snapshotMatchesExisting(_ snap: [String: Any]) -> Bool {
        for s in allStates() where s.id != OFF_ID {
            let p = s.params
            let sameDimming = (p["dimming"] as? Int) == (snap["dimming"] as? Int)
            if let sc = p["sceneId"] as? Int {
                if (snap["sceneId"] as? Int) == sc && sameDimming { return true }
            } else if let r = p["r"] as? Int, let g = p["g"] as? Int, let b = p["b"] as? Int {
                if (snap["r"] as? Int) == r, (snap["g"] as? Int) == g,
                   (snap["b"] as? Int) == b, sameDimming { return true }
            } else if let t = p["temp"] as? Int {
                if (snap["temp"] as? Int) == t && sameDimming { return true }
            }
        }
        return false
    }

    // MARK: Bulb naming

    func defaultName(for mac: String) -> String {
        "WiZ Bulb " + String(mac.suffix(4)).uppercased()
    }
    func displayName(for mac: String?) -> String {
        guard let mac else { return "WiZ Bulb" }
        return aliases[mac] ?? defaultName(for: mac)
    }

    // MARK: Menu construction

    func applicationDidFinishLaunching(_: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        setIcon(named: "lightbulb")
        statusItem.button?.toolTip = "WiZard — WiZ presets in your menu bar"

        menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        header = HeaderView(frame: NSRect(x: 0, y: 0, width: MENU_WIDTH, height: 44))
        header.delegate = self
        let headerItem = NSMenuItem()
        headerItem.view = header
        menu.addItem(headerItem)
        menu.addItem(.separator())                       // index 1; rows go after this

        rebuildRows()
        menu.addItem(.separator())

        // Brightness row
        let row = NSView(frame: NSRect(x: 0, y: 0, width: MENU_WIDTH, height: 32))
        let label = NSTextField(labelWithString: "Brightness")
        label.font = .systemFont(ofSize: 10.5)
        label.textColor = .secondaryLabelColor
        label.frame = NSRect(x: 14, y: 10, width: 70, height: 14)
        slider = NSSlider(value: 100, minValue: 10, maxValue: 100,
                          target: self, action: #selector(brightnessChanged(_:)))
        slider.frame = NSRect(x: 88, y: 7, width: 152, height: 19)
        pctLabel = NSTextField(labelWithString: "\u{2014}")
        pctLabel.font = .systemFont(ofSize: 11, weight: .medium)
        pctLabel.alignment = .right
        pctLabel.frame = NSRect(x: 244, y: 9, width: 42, height: 16)
        row.addSubview(label)
        row.addSubview(slider)
        row.addSubview(pctLabel)
        let sliderItem = NSMenuItem()
        sliderItem.view = row
        menu.addItem(sliderItem)
        self.sliderItem = sliderItem
        sliderSep = NSMenuItem.separator()
        menu.addItem(sliderSep)

        saveAsItem = NSMenuItem(title: "Save as new preset…",
                                action: #selector(saveAsNewState), keyEquivalent: "")
        saveAsItem.target = self
        saveAsItem.toolTip = "Capture the bulb's current state (or start blank if it's off) as a new preset"
        menu.addItem(saveAsItem)

        let prefs = NSMenuItem(title: "Preferences…", action: #selector(openPreferencesFromMenu), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        let find = NSMenuItem(title: "Find WiZ bulbs", action: #selector(findBulbs), keyEquivalent: "f")
        find.target = self
        menu.addItem(find)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit WiZard",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        updateUI()
        refreshState()
    }

    func setIcon(named name: String) {
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "bulb")
        img?.isTemplate = true
        if let img {
            img.size = NSSize(width: 16, height: 16)
            statusItem.button?.image = img
            statusItem.button?.title = ""
        } else {
            statusItem.button?.title = "💡"
        }
    }

    /// Rebuild the dynamic state rows in the menu.
    func rebuildRows() {
        for it in rowItems { menu.removeItem(it) }
        rowItems.removeAll()
        modeButtons.removeAll()

        var states = allStates()
        states.append(.off())
        for (i, s) in states.enumerated() {
            let row = ModeButton(frame: NSRect(x: 0, y: 0, width: MENU_WIDTH, height: 30))
            row.stateId = s.id
            row.titleField.stringValue = s.name
            row.target = self
            row.action = #selector(modeRowClicked(_:))
            let item = NSMenuItem()
            item.view = row
            menu.insertItem(item, at: 2 + i)
            rowItems.append(item)
            modeButtons[s.id] = row
        }
        updateUI()
    }

    // MARK: UI updates

    func updateUI() {
        switch currentId {
        case .some(OFF_ID), .none: setIcon(named: "lightbulb")
        case .some:                setIcon(named: "lightbulb.fill")
        }

        for (id, row) in modeButtons {
            guard let s = stateById(id) else { continue }
            row.selected = (id == currentId)
            row.swatch = swatchColor(for: s.params)
            row.swatchIsRing = (id == OFF_ID)
            row.detailText = detailText(for: s.params)
            var overridden = false
            if s.isBuiltin, id != OFF_ID,
               let m = Mode(rawValue: String(id.dropFirst("builtin:".count))),
               let o = overrides[m.rawValue] {
                overridden = !paramsEqual(o, m.defaultParams)
            }
            row.savedDot.isHidden = !overridden
        }

        header?.nameField.stringValue = displayName(for: bulbMAC)
        var dotColor: NSColor
        if busy {
            header?.subField.stringValue = "searching…"
            dotColor = .systemYellow
        } else if let msg = statusMessage {
            header?.subField.stringValue = msg
            dotColor = .systemRed
        } else if online == true, let ip = bulbIP {
            header?.subField.stringValue = ip
            dotColor = .systemGreen
        } else {
            header?.subField.stringValue = bulbIP.map { "\($0)  ·  offline" } ?? "no bulb found"
            dotColor = .systemRed
        }
        header?.dot.color = dotColor

        // Scenes always run at 100% — no brightness slider for them.
        let isScene = currentId.flatMap { stateById($0) }?.params["sceneId"] != nil
        sliderItem?.isHidden = isScene
        sliderSep?.isHidden = isScene
        // "Save as new preset" only when the bulb shows a look that isn't
        // already saved — i.e. something actually changed (brightness, color, …).
        if let snap = captureSnapshot(from: lastPilot), !snapshotMatchesExisting(snap) {
            saveAsItem?.isEnabled = true
        } else {
            saveAsItem?.isEnabled = false
        }
        menu.update()
    }

    // MARK: State refresh

    func refreshState() {
        guard !busy else { return }
        busy = true
        statusMessage = nil
        updateUI()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var result: [String: Any]?
            var ip = bulbIP
            if let ip {
                result = request(ip, payload: ["id": 91, "method": "getPilot", "params": [String: Any]()])
            }
            if result == nil {
                let found = discover()
                recordBulbs(found)
                if let first = found.first {
                    ip = first.ip
                    result = first.result
                    cfg["ip"] = first.ip
                    if let mac = first.result["mac"] as? String { cfg["mac"] = mac }
                    saveConfig(cfg)
                } else {
                    ip = nil
                }
            }
            DispatchQueue.main.async { [self] in
                busy = false
                online = result != nil
                currentId = currentStateId(from: result)
                lastPilot = result
                if let d = result?["dimming"] as? Int {
                    slider.integerValue = max(10, min(100, d))
                    pctLabel.stringValue = "\(d)%"
                }
                updateUI()
                if prefsWindow != nil { syncHeaderLabels() }
            }
        }
    }

    @objc func refreshRequested() { refreshState() }

    func recordBulbs(_ found: [(ip: String, result: [String: Any])]) {
        var b = bulbs
        for f in found {
            if let mac = f.result["mac"] as? String { b[mac] = f.ip }
        }
        if b != bulbs {
            bulbs = b
            saveConfig(cfg)
        }
    }

    // MARK: Menu actions

    @objc func modeRowClicked(_ sender: NSButton) {
        guard let row = sender as? ModeButton, let s = stateById(row.stateId) else { return }
        row.enclosingMenuItem?.menu?.cancelTracking()
        applyState(s)
    }

    func applyState(_ s: StateEntry) {
        currentId = s.id
        updateUI()
        var params = s.params
        if s.id != OFF_ID { params["state"] = true }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var ok = false
            if let ip = bulbIP {
                ok = request(ip, payload: ["id": 92, "method": "setPilot", "params": params]) != nil
            }
            if !ok {
                cfg.removeValue(forKey: "ip")
                let found = discover()
                recordBulbs(found)
                if let found = found.first {
                    cfg["ip"] = found.ip
                    if let mac = found.result["mac"] as? String { cfg["mac"] = mac }
                    saveConfig(cfg)
                    ok = request(found.ip, payload: ["id": 93, "method": "setPilot", "params": params]) != nil
                }
            }
            DispatchQueue.main.async { [self] in
                online = ok
                if !ok { statusMessage = "bulb did not respond" }
                updateUI()
            }
        }
    }

    /// Send dimming, preserving the bulb's current color / temp / scene.
    func sendDimming(_ value: Int) {
        var params: [String: Any] = ["state": true, "dimming": value]
        // Same ordering as captureSnapshot: a non-zero sceneId wins over
        // stale r/g/b the pilot may still carry in scene mode.
        if let sc = lastPilot?["sceneId"] as? Int, sc != 0 {
            params["sceneId"] = sc
        } else if let r = lastPilot?["r"] as? Int, let g = lastPilot?["g"] as? Int, let b = lastPilot?["b"] as? Int {
            params["r"] = r; params["g"] = g; params["b"] = b
        } else if let t = lastPilot?["temp"] as? Int, t != 0 {
            params["temp"] = t
        }
        var ok = false
        if let ip = bulbIP {
            ok = request(ip, payload: ["id": 94, "method": "setPilot", "params": params]) != nil
        }
        if !ok {
            let found = discover()
            recordBulbs(found)
            if let found = found.first {
                cfg["ip"] = found.ip
                if let mac = found.result["mac"] as? String { cfg["mac"] = mac }
                saveConfig(cfg)
                ok = request(found.ip, payload: ["id": 95, "method": "setPilot", "params": params]) != nil
            }
        }
        if ok {
            lastPilot = params
            DispatchQueue.main.async { [self] in
                online = true
                currentId = currentStateId(from: params)
                updateUI()
            }
        }
    }

    @objc func brightnessChanged(_ sender: NSSlider) {
        let v = Int(sender.doubleValue)
        pctLabel.stringValue = "\(v)%"
        pendingDim?.cancel()
        let w = DispatchWorkItem { [self] in sendDimming(v) }
        pendingDim = w
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.2, execute: w)
    }

    @objc func saveAsNewState() {
        let captured = captureSnapshot(from: lastPilot)
        openPreferences(newFromCapture: captured)
    }

    // MARK: - Preferences window

    var prefsWindow: NSWindow?

    // Left panel
    var preview: BulbPreviewView!
    var prefsDot: DotView!
    var prefsNameField: NSTextField!
    var prefsSubField: NSTextField!

    // Tabs
    var tabSegment: NSSegmentedControl!
    var statesTab: NSView!
    var scenesTab: NSView!
    var bulbsTab: NSView!

    // States tab
    var statesListScroll: NSScrollView!
    var statesListContent: NSView!
    var nameField: NSTextField!
    var kindSeg: NSSegmentedControl!
    var tempSlider: NSSlider!
    var tempLabel: NSTextField!
    var tempTitleLabel: NSTextField!
    var colorWell: NSColorWell!
    var brightSlider: NSSlider!
    var brightLabel: NSTextField!
    var brightTitleLabel: NSTextField!
    var revertBtn: NSButton!
    var deleteBtn: NSButton!
    var saveBtn: NSButton!
    var newBtn: NSButton!
    var restoreBtn: NSButton!

    // Scenes tab
    var scenesListScroll: NSScrollView!
    var scenesListContent: NSView!

    // Bulbs tab
    var bulbsListScroll: NSScrollView!
    var bulbsListContent: NSView!
    var bulbRenameField: NSTextField!
    var selectedMAC: String?

    // States editor, Scene mode
    var scenePopup: NSPopUpButton!

    // Live editing preview on the real bulb
    var pendingPreview: DispatchWorkItem?
    var previewOriginal: [String: Any]?   // pilot to restore when the window closes
    var didPreview = false

    /// Working copy of the state being edited.
    struct WorkingState {
        var target: EditTarget
        var name: String
        var kind: Int          // 0 = white, 1 = color, 2 = scene
        var color: NSColor
        var temp: Int
        var dimming: Int
        var sceneId: Int?      // only when kind == 2
    }
    enum EditTarget { case new, custom(Int), builtin(Mode) }
    var working: WorkingState?
    var selectedStateId: String?

    @objc func openPreferencesFromMenu() {
        openPreferences(newFromCapture: nil)
    }

    @objc func openPreferences(newFromCapture captured: [String: Any]? = nil) {
        if prefsWindow == nil {
            buildWindow()
        } else {
            // Already open — refresh everything from config
            syncHeaderLabels()
            reloadStatesList()
            reloadScenesList()
            reloadBulbsList()
        }
        NSApp.activate(ignoringOtherApps: true)
        prefsWindow?.makeKeyAndOrderFront(nil)

        if let captured {
            selectWorking(WorkingState(target: .new,
                                       name: "",
                                       kind: captured["sceneId"] != nil ? 2 : (captured["r"] != nil ? 1 : 0),
                                       color: rgbColor(from: captured) ?? .systemOrange,
                                       temp: (captured["temp"] as? Int) ?? 3500,
                                       dimming: (captured["dimming"] as? Int) ?? 70,
                                       sceneId: captured["sceneId"] as? Int))
        } else if working == nil && selectedStateId == nil {
            selectFirstState()
        }
        syncWorkingToControls()
        syncPreview()
    }

    func buildWindow() {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 660, height: 500),
                           styleMask: [.titled, .closable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = "WiZard Presets"
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 660, height: 500))
        content.wantsLayer = true
        win.contentView = content

        // ---- Left panel: preview + status
        preview = BulbPreviewView(frame: NSRect(x: 24, y: 182, width: 190, height: 296))
        content.addSubview(preview)

        prefsDot = DotView(frame: NSRect(x: 30, y: 128, width: 8, height: 8))
        content.addSubview(prefsDot)
        prefsNameField = NSTextField(labelWithString: "Bulb")
        prefsNameField.font = .systemFont(ofSize: 14, weight: .semibold)
        prefsNameField.frame = NSRect(x: 46, y: 142, width: 168, height: 18)
        content.addSubview(prefsNameField)
        prefsSubField = NSTextField(labelWithString: "")
        prefsSubField.font = .systemFont(ofSize: 10.5)
        prefsSubField.textColor = .secondaryLabelColor
        prefsSubField.frame = NSRect(x: 46, y: 124, width: 168, height: 14)
        content.addSubview(prefsSubField)

        let refreshBtn = NSButton(title: "Refresh", target: self, action: #selector(refreshRequested))
        refreshBtn.bezelStyle = .rounded
        refreshBtn.controlSize = .small
        refreshBtn.font = .systemFont(ofSize: 11)
        refreshBtn.frame = NSRect(x: 30, y: 86, width: 90, height: 24)
        content.addSubview(refreshBtn)

        // ---- Right panel: tabs
        tabSegment = NSSegmentedControl(labels: ["Presets", "Scenes", "Bulbs"],
                                        trackingMode: .selectOne,
                                        target: self, action: #selector(tabChanged(_:)))
        tabSegment.frame = NSRect(x: 240, y: 460, width: 396, height: 26)
        tabSegment.selectedSegment = 0
        content.addSubview(tabSegment)

        let container = NSView(frame: NSRect(x: 240, y: 14, width: 396, height: 436))
        content.addSubview(container)

        statesTab = buildStatesTab(frame: container.bounds)
        scenesTab = buildScenesTab(frame: container.bounds)
        bulbsTab = buildBulbsTab(frame: container.bounds)
        container.addSubview(statesTab)
        container.addSubview(scenesTab)
        container.addSubview(bulbsTab)
        scenesTab.isHidden = true
        bulbsTab.isHidden = true

        prefsWindow = win
        syncHeaderLabels()
        reloadStatesList()
        reloadScenesList()
        reloadBulbsList()
    }

    // MARK: Window building helpers

    func makeScroll(contentView: NSView, frame: NSRect) -> NSScrollView {
        let scroll = NSScrollView(frame: frame)
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.horizontalScrollElasticity = .none
        // Force overlay style: classic (always-visible) scrollers would reserve
        // ~16pt, making the document wider than the visible area and enabling
        // an annoying horizontal pan. Overlay scrollers draw over content.
        scroll.scrollerStyle = .overlay
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .clear
        scroll.documentView = contentView
        scroll.autohidesScrollers = true
        // Round the viewport so rows that get cut at the edges read as sliding
        // under a rounded card instead of ending in square corners.
        scroll.contentView.wantsLayer = true
        scroll.contentView.layer?.cornerRadius = 12
        scroll.contentView.layer?.masksToBounds = true
        return scroll
    }

    func buildStatesTab(frame: NSRect) -> NSView {
        let v = NSView(frame: frame)
        let m: CGFloat = 12            // outer padding, consistent across all tabs
        let w = frame.width

        restoreBtn = NSButton(title: "Restore presets", target: self, action: #selector(restoreBuiltinsClicked))
        restoreBtn.bezelStyle = .rounded
        restoreBtn.frame = NSRect(x: w - m - 132, y: frame.height - m - 26, width: 132, height: 26)
        v.addSubview(restoreBtn)

        statesListContent = FlippedView(frame: NSRect(x: 0, y: 0, width: w - 2 * m, height: 1))
        let listFrame = NSRect(x: m, y: 238, width: w - 2 * m, height: 152)
        let listCard = RoundedBoxView(frame: listFrame)
        v.addSubview(listCard)
        statesListScroll = makeScroll(contentView: statesListContent, frame: listFrame)
        v.addSubview(statesListScroll)

        // "Create new preset" — attached to the bottom of the states list,
        // same length as the list card above
        newBtn = NewStateButton(frame: NSRect(x: m, y: 208, width: w - 2 * m, height: 28))
        newBtn.target = self
        newBtn.action = #selector(newStateClicked)
        newBtn.toolTip = "Create a new preset"
        v.addSubview(newBtn)

        // Editor box: y 12…196, inner padding 12 (content x 24…372)
        let box = RoundedBoxView(frame: NSRect(x: m, y: 12, width: w - 2 * m, height: 184))
        v.addSubview(box)

        let nameLabel = NSTextField(labelWithString: "Name")
        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.frame = NSRect(x: 24, y: 157, width: 40, height: 14)
        v.addSubview(nameLabel)
        nameField = NSTextField(frame: NSRect(x: 68, y: 152, width: w - 68 - 24, height: 22))
        nameField.placeholderString = "Preset name"
        nameField.target = self
        nameField.action = #selector(nameFieldChanged)
        v.addSubview(nameField)

        kindSeg = NSSegmentedControl(labels: ["White", "Color", "Scene"], trackingMode: .selectOne,
                                     target: self, action: #selector(kindChanged(_:)))
        kindSeg.frame = NSRect(x: 24, y: 122, width: 190, height: 24)
        v.addSubview(kindSeg)

        tempTitleLabel = NSTextField(labelWithString: "Temperature")
        tempTitleLabel.font = .systemFont(ofSize: 11)
        tempTitleLabel.textColor = .secondaryLabelColor
        tempTitleLabel.frame = NSRect(x: 24, y: 95, width: 70, height: 14)
        v.addSubview(tempTitleLabel)
        tempSlider = NSSlider(value: 3500, minValue: 2200, maxValue: 6500,
                              target: self, action: #selector(tempSliderChanged(_:)))
        tempSlider.frame = NSRect(x: 98, y: 90, width: 214, height: 24)
        v.addSubview(tempSlider)
        tempLabel = NSTextField(labelWithString: "3500 K")
        tempLabel.font = .systemFont(ofSize: 11)
        tempLabel.alignment = .right
        tempLabel.frame = NSRect(x: 318, y: 95, width: 54, height: 14)
        v.addSubview(tempLabel)

        colorWell = NSColorWell(frame: NSRect(x: 24, y: 88, width: 72, height: 32))
        colorWell.target = self
        colorWell.action = #selector(colorWellChanged)
        v.addSubview(colorWell)

        // Scene chooser (shown when the editor is in Scene mode)
        scenePopup = NSPopUpButton(frame: NSRect(x: 24, y: 88, width: 230, height: 26))
        scenePopup.target = self
        scenePopup.action = #selector(scenePopupChanged)
        for preset in SCENE_PRESETS {
            scenePopup.addItem(withTitle: preset.name)
            scenePopup.lastItem?.representedObject = preset.id
        }
        scenePopup.isHidden = true
        v.addSubview(scenePopup)

        let brightTitle = NSTextField(labelWithString: "Brightness")
        brightTitleLabel = brightTitle
        brightTitle.font = .systemFont(ofSize: 11)
        brightTitle.textColor = .secondaryLabelColor
        brightTitle.frame = NSRect(x: 24, y: 63, width: 70, height: 14)
        v.addSubview(brightTitle)
        brightSlider = NSSlider(value: 70, minValue: 10, maxValue: 100,
                                target: self, action: #selector(brightSliderChanged(_:)))
        brightSlider.frame = NSRect(x: 98, y: 58, width: 214, height: 24)
        v.addSubview(brightSlider)
        brightLabel = NSTextField(labelWithString: "70%")
        brightLabel.font = .systemFont(ofSize: 11)
        brightLabel.alignment = .right
        brightLabel.frame = NSRect(x: 318, y: 63, width: 54, height: 14)
        v.addSubview(brightLabel)

        revertBtn = NSButton(title: "Revert", target: self, action: #selector(revertClicked))
        revertBtn.bezelStyle = .rounded
        revertBtn.frame = NSRect(x: 24, y: 24, width: 68, height: 26)
        v.addSubview(revertBtn)

        deleteBtn = NSButton(title: "Delete", target: self, action: #selector(deleteClicked))
        deleteBtn.bezelStyle = .rounded
        deleteBtn.hasDestructiveAction = true
        deleteBtn.attributedTitle = NSAttributedString(
            string: "Delete",
            attributes: [.foregroundColor: NSColor.systemRed,
                         .font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
        deleteBtn.frame = NSRect(x: 98, y: 24, width: 68, height: 26)
        v.addSubview(deleteBtn)

        saveBtn = NSButton(title: "Save", target: self, action: #selector(saveClicked))
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        saveBtn.frame = NSRect(x: w - 24 - 68, y: 24, width: 68, height: 26)
        v.addSubview(saveBtn)

        return v
    }

    func buildScenesTab(frame: NSRect) -> NSView {
        let v = NSView(frame: frame)
        let m: CGFloat = 12
        let hint = NSTextField(labelWithString: "Click to preview · + adds · click an added scene to remove it")
        hint.font = .systemFont(ofSize: 10.5)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: m, y: frame.height - 22, width: frame.width - 2 * m, height: 14)
        v.addSubview(hint)

        scenesListContent = FlippedView(frame: NSRect(x: 0, y: 0, width: frame.width - 2 * m, height: 1))
        let gridFrame = NSRect(x: m, y: 0, width: frame.width - 2 * m, height: frame.height - 30)
        let gridCard = RoundedBoxView(frame: gridFrame)
        v.addSubview(gridCard)
        scenesListScroll = makeScroll(contentView: scenesListContent, frame: gridFrame)
        v.addSubview(scenesListScroll)
        return v
    }

    func buildBulbsTab(frame: NSRect) -> NSView {
        let v = NSView(frame: frame)
        let m: CGFloat = 12

        bulbsListContent = FlippedView(frame: NSRect(x: 0, y: 0, width: frame.width - 2 * m, height: 1))
        let bulbFrame = NSRect(x: m, y: 130, width: frame.width - 2 * m, height: frame.height - 152)
        let bulbCard = RoundedBoxView(frame: bulbFrame)
        v.addSubview(bulbCard)
        bulbsListScroll = makeScroll(contentView: bulbsListContent, frame: bulbFrame)
        v.addSubview(bulbsListScroll)

        let nameLabel = NSTextField(labelWithString: "Name")
        nameLabel.font = .systemFont(ofSize: 11)
        nameLabel.textColor = .secondaryLabelColor
        nameLabel.frame = NSRect(x: 14, y: 100, width: 44, height: 14)
        v.addSubview(nameLabel)
        bulbRenameField = NSTextField(frame: NSRect(x: 58, y: 96, width: frame.width - 58 - m, height: 22))
        bulbRenameField.placeholderString = "Bulb name"
        v.addSubview(bulbRenameField)

        let renameBtn = NSButton(title: "Rename", target: self, action: #selector(renameBulbClicked))
        renameBtn.bezelStyle = .rounded
        renameBtn.frame = NSRect(x: m, y: 58, width: 110, height: 28)
        v.addSubview(renameBtn)

        let setActiveBtn = NSButton(title: "Use this bulb", target: self, action: #selector(setActiveBulbClicked))
        setActiveBtn.bezelStyle = .rounded
        setActiveBtn.frame = NSRect(x: m + 118, y: 58, width: 140, height: 28)
        v.addSubview(setActiveBtn)

        let findBtn = NSButton(title: "Find WiZ bulbs", target: self, action: #selector(findBulbs))
        findBtn.bezelStyle = .rounded
        findBtn.frame = NSRect(x: m, y: 20, width: 124, height: 28)
        v.addSubview(findBtn)

        return v
    }

    @objc func tabChanged(_ sender: NSSegmentedControl) {
        statesTab.isHidden = sender.selectedSegment != 0
        scenesTab.isHidden = sender.selectedSegment != 1
        bulbsTab.isHidden = sender.selectedSegment != 2
        if sender.selectedSegment == 1 { reloadScenesList() }
        if sender.selectedSegment == 2 { reloadBulbsList() }
    }

    func windowWillClose(_ notification: Notification) {
        restoreAfterPreview()
        prefsWindow = nil
    }

    // MARK: Live editing preview on the real bulb

    /// Build setPilot params (without "state") from the state being edited.
    func workingParams() -> [String: Any]? {
        guard let w = working else { return nil }
        // Scenes always run at full brightness.
        let dim = (w.kind == 2) ? 100 : w.dimming
        var p: [String: Any] = ["dimming": dim]
        switch w.kind {
        case 1:
            guard let c = w.color.usingColorSpace(.deviceRGB) else { return nil }
            p["r"] = Int(round(c.redComponent * 255))
            p["g"] = Int(round(c.greenComponent * 255))
            p["b"] = Int(round(c.blueComponent * 255))
        case 2:
            p["sceneId"] = w.sceneId ?? 14
        default:
            p["temp"] = w.temp
        }
        return p
    }

    /// Send the state being edited to the real bulb (debounced). The bulb's
    /// previous pilot is remembered once and restored when the window closes.
    func previewWorking() {
        guard let p = workingParams() else { return }
        livePreview(params: p)
    }

    func livePreview(params: [String: Any]) {
        guard prefsWindow != nil else { return }
        if previewOriginal == nil { previewOriginal = lastPilot }
        didPreview = true
        pendingPreview?.cancel()
        var p = params
        p["state"] = true
        let work = DispatchWorkItem { [self] in
            var ok = false
            if let ip = bulbIP {
                ok = request(ip, payload: ["id": 96, "method": "setPilot", "params": p]) != nil
            }
            if !ok {
                let found = discover()
                recordBulbs(found)
                if let first = found.first {
                    ok = request(first.ip, payload: ["id": 97, "method": "setPilot", "params": p]) != nil
                }
            }
            if ok {
                DispatchQueue.main.async { [self] in
                    online = true
                    syncHeaderLabels()
                }
            }
        }
        pendingPreview = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Put the bulb back to how it was before live previewing.
    func restoreAfterPreview() {
        pendingPreview?.cancel()
        pendingPreview = nil
        guard didPreview, let orig = previewOriginal else {
            didPreview = false
            previewOriginal = nil
            return
        }
        didPreview = false
        previewOriginal = nil
        var p = orig
        p["state"] = (orig["state"] as? Bool) ?? true
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            if let ip = bulbIP {
                _ = request(ip, payload: ["id": 98, "method": "setPilot", "params": p])
            }
            DispatchQueue.main.async { [self] in refreshState() }
        }
    }

    func syncHeaderLabels() {
        prefsNameField?.stringValue = displayName(for: bulbMAC)
        let ip = bulbIP ?? "no bulb yet"
        var sub = ip
        var dotColor: NSColor
        if busy {
            sub += "  ·  searching…"
            dotColor = .systemYellow
        } else if online == true {
            dotColor = .systemGreen
        } else {
            sub += "  ·  offline"
            dotColor = .systemRed
        }
        prefsSubField?.stringValue = sub
        prefsDot?.color = dotColor
    }

    // MARK: States list + editor

    func makeWorking(from s: StateEntry) -> WorkingState {
        let p = s.params
        var w = WorkingState(target: s.isBuiltin
            ? .builtin(Mode(rawValue: String(s.id.dropFirst("builtin:".count))) ?? .cool)
            : .custom(Int(s.id.dropFirst("custom:".count)) ?? 0),
            name: s.name, kind: 0, color: .systemOrange, temp: 3500, dimming: 70, sceneId: nil)
        w.dimming = (p["dimming"] as? Int) ?? 70
        if p["sceneId"] != nil {
            w.kind = 2
            w.sceneId = p["sceneId"] as? Int
            w.dimming = 100  // scenes always run at full brightness
        } else if p["r"] != nil {
            w.kind = 1
            w.color = rgbColor(from: p) ?? .systemOrange
        } else {
            w.kind = 0
            w.temp = (p["temp"] as? Int) ?? 3500
        }
        return w
    }

    func rgbColor(from params: [String: Any]) -> NSColor? {
        guard let r = params["r"] as? Int, let g = params["g"] as? Int, let b = params["b"] as? Int
        else { return nil }
        return NSColor(calibratedRed: CGFloat(r) / 255, green: CGFloat(g) / 255,
                       blue: CGFloat(b) / 255, alpha: 1)
    }

    func selectWorking(_ w: WorkingState) {
        working = w
        selectedStateId = nil
        if prefsWindow != nil { reloadStatesList() }
        syncWorkingToControls()
        syncPreview()
    }

    func selectFirstState() {
        let states = allStates()
        if let first = states.first {
            selectedStateId = first.id
            working = makeWorking(from: first)
        } else {
            selectedStateId = nil
            working = nil
        }
        reloadStatesList()
        syncWorkingToControls()
        syncPreview()
    }

    func storedParams(from w: WorkingState) -> [String: Any] {
        // Scenes always run at full brightness.
        let dim = (w.kind == 2) ? 100 : w.dimming
        var stored: [String: Any]
        switch w.kind {
        case 1:
            guard let c = w.color.usingColorSpace(.deviceRGB) else { return ["temp": w.temp, "dimming": w.dimming] }
            stored = ["r": Int(round(c.redComponent * 255)),
                      "g": Int(round(c.greenComponent * 255)),
                      "b": Int(round(c.blueComponent * 255)), "dimming": w.dimming]
        case 2:
            stored = ["sceneId": w.sceneId ?? 14, "dimming": dim]
        default:
            stored = ["temp": w.temp, "dimming": w.dimming]
        }
        return stored
    }

    func syncWorkingToControls() {
        guard let w = working else {
            nameField?.stringValue = ""
            kindSeg?.selectSegment(withTag: 0)
            tempSlider?.integerValue = 3500
            tempLabel?.stringValue = "3500 K"
            colorWell?.color = .systemOrange
            brightSlider?.integerValue = 70
            brightLabel?.stringValue = "70%"
            updateEditorVisibility()
            return
        }
        nameField?.stringValue = w.name
        kindSeg?.selectedSegment = w.kind
        tempSlider?.integerValue = w.temp
        tempLabel?.stringValue = "\(w.temp) K"
        colorWell?.color = w.color
        if w.kind == 2, let id = w.sceneId,
           let idx = SCENE_PRESETS.firstIndex(where: { $0.id == id }) {
            scenePopup?.selectItem(at: idx)
        }
        brightSlider?.integerValue = (w.kind == 2) ? 100 : w.dimming
        brightLabel?.stringValue = (w.kind == 2) ? "100%" : "\(w.dimming)%"
        updateEditorVisibility()
    }

    func updateEditorVisibility() {
        let kind = working?.kind ?? 0
        tempSlider?.isHidden = kind != 0
        tempLabel?.isHidden = kind != 0
        tempTitleLabel?.isHidden = kind != 0
        colorWell?.isHidden = kind != 1
        scenePopup?.isHidden = kind != 2
        kindSeg?.isHidden = working == nil
        // Scenes always run at full brightness — no slider.
        let isScene = (working?.kind ?? 0) == 2
        if isScene { working?.dimming = 100 }
        brightTitleLabel?.isHidden = isScene
        brightSlider?.isHidden = isScene
        brightLabel?.isHidden = isScene
        var isNew = false
        if let w = working, case .new = w.target { isNew = true }
        saveBtn?.title = isNew ? "Add preset" : "Save"
        // "Add preset" needs a wider button than "Save" — resize and keep
        // it right-aligned so it never truncates.
        if let save = saveBtn, let parent = save.superview {
            let w = parent.bounds.width
            let saveW: CGFloat = isNew ? 104 : 68
            save.frame = NSRect(x: w - 24 - saveW, y: 24, width: saveW, height: 26)
        }
    }

    func syncPreview() {
        if let w = working {
            let color: NSColor
            switch w.kind {
            case 1: color = w.color
            case 2: color = scenePreset(id: w.sceneId ?? 14)?.color ?? .systemOrange
            default: color = swatchColor(for: ["temp": w.temp])
            }
            preview.show(working: color, isOn: true, dimming: w.dimming)
        } else if let s = selectedStateId.flatMap({ stateById($0) }) {
            preview.show(state: s)
        } else {
            preview.show(state: nil)
        }
    }

    func reloadStatesList() {
        guard let content = statesListContent else { return }
        content.subviews.forEach { $0.removeFromSuperview() }
        let states = allStates()
        let rowH: CGFloat = 34
        let width = statesListScroll?.bounds.width ?? 396
        let scrollH = statesListScroll?.bounds.height ?? 200
        let totalH = 8 + CGFloat(max(1, states.count)) * rowH + 8
        content.frame = NSRect(x: 0, y: 0, width: width, height: max(totalH, scrollH))

        for (i, s) in states.enumerated() {
            let row = PrefRowView(frame: NSRect(x: 8, y: 8 + CGFloat(i) * rowH,
                                                width: width - 16, height: rowH))
            row.selected = (s.id == selectedStateId)
            row.set(swatch: swatchColor(for: s.params), ring: false,
                    title: s.name, detail: detailText(for: s.params))
            let isSel = s.id == selectedStateId
            row.onClick = { [self] in
                selectedStateId = s.id
                working = makeWorking(from: s)
                reloadStatesList()
                syncWorkingToControls()
                syncPreview()
                previewWorking()
            }
            row.onDoubleClick = isSel ? { [self] in syncWorkingToControls() } : row.onClick
            content.addSubview(row)
        }
    }

    // Editor actions

    @objc func nameFieldChanged() {
        working?.name = nameField.stringValue
    }

    @objc func kindChanged(_ sender: NSSegmentedControl) {
        working?.kind = sender.selectedSegment
        if sender.selectedSegment == 2 && working?.sceneId == nil {
            working?.sceneId = 14   // sensible default: Night light
            if let idx = SCENE_PRESETS.firstIndex(where: { $0.id == 14 }) {
                scenePopup.selectItem(at: idx)
            }
        }
        updateEditorVisibility()
        syncPreview()
        previewWorking()
    }

    @objc func scenePopupChanged() {
        guard let id = scenePopup.selectedItem?.representedObject as? Int else { return }
        working?.sceneId = id
        working?.kind = 2
        kindSeg.selectedSegment = 2
        updateEditorVisibility()
        syncPreview()
        previewWorking()
    }

    @objc func tempSliderChanged(_ sender: NSSlider) {
        working?.temp = Int(sender.doubleValue)
        tempLabel.stringValue = "\(working?.temp ?? 3500) K"
        syncPreview()
        previewWorking()
    }

    @objc func colorWellChanged() {
        working?.color = colorWell.color
        working?.kind = 1
        kindSeg.selectedSegment = 1
        updateEditorVisibility()
        syncPreview()
        previewWorking()
    }

    @objc func brightSliderChanged(_ sender: NSSlider) {
        working?.dimming = Int(sender.doubleValue)
        brightLabel.stringValue = "\(working?.dimming ?? 0)%"
        syncPreview()
        previewWorking()
    }

    @objc func revertClicked() {
        if let id = selectedStateId, let s = stateById(id) {
            working = makeWorking(from: s)
        } else {
            working = nil
        }
        syncWorkingToControls()
        syncPreview()
    }

    @objc func newStateClicked() {
        selectWorking(WorkingState(target: .new, name: "", kind: 0,
                                   color: .systemOrange, temp: 3500, dimming: 70, sceneId: nil))
    }

    @objc func deleteClicked() {
        guard let w = working else { return }
        let stateName: String
        let info: String
        switch w.target {
        case .custom:
            stateName = w.name.isEmpty ? "this preset" : w.name
            info = "“\(stateName)” will be removed from your menu."
        case .builtin(let m):
            stateName = m.title
            info = "The built-in preset “\(m.title)” will be removed from the menu. "
                 + "You can bring it back with “Restore presets”."
        case .new:
            return
        }
        let alert = NSAlert()
        alert.messageText = "Delete “\(stateName)”?"
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Delete")
        alert.buttons.last?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        switch w.target {
        case .custom(let i):
            customs.remove(at: i)
        case .builtin(let m):
            var o = overrides
            o.removeValue(forKey: m.rawValue)
            overrides = o
            var h = cfg["hiddenBuiltin"] as? [String] ?? []
            if !h.contains(m.rawValue) { h.append(m.rawValue) }
            cfg["hiddenBuiltin"] = h
        case .new:
            break
        }
        saveConfig(cfg)
        working = nil
        selectedStateId = nil
        afterDataChange()
        selectFirstState()
    }

    @objc func restoreBuiltinsClicked() {
        overrides = [:]
        cfg["hiddenBuiltin"] = [String]()
        saveConfig(cfg)
        // Defaults changed under the working copy — reload it so the editor
        // and the live bulb both show the restored values.
        if let id = selectedStateId, let s = stateById(id) {
            working = makeWorking(from: s)
        }
        afterDataChange()
        previewWorking()
    }

    @objc func saveClicked() {
        guard var w = working else { return }
        w.name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let stored = storedParams(from: w)
        var newSelectedId: String?
        switch w.target {
        case .new:
            let finalName = w.name.isEmpty ? "Preset \(customs.count + 1)" : w.name
            customs.append(["name": finalName, "params": stored])
            newSelectedId = "custom:\(customs.count - 1)"
        case .custom(let i):
            let finalName = w.name.isEmpty ? "Preset \(i + 1)" : w.name
            customs[i] = ["name": finalName, "params": stored]
            newSelectedId = "custom:\(i)"
        case .builtin(let m):
            var o = overrides
            if paramsEqual(stored, m.defaultParams) {
                o.removeValue(forKey: m.rawValue)  // unchanged = no override
            } else {
                o[m.rawValue] = stored
            }
            overrides = o
            newSelectedId = m.id
        }
        working = w
        saveConfig(cfg)
        selectedStateId = newSelectedId
        if let id = selectedStateId, let s = stateById(id) {
            working = makeWorking(from: s)
        }
        previewOriginal = nil   // the bulb now legitimately shows the saved state
        didPreview = false
        afterDataChange()
    }

    /// Refresh everything that can show state data.
    func afterDataChange() {
        reloadStatesList()
        reloadScenesList()
        rebuildRows()          // menu rows + updateUI
        currentId = currentStateId(from: lastPilot)
        updateUI()
        syncWorkingToControls()
        syncPreview()
    }

    // MARK: Scenes tab

    func sceneIsAdded(_ preset: ScenePreset) -> Bool {
        if customs.contains(where: { ($0["params"] as? [String: Any])?["sceneId"] as? Int == preset.id }) {
            return true
        }
        return preset.id == 14 && !(cfg["hiddenBuiltin"] as? [String] ?? []).contains("night")
    }

    /// Remove a scene from the menu (toggle-off). Drops matching customs and,
    /// for Night light, hides the builtin when no custom covers it anymore.
    /// Editor selection is shifted past the removed rows so it stays valid.
    func removeScenePreset(_ preset: ScenePreset) {
        let removed = customs.indices.filter {
            (customs[$0]["params"] as? [String: Any])?["sceneId"] as? Int == preset.id
        }
        for i in removed.reversed() { customs.remove(at: i) }
        if preset.id == 14 {
            var h = cfg["hiddenBuiltin"] as? [String] ?? []
            if !h.contains("night") { h.append("night") }
            cfg["hiddenBuiltin"] = h
        }
        saveConfig(cfg)
        if let sel = selectedStateId {
            if sel.hasPrefix("custom:"), let n = Int(sel.dropFirst("custom:".count)) {
                if removed.contains(n) {
                    selectedStateId = nil
                } else {
                    selectedStateId = "custom:\(n - removed.filter { $0 < n }.count)"
                }
            } else if sel == "builtin:night", preset.id == 14 {
                selectedStateId = nil
            }
        }
        // Rebuild the working copy when it pointed at a removed/shifted row.
        // An unsaved new preset (.new) is left untouched.
        if let w = working {
            switch w.target {
            case .new:
                break
            case .custom:
                if let id = selectedStateId, let s = stateById(id) {
                    working = makeWorking(from: s)
                } else {
                    working = nil
                }
            case .builtin(let m):
                if m == .night, preset.id == 14 {
                    working = selectedStateId.flatMap { stateById($0) }.map { makeWorking(from: $0) }
                }
            }
        }
        afterDataChange()
        if selectedStateId == nil && working == nil { selectFirstState() }
    }

    func reloadScenesList() {
        guard let content = scenesListContent, let scroll = scenesListScroll else { return }
        content.subviews.forEach { $0.removeFromSuperview() }
        let width = scroll.bounds.width
        let cols = 2
        let cellW = (width - 16 - 8) / CGFloat(cols)   // 8pt side padding + 8pt gutter
        let cellH: CGFloat = 34
        let rows = Int(ceil(Double(SCENE_PRESETS.count) / Double(cols)))
        content.frame = NSRect(x: 0, y: 0, width: width,
                               height: max(8 + CGFloat(rows) * (cellH + 6) + 8, scroll.bounds.height))

        for (i, preset) in SCENE_PRESETS.enumerated() {
            let col = i % cols
            let row = i / cols
            let cell = SceneCellView(frame: NSRect(
                x: 8 + CGFloat(col) * (cellW + 8),
                y: 8 + CGFloat(row) * (cellH + 6),
                width: cellW, height: cellH), preset: preset)
            let added = sceneIsAdded(preset)
            cell.configure(added: added)
            cell.onPreview = { [self] in
                if sceneIsAdded(preset) {
                    removeScenePreset(preset)
                } else {
                    preview.show(working: preset.color, isOn: true, dimming: 100)
                    livePreview(params: ["sceneId": preset.id, "dimming": 100])
                }
            }
            cell.onAdd = { [self] in
                if sceneIsAdded(preset) {
                    removeScenePreset(preset)
                    return
                }
                customs.append(["name": preset.name,
                                "params": ["sceneId": preset.id, "dimming": 100]])
                saveConfig(cfg)
                selectedStateId = "custom:\(customs.count - 1)"
                working = stateById(selectedStateId!).map { makeWorking(from: $0) }
                afterDataChange()
            }
            content.addSubview(cell)
        }
    }

    // MARK: Bulbs tab

    /// Every known bulb: the discovered registry plus the currently active one.
    func knownBulbMACs() -> [String] {
        var set = Set(bulbs.keys)
        if let mac = bulbMAC { set.insert(mac) }
        return set.sorted { displayName(for: $0).lowercased() < displayName(for: $1).lowercased() }
    }

    func lastIP(for mac: String) -> String? {
        bulbs[mac] ?? (mac == bulbMAC ? bulbIP : nil)
    }

    func reloadBulbsList() {
        guard let content = bulbsListContent, let scroll = bulbsListScroll else { return }
        content.subviews.forEach { $0.removeFromSuperview() }
        let macs = knownBulbMACs()
        let rowH: CGFloat = 36
        let width = scroll.bounds.width
        let scrollH = scroll.bounds.height
        let totalH = 8 + CGFloat(max(1, macs.count)) * rowH + 8
        content.frame = NSRect(x: 0, y: 0, width: width, height: max(totalH, scrollH))

        if macs.isEmpty {
            let empty = NSTextField(labelWithString: "No WiZ bulbs found yet — click “Find WiZ bulbs”.")
            empty.font = .systemFont(ofSize: 11)
            empty.textColor = .secondaryLabelColor
            empty.frame = NSRect(x: 6, y: 16, width: width - 12, height: 14)
            content.addSubview(empty)
        }
        for (i, mac) in macs.enumerated() {
            let row = PrefRowView(frame: NSRect(x: 8, y: 8 + CGFloat(i) * rowH,
                                                width: width - 16, height: rowH))
            let isActive = (mac == bulbMAC)
            row.selected = (mac == (selectedMAC ?? bulbMAC))
            row.set(swatch: isActive ? .systemGreen : .secondaryLabelColor, ring: !isActive,
                    title: displayName(for: mac),
                    detail: lastIP(for: mac) ?? "?")
            row.onClick = { [self] in
                selectedMAC = mac
                bulbRenameField.stringValue = displayName(for: mac)
                reloadBulbsList()
            }
            content.addSubview(row)
        }
        if let sel = selectedMAC ?? bulbMAC {
            bulbRenameField.stringValue = displayName(for: sel)
        }
    }

    @objc func renameBulbClicked() {
        guard let mac = selectedMAC ?? bulbMAC else { return }
        let name = bulbRenameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var a = aliases
        if name.isEmpty || name == defaultName(for: mac) {
            a.removeValue(forKey: mac)
        } else {
            a[mac] = name
        }
        aliases = a
        saveConfig(cfg)
        updateUI()
        reloadBulbsList()
        syncHeaderLabels()
    }

    @objc func setActiveBulbClicked() {
        guard let mac = selectedMAC, let ip = lastIP(for: mac) else { return }
        cfg["ip"] = ip
        cfg["mac"] = mac
        saveConfig(cfg)
        selectedStateId = nil
        working = nil
        refreshState()
        reloadBulbsList()
    }

    // MARK: App delegate end

    @objc func findBulbs() {
        guard !busy else { return }
        busy = true
        online = nil
        statusMessage = nil
        updateUI()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let found = discover()
            recordBulbs(found)
            if let first = found.first {
                cfg["ip"] = first.ip
                if let mac = first.result["mac"] as? String { cfg["mac"] = mac }
                saveConfig(cfg)
                lastPilot = first.result
                online = true
                currentId = currentStateId(from: first.result)
            } else {
                cfg.removeValue(forKey: "ip")
                online = false
                statusMessage = "no bulbs found"
            }
            DispatchQueue.main.async { [self] in
                busy = false
                updateUI()
                syncHeaderLabels()
                reloadBulbsList()
            }
        }
    }

    func menuWillOpen(_: NSMenu) {
        refreshState()
    }
}

// MARK: - Preferences row views

/// Generic selectable row used in the preferences lists.
final class PrefRowView: NSView {
    var selected = false { didSet { needsDisplay = true } }
    var hovered = false { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    let dot = DotView(frame: NSRect(x: 12, y: 12, width: 10, height: 10))
    let titleField: NSTextField
    let detailField: NSTextField

    override init(frame frameRect: NSRect) {
        titleField = NSTextField(labelWithString: "")
        detailField = NSTextField(labelWithString: "")
        super.init(frame: frameRect)

        titleField.frame = NSRect(x: 32, y: (frameRect.height - 17) / 2 + 1, width: 150, height: 17)
        titleField.font = .systemFont(ofSize: 12.5, weight: .medium)
        titleField.lineBreakMode = .byTruncatingTail
        addSubview(titleField)

        detailField.frame = NSRect(x: 184, y: (frameRect.height - 14) / 2 + 1, width: 196, height: 14)
        detailField.font = .systemFont(ofSize: 10.5)
        detailField.textColor = .secondaryLabelColor
        detailField.alignment = .right
        detailField.lineBreakMode = .byTruncatingHead
        addSubview(detailField)

        dot.frame.origin.y = (frameRect.height - 10) / 2
        addSubview(dot)
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    func set(swatch: NSColor, ring: Bool, title: String, detail: String) {
        dot.color = swatch
        dot.needsDisplay = true
        titleField.stringValue = title
        detailField.stringValue = detail
    }

    override func layout() {
        super.layout()
        titleField.frame.size.width = bounds.width - 220
        detailField.frame.origin.x = bounds.width - 208
        detailField.frame.size.width = 196
        dot.frame.origin.y = (bounds.height - 10) / 2
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount >= 2 {
            onDoubleClick?()
        } else {
            onClick?()
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        if selected || hovered {
            let box = bounds.insetBy(dx: 0, dy: 1)
            (selected ? NSColor.controlAccentColor.withAlphaComponent(0.15)
                      : NSColor.labelColor.withAlphaComponent(0.05)).setFill()
            NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
        }
    }
}

/// Soft rounded background for the editor area.
final class RoundedBoxView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0, dy: 2), xRadius: 12, yRadius: 12)
        NSColor.labelColor.withAlphaComponent(0.05).setFill()
        box.fill()
    }
}

/// Flat "＋ New preset" button attached under the states list — styled like
/// the list rows (subtle fill, 6px corners, no outline) so it fits the UI.
final class NewStateButton: NSButton {
    var hovered = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = ""
        setButtonType(.momentaryPushIn)
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func draw(_ dirtyRect: NSRect) {
        let box = bounds.insetBy(dx: 0, dy: 1)
        (hovered ? NSColor.controlAccentColor.withAlphaComponent(0.10)
                 : NSColor.labelColor.withAlphaComponent(0.05)).setFill()
        NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5).fill()

        let text = "＋  New preset"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
            .foregroundColor: hovered ? NSColor.labelColor : NSColor.secondaryLabelColor
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                            y: (bounds.height - size.height) / 2),
                                withAttributes: attrs)
    }
}

/// Top-anchored content view for scroll lists (origin at top-left).
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// One scene preset cell in the Scenes grid.
final class SceneCellView: NSView {
    var onPreview: (() -> Void)?
    var onAdd: (() -> Void)?
    private var added = false
    private var hovered = false
    private let preset: ScenePreset

    private let dot = DotView(frame: NSRect(x: 10, y: 12, width: 10, height: 10))
    private let nameField: NSTextField
    private let addButton: NSButton

    init(frame frameRect: NSRect, preset: ScenePreset) {
        self.preset = preset
        nameField = NSTextField(labelWithString: preset.name)
        addButton = NSButton(title: "", target: nil, action: nil)
        super.init(frame: frameRect)

        nameField.frame = NSRect(x: 30, y: (frameRect.height - 16) / 2, width: frameRect.width - 66, height: 16)
        nameField.font = .systemFont(ofSize: 12)
        nameField.lineBreakMode = .byTruncatingTail
        addSubview(nameField)

        addButton.bezelStyle = .rounded
        addButton.controlSize = .small
        addButton.font = .systemFont(ofSize: 11)
        addButton.frame = NSRect(x: frameRect.width - 34, y: (frameRect.height - 19) / 2, width: 28, height: 19)
        addButton.target = self
        addButton.action = #selector(addClicked)
        addSubview(addButton)

        dot.frame.origin.y = (frameRect.height - 10) / 2
        dot.color = preset.color
        addSubview(dot)

        setAdded(false)
    }

    required init?(coder: NSCoder) { fatalError("unsupported") }

    func configure(added: Bool) {
        setAdded(added)
    }

    private func setAdded(_ added: Bool) {
        self.added = added
        addButton.title = added ? "–" : "+"
        addButton.toolTip = added ? "Remove from menu" : "Add to menu"
    }

    override func layout() {
        super.layout()
        nameField.frame.size.width = bounds.width - 66
        addButton.frame.origin.x = bounds.width - 34
        dot.frame.origin.y = (bounds.height - 10) / 2
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseEnteredAndExited, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if addButton.frame.contains(p) { return }   // handled by the button
        onPreview?()
    }

    @objc private func addClicked() {
        onAdd?()
    }

    override func draw(_ dirtyRect: NSRect) {
        if hovered || added {
            let box = bounds.insetBy(dx: 0, dy: 1)
            (added ? NSColor.controlAccentColor.withAlphaComponent(0.08)
                   : NSColor.labelColor.withAlphaComponent(0.05)).setFill()
            NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)

// UI test hook: BULB_UI_TEST=1 opens the preferences window, writes its window
// number to /tmp/bulb_winid (for `screencapture -l`) and exits. Not used normally.
if ProcessInfo.processInfo.environment["BULB_UI_TEST"] == "1" {
    func snap(_ tag: String) {
        guard let win = delegate.prefsWindow, let content = win.contentView else { return }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(content.bounds.width * 2),
                                   pixelsHigh: Int(content.bounds.height * 2), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        rep?.size = content.bounds.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep!)
        content.layer?.render(in: NSGraphicsContext.current!.cgContext)
        content.displayIgnoringOpacity(content.bounds, in: NSGraphicsContext.current!)
        NSGraphicsContext.restoreGraphicsState()
        if let png = rep?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: "/tmp/bulb_prefs_\(tag).png"))
        }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
        delegate.openPreferences(newFromCapture: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            snap("states")
            delegate.tabSegment.selectedSegment = 1
            delegate.tabChanged(delegate.tabSegment)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                snap("scenes")
                delegate.tabSegment.selectedSegment = 2
                delegate.tabChanged(delegate.tabSegment)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    snap("bulbs")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }
                }
            }
        }
    }
}

app.run()
