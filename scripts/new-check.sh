#!/bin/zsh
# Module 11a's gate for the generated app project (`just new-check`): `kajo
# new` writes the Sample app into a scratch directory with this working
# tree's checkout as its Kajo (since module 11b: `scripts/dist.sh checkout`
# exports the tree and builds its Prebuilt/, the frameworks and kajo a
# project links and runs; KAJO_CHECKOUT names an existing checkout instead,
# such as the one the Kajo app copied from the dmg, and KAJO_NEW the kajo
# that runs `kajo new`), xcodegen makes the project, and xcodebuild builds both
# targets in both configurations from clean (the iOS target for a generic
# device without signing, as `just apps` does), and the iOS target's Debug
# configuration once more for a generic iOS Simulator. Each build reads the exit
# status and the error count first, then the compiler warnings (0 or fail).
# Then the built products: a Release binary links no development protocol,
# no compiler and no shell modes (symbols and strings), its Info.plist names
# neither the Bonjour service nor the local network, and its image is a
# release image that refuses to serve and holds no class of the type
# checker and no signature's text (Types 2); a Debug product has all of
# them; both
# link the prebuilt VM (no KajoVM is compiled for the app, and the Debug
# product holds the prebuilt framework's symbols). The
# image build phase is timed first and incremental (nothing changed, then
# one source touched). The scratch project and its DerivedData are removed.
# Since the native-by-default follow-up the plain Release builds carry the
# image's native module (the project's default) and each Release product is
# built again with KAJO_NATIVE=NO, the module's negative control.
#
#   scripts/new-check.sh [outdir]      (DD overrides the DerivedData root)
#   KAJO_CHECKOUT=<dir> scripts/new-check.sh [outdir]
#   APP_PROJECT=<dir> KAJO_CHECKOUT=<dir> scripts/new-check.sh [outdir]   (a project made elsewhere, checked as is)
set -uo pipefail
root=${0:A:h:h}
out=${1:-${TMPDIR:-/tmp}/kajo-new-check}
DD=${DD:-${TMPDIR:-/tmp}/kajo-new-check-dd}
mkdir -p $out
work=$(mktemp -d)
trap 'rm -rf $work $DD' EXIT
fail=0
if [[ -n ${KAJO_CHECKOUT:-} ]]; then
  ck=$KAJO_CHECKOUT
  print "new-check: the checkout $ck"
else
  ck=$work/kajo-checkout
  t0=$(date +%s)
  $root/scripts/dist.sh checkout $ck > $out/checkout.log 2>&1 || { tail -20 $out/checkout.log $ck.work/dist.log; print "new-check: the checkout did not build"; exit 1; }
  print "new-check: the working tree's checkout with its Prebuilt/ in $(( $(date +%s) - t0 )) s"
  cp $ck.work/dist.log $out/checkout-dist.log
  cp $ck/Prebuilt/FLAGS.txt $out/prebuilt-flags.txt
fi
if [[ -n ${KAJO_NEW:-} ]]; then
  kajo=$KAJO_NEW
else
  swift build --package-path $root --product kajo > $out/kajo-build.log 2>&1 || { print "new-check: kajo did not build"; exit 1; }
  kajo=$(swift build --package-path $root --product kajo --show-bin-path)/kajo
fi
if [[ -n ${APP_PROJECT:-} ]]; then
  # A project made elsewhere (the Kajo app's New App): a copy of it, so the
  # original keeps its own build state; its pin is an absolute path.
  [[ -d $APP_PROJECT/Sample.xcodeproj ]] || { print "new-check: no Sample.xcodeproj in $APP_PROJECT"; exit 1; }
  ditto $APP_PROJECT $work/Sample && rm -rf $work/Sample/.build
  print "new-check: the project $APP_PROJECT, pinned to $(sed -n 's/^    path: //p' $work/Sample/project.yml | head -1)"
else
  (cd $work && $kajo new Sample --bundle-id dev.katajamaki.kajo.sample --team BDN6M642M2 --kajo $ck) > $out/new.log 2>&1 \
    || { cat $out/new.log; print "new-check: kajo new failed"; exit 1; }
