import SwiftUI

/// The chess board. Draws `context.engine as! Chess` with the local player
/// at the bottom; tap a piece, then a destination, to send one move.
struct ChessBoardView: View {
    let context: GameBoardContext
    @State private var selected: Int?
    @State private var promotion: (from: Int, to: Int)?

    private var chess: Chess { context.engine as! Chess }

    var body: some View {
        let chess = self.chess
        let legal = context.interactive ? chess.legalMoves().map { [UInt8]($0) } : []
        let targets = Set(legal.filter { Int($0[0]) == selected }.map { Int($0[1]) })
        let checkedKing = chess.isInCheck ? chess.kingSquare(chess.toMove) : nil
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            VStack(spacing: 0) {
                ForEach(0..<8, id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(0..<8, id: \.self) { col in
                            let square = self.square(row: row, col: col)
                            SquareView(square: square, size: side / 8,
                                       piece: chess.piece(at: square),
                                       isSelected: square == selected,
                                       isTarget: targets.contains(square),
                                       isLastMove: chess.lastMove.map { $0.from == square || $0.to == square } ?? false,
                                       isCheckedKing: square == checkedKing,
                                       showFile: row == 7, showRank: col == 0)
                                .onTapGesture { tap(square, legal: legal) }
                        }
                    }
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .aspectRatio(1, contentMode: .fit)
        .onChange(of: chess.canonical) { selected = nil; promotion = nil }
        .onChange(of: context.interactive) { if !context.interactive { selected = nil } }
        .confirmationDialog("Promote to", isPresented: Binding(
            get: { promotion != nil }, set: { if !$0 { promotion = nil } }
        ), titleVisibility: .visible) {
            ForEach(Array(zip(["Queen", "Rook", "Bishop", "Knight"], 1...4)), id: \.1) { name, code in
                Button(name) { promote(UInt8(code)) }
            }
        }
    }

    /// Display row/col (0,0 = top left) → square, flipped for Black.
    private func square(row: Int, col: Int) -> Int {
        context.myPlayer == .one ? (7 - row) * 8 + col : row * 8 + (7 - col)
    }

    private func tap(_ square: Int, legal: [[UInt8]]) {
        guard context.interactive else { return }
        if let from = selected {
            if from == square { selected = nil; return }
            let matches = legal.filter { Int($0[0]) == from && Int($0[1]) == square }
            if matches.count > 1 { promotion = (from, square); return }
            if let move = matches.first { selected = nil; context.onMove(Data(move)); return }
        }
        selected = legal.contains { Int($0[0]) == square } ? square : nil
    }

    private func promote(_ code: UInt8) {
        guard let p = promotion else { return }
        promotion = nil
        selected = nil
        context.onMove(Data([UInt8(p.from), UInt8(p.to), code]))
    }
}

private struct SquareView: View {
    let square: Int
    let size: CGFloat
    let piece: (player: Player, kind: Chess.Kind)?
    let isSelected: Bool, isTarget: Bool, isLastMove: Bool, isCheckedKing: Bool
    let showFile: Bool, showRank: Bool

    private var isLight: Bool { ((square & 7) + (square >> 3)) % 2 == 1 }
    private static let light = Color(red: 0.93, green: 0.86, blue: 0.72)
    private static let dark = Color(red: 0.70, green: 0.53, blue: 0.39)

    var body: some View {
        ZStack {
            Rectangle().fill(isLight ? Self.light : Self.dark)
            if isLastMove { Rectangle().fill(Color.yellow.opacity(0.35)) }
            if isSelected { Rectangle().fill(Color.yellow.opacity(0.55)) }
            if isCheckedKing { Rectangle().fill(Color.red.opacity(0.5)) }
            if let piece {
                Text(Self.glyph(piece))
                    .font(.system(size: size * 0.74))
                    .foregroundStyle(.black)
                    .minimumScaleFactor(0.5)
            }
            if isTarget {
                if piece == nil {
                    Circle().fill(Color.black.opacity(0.25)).frame(width: size * 0.3, height: size * 0.3)
                } else {
                    Circle().strokeBorder(Color.black.opacity(0.3), lineWidth: size * 0.08)
                }
            }
            let labelColor = isLight ? Self.dark : Self.light
            if showRank {
                Text("\((square >> 3) + 1)")
                    .font(.system(size: size * 0.2, weight: .semibold)).foregroundStyle(labelColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).padding(2)
            }
            if showFile {
                Text(String(Chess.name(of: square).prefix(1)))
                    .font(.system(size: size * 0.2, weight: .semibold)).foregroundStyle(labelColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing).padding(2)
            }
        }
        .frame(width: size, height: size)
        .contentShape(Rectangle())
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let name = Chess.name(of: square)
        guard let piece else { return name }
        return "\(piece.player == .one ? "white" : "black") \(piece.kind) on \(name)"
    }

    private static func glyph(_ piece: (player: Player, kind: Chess.Kind)) -> String {
        let white = ["♙", "♘", "♗", "♖", "♕", "♔"], black = ["♟", "♞", "♝", "♜", "♛", "♚"]
        return (piece.player == .one ? white : black)[Int(piece.kind.rawValue) - 1]
    }
}
