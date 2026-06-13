import Cocoa
import Carbon
import Vision
import UserNotifications
import UniformTypeIdentifiers

// MARK: - Global hotkeys (Carbon — no Accessibility permission required)

final class HotKeyManager {
    static let shared = HotKeyManager()
    private var handlers: [UInt32: () -> Void] = [:]
    private var refs: [EventHotKeyRef] = []
    private var installed = false

    private func installHandlerIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &hkID)
            if let handler = HotKeyManager.shared.handlers[hkID.id] {
                DispatchQueue.main.async { handler() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }

    func register(keyCode: UInt32, modifiers: UInt32, id: UInt32, handler: @escaping () -> Void) {
        installHandlerIfNeeded()
        handlers[id] = handler
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x534E4350) /* 'SNCP' */, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref = ref {
            refs.append(ref)
        } else {
            NSLog("SnapCopy: failed to register hotkey id \(id) (status \(status))")
        }
    }
}

// MARK: - Screen capture / recognition / clipboard

/// Appends a line to ~/snapcopy-debug.log for troubleshooting.
enum Grab {
    /// Launches the native interactive selection (crosshair). Returns the CGImage,
    /// or nil if the user pressed Escape / made no selection.
    static func captureSelection() -> CGImage? {
        let path = NSTemporaryDirectory() + "snapcopy-\(UUID().uuidString).png"
        let url = URL(fileURLWithPath: path)
        defer { try? FileManager.default.removeItem(at: url) }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -i interactive selection, -x no capture sound
        task.arguments = ["-i", "-x", path]
        do { try task.run() } catch { return nil }
        task.waitUntilExit()

        guard FileManager.default.fileExists(atPath: path),
              let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let lazy = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }

        // Materialize the pixels into a standalone bitmap. The decoded image above is
        // lazily backed by the temp file, and recognition runs asynchronously — by then
        // `defer` has deleted the file, leaving Vision nothing to read. Drawing into our
        // own context forces the decode now, while the file still exists.
        return materialize(lazy)
    }

    /// Draws a (possibly lazily-backed) CGImage into an in-memory bitmap so its pixels
    /// are fully owned and independent of any source file.
    private static func materialize(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0,
              let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    static func recognizeText(in image: CGImage, completion: @escaping (String?) -> Void) {
        let request = VNRecognizeTextRequest { req, _ in
            let lines = (req.results as? [VNRecognizedTextObservation] ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
            completion(lines.isEmpty ? nil : lines.joined(separator: "\n"))
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        perform(request, on: image, completion: completion)
    }

    static func scanCodes(in image: CGImage, completion: @escaping (String?) -> Void) {
        let request = VNDetectBarcodesRequest { req, _ in
            let payloads = (req.results as? [VNBarcodeObservation] ?? [])
                .compactMap { $0.payloadStringValue }
            completion(payloads.isEmpty ? nil : payloads.joined(separator: "\n"))
        }
        perform(request, on: image, completion: completion)
    }

    private static func perform(_ request: VNImageBasedRequest,
                                on image: CGImage,
                                completion: @escaping (String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
            } catch {
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }

    static func copyToClipboard(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }
}

// MARK: - Notifications

enum Notifier {
    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func show(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var busy = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        UNUserNotificationCenter.current().delegate = self
        Notifier.requestAuthorization()

        setupStatusItem()
        setupHotKeys()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "text.viewfinder",
                                   accessibilityDescription: "SnapCopy")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()

        let textItem = NSMenuItem(title: "Select Text",
                                  action: #selector(selectText),
                                  keyEquivalent: "")
        textItem.target = self
        menu.addItem(textItem)

        let qrItem = NSMenuItem(title: "Select QR Code",
                                action: #selector(selectQR),
                                keyEquivalent: "")
        qrItem.target = self
        menu.addItem(qrItem)

        menu.addItem(.separator())

        // Show the keyboard hints as disabled rows so the user knows the shortcuts.
        let hint1 = NSMenuItem(title: "  ⌃S  Select Text", action: nil, keyEquivalent: "")
        hint1.isEnabled = false
        menu.addItem(hint1)
        let hint2 = NSMenuItem(title: "  ⌃Q  Select QR Code", action: nil, keyEquivalent: "")
        hint2.isEnabled = false
        menu.addItem(hint2)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit SnapCopy",
                              action: #selector(NSApplication.terminate(_:)),
                              keyEquivalent: "q")
        menu.addItem(quit)

        statusItem.menu = menu
    }

    private func setupHotKeys() {
        // ⌃S -> Select Text, ⌃Q -> Select QR Code
        HotKeyManager.shared.register(keyCode: UInt32(kVK_ANSI_S),
                                      modifiers: UInt32(controlKey),
                                      id: 1) { [weak self] in self?.selectText() }
        HotKeyManager.shared.register(keyCode: UInt32(kVK_ANSI_Q),
                                      modifiers: UInt32(controlKey),
                                      id: 2) { [weak self] in self?.selectQR() }
    }

    // MARK: Actions

    @objc private func selectText() { run(mode: .text) }
    @objc private func selectQR() { run(mode: .qr) }

    private enum Mode { case text, qr }

    private func run(mode: Mode) {
        guard !busy else { return }
        busy = true

        // Let the menu close before the crosshair appears.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard let image = Grab.captureSelection() else {
                self.busy = false   // user cancelled — stay quiet
                return
            }

            let finish: (String?) -> Void = { result in
                DispatchQueue.main.async {
                    self.busy = false
                    guard let result = result, !result.isEmpty else {
                        Notifier.show(title: "SnapCopy",
                                      body: mode == .text ? "No text found" : "No code found")
                        return
                    }
                    Grab.copyToClipboard(result)
                    let preview = result.count > 60
                        ? String(result.prefix(60)) + "…"
                        : result
                    Notifier.show(title: "Copied", body: preview)
                }
            }

            switch mode {
            case .text: Grab.recognizeText(in: image, completion: finish)
            case .qr:   Grab.scanCodes(in: image, completion: finish)
            }
        }
    }

    // Show banners even while the app is frontmost/agent.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
