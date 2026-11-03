#!/bin/zsh
# The fixture kernels through `kajo run` (release, one worker) against the
# single-worker checksums published in experiments/vm-language-bench and
# experiments/object-representation RESULTS.md.
set -uo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product kajo >/dev/null || exit 2
kajo=$(swift build -c release --product kajo --show-bin-path)/kajo
k=Tests/KajoVMTests/Fixtures/kernels
fail=0
for pair in arith:372800000 fib:24682992 sends:1066666666666668 alloc:41950911 ivars:36383626 walk:9016009025388544 storeheavy:512000; do
  name=${pair%%:*} want=${pair#*:}
  line=$($kajo run $k/prelude.kasm $k/lib.kasm $k/$name.kasm --workers 1)
  got=$(print -- "$line" | tr ' ' '\n' | sed -n 's/^checksum=//p')
  ms=$(print -- "$line" | tr ' ' '\n' | sed -n 's/^ms=//p')
  if [[ $got == $want ]]; then printf '%-6s ok   %s  %8s ms\n' $name $got $ms
  else printf '%-6s FAIL got %s want %s\n' $name "$got" $want; fail=1; fi
done
exit $fail
