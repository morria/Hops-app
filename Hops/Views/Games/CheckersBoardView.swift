import SwiftUI

/// Draws a `Checkers` position with my pieces at the bottom. Tap a piece to
/// see where it can go, tap a destination to send the move.
struct CheckersBoardView: View {
    let context: GameBoardContext
    @State private var selected: Int?

    private var engine: Checkers { context.engine as! Checkers }
    private var flipped: Bool { context.myPlayer == .two }
    private var moves: [Data] { context.interactive ? engine.legalMoves() : [] }
    private var movable: Set<Int> { Set(moves.map { Int($0.first!) }) }
    /// Mid multi-jump only one piece can move, so pre-select it.
    private var effectiveSelected: Int? { selected ?? (movable.count == 1 ? movable.first : nil) }
    private var targets: Set<Int> {
        guard let from = effectiveSelected else { return [] }
        return Set(moves.filter { $0.first == UInt8(from) }.map { Int($0.last!) })
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size.width / 8
            ZStack(alignment: .topLeading) {
                ForEach(0..<64, id: \.self) { i in
                    let r = i / 8, c = i % 8   // screen position
                    squareView(row: flipped ? 7 - r : r, col: flipped ? 7 - c : c, size: size)
                        .offset(x: CGFloat(c) * size, y: CGFloat(r) * size)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .onChange(of: context.engine.canonical) { selected = nil }
    }

    private func squareView(row: Int, col: Int, size: CGFloat) -> some View {
        let square = Checkers.square(row: row, col: col)
        let value = square.map { engine.squares[$0] } ?? Checkers.empty
        return ZStack {
            Rectangle().fill(square == nil ? Color(red: 0.93, green: 0.85, blue: 0.70)
                                           : Color(red: 0.45, green: 0.30, blue: 0.20))
            if let s = square, s == effectiveSelected {
                Rectangle().strokeBorder(Color.yellow, lineWidth: 3)
            }
            if let s = square, targets.contains(s) {
                Circle().fill(Color.yellow.opacity(0.7)).frame(width: size * 0.3, height: size * 0.3)
            }
            if let owner = Checkers.owner(value) {
                piece(owner, king: Checkers.isKing(value), size: size)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .onTapGesture { if let s = square { tap(s) } }
    }

    private func piece(_ owner: Player, king: Bool, size: CGFloat) -> some View {
        ZStack {
            Circle().fill(owner == .one ? Color(white: 0.15) : Color(red: 0.75, green: 0.15, blue: 0.15))
            Circle().strokeBorder(Color.white.opacity(0.6), lineWidth: 1.5)
            if king {
                Image(systemName: "crown.fill")
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(Color.yellow)
            }
        }
        .padding(size * 0.12)
    }

    private func tap(_ square: Int) {
        guard context.interactive else { return }
        if let from = effectiveSelected, targets.contains(square) {
            context.onMove(Data([UInt8(from), UInt8(square)]))
            selected = nil
        } else if movable.contains(square) {
            selected = square
        } else {
            selected = nil
        }
    }
}
