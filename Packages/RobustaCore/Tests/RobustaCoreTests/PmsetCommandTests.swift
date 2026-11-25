import Foundation
import Testing
@testable import RobustaCore

private let utc = TimeZone(identifier: "UTC")!
private let instant = Date(timeIntervalSince1970: 1_796_115_540) // 2026-12-01 08:59:00 UTC

@Suite struct PmsetCommandTests {
    @Test func scheduleArgv() throws {
        let event = PowerEvent(type: .wakeOrPowerOn, date: instant, owner: "robusta.agenda")
        #expect(try PmsetCommand.schedule(event).arguments(timeZone: utc)
                == ["schedule", "wakeorpoweron", "12/01/26 08:59:00", "robusta.agenda"])
        #expect(try PmsetCommand.schedule(event).sudoArguments(timeZone: utc).prefix(2) == ["-n", "/usr/bin/pmset"])
    }

    @Test func cancelArgvNeedsTypeDateAndOwner() throws {
        let event = PowerEvent(type: .wake, date: instant, owner: "robusta")
        #expect(try PmsetCommand.cancel(event).arguments(timeZone: utc)
                == ["schedule", "cancel", "wake", "12/01/26 08:59:00", "robusta"])
    }

    @Test func refusesForeignOrMissingOwner() {
        for owner in [nil, "pmset", "com.apple.alarm", "Robusta", "robusta.teste"] {
            let event = PowerEvent(type: .wake, date: instant, owner: owner)
            #expect(throws: PmsetCommand.ValidationError.ownerNotAllowed(owner)) {
                try PmsetCommand.cancel(event).arguments(timeZone: utc)
            }
        }
    }

    @Test func refusesSleepAndShutdown() {
        let event = PowerEvent(type: .sleep, date: instant, owner: "robusta")
        #expect(throws: PmsetCommand.ValidationError.typeNotAllowed(.sleep)) {
            try PmsetCommand.schedule(event).arguments(timeZone: utc)
        }
    }

    @Test func repeatKeepsTheOffSide() throws {
        let schedule = RepeatSchedule(
            powerOn: RepeatEntry(type: .wakeOrPowerOn, hour: 7, minute: 59, days: .weekdays),
            powerOff: RepeatEntry(type: .sleep, hour: 0, minute: 30, days: .weekends))
        #expect(try PmsetCommand.setRepeat(schedule).arguments()
                == ["repeat", "wakeorpoweron", "MTWRF", "07:59:00", "sleep", "SU", "00:30:00"])
    }

    @Test func repeatRefusesUnknownDaysAndSwappedSides() {
        let unknown = RepeatSchedule(powerOn: RepeatEntry(type: .wake, hour: 8, minute: 0, days: nil))
        #expect(throws: PmsetCommand.ValidationError.repeatDaysUnknown) { try PmsetCommand.setRepeat(unknown).arguments() }
        let swapped = RepeatSchedule(powerOn: RepeatEntry(type: .sleep, hour: 8, minute: 0, days: .weekdays))
        #expect(throws: PmsetCommand.ValidationError.repeatSideMismatch) { try PmsetCommand.setRepeat(swapped).arguments() }
        #expect(throws: PmsetCommand.ValidationError.repeatEmpty) { try PmsetCommand.setRepeat(RepeatSchedule()).arguments() }
    }

    /// Regra 1 e sudoers: nenhum argv gerado contém cancelall ou cancel por índice.
    @Test func neverCancelAllNorByIndex() throws {
        let event = PowerEvent(type: .wake, date: instant, owner: "robusta.agenda")
        let all = [try PmsetCommand.schedule(event).arguments(), try PmsetCommand.cancel(event).arguments(),
                   try PmsetCommand.cancelRepeat.arguments()]
        for argv in all {
            #expect(!argv.contains("cancelall"))
            if let index = argv.firstIndex(of: "cancel"), index + 1 < argv.count {
                #expect(Int(argv[index + 1]) == nil, "cancel por índice: \(argv)")
            }
        }
    }

    /// A checagem de permissão distingue a recusa do sudo do erro do próprio pmset.
    @Test func permissionProbeReadsSudoRefusal() {
        #expect(!PmsetRunner.ranPmset(status: 1, stderr: "sudo: a password is required\n"))
        #expect(PmsetRunner.ranPmset(status: 1, stderr: "Error in scheduling operation\n"))
        #expect(PmsetRunner.ranPmset(status: 0, stderr: ""))
    }

    @Test func logDescriptionIsTheCommandLine() {
        let event = PowerEvent(type: .wake, date: instant, owner: "robusta")
        #expect(PmsetCommand.cancel(event).logDescription.hasPrefix("schedule cancel wake "))
        #expect(PmsetCommand.cancel(event).logDescription.hasSuffix(" robusta"))
    }
}
