//! Single-threaded iterative mark (SPEC-SHARED.md "Heap, TLAB, GC").

use crate::object::*;

#[inline(always)]
unsafe fn mark_value(v: Oop, stack: &mut Vec<Oop>) {
    if v & 1 == 0 {
        let h = header(v);
        if !hdr_marked(h) {
            *header_ptr(v) = h | MARK_BIT;
            if !hdr_is_bytes(h) {
                stack.push(v);
            }
        }
    }
}

/// Mark everything reachable from `roots`. `stack` is a reusable mark stack.
pub unsafe fn mark_roots(roots: &[Oop], stack: &mut Vec<Oop>) {
    for &r in roots {
        mark_value(r, stack);
    }
    drain(stack);
}

pub unsafe fn drain(stack: &mut Vec<Oop>) {
    while let Some(o) = stack.pop() {
        let n = hdr_slots(header(o));
        let s = slots_ptr(o);
        for i in 0..n {
            mark_value(*s.add(i), stack);
        }
    }
}
