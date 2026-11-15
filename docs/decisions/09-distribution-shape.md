# The owner's distribution shape (2026-11-05)

The owner's distribution shape (2026-11-05): Kajo ships as one Mac app
(`Kajo.dmg`, outside the App Store) carrying the development image, in which
the developer customizes the tools and creates new apps; a new app is a
generated project (an xcodegen spec with a Mac and an iOS target sharing one
Tonel directory, a pinned dependency on the Kajo package, the Debug
configuration bundling the development image with the protocol compiled in,
the Release configuration the release image without it), so the phone runs
the developer's own development build installed with Xcode and no Kajo app
is ever reviewed under guideline 2.5.2; serving on the phone therefore
becomes a property of the development build, not a launch argument, with the
pairing screen reached from the running app; a separate iOS/iPadOS Kajo app,
a teaching tool and playground with the tools on the device, is a later
idea, not planned.
