# Module 9d: the phone transport, the device rows and the devices investigation

The phone transport built in module 9d, `docs/modules/phone-transport.md`:
`ProtocolServer` listens on TCP beside the Unix socket with one accept loop
and the same reader and token rule, `TCP_NODELAY` and keepalive, three wrong
tokens close a connection and ten failures in a minute pause the listener, a
Bonjour advertisement `_kajo-dev._tcp` through dns_sd whose TXT record names
the image and the versions and never the token, the iOS shell's
`protocol=tcp` with a pairing screen (token per install in Application
Support at 0600, a New token button that ends every session),
`TargetAddress` reading `/path`, `tcp://host:port` and `bonjour:<name>` for
`ClientHost`, the Swift client, the CLI, MCP and the targets file, phones
found by `NWBrowser` listed by `targets` with a `targets.changed` event,
`DevClient` reconnecting with 1, 2, 4 s backoff up to a minute and sending
again every request but `evaluate`, `process.evaluate`, `process.step` and
`test.run`, debuggers refreshing from `process.list`, 9c's scripted session
against another target (`mode=devsession target=`, `mode=serve`,
`scripts/remote-session.sh`) with define-and-retry and a dropped link as
steps; measured Mac to Mac because the iPhone build waited on a keychain
prompt the agent could not answer: TCP adds about 0.07 ms a request over the
Unix socket, round trips through the tools match the local ones, the first
Bonjour connect costs 0.3 to 0.4 s of resolution, define-and-retry across
the link 0.2 s, a dropped link is whole again in 1.05 to 1.09 s of which
1.006 s is the backoff, the serving shell missed 0 of 2400 frames idle and
ring with and without a client, bench within noise and `interpret`
identical; 9b's client closed a descriptor twice from `deinit` (fixed); the
phone's rows ran in part on 2026-11-06 (signing cleared by the owner): the
iPhone signs, serves over TCP and missed 0 of 2400 frames serving idle and
ring with no client (ring stopped for others 48 ms per 10 s, 4.1 W, thermal
nominal), but no client row ran on either device because the Mac session's
processes get "No route to host" to every LAN host but the router (macOS
Local Network privacy for the terminal's process tree, the owner's to allow;
the Mac-to-Mac run never left the Mac's own address so never met it) and the
phone's `_kajo-dev._tcp` never appeared in `dns-sd -B` (iOS's local-network
permission for the shell, the owner's to grant); the iPad (device family 1,2
since c2de63f) did not build because Xcode has no account for team
BDN6M642M2 and the team profile does not include it; two script bugs fixed
on the way (`device.sh token` copied onto a directory, so the token never
arrived; `remote-session.sh` took the phone's first address, the USB link's
169.254 one, instead of its address on the Mac's network); the kernel tests
on the iPhone and the Mac shell's tests mode failed 4 and 3 of 202 in
`ViewWrapperTest`, which assumed the headless host (fixed in 815b512 the
same night: `View class>>supports:`, 202 of 202 on all three hosts); the
rest ran on 2026-11-06 once the owner allowed Local Network on the mini and
signed the mini's Xcode in (5a180c2, `docs/modules/phone-transport.md` "On
the devices" and `docs/modules/shells.md`): the iPad Pro 12.9-inch 3rd
generation (A12X, iPadOS 26.7.2) passes 202 of 202 kernel tests in 7.1 s and
misses 0 of 1200 frames in every scenario at 5 workers, the main thread
stopped for others 475 / 54 / 53 ms per 10 s under the storm and 1244 / 101
/ 93 under the ring (stop-the-world / local / offload; the iPhone 464 / 43 /
48 and 1252 / 76 / 81), share even at 71 / 70 / 64 where the iPhone's
halves, at 7 workers the ring under the oracle misses 7 to 30 frames from
oversubscribing its 8 cores, one worker 1.24 to 1.62 times the A15's time
and six within 2 to 12 percent; module 10's large churn misses no frame on
either device (main stopped 117 ms per 10 s on the iPhone, 160 on the iPad,
against the Mac's 59 to 67) but counts module 5 fallbacks in 3 of 6 runs
where the Mac counts none; module 9d's client rows over Wi-Fi: 51 sessions
against the iPhone (by address and by Bonjour name) and 23 against the iPad
(by address), none failed, 0 frames missed in all 30 serving launches with
or without a client, `class.definition` 3.9 to 9.9 ms against 0.8 Mac to
Mac, `class.hierarchy` 40 to 65 ms against 29, `package.selectors` 77 to 103
against 78, define-and-retry 235 to 315 ms against 211, a dropped link whole
again in 1.18 to 1.21 s, so the class tree keeps the push form (the
2000-class image was not served from a device; that is an extrapolation);
the iPad's `_kajo-dev._tcp` was not seen from the Mac until the owner
granted its local-network permission later that day, after which its rows by
name ran beside rows by address (45 sessions, 22 by name, none failed, 0
frames missed in 12 serving launches, name and address within each other's
ranges), and `remote-session.sh`'s lan form no longer waits for a Bonjour
name (7bdb024); unexplained on the iPad: event latency p50 2.2 ms under the
storm (22 times the iPhone's), request maxima of 0.2 to 0.7 s over Wi-Fi,
and energy readings too low to compare with the iPhone's; the devices
investigation of the same evening (`docs/modules/shells.md` "Where the 2.2
ms went" and "The iPad's energy reading checked",
`docs/modules/phone-transport.md` "The devices investigation") explained or
bounded all three: the latency is the main thread's busy fraction (an event
due inside a turn waits about half of it; cooled, the iPad's p50 is 0.118 ms
against the iPhone's 0.097, and after sustained load its performance cluster
runs at 1.3 to 1.7 GHz instead of 2.3 while the state reads only fair, the
frame work no longer fits its turn, the main thread is busy more than half
the time and the median event is one that waited), the request maxima are
the link (every request served inside the device in at most 7.4 ms while the
client saw up to 245; both devices doze between bursts and the first request
after a gap costs about one beacon interval, 95 to 115 ms), and the A12X's
energy counters are not usable for performance cores (17 pJ per cycle
against 40 on its own efficiency cores and 323 on the A15), with no sign of
a capped clock (one thread at the rated 2.47 GHz in every launch, the slower
kernels being clock times IPC; not run on battery); the 2000-class image
served from both devices (36.9 MB, 24 sessions each, none failed, 0 frames
missed) puts `class.hierarchy` at 360 to 404 ms and `package.selectors` at
513 to 551 against the Mac's 335 and 457 with the tree step the same pushed
or on demand, so push holds on evidence; the same raw rows show the storm
missing frames on the devices in 14 of 49 launches, every one a module 5
fallback while sweeping with a stop-the-world full collection of 41 to 84 ms
(3 of 16 at 5 workers cooled, 11 of 21 at 7 workers), to be removed in the
large-bytes follow-up; its six open questions answered by the owner on
2026-11-05 (plain TCP now and PSK-TLS as a later module, no token expiry,
any number of sessions on the phone, serving only by launch argument,
signing is the owner's, doits fail at a dropped link rather than being
resent).
