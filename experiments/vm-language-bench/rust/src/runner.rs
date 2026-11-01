//! Run a kernel on N worker threads and combine the results.

use crate::interp::execute;
use crate::object::*;
use crate::vm::{Vm, Worker};
use std::sync::atomic::Ordering;
use std::time::Instant;

pub struct RunResult {
    pub checksum: i64,
    pub results: Vec<i64>,
    pub ms: f64,
    pub gc_count: u64,
    pub gc_ms: f64,
    pub misses: u64,
}

struct SendPtr(*mut Worker);
unsafe impl Send for SendPtr {}

pub fn kernel_sources(dir: &str, kernel: &str) -> Result<Vec<String>, String> {
    ["prelude", kernel]
        .iter()
        .map(|k| std::fs::read_to_string(format!("{dir}/{k}.kasm")).map_err(|e| format!("{dir}/{k}.kasm: {e}")))
        .collect()
}

pub fn run(vm: &Vm, nworkers: usize) -> RunResult {
    let mut workers: Vec<Box<Worker>> = (0..nworkers).map(|i| Worker::new(i, vm.nil)).collect();
    let ptrs: Vec<*mut Worker> = workers.iter_mut().map(|w| &mut **w as *mut Worker).collect();
    vm.set_workers(&ptrs);
    let sel = vm.symbols["run:of:"];
    let t0 = Instant::now();
    let results: Vec<i64> = std::thread::scope(|s| {
        let handles: Vec<_> = ptrs
            .iter()
            .map(|&p| {
                let p = SendPtr(p);
                s.spawn(move || {
                    let p = p;
                    let w = unsafe { &mut *p.0 };
                    let r = unsafe { execute(vm, w, vm.nil, sel, &[mk_int(w.id as i64), mk_int(nworkers as i64)]) };
                    vm.worker_finished(w);
                    r
                })
            })
            .collect();
        handles
            .into_iter()
            .map(|h| {
                let r = h.join().unwrap();
                if !is_int(r) {
                    crate::vm::fatal("kernel returned a non-SmallInteger");
                }
                int_val(r)
            })
            .collect()
    });
    let ms = t0.elapsed().as_secs_f64() * 1e3;
    RunResult {
        checksum: results.iter().fold(0i64, |a, &b| a.wrapping_add(b)),
        results,
        ms,
        gc_count: vm.gc_count.load(Ordering::Relaxed),
        gc_ms: vm.gc_nanos.load(Ordering::Relaxed) as f64 / 1e6,
        misses: workers.iter().map(|w| w.misses).sum(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run_src(src: &str, n: usize) -> RunResult {
        let vm = Vm::from_sources(&[&std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/../kernels/prelude.kasm")).unwrap(), src]).unwrap();
        run(&vm, n)
    }

    #[test]
    fn small_programs_run() {
        let src = "method SmallInteger fib temps=0\n push_self\n push_int 2\n lt\n jump_if_false r\n push_self\n return_top\nr:\n push_self\n push_int 1\n sub\n send fib 0\n push_self\n push_int 2\n sub\n send fib 0\n add\n return_top\nend\nmethod UndefinedObject run:of: temps=0\n push_int 20\n send fib 0\n push_temp 0\n add\n return_top\nend\n";
        let r = run_src(src, 1);
        assert_eq!(r.checksum, 6765);
        let r = run_src(src, 4);
        assert_eq!(r.results, vec![6765, 6766, 6767, 6768]);
    }

    #[test]
    fn primitives_and_division() {
        let src = "class P Object 1\nmethod UndefinedObject run:of: temps=1\n push_lit @Array\n push_int 3\n send new: 1\n store_temp 2\n push_temp 2\n push_int 2\n push_int -7\n push_int 2\n send // 1\n send at:put: 2\n pop\n push_temp 2\n push_int 2\n send at: 1\n push_int -7\n push_int 2\n send \\\\ 1\n add\n push_lit @P\n send basicNew 0\n send class 0\n push_lit @P\n identical\n jump_if_false bad\n return_top\nbad:\n push_int 99\n return_top\nend\n";
        // -7 // 2 = -4, -7 \\ 2 = 1
        assert_eq!(run_src(src, 1).checksum, -3);
    }
}
