// iOS only: on the macOS host (XCTest) the native core builds without Cordova.
#if canImport(Cordova)
import Cordova
import UIKit

/// Native core entry point (spec A1). Loaded at launch via onload=true.
@objc(EdgeRumPlugin)
class EdgeRumPlugin: CDVPlugin {
    private var outbox: Outbox!
    private var sender: Sender!
    private var ticker: DispatchSourceTimer?
    private var identity = ""
    private var sdkVersion = "unknown"
    // ponytail: one id per process until session rotation lands (spec E1, issue 07).
    private let sessionId = DeviceId.newId("session")
    private let processStartedAt = EdgeRumPlugin.processStartMs()

    override func pluginInitialize() {
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
        // W3: app identity from Bundle.main, no override.
        let info = Bundle.main.infoDictionary ?? [:]
        identity = Sender.identityLine(
            name: (info["CFBundleDisplayName"] ?? info["CFBundleName"]) as? String,
            packageName: Bundle.main.bundleIdentifier,
            version: info["CFBundleShortVersionString"] as? String,
            buildNumber: info["CFBundleVersion"] as? String,
            deviceId: DeviceId().resolve())

        // T3: 30 s after the first event, within a second. T6: 30 s retry tick for parked segments.
        var ticks = 0
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.outbox.sealIfDue()
            ticks += 1
            if ticks % 30 == 0 { self.sender.trigger() }
        }
        timer.resume()
        ticker = timer

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(didEnterBackground),
                       name: UIApplication.didEnterBackgroundNotification, object: nil)
        nc.addObserver(self, selector: #selector(willEnterForeground),
                       name: UIApplication.willEnterForegroundNotification, object: nil)
        sender.trigger()
    }

    private func setting(_ name: String) -> String? {
        commandDelegate.settings.object(forKey: name) as? String
    }

    /// C1 plugin variable; the plugin.xml placeholder `unset` means missing (blank is handled by Sender).
    private func pref(_ name: String) -> String? {
        let v = setting(name)
        return v == "unset" ? nil : v
    }

    /// T3: background seals the open segment and sends, inside a background task.
    @objc private func didEnterBackground() {
        let app = UIApplication.shared
        var task = UIBackgroundTaskIdentifier.invalid
        // Main thread only: the expiration handler runs there and must end the task before returning.
        let end = {
            guard task != .invalid else { return }
            app.endBackgroundTask(task)
            task = .invalid
        }
        task = app.beginBackgroundTask(withName: "EdgeRum flush", expirationHandler: end)
        DispatchQueue.global(qos: .utility).async {
            self.outbox.seal()
            self.sender.trigger { DispatchQueue.main.async(execute: end) }
        }
    }

    @objc private func willEnterForeground() {
        sender.trigger()
    }

    @objc(getState:)
    func getState(_ command: CDVInvokedUrlCommand) {
        let state: [String: Any] = [
            "enabled": commandDelegate.settings.cordovaBoolSetting(forKey: "EdgeRumEnabled", defaultValue: true),
            "sessionId": sessionId,
            "sampled": true,
            "configured": sender.configured,
            "sdkVersion": sdkVersion,
            "deviceStartedAt": processStartedAt,
        ]
        commandDelegate.send(CDVPluginResult(status: .ok, messageAs: state), callbackId: command.callbackId)
    }

    @objc(enqueue:)
    func enqueue(_ command: CDVInvokedUrlCommand) {
        let payload = command.arguments.first as? [String: Any]
        commandDelegate.run(inBackground: {
            guard let events = payload?["events"] as? [Any] else {
                self.reply(command, error: "events missing")
                return
            }
            let lines = events.compactMap { e -> String? in
                guard e is [String: Any], JSONSerialization.isValidJSONObject(e),
                      let data = try? JSONSerialization.data(withJSONObject: e, options: .withoutEscapingSlashes)
                else { return nil }
                return String(decoding: data, as: UTF8.self)
            }
            do {
                try self.outbox.append(self.identity, lines)
                self.commandDelegate.send(CDVPluginResult(status: .ok), callbackId: command.callbackId)
            } catch {
                // Not counted here: JS counts a failed exec as a drop (A4, T8).
                NSLog("[EdgeRum] enqueue failed: \(error)")
                self.reply(command, error: error.localizedDescription)
            }
            self.sender.trigger()
        })
    }

    @objc(configure:)
    func configure(_ command: CDVInvokedUrlCommand) {
        if let opts = command.arguments.first as? [String: Any] {
            // From init(); runtime only, never persisted (C1).
            sender.configure(apiKey: opts["apiKey"] as? String, url: opts["endpoint"] as? String)
            sender.trigger()
        }
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
