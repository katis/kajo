//! The bytecode interpreter and primitives (SPEC-SHARED.md "Bytecodes", "Frames").

use crate::kasm::*;
use crate::object::*;
use crate::vm::{fatal, Vm, Worker, CACHE_SIZE};
use std::sync::atomic::Ordering;

/// Interpreter registers. Passed by value into always-inline helpers so they
/// stay in machine registers.
#[derive(Clone, Copy)]
struct Regs {
    pc: *const u8,
    sp: *mut u64,
    fp: *mut u64,
    hdr: *mut u64,
    lits: *const u64,
}

const HOST_FP: u64 = 1; // mk_int(0)

#[inline(always)]
unsafe fn activate(vm: &Vm, w: &mut Worker, r: Regs, method: Oop, argc: usize) -> Regs {
    let fp = r.sp.sub(argc);
    let nt = int_val(slot(method, M_NTEMPS)) as usize;
    let max_stack = int_val(slot(method, M_MAXSTACK)) as usize;
    let mut sp = r.sp;
    if sp.add(nt + 4 + max_stack) >= w.stack_end {
        fatal("stack overflow");
    }
    for _ in 0..nt {
        sp = sp.add(1);
        *sp = vm.nil;
    }
    let hdr = sp.add(1);
    *hdr = method;
    *hdr.add(1) = mk_int(r.pc as i64);
    *hdr.add(2) = mk_int(r.fp as i64);
    *hdr.add(3) = mk_int(r.hdr as i64);
    Regs {
        pc: bytes_ptr(slot(method, M_BYTECODES)),
        sp: hdr.add(3),
        fp,
        hdr,
        lits: slots_ptr(slot(method, M_LITERALS)),
    }
}

#[inline(always)]
unsafe fn do_return(r: Regs, v: Oop) -> Regs {
    let fp = int_val(*r.hdr.add(2)) as *mut u64;
    let hdr = int_val(*r.hdr.add(3)) as *mut u64;
    *r.fp = v;
    Regs {
        pc: int_val(*r.hdr.add(1)) as *const u8,
        sp: r.fp,
        fp,
        hdr,
        lits: slots_ptr(slot(*hdr, M_LITERALS)),
    }
}

#[inline(always)]
unsafe fn poll(vm: &Vm, w: &mut Worker, sp: *mut u64) {
    if vm.gc_requested.load(Ordering::Relaxed) {
        w.sp = sp;
        vm.safepoint(w);
    }
}

#[inline(always)]
unsafe fn send(vm: &Vm, w: &mut Worker, r: Regs, sel: Oop, argc: usize) -> Regs {
    poll(vm, w, r.sp);
    let recv = *r.sp.sub(argc);
    let cls = class_index_of(recv);
    let e = &mut *w.cache.add((((sel >> 3) ^ cls) as usize) & (CACHE_SIZE - 1));
    let method = if e.cls == cls && e.sel == sel {
        e.method
    } else {
        let m = lookup_miss(vm, w, cls, sel);
        let e = &mut *w.cache.add((((sel >> 3) ^ cls) as usize) & (CACHE_SIZE - 1));
        e.cls = cls;
        e.sel = sel;
        e.method = m;
        m
    };
    let prim = slot(method, M_PRIM);
    if prim != mk_int(0) {
        w.sp = r.sp;
        let res = primitive(vm, w, int_val(prim), r.sp, argc);
        let sp = r.sp.sub(argc);
        *sp = res;
        return Regs { sp, ..r };
    }
    activate(vm, w, r, method, argc)
}

#[inline(never)]
unsafe fn send_slow(vm: &Vm, w: &mut Worker, r: Regs, sel: Oop, argc: usize) -> Regs {
    send(vm, w, r, sel, argc)
}

#[cold]
#[inline(never)]
unsafe fn lookup_miss(vm: &Vm, w: &mut Worker, cls: u64, sel: Oop) -> Oop {
    w.misses += 1;
    let m = vm.lookup(cls, sel);
    if m == 0 {
        fatal("doesNotUnderstand");
    }
    m
}

