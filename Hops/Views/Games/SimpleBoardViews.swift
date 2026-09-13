import SwiftUI

// MARK: - Tic-Tac-Toe

struct TicTacToeBoardView: View {
    let context: GameBoardContext
    private var game: TicTacToe { context.engine as! TicTacToe }

    var body: some View {
        let legal = Set(game.legalMoves().map { Int($0[$0.startIndex]) })
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) / 3
            VStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: 4) {
                        ForEach(0..<3, id: \.self) { col in
                            let cell = row * 3 + col
                            Button {
                                context.onMove(Data([UInt8(cell)]))
                            } label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color(.secondarySystemBackground))
                                    Text(mark(game.cells[cell]))
                                        .font(.system(size: side * 0.55, weight: .bold, design: .rounded))
                                        .foregroundStyle(game.cells[cell] == 1 ? Color.accentColor : Color.orange)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(!context.interactive || !legal.contains(cell))
                            .frame(width: side - 4, height: side - 4)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .overlay(alignment: .bottom) {
            Text("You are \(context.myPlayer == .one ? "X" : "O")")
                .font(.caption).foregroundStyle(.secondary)
                .offset(y: 18)
        }
    }

    private func mark(_ v: UInt8) -> String { v == 1 ? "X" : v == 2 ? "O" : "" }
}

// MARK: - Connect Four

struct ConnectFourBoardView: View {
    let context: GameBoardContext
    private var game: ConnectFour { context.engine as! ConnectFour }

    var body: some View {
        let legal = Set(game.legalMoves().map { Int($0[$0.startIndex]) })
        VStack(spacing: 6) {
            GeometryReader { geo in
                let cell = geo.size.width / CGFloat(ConnectFour.columns)
                HStack(spacing: 0) {
                    ForEach(0..<ConnectFour.columns, id: \.self) { col in
                        Button {
                            context.onMove(Data([UInt8(col)]))
                        } label: {
                            VStack(spacing: 0) {
                                ForEach((0..<ConnectFour.rows).reversed(), id: \.self) { row in
                                    let v = game.cell(row: row, column: col)
                                    let index = row * ConnectFour.columns + col
                                    Circle()
                                        .fill(v == 1 ? Color.accentColor : v == 2 ? Color.orange : Color(.systemBackground))
                                        .overlay(Circle().strokeBorder(index == game.lastCell ? Color.primary : .clear, lineWidth: 2))
                                        .padding(cell * 0.08)
                                        .frame(width: cell, height: cell)
                                }
                            }
                            .background(Color.blue.opacity(0.35))
                        }
                        .buttonStyle(.plain)
                        .disabled(!context.interactive || !legal.contains(col))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            .aspectRatio(CGFloat(ConnectFour.columns) / CGFloat(ConnectFour.rows), contentMode: .fit)
            Text("You are \(context.myPlayer == .one ? "blue" : "orange")")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Dots and Boxes

struct DotsAndBoxesBoardView: View {
    let context: GameBoardContext
    private var game: DotsAndBoxes { context.engine as! DotsAndBoxes }

    var body: some View {
        let n = DotsAndBoxes.size
        let legal = Set(game.legalMoves().map { Int($0[$0.startIndex]) })
        VStack(spacing: 8) {
            GeometryReader { geo in
                let pitch = geo.size.width / CGFloat(n + 1)
                let inset = pitch / 2
                ZStack {
                    // Boxes
                    ForEach(0..<(n * n), id: \.self) { index in
                        let row = index / n, col = index % n
                        let owner = game.boxes[index]
                        if owner != 0 {
                            RoundedRectangle(cornerRadius: 4)
                                .fill((owner == 1 ? Color.accentColor : Color.orange).opacity(0.35))
                                .frame(width: pitch - 8, height: pitch - 8)
                                .position(x: inset + pitch * (CGFloat(col) + 0.5), y: inset + pitch * (CGFloat(row) + 0.5))
                        }
                    }
                    // Horizontal edges
                    ForEach(0..<20, id: \.self) { e in
                        let row = e / n, col = e % n
                        edge(e, drawn: game.edges[e], legal: legal.contains(e),
                             size: CGSize(width: pitch - 10, height: 8))
                            .position(x: inset + pitch * (CGFloat(col) + 0.5), y: inset + pitch * CGFloat(row))
                    }
                    // Vertical edges
                    ForEach(20..<40, id: \.self) { e in
                        let row = (e - 20) / (n + 1), col = (e - 20) % (n + 1)
                        edge(e, drawn: game.edges[e], legal: legal.contains(e),
                             size: CGSize(width: 8, height: pitch - 10))
                            .position(x: inset + pitch * CGFloat(col), y: inset + pitch * (CGFloat(row) + 0.5))
                    }
                    // Dots
                    ForEach(0..<((n + 1) * (n + 1)), id: \.self) { d in
                        let row = d / (n + 1), col = d % (n + 1)
                        Circle().fill(Color.primary).frame(width: 10, height: 10)
                            .position(x: inset + pitch * CGFloat(col), y: inset + pitch * CGFloat(row))
                    }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            HStack {
                Text("You \(game.score(context.myPlayer))")
                Text("·").foregroundStyle(.secondary)
                Text("Them \(game.score(context.myPlayer.other))")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func edge(_ index: Int, drawn: Bool, legal: Bool, size: CGSize) -> some View {
        Button {
            context.onMove(Data([UInt8(index)]))
        } label: {
            RoundedRectangle(cornerRadius: 4)
                .fill(drawn ? Color.primary : Color.secondary.opacity(context.interactive && legal ? 0.25 : 0.08))
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle().size(width: max(size.width, 24), height: max(size.height, 24)))
        }
        .buttonStyle(.plain)
        .disabled(!context.interactive || !legal)
    }
}
