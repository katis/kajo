//! .kasm parser and assembler (SPEC-SHARED.md ".kasm text format", "Bytecodes").
//! Produces heap-independent bytecode + literal lists; image.rs installs them.

use std::collections::HashMap;

pub const OP_PUSH_TEMP: u8 = 0x00;
pub const OP_PUSH_LIT: u8 = 0x01;
pub const OP_PUSH_SELF: u8 = 0x02;
pub const OP_PUSH_IVAR: u8 = 0x03;
pub const OP_STORE_TEMP: u8 = 0x04;
pub const OP_STORE_IVAR: u8 = 0x05;
pub const OP_POP: u8 = 0x06;
pub const OP_DUP: u8 = 0x07;
pub const OP_PUSH_NIL: u8 = 0x08;
pub const OP_PUSH_TRUE: u8 = 0x09;
pub const OP_PUSH_FALSE: u8 = 0x0A;
pub const OP_PUSH_INT: u8 = 0x0B;
pub const OP_SEND: u8 = 0x0C;
pub const OP_RETURN_TOP: u8 = 0x0D;
pub const OP_RETURN_SELF: u8 = 0x0E;
pub const OP_JUMP: u8 = 0x0F;
pub const OP_JUMP_IF_TRUE: u8 = 0x10;
pub const OP_JUMP_IF_FALSE: u8 = 0x11;
pub const OP_ADD: u8 = 0x12;
pub const OP_SUB: u8 = 0x13;
pub const OP_MUL: u8 = 0x14;
pub const OP_LT: u8 = 0x15;
pub const OP_GT: u8 = 0x16;
pub const OP_LE: u8 = 0x17;
pub const OP_GE: u8 = 0x18;
pub const OP_EQ: u8 = 0x19;
pub const OP_IDENTICAL: u8 = 0x1A;

/// Special selectors, in opcode order OP_ADD..OP_IDENTICAL.
pub const SPECIAL_SELECTORS: [&str; 9] = ["+", "-", "*", "<", ">", "<=", ">=", "=", "=="];

#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum Lit {
    Int(i64),
    Sym(String),
    Class(String),
    Nil,
    True,
    False,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Ins {
    Simple(u8),
    WithByte(u8, u8),
    PushInt(i8),
    PushLit(Lit),
    Send(String, u8),
    Jump(u8, String),
    Label(String),
}

#[derive(Clone, Debug, PartialEq)]
pub struct ClassDef {
    pub name: String,
    pub superclass: String,
    pub inst_size: usize,
}

