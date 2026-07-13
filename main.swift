// ProjBar — menü çubuğunda aktif proje göstergesi + proje değiştirici.
//
// Nasıl çalışır:
//  - ~/.tmux-proj.zsh'teki hook her sekmenin projesini ~/.local/state/projbar/<tty>
//    dosyasına yazar (isim \t renk \t cwd). ProjBar bunları okur.
//  - Terminal öndeyken saniyede bir "seçili sekmenin tty'si" sorulur (AppleScript),
//    menü çubuğu o sekmenin projesini renkli ● ile gösterir.
//  - Menü: açık projeler (tıkla → o sekmeye atla) + tüm projeler (tıkla → yeni
//    sekmede aç, `pj <ad>` ile).
//  - ⌥Tab: açık projeler arasında döngü (Carbon global hotkey, izin istemez).
//
// İzin: ilk çalıştırmada macOS "ProjBar, Terminal'i kontrol etmek istiyor" diye
// sorar — bir kez İzin Ver.

import AppKit
import ApplicationServices
import Carbon.HIToolbox

let HOME = FileManager.default.homeDirectoryForCurrentUser
let PROJ_BASE = HOME.appendingPathComponent("Documents/projects")
let STATE_DIR = HOME.appendingPathComponent(".local/state/projbar")

struct TabInfo {
    let tty: String      // "ttys012"
    let project: String
    let colorHex: String
    let cwd: String
}

// ── Süreç-cwd çözümü (libproc, süreç doğurmadan) ────────────────────────────
// Hook'suz sekmelerde state dosyası yok; sekmenin tty'sindeki süreçlerin
// (zsh/claude) çalışma dizininden projeyi çıkarırız. Saf C çağrıları — spawn yok.

func ttyDev(_ tty: String) -> dev_t? {
    var st = stat()
    guard stat("/dev/" + tty, &st) == 0 else { return nil }
    return st.st_rdev
}

func cwdOfPid(_ pid: pid_t) -> String? {
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
    return withUnsafePointer(to: &info.pvi_cdir.vip_path) { p in
        p.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
    }
}

/// tty'deki süreçlerden PROJ_BASE altında cwd'si olan ilkinin proje adı.
func projectFromTTYProcesses(_ tty: String) -> String? {
    guard let dev = ttyDev(tty) else { return nil }
    let cap = 4096
    var pids = [pid_t](repeating: 0, count: cap)
    let bytes = proc_listallpids(&pids, Int32(cap * MemoryLayout<pid_t>.size))
    guard bytes > 0 else { return nil }
    let count = min(Int(bytes), cap)
    let base = PROJ_BASE.path + "/"
    for i in 0..<count {
        let pid = pids[i]
        guard pid > 0 else { continue }
        var bsd = proc_bsdinfo()
        let bs = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bs) == bs else { continue }
        guard bsd.e_tdev == UInt32(dev) else { continue }
        guard let cwd = cwdOfPid(pid), cwd.hasPrefix(base) else { continue }
        if let name = cwd.dropFirst(base.count).split(separator: "/").first.map(String.init),
           !name.isEmpty {
            return name
        }
    }
    return nil
}

/// zsh __proj_rgb256 + palet fallback'inin Swift portu — state'te rengi hiç
/// görülmemiş projeler için zsh ile AYNI deterministik renk üretilir.
func fallbackColorHex(_ name: String) -> String {
    let palette = [124, 25, 22, 54, 130, 23, 90, 94, 61, 125, 100, 53, 166, 30, 133, 65]
    let sum = name.utf8.reduce(0) { $0 + Int($1) }
    return hexFrom256(palette[sum % palette.count])
}

func hexFrom256(_ c: Int) -> String {
    let lv = [0, 95, 135, 175, 215, 255]
    var r = 0, g = 0, b = 0
    if c >= 16 && c <= 231 {
        let i = c - 16
        r = lv[i / 36]; g = lv[(i % 36) / 6]; b = lv[i % 6]
    } else if c >= 232 {
        let v = 8 + (c - 232) * 10
        r = v; g = v; b = v
    }
    return String(format: "#%02x%02x%02x", r, g, b)
}

