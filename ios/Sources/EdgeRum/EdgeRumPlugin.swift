// iOS only: on the macOS host (XCTest) the native core builds without Cordova.
#if canImport(Cordova)
import Cordova
import EdgeRumCrash
import Network
import UIKit
import WebKit

/// Native core entry point (spec A1). Loaded at launch via onload=true.
@objc(EdgeRumPlugin)
class EdgeRumPlugin: CDVPlugin {
    private var outbox: Outbox!
    private var sender: Sender!
    private var ticker: DispatchSourceTimer?
    /// Serial: every state-changing action, so a disable can't interleave an append.
    private let worker = DispatchQueue(label: "com.nathanclaire.rum.worker")
    private var user: User!
    private var session: Session!
    private var consent: Consent!
    private var crash: Crash!
    private var watchdog: Watchdog!
    /// Watchdog is foreground only (E15). Main thread only.
    private var foreground = false
    private var subscriber: String?
    private var identity = ""
    private var sdkVersion = "unknown"
    private let processStartedAt = EdgeRumPlugin.processStartMs()
    private var launch: Launch!
    /// A6 fallback, when the hook is off. Worker queue only.
    private var pageWatch = PageWatch()
    /// E32: launch-time device context; `network.type` is added per event.
    private var device: [String: Any] = [:]
    /// E26: last path transport; nil until the first reading.
    private var networkType: String?
    private let networkLock = NSLock()
    private var pathMonitor: NWPathMonitor?