#[inline(never)]
unsafe fn primitive(vm: &Vm, w: &mut Worker, prim: i64, sp: *mut u64, argc: usize) -> Oop {
    let recv = *sp.sub(argc);
    let arg = |i: usize| *sp.sub(argc).add(1 + i);
    match prim {
        1 | 2 => {
            let idx = arg(0);
            if is_int(recv) || !is_int(idx) {
                fatal("at: bad receiver or index");
            }
            let h = header(recv);
            let i = int_val(idx);
            if i < 1 || i as usize > hdr_slots(h) {
                fatal("at: index out of bounds");
            }
            let i = i as usize - 1;
            if hdr_is_bytes(h) {
                if prim == 2 {
                    fatal("at:put: on bytes");
                }
                mk_int(*bytes_ptr(recv).add(i) as i64)
            } else if prim == 1 {
                slot(recv, i)
            } else {
                set_slot(recv, i, arg(1));
                arg(1)
            }
        }
        3 | 4 => {
            if is_int(recv) || hdr_class(header(recv)) != CI_CLASS as u64 {
                fatal("basicNew on non-class");
            }
            let extra = if prim == 3 {
                let n = arg(0);
                if !is_int(n) || int_val(n) < 0 {
                    fatal("basicNew: bad size");
                }
                int_val(n) as usize
            } else {
                0
            };
            let n = int_val(slot(recv, C_INSTSIZE)) as usize + extra;
            let cls = int_val(slot(recv, C_INDEX)) as u32;
            vm.alloc(w, cls, n, false)
        }
        5 => vm.class_at(class_index_of(recv)),
        6 | 7 => {
            let b = arg(0);
            if !is_int(recv) || !is_int(b) || int_val(b) == 0 {
                fatal("// or \\\\ failed");
            }
            let (a, b) = (int_val(recv), int_val(b));
            let q = a / b;
            let fq = if a % b != 0 && ((a < 0) != (b < 0)) { q - 1 } else { q };
            if !fits_int(fq) {
                fatal("// overflow");
            }
            mk_int(if prim == 6 { fq } else { a - fq * b })
        }
        _ => fatal("unknown primitive"),
    }
}

