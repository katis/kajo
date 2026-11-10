#!/bin/zsh
# Module 11b (docs/modules/distribution.md): Kajo.dmg, built on the mini.
#
#   scripts/dist.sh <version>          the dmg of HEAD's tree (or of the tag
#                                      v<version> when it names HEAD)
#   scripts/dist.sh checkout <dir>     the working tree's checkout with its
#                                      Prebuilt/ into <dir> (just new-check's)
#
# Steps of a dmg build, each timed in <out>/dist.log:
#   1. the checkout: `git archive` of the commit (no .git, no experiments/,
#      no references/, no fuzz seeds) as Kajo-<version>/
#   2. Prebuilt/bin/kajo: `swift build -c release` of the checkout's CLI
#   3. Prebuilt/*.xcframework: one static framework per module a generated
#      app links (KajoVM, KajoApp, KajoAppDevelopment, KajoDev), macOS arm64,
#      iOS arm64 and (since the simulator-slices follow-up,
#      docs/modules/simulator-slices.md) iOS Simulator arm64, built by
#      xcodebuild from scripts/dist-frameworks.yml
#      over the checkout's sources (-O, whole module, strict memory safety,
#      library evolution), and Prebuilt/Package.swift naming them
#   4. the Kajo app: xcodebuild Release of the checkout's apps/KajoShell-macOS
#      with MARKETING_VERSION=<version> and only the development image;
#      Contents/Helpers/kajo (the CLI), Contents/Resources/xcodegen (New
#      App's project maker), Contents/Resources/Kajo-<version> (the checkout the
#      app copies to Application Support)
#   5. signing, inside out, hardened runtime: KAJO_SIGN_IDENTITY, or the
#      first Developer ID Application identity in the keychain; without one
#      the Apple Development identity signs a local build and the dmg is
#      named Kajo-<version>-unsigned-dev.dmg (not for distribution)
#   6. the dmg (hdiutil: the app, Kajo-<version> beside it as a link into
#      the app, Applications, README.txt), signed, and its SHA-256
#   7. notarization when KAJO_NOTARY_PROFILE names a notarytool keychain
#      profile (the app, stapled, then the dmg, stapled); skipped with one
#      line otherwise. The script never reads a secret itself.
#   8. checks: codesign --verify, codesign -dvvv, spctl on the app and the
#      dmg as built and on a quarantined copy, the bundled kajo running the
#      kernel's tests, and the size of every part
#
# KAJO_DIST_OUT is the output directory (default .build/dist/<version>);
# KAJO_DIST_WORKTREE=1 exports the working tree, dirty or not, instead of
# the commit (for trying the script; never for a release). Every wait is
# bounded; nothing here writes outside the output directory.
set -uo pipefail
root=${0:A:h:h}
excluded='^(experiments|references|Tests/KajoVMTests/Fixtures/fuzz)(/|$)'

log() { print -r -- "$(date '+%F %T') $*" | tee -a $logfile }
step_t0=0
step() { step_t0=$(date +%s); log "step $1" }
done_step() { log "done $1 $(( $(date +%s) - step_t0 )) s" }
die() { log "FAILED $*"; exit 1 }

# The tree to ship, into $1: the commit's (git archive) or the working
# tree's files (tracked and untracked, not ignored), minus $excluded.
export_tree() {
  local dest=$1 rev=${2:-HEAD}
  mkdir -p $dest
  if [[ ${KAJO_DIST_WORKTREE:-0} == 1 || $rev == worktree ]]; then
    (cd $root && git ls-files -co --exclude-standard --deduplicate | grep -vE $excluded | while IFS= read -r f; do [[ -e $f ]] && print -r -- $f; done) > $dest.files
    tar -C $root -cf - -T $dest.files | tar -C $dest -xf - || return 1
    rm -f $dest.files
  else
    git -C $root archive --format=tar $rev | tar -C $dest -xf - || return 1
    rm -rf $dest/experiments $dest/references $dest/Tests/KajoVMTests/Fixtures/fuzz
  fi
}

