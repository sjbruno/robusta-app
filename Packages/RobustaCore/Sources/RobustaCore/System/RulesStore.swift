import Foundation

/// Conteúdo do `rules.json`.
public struct RulesFile: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var rules: [AgendaRule]
    /// Agendamentos únicos criados pelo app (E4): o `pmset` não sabe que são "únicos".
    public var onceEvents: [OnceRecord]
    /// Recorrência nativa que o Robusta gravou (E1). Se a atual divergir, foi mexida por fora.
    public var nativeSignature: NativeSignature?
    /// Bules cheios (E7): dose no início e Mac acordado até o fim, na tomada.
    public var awakeWindows: [AwakeWindow]

    public init(rules: [AgendaRule] = [], onceEvents: [OnceRecord] = [], nativeSignature: NativeSignature? = nil,
                awakeWindows: [AwakeWindow] = []) {
        self.version = Self.currentVersion
        self.rules = rules
        self.onceEvents = onceEvents
        self.nativeSignature = nativeSignature
        self.awakeWindows = awakeWindows
    }

    /// Agendas mais as doses de início dos bules cheios: o que a renovação mantém.
    public var renewalRules: [AgendaRule] { rules + awakeWindows.filter(\.isValid).map(\.startRule) }

    /// Tolerante: campo que falta vira vazio, para versões antigas do arquivo abrirem.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        rules = try container.decodeIfPresent([AgendaRule].self, forKey: .rules) ?? []
        onceEvents = try container.decodeIfPresent([OnceRecord].self, forKey: .onceEvents) ?? []
        nativeSignature = try container.decodeIfPresent(NativeSignature.self, forKey: .nativeSignature)
        awakeWindows = try container.decodeIfPresent([AwakeWindow].self, forKey: .awakeWindows) ?? []
    }

    /// Remove os únicos já vencidos (E4).
    public mutating func dropExpiredOnce(now: Date) {
        onceEvents.removeAll { $0.date <= now }
    }
}

public struct OnceRecord: Codable, Hashable, Sendable {
    public var type: EventType
    public var date: Date
    public init(type: EventType, date: Date) {
        self.type = type
        self.date = date
    }
}

public struct NativeSignature: Codable, Hashable, Sendable {
    public var type: EventType
    public var hour: Int
    public var minute: Int
    public var weekdays: Weekdays

    public init(type: EventType, hour: Int, minute: Int, weekdays: Weekdays) {
        self.type = type
        self.hour = hour
        self.minute = minute
        self.weekdays = weekdays
    }

    public func matches(_ entry: RepeatEntry?) -> Bool {
        guard let entry else { return false }
        return entry.type == type && entry.hour == hour && entry.minute == minute && entry.days == weekdays
    }
}

/// Lê e grava o `rules.json`. Arquivo ausente = sem agendas. Gravação atômica.
public struct RulesStore: Sendable {
    public let url: URL

    public init(url: URL = Robusta.rulesFile) {
        self.url = url
    }

    public func load() throws -> RulesFile {
        guard FileManager.default.fileExists(atPath: url.path) else { return RulesFile() }
        let data = try Data(contentsOf: url)
        return try Self.decoder.decode(RulesFile.self, from: data)
    }

    public func save(_ file: RulesFile) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(file).write(to: url, options: .atomic)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