fi
proj=$work/Sample
[[ -f $proj/Sample.xcodeproj/project.pbxproj ]] || { cat $out/new.log; print "new-check: no Xcode project (is xcodegen on PATH?)"; exit 1; }

build() {
  local scheme=$1 config=$2 tag=$3; shift 3
  local log=$out/build-$tag.log t0=$(date +%s)
  gtimeout 3600 xcodebuild -project $proj/Sample.xcodeproj -scheme $scheme -configuration $config -derivedDataPath $DD "$@" build > $log 2>&1
  local rc=$? secs=$(( $(date +%s) - t0 ))
  local errors=$(grep -cE "(^|: )error:" $log)
  local warnings=$(grep -E "^/.*: warning:" $log | sort -u | wc -l | tr -d ' ')
  print "$tag: exit=$rc errors=$errors warnings=$warnings seconds=$secs"
  grep -E "^/.*: (warning|error):" $log | sort -u | head -20
  [[ $rc == 0 && $errors == 0 && $warnings == 0 ]] || fail=1
}

# The development objects and the shell and compiler modules, by mangled
# module name in the symbol table.
# KajoVM last, the positive control (the review fixes, part 2, item 12):
# every product links the VM, so a count of 0 there means the symbol table
# is gone (a stripped binary) and every 0 before it means nothing.
symbols() { for m in KajoDev KajoAppDevelopment KajoCompiler KajoShellCore KajoAOT KajoVM; do print -n "$m=$(nm $1 2>/dev/null | grep -c "[0-9]$m") "; done }
strs() {
  for s in _kajo-dev._tcp kajo-pairing-token; do print -n "$s=$(strings -a $1 | grep -c -- $s) "; done
  print -n "DNSServiceRegister=$(nm -u $1 2>/dev/null | grep -c _DNSServiceRegister) "
}
plistkeys() { plutil -p $1 | grep -cE "NSBonjourServices|NSLocalNetworkUsageDescription" }
# Types 2 (docs/modules/types-2.md): the type checker's classes and the
# kernel's signatures without a method (the type table's text) in an
# image's bytes: none in a Release image, both in a Debug one.
types() {
  print -n "checker_classes=$(LC_ALL=C grep -c -a -E 'TypeChecker|MethodTypeCheck' $1) "
  print -n "signature_text=$(LC_ALL=C grep -c -a -F 'bitXor: anInteger <Integer> ^<Integer>' $1) "
}
refuses() {
  local sock=$work/check-$$.sock
  gtimeout 20 $kajo run $1 --protocol $sock > $work/refuse.out 2>&1
  grep -q "elease image" $work/refuse.out && print 1 || print 0
}

check() {
  local tag=$1 bin=$2 plist=$3 img=$4 want=$5
  local sy=$(symbols $bin) st=$(strs $bin) pk=$(plistkeys $plist) rf=$(refuses $img) ty=$(types $img)
  local bytes=$(stat -f %z $bin) imgbytes=$(stat -f %z $img)
  print "$tag: binary_bytes=$bytes image_bytes=$imgbytes ${sy}${st}${ty}plist_keys=$pk image_refuses_to_serve=$rf"
  if [[ $want == release ]]; then
    [[ $sy == *"KajoDev=0 KajoAppDevelopment=0 KajoCompiler=0 KajoShellCore=0 KajoAOT=0 "* && $sy != *"KajoVM=0 "* && $st == "_kajo-dev._tcp=0 kajo-pairing-token=0 DNSServiceRegister=0 " && $ty == "checker_classes=0 signature_text=0 " && $pk == 0 && $rf == 1 ]] \
      || { print "$tag: FAILED the release checks"; fail=1; }
  else
    [[ $sy != *"KajoDev=0 "* && $sy != *"KajoAppDevelopment=0 "* && $sy == *"KajoCompiler=0 KajoShellCore=0 KajoAOT=0 "* && $st != *"DNSServiceRegister=0 "* && $ty != *"checker_classes=0 "* && $ty != *"signature_text=0 "* && $pk == 2 && $rf == 0 ]] \
      || { print "$tag: FAILED the debug checks"; fail=1; }
  fi
}