# The Release CLI of checkout $1 into $1/Prebuilt/bin/kajo.
build_cli() {
  local ck=$1 work=$2
  mkdir -p $ck/Prebuilt/bin
  gtimeout 3600 swift build -c release --package-path $ck --scratch-path $work/cli --product kajo > $work/cli.log 2>&1 \
    || { tail -20 $work/cli.log; return 1; }
  cp $(swift build -c release --package-path $ck --scratch-path $work/cli --product kajo --show-bin-path)/kajo $ck/Prebuilt/bin/kajo
}

# The frameworks of checkout $1 into $1/Prebuilt, and its manifest.
build_frameworks() {
  local ck=$1 work=$2 fw=$2/fw p m line flags t0 rc errors warnings args
  rm -rf $fw && mkdir -p $fw
  sed "s|__SRC__|$ck/Sources|g" $root/scripts/dist-frameworks.yml > $fw/project.yml
  (cd $fw && xcodegen generate --quiet) || return 1
  # One build per slice: the destination's platform name, the log's tag and
  # the products directory's suffix. arm64 only: every Mac Kajo runs on is
  # Apple silicon, the simulator's included.
  local -A dest=(macOS macOS iOS iOS iOSSimulator 'iOS Simulator')
  local -A products=(macOS Release iOS Release-iphoneos iOSSimulator Release-iphonesimulator)
  local slices=(macOS iOS iOSSimulator)
  for p in $slices; do
    t0=$(date +%s)
    gtimeout 3600 xcodebuild build -project $fw/KajoFrameworks.xcodeproj -scheme KajoFrameworks -configuration Release \
      -destination "generic/platform=${dest[$p]}" -derivedDataPath $fw/dd ARCHS=arm64 ONLY_ACTIVE_ARCH=NO > $work/fw-$p.log 2>&1
    rc=$?
    errors=$(grep -cE "(^|: )error:" $work/fw-$p.log)
    warnings=$(grep -E "^/.*: warning:" $work/fw-$p.log | sort -u | wc -l | tr -d ' ')
    log "frameworks $p: exit=$rc errors=$errors warnings=$warnings seconds=$(( $(date +%s) - t0 ))"
    [[ $rc == 0 && $errors == 0 && $warnings == 0 ]] || { grep -E "^/.*: (warning|error):" $work/fw-$p.log | sort -u | head; return 1; }
  done
  # The flags the slices were compiled with, read from the compile lines.
  : > $work/flags.txt
  for p in $slices; do
    for m in KajoVM KajoApp KajoAppDevelopment KajoDev; do
      line=$(grep -m1 -E "swiftc -module-name $m .*-target arm64" $work/fw-$p.log)
      flags=$(print -r -- $line | tr ' ' '\n' | grep -E '^(-O|-Onone|-whole-module-optimization|-strict-memory-safety|-enable-library-evolution|-swift-version|6|-target|arm64-apple-.*|-D.*|-enable-testing|-g)$' | tr '\n' ' ')
      print "$p $m: $flags" >> $work/flags.txt
      # Asserted, not only recorded (the review fixes, part 2, item 12): a
      # product's build mode is read from its compile line.
      local words=" $flags"
      if [[ -z $line || $words != *" -O "* || $words != *" -whole-module-optimization "* || $words != *" -strict-memory-safety "* \
            || $words == *" -Onone "* || $words == *" -enable-testing "* || $words == *" -g "* ]]; then
        log "frameworks $p $m: FAILED the compile flags (${flags:-no compile line found}): -O -whole-module-optimization -strict-memory-safety wanted, no -Onone, -enable-testing or -g"
        return 1
      fi
    done
  done
  for m in KajoVM KajoApp KajoAppDevelopment KajoDev; do
    rm -rf $ck/Prebuilt/$m.xcframework
    args=()
    for p in $slices; do args+=(-framework $fw/dd/Build/Products/${products[$p]}/$m.framework); done
    xcodebuild -create-xcframework $args \
      -output $ck/Prebuilt/$m.xcframework > $work/xcf-$m.log 2>&1 || return 1
  done
  cat > $ck/Prebuilt/Package.swift <<'EOF'
// swift-tools-version: 6.2
// The prebuilt Kajo (module 11b, docs/modules/distribution.md): the Release
// build of every module a generated app links, one static framework each
// for macOS arm64, iOS arm64 and the iOS Simulator on arm64, made by
// scripts/dist.sh from this
// checkout's sources (FLAGS.txt). A generated project names this package as
// its one local package: KajoApp in both configurations, KajoAppDevelopment
// built for the compiler and linked by Debug alone.
import PackageDescription

let package = Package(
    name: "Kajo",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "KajoApp", targets: ["KajoApp", "KajoVM"]),
        .library(name: "KajoAppDevelopment", targets: ["KajoAppDevelopment", "KajoDev"]),
    ],
    targets: [
        .binaryTarget(name: "KajoVM", path: "KajoVM.xcframework"),
        .binaryTarget(name: "KajoApp", path: "KajoApp.xcframework"),
        .binaryTarget(name: "KajoDev", path: "KajoDev.xcframework"),
        .binaryTarget(name: "KajoAppDevelopment", path: "KajoAppDevelopment.xcframework"),
    ]
)
EOF
  {
    print "Kajo prebuilt frameworks (scripts/dist.sh, scripts/dist-frameworks.yml)"
    print "built $(date '+%F %T') by $(xcodebuild -version | tr '\n' ' ')"
    print "compiler $(xcrun swiftc --version 2>&1 | head -1)"
    print "per slice and module, the compile line's flags:"
    cat $work/flags.txt
    print "kajo: swift build -c release, $(swift --version 2>&1 | head -1)"
  } > $ck/Prebuilt/FLAGS.txt
}

