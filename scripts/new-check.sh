#!/bin/zsh
# Module 11a's gate for the generated app project (`just new-check`): `kajo
# new` writes the Sample app into a scratch directory with this working
# tree's checkout as its Kajo (since module 11b: `scripts/dist.sh checkout`
# exports the tree and builds its Prebuilt/, the frameworks and kajo a
# project links and runs; KAJO_CHECKOUT names an existing checkout instead,
# such as the one the Kajo app copied from the dmg, and KAJO_NEW the kajo
# that runs `kajo new`), xcodegen makes the project, and xcodebuild builds both
# targets in both configurations from clean (the iOS target for a generic
# device without signing, as `just apps` does). Each build reads the exit
# status and the error count first, then the compiler warnings (0 or fail).
# Then the built products: a Release binary links no development protocol,
# no compiler and no shell modes (symbols and strings), its Info.plist names
# neither the Bonjour service nor the local network, and its image is a
# release image that refuses to serve; a Debug product has all three; both
# link the prebuilt VM (no KajoVM is compiled for the app, and the Debug
# product holds the prebuilt framework's symbols). The
# image build phase is timed first and incremental (nothing changed, then
# one source touched). The scratch project and its DerivedData are removed.
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
symbols() { for m in KajoDev KajoAppDevelopment KajoCompiler KajoShellCore; do print -n "$m=$(nm $1 2>/dev/null | grep -c "[0-9]$m") "; done }
strs() {
  for s in _kajo-dev._tcp kajo-pairing-token; do print -n "$s=$(strings -a $1 | grep -c -- $s) "; done
  print -n "DNSServiceRegister=$(nm -u $1 2>/dev/null | grep -c _DNSServiceRegister) "
}
plistkeys() { plutil -p $1 | grep -cE "NSBonjourServices|NSLocalNetworkUsageDescription" }
refuses() {
  local sock=$work/check-$$.sock
  gtimeout 20 $kajo run $1 --protocol $sock > $work/refuse.out 2>&1
  grep -q "elease image" $work/refuse.out && print 1 || print 0
}

check() {
  local tag=$1 bin=$2 plist=$3 img=$4 want=$5
  local sy=$(symbols $bin) st=$(strs $bin) pk=$(plistkeys $plist) rf=$(refuses $img)
  local bytes=$(stat -f %z $bin) imgbytes=$(stat -f %z $img)
  print "$tag: binary_bytes=$bytes image_bytes=$imgbytes ${sy}${st}plist_keys=$pk image_refuses_to_serve=$rf"
  if [[ $want == release ]]; then
    [[ $sy == *"KajoDev=0 KajoAppDevelopment=0 KajoCompiler=0 KajoShellCore=0 "* && $st == "_kajo-dev._tcp=0 kajo-pairing-token=0 DNSServiceRegister=0 " && $pk == 0 && $rf == 1 ]] \
      || { print "$tag: FAILED the release checks"; fail=1; }
  else
    [[ $sy != *"KajoDev=0 "* && $sy != *"KajoAppDevelopment=0 "* && $sy == *"KajoCompiler=0 KajoShellCore=0 "* && $st != *"DNSServiceRegister=0 "* && $pk == 2 && $rf == 0 ]] \
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
build Sample-macOS Release macos-release
mac=$DD/Build/Products/Release/Sample.app/Contents
check macos-release $mac/MacOS/Sample $mac/Info.plist $mac/Resources/kajo/app.img release
print "macos-release: app_bytes=$(du -sk $DD/Build/Products/Release/Sample.app | cut -f1)KiB"
build Sample-iOS Debug ios-debug -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO
ios=$DD/Build/Products/Debug-iphoneos/Sample.app
check ios-debug $ios/Sample.debug.dylib $ios/Info.plist $ios/kajo/app.img debug
build Sample-iOS Release ios-release -destination generic/platform=iOS CODE_SIGNING_ALLOWED=NO
ios=$DD/Build/Products/Release-iphoneos/Sample.app
check ios-release $ios/Sample $ios/Info.plist $ios/kajo/app.img release
print "ios-release: app_bytes=$(du -sk $ios | cut -f1)KiB"
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
