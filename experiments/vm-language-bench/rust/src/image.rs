//! Boot the object memory and install .kasm programs (SPEC-SHARED.md "Boot").

use crate::heap::HEAP_SIZE;
use crate::kasm::{self, Lit, Program, SPECIAL_SELECTORS};
use crate::object::*;
use crate::vm::{Vm, Worker};

impl Vm {
    /// A VM with nil/true/false, builtin classes and special selectors.
    pub fn boot(heap_size: usize) -> (Box<Vm>, Box<Worker>) {
        let mut vm = Box::new(Vm::new_empty(heap_size));
        let mut w = Worker::new(usize::MAX, 0);
        unsafe {
            vm.nil = vm.alloc(&mut w, CI_NIL, 0, false);
            vm.true_obj = vm.alloc(&mut w, CI_TRUE, 0, false);
            vm.false_obj = vm.alloc(&mut w, CI_FALSE, 0, false);
            vm.roots.extend([vm.nil, vm.true_obj, vm.false_obj]);
            for (i, name) in BUILTIN_CLASS_NAMES.iter().enumerate() {
                let idx = i as u32 + 1;
                let c = vm.alloc(&mut w, CI_CLASS, CLASS_SLOTS, false);
                *vm.class_table.add(idx as usize) = c;
                vm.class_names.insert(name.to_string(), idx);
            }
            vm.class_count = 1 + BUILTIN_CLASS_NAMES.len();
            let object = vm.class_at(CI_OBJECT as u64);
            for idx in 1..vm.class_count as u32 {
                let c = vm.class_at(idx as u64);
                set_slot(c, C_SUPER, if idx == CI_OBJECT { vm.nil } else { object });
                set_slot(c, C_INSTSIZE, mk_int(0));
                set_slot(c, C_INDEX, mk_int(idx as i64));
            }
            for (i, s) in SPECIAL_SELECTORS.iter().enumerate() {
                vm.special[i] = vm.intern(&mut w, s);
            }
        }
        (vm, w)
    }

    pub unsafe fn intern(&mut self, w: &mut Worker, name: &str) -> Oop {
        if let Some(&s) = self.symbols.get(name) {
            return s;
        }
        let id = self.symbols.len() as i64;
        let s = self.alloc(w, CI_SYMBOL, 1, false);
        set_slot(s, 0, mk_int(id));
        self.symbols.insert(name.to_string(), s);
        self.roots.push(s);
        s
    }

    pub fn class_index(&self, name: &str) -> Result<u32, String> {
        self.class_names.get(name).copied().ok_or_else(|| format!("unknown class {name}"))
    }

    /// Install programs in order, then build method dictionaries.
    pub unsafe fn load(&mut self, w: &mut Worker, programs: &[Program]) -> Result<(), String> {
        let mut installed: Vec<(u32, Oop, Oop)> = vec![];
        for p in programs {
            let mut new_classes = vec![];
            for cd in &p.classes {
                let idx = self.class_count as u32;
                if self.class_names.contains_key(&cd.name) {
                    return Err(format!("duplicate class {}", cd.name));
                }
                let c = self.alloc(w, CI_CLASS, CLASS_SLOTS, false);
                *self.class_table.add(idx as usize) = c;
                self.class_count += 1;
                self.class_names.insert(cd.name.clone(), idx);
                set_slot(c, C_INSTSIZE, mk_int(cd.inst_size as i64));
                set_slot(c, C_INDEX, mk_int(idx as i64));
                new_classes.push((c, cd));
            }
            for (c, cd) in new_classes {
                let sup = self.class_at(self.class_index(&cd.superclass)? as u64);
                set_slot(c, C_SUPER, sup);
            }
            for m in &p.methods {
                let cls = self.class_index(&m.class)?;
                let a = kasm::assemble(m)?;
                let sel = self.intern(w, &m.selector);
                for l in &a.literals {
                    if let Lit::Sym(s) = l {
                        self.intern(w, s);
                    }
                }
                let bc = self.alloc(w, CI_BYTEARRAY, a.bytecodes.len(), true);
                std::ptr::copy_nonoverlapping(a.bytecodes.as_ptr(), bytes_ptr(bc), a.bytecodes.len());
                let lits = self.alloc(w, CI_ARRAY, a.literals.len(), false);
                for (i, l) in a.literals.iter().enumerate() {
                    let v = match l {
                        Lit::Int(i) => {
                            if !fits_int(*i) {
                                return Err(format!("literal {i} out of range"));
                            }
                            mk_int(*i)
                        }
                        Lit::Sym(s) => self.symbols[s],
                        Lit::Class(c) => self.class_at(self.class_index(c)? as u64),
                        Lit::Nil => self.nil,
                        Lit::True => self.true_obj,
                        Lit::False => self.false_obj,
                    };
                    set_slot(lits, i, v);
                }
                let meth = self.alloc(w, CI_METHOD, METHOD_SLOTS, false);
                set_slot(meth, M_BYTECODES, bc);
                set_slot(meth, M_LITERALS, lits);
                set_slot(meth, M_ARGC, mk_int(a.argc as i64));
                set_slot(meth, M_NTEMPS, mk_int(m.temps as i64));
                set_slot(meth, M_MAXSTACK, mk_int(a.max_stack as i64));
                set_slot(meth, M_SELECTOR, sel);
                set_slot(meth, M_PRIM, mk_int(m.prim as i64));
                installed.push((cls, sel, meth));
            }
        }
        for idx in 1..self.class_count as u32 {
            let ms: Vec<_> = installed.iter().filter(|e| e.0 == idx).collect();
            if ms.is_empty() {
                continue;
            }
            let mut cap = 8;
            while cap < 2 * ms.len() {
                cap *= 2;
            }
            let dict = self.alloc(w, CI_METHODDICT, 2 * cap, false);
            for &&(_, sel, meth) in &ms {
                let mut i = ((sel >> 3) as usize) & (cap - 1);
                loop {
                    let k = slot(dict, 2 * i);
                    if k == self.nil || k == sel {
                        set_slot(dict, 2 * i, sel);
                        set_slot(dict, 2 * i + 1, meth);
                        break;
                    }
                    i = (i + 1) & (cap - 1);
                }
            }
            set_slot(self.class_at(idx as u64), C_DICT, dict);
        }
        Ok(())
    }

