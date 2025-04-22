//
//  OutputDevices.swift
//  Quality
//
//  Created by Vincent Neo on 20/4/22.
//

import Combine
import Foundation
import SimplyCoreAudio
import CoreAudioTypes

class OutputDevices: ObservableObject {
    @Published var selectedOutputDevice: AudioDevice?
    @Published var defaultOutputDevice: AudioDevice?
    @Published var outputDevices = [AudioDevice]()
    @Published var currentSampleRate: Float64?

    private let coreAudio = SimplyCoreAudio()
    private var changesCancellable: AnyCancellable?
    private var defaultChangesCancellable: AnyCancellable?

    init() {
        self.outputDevices = coreAudio.allOutputDevices
        self.defaultOutputDevice = coreAudio.defaultOutputDevice
        getDeviceSampleRate()

        changesCancellable = NotificationCenter.default.publisher(for: .deviceListChanged)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.outputDevices = self.coreAudio.allOutputDevices
            }

        defaultChangesCancellable = NotificationCenter.default.publisher(for: .defaultOutputDeviceChanged)
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.defaultOutputDevice = self.coreAudio.defaultOutputDevice
                self.getDeviceSampleRate()
            }

    }

    deinit {
        changesCancellable?.cancel()
        defaultChangesCancellable?.cancel()
    }

    func getDeviceSampleRate() {
        guard let rate = (selectedOutputDevice ?? defaultOutputDevice)?.nominalSampleRate else { return }
        updateSampleRate(rate)
    }

    func getAllStats() -> [CMPlayerStats] {
        do {
            let logs = try Console.getRecentEntries(type: .music)
            let stats = CMPlayerParser.parseMusicConsoleLogs(logs)
            return stats.sorted { $0.priority > $1.priority }
        } catch {
            return []
        }
    }

    func switchLatestSampleRate() {
        let stats = getAllStats()
        guard let stat = stats.first else { return }
        guard let device = selectedOutputDevice ?? defaultOutputDevice else { return }

        if Defaults.shared.userPreferBitDepthDetection {
            // Full format switch (sample rate + bit depth)
            applyBestFormat(for: stat, on: device)
        } else {
            // Sample-rate only
            let newRate = Double(stat.sampleRate)
            if newRate != device.nominalSampleRate {
                device.setNominalSampleRate(newRate)
                updateSampleRate(newRate)
            }
        }
    }

    func updateSampleRate(_ sampleRate: Float64) {
        DispatchQueue.main.async {
            let readable = sampleRate / 1000
            self.currentSampleRate = readable
            AppDelegate.instance.statusItemTitle = String(format: "%.1f kHz", readable)
        }
        runUserScript(sampleRate)
    }

    func runUserScript(_ sampleRate: Float64) {
        guard let path = Defaults.shared.shellScriptPath else { return }
        let arg = String(Int(sampleRate))
        Task {
            do {
                let task = try NSUserUnixTask(url: URL(fileURLWithPath: path))
                try await task.execute(withArguments: [arg])
            } catch {
            }
        }
    }

    /// Chooses and applies the best available audio format (sample rate + bit depth) on the device.
    private func applyBestFormat(for stat: CMPlayerStats, on device: AudioDevice) {
        // Get the output streams and their available formats
        guard let streams = device.streams(scope: .output),
              let stream = streams.first,
              let availableFormats = stream.availablePhysicalFormats?.map({ $0.mFormat })
        else { return }

        let targetRate  = stat.sampleRate
        let targetDepth = stat.bitDepth

        // Find the format with minimal combined delta of rate and depth
        let bestFormat = availableFormats.min { a, b in
            let rateDeltaA = abs(a.mSampleRate - targetRate)
            let rateDeltaB = abs(b.mSampleRate - targetRate)
            if rateDeltaA != rateDeltaB {
                return rateDeltaA < rateDeltaB
            }
            let depthDeltaA = abs(Int(a.mBitsPerChannel) - targetDepth)
            let depthDeltaB = abs(Int(b.mBitsPerChannel) - targetDepth)
            return depthDeltaA < depthDeltaB
        }

        // Apply if different
        if let fmt = bestFormat, stream.physicalFormat != fmt {
            stream.physicalFormat = fmt
            updateSampleRate(fmt.mSampleRate)
        }
    }
}
