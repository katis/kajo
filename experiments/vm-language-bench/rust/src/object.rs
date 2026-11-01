//! Tagged values and object header packing (SPEC-SHARED.md "Values", "Object header").

pub type Oop = u64;

pub const CLASS_MASK: u64 = (1 << 22) - 1;
pub const SLOTS_SHIFT: u32 = 22;
pub const SLOTS_MASK: u64 = (1 << 32) - 1;
pub const MARK_BIT: u64 = 1 << 54;
pub const BYTES_BIT: u64 = 1 << 55;

pub const INT_MIN: i64 = -(1 << 62);
pub const INT_MAX: i64 = (1 << 62) - 1;

// Well-known class indices.
pub const CI_SMALLINT: u32 = 1;
pub const CI_NIL: u32 = 2;
pub const CI_TRUE: u32 = 3;
pub const CI_FALSE: u32 = 4;
pub const CI_CLASS: u32 = 5;
pub const CI_METHOD: u32 = 6;
pub const CI_ARRAY: u32 = 7;
pub const CI_BYTEARRAY: u32 = 8;
pub const CI_SYMBOL: u32 = 9;
pub const CI_METHODDICT: u32 = 10;
pub const CI_OBJECT: u32 = 11;
pub const FIRST_USER_CLASS: u32 = 12;
pub const CLASS_TABLE_SIZE: usize = 1024;

pub const BUILTIN_CLASS_NAMES: [&str; 11] = [
    "SmallInteger", "UndefinedObject", "True", "False", "Class", "Method",
    "Array", "ByteArray", "Symbol", "MethodDict", "Object",
];

// Class object slots.
pub const C_SUPER: usize = 0;
pub const C_DICT: usize = 1;
pub const C_NAME: usize = 2;
pub const C_INSTSIZE: usize = 3;
pub const C_INDEX: usize = 4;
pub const CLASS_SLOTS: usize = 5;

// Method object slots.
pub const M_BYTECODES: usize = 0;
pub const M_LITERALS: usize = 1;
pub const M_ARGC: usize = 2;
pub const M_NTEMPS: usize = 3;
pub const M_MAXSTACK: usize = 4;
pub const M_SELECTOR: usize = 5;
pub const M_PRIM: usize = 6;
pub const METHOD_SLOTS: usize = 7;

#[inline(always)]
pub fn is_int(v: Oop) -> bool {
    v & 1 != 0
}
#[inline(always)]
pub fn int_val(v: Oop) -> i64 {
    (v as i64) >> 1
}
#[inline(always)]
pub fn mk_int(i: i64) -> Oop {
    ((i << 1) | 1) as u64
}
#[inline(always)]
pub fn fits_int(i: i64) -> bool {
    (INT_MIN..=INT_MAX).contains(&i)
}

#[inline(always)]
pub fn make_header(class: u32, slots: usize, bytes: bool) -> u64 {
    debug_assert!((class as u64) <= CLASS_MASK);
    debug_assert!((slots as u64) <= SLOTS_MASK);
    (class as u64) | ((slots as u64) << SLOTS_SHIFT) | if bytes { BYTES_BIT } else { 0 }
}
#[inline(always)]
pub fn hdr_class(h: u64) -> u64 {
    h & CLASS_MASK
}
#[inline(always)]
pub fn hdr_slots(h: u64) -> usize {
    ((h >> SLOTS_SHIFT) & SLOTS_MASK) as usize
}
#[inline(always)]
pub fn hdr_is_bytes(h: u64) -> bool {
    h & BYTES_BIT != 0
}
#[inline(always)]
pub fn hdr_marked(h: u64) -> bool {
    h & MARK_BIT != 0
}
/// Total object size in bytes, header included.
#[inline(always)]
pub fn object_bytes(h: u64) -> usize {
    let n = hdr_slots(h);
    8 + if hdr_is_bytes(h) { (n + 7) & !7 } else { n * 8 }
}
#[inline(always)]
pub fn size_for(slots: usize, bytes: bool) -> usize {
    8 + if bytes { (slots + 7) & !7 } else { slots * 8 }
}

// Raw object access. Callers guarantee `o` is a valid object pointer.
#[inline(always)]
pub unsafe fn header(o: Oop) -> u64 {
    *(o as *const u64)
}
#[inline(always)]
pub unsafe fn header_ptr(o: Oop) -> *mut u64 {
    o as *mut u64
}
#[inline(always)]
pub unsafe fn slots_ptr(o: Oop) -> *mut u64 {
    (o as *mut u64).add(1)
}
#[inline(always)]
pub unsafe fn slot(o: Oop, i: usize) -> Oop {
    *slots_ptr(o).add(i)
}
#[inline(always)]
pub unsafe fn set_slot(o: Oop, i: usize, v: Oop) {
    *slots_ptr(o).add(i) = v
}
#[inline(always)]
pub unsafe fn bytes_ptr(o: Oop) -> *mut u8 {
    (o as *mut u8).add(8)
}
#[inline(always)]
pub unsafe fn class_index_of(v: Oop) -> u64 {
    if is_int(v) {
        CI_SMALLINT as u64
    } else {
        hdr_class(header(v))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn smallint_roundtrip() {
        for i in [0i64, 1, -1, 42, -42, INT_MAX, INT_MIN] {
            let v = mk_int(i);
            assert!(is_int(v));
            assert_eq!(int_val(v), i);
        }
        assert!(!fits_int(INT_MAX + 1));
        assert!(!fits_int(INT_MIN - 1));
    }

    #[test]
    fn tagged_ordering_is_monotonic() {
        assert!((mk_int(-5) as i64) < (mk_int(3) as i64));
        assert!((mk_int(INT_MIN) as i64) < (mk_int(INT_MAX) as i64));
    }

    #[test]
    fn header_packing() {
        let h = make_header(0x3F_FFFF, 0xFFFF_FFFF, false);
        assert_eq!(hdr_class(h), 0x3F_FFFF);
        assert_eq!(hdr_slots(h), 0xFFFF_FFFF);
        assert!(!hdr_marked(h) && !hdr_is_bytes(h));
        let h = make_header(7, 3, true) | MARK_BIT;
        assert_eq!(hdr_class(h), 7);
        assert_eq!(hdr_slots(h), 3);
        assert!(hdr_is_bytes(h) && hdr_marked(h));
        assert_eq!(h, 7 | (3 << 22) | (1 << 54) | (1 << 55));
    }

    #[test]
    fn object_sizes() {
        assert_eq!(object_bytes(make_header(1, 0, false)), 8);
        assert_eq!(object_bytes(make_header(1, 2, false)), 24);
        assert_eq!(object_bytes(make_header(1, 1, true)), 16);
        assert_eq!(object_bytes(make_header(1, 8, true)), 16);
        assert_eq!(object_bytes(make_header(1, 9, true)), 24);
    }
}
