import Foundation

/// Battleship on two hidden 10×10 boards. Cell = row * 10 + col.
///
/// Only public information enters the move log: a shot by the attacker
/// (1 byte, cell 0–99) followed by the defender's report (1 byte with the
/// high bit set: 0x80 miss, 0x81 hit, 0x90 | ship hit-and-sunk). After
/// reporting, the defender takes their own shot, so `toMove` runs
/// one(shoot) → two(report) → two(shoot) → one(report) → one(shoot)…
/// Placements never leave the phone; `autoMove` reads them from private
/// data (5 ships × [row, col, orientation 0=horizontal/1=vertical]).
struct Battleship: GameEngine {
    static let fleet = [5, 4, 3, 3, 2]
    static let shipNames = ["Carrier", "Battleship", "Cruiser", "Submarine", "Destroyer"]
    static let totalHits = 17
    static var needsPrivateSetup: Bool { true }

    enum Report: Equatable {
        case miss, hit, sunk(Int)

        init?(byte: UInt8) {
            switch byte {
            case 0x80: self = .miss
            case 0x81: self = .hit
            case 0x90...0x94: self = .sunk(Int(byte & 0x0F))
            default: return nil
            }
        }
        var byte: UInt8 {
            switch self {
            case .miss: return 0x80
            case .hit: return 0x81
            case .sunk(let i): return 0x90 | UInt8(i)
            }
        }
        var isHit: Bool { self != .miss }
    }

    struct Shot: Equatable {
        let cell: Int
        /// nil while the defender's report is outstanding.
        var report: Report?
    }

    private(set) var log: [UInt8] = []
    private var shotsByPlayer: [[Shot]] = [[], []]
    private(set) var toMove: Player = .one

    init(options: Data) {}

    // MARK: Read-only helpers for the view

    /// Shots `player` has fired, in order, with the opponent's report.
    func shots(by player: Player) -> [Shot] { shotsByPlayer[Int(player.rawValue)] }
    /// The shot awaiting `toMove`'s report, if any.
    var pendingShot: Int? {
        guard let last = shots(by: toMove.other).last, last.report == nil else { return nil }
        return last.cell
    }
    var isReportPending: Bool { pendingShot != nil }
    func hits(by player: Player) -> Int { shots(by: player).filter { $0.report?.isHit == true }.count }
    /// Indices of the opponent's ships that `player` has sunk.
    func sunkShips(by player: Player) -> Set<Int> {
        Set(shots(by: player).compactMap { if case .sunk(let i) = $0.report { return i } else { return nil } })
    }

    var result: GameResult? {
        if hits(by: .one) >= Battleship.totalHits { return .win(.one) }
        if hits(by: .two) >= Battleship.totalHits { return .win(.two) }
        return nil
    }

    func legalMoves() -> [Data] {
        guard result == nil else { return [] }
        if isReportPending {
            let sunk = sunkShips(by: toMove.other)
            let sinkable = (0..<Battleship.fleet.count).filter { !sunk.contains($0) }
            return [Report.miss, .hit].map { Data([$0.byte]) } + sinkable.map { Data([Report.sunk($0).byte]) }
        }
        let fired = Set(shots(by: toMove).map(\.cell))
        return (0..<100).filter { !fired.contains($0) }.map { Data([UInt8($0)]) }
    }

    mutating func apply(_ move: Data) throws {
        guard move.count == 1 else { throw GameError.malformedMove }
        guard result == nil else { throw GameError.gameOver }
        guard legalMoves().contains(move), let byte = move.first else { throw GameError.illegalMove }
        if let report = Report(byte: byte) {
            let attacker = Int(toMove.other.rawValue)
            shotsByPlayer[attacker][shotsByPlayer[attacker].count - 1].report = report
            // The defender keeps the move: it is now their shot.
        } else {
            shotsByPlayer[Int(toMove.rawValue)].append(Shot(cell: Int(byte), report: nil))
            toMove = toMove.other
        }
        log.append(byte)
    }

    /// The correct report for the pending shot, judged against my placement.
    func autoMove(privateData: Data) -> Data? {
        guard let cell = pendingShot, Battleship.placementIsValid(privateData),
              let ships = Battleship.shipCells(privateData) else { return nil }
        guard let index = ships.firstIndex(where: { $0.contains(cell) }) else { return Data([Report.miss.byte]) }
        let fired = Set(shots(by: toMove.other).map(\.cell))   // includes the pending shot
        let sunk = ships[index].allSatisfy(fired.contains)
        return Data([(sunk ? Report.sunk(index) : .hit).byte])
    }

    func describe(_ move: Data) -> String {
        guard move.count == 1, let byte = move.first else { return "?" }
        if byte < 100 { return Battleship.cellName(Int(byte)) }
        switch Report(byte: byte) {
        case .miss: return "miss"
        case .hit: return "hit"
        case .sunk(let i): return "sunk the \(Battleship.shipNames[i])"
        case nil: return "?"
        }
    }

    /// The whole shot/report sequence plus whose move it is.
    var canonical: Data { Data(log) + [toMove.rawValue] }

    // MARK: Placement

    /// "B7": rows A–J, columns 1–10.
    static func cellName(_ cell: Int) -> String {
        "\(Character(UnicodeScalar(UInt8(65 + cell / 10))))\(cell % 10 + 1)"
    }

    /// Cells occupied by each placed ship (a prefix of the fleet is allowed,
    /// so the placement screen can check partial fleets). nil if malformed
    /// or off the board; overlap is not checked here.
    static func shipCells(_ data: Data) -> [[Int]]? {
        let b = [UInt8](data)
        guard b.count % 3 == 0, b.count <= fleet.count * 3 else { return nil }
        var ships: [[Int]] = []
        for i in 0..<(b.count / 3) {
            let r = Int(b[3 * i]), c = Int(b[3 * i + 1]), vertical = b[3 * i + 2]
            guard vertical <= 1, r < 10, c < 10 else { return nil }
            let end = (vertical == 1 ? r : c) + fleet[i] - 1
            guard end < 10 else { return nil }
            ships.append((0..<fleet[i]).map { vertical == 1 ? (r + $0) * 10 + c : r * 10 + c + $0 })
        }
        return ships
    }

    static func placementIsValid(_ data: Data) -> Bool {
        guard data.count == fleet.count * 3, let ships = shipCells(data) else { return false }
        let all = ships.flatMap { $0 }
        return Set(all).count == all.count
    }

    static func randomPlacement() -> Data {
        var data = Data()
        var taken = Set<Int>()
        for length in fleet {
            while true {
                let vertical = Bool.random()
                let r = Int.random(in: 0..<(vertical ? 11 - length : 10))
                let c = Int.random(in: 0..<(vertical ? 10 : 11 - length))
                let cells = (0..<length).map { vertical ? (r + $0) * 10 + c : r * 10 + c + $0 }
                if taken.isDisjoint(with: cells) {
                    taken.formUnion(cells)
                    data.append(contentsOf: [UInt8(r), UInt8(c), vertical ? 1 : 0])
                    break
                }
            }
        }
        return data
    }
}
