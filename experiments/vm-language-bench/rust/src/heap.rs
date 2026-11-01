//! Block-structured arena, free-block pool and TLABs (SPEC-SHARED.md "Heap, TLAB, GC").

use crate::object::*;
use std::sync::atomic::{AtomicUsize, Ordering};

pub const BLOCK_SIZE: usize = 32 * 1024;
pub const HEAP_SIZE: usize = 64 << 20;
pub const NO_BLOCK: u32 = u32::MAX;

extern "C" {
    fn mmap(addr: *mut u8, len: usize, prot: i32, flags: i32, fd: i32, off: i64) -> *mut u8;
}
const PROT_READ_WRITE: i32 = 0x1 | 0x2;
const MAP_PRIVATE_ANON: i32 = 0x0002 | 0x1000;

/// Thread-local allocation buffer: a bump pointer into one block.
pub struct Tlab {
    pub cur: *mut u8,
    pub end: *mut u8,
    pub block: u32,
}

impl Tlab {
    pub const fn empty() -> Tlab {
        Tlab { cur: std::ptr::null_mut(), end: std::ptr::null_mut(), block: NO_BLOCK }
    }
}

pub struct Heap {
    pub base: *mut u8,
    pub nblocks: usize,
    used: *mut u32,
    in_use: *mut bool,
    free_list: *mut u32,
    free_count: AtomicUsize,
    free_next: AtomicUsize,
}

fn leak_array<T: Copy>(n: usize, v: T) -> *mut T {
    Box::into_raw(vec![v; n].into_boxed_slice()) as *mut T
}

impl Heap {
    pub fn new(size: usize) -> Heap {
        assert!(size % BLOCK_SIZE == 0);
        let base = unsafe { mmap(std::ptr::null_mut(), size, PROT_READ_WRITE, MAP_PRIVATE_ANON, -1, 0) };
        assert!(!base.is_null() && base as isize != -1, "mmap failed");
        let nblocks = size / BLOCK_SIZE;
        let free_list = leak_array(nblocks, 0u32);
        for i in 0..nblocks {
            unsafe { *free_list.add(i) = i as u32 };
        }
        Heap {
            base,
            nblocks,
            used: leak_array(nblocks, 0u32),
            in_use: leak_array(nblocks, false),
            free_list,
            free_count: AtomicUsize::new(nblocks),
            free_next: AtomicUsize::new(0),
        }
    }

    #[inline]
    pub fn block_start(&self, b: u32) -> *mut u8 {
        unsafe { self.base.add(b as usize * BLOCK_SIZE) }
    }

    /// Takes a completely empty block from the pool. Lock-free; the pool is
    /// only rebuilt while the world is stopped.
    pub fn take_block(&self) -> Option<u32> {
        let i = self.free_next.fetch_add(1, Ordering::Relaxed);
        if i < self.free_count.load(Ordering::Relaxed) {
            unsafe {
                let b = *self.free_list.add(i);
                *self.in_use.add(b as usize) = true;
                Some(b)
            }
        } else {
            None
        }
    }

    /// Point the TLAB at a fresh block. Returns false if the pool is empty.
    pub fn refill(&self, t: &mut Tlab) -> bool {
        self.retire(t);
        match self.take_block() {
            Some(b) => {
                t.block = b;
                t.cur = self.block_start(b);
                t.end = unsafe { t.cur.add(BLOCK_SIZE) };
                true
            }
            None => false,
        }
    }

    /// Record how much of the TLAB's block is used and detach it.
    pub fn retire(&self, t: &mut Tlab) {
        if t.block != NO_BLOCK {
            let used = t.cur as usize - self.block_start(t.block) as usize;
            unsafe { *self.used.add(t.block as usize) = used as u32 };
        }
        *t = Tlab::empty();
    }

    pub fn free_blocks(&self) -> usize {
        self.free_count.load(Ordering::Relaxed).saturating_sub(self.free_next.load(Ordering::Relaxed))
    }

    /// Sweep (world stopped, all TLABs retired): clear marks, return blocks
    /// without live objects to the pool. Returns (free blocks, live bytes).
    pub unsafe fn sweep(&self) -> (usize, usize) {
        let mut live_bytes = 0;
        let mut nfree = 0;
        for b in 0..self.nblocks {
            if *self.in_use.add(b) {
                let start = self.block_start(b as u32);
                let end = start.add(*self.used.add(b) as usize);
                let mut p = start;
                let mut live = false;
                while p < end {
                    let h = *(p as *const u64);
                    let size = object_bytes(h);
                    if hdr_marked(h) {
                        *(p as *mut u64) = h & !MARK_BIT;
                        live = true;
                        live_bytes += size;
                    }
                    p = p.add(size);
                }
                if live {
                    continue;
                }
                *self.in_use.add(b) = false;
                *self.used.add(b) = 0;
            }
            *self.free_list.add(nfree) = b as u32;
            nfree += 1;
        }
        self.free_count.store(nfree, Ordering::Relaxed);
        self.free_next.store(0, Ordering::Relaxed);
        (nfree, live_bytes)
    }
}

/// Allocation fast path. Returns None when the TLAB is exhausted.
#[inline(always)]
pub unsafe fn tlab_alloc(t: &mut Tlab, class: u32, slots: usize, bytes: bool, fill: Oop) -> Option<Oop> {
    let size = size_for(slots, bytes);
    if (t.end as usize) - (t.cur as usize) < size {
        return None;
    }
    let p = t.cur as *mut u64;
    t.cur = t.cur.add(size);
    *p = make_header(class, slots, bytes);
    let n = (size - 8) / 8;
    let f = if bytes { 0 } else { fill };
    for i in 1..=n {
        *p.add(i) = f;
    }
    Some(p as Oop)
}
