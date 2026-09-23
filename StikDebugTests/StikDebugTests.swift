//
//  StikDebugTests.swift
//  StikDebugTests
//
//  Created by Stephen on 3/26/25.
//

import Foundation
import Testing
@testable import StikDebug

struct StikDebugTests {

    @Test func txmDetectionUsesClassicTXMBeforeIOS266() async throws {
        #expect(
            ProcessInfo.hasTXMSupport(
                isIOS266OrNewer: false,
                hasTXMClassic: false,
                hardwareIdentifier: "iPhone15,2"
            ) == false
        )
        #expect(
            ProcessInfo.hasTXMSupport(
                isIOS266OrNewer: false,
                hasTXMClassic: true,
                hardwareIdentifier: "iPhone1,1"
            ) == true
        )
    }

    @Test func txmDetectionUsesClassicTXMWhenAvailableOnIOS266() async throws {
        #expect(
            ProcessInfo.hasTXMSupport(
                isIOS266OrNewer: true,
                hasTXMClassic: true,
                hardwareIdentifier: "iPhone1,1"
            ) == true
        )
    }

    @Test func txmDetectionFallsBackToIPhoneThresholdOnIOS266() async throws {
        #expect(
            ProcessInfo.hasTXMSupport(
                isIOS266OrNewer: true,
                hasTXMClassic: false,
                hardwareIdentifier: "iPhone14,1"
            ) == false
        )
        #expect(
            ProcessInfo.hasTXMSupport(
                isIOS266OrNewer: true,
                hasTXMClassic: false,
                hardwareIdentifier: "iPhone14,2"
            ) == true
        )
    }

    @Test func txmDetectionFallsBackToIPadThresholdOnIOS266() async throws {
        #expect(
            ProcessInfo.hasTXMSupport(
                isIOS266OrNewer: true,
                hasTXMClassic: false,
                hardwareIdentifier: "iPad14,4"
            ) == false
        )
        #expect(
            ProcessInfo.hasTXMSupport(
                isIOS266OrNewer: true,
                hasTXMClassic: false,
                hardwareIdentifier: "iPad14,5"
            ) == true
        )
    }

    @Test func deviceVersionParsesSupportedIdentifiers() async throws {
        #expect(ProcessInfo.processInfo.deviceVersion(from: "iPhone14,2") == 14.2)
        #expect(ProcessInfo.processInfo.deviceVersion(from: "iPad14,5") == 14.5)
        #expect(ProcessInfo.processInfo.deviceVersion(from: "Mac14,2") == nil)
    }

    @Test func batteryAnalyticsParsesPowerUtilMetrics() throws {
        let data = Data(#"""
        {
            "last_value_CycleCount": 412,
            "last_value_NominalChargeCapacity": 4210,
            "last_value_MaximumFCC": 5000,
            "last_value_AverageTemperature": 31.5
        }
        """#.utf8)
        let sample = try #require(BatteryAnalyticsService.parse(
            data: data,
            sourceName: "Analytics-2026-09-22.ips"
        ))
        #expect(sample.cycleCount == 412)
        #expect(sample.availableCapacity == 4210)
        #expect(sample.originalCapacity == 5000)
        #expect(abs((sample.healthPercent ?? 0) - 84.2) < 0.001)
        #expect(sample.averageTemperature == 31.5)
    }

}