rm -rf $DD
build Sample-macOS Debug macos-debug
mac=$DD/Build/Products/Debug/Sample.app/Contents
# A Debug Mac build links the app into a debug dylib beside the stub.
check macos-debug $mac/MacOS/Sample.debug.dylib $mac/Info.plist $mac/Resources/kajo/app.img debug
# Module 11b: the Debug build's VM is the prebuilt Release one: no KajoVM
# (nor any other Kajo module) is compiled for the app, and the Debug
# product holds the prebuilt framework's code (by a symbol only KajoVM has).
compiled=$(grep -cE -- "-module-name (KajoVM|KajoApp|KajoAppDevelopment|KajoDev) " $out/build-macos-debug.log)
vmsyms=$(nm $mac/MacOS/Sample.debug.dylib 2>/dev/null | grep -c "6KajoVM")
print "macos-debug: kajo_modules_compiled=$compiled prebuilt_vm_symbols=$vmsyms"
[[ $compiled == 0 && $vmsyms -gt 1000 ]] || { print "macos-debug: FAILED the Debug VM is not the prebuilt one"; fail=1; }
# Incremental: nothing changed, then one source touched (the image is built
# again, nothing else).
build Sample-macOS Debug macos-debug-again
touch $proj/src/SampleApp.class.st
build Sample-macOS Debug macos-debug-touched
# The native-by-default follow-up (docs/modules/native-by-default.md): a
# project from `kajo new` has KAJO_NATIVE = YES, so the plain Release
# builds are the native ones. Each Release binary has the descriptor's
# section and no generator (KajoAOT) or development symbol; the Mac app is
# launched and must bind every method its module generated with 0 declined.
# The same products built with KAJO_NATIVE=NO on the xcodebuild line (the
# project is not generated again) are the off rows: no section, nothing
# under .build/kajo/native/<platform>/, their size beside the on one; each
# side is the other's control. The cache: an unchanged second build
# compiles nothing; a truncated library is rebuilt, never linked; a stale
# library (another layout hash, as after a Kajo update) is linked, refused
# at launch with its reason, and the app runs interpreted; a changed image
# builds a new library and the earlier ones go (one library per platform).
section() { otool -l $1 2>/dev/null | grep -c "sectname __kajo_native" }
launch() { # <binary> <out>: run the app until it prints its native line (bounded)
  ( gtimeout 30 $1 > $2 2>&1 & ); local i=0
  while (( i < 280 )) && ! grep -q '^native=' $2 2>/dev/null; do sleep 0.1; i=$((i + 1)); done
  sleep 0.5; pkill -f "^$1" 2>/dev/null; sleep 0.3
  grep -m1 '^native=' $2 || print "native=none"
}
generated() { grep -c 'native module: generating' $out/build-$1.log }
keys() { # the cached libraries' key directories
  local n=0 d
  for d in $proj/.build/kajo/native/*(N/); do [[ ${#${d:t}} == 24 ]] && n=$((n + 1)); done
  print $n
}
# off <platform dir>: whether .build/kajo/native/<platform>/ holds no file
nofiles() { [[ -z $(find $proj/.build/kajo/native/$1 -type f -o -type l 2>/dev/null) ]] && print 1 || print 0 }
bound() { # <tag> <native line>: bound at least generated, bound plus unbound the image's methods, 0 declined
  local nl=$2 n b u g dcl
  n=$(print -- $nl | sed -n 's/.* methods=\([0-9]*\).*/\1/p'); b=$(print -- $nl | sed -n 's/.* bound=\([0-9]*\).*/\1/p')
  u=$(print -- $nl | sed -n 's/.* unbound=\([0-9]*\).*/\1/p'); g=$(print -- $nl | sed -n 's/.* generated=\([0-9]*\).*/\1/p')
  dcl=$(print -- $nl | sed -n 's/.* declined=\([0-9]*\).*/\1/p')
  [[ $nl == native=bound* && -n $n && -n $g && $b -ge $g && $(( b + u )) == $n && $dcl == 0 ]] \
    || { print "$1: FAILED the bind (bound $b of $n, generated $g, declined $dcl)"; fail=1; }
}
macbin=$DD/Build/Products/Release/Sample.app/Contents/MacOS/Sample
build Sample-macOS Release macos-release
mac=$DD/Build/Products/Release/Sample.app/Contents
check macos-release $mac/MacOS/Sample $mac/Info.plist $mac/Resources/kajo/app.img release
onbytes=$(stat -f %z $macbin)
nl=$(launch $macbin $out/launch-native.txt)
print "macos-release: native_section=$(section $macbin) app_bytes=$(du -sk $DD/Build/Products/Release/Sample.app | cut -f1)KiB generated_in_build=$(generated macos-release) $nl"
[[ $(section $macbin) == 1 ]] || { print "macos-release: FAILED a plain Release binary has no module section"; fail=1; }
bound macos-release $nl
build Sample-macOS Release macos-release-again
again=$(generated macos-release-again)
print "macos-release-again: generated_in_build=$again"
[[ $again == 0 ]] || { print "macos-release-again: FAILED an unchanged build compiled the module again"; fail=1; }
nlib=$(readlink $proj/.build/kajo/native/macosx/libkajo_native.a)
# No library (a project with the module off): the rows below fail, and
# their files stay in the scratch directory.
[[ -n $nlib ]] || { nlib=$work/no-library/libkajo_native.a; mkdir -p ${nlib:h}; }
ndir=${nlib:h}
# A truncated library: its stamp no longer matches, so it is built again.
head -c 1000 $nlib > $nlib.cut && mv $nlib.cut $nlib
build Sample-macOS Release macos-release-truncated
nl=$(launch $macbin $out/launch-truncated.txt)
print "macos-release-truncated: generated_in_build=$(generated macos-release-truncated) $nl"
[[ $(generated macos-release-truncated) == 1 && $nl == native=bound* ]] \
  || { print "macos-release-truncated: FAILED a truncated library was not rebuilt"; fail=1; }