if [[ ${1:-} == checkout ]]; then
  dest=${2:?checkout <dir>}
  rm -rf $dest && mkdir -p ${dest:h}
  work=$dest.work && rm -rf $work && mkdir -p $work
  logfile=$work/dist.log
  step export; export_tree $dest worktree || die "export"; done_step export
  step cli; build_cli $dest $work || die "the CLI did not build ($work/cli.log)"; done_step cli
  step frameworks; build_frameworks $dest $work || die "the frameworks did not build ($work)"; done_step frameworks
  log "checkout $dest"
  exit 0
fi

version=${1:?usage: dist.sh <version> | dist.sh checkout <dir>}
[[ $version =~ '^[0-9]+(\.[0-9]+)*$' ]] || { print "dist: a version is numbers and dots, e.g. 0.1"; exit 2 }
out=${KAJO_DIST_OUT:-$root/.build/dist/$version}
rm -rf $out && mkdir -p $out
logfile=$out/dist.log
work=$out/work stage=$out/stage
mkdir -p $work $stage
cd $root
head=$(git rev-parse HEAD)
rev=HEAD
if [[ ${KAJO_DIST_WORKTREE:-0} == 1 ]]; then
  log "dist $version from the working tree at $(git rev-parse --short HEAD)$([[ -n $(git status --porcelain) ]] && print ' (dirty)') -- not for a release"
else
  [[ -z $(git status --porcelain) ]] || die "the tree is dirty; commit first (or KAJO_DIST_WORKTREE=1 to try the script)"
  if git rev-parse -q --verify "refs/tags/v$version" > /dev/null; then
    [[ $(git rev-parse "v$version^{commit}") == $head ]] || die "tag v$version is not HEAD"
    rev=v$version
  fi
  log "dist $version from $rev ($head)"
fi
log "toolchain: $(swift --version 2>&1 | head -1); $(xcodebuild -version | tr '\n' ' ')"

# The identity: KAJO_SIGN_IDENTITY, the first Developer ID Application one,
# or (a local build) the Apple Development one.
ids=$(security find-identity -v -p codesigning 2>/dev/null)
identity=${KAJO_SIGN_IDENTITY:-}
if [[ -z $identity ]]; then
  identity=$(print -r -- $ids | sed -nE 's/.*"(Developer ID Application: [^"]*)".*/\1/p' | head -1)