func hexColor(_ hex: String) -> NSColor {
    var h = hex
    if h.hasPrefix("#") { h.removeFirst() }
    guard h.count == 6, let v = UInt32(h, radix: 16) else { return .systemGray }
    return NSColor(
        red: CGFloat((v >> 16) & 0xFF) / 255.0,
        green: CGFloat((v >> 8) & 0xFF) / 255.0,
        blue: CGFloat(v & 0xFF) / 255.0,
        alpha: 1.0)
}

/// State dosyalarını oku; kapanmış (tty'si kalmamış) sekmelerin kaydını temizle.
func readState() -> [TabInfo] {
    guard let files = try? FileManager.default.contentsOfDirectory(atPath: STATE_DIR.path) else { return [] }
    var out: [TabInfo] = []
    // Kapanmış sekmelerin görev etiketlerini de süpür.
    for f in files where f.hasPrefix("task-tty-") {
        let tty = String(f.dropFirst("task-tty-".count))
        if !FileManager.default.fileExists(atPath: "/dev/" + tty) {
            try? FileManager.default.removeItem(at: STATE_DIR.appendingPathComponent(f))
        }
    }
    for f in files where f.hasPrefix("tty") {
        if !FileManager.default.fileExists(atPath: "/dev/" + f) {
            try? FileManager.default.removeItem(at: STATE_DIR.appendingPathComponent(f))
            continue
        }
        guard let line = try? String(contentsOf: STATE_DIR.appendingPathComponent(f), encoding: .utf8) else { continue }
        let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\t")
        if parts.count >= 3 {
            out.append(TabInfo(tty: f, project: parts[0], colorHex: parts[1], cwd: parts[2]))
        }
    }
    return out.sorted { $0.project < $1.project }
}

@discardableResult
func runAppleScript(_ src: String) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = ["-e", src]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return nil }
    p.waitUntilExit()
    let d = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
}

func terminalRunning() -> Bool {
    NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == "com.apple.Terminal" }
}

func terminalFrontmost() -> Bool {
    NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.Terminal"
}

/// Öndeki Terminal penceresi: seçili sekmenin tty'si + pencere çerçevesi.
/// TEK AppleScript çağrısı — eskiden tty ve konum ayrı sorgulanınca rozet
/// gecikmeli geliyordu.
func frontTabInfo() -> (tty: String, frame: NSRect)? {
    guard terminalRunning() else { return nil }
    let src = """
    tell application "Terminal"
      if (count of windows) > 0 then
        set t to tty of selected tab of front window
        set b to bounds of front window
        return t & "|" & (item 1 of b) & "," & (item 2 of b) & "," & (item 3 of b) & "," & (item 4 of b)
      end if
    end tell
    """
    guard let out = runAppleScript(src), out.contains("|") else { return nil }
    let halves = out.components(separatedBy: "|")
    guard halves.count == 2, halves[0].hasPrefix("/dev/") else { return nil }
    let nums = halves[1].components(separatedBy: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
    guard nums.count == 4 else { return nil }
    // AppleScript bounds: {sol, üst, sağ, alt} — orijin ana ekranın SOL ÜSTÜ.
    // AppKit orijini sol alt → y'yi çevir.
    let primaryH = NSScreen.screens.first?.frame.height ?? 0
    let frame = NSRect(x: nums[0], y: primaryH - nums[3],
                       width: nums[2] - nums[0], height: nums[3] - nums[1])
    return (String(halves[0].dropFirst("/dev/".count)), frame)
}

func readTaskFile(_ name: String) -> String? {
    let f = STATE_DIR.appendingPathComponent(name)
    guard let s = try? String(contentsOf: f, encoding: .utf8) else { return nil }
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty { return nil }
    return t.count > 48 ? String(t.prefix(47)) + "…" : t
}

/// Görev SEKME-başına (task-tty-*); eski proje-başına dosya geçiş için fallback.
func readTask(tty: String?, project: String) -> String? {
    if let tty, let t = readTaskFile("task-tty-" + tty) { return t }
    return readTaskFile("task-" + project)
}

/// Verilen tty'nin sekmesine odaklan (pencereyi öne al + Terminal'i aktive et).
func focusTab(tty: String) {
    let src = """
    tell application "Terminal"
      repeat with w in windows
        repeat with t in tabs of w
          if tty of t is "/dev/\(tty)" then
            set selected of t to true
            set index of w to 1
            activate
            return
          end if
        end repeat
      end repeat
    end tell
    """
    runAppleScript(src)
}

/// Projeyi yeni Terminal penceresinde aç (`pj` cd'ler; boyama/başlık hook'tan gelir).
func openProject(_ name: String) {
    runAppleScript("tell application \"Terminal\" to do script \"pj \(name)\"")
    runAppleScript("tell application \"Terminal\" to activate")
}

func allProjectDirs() -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: PROJ_BASE.path))?
        .filter { name in
            var isDir: ObjCBool = false
            let full = PROJ_BASE.appendingPathComponent(name).path
            return !name.hasPrefix(".")
                && FileManager.default.fileExists(atPath: full, isDirectory: &isDir)
                && isDir.boolValue
        }
        .sorted() ?? []
}

