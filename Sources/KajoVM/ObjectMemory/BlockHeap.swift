/// The block heap: one reservation, cut into 32 KiB blocks.
struct BlockHeap {
    static let blockBytes = 32 * 1024
}