fi
distribution=1
if [[ -z $identity ]]; then
  identity=$(print -r -- $ids | sed -nE 's/.*"(Apple Development: [^"]*)".*/\1/p' | head -1)
  distribution=0
  log "signing: no Developer ID Application identity in the keychain; a local build signed by '$identity', not for distribution"
fi
[[ $identity == "Developer ID Application:"* ]] || distribution=0
[[ -n $identity ]] || die "no code-signing identity at all"
log "signing identity: $identity (distribution=$distribution)"
dmgname=Kajo-$version$([[ $distribution == 0 ]] && print -- -unsigned-dev).dmg

ck=$work/Kajo-$version
step export; export_tree $ck $rev || die "export"; done_step export
step cli; build_cli $ck $work || die "the CLI did not build ($work/cli.log)"; done_step cli
cli=$ck/Prebuilt/bin/kajo
step frameworks; build_frameworks $ck $work || die "the frameworks did not build ($work)"; done_step frameworks

step app
t0=$(date +%s)
gtimeout 3600 xcodebuild -project $ck/apps/KajoShell-macOS/KajoShell-macOS.xcodeproj -scheme Kajo -configuration Release \
  -derivedDataPath $work/appdd MARKETING_VERSION=$version KAJO_APP_IMAGES=product KAJO=$cli CODE_SIGN_IDENTITY=- build > $work/app.log 2>&1
rc=$?
errors=$(grep -cE "(^|: )error:" $work/app.log); warnings=$(grep -E "^/.*: warning:" $work/app.log | sort -u | wc -l | tr -d ' ')
log "app: exit=$rc errors=$errors warnings=$warnings seconds=$(( $(date +%s) - t0 ))"
[[ $rc == 0 && $errors == 0 ]] || die "the app did not build ($work/app.log)"
app=$stage/Kajo.app
ditto $work/appdd/Build/Products/Release/Kajo.app $app
mkdir -p $app/Contents/Helpers
cp $cli $app/Contents/Helpers/kajo
xg=$(readlink -f $(command -v xcodegen)); xgroot=${xg:h:h}
# In Resources, not Helpers: xcodegen reads its presets from ../share beside
# its bin/, and data files in a code directory are refused by codesign.
mkdir -p $app/Contents/Resources/xcodegen/bin $app/Contents/Resources/xcodegen/share/xcodegen
cp $xg $app/Contents/Resources/xcodegen/bin/xcodegen
cp -R $xgroot/share/xcodegen/SettingPresets $app/Contents/Resources/xcodegen/share/xcodegen/
cp $xgroot/LICENSE $app/Contents/Resources/xcodegen-LICENSE
print "xcodegen $(xcodegen --version 2>&1 | tail -1) (MIT, LICENSE in Resources/xcodegen-LICENSE)" > $app/Contents/Resources/xcodegen-VERSION
ditto $ck $app/Contents/Resources/Kajo-$version
plutil -extract CFBundleShortVersionString raw $app/Contents/Info.plist | grep -qx $version || die "the app's version is not $version"
done_step app

