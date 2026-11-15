# The project directory decided by the host

The project directory decided by the host, built 2026-11-11
(`docs/modules/project-directory.md`, the second review's `primitives.F7`;
nothing under `Sources/KajoVM`): the image named the client's project
directory as the fourth argument of primitive 164's `connect`, so Smalltalk
in a development image could make the host write and remove `.class.st` and
`.extension.st` files in any directory the user can write; now the host
holds one directory per target and the image names none:
`ClientHost.setProject(_:for:)` is the only way in (host code only; an
absolute path of at most 1024 bytes with no control character and no `.` or
`..` component that is an existing directory, a link to a directory checked
at its target and the path kept as given; every refusal a `ProjectRefusal`
value), keyed by the resolved address so a target's name, its address and
the local socket path are one entry and a Bonjour service is
`bonjour:<name>`; `connect` takes exactly three arguments (target, client,
package) and a fourth is refused, the connection takes its directory from
the host's table at connect time, and a target with none writes no file; two
new ops, `project <target>` (the directory or nil) and `chooseProject
<target>` (the host's own panel through a hook, `setDirectoryPrompt`; an
`NSOpenPanel` for directories on AppKit, nil on iOS and without a hook; the
choice goes through the same setter, a refused one answers its reason for
the panel to show, a `targets` event follows), and `targets` and `close`
refuse arguments; the hosts set it through one function (`setHostProjects`,
printing `project target=… dir=…` or `project=refused …`): `mode=dev
project=` and `mode=devsession` for their target, the product mode the
copied checkout's `tools/` for the local target plus the remembered choices
(`ProjectMemory`, `<support>/project-directories`, one `name<TAB>dir` line
each, read at start, a vanished directory dropped and never created, the
scripted modes remembering nothing), while `kajo run` and generated apps
have no client transport and the CLI's and MCP's `--project` (the Swift
client's writer) is unchanged; in the image `ClientTransport
class>>connect:client:package:`, `projectOf:` and `chooseProject:`,
`DevClient` and `DevTools` keeping no directory, the target picker a Project
column and a Project… toolbar item; on the starting commit 64db65e the
four-argument `connect` writes `Planted.class.st` into the directory the
image named and the kernel's and tools' new tests fail or do not understand;
on the Mac the round trip ran whole (`tools_change_written=1`,
`starts_with_change=1` by Bonjour name) and the scripted session's change
landed in the host-set directory; the hand-back's one unbaselined number, 58
frames of 273 missed in the scripted session, was baselined by the main
session: five interleaved launches a side at `classes=0`, 43 to 48 of 255 to
266 on 64db65e against 43 to 57 of 261 to 268 on the head, every miss in the
window-opening steps on both; `just check 64db65e` on 3f978e6, the Swift
tier, every gate in 5393 s (419 + 161 tests, ThreadSanitizer 0 reports in
4140 s, 249 kernel tests, apps, new-check, the protocol fuzzer with
"libFuzzer build: ok" at 360 541 runs) and the Smalltalk tier forced on the
same commit in 641 s (249 kernel, 292 tools-image and 161 compiler tests,
golden, the Mac shell's 249 of 249), the round trip byte-identical on both
code commits; not done: the devices (the iOS host has no panel), `mode=dev`
and the product mode do not browse Bonjour so a phone is chosen for by its
targets-file name or address, two spellings of one address are two entries,
no UI to clear a target's directory; its three questions answered by the
owner on 2026-11-11 as recommended and as built (the developer chooses from
the picker, the choice is remembered per target name across launches in the
product mode, a four-argument `connect` is refused).
