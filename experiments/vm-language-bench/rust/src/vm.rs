//! VM state, workers, allocation slow path, safepoints and GC driver.

use crate::gc;
use crate::heap::*;
use crate::object::*;
use std::cell::UnsafeCell;
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Condvar, Mutex};
use std::time::Instant;

pub const CACHE_SIZE: usize = 1024;
pub const STACK_WORDS: usize = 64 * 1024;

#[repr(C)]
#[derive(Clone, Copy)]
pub struct CacheEntry {
    pub cls: u64,
    pub sel: u64,
    pub method: u64,
}

/// Per-worker state. Owned by its thread while running; the GC reads `stack`
/// and `sp` only while the owner is parked.
pub struct Worker {
    pub id: usize,
    pub stack: *mut u64,
    pub stack_end: *mut u64,
    pub sp: *mut u64,
    pub tlab: Tlab,
    pub cache: *mut CacheEntry,
    pub misses: u64,
}

impl Worker {
    pub fn new(id: usize, nil: Oop) -> Box<Worker> {
        let stack = Box::into_raw(vec![nil; STACK_WORDS].into_boxed_slice()) as *mut u64;
        let cache = Box::into_raw(vec![CacheEntry { cls: 0, sel: 0, method: 0 }; CACHE_SIZE].into_boxed_slice())
            as *mut CacheEntry;
        Box::new(Worker {
            id,
            stack,
            stack_end: unsafe { stack.add(STACK_WORDS) },
            sp: stack, // stack[0] = nil sentinel
            tlab: Tlab::empty(),
            cache,
            misses: 0,
        })
    }
}

impl Drop for Worker {
    fn drop(&mut self) {
        unsafe {
            drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(self.stack, STACK_WORDS)));
            drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(self.cache, CACHE_SIZE)));
        }
    }
}

struct SafepointState {
    active: usize,
    parked: usize,
    epoch: u64,
}

pub struct Vm {
    pub heap: Heap,
    pub class_table: *mut Oop,
    pub class_count: usize,
    pub nil: Oop,
    pub true_obj: Oop,
    pub false_obj: Oop,
    pub special: [Oop; 9],
    pub class_names: HashMap<String, u32>,
    pub symbols: HashMap<String, Oop>,
    /// Host-side roots: nil/true/false and every symbol.
    pub roots: Vec<Oop>,
    pub gc_requested: AtomicBool,
    sp_state: Mutex<SafepointState>,
    sp_cond: Condvar,
    workers: UnsafeCell<Vec<*mut Worker>>,
    mark_stack: UnsafeCell<Vec<Oop>>,
    pub gc_count: AtomicU64,
    pub gc_nanos: AtomicU64,
    pub verbose_gc: bool,
}

// The VM is shared by all worker threads. Mutable parts are either atomics,
// behind the safepoint mutex, or only touched while the world is stopped.
unsafe impl Sync for Vm {}
unsafe impl Send for Vm {}

impl Vm {
    pub fn new_empty(heap_size: usize) -> Vm {
        Vm {
            heap: Heap::new(heap_size),
            class_table: Box::into_raw(vec![0u64; CLASS_TABLE_SIZE].into_boxed_slice()) as *mut Oop,
            class_count: 0,
            nil: 0,
            true_obj: 0,
            false_obj: 0,
            special: [0; 9],
            class_names: HashMap::new(),
            symbols: HashMap::new(),
            roots: vec![],
            gc_requested: AtomicBool::new(false),
            sp_state: Mutex::new(SafepointState { active: 0, parked: 0, epoch: 0 }),
            sp_cond: Condvar::new(),
            workers: UnsafeCell::new(vec![]),
            mark_stack: UnsafeCell::new(Vec::with_capacity(1 << 16)),
            gc_count: AtomicU64::new(0),
            gc_nanos: AtomicU64::new(0),
            verbose_gc: false,
        }
    }

    #[inline(always)]
    pub unsafe fn class_at(&self, idx: u64) -> Oop {
        *self.class_table.add(idx as usize)
    }

    /// Register workers and set the active count. Call before starting threads.
    pub fn set_workers(&self, ws: &[*mut Worker]) {
        unsafe { *self.workers.get() = ws.to_vec() };
        let mut st = self.sp_state.lock().unwrap();
        st.active = ws.len();
        st.parked = 0;
    }

    /// Allocate an object; may stop the world. `w.sp` must be flushed.
    #[inline(always)]
    pub unsafe fn alloc(&self, w: &mut Worker, class: u32, slots: usize, bytes: bool) -> Oop {
        match tlab_alloc(&mut w.tlab, class, slots, bytes, self.nil) {
            Some(o) => o,
            None => self.alloc_slow(w, class, slots, bytes),
        }
    }

