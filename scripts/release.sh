#!/bin/zsh
# A Kajo release, built on the mini (module 11b, docs/modules/distribution.md;
# no paid CI, nothing built on GitHub): tag the commit v0.<n> (a local tag),
# run scripts/dist.sh for version 0.<n> (Kajo-0.<n>.dmg with its SHA-256,
# signed with the Developer ID identity and notarized when
# KAJO_NOTARY_PROFILE names the owner's notarytool profile), write release
# notes to fill in, and print the `gh release create` command. It uploads
# nothing and pushes nothing: the main session pushes the tag and runs the
# command.
#
#   scripts/release.sh v0.<n> [--dry-run]
#
# The tree must be clean and at the tag when the tag exists. --dry-run
# checks the same and prints what it would do (the tag, the dist command,
# the gh command), building and tagging nothing. A build that found no
# Developer ID identity makes Kajo-<version>-unsigned-dev.dmg; the script
# says it is not for distribution and prints no upload command for it.
set -uo pipefail
root=${0:A:h:h}
tag=${1:?usage: release.sh v0.<n> [--dry-run]}
dry=0; [[ ${2:-} == --dry-run ]] && dry=1
[[ $tag =~ '^v[0-9]+\.[0-9]+(\.[0-9]+)?$' ]] || { print "release: a tag is v<major>.<minor>, e.g. v0.1"; exit 2 }
version=${tag#v}
cd $root
[[ -z $(git status --porcelain) ]] || { print "release: the tree is dirty; commit first"; exit 1 }
head=$(git rev-parse HEAD)
made_tag=0
if git rev-parse -q --verify "refs/tags/$tag" > /dev/null; then
  [[ $(git rev-parse "$tag^{commit}") == $head ]] || { print "release: tag $tag is not HEAD"; exit 1 }
  print "release: $tag is HEAD ($(git rev-parse --short HEAD))"
elif [[ $dry == 1 ]]; then
  print "release: would tag $tag at $(git rev-parse --short HEAD) (git tag -a $tag -m 'Kajo $version')"
else
  git tag -a $tag -m "Kajo $version" || exit 1
  made_tag=1
  print "release: tagged $tag at $(git rev-parse --short HEAD) (local; push it with git push origin $tag)"
fi
out=${KAJO_DIST_OUT:-$root/.build/dist/$version}
if [[ $dry == 1 ]]; then
  print "release: would run KAJO_DIST_OUT=$out scripts/dist.sh $version"
  dmg=$out/Kajo-$version.dmg
else
  KAJO_DIST_OUT=$out $root/scripts/dist.sh $version || { print "release: dist failed ($out/dist.log)"; exit 1 }
  dmg=$(ls $out/Kajo-$version*.dmg | head -1)
fi
notes=$out/notes.md
if [[ $dry == 0 ]]; then
  {
    print "# Kajo $version"
    print
    print "Kajo-$version.dmg: the Kajo app (the tools on the development image, File > New App..., the kajo CLI),"
    print "the Kajo checkout of $tag ($head) and the prebuilt Kajo frameworks for macOS arm64 and iOS arm64."
    print "Apple silicon Macs, macOS 15 or later; Xcode for building apps. SHA-256 in Kajo-$version.dmg.sha256."
    print
    print "## First steps"
    print
    print "Open a Workspace (Tools > Workspace, ⌘K), type \`3 + 4\` and press ⌘P (Smalltalk > Print it): the answer"
    print "appears after the expression. ⌘D does it, ⌘I inspects it; the Smalltalk menu and a right-click in any"
    print "workspace or source pane list the rest, and Help > Keyboard Shortcuts lists every key. In Smalltalk"
    print "\`\"…\"\` is a comment and \`'…'\` a String."
    print
    print "## Changes"
    print
    print "(fill in)"
  } > $notes
fi
print
if [[ $dmg == *-unsigned-dev.dmg ]]; then
  print "release: $dmg is a local build signed for development, not for distribution (no Developer ID identity);"
  print "         no upload command. With the owner's certificate and notary profile:"
  print "  KAJO_NOTARY_PROFILE=<profile> scripts/release.sh $tag"
else
  print "To publish (not run by this script):"
  print "  git push origin $tag"
  print "  gh release create $tag $dmg $dmg.sha256 --title 'Kajo $version' --notes-file $notes --verify-tag"
fi
[[ $made_tag == 1 ]] && print "(the local tag $tag stays; git tag -d $tag removes it)"
exit 0