#[derive(Clone, Debug, PartialEq)]
pub struct MethodDef {
    pub class: String,
    pub selector: String,
    pub temps: usize,
    pub prim: usize,
    pub code: Vec<Ins>,
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Program {
    pub classes: Vec<ClassDef>,
    pub methods: Vec<MethodDef>,
}

#[derive(Debug, PartialEq)]
pub struct Assembled {
    pub bytecodes: Vec<u8>,
    pub literals: Vec<Lit>,
    pub argc: usize,
    pub max_stack: usize,
}

pub fn selector_argc(sel: &str) -> usize {
    let first = sel.chars().next().unwrap_or('a');
    if !(first.is_ascii_alphabetic() || first == '_') {
        1
    } else {
        sel.matches(':').count()
    }
}

fn parse_kv(tok: &str, key: &str) -> Option<usize> {
    tok.strip_prefix(key)?.strip_prefix('=')?.parse().ok()
}

fn parse_lit(tok: &str) -> Result<Lit, String> {
    Ok(match tok {
        "nil" => Lit::Nil,
        "true" => Lit::True,
        "false" => Lit::False,
        _ if tok.starts_with('#') => Lit::Sym(tok[1..].to_string()),
        _ if tok.starts_with('@') => Lit::Class(tok[1..].to_string()),
        _ => Lit::Int(tok.parse().map_err(|_| format!("bad literal '{tok}'"))?),
    })
}

pub fn parse(src: &str) -> Result<Program, String> {
    let mut prog = Program::default();
    let mut cur: Option<MethodDef> = None;
    for (lineno, raw) in src.lines().enumerate() {
        let line = raw.split(';').next().unwrap().trim();
        if line.is_empty() {
            continue;
        }
        let err = |m: String| format!("line {}: {}", lineno + 1, m);
        let toks: Vec<&str> = line.split_whitespace().collect();
        if let Some(m) = cur.as_mut() {
            if toks[0] == "end" {
                prog.methods.push(cur.take().unwrap());
                continue;
            }
            if toks.len() == 1 && toks[0].ends_with(':') && toks[0].len() > 1 {
                m.code.push(Ins::Label(toks[0][..toks[0].len() - 1].to_string()));
                continue;
            }
            let operand = |i: usize| toks.get(i).copied().ok_or_else(|| err(format!("missing operand for {}", toks[0])));
            let byte = |i: usize| -> Result<u8, String> { operand(i)?.parse::<u8>().map_err(|_| err("bad u8 operand".into())) };
            let ins = match toks[0] {
                "push_temp" => Ins::WithByte(OP_PUSH_TEMP, byte(1)?),
                "push_ivar" => Ins::WithByte(OP_PUSH_IVAR, byte(1)?),
                "store_temp" => Ins::WithByte(OP_STORE_TEMP, byte(1)?),
                "store_ivar" => Ins::WithByte(OP_STORE_IVAR, byte(1)?),
                "push_lit" => Ins::PushLit(parse_lit(operand(1)?).map_err(err)?),
                "push_int" => Ins::PushInt(operand(1)?.parse::<i8>().map_err(|_| err("bad i8 operand".into()))?),
                "send" => {
                    let sel = operand(1)?.to_string();
                    let argc = byte(2)?;
                    if selector_argc(&sel) != argc as usize {
                        return Err(err(format!("argc mismatch for {sel}")));
                    }
                    Ins::Send(sel, argc)
                }
                "jump" => Ins::Jump(OP_JUMP, operand(1)?.to_string()),
                "jump_if_true" => Ins::Jump(OP_JUMP_IF_TRUE, operand(1)?.to_string()),
                "jump_if_false" => Ins::Jump(OP_JUMP_IF_FALSE, operand(1)?.to_string()),
                "push_self" => Ins::Simple(OP_PUSH_SELF),
                "pop" => Ins::Simple(OP_POP),
                "dup" => Ins::Simple(OP_DUP),
                "push_nil" => Ins::Simple(OP_PUSH_NIL),
                "push_true" => Ins::Simple(OP_PUSH_TRUE),
                "push_false" => Ins::Simple(OP_PUSH_FALSE),
                "return_top" => Ins::Simple(OP_RETURN_TOP),
                "return_self" => Ins::Simple(OP_RETURN_SELF),
                "add" => Ins::Simple(OP_ADD),
                "sub" => Ins::Simple(OP_SUB),
                "mul" => Ins::Simple(OP_MUL),
                "lt" => Ins::Simple(OP_LT),
                "gt" => Ins::Simple(OP_GT),
                "le" => Ins::Simple(OP_LE),
                "ge" => Ins::Simple(OP_GE),
                "eq" => Ins::Simple(OP_EQ),
                "identical" => Ins::Simple(OP_IDENTICAL),
                other => return Err(err(format!("unknown op '{other}'"))),
            };
            m.code.push(ins);
            continue;
        }
        match toks[0] {
            "class" => {
                if toks.len() != 4 {
                    return Err(err("class <Name> <Super> <instSize>".into()));
                }
                prog.classes.push(ClassDef {
                    name: toks[1].into(),
                    superclass: toks[2].into(),
                    inst_size: toks[3].parse().map_err(|_| err("bad instSize".into()))?,
                });
            }
            "method" => {
                if toks.len() < 3 {
                    return Err(err("method <Class> <selector> temps=n [prim=k]".into()));
                }
                let mut temps = 0;
                let mut prim = 0;
                for t in &toks[3..] {
                    if let Some(v) = parse_kv(t, "temps") {
                        temps = v;
                    } else if let Some(v) = parse_kv(t, "prim") {
                        prim = v;
                    } else {
                        return Err(err(format!("bad method attribute '{t}'")));
                    }
                }
                cur = Some(MethodDef { class: toks[1].into(), selector: toks[2].into(), temps, prim, code: vec![] });
            }
            other => return Err(err(format!("unexpected '{other}'"))),
        }
    }
    if cur.is_some() {
        return Err("unterminated method".into());
    }
    Ok(prog)
}

fn ins_size(ins: &Ins) -> usize {
    match ins {
        Ins::Label(_) => 0,
        Ins::Simple(_) => 1,
        Ins::WithByte(..) | Ins::PushInt(_) | Ins::PushLit(_) => 2,
        Ins::Send(..) | Ins::Jump(..) => 3,
    }
}

fn stack_effect(ins: &Ins) -> isize {
    match ins {
        Ins::Label(_) => 0,
        Ins::WithByte(op, _) => if *op == OP_PUSH_TEMP || *op == OP_PUSH_IVAR { 1 } else { -1 },
        Ins::PushInt(_) | Ins::PushLit(_) => 1,
        Ins::Send(_, argc) => -(*argc as isize),
        Ins::Jump(op, _) => if *op == OP_JUMP { 0 } else { -1 },
        Ins::Simple(op) => match *op {
            OP_PUSH_SELF | OP_DUP | OP_PUSH_NIL | OP_PUSH_TRUE | OP_PUSH_FALSE => 1,
            OP_POP => -1,
            OP_RETURN_TOP | OP_RETURN_SELF => 0,
            _ => -1, // binary specials
        },
    }
}

pub fn assemble(m: &MethodDef) -> Result<Assembled, String> {
    let mut labels = HashMap::new();
    let mut pos = 0;
    for ins in &m.code {
        if let Ins::Label(l) = ins {
            labels.insert(l.clone(), pos);
        }
        pos += ins_size(ins);
    }
    let mut literals: Vec<Lit> = vec![];
    let mut lit_index = |l: Lit| -> Result<u8, String> {
        let i = match literals.iter().position(|x| *x == l) {
            Some(i) => i,
            None => {
                literals.push(l);
                literals.len() - 1
            }
        };
        u8::try_from(i).map_err(|_| "too many literals".to_string())
    };
    let mut out = Vec::with_capacity(pos);
    let (mut depth, mut max_depth) = (0isize, 0isize);
    for ins in &m.code {
        match ins {
            Ins::Label(_) => {}
            Ins::Simple(op) => out.push(*op),
            Ins::WithByte(op, b) => out.extend([*op, *b]),
            Ins::PushInt(i) => out.extend([OP_PUSH_INT, *i as u8]),
            Ins::PushLit(l) => {
                let i = lit_index(l.clone())?;
                out.extend([OP_PUSH_LIT, i]);
            }
            Ins::Send(sel, argc) => {
                let i = lit_index(Lit::Sym(sel.clone()))?;
                out.extend([OP_SEND, i, *argc]);
            }
            Ins::Jump(op, label) => {
                let target = *labels.get(label).ok_or_else(|| format!("{}: unknown label {label}", m.selector))? as isize;
                let off = target - (out.len() as isize + 3);
                let off = i16::try_from(off).map_err(|_| "jump too far".to_string())?;
                let b = off.to_le_bytes();
                out.extend([*op, b[0], b[1]]);
            }
        }
        depth += stack_effect(ins);
        max_depth = max_depth.max(depth);
    }
    Ok(Assembled { bytecodes: out, literals, argc: selector_argc(&m.selector), max_stack: max_depth.max(1) as usize })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn argc_of_selectors() {
        assert_eq!(selector_argc("fib"), 0);
        assert_eq!(selector_argc("at:put:"), 2);
        assert_eq!(selector_argc("+"), 1);
        assert_eq!(selector_argc("\\\\"), 1);
        assert_eq!(selector_argc("run:of:"), 2);
    }

    #[test]
    fn parses_classes_and_methods() {
        let p = parse("class Foo Object 2 ; c\nmethod Foo bar: temps=1 \n push_temp 0\n return_top\nend\nmethod Object at: temps=0 prim=1\nend\n").unwrap();
        assert_eq!(p.classes, vec![ClassDef { name: "Foo".into(), superclass: "Object".into(), inst_size: 2 }]);
        assert_eq!(p.methods.len(), 2);
        assert_eq!(p.methods[0].temps, 1);
        assert_eq!(p.methods[1].prim, 1);
        assert!(p.methods[1].code.is_empty());
    }

    #[test]
    fn assembles_jumps_literals_and_sends() {
        let p = parse(
            "method Object m temps=0\nloop:\n push_lit 1000\n push_lit #foo\n push_lit 1000\n send at:put: 2\n jump_if_false loop\n push_int -1\n jump loop\nend\n",
        )
        .unwrap();
        let a = assemble(&p.methods[0]).unwrap();
        assert_eq!(a.literals, vec![Lit::Int(1000), Lit::Sym("foo".into()), Lit::Sym("at:put:".into())]);
        // offsets: 0 push_lit, 2 push_lit, 4 push_lit, 6 send, 9 jif(-12), 12 push_int, 14 jump(-17)
        assert_eq!(
            a.bytecodes,
            vec![1, 0, 1, 1, 1, 0, 0x0C, 2, 2, 0x11, 0xF4, 0xFF, 0x0B, 0xFF, 0x0F, 0xEF, 0xFF]
        );
        assert_eq!(a.max_stack, 3);
        assert_eq!(a.argc, 0);
    }

    #[test]
    fn rejects_argc_mismatch_and_unknown_ops() {
        assert!(parse("method Object m temps=0\n send at: 2\nend\n").is_err());
        assert!(parse("method Object m temps=0\n frob\nend\n").is_err());
    }

    #[test]
    fn kernels_assemble() {
        let dir = concat!(env!("CARGO_MANIFEST_DIR"), "/../kernels");
        for k in ["prelude", "arith", "fib", "sends", "alloc"] {
            let src = std::fs::read_to_string(format!("{dir}/{k}.kasm")).unwrap();
            let p = parse(&src).unwrap();
            for m in &p.methods {
                assemble(m).unwrap();
            }
        }
    }
}