/// Ekranın sağ üstünde HEP görünen ufak rozet — menü çubuğu otomatik gizli
/// olsa bile aktif proje görünür kalır. Tıklamaları yutmaz (click-through),
/// tam ekran dahil her Space'te durur. Terminal önde değilken gizlenir.
final class Overlay {
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let container = NSView()

    init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
        container.layer?.cornerRadius = 9
        label.font = .systemFont(ofSize: 11.5, weight: .semibold)
        label.frame.origin = NSPoint(x: 10, y: 5)
        container.addSubview(label)
        panel.contentView = container
    }

    func update(project: String?, colorHex: String?, task: String?, windowFrame: NSRect?) {
        guard let project, let colorHex else {
            panel.orderOut(nil)
            return
        }
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: "● ", attributes: [
            .foregroundColor: hexColor(colorHex),
            .font: NSFont.systemFont(ofSize: 11.5, weight: .bold),
        ]))
        s.append(NSAttributedString(string: project, attributes: [
            .foregroundColor: NSColor.white,
            .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
        ]))
        if let task {
            s.append(NSAttributedString(string: "  —  " + task, attributes: [
                .foregroundColor: NSColor.white.withAlphaComponent(0.75),
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
            ]))
        }
        label.attributedStringValue = s
        label.sizeToFit()
        label.frame.origin = NSPoint(x: 10, y: 5)
        let w = label.frame.width + 20
        let h = label.frame.height + 10

        // TERMİNAL PENCERESİNİN sağ üst köşesine — pencereyle gezer.
        // Pencere bilgisi yoksa ekranın sağ üstüne düş (eski davranış).
        var origin: NSPoint
        if let wf = windowFrame {
            origin = NSPoint(x: wf.maxX - w - 10, y: wf.maxY - h - 4)
        } else if let vf = NSScreen.main?.visibleFrame {
            origin = NSPoint(x: vf.maxX - w - 12, y: vf.maxY - h - 6)
        } else {
            return
        }
        panel.setFrame(NSRect(x: origin.x, y: origin.y, width: w, height: h), display: true)
        panel.orderFrontRegardless()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    var currentProject: String?   // öndeki sekmenin projesi (menü çubuğunda yazan)
    var hotKeyRef: EventHotKeyRef?
    var overlay: Overlay!
    // Adaptif nabız + "değişmediyse dokunma" önbellekleri
    var nextPollAt = Date.distantPast
    var fastUntil = Date.distantPast
    var lastOverlayKey = ""
    var lastTitleKey = ""
    // Olay-tabanlı (AX) mod durumu
    var axMode = false
    var axObserver: AXObserver?
    var axApp: AXUIElement?
    var axWatchedWindow: AXUIElement?
    var pollTimer: Timer?
    // proje → renk (state dosyalarından derlenir, kalıcı saklanır — sekme
    // kapansa bile renk bilinsin)
    var projectColors: [String: String] =
        (UserDefaults.standard.dictionary(forKey: "projectColors") as? [String: String]) ?? [:]
    var projectNamesCache: [String] = []
    // Başlık → (tty, proje) önbelleği. tty, SEKME-başına görev etiketi için
    // şart (aynı projede iki iş = iki sekme = iki görev). Claude Code her
    // sekmeye FARKLI başlık yazdığı için başlık pratik bir sekme-kimliği;
    // başlık değişmedikçe sıfır sorgu.
    var titleTabCache: [String: (tty: String, project: String)] = [:]
    var pendingTitleLookups: Set<String> = []
    var currentTTY: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        overlay = Overlay()
        setTitle(project: nil, colorHex: nil)

        // ─── Mod seçimi ────────────────────────────────────────────────────
        // TERCİH: olay-tabanlı AX modu — Terminal "pencere taşındı / sekme
        // değişti / başlık değişti" olaylarını KENDİSİ bildirir; boştayken
        // SIFIR sorgu, sıfır süreç. Erişilebilirlik izni ister (bir kez).
        // İzin yoksa: adaptif osascript polling'ine düşer ve izin verilir
        // verilmez kendini AX moduna yükseltir.
        if axTrusted(prompt: true), setupAX() {
            axMode = true
        } else {
            startPollingFallback()
            // izin sonradan verilirse yükselt (5 sn'de bir ucuz yerel kontrol)
            let upgrade = Timer(timeInterval: 5.0, repeats: true) { [weak self] t in
                guard let self, self.axTrusted(prompt: false), self.setupAX() else { return }
                self.axMode = true
                self.pollTimer?.invalidate()
                self.pollTimer = nil
                t.invalidate()
                self.displayRefresh()
            }
            RunLoop.main.add(upgrade, forMode: .common)
        }

        // Terminal'e geçiş/ayrılış anında tazele (olay, sorgu değil).
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.displayRefresh() }
        // Terminal yeniden başlarsa AX gözlemcisini yeniden kur.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { [weak self] n in
            guard let self, self.axMode,
                  (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                      .bundleIdentifier == "com.apple.Terminal" else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { _ = self.setupAX(); self.displayRefresh() }
        }
        // State klasörünü izle: cd/projtask anında rozet BEKLEMEDEN güncellenir.
        watchStateDir()

        registerHotKey()
        projectNamesCache = allProjectDirs()
        mergeColors(readState())
        displayRefresh()
    }

    func startPollingFallback() {
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard Date() >= self.nextPollAt else { return }
            let fast = Date() < self.fastUntil
            self.nextPollAt = Date().addingTimeInterval(fast ? 0.25 : 1.0)
            self.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    /// Moda göre tek kapı: AX'ta olaydan render, fallback'te osascript refresh.
    func displayRefresh() {
        if axMode { renderFromAX() } else { refresh(force: true) }
    }

    // ── AX (Erişilebilirlik) olay-tabanlı mod ──────────────────────────────
    func axTrusted(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    func setupAX() -> Bool {
        guard let term = NSRunningApplication
            .runningApplications(withBundleIdentifier: "com.apple.Terminal").first else { return false }
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let me = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
            DispatchQueue.main.async { me.axEvent() }
        }
        guard AXObserverCreate(term.processIdentifier, cb, &obs) == .success, let obs else { return false }
        let app = AXUIElementCreateApplication(term.processIdentifier)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        // Uygulama-seviyesi olaylar: odak/pencere değişimi + taşıma/boyutlama.
        // kAXFocusedUIElementChanged ŞART: aynı penceredeki SEKME geçişi
        // (⌘1/⌘2, sekmeye tıklama) pencere elemanını değiştirmez — ama her
        // sekmenin kendi metin alanı olduğundan odak elemanı değişir. Bu
        // olmadan sekme geçişleri görünmüyordu.
        for n in [kAXFocusedWindowChangedNotification, kAXWindowMovedNotification,
                  kAXWindowResizedNotification, kAXWindowCreatedNotification,
                  kAXFocusedUIElementChangedNotification, kAXMainWindowChangedNotification] {
            AXObserverAddNotification(obs, app, n as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        axObserver = obs
        axApp = app
        watchFocusedWindowTitle()
        return true
    }

    /// Başlık değişimi (sekme geçişi / cd'nin OSC başlığı) pencere-elemanına
    /// kayıt ister — odak her değiştiğinde yeni pencereye taşınır.
    func watchFocusedWindowTitle() {
        guard let obs = axObserver, let app = axApp else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        if let old = axWatchedWindow {
            AXObserverRemoveNotification(obs, old, kAXTitleChangedNotification as CFString)
        }
        axWatchedWindow = nil
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let winRef, CFGetTypeID(winRef) == AXUIElementGetTypeID() else { return }
        let win = winRef as! AXUIElement
        AXObserverAddNotification(obs, win, kAXTitleChangedNotification as CFString, refcon)
        axWatchedWindow = win
    }

    func axEvent() {
        watchFocusedWindowTitle()
        renderFromAX()
    }

    /// Ön penceredeki başlık + çerçeve — süreç doğurmadan, C çağrılarıyla.
    func axFrontWindowInfo() -> (title: String, frame: NSRect)? {
        guard let app = axApp else { return nil }
        var winRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &winRef) == .success,
              let winRef, CFGetTypeID(winRef) == AXUIElementGetTypeID() else { return nil }
        let win = winRef as! AXUIElement
        var t: CFTypeRef?, p: CFTypeRef?, s: CFTypeRef?
        AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &t)
        AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &p)
        AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &s)
        guard let title = t as? String else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        if let p, CFGetTypeID(p) == AXValueGetTypeID() { AXValueGetValue(p as! AXValue, .cgPoint, &pt) }
        if let s, CFGetTypeID(s) == AXValueGetTypeID() { AXValueGetValue(s as! AXValue, .cgSize, &sz) }
        // AX konumu sol-ÜST orijinli → AppKit sol-alt'a çevir.
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let frame = NSRect(x: pt.x, y: primaryH - pt.y - sz.height, width: sz.width, height: sz.height)
        return (title, frame)
    }

    /// Pencere başlığından proje adı çıkar — zsh hook'u başlığı proje adına
    /// set ediyor. Uzun ad önce (my-app / my-app-mobile karışmasın), sınır
    /// kontrollü (harf/rakam/tire bitişiğinde eşleşme sayılmaz).
    func matchProject(in title: String) -> String? {
        let boundary: (Character?) -> Bool = { c in
            guard let c else { return true }
            return !(c.isLetter || c.isNumber || c == "-" || c == "_")
        }
        for name in projectNamesCache.sorted(by: { $0.count > $1.count }) {
            var search = title.startIndex
            while let r = title.range(of: name, range: search..<title.endIndex) {
                let before = r.lowerBound == title.startIndex ? nil : title[title.index(before: r.lowerBound)]
                let after = r.upperBound == title.endIndex ? nil : title[r.upperBound]
                if boundary(before) && boundary(after) { return name }
                search = r.upperBound
            }
        }
        return nil
    }

    /// Başlıktan çözülemeyen sekme: tty'yi TEK SEFER osascript'le al, state
    /// dosyasından projeye bağla, başlığa göre cache'le. Başlık değişmedikçe
    /// bir daha sorgu yok — boşta maliyet sıfır kalır.
    func resolveTitleViaTTY(_ title: String) {
        guard !pendingTitleLookups.contains(title) else { return }
        pendingTitleLookups.insert(title)
        DispatchQueue.global(qos: .utility).async {
            let info = frontTabInfo()
            var project: String? = nil
            if let tty = info?.tty {
                let f = STATE_DIR.appendingPathComponent(tty)
                let existing = (try? String(contentsOf: f, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let parts = existing?.components(separatedBy: "\t") ?? []
                // 4. alan "auto" = dosyayı ProjBar türetip yazmış (hook'suz sekme)
                // → bayat olabilir, her seferinde yeniden türet. Hook/projbar-set
                // yazdıysa (3 alan) güvenilirdir.
                let isAuto = parts.count >= 4 && parts[3] == "auto"
                if parts.count >= 3 && !isAuto {
                    project = parts[0]
                } else if let derived = projectFromTTYProcesses(tty) {
                    // HOOK'SUZ sekme: tty süreçlerinin cwd'sinden çöz (libproc,
                    // süreç doğurmaz); state'i yaz ki menü + ⌥Tab de görsün.
                    project = derived
                    let hex = self.projectColors[derived] ?? fallbackColorHex(derived)
                    let line = "\(derived)\t\(hex)\t\(PROJ_BASE.path)/\(derived)\tauto\n"
                    // İçerik aynıysa YAZMA — yazım state-izleyiciyi tetikleyip
                    // cache temizliği → yeniden çözüm döngüsü yaratırdı.
                    if existing != line.trimmingCharacters(in: .whitespacesAndNewlines) {
                        try? line.write(to: f, atomically: true, encoding: .utf8)
                    }
                } else if parts.count >= 3 {
                    project = parts[0]   // auto-bayat ama türetilemedi → eldekiyle devam
                }
            }
            DispatchQueue.main.async {
                self.pendingTitleLookups.remove(title)
                if let project, let tty = info?.tty {
                    if self.titleTabCache.count > 100 { self.titleTabCache.removeAll() }
                    self.titleTabCache[title] = (tty: tty, project: project)
                    if self.projectColors[project] == nil {
                        self.projectColors[project] = fallbackColorHex(project)
                    }
                    self.renderFromAX()
                }
                // hiçbir yoldan çözülemediyse cache'e YAZMA — sekme sonradan
                // projeye girerse bir sonraki olayda yeniden denenir.
            }
        }
    }

    func mergeColors(_ tabs: [TabInfo]) {
        var changed = false
        for t in tabs where projectColors[t.project] != t.colorHex {
            projectColors[t.project] = t.colorHex
            changed = true
        }
        if changed { UserDefaults.standard.set(projectColors, forKey: "projectColors") }
    }

    /// AX modunun render'ı: hiçbir dış süreç yok — başlık+çerçeve AX'tan,
    /// proje/renk/görev dosya-cache'lerinden.
    func renderFromAX() {
        guard terminalFrontmost() else {
            applyOverlay(key: "HIDDEN") {
                self.overlay.update(project: nil, colorHex: nil, task: nil, windowFrame: nil)
            }
            return
        }
        guard let info = axFrontWindowInfo() else {
            applyTitle(key: "NONE") { self.setTitle(project: nil, colorHex: nil) }
            applyOverlay(key: "HIDDEN") {
                self.overlay.update(project: nil, colorHex: nil, task: nil, windowFrame: nil)
            }
            return
        }
        // 1) başlık-cache (tty+proje; sekme-başına görev için tty şart)
        // 2) başlıktan proje eşle (hook'lu sekme) — tty'yi arka planda öğren
        // 3) hiçbiri yoksa tty sorgusuyla çöz (bir kez, cache'lenir)
        let cached = titleTabCache[info.title]
        guard let project = cached?.project ?? matchProject(in: info.title) else {
            resolveTitleViaTTY(info.title)
            applyTitle(key: "NONE") { self.setTitle(project: nil, colorHex: nil) }
            applyOverlay(key: "HIDDEN") {
                self.overlay.update(project: nil, colorHex: nil, task: nil, windowFrame: nil)
            }
            return
        }
        if cached == nil {
            // proje başlıktan belli ama sekme (tty) bilinmiyor — görev etiketi
            // için öğren; render'ı bekletme.
            resolveTitleViaTTY(info.title)
        }
        currentTTY = cached?.tty
        let color = projectColors[project] ?? "#8E8E93"
        let task = readTask(tty: cached?.tty, project: project)
        let frameStr = "\(Int(info.frame.origin.x)),\(Int(info.frame.origin.y)),\(Int(info.frame.width))"
        applyTitle(key: project + "|" + color) {
            self.setTitle(project: project, colorHex: color)
        }
        applyOverlay(key: [project, color, task ?? "-", frameStr].joined(separator: "|")) {
            self.overlay.update(project: project, colorHex: color, task: task, windowFrame: info.frame)
        }
    }

    // ── State klasörü izleyici (cd / projtask → anında tazele) ────────────
    var stateWatcher: DispatchSourceFileSystemObject?
    func watchStateDir() {
        try? FileManager.default.createDirectory(at: STATE_DIR, withIntermediateDirectories: true)
        let fd = open(STATE_DIR.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write], queue: .global(qos: .utility))
        src.setEventHandler { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.projectNamesCache = allProjectDirs()
                self.mergeColors(readState())
                // tty↔proje eşleşmeleri değişmiş olabilir (cd) — cache tazelensin
                self.titleTabCache.removeAll()
                self.displayRefresh()
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        stateWatcher = src
    }

    // ── Menü çubuğu başlığı ────────────────────────────────────────────────
    func setTitle(project: String?, colorHex: String?) {
        currentProject = project
        let title = NSMutableAttributedString()
        if let project, let colorHex {
            title.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: hexColor(colorHex)]))
            title.append(NSAttributedString(string: project, attributes: [
                .font: NSFont.menuBarFont(ofSize: 0),
            ]))
        } else {
            title.append(NSAttributedString(string: "▱ proje", attributes: [
                .font: NSFont.menuBarFont(ofSize: 0),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
        }
        statusItem.button?.attributedTitle = title
    }

    func refresh(force: Bool = false) {
        // Terminal önde değilse: menü çubuğu son bilineni korur ("hangi
        // projedeydim" görünür kalsın) ama overlay rozeti gizlenir — başka
        // app'in üstünde durmasın. force = aktivasyon/menü anı.
        let front = terminalFrontmost()
        if !front {
            DispatchQueue.main.async { self.applyOverlay(key: "HIDDEN") {
                self.overlay.update(project: nil, colorHex: nil, task: nil, windowFrame: nil)
            } }
            return
        }
        DispatchQueue.global(qos: .utility).async {
            let info = frontTabInfo()
            let tabs = readState()
            let hit = info.flatMap { i in tabs.first { $0.tty == i.tty } }
            let task = hit.flatMap { readTask(tty: $0.tty, project: $0.project) }
            let frameStr = info.map { "\(Int($0.frame.origin.x)),\(Int($0.frame.origin.y)),\(Int($0.frame.width))" } ?? "-"
            DispatchQueue.main.async {
                self.mergeColors(tabs)
                if let hit {
                    self.applyTitle(key: hit.project + "|" + hit.colorHex) {
                        self.setTitle(project: hit.project, colorHex: hit.colorHex)
                    }
                    self.applyOverlay(key: [hit.project, hit.colorHex, task ?? "-", frameStr].joined(separator: "|")) {
                        self.overlay.update(project: hit.project, colorHex: hit.colorHex,
                                            task: task, windowFrame: info?.frame)
                    }
                } else {
                    if info != nil || !terminalRunning() {
                        // Terminal açık ama sekme proje dışında (veya Terminal kapalı)
                        self.applyTitle(key: "NONE") { self.setTitle(project: nil, colorHex: nil) }
                    }
                    self.applyOverlay(key: "HIDDEN") {
                        self.overlay.update(project: nil, colorHex: nil, task: nil, windowFrame: nil)
                    }
                }
            }
        }
    }

    /// Değişiklik yoksa pencere sunucusuna hiç dokunma; değişiklik varsa uygula
    /// ve 2 sn'liğine hızlı nabza geç (sürükleme/sekme geçişi akıcı izlensin).
    func applyOverlay(key: String, _ apply: () -> Void) {
        guard key != lastOverlayKey else { return }
        lastOverlayKey = key
        fastUntil = Date().addingTimeInterval(2.0)
        nextPollAt = .distantPast
        apply()
    }

    func applyTitle(key: String, _ apply: () -> Void) {
        guard key != lastTitleKey else { return }
        lastTitleKey = key
        apply()
    }

    // ── Menü ───────────────────────────────────────────────────────────────
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        projectNamesCache = allProjectDirs()
        let tabs = readState()
        mergeColors(tabs)
        var openByProject: [String: [TabInfo]] = [:]
        for t in tabs { openByProject[t.project, default: []].append(t) }

        if !tabs.isEmpty {
            menu.addItem(sectionHeader("AÇIK İŞLER  (⌥Tab ile döngü)"))
            // SEKME başına satır: aynı projede iki iş = iki satır, her biri
            // kendi görev etiketiyle — tıklayınca o sekmeye gider.
            let ordered = tabs.sorted { ($0.project, $0.tty) < ($1.project, $1.tty) }
            for t in ordered {
                let item = NSMenuItem(title: "", action: #selector(jumpToProject(_:)), keyEquivalent: "")
                let label = NSMutableAttributedString()
                label.append(NSAttributedString(string: "● ", attributes: [.foregroundColor: hexColor(t.colorHex)]))
                label.append(NSAttributedString(string: t.project))
                if let task = readTask(tty: t.tty, project: t.project) {
                    label.append(NSAttributedString(string: "  —  " + task, attributes: [
                        .foregroundColor: NSColor.secondaryLabelColor,
                        .font: NSFont.menuFont(ofSize: 11),
                    ]))
                }
                item.attributedTitle = label
                item.representedObject = t.tty
                item.target = self
                if t.tty == currentTTY || (currentTTY == nil && t.project == currentProject) {
                    item.state = .on
                }
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let closed = allProjectDirs().filter { openByProject[$0] == nil }
        if !closed.isEmpty {
            menu.addItem(sectionHeader("YENİ SEKMEDE AÇ"))
            for name in closed {
                let item = NSMenuItem(title: name, action: #selector(openProjectItem(_:)), keyEquivalent: "")
                item.representedObject = name
                item.target = self
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let quit = NSMenuItem(title: "ProjBar'ı Kapat", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    func sectionHeader(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc func jumpToProject(_ sender: NSMenuItem) {
        guard let tty = sender.representedObject as? String else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            focusTab(tty: tty)
            DispatchQueue.main.async { self.refresh(force: true) }
        }
    }

    @objc func openProjectItem(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            openProject(name)
            DispatchQueue.main.async { self.refresh(force: true) }
        }
    }

    // ── ⌥Tab: açık projeler arasında döngü ────────────────────────────────
    func registerHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, userData -> OSStatus in
            let me = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()
            me.cycleProject()
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)

        let hotKeyID = EventHotKeyID(signature: OSType(0x50524A42) /* 'PRJB' */, id: 1)
        RegisterEventHotKey(UInt32(kVK_Tab), UInt32(optionKey), hotKeyID, GetEventDispatcherTarget(), 0, &hotKeyRef)
    }

    func cycleProject() {
        DispatchQueue.global(qos: .userInitiated).async {
            // SEKME başına döngü: aynı projedeki iki iş de ziyaret edilir.
            let order = readState().sorted { ($0.project, $0.tty) < ($1.project, $1.tty) }
            guard !order.isEmpty else { return }
            let curTTY = self.currentTTY
            let curProject = self.currentProject
            var next = order[0]
            if let idx = order.firstIndex(where: { $0.tty == curTTY }) {
                next = order[(idx + 1) % order.count]
            } else if let idx = order.firstIndex(where: { $0.project == curProject }) {
                next = order[(idx + 1) % order.count]
            }
            focusTab(tty: next.tty)
            DispatchQueue.main.async {
                self.currentTTY = next.tty
                self.setTitle(project: next.project, colorHex: next.colorHex)
                // pencere öne geldikten hemen sonra rozeti yeni pencereye taşı
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                    self.displayRefresh()
                }
            }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // Dock'ta görünme, sadece menü çubuğu
let delegate = AppDelegate()
app.delegate = delegate
app.run()
