import SwiftUI

/// Placement screen until my fleet is chosen, then the two boards: their
/// waters (my shots) on top, my waters (my ships, their shots) below.
struct BattleshipBoardView: View {
    let context: GameBoardContext

    private var engine: Battleship { context.engine as! Battleship }

    var body: some View {
        if context.privateData.isEmpty {
            BattleshipPlacementView(onReady: context.onPrivateSetup)
        } else {
            playView
        }
    }

    private var playView: some View {
        let me = context.myPlayer
        let myShots = Dictionary(uniqueKeysWithValues: engine.shots(by: me).map { ($0.cell, $0) })
        let theirShots = Dictionary(uniqueKeysWithValues: engine.shots(by: me.other).map { ($0.cell, $0) })
        let myShips = Set((Battleship.shipCells(context.privateData) ?? []).flatMap { $0 })
        let canShoot = context.interactive && engine.toMove == me && !engine.isReportPending
        return VStack(spacing: 10) {
            Text(status).font(.subheadline).foregroundStyle(.secondary)
            Text("Their waters").font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            BattleshipGrid(
                cell: { i in BattleshipCell(ship: false, shot: myShots[i]) },
                onTap: { i in
                    if canShoot, myShots[i] == nil { context.onMove(Data([UInt8(i)])) }
                })
            fleetStatus(sunk: engine.sunkShips(by: me))
            Text("Your waters").font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            BattleshipGrid(cell: { i in BattleshipCell(ship: myShips.contains(i), shot: theirShots[i]) })
        }
    }

    private var status: String {
        let me = context.myPlayer
        if let result = engine.result {
            return result == .win(me) ? "You sank their fleet" : "They sank your fleet"
        }
        if engine.isReportPending { return engine.toMove == me ? "Reporting…" : "Waiting for their report…" }
        return engine.toMove == me ? "Your shot" : "Their shot"
    }

    private func fleetStatus(sunk: Set<Int>) -> some View {
        HStack(spacing: 8) {
            ForEach(0..<Battleship.fleet.count, id: \.self) { i in
                Text(Battleship.shipNames[i])
                    .font(.caption2)
                    .strikethrough(sunk.contains(i))
                    .foregroundStyle(sunk.contains(i) ? .secondary : .primary)
            }
        }
    }
}

/// One square of water: an optional ship underneath, an optional shot on top.
private struct BattleshipCell: View {
    let ship: Bool
    let shot: Battleship.Shot?

    var body: some View {
        ZStack {
            Rectangle().fill(fill)
            Rectangle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5)
            if let shot {
                Text(mark(for: shot)).font(.system(size: 14, weight: .bold)).foregroundStyle(color(for: shot))
            }
        }
    }

    private var fill: Color {
        if case .sunk = shot?.report { return Color.red.opacity(0.5) }
        return ship ? Color.gray.opacity(0.6) : Color.blue.opacity(0.25)
    }
    private func mark(for shot: Battleship.Shot) -> String {
        switch shot.report {
        case nil: return "·"
        case .miss: return "○"
        case .hit, .sunk: return "✕"
        }
    }
    private func color(for shot: Battleship.Shot) -> Color {
        switch shot.report {
        case .hit, .sunk: return .red
        default: return .primary
        }
    }
}

/// 10×10 grid sized to its width; `cell` draws one square, `onTap` gets its index.
private struct BattleshipGrid<Cell: View>: View {
    let cell: (Int) -> Cell
    var onTap: ((Int) -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            let size = geo.size.width / 10
            VStack(spacing: 0) {
                ForEach(0..<10, id: \.self) { r in
                    HStack(spacing: 0) {
                        ForEach(0..<10, id: \.self) { c in
                            cell(r * 10 + c)
                                .frame(width: size, height: size)
                                .contentShape(Rectangle())
                                .onTapGesture { onTap?(r * 10 + c) }
                        }
                    }
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Place the fleet one ship at a time: tap the bow cell; the ship extends
/// right (or down when rotated).
private struct BattleshipPlacementView: View {
    let onReady: (Data) -> Void

    private struct Placement { var row: Int; var col: Int; var vertical: Bool }
    @State private var placed: [Placement] = []
    @State private var vertical = false

    private var data: Data {
        Data(placed.flatMap { [UInt8($0.row), UInt8($0.col), $0.vertical ? 1 : 0] })
    }
    private var occupied: Set<Int> { Set((Battleship.shipCells(data) ?? []).flatMap { $0 }) }
    private var complete: Bool { placed.count == Battleship.fleet.count }

    var body: some View {
        VStack(spacing: 10) {
            Text(complete ? "Fleet placed"
                          : "Place the \(Battleship.shipNames[placed.count]) (\(Battleship.fleet[placed.count])), \(vertical ? "down" : "across")")
                .font(.subheadline)
            BattleshipGrid(cell: { i in BattleshipCell(ship: occupied.contains(i), shot: nil) },
                           onTap: place)
            HStack {
                Button("Rotate") { vertical.toggle() }.disabled(complete)
                Button("Undo") { _ = placed.popLast() }.disabled(placed.isEmpty)
                Button("Random") { placed = decode(Battleship.randomPlacement()) }
                Spacer()
                Button("Ready") { onReady(data) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!complete || !Battleship.placementIsValid(data))
            }
            .font(.callout)
        }
    }

    private func place(_ cell: Int) {
        guard !complete else { return }
        let candidate = Placement(row: cell / 10, col: cell % 10, vertical: vertical)
        var trial = data
        trial.append(contentsOf: [UInt8(candidate.row), UInt8(candidate.col), vertical ? 1 : 0])
        guard let ships = Battleship.shipCells(trial),
              occupied.isDisjoint(with: ships[placed.count]) else { return }
        placed.append(candidate)
    }

    private func decode(_ data: Data) -> [Placement] {
        let b = [UInt8](data)
        var out: [Placement] = []
        for i in stride(from: 0, to: b.count - 2, by: 3) {
            let row = Int(b[i]), col = Int(b[i + 1])
            let vertical: Bool = b[i + 2] == 1
            out.append(Placement(row: row, col: col, vertical: vertical))
        }
        return out
    }
}
