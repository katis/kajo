use kajo::runner;
use kajo::vm::Vm;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("usage: kajo-bench <arith|fib|sends|alloc> <workers> [kernels-dir]");
        std::process::exit(1);
    }
    let kernel = &args[1];
    let n: usize = args[2].parse().expect("workers");
    let dir = args.get(3).cloned().unwrap_or_else(|| concat!(env!("CARGO_MANIFEST_DIR"), "/../kernels").to_string());
    let srcs = runner::kernel_sources(&dir, kernel).unwrap_or_else(|e| {
        eprintln!("{e}");
        std::process::exit(1)
    });
    let refs: Vec<&str> = srcs.iter().map(|s| s.as_str()).collect();
    let mut vm = Vm::from_sources(&refs).unwrap_or_else(|e| {
        eprintln!("load error: {e}");
        std::process::exit(1)
    });
    vm.verbose_gc = std::env::var("KAJO_VERBOSE_GC").is_ok();
    let r = runner::run(&vm, n);
    println!(
        "lang=rust kernel={kernel} workers={n} ms={:.1} gc={} gc_ms={:.1} misses={} checksum={}",
        r.ms, r.gc_count, r.gc_ms, r.misses, r.checksum
    );
}