    #[inline(never)]
    pub unsafe fn alloc_slow(&self, w: &mut Worker, class: u32, slots: usize, bytes: bool) -> Oop {
        if size_for(slots, bytes) > BLOCK_SIZE {
            fatal("object larger than a block");
        }
        if !self.heap.refill(&mut w.tlab) {
            self.request_gc(w);
            if !self.heap.refill(&mut w.tlab) {
                fatal("out of memory");
            }
        }
        tlab_alloc(&mut w.tlab, class, slots, bytes, self.nil).unwrap()
    }

    /// Called at a safepoint when `gc_requested` was seen set.
    #[inline(never)]
    pub fn safepoint(&self, w: &mut Worker) {
        self.heap.retire(&mut w.tlab);
        let st = self.sp_state.lock().unwrap();
        drop(self.park(st));
    }

    fn park<'a>(&self, mut st: std::sync::MutexGuard<'a, SafepointState>) -> std::sync::MutexGuard<'a, SafepointState> {
        if !self.gc_requested.load(Ordering::Acquire) {
            return st;
        }
        let epoch = st.epoch;
        st.parked += 1;
        self.sp_cond.notify_all();
        while st.epoch == epoch {
            st = self.sp_cond.wait(st).unwrap();
        }
        st.parked -= 1;
        st
    }

    /// Stop the world and collect (or park if someone else is collecting).
    pub fn request_gc(&self, w: &mut Worker) {
        self.heap.retire(&mut w.tlab);
        let mut st = self.sp_state.lock().unwrap();
        if self.gc_requested.load(Ordering::Acquire) {
            drop(self.park(st));
            return;
        }
        self.gc_requested.store(true, Ordering::Release);
        while st.parked + 1 < st.active {
            st = self.sp_cond.wait(st).unwrap();
        }
        unsafe { self.collect() };
        self.gc_requested.store(false, Ordering::Release);
        st.epoch += 1;
        self.sp_cond.notify_all();
    }

    /// A worker leaves the VM (its thread is done running Smalltalk).
    pub fn worker_finished(&self, w: &mut Worker) {
        self.heap.retire(&mut w.tlab);
        let mut st = self.sp_state.lock().unwrap();
        st.active -= 1;
        self.sp_cond.notify_all();
    }

    /// Full mark-sweep. World must be stopped and all TLABs retired.
    pub unsafe fn collect(&self) {
        let t0 = Instant::now();
        let ms = &mut *self.mark_stack.get();
        gc::mark_roots(&self.roots, ms);
        gc::mark_roots(std::slice::from_raw_parts(self.class_table.add(1), self.class_count.saturating_sub(1)), ms);
        for &w in (*self.workers.get()).iter() {
            let w = &*w;
            let n = w.sp.offset_from(w.stack) as usize + 1;
            gc::mark_roots(std::slice::from_raw_parts(w.stack, n), ms);
        }
        let (free, live) = self.heap.sweep();
        let ns = t0.elapsed().as_nanos() as u64;
        self.gc_count.fetch_add(1, Ordering::Relaxed);
        self.gc_nanos.fetch_add(ns, Ordering::Relaxed);
        if self.verbose_gc {
            eprintln!("gc: {free} free blocks, {live} live bytes, {:.2} ms", ns as f64 / 1e6);
        }
    }
}

#[cold]
#[inline(never)]
pub fn fatal(msg: &str) -> ! {
    eprintln!("kajo: fatal: {msg}");
    std::process::exit(2)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn gc_reclaims_garbage_and_keeps_survivors() {
        // 1 MiB heap = 32 blocks; allocate ~40 MiB total with a live list.
        let mut vm = Vm::new_empty(32 * BLOCK_SIZE);
        let mut boot = Worker::new(0, 0);
        unsafe {
            vm.nil = vm.alloc(&mut boot, CI_NIL, 0, false);
            vm.roots.push(vm.nil);
            vm.heap.retire(&mut boot.tlab);
        }
        let mut w = Worker::new(0, vm.nil);
        let wp: *mut Worker = &mut *w;
        vm.set_workers(&[wp]);
        unsafe {
            // Survivors: a 1000-element linked list (slot 0 = next, slot 1 = int).
            let mut head = vm.nil;
            w.sp = w.sp.add(1);
            for i in 0..1000 {
                *w.sp = head;
                let node = vm.alloc(&mut w, CI_ARRAY, 2, false);
                set_slot(node, 0, head);
                set_slot(node, 1, mk_int(i));
                head = node;
            }
            *w.sp = head;
            for i in 0..200_000 {
                let g = vm.alloc(&mut w, CI_ARRAY, 20, i % 3 == 0);
                assert_eq!(hdr_slots(header(g)), 20);
            }
            assert!(vm.gc_count.load(Ordering::Relaxed) > 5);
            let mut p = *w.sp;
            let mut i = 999;
            while p != vm.nil {
                assert_eq!(hdr_class(header(p)), CI_ARRAY as u64);
                assert!(!hdr_marked(header(p)));
                assert_eq!(int_val(slot(p, 1)), i);
                i -= 1;
                p = slot(p, 0);
            }
            assert_eq!(i, -1);
        }
    }
}
