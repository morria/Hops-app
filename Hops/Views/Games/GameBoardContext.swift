import SwiftUI

/// Everything a board view needs. Views are dumb: they draw `engine`, and
/// when `interactive` they call `onMove` with one encoded move. The
/// coordinator does the sending, acking, and committing.
struct GameBoardContext {
    let engine: any GameEngine
    let myPlayer: Player
    /// True only when it is my turn and nothing is in flight.
    let interactive: Bool
    /// Hidden local setup (Battleship placement); empty until chosen.
    let privateData: Data
    let onMove: (Data) -> Void
    let onPrivateSetup: (Data) -> Void
}
