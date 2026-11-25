import Foundation

/// Evento avulso agendado (`pmset schedule`).
public struct PowerEvent: Hashable, Sendable {
    public var type: EventType
    /// Instante absoluto; o `pmset` trabalha ao segundo.
    public var date: Date
    /// `scheduledby`. Sem owner na criação, o `powerd` grava o nome do processo (`pmset`).
    public var owner: String?
    public var userVisible: Bool

    public init(type: EventType, date: Date, owner: String?, userVisible: Bool = false) {
        self.type = type
        self.date = date
        self.owner = owner
        self.userVisible = userVisible
    }

    /// Identidade usada pelo `pmset` para cancelar: tipo, data ao segundo e owner.
    public var key: Key { Key(type: type, second: Int(date.timeIntervalSince1970.rounded(.down)), owner: owner) }

    public struct Key: Hashable, Sendable {
        public let type: EventType
        public let second: Int
        public let owner: String?
    }

    public var ownerKind: OwnerKind { OwnerKind(owner: owner) }
}

/// Classificação do owner para a UI e para as regras de segurança.
public enum OwnerKind: Hashable, Sendable {
    /// `robusta`: avulso manual do app. A renovação nunca mexe.
    case robustaManual
    /// `robusta.agenda`: o único que a renovação cria e cancela.
    case robustaAgenda
    /// `com.apple.*`.
    case system
    /// Qualquer outro owner, inclusive `pmset` (criado sem owner).
    case other(String)
    case none

    public init(owner: String?) {
        switch owner {
        case nil, "": self = .none
        case Robusta.OwnerID.manual: self = .robustaManual
        case Robusta.OwnerID.agenda: self = .robustaAgenda
        case let value? where value.hasPrefix("com.apple."): self = .system
        case let value?: self = .other(value)
        }
    }

    public var isRobusta: Bool {
        self == .robustaManual || self == .robustaAgenda
    }
}