step sign
# Inside out: every Mach-O and framework bundle first, the app last. The
# hardened runtime on every executable; no entitlement is needed (no JIT, no
# unsigned memory, no library validation exception: the app loads nothing
# but its own code; serving needs none outside the App Sandbox).
ts=(--timestamp=none)
[[ $distribution == 1 ]] && ts=(--timestamp)
sign() { gtimeout 120 codesign --force --sign "$identity" $ts "$@" >> $work/sign.log 2>&1 || { tail -5 $work/sign.log; die "codesign $*"; } }
inner=$app/Contents/Resources/Kajo-$version/Prebuilt
sign --options runtime $inner/bin/kajo
for x in $inner/*.xcframework; do sign $x; done
sign --options runtime $app/Contents/Resources/xcodegen/bin/xcodegen
sign --options runtime $app/Contents/Helpers/kajo
sign --options runtime $app
gtimeout 300 codesign --verify --deep --strict --verbose=2 $app > $out/codesign-verify.txt 2>&1 && log "codesign --verify --deep --strict: ok" || die "codesign --verify ($out/codesign-verify.txt)"
done_step sign

step notarize-app
if [[ -z ${KAJO_NOTARY_PROFILE:-} ]]; then
  log "notarization skipped: KAJO_NOTARY_PROFILE is not set (a notarytool keychain profile name, the owner's: xcrun notarytool store-credentials)"
  notarize=0
elif ! gtimeout 60 xcrun notarytool history --keychain-profile $KAJO_NOTARY_PROFILE > /dev/null 2>&1; then
  log "notarization skipped: no notarytool keychain profile named $KAJO_NOTARY_PROFILE"
  notarize=0
elif [[ $distribution == 0 ]]; then
  log "notarization skipped: not signed with a Developer ID Application identity"
  notarize=0
else
  notarize=1
  ditto -c -k --keepParent $app $work/Kajo-app.zip
  gtimeout 3600 xcrun notarytool submit $work/Kajo-app.zip --keychain-profile $KAJO_NOTARY_PROFILE --wait > $out/notary-app.txt 2>&1 \
    && grep -q "status: Accepted" $out/notary-app.txt || die "the app was not notarized ($out/notary-app.txt)"
  gtimeout 300 xcrun stapler staple $app > $out/staple-app.txt 2>&1 || die "stapler staple (app)"
fi
done_step notarize-app

step dmg
ln -s /Applications $stage/Applications
ln -s Kajo.app/Contents/Resources/Kajo-$version $stage/Kajo-$version
cat > $stage/README.txt <<EOF
Kajo $version

Drag Kajo to Applications and open it. On its first launch it copies the
Kajo checkout it carries (Kajo-$version, here beside it: the sources, the
kernel, the tools and the prebuilt Kajo frameworks) to
~/Library/Application Support/Kajo/$version/ and opens the tools on its
development image. File > New App... makes a Kajo app project (a Mac and
an iPhone and iPad target over one directory of Smalltalk) that builds in
Xcode with nothing more to install, and opens it in Xcode.

File > Install Command Line Tool... links kajo (kajo new, kajo eval,
kajo mcp, ...) into /usr/local/bin. Without it, the tool is
/Applications/Kajo.app/Contents/Helpers/kajo.

Versions sit side by side: each has its own folder in Application Support.
Apple silicon Macs, macOS 15 or later; Xcode for building apps.
EOF
rm -f $out/$dmgname
gtimeout 900 hdiutil create -volname "Kajo $version" -srcfolder $stage -format UDZO -fs HFS+ -ov $out/$dmgname > $work/hdiutil.log 2>&1 || die "hdiutil create ($work/hdiutil.log)"
sign $out/$dmgname
done_step dmg

step notarize-dmg
if [[ $notarize == 1 ]]; then
  gtimeout 3600 xcrun notarytool submit $out/$dmgname --keychain-profile $KAJO_NOTARY_PROFILE --wait > $out/notary-dmg.txt 2>&1 \
    && grep -q "status: Accepted" $out/notary-dmg.txt || die "the dmg was not notarized ($out/notary-dmg.txt)"
  gtimeout 300 xcrun stapler staple $out/$dmgname > $out/staple-dmg.txt 2>&1 || die "stapler staple (dmg)"
else
  log "notarization of the dmg skipped (as the app's)"
fi
(cd $out && shasum -a 256 $dmgname > $dmgname.sha256)
log "dmg $out/$dmgname $(stat -f %z $out/$dmgname) bytes, sha256 $(cut -d' ' -f1 $out/$dmgname.sha256)"
done_step notarize-dmg

step checks
codesign -dvvv $app > $out/codesign-app.txt 2>&1
codesign -dvvv $app/Contents/Helpers/kajo > $out/codesign-kajo.txt 2>&1
codesign -dvvv $out/$dmgname > $out/codesign-dmg.txt 2>&1
for x in $inner/*.xcframework; do print "== ${x:t}"; codesign -dvv $x 2>&1; done > $out/codesign-xcframeworks.txt
spctl_app=$(spctl --assess --type execute -vv $app 2>&1); print -r -- $spctl_app > $out/spctl-app.txt
spctl_dmg=$(spctl --assess --type open --context context:primary-signature -vv $out/$dmgname 2>&1); print -r -- $spctl_dmg > $out/spctl-dmg.txt
log "spctl app: $(print -r -- $spctl_app | tr '\n' ' ')"
log "spctl dmg: $(print -r -- $spctl_dmg | tr '\n' ' ')"
# As downloaded: a copy with the quarantine attribute a browser sets, its
# volume mounted read-only, the app on it assessed (the mini stands in for a
# Mac that did not build it).
q=$work/quarantine && mkdir -p $q
cp $out/$dmgname $q/
xattr -w com.apple.quarantine "0083;$(printf %x $(date +%s));Safari;" $q/$dmgname
mnt=$q/mnt && mkdir -p $mnt
spctl --assess --type open --context context:primary-signature -vv $q/$dmgname > $out/spctl-dmg-quarantined.txt 2>&1
if gtimeout 120 hdiutil attach -nobrowse -readonly -mountpoint $mnt $q/$dmgname > $work/attach.log 2>&1; then
  spctl --assess --type execute -vv $mnt/Kajo.app > $out/spctl-app-quarantined.txt 2>&1
  xattr -p com.apple.quarantine $mnt/Kajo.app >> $out/spctl-app-quarantined.txt 2>&1
  gtimeout 120 hdiutil detach $mnt > /dev/null 2>&1 || gtimeout 120 hdiutil detach -force $mnt > /dev/null 2>&1
fi
log "spctl dmg, quarantined: $(tr '\n' ' ' < $out/spctl-dmg-quarantined.txt)"
log "spctl app on the quarantined dmg: $(tr '\n' ' ' < $out/spctl-app-quarantined.txt 2>/dev/null)"
# The bundled kajo runs the kernel's tests on an image it builds from the
# bundled checkout.
k=$app/Contents/Helpers/kajo
gtimeout 600 $k build-image -o $work/kernel.img $app/Contents/Resources/Kajo-$version/kernel > $out/kajo-test.txt 2>&1 \
  && gtimeout 900 $k test $work/kernel.img > $work/kajo-test-events.ndjson 2>> $out/kajo-test.txt
rc=$?
log "bundled kajo test: exit=$rc $(tail -1 $out/kajo-test.txt)"
# Sizes.
{
  print "part bytes"
  print "dmg $(stat -f %z $out/$dmgname)"
  print "Kajo.app $(du -sk $app | cut -f1)KiB"
  print "Kajo.app/Contents/MacOS/Kajo $(stat -f %z $app/Contents/MacOS/Kajo)"
  print "Kajo.app/Contents/Helpers/kajo $(stat -f %z $app/Contents/Helpers/kajo)"
  print "Kajo.app/Contents/Resources/xcodegen $(du -sk $app/Contents/Resources/xcodegen | cut -f1)KiB"
  print "Kajo.app/Contents/Resources/kajo/dev.img $(stat -f %z $app/Contents/Resources/kajo/dev.img)"
  print "Kajo-$version (the checkout) $(du -sk $app/Contents/Resources/Kajo-$version | cut -f1)KiB"
  print "Kajo-$version without Prebuilt $(( $(du -sk $app/Contents/Resources/Kajo-$version | cut -f1) - $(du -sk $inner | cut -f1) ))KiB"
  print "Prebuilt $(du -sk $inner | cut -f1)KiB"
  for x in $inner/*.xcframework; do
    print "${x:t} $(du -sk $x | cut -f1)KiB"
    for s in ios-arm64 ios-arm64-simulator macos-arm64; do print "  ${x:t:r}/$s $(stat -L -f %z $x/$s/${x:t:r}.framework/${x:t:r})"; done
  done
  print "Prebuilt/bin/kajo $(stat -f %z $inner/bin/kajo)"
} > $out/sizes.txt
cat $out/sizes.txt >> $logfile
done_step checks
log "dist done: $out/$dmgname"
