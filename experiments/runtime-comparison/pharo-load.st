"Loads the Tonel files of one program directory (the first argument after
this file) into the running image and saves it. bench.sh runs it on a copy
of Pharo.image per kernel, before any timed run, as it builds Kajo's
images."
| dir defs |
dir := (Smalltalk arguments at: 2) asFileReference.
defs := OrderedCollection new.
(dir files select: [:f | f basename endsWith: '.st'])
	do: [:f | defs addAll: (TonelParser parseString: f contents)].
(MCSnapshot fromDefinitions: defs) install.
Smalltalk snapshot: true andQuit: true.
