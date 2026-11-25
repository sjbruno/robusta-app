import Foundation
import Testing
@testable import RobustaCore

/// Lê o sistema de verdade (somente leitura) e confere a IOKit contra o texto do pmset.
/// Pega mudança de formato ou de API numa versão nova do macOS.
@Suite struct SystemReaderTests {
    @Test func ioKitAgreesWithPmsetText() throws {
        let reading = PowerScheduleReader.read()
        let text = try ProcessRunner.run(Robusta.pmsetPath, ["-g", "sched"]).stdout
        let parsed = SchedParser.parse(text)

        // A função privada da recorrência existe neste macOS.
        #expect(reading.repeatSource == .ioKit)

        // Mesmos avulsos (o texto pode listar vencidos, a IOKit também: comparar tudo).
        #expect(Set(reading.snapshot.events.map(\.key)) == Set(parsed.events.map(\.key)))

        // Mesma recorrência; o texto só perde os dias em "Some days".
        for (fromIOKit, fromText) in [(reading.snapshot.repeatSchedule.powerOn, parsed.repeatSchedule.powerOn),
                                      (reading.snapshot.repeatSchedule.powerOff, parsed.repeatSchedule.powerOff)] {
            #expect(fromIOKit?.type == fromText?.type)
            #expect(fromIOKit?.minutesOfDay == fromText?.minutesOfDay)
            if let days = fromText?.days { #expect(fromIOKit?.days == days) }
        }
        #expect(reading.snapshot.unparsed.isEmpty)
    }
}