/// Send `sel` to `recv` with `args` on worker `w` and run to completion.
pub unsafe fn execute(vm: &Vm, w: &mut Worker, recv: Oop, sel: Oop, args: &[Oop]) -> Oop {
    let mut sp = w.sp;
    sp = sp.add(1);
    *sp = recv;
    for &a in args {
        sp = sp.add(1);
        *sp = a;
    }
    let method = vm.lookup(class_index_of(recv), sel);
    if method == 0 || slot(method, M_PRIM) != mk_int(0) {
        fatal("entry method missing or primitive");
    }
    let host = Regs { pc: std::ptr::null(), sp, fp: std::ptr::null_mut(), hdr: std::ptr::null_mut(), lits: std::ptr::null() };
    let mut r = activate(vm, w, host, method, args.len());
    let (nil, t, f) = (vm.nil, vm.true_obj, vm.false_obj);

    macro_rules! push {
        ($v:expr) => {{
            let v = $v;
            r.sp = r.sp.add(1);
            *r.sp = v;
        }};
    }
    macro_rules! byte {
        () => {{
            let b = *r.pc;
            r.pc = r.pc.add(1);
            b
        }};
    }
    macro_rules! offset {
        () => {{
            let o = i16::from_le_bytes([*r.pc, *r.pc.add(1)]) as isize;
            r.pc = r.pc.add(2);
            o
        }};
    }
    macro_rules! arith {
        ($idx:expr, $fast:expr) => {{
            let b = *r.sp;
            let a = *r.sp.sub(1);
            let fast: Option<u64> = if a & b & 1 != 0 { $fast(a as i64, b as i64) } else { None };
            match fast {
                Some(v) => {
                    r.sp = r.sp.sub(1);
                    *r.sp = v;
                }
                None => r = send_slow(vm, w, r, vm.special[$idx], 1),
            }
        }};
    }
    macro_rules! compare {
        ($idx:expr, $op:tt) => {{
            let b = *r.sp;
            let a = *r.sp.sub(1);
            if a & b & 1 != 0 {
                r.sp = r.sp.sub(1);
                *r.sp = if (a as i64) $op (b as i64) { t } else { f };
            } else {
                r = send_slow(vm, w, r, vm.special[$idx], 1);
            }
        }};
    }
    macro_rules! ret {
        ($v:expr) => {{
            let v = $v;
            if *r.hdr.add(2) == HOST_FP {
                w.sp = r.fp.sub(1);
                return v;
            }
            r = do_return(r, v);
        }};
    }

    loop {
        let op = byte!();
        match op {
            OP_PUSH_TEMP => {
                let n = byte!() as usize;
                push!(*r.fp.add(1 + n));
            }
            OP_PUSH_LIT => {
                let n = byte!() as usize;
                push!(*r.lits.add(n));
            }
            OP_PUSH_SELF => push!(*r.fp),
            OP_PUSH_IVAR => {
                let n = byte!() as usize;
                push!(slot(*r.fp, n));
            }
            OP_STORE_TEMP => {
                let n = byte!() as usize;
                *r.fp.add(1 + n) = *r.sp;
                r.sp = r.sp.sub(1);
            }
            OP_STORE_IVAR => {
                let n = byte!() as usize;
                set_slot(*r.fp, n, *r.sp);
                r.sp = r.sp.sub(1);
            }
            OP_POP => r.sp = r.sp.sub(1),
            OP_DUP => push!(*r.sp),
            OP_PUSH_NIL => push!(nil),
            OP_PUSH_TRUE => push!(t),
            OP_PUSH_FALSE => push!(f),
            OP_PUSH_INT => {
                let b = byte!() as i8;
                push!(mk_int(b as i64));
            }
            OP_SEND => {
                let lit = byte!() as usize;
                let argc = byte!() as usize;
                let sel = *r.lits.add(lit);
                r = send(vm, w, r, sel, argc);
            }
            OP_RETURN_TOP => ret!(*r.sp),
            OP_RETURN_SELF => ret!(*r.fp),
            OP_JUMP => {
                let off = offset!();
                r.pc = r.pc.offset(off);
                if off < 0 {
                    poll(vm, w, r.sp);
                }
            }
            OP_JUMP_IF_TRUE => {
                let off = offset!();
                let v = *r.sp;
                r.sp = r.sp.sub(1);
                if v == t {
                    r.pc = r.pc.offset(off);
                    if off < 0 {
                        poll(vm, w, r.sp);
                    }
                } else if v != f {
                    fatal("mustBeBoolean");
                }
            }
            OP_JUMP_IF_FALSE => {
                let off = offset!();
                let v = *r.sp;
                r.sp = r.sp.sub(1);
                if v == f {
                    r.pc = r.pc.offset(off);
                    if off < 0 {
                        poll(vm, w, r.sp);
                    }
                } else if v != t {
                    fatal("mustBeBoolean");
                }
            }
            OP_ADD => arith!(0, |a: i64, b: i64| a.checked_add(b - 1).map(|v| v as u64)),
            OP_SUB => arith!(1, |a: i64, b: i64| a.checked_sub(b - 1).map(|v| v as u64)),
            OP_MUL => arith!(2, |a: i64, b: i64| (a >> 1).checked_mul(b - 1).map(|v| (v | 1) as u64)),
            OP_LT => compare!(3, <),
            OP_GT => compare!(4, >),
            OP_LE => compare!(5, <=),
            OP_GE => compare!(6, >=),
            OP_EQ => compare!(7, ==),
            OP_IDENTICAL => {
                let b = *r.sp;
                r.sp = r.sp.sub(1);
                *r.sp = if *r.sp == b { t } else { f };
            }
            _ => fatal("bad opcode"),
        }
    }
}
