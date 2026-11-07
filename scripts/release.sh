#!/bin/zsh
# A release of the headless pieces, built on the mini (docs/modules/gate-tiers.md;
# no paid CI, nothing built on GitHub): the Release `kajo` CLI and the
# development image (kernel/ with tools/) it builds, in one tarball with
# its SHA-256, under .build/release-artifacts/<tag>/. It uploads nothing:
# it prints the `gh release create` command for the owner. The dmg,
# signing and notarization are the distribution module's.
#
#   scripts/release.sh <tag>
#
# The tag names a commit the tree is at (refused otherwise); a dirty tree
# is refused, so the tarball is what the tag says.
set -uo pipefail
root=${0:A:h:h}
tag=${1:?<tag>, e.g. v0.1.0}
[[ $tag =~ '^[A-Za-z0-9._-]+$' ]] || { print "release: a tag is letters, digits, '.', '_' and '-'"; exit 2 }
cd $root
[[ -z $(git status --porcelain) ]] || { print "release: the tree is dirty; commit or stash first"; exit 1 }
head=$(git rev-parse HEAD)
if git rev-parse -q --verify "refs/tags/$tag" > /dev/null; then
  [[ $(git rev-parse "$tag^{commit}") == $head ]] || { print "release: tag $tag is not HEAD"; exit 1 }
else
  print "release: no tag $tag yet; the command below creates it on the remote at $(git rev-parse --short HEAD) (--target)"
fi
out=$root/.build/release-artifacts/$tag
name=kajo-$tag-macos-$(uname -m)
rm -rf $out && mkdir -p $out/$name/bin
gtimeout 3600 swift build -c release --product kajo > $out/build.log 2>&1 || { print "release: build failed ($out/build.log)"; exit 1 }
bin=$(swift build -c release --product kajo --show-bin-path)/kajo
cp $bin $out/$name/bin/kajo
gtimeout 600 $out/$name/bin/kajo build-image -o $out/$name/dev.img --with tools > $out/image.log 2>&1 || { print "release: the development image did not build ($out/image.log)"; exit 1 }
{
  print "kajo $tag"
  print "commit $head"
  print "built $(date '+%F %T') on $(sysctl -n hw.model), $(swift --version 2>&1 | head -1)"
  print "bin/kajo      the headless CLI (kajo run, build-image, test, new, mcp, ...)"
  print "dev.img       the development image: kernel/ and tools/"
} > $out/$name/VERSION
tar -C $out -czf $out/$name.tar.gz $name
(cd $out && shasum -a 256 $name.tar.gz > $name.tar.gz.sha256)
print "release: $out/$name.tar.gz ($(stat -f %z $out/$name.tar.gz) bytes)"
cat $out/$name.tar.gz.sha256
print "\nTo publish (not run by this script):"
print "  gh release create $tag --target $head --title 'Kajo $tag' --notes-file <notes.md> \\"
print "    $out/$name.tar.gz $out/$name.tar.gz.sha256"
