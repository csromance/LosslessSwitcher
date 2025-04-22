//
//  AppDelegate.swift
//  Quality
//
//  Created by Vincent Neo on 21/4/22.
//

import Cocoa
import Combine
import SimplyCoreAudio
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) var instance: AppDelegate! = nil

    var outputDevices: OutputDevices!
    private let defaults = Defaults.shared
    var devicesMenu: NSMenu!

    var statusItem: NSStatusItem?
    var cancellable: AnyCancellable?
    var currentScriptSelectionMenuItem: NSMenuItem?

    private var lastPersistentID: String?

    private var _statusItemTitle = "Loading..."
    var statusItemTitle: String {
        get { _statusItemTitle }
        set {
            _statusItemTitle = newValue
            statusItemDisplay()
        }
    }

    func checkPermissions() {
        User.current.isAdmin { isAdmin in
            DispatchQueue.main.async {
                if !isAdmin {
                    let alert = NSAlert()
                    alert.messageText = "Requires Privileges"
                    alert.informativeText =
                        "LosslessSwitcher requires Administrator privileges to detect lossless sample rates."
                    alert.alertStyle = .critical
                    alert.runModal()
                    NSApp.terminate(self)
                }
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.instance = self
        outputDevices = OutputDevices()

        DistributedNotificationCenter.default.addObserver(
            self,
            selector: #selector(trackChanged(_:)),
            name: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil
        )

        // Fetch immediately on launch
        outputDevices.switchLatestSampleRate()

        checkPermissions()

        // Build status bar menu
        let menu = NSMenu()
        menu.delegate = self

        // Current sample rate view
        let sampleRateView = ContentView().environmentObject(outputDevices)
        let rateHosting = NSHostingView(rootView: sampleRateView)
        rateHosting.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        let rateItem = NSMenuItem()
        rateItem.view = rateHosting
        menu.addItem(rateItem)

        menu.addItem(NSMenuItem.separator())

        // Toggle status item title
        let titleItem = NSMenuItem(
            title: defaults.statusBarItemTitle,
            action: #selector(toggleSampleRate(item:)),
            keyEquivalent: ""
        )
        menu.addItem(titleItem)

        // Bit depth switch
        let bitDepthItem = NSMenuItem(
            title: "Bit Depth Switching",
            action: #selector(toggleBitDepthDetection(item:)),
            keyEquivalent: ""
        )
        bitDepthItem.state = defaults.userPreferBitDepthDetection ? .on : .off
        menu.addItem(bitDepthItem)

        // Devices submenu
        let devicesItem = NSMenuItem(
            title: "Selected Device",
            action: nil,
            keyEquivalent: ""
        )
        devicesMenu = NSMenu()
        devicesItem.submenu = devicesMenu
        menu.addItem(devicesItem)
        handleDevicesMenu()

        menu.addItem(NSMenuItem.separator())

        // About submenu
        let aboutItem = NSMenuItem(
            title: "About",
            action: nil,
            keyEquivalent: ""
        )
        let version = NSMenuItem(
            title: "Version - \(currentVersion)",
            action: nil,
            keyEquivalent: ""
        )
        let build = NSMenuItem(
            title: "Build   - \(currentBuild)",
            action: nil,
            keyEquivalent: ""
        )
        aboutItem.submenu = NSMenu()
        aboutItem.submenu?.addItem(version)
        aboutItem.submenu?.addItem(build)
        menu.addItem(aboutItem)

        // Scripting submenu
        let scriptItem = NSMenuItem(
            title: "Scripting",
            action: nil,
            keyEquivalent: ""
        )
        let selectScript = NSMenuItem(
            title: "Select Script…",
            action: #selector(selectScript(_:)),
            keyEquivalent: ""
        )
        let clearScript = NSMenuItem(
            title: "Clear selection",
            action: #selector(resetScript(_:)),
            keyEquivalent: ""
        )
        currentScriptSelectionMenuItem = NSMenuItem(
            title: "No selection",
            action: nil,
            keyEquivalent: ""
        )
        scriptItem.submenu = NSMenu()
        scriptItem.submenu?.addItem(selectScript)
        scriptItem.submenu?.addItem(clearScript)
        scriptItem.submenu?.addItem(currentScriptSelectionMenuItem!)
        menu.addItem(scriptItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(NSApp.terminate(_:)),
            keyEquivalent: ""
        )
        menu.addItem(quitItem)

        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        statusItem?.menu = menu
        statusItem?.button?.title = "Loading..."
        statusItemDisplay()

        // Listen for device list changes to rebuild menu
        cancellable = NotificationCenter.default.publisher(
            for: .deviceListChanged
        )
        .sink { [weak self] _ in
            self?.handleDevicesMenu()
        }
    }

    func handleDevicesMenu() {
        devicesMenu.removeAllItems()
        let auto = DeviceMenuItem(
            title: "Default Device",
            action: #selector(deviceSelection(_:)),
            keyEquivalent: "",
            device: nil
        )
        auto.tag = -1
        devicesMenu.addItem(auto)

        let selectedUID = Defaults.shared.selectedDeviceUID
        if let uid = selectedUID,
            outputDevices.outputDevices.contains(where: { $0.uid == uid })
        {
            // keep selection
        } else {
            auto.state = .on
            outputDevices.selectedOutputDevice = nil
        }

        for (idx, device) in outputDevices.outputDevices.enumerated() {
            let item = DeviceMenuItem(
                title: device.name,
                action: #selector(deviceSelection(_:)),
                keyEquivalent: "",
                device: device
            )
            item.tag = idx
            if device.uid == Defaults.shared.selectedDeviceUID {
                item.state = .on
                outputDevices.selectedOutputDevice = device
            }
            devicesMenu.addItem(item)
        }
    }

    @objc func deviceSelection(_ sender: DeviceMenuItem) {
        devicesMenu.items.forEach { $0.state = .off }
        sender.state = .on
        outputDevices.selectedOutputDevice = sender.device
        Defaults.shared.selectedDeviceUID = sender.device?.uid
    }

    func statusItemDisplay() {
        if defaults.userPreferIconStatusBarItem {
            statusItem?.button?.image = NSImage(
                systemSymbolName: "music.note",
                accessibilityDescription: nil
            )
            statusItem?.button?.title = ""
        } else {
            statusItem?.button?.image = nil
            statusItem?.button?.title = statusItemTitle
        }
    }

    @objc func toggleSampleRate(item: NSMenuItem) {
        defaults.userPreferIconStatusBarItem.toggle()
        statusItemDisplay()
        item.title = defaults.statusBarItemTitle
    }

    @objc func toggleBitDepthDetection(item: NSMenuItem) {
        Task {
            await defaults.setPreferBitDepthDetection(
                newValue: !defaults.userPreferBitDepthDetection
            )
            item.state = defaults.userPreferBitDepthDetection ? .on : .off
        }
    }

    @objc func selectScript(_ item: NSMenuItem) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a script to invoke on rate change."
        panel.begin { response in
            Defaults.shared.shellScriptPath = panel.url?.path
        }
    }

    @objc func resetScript(_ item: NSMenuItem) {
        Defaults.shared.shellScriptPath = nil
    }

    @objc func trackChanged(_ notification: Notification) {
        guard let info = notification.userInfo as? [String: Any],
            let rawPID = info["PersistentID"] ?? info["Persistent ID"]
        else {
            return
        }
        let pid = String(describing: rawPID)
        guard pid != lastPersistentID else { return }
        lastPersistentID = pid
        let changeTime = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.outputDevices.switchLatestSampleRate(since: changeTime)
        }
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        currentScriptSelectionMenuItem?.title =
            Defaults.shared.shellScriptPath ?? "No selection"
    }
}