    override func pluginInitialize() {
        // A5: onload plugins start in viewDidLoad, once the WebView exists; close enough to "WebView created".
        launch = Launch(processStart: processStartedAt, webViewCreated: Outbox.now())
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("edge_rum")
        let health = Health(dir: dir)
        outbox = Outbox(dir: dir, health: health)
        if let v = setting("EdgeRumSdkVersion") {
            sdkVersion = v
        } else {
            // plugin.xml always writes it; missing means a hand-edited config.xml.
            NSLog("[EdgeRum] EdgeRumSdkVersion preference missing; reinstall the plugin")
        }
        sender = Sender(outbox: outbox, health: health, sdkVersion: sdkVersion)
        sender.configure(apiKey: pref("EDGE_RUM_API_KEY"), url: pref("EDGE_RUM_ENDPOINT"))
        let deviceId = DeviceId()
        identity = Self.identityLine(deviceId.resolve())
        let user = User(defaults: .standard)
        self.user = user
        session = Session(defaults: .standard, health: health, sampleRate: Session.sampleRate(setting("EdgeRumSampleRate")),
                          userId: { user.id })
        consent = Consent(defaults: .standard,
                          prefEnabled: bool("EdgeRumEnabled", true),
                          session: session, user: user, outbox: outbox, deviceId: deviceId)
        device = Self.deviceContext()
        session.context = { [weak self] in self?.context() ?? [:] }
        crash = Crash(dir: dir)
        let hangMs = bool("EdgeRumHang", true)
            ? Int64(setting("EdgeRumHangTimeoutMs") ?? "") ?? 2000 : 0
        watchdog = Watchdog(hangMs: hangMs) { [weak self] ms in
            guard let self else { return }
            // Read now, while main is still stuck; recorded on the worker.
            let frames = Crash.mainStack()
            self.worker.async { self.solo(self.crash.hang(durationMs: ms, frames: frames)) }
        }
        foreground = UIApplication.shared.applicationState != .background
        let launchedForeground = foreground

        worker.async {
            // T4: last launch's crash, under the identity it crashed with. Gone either way.
            if let p = self.crash.takeReport(), self.consent.enabled { self.writeSolo(p.identity, p.event) }
            let timeout = Launch.takeTimeout(.standard)
            // P7: opt-in mode arms nothing until enable().
            guard self.consent.enabled else { return }
            self.append(self.session.begin())
            self.record(Self.list(timeout))
            if launchedForeground { self.record([Signals.lifecycle("foregrounded", at: Outbox.now())]) } // E2, as Android onStart
            // Armed after the context exists, so a crash always has one to replay under.
            self.saveCrashContext()
            self.arm()
        }

        // E23: opt-in periodic memory, foreground only, on the 1 s tick.
        let memoryEvery = bool("EdgeRumMemorySampling", false)
            ? max(1, (Int(setting("EdgeRumMemorySamplingIntervalMs") ?? "") ?? 30_000) / 1000) : 0
        // T3: 30 s after the first event, within a second. T6: 30 s retry tick for parked segments.
        var ticks = 0
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.outbox.sealIfDue()
            ticks += 1
            if ticks % 30 == 0 { self.sender.trigger() }
            if memoryEvery > 0 && ticks % memoryEvery == 0 {
                DispatchQueue.main.async {
                    if self.foreground { self.worker.async { self.sampleMemory("periodic") } }
                }
            }
        }
        timer.resume()
        ticker = timer

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(didEnterBackground),
                       name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(willEnterForeground),
                       name: UIApplication.willEnterForegroundNotification, object: nil)

        // A7: no deviceready by the timeout → marker for next launch. Backgrounded on the splash
        // screen isn't a timeout.
        let readyTimeoutMs = Int64(setting("EdgeRumDevicereadyTimeoutMs") ?? "") ?? 10_000
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(Int(readyTimeoutMs))) {
            let foreground = self.foreground
            self.worker.async {
                if self.consent.enabled && foreground && !self.launch.devicereadySeen {
                    Launch.timedOut(.standard, timeoutMs: readyTimeoutMs, now: Outbox.now())
                }
            }
        }
        watchWebView()
        watchNetwork()
        sender.trigger()
    }

    /// A6 / E13: the swizzle on tested cordova-ios; otherwise inference on each page load.
    private func watchWebView() {
        let hooked = WebViewHook.install(NSClassFromString("CDVWebViewEngine"),
                                         cordovaMajor: Int(CORDOVA_VERSION_MIN_REQUIRED) / 10_000,
                                         enabled: bool("EdgeRumIosWebViewHook", true)) { [weak self] in
            guard let self else { return }
            self.worker.async { self.solo(self.crash.webViewTerminated(detectedBy: "callback")) }
        }
        let engine: AnyClass? = NSClassFromString("CDVWebViewEngine")
        // Main thread (Cordova posts from the navigation delegate).
        NotificationCenter.default.addObserver(forName: .CDVPageDidLoad, object: nil, queue: nil) { [weak self] note in
            guard let self, let view = note.object as? WKWebView else { return }
            // The hook only sees deaths while the engine is still the delegate; a host VC or
            // another plugin can take that over (CDVWebViewEngine.m `updateWithInfo:`).
            if hooked, let engine, (view.navigationDelegate as AnyObject?)?.isKind(of: engine) == true { return }
            let url = view.url
            self.worker.async {
                if self.pageWatch.loaded(url) { self.solo(self.crash.webViewTerminated(detectedBy: "inference")) }
            }
        }
    }

    /// E26: path transport changes → `network_change`; the first reading only seeds `network.type`.
    private func watchNetwork() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { self?.networkChanged("none"); return }
            self?.networkChanged(path.usesInterfaceType(.wifi) ? "wifi" : path.usesInterfaceType(.cellular) ? "cellular"
                          : path.usesInterfaceType(.wiredEthernet) ? "ethernet" : "other")
        }
        monitor.start(queue: DispatchQueue(label: "com.nathanclaire.rum.network"))
        pathMonitor = monitor
    }

    private func networkChanged(_ type: String) {
        networkLock.lock()
        let previous = networkType
        networkType = type
        networkLock.unlock()
        guard let previous, previous != type else { return }
        let at = Outbox.now()
        worker.async { self.recordPassive([Signals.network(previous: previous, current: type, at: at)]) }
        // T6: connectivity regained retries parked segments.
        if previous == "none" { sender.trigger() }
    }

    /// E32: device context plus the current `network.type`, stamped by the session gate.
    private func context() -> [String: Any] {
        networkLock.lock(); defer { networkLock.unlock() }
        var c = device
        c["network.type"] = networkType
        return c
    }

    /// Main thread (UIKit).
    private static func deviceContext() -> [String: Any] {
        var u = utsname()
        uname(&u)
        let machine = withUnsafeBytes(of: &u.machine) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let screen = UIScreen.main
        #if arch(arm64)
        let abi = "arm64"
        #else
        let abi = "x86_64"
        #endif
        return [
            "device.platform": "ios",
            "device.platform_version": UIDevice.current.systemVersion,
            // The simulator reports the host's arch; it names the device it plays.
            "device.model": ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? machine,
            "device.manufacturer": "Apple",
            "device.brand": "Apple",
            "device.locale": Locale.current.identifier.replacingOccurrences(of: "_", with: "-"),
            "device.timezone": TimeZone.current.identifier,
            "device.dark_mode": UITraitCollection.current.userInterfaceStyle == .dark,
            "device.cpu_abi": abi,
            "device.cpu_cores": ProcessInfo.processInfo.activeProcessorCount,
            "device.screen_density": Int(screen.scale * 160), // dpi, as Android densityDpi (1x = 160)
            "device.screen_width_px": Int(screen.nativeBounds.width),
            "device.screen_height_px": Int(screen.nativeBounds.height),
            "display.refresh_rate": screen.maximumFramesPerSecond,
        ]
    }

    /// E24: memory warning → `memory_pressure`.
    override func onMemoryWarning() {
        let at = Outbox.now()
        let footprint = Signals.footprintBytes()
        worker.async { self.recordPassive([Signals.pressure(footprint: footprint, at: at)]) }
    }

    /// Worker queue only: consent (P7), then the session gate.
    private func record(_ events: [[String: Any]]) {
        if !events.isEmpty && consent.enabled { _ = admit(events) }
    }

    /// Background-capable native signals: the gate that isn't session activity.
    private func recordPassive(_ events: [[String: Any]]) {
        if !events.isEmpty && consent.enabled { append(session.admitPassive(events)) }
    }

    /// E22 / E23: footprint + RSS. Worker queue only.
    private func sampleMemory(_ source: String) {
        recordPassive(Signals.memory(footprint: Signals.footprintBytes(), resident: Signals.residentBytes(), source: source,
                                     at: Outbox.now()))
    }

    /// E22: a new session gets its memory bookend, in the same segment (before any background seal).
    /// Worker queue only.
    // ponytail: substring check on serialized lines; Session returns strings, not events.
    private func sampleIfStarted(_ lines: [String]) {
        if lines.contains(where: { $0.contains(#""eventName":"session.started""#) }) { sampleMemory("session_start") }
    }

    private static func list(_ e: [String: Any]?) -> [[String: Any]] {
        e.map { [$0] } ?? []
    }

    /// Worker queue only: `app.start` without `markReady`, if still owed.
    private func finishLaunch() {
        record(Self.list(launch.finish()))
    }

    /// A5: JS phase marks; `deviceready` opens the `markReady` window. A6: `pagehide` is the clean
    /// shutdown the inference looks for.
    @objc(markPhase:)
    func markPhase(_ command: CDVInvokedUrlCommand) {
        let opts = command.arguments.first as? [String: Any]
        worker.async {
            defer { self.ok(command) }
            guard let phase = opts?["phase"] as? String else { return }
            if phase == "pagehide" { return self.pageWatch.hidden() }
            let ts = (opts?["ts"] as? NSNumber)?.int64Value ?? Outbox.now()
            if let start = self.launch.mark(phase, ts) {
                self.record([start])
            } else if phase == Launch.deviceready {
                self.worker.asyncAfter(deadline: .now() + .milliseconds(Int(Launch.readyWindowMs))) { self.finishLaunch() }
            }
        }
    }

    /// W3: app identity from Bundle.main, no override.
    private static func identityLine(_ deviceId: String) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        return Sender.identityLine(
            name: (info["CFBundleDisplayName"] ?? info["CFBundleName"]) as? String,
            packageName: Bundle.main.bundleIdentifier,
            version: info["CFBundleShortVersionString"] as? String,
            buildNumber: info["CFBundleVersion"] as? String,
            deviceId: deviceId)
    }

    private func setting(_ name: String) -> String? {
        // cordova-ios stores preference names lowercased; this lookup lowercases too.
        commandDelegate.settings.cordovaSetting(forKey: name) as? String
    }

    private func bool(_ name: String, _ fallback: Bool) -> Bool {
        commandDelegate.settings.cordovaBoolSetting(forKey: name, defaultValue: fallback)
    }

    /// C1 plugin variable; the plugin.xml placeholder `unset` means missing (blank is handled by Sender).
    private func pref(_ name: String) -> String? {
        let v = setting(name)
        return v == "unset" ? nil : v
    }

    /// E12, E15: crash handlers once per process (main thread: its alternate signal stack); the
    /// watchdog while in the foreground. Any queue.
    private func arm() {
        let path = crash.reportPath
        DispatchQueue.main.async {
            edge_rum_crash_install(path)
            if self.foreground { self.watchdog.start() }
        }
    }

    /// T4: a native crash / hang record becomes its own segment under the running build's
    /// identity, after the session gate (a hang follows the roll, S2). Worker queue only.
    private func solo(_ event: [String: Any]) {
        guard consent.enabled else { return }
        let before = session.id
        let lines = session.admit([event])
        for line in lines { writeSolo(identity, line) }
        sampleIfStarted(lines)
        if before != nil && before != session.id { notify("session") }
    }

    private func writeSolo(_ identity: String, _ line: String) {
        do {
            try outbox.writeSolo(identity, line)
            sender.trigger()
        } catch {
            NSLog("[EdgeRum] solo segment failed: \(error)")
        }
    }

    /// What a later crash report replays under (T4). Worker queue only.
    private func saveCrashContext() {
        crash.saveContext(identity: identity, sessionId: session.id, userId: user.id)
    }

    /// T3: background seals the open segment and sends, inside a background task. E2 background;
    /// E22 end bookend (every background may be the session's last: it ends after the idle
    /// timeout, unobserved); A5: an owed `app.start` goes now. All appended before the seal.
    @objc private func didEnterBackground() {
        let at = Outbox.now()
        foreground = false
        watchdog.stop()
        let app = UIApplication.shared
        var task = UIBackgroundTaskIdentifier.invalid
        // Main thread only: the expiration handler runs there and must end the task before returning.
        let end = {
            guard task != .invalid else { return }
            app.endBackgroundTask(task)
            task = .invalid
        }
        task = app.beginBackgroundTask(withName: "EdgeRum flush", expirationHandler: end)
        worker.async {
            self.record([Signals.lifecycle("backgrounded", at: at)])
            self.finishLaunch()
            self.sampleMemory("session_end")
            self.outbox.seal()
            self.sender.trigger { DispatchQueue.main.async(execute: end) }
        }
    }

    @objc private func willEnterForeground() {
        let at = Outbox.now()
        foreground = true
        if consent.enabled { watchdog.start() }
        worker.async {
            // E1: a foreground after the idle timeout starts a new session.
            let bookends = self.consent.enabled ? self.session.rotateIfIdle() : []
            if !bookends.isEmpty {
                self.append(bookends)
                self.notify("session")
            }
            self.record([Signals.lifecycle("foregrounded", at: at)]) // E2
            self.sender.trigger()
        }
    }

    @objc(getState:)
    func getState(_ command: CDVInvokedUrlCommand) {
        // On the worker: after the launch session.begin(), never mid reset/disable.
        commandDelegate.send(CDVPluginResult(status: .ok, messageAs: worker.sync { state() }), callbackId: command.callbackId)
    }

    private func state() -> [String: Any] {
        let id = session.id
        return [
            "enabled": consent.enabled,
            "sessionId": id ?? NSNull(),
            "userId": user.id ?? NSNull(),
            "sampled": id != nil && session.sampled,
            "configured": sender.configured,
            "sdkVersion": sdkVersion,
            "deviceStartedAt": processStartedAt,
        ]
    }

    /// A2 `subscribe`: `{ type, …state }` on the kept callback.
    @objc(subscribe:)
    func subscribe(_ command: CDVInvokedUrlCommand) {
        worker.async { self.subscriber = command.callbackId }
        let keep = CDVPluginResult(status: .noResult)
        keep.setKeepCallbackAs(true)
        commandDelegate.send(keep, callbackId: command.callbackId)
    }

    /// Worker queue only.
    private func notify(_ type: String) {
        guard let cb = subscriber else { return }
        var s = state()
        s["type"] = type
        let r = CDVPluginResult(status: .ok, messageAs: s)
        r.setKeepCallbackAs(true)
        commandDelegate.send(r, callbackId: cb)
    }

    @objc(enqueue:)
    func enqueue(_ command: CDVInvokedUrlCommand) {
        let payload = command.arguments.first as? [String: Any]
        worker.async {
            guard let events = payload?["events"] as? [Any] else {
                self.reply(command, error: "events missing")
                return
            }
            // P7: opt-in mode / disabled → nothing captured or buffered.
            // Not counted on failure: JS counts a failed exec as a drop (A4, T8).
            guard self.consent.enabled else { return self.ok(command) }
            if let payload { self.crash.mirror(payload) }
            let ok = self.admit(events.compactMap { $0 as? [String: Any] })
            self.saveCrashContext()
            if ok {
                self.ok(command)
            } else {
                self.reply(command, error: "append failed")
            }
        }
    }

    /// S5: every event goes through the session gate on its way into the outbox. Worker queue only.
    private func admit(_ events: [[String: Any]]) -> Bool {
        let before = session.id
        let ok = append(session.admit(events))
        if before != nil && before != session.id { notify("session") }
        return ok
    }

    /// Worker queue only. - Returns: false when nothing was given or the append failed.
    @discardableResult
    private func append(_ lines: [String]) -> Bool {
        guard !lines.isEmpty else { return true }
        do {
            try outbox.append(identity, lines)
            sampleIfStarted(lines)
            sender.trigger()
            return true
        } catch {
            NSLog("[EdgeRum] append failed: \(error)")
            return false
        }
    }

    /// P6: persisted traits; a trait change becomes one `user.profile.update`.
    @objc(identify:)
    func identify(_ command: CDVInvokedUrlCommand) {
        let traits = command.arguments.first as? [String: Any]
        worker.async {
            if let traits, self.consent.enabled, let update = self.user.identify(traits) { _ = self.admit([update]) }
            self.ok(command)
        }
    }

    @objc(clearUser:)
    func clearUser(_ command: CDVInvokedUrlCommand) {
        worker.async {
            self.user.clear()
            self.ok(command)
        }
    }

    @objc(enable:)
    func enable(_ command: CDVInvokedUrlCommand) {
        worker.async { self.setEnabled(true, command) }
    }

    @objc(disable:)
    func disable(_ command: CDVInvokedUrlCommand) {
        worker.async { self.setEnabled(false, command) }
    }

    private func setEnabled(_ on: Bool, _ command: CDVInvokedUrlCommand) {
        let was = consent.enabled
        append(consent.setEnabled(on))
        if on {
            saveCrashContext()
            arm()
        } else {
            DispatchQueue.main.async { self.watchdog.stop() }
            crash.clear()
        }
        if was != on { notify("enabled") }
        ok(command)
    }

    /// P7: new device_id and session, user and outbox cleared; enabled state untouched.
    @objc(reset:)
    func reset(_ command: CDVInvokedUrlCommand) {
        worker.async {
            self.identity = Self.identityLine(self.consent.reset())
            self.crash.clear()
            if self.consent.enabled {
                self.append(self.session.restart())
                self.saveCrashContext()
                self.notify("session")
            }
            self.ok(command)
        }
    }

    @objc(configure:)
    func configure(_ command: CDVInvokedUrlCommand) {
        if let opts = command.arguments.first as? [String: Any] {
            // From init(); runtime only, never persisted (C1).
            sender.configure(apiKey: opts["apiKey"] as? String, url: opts["endpoint"] as? String)
            sender.trigger()
        }
        ok(command)
    }

    private func ok(_ command: CDVInvokedUrlCommand) {
        commandDelegate.send(CDVPluginResult(status: .ok), callbackId: command.callbackId)
    }

    private func reply(_ command: CDVInvokedUrlCommand, error: String) {
        commandDelegate.send(CDVPluginResult(status: .error, messageAs: error), callbackId: command.callbackId)
    }

    /// Process start, epoch ms (`kinfo_proc.p_starttime`); now if sysctl fails.
    private static func processStartMs() -> Int64 {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Outbox.now() }
        let t = info.kp_proc.p_un.__p_starttime
        return Int64(t.tv_sec) * 1000 + Int64(t.tv_usec) / 1000
    }
}
#endif
