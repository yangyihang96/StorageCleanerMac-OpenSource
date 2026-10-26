import Darwin

/// D101 G4-2, layer 3: the BSD file flags that keep an item from being moved
/// or deleted, read the same way by the privileged helper and by every flow
/// in the app. Copying keeps its own set (`GuardedFileCopy.renameBlockingFlags`):
/// there the flags are carried over, not a reason to refuse.
public enum FileProtectionFlags {
    /// Set by the owner: Finder's "Locked" (`uchg`) and append-only (`uappnd`).
    public static let owner = UInt32(UF_IMMUTABLE | UF_APPEND)
    /// Set only by the system: `schg`, `sappnd`, `sunlnk` and SIP's `restricted`.
    public static let system = UInt32(SF_IMMUTABLE | SF_APPEND | SF_RESTRICTED | SF_NOUNLINK)
    public static let all = owner | system

    public enum Lock: Equatable, Sendable {
        case none
        /// The owner can lift it.
        case owner
        /// Only the system can lift it; wins over an owner flag.
        case system
    }

    public static func lock(_ flags: UInt32) -> Lock {
        if flags & system != 0 { return .system }
        if flags & owner != 0 { return .owner }
        return .none
    }
}
