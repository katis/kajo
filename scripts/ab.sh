#!/bin/zsh
# The aligned A/B of the core tier (docs/modules/gate-tiers.md, AGENTS.md:
# build both binaries with -align-all-nofallthru-blocks=5 -align-loops=32):
# the base commit (exported with `git archive`, the working tree untouched)
# against the working tree, both `-c release -Xswiftc -enable-testing`
# aligned builds of `kajo`, RUNS runs interleaved over the kasm kernels and
# the Smalltalk kernels at 1 and 8 workers with --slice-ms 0, raw lines in
# <out>/bench.txt and the table (median and range, ratio, cycles and
# instructions per send, checksums) on stdout and in <out>/table.md.
#
#   scripts/ab.sh <base> <outdir>        (RUNS 5, KERNELS, WORKERS override)
#
# Exit status 1 when a build fails or a checksum differs between the sides.
set -uo pipefail
root=${0:A:h:h}
base=${1:?<base commit> <outdir>}
out=${2:?<base commit> <outdir>}
RUNS=${RUNS:-5}
KERNELS=(${=KERNELS:-alloc arith fib ivars sends storeheavy st-closures st-ivars st-sends})
WORKERS=(${=WORKERS:-1 8})
F=(-c release -Xswiftc -enable-testing -Xswiftc -Xllvm -Xswiftc -align-all-nofallthru-blocks=5 -Xswiftc -Xllvm -Xswiftc -align-loops=32 --product kajo)
mkdir -p $out
src=$out/base-src
rm -rf $src && mkdir -p $src
git -C $root archive $base | tar -x -C $src || { print "ab: cannot export $base"; exit 1 }
(cd $src && gtimeout 3600 swift build $F --scratch-path $out/base-build > $out/base-build.log 2>&1) || { print "ab: base build failed ($out/base-build.log)"; exit 1 }
(cd $root && gtimeout 3600 swift build $F --scratch-path $out/head-build > $out/head-build.log 2>&1) || { print "ab: head build failed ($out/head-build.log)"; exit 1 }
A=$out/base-build/release/kajo
B=$out/head-build/release/kajo
k=$root/Tests/KajoVMTests/Fixtures/kernels
mkdir -p $out/img-base $out/img-head
for n in sends ivars closures; do
  (cd $src && gtimeout 600 $A build-image -o $out/img-base/$n.img kernel Tests/KajoVMTests/Fixtures/smalltalk/$n > /dev/null) || print "ab: base image $n failed"
  (cd $root && gtimeout 600 $B build-image -o $out/img-head/$n.img kernel Tests/KajoVMTests/Fixtures/smalltalk/$n > /dev/null) || print "ab: head image $n failed"
done
raw=$out/bench.txt
print "# $(date '+%F %T') base $(git -C $root rev-parse --short $base) head $(git -C $root rev-parse --short HEAD)+wt load $(sysctl -n vm.loadavg)" >> $raw
for run in $(seq 1 $RUNS); do
  for w in $WORKERS; do
    for kern in $KERNELS; do
      for side in start head; do
        bin=$A img=$out/img-base; [[ $side == head ]] && { bin=$B; img=$out/img-head }
        if [[ $kern == st-* ]]; then
          line=$(gtimeout 300 $bin run $img/${kern#st-}.img --workers $w --slice-ms 0)
        else
          line=$(gtimeout 300 $bin run $k/prelude.kasm $k/lib.kasm $k/$kern.kasm --workers $w --slice-ms 0)
        fi
        f() { print -- "$line" | tr ' ' '\n' | sed -n "s/^$1=//p" }
        print "run=$run workers=$w kernel=$kern side=$side ms=$(f ms) checksum=$(f checksum) sends=$(f sends) cycles=$(f workerCycles) instructions=$(f workerInstructions)" >> $raw
      done
    done
  done
done
print "# $(date '+%F %T') end load $(sysctl -n vm.loadavg)" >> $raw
rm -rf $src
$root/scripts/ab-table.py $raw | tee $out/table.md