    /// Full method lookup along the superclass chain. Returns 0 if not found.
    pub unsafe fn lookup(&self, class_idx: u64, sel: Oop) -> Oop {
        let mut c = self.class_at(class_idx);
        while c != self.nil {
            let dict = slot(c, C_DICT);
            if dict != self.nil {
                let cap = hdr_slots(header(dict)) / 2;
                let mut i = ((sel >> 3) as usize) & (cap - 1);
                loop {
                    let k = slot(dict, 2 * i);
                    if k == sel {
                        return slot(dict, 2 * i + 1);
                    }
                    if k == self.nil {
                        break;
                    }
                    i = (i + 1) & (cap - 1);
                }
            }
            c = slot(c, C_SUPER);
        }
        0
    }

    /// Boot, load prelude + kernel sources, retire the boot TLAB.
    pub fn from_sources(sources: &[&str]) -> Result<Box<Vm>, String> {
        Self::from_sources_with_heap(sources, HEAP_SIZE)
    }

    pub fn from_sources_with_heap(sources: &[&str], heap_size: usize) -> Result<Box<Vm>, String> {
        let progs = sources.iter().map(|s| kasm::parse(s)).collect::<Result<Vec<_>, _>>()?;
        let (mut vm, mut w) = Vm::boot(heap_size);
        unsafe { vm.load(&mut w, &progs)? };
        vm.heap.retire(&mut w.tlab);
        Ok(vm)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lookup_walks_superclass_chain() {
        let vm = Vm::from_sources(&[
            "class A Object 0\nclass B A 1\nmethod A foo temps=0\n push_int 1\n return_top\nend\nmethod B bar temps=0\n return_self\nend\nmethod A bar temps=0\n return_self\nend\n",
        ])
        .unwrap();
        unsafe {
            let a = vm.class_index("A").unwrap() as u64;
            let b = vm.class_index("B").unwrap() as u64;
            assert_eq!(a, FIRST_USER_CLASS as u64);
            let foo = vm.symbols["foo"];
            let bar = vm.symbols["bar"];
            let a_foo = vm.lookup(a, foo);
            assert_ne!(a_foo, 0);
            assert_eq!(vm.lookup(b, foo), a_foo);
            let b_bar = vm.lookup(b, bar);
            assert_ne!(b_bar, vm.lookup(a, bar));
            assert_eq!(slot(b_bar, M_SELECTOR), bar);
            assert_eq!(vm.lookup(CI_SMALLINT as u64, foo), 0);
            assert_eq!(int_val(slot(vm.class_at(b), C_INSTSIZE)), 1);
        }
    }
}
