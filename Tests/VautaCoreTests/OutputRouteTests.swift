// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2026 Nicolás López de Lerma López

import CoreAudio
import Testing
@testable import VautaCore

/// `OutputRoute`: the panel suggests headphones only for speakers the microphone surely hears, never for a device that can
/// be headphones.
@Suite("Audio: speakers or headphones")
struct OutputRouteTests {
    @Test func theMacsOwnOutputFollowsItsDataSource() {
        #expect(OutputRoute.route(transport: kAudioDeviceTransportTypeBuiltIn, dataSource: OutputRoute.internalSpeakers) == .speakers)
        #expect(OutputRoute.route(transport: kAudioDeviceTransportTypeBuiltIn, dataSource: OutputRoute.headphoneJack) == .headphones)
        #expect(OutputRoute.route(transport: kAudioDeviceTransportTypeBuiltIn, dataSource: nil) == .unknown)
        // The four-character codes Core Audio uses.
        #expect(OutputRoute.internalSpeakers == fourCC("ispk") && OutputRoute.headphoneJack == fourCC("hdpn"))
    }

    @Test func displaysAndAirPlayAreSpeakers() {
        for transport in [kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeAirPlay] {
            #expect(OutputRoute.route(transport: transport, dataSource: nil) == .speakers)
        }
    }

    @Test func devicesThatCanBeHeadphonesAreNeverSpeakers() {
        for transport in [kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE, kAudioDeviceTransportTypeUSB,
                          kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate,
                          kAudioDeviceTransportTypeUnknown] {
            #expect(OutputRoute.route(transport: transport, dataSource: OutputRoute.internalSpeakers) == .unknown)
        }
    }

    private func fourCC(_ s: String) -> UInt32 { s.utf8.reduce(0) { $0 << 8 | UInt32($1) } }
}