# A stale library: the same module with another layout hash, stamped as
# whole, as a library left by an earlier Kajo would be.
rm -rf $work/stale && mkdir -p $work/stale
$ck/Prebuilt/bin/kajo aot $proj/.build/kajo/app-release.img -o $work/stale/c > /dev/null
sed -i '' 's/FORMAT_VERSION, LAYOUT_HASH0, LAYOUT_HASH1/FORMAT_VERSION, LAYOUT_HASH0 ^ 1, LAYOUT_HASH1/' $work/stale/c/kajo_native_tables.c
(cd $work/stale/c && for f in kajo_native_*.c; do xcrun clang -O2 -target arm64-apple-macos15.0 -c $f -o $f.o || exit 1; done && libtool -static -o $nlib *.o) \
  && shasum -a 256 $nlib | cut -d' ' -f1 > $ndir/stamp
build Sample-macOS Release macos-release-stale
nl=$(launch $macbin $out/launch-stale.txt)
print "macos-release-stale: $nl"
[[ $nl == *"native=refused"*"layout hash"* ]] || { print "macos-release-stale: FAILED a stale module was not refused with its reason"; fail=1; }
# A changed image (the app's class comment edited): a new key, a new
# library linked and bound, and the earlier one (the stale) removed.
before=$(keys)
sed -i '' '1s/^"/"Changed by new-check. /' $proj/src/SampleApp.class.st
build Sample-macOS Release macos-release-changed
nl=$(launch $macbin $out/launch-changed.txt)
after=$(keys)
print "macos-release-changed: generated_in_build=$(generated macos-release-changed) keys_before=$before keys_after=$after old_key_left=$([[ -d $ndir ]] && print 1 || print 0) $(grep -m1 'libraries of earlier builds removed' $out/build-macos-release-changed.log) $nl"
[[ $(generated macos-release-changed) == 1 && $before == 1 && $after == 1 && ! -d $ndir ]] \
  || { print "macos-release-changed: FAILED a changed image left more than one library"; fail=1; }
