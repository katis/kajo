#!/bin/zsh
# Release-build disassembly check: the object memory's allocation and store
# paths must contain no swift_retain / swift_release (AGENTS.md hot-path
# rules). Internal functions are dead-stripped from a plain release build
# (nothing public calls them yet), so this builds -O with -enable-testing,
# which keeps every internal function as an optimized symbol, and
# disassembles each function on the paths with relocations shown, so every
# call names its callee.
set -uo pipefail
cd "$(dirname "$0")/.."
swift build -c release -Xswiftc -enable-testing --scratch-path .build/release-testing >/dev/null || exit 2
objs=.build/release-testing/out/Intermediates.noindex/kajo.build/Release/KajoVM-t.build/Objects-normal/arm64
wanted=(
  'ObjectMemory.tryAllocate(_:classIndex:slots:fill:)'
  'ObjectMemory.tryAllocateBytes(_:classIndex:count:)'
  'ObjectMemory.allocate(_:header:bytes:fill:)'
  'ObjectMemory.place(_:header:bytes:fill:)'
  'ObjectMemory.allocateSlow(_:header:bytes:fill:)'
  'ObjectMemory.refillBlock(_:bytes:)'
  'ObjectMemory.refillEntries(_:)'
  'ObjectMemory.allocateBody(_:bytes:)'
  'ObjectMemory.retire(_:)'
  'ObjectMemory.store(_:_:_:)'
  'ObjectMemory.load(_:_:)'
  'ObjectMemory.storeByte(_:_:_:)'
  'ObjectMemory.loadByte(_:_:)'
  'ObjectMemory.lockPools()'
  'ObjectMemory.unlockPools()'
)
fail=0
found=0
for o in $objs/Allocation.o $objs/ObjectMemory.o; do
  syms=("${(@f)$(nm $o | awk '$2 == "T" {print $3}')}")
  names=("${(@f)$(print -l -- $syms | xcrun swift-demangle --simplified --compact)}")
  for i in {1..${#syms}}; do
    (( ${wanted[(Ie)${names[$i]}]} )) || continue
    found=$((found + 1))
    body=$(xcrun objdump -d -r --no-show-raw-insn --disassemble-symbols="${syms[$i]}" $o)
    n=$(print -- "$body" | grep -cE '^ +[0-9a-f]+:')
    arc=$(print -- "$body" | grep -cE 'swift_(retain|release|bridgeObjectRetain|bridgeObjectRelease|unknownObjectRetain|unknownObjectRelease)')
    calls=$(print -- "$body" | grep -E 'ARM64_RELOC_BRANCH26|R_AARCH64_CALL26' | awk '{print $NF}' | sort -u | xcrun swift-demangle --simplified --compact | tr '\n' ' ')
    printf '%-52s %4d insns  ARC %d  calls: %s\n' "${names[$i]}" "$n" "$arc" "${calls:-none}"
    (( arc == 0 )) || fail=1
  done
done
if (( found != ${#wanted} )); then echo "found $found of ${#wanted} functions"; exit 2; fi
(( fail == 0 )) && echo "OK: no retain or release on the allocation and store paths"
exit $fail
