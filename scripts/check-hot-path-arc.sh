#!/bin/zsh
# Release-build disassembly checks (AGENTS.md hot-path rules):
#  1. no swift_retain / swift_release on the object memory's allocation and
#     store paths, the interpreter's dispatch loop, its send path and slow
#     paths, and the primitives (including the ones that allocate);
#     module 3's poll slow path, park, enter and leave, suspension and
#     resumption (runSlice) and the scheduler's queue operations;
#     module 4's barrier slow path, the eden allocation (inlined into
#     Machine.allocate) and the scavenge's copy, scan, packet and sweep loops;
#     module 5's barrier with the flag word (inlined into interpret and the
#     primitives), the SATB slow path and handover, the weak keep-alive, the
#     marker's trace loop and poll, the final mark's drain, the lazy sweep
#     and the apply;
#  2. the dispatch loop `interpret` is one jump table: one indirect branch
#     and one jump-table relocation.
# Internal functions are dead-stripped from a plain release build, so this
# builds -O with -enable-testing, which keeps every internal function as an
# optimized symbol, and disassembles each one with relocations shown, so
# every call names its callee. Private functions are local symbols (`t`).
set -uo pipefail
cd "$(dirname "$0")/.."
swift build -c release -Xswiftc -enable-testing --scratch-path .build/release-testing >/dev/null || exit 2
objs=.build/release-testing/out/Intermediates.noindex/kajo.build/Release/KajoVM-t.build/Objects-normal/arm64
typeset -A wanted
wanted=(
  Allocation 'ObjectMemory.tryAllocate(_:classIndex:slots:fill:)|ObjectMemory.tryAllocateBytes(_:classIndex:count:)|ObjectMemory.allocate(_:header:bytes:fill:)|ObjectMemory.place(_:header:bytes:fill:)|ObjectMemory.allocateSlow(_:header:bytes:fill:)|ObjectMemory.refillBlock(_:bytes:reserve:)|ObjectMemory.refillEntries(_:)|ObjectMemory.allocateBody(_:bytes:reserve:)|ObjectMemory.retire(_:)'
  ObjectMemory 'ObjectMemory.store(_:_:_:)|ObjectMemory.load(_:_:)|ObjectMemory.storeByte(_:_:_:)|ObjectMemory.loadByte(_:_:)|ObjectMemory.lockPools()|ObjectMemory.unlockPools()|ObjectMemory.bytesBase(_:)|ObjectMemory.slotsBase(_:)'
  Dispatch 'interpret(_:_:)'
  Send 'lookupMiss(_:_:_:)|pollAndSend(_:_:_:_:_:_:_:_:)|pollAtJump(_:_:_:_:_:)|specialSend(_:_:_:_:_:_:)|primitiveSend(_:_:_:_:_:_:_:_:)|bottomReturn(_:_:_:_:_:)|stackOverflow(_:_:_:_:_:_:_:)|failAt(_:_:_:_:_:_:_:_:_:)|doesNotUnderstand(_:_:_:_:_:_:_:_:)'
  Primitives 'primitive(_:_:_:)|primAt(_:_:)|primAtPut(_:_:)|primBasicNew(_:_:size:)|primDivide(_:modulo:)'
  InterpreterState 'Machine.allocate(_:slots:keeping:)|Machine.allocateBytes(_:count:)|Machine.fail(_:selector:receiverClass:primitive:)'
  Image 'lookupMethod(_:nilObject:classIndex:selector:)'
  Poll 'pollSlow(_:rewind:)|stopIfStressed(_:_:)'
  Safepoint 'park(_:_:)|enterVM(_:_:)|leaveVM(_:_:)'
  Scheduling 'requeueCurrent(_:_:sp:pc:affinity:result:reason:hop:)|suspendLocked(_:_:sp:pc:)|suspendAfterPrimitiveLocked(_:_:argc:result:)|finishSuspend(_:_:_:)|detachLocked(_:_:unconditionally:)|makeReadyLocked(_:_:_:fromBlocked:)|dequeueLocked(_:main:minPriority:for:)|waitSemaphore(_:_:_:argc:)|signalSemaphore(_:_:_:)|signalLocked(_:_:)|terminateCurrent(_:_:result:)'
  Run 'runSlice(_:_:_:)'
  External 'drainExternal(_:_:)'
  Generations 'ObjectMemory.promotionRefill(_:bytes:)'
  Barrier 'rememberSlow(_:_:_:_:)'
  Scavenge 'Scavenger.evacuate(_:_:)|Scavenger.drain()|Scavenger.scanRemembered(_:_:)|Scavenger.sweepNursery(_:)|Scavenger.exportPacket()|Scavenger.takePacket()|participateInScavenge(_:_:)'
  SATB 'storeWithBarriers(_:_:_:_:_:)|handOver(_:_:_:)|weakReadBarrier(_:_:_:_:)|takeBufferLocked(_:)'
  Marker 'markSome(_:_:limit:)|markerPoll(_:_:cycle:phase:)|drainStack(_:_:_:)|takeItem(_:_:_:_:)|popItem(_:)|returnBuffer(_:_:)'
  Sweep 'sweepCycle(_:_:inPause:)|applyInStop(_:_:)'
)
fail=0
found=0
total=0
for obj in ${(k)wanted}; do
  list=("${(@s:|:)wanted[$obj]}")
  total=$((total + ${#list}))
  o=$objs/$obj.o
  syms=("${(@f)$(nm $o | awk '$2 == "T" || $2 == "t" {print $3}')}")
  names=("${(@f)$(print -l -- $syms | xcrun swift-demangle --simplified --compact | sed 's/^specialized //')}")
  for i in {1..${#syms}}; do
    (( ${list[(Ie)${names[$i]}]} )) || continue
    found=$((found + 1))
    body=$(xcrun objdump -d -r --no-show-raw-insn --disassemble-symbols="${syms[$i]}" $o)
    n=$(print -- "$body" | grep -cE '^ +[0-9a-f]+:')
    arc=$(print -- "$body" | grep -cE 'swift_(retain|release|bridgeObjectRetain|bridgeObjectRelease|unknownObjectRetain|unknownObjectRelease)')
    calls=$(print -- "$body" | grep -E 'ARM64_RELOC_BRANCH26|R_AARCH64_CALL26' | awk '{print $NF}' | sort -u | xcrun swift-demangle --simplified --compact | tr '\n' ' ')
    printf '%-46s %5d insns  ARC %d  calls: %s\n' "${names[$i]}" "$n" "$arc" "${calls:-none}"
    (( arc == 0 )) || fail=1
    if [[ ${names[$i]} == 'interpret(_:_:)' ]]; then
      branches=$(print -- "$body" | grep -cE '	br	x[0-9]+')
      tables=$(print -- "$body" | grep -oE 'lJTI[0-9_]+' | sort -u | wc -l | tr -d ' ')
      printf '%-46s indirect branches %d, jump tables %d\n' "  dispatch" "$branches" "$tables"
      (( branches == 1 && tables == 1 )) || { echo "FAIL: the dispatch loop is not one jump table"; fail=1; }
    fi
  done
done
# a function may be emitted twice (a specialization beside the original): count names
if (( found < total )); then echo "found $found of $total functions"; exit 2; fi
(( fail == 0 )) && echo "OK: no retain or release on the checked paths; the dispatch loop is one jump table"
exit $fail