bound macos-release-changed $nl
build Sample-macOS Release macos-release-off KAJO_NATIVE=NO
check macos-release-off $mac/MacOS/Sample $mac/Info.plist $mac/Resources/kajo/app.img release
print "macos-release-off: native_section=$(section $macbin) binary_bytes=$(stat -f %z $macbin) on_bytes=$onbytes no_files=$(nofiles macosx) app_bytes=$(du -sk $DD/Build/Products/Release/Sample.app | cut -f1)KiB"
[[ $(section $macbin) == 0 && $(nofiles macosx) == 1 ]] || { print "macos-release-off: FAILED a KAJO_NATIVE=NO build has the section or a library"; fail=1; }
build Sample-iOS Release ios-release -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO
ios=$DD/Build/Products/Release-iphoneos/Sample.app
check ios-release $ios/Sample $ios/Info.plist $ios/kajo/app.img release
ionbytes=$(stat -f %z $ios/Sample)
print "ios-release: native_section=$(section $ios/Sample) app_bytes=$(du -sk $ios | cut -f1)KiB generated_in_build=$(generated ios-release)"
[[ $(section $ios/Sample) == 1 ]] || { print "ios-release: FAILED no module section"; fail=1; }
build Sample-iOS Release ios-release-off -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO KAJO_NATIVE=NO
check ios-release-off $ios/Sample $ios/Info.plist $ios/kajo/app.img release
print "ios-release-off: native_section=$(section $ios/Sample) binary_bytes=$(stat -f %z $ios/Sample) on_bytes=$ionbytes no_files=$(nofiles iphoneos) app_bytes=$(du -sk $ios | cut -f1)KiB"
[[ $(section $ios/Sample) == 0 && $(nofiles iphoneos) == 1 ]] || { print "ios-release-off: FAILED a KAJO_NATIVE=NO build has the section or a library"; fail=1; }
build Sample-iOS Release ios-simulator-release -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
sim=$DD/Build/Products/Release-iphonesimulator/Sample.app
snbytes=$(stat -f %z $sim/Sample)
print "ios-simulator-release: native_section=$(section $sim/Sample) platform=$(vtool -show-build $sim/Sample 2>/dev/null | awk '/platform/ {print $2; exit}') binary_bytes=$snbytes generated_in_build=$(generated ios-simulator-release)"
[[ $(section $sim/Sample) == 1 ]] || { print "ios-simulator-release: FAILED no module section"; fail=1; }
build Sample-iOS Release ios-simulator-release-off -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO KAJO_NATIVE=NO
print "ios-simulator-release-off: native_section=$(section $sim/Sample) binary_bytes=$(stat -f %z $sim/Sample) on_bytes=$snbytes no_files=$(nofiles iphonesimulator)"
[[ $(section $sim/Sample) == 0 && $(nofiles iphonesimulator) == 1 ]] || { print "ios-simulator-release-off: FAILED a KAJO_NATIVE=NO build has the section or a library"; fail=1; }
# The image build phase alone: first (no kajo built for the project yet),
# again with nothing changed, and with one source touched.
phase() {
  local t0=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  $proj/scripts/build-images.sh $work/res $1 > $out/phase.log 2>&1 || { print -n FAILED; return; }
  perl -MTime::HiRes=time -e "printf \"%.2f\", time - $t0"
}
rm -rf $proj/.build
line="image-phase: first_debug_s=$(phase Debug) again_debug_s=$(phase Debug) first_release_s=$(phase Release)"
line+=" again_release_s=$(phase Release) $(touch $proj/src/SampleApp.class.st)touched_debug_s=$(phase Debug)"
print $line
[[ $line != *FAILED* ]] || fail=1
[[ $fail == 0 ]] && print "new-check: ok" || print "new-check: FAILED"
exit $fail
