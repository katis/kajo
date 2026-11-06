"Module 9a's measurement scenarios in Smalltalk (the shells' mode=scenario): module 7's background loads (storm, ring, share; module 10's large) forked on the background workers until the shell terminates them, the measurement window built from the kernel's view wrappers, a frame action that runs module 7's main-thread load (mainTick:work:) and moves a probe view every frame, a synthetic-event action that sets a label (the latency measurement), and the main-thread hog."
Class {
	#name : #ShellBench,
	#superclass : #Object,
	#classInstVars : [
		'window',
		'label',
		'probe',
		'slider',
		'text',
		'ring',
		'shared',
		'failures'
	],
	#category : #'Shell-Bench'
}

{ #category : #window }
ShellBench class >> openScenario: aName mainAlloc: alloc mainWork: work [
	"The scenario's window; answers the latency label's handle. Starts the event loop."
	window := Window new.
	window title: 'Kajo ' , aName.
	window x: 0 y: 0 width: 390 height: 700.
	label := window add: Label new.
	label x: 20 y: 60 width: 300 height: 30.
	label text: aName.
	probe := window add: View new.
	probe x: 0 y: 110 width: 14 height: 14.
	probe color: 'blue'.
	slider := window add: Slider new.
	slider x: 20 y: 140 width: 340 height: 30.
	slider minimum: 0 maximum: 100.
	slider value: 42.
	text := window add: TextView new.
	text x: 20 y: 190 width: 340 height: 300.
	window show.
	ring := Array new: 256.
	UIEventLoop onFrame: [:e |
		self mainTick: alloc work: work.
		probe moveToX: e value \\ 360 y: 110].
	UIEventLoop onSynthetic: [:e | label text: e value printString].
	UIEventLoop start.
	^ label handle
]

{ #category : #window }
ShellBench class >> mainTick: alloc work: work [
	"Module 7's mainload.kasm: alloc pairs, every 64th kept in a ring of 256, then work iterations of arithmetic."
	| p acc |
	p := nil.
	0 to: alloc - 1 do: [:i |
		p := Array with: i with: p.
		i \\ 64 = 0 ifTrue: [ring at: i // 64 \\ 256 + 1 put: p. p := nil]].
	acc := 0.
	0 to: work - 1 do: [:i | acc := acc + i \\ 7].
	^ acc
]

{ #category : #loads }
ShellBench class >> startLoad: aName workers: n [
	"Fork the background load on n Processes (one per background worker); answers how many."
	failures := 0.
	aName = 'storm' ifTrue: [n timesRepeat: [[self storm] forkAt: 1]. ^ n].
	aName = 'ring' ifTrue: [1 to: n do: [:w | [self ring: w] forkAt: 1]. ^ n].
	aName = 'large' ifTrue: [[self large] forkAt: 1. ^ 1].
	aName = 'photo' ifTrue: [[self photo] forkAt: 1. ^ 1].
	aName = 'share' ifTrue: [
		shared := Array new: n * 256.
		0 to: n - 1 do: [:w | [self share: w of: n] forkAt: 1].
		^ n].
	^ 0
]

{ #category : #loads }
ShellBench class >> large [
	"Module 10's churn of large objects, on one Process: an Array of 1 000 000 slots kept live throughout (every marking cycle traces it, a small Array in every 1000th slot), then forever an Array of 131 072 slots (1 MiB, a run of 33 blocks) filled and checked, and every 16th time a ByteArray of 16 MiB - 1 (a run of 513 blocks) written at both ends; the last four Arrays stay live, everything else is dropped."
	| keep i a b huge |
	huge := Array new: 1000000.
	1 to: 1000000 by: 1000 do: [:k | huge at: k put: (Array new: 2)].
	keep := Array new: 4.
	i := 0.
	[a := Array new: 131072.
	 1 to: 131072 by: 1024 do: [:k | a at: k put: k].
	 (a at: 130049) = 130049 ifFalse: [failures := failures + 1].
	 keep at: i \\ 4 + 1 put: a.
	 i \\ 16 = 0 ifTrue: [
		b := ByteArray new: 16777215.
		b at: 1 put: 1; at: 16777215 put: 255.
		(b at: 16777215) = 255 ifFalse: [failures := failures + 1].
		b := nil].
	 (huge at: 999001) size = 2 ifFalse: [failures := failures + 1].
	 i := i + 1] repeat
]

{ #category : #loads }
ShellBench class >> photo [
	"Large bytes: a photo app's churn on one Process: forever a decoded 12-megapixel RGBA photo, a ByteArray of 48 000 000 bytes (past the header's count field), filled row by row from a 16 000-byte row (primitive 38), checked at both ends and dropped; the last one stays live."
	| row keep p n |
	n := 4000 * 3000 * 4.
	row := ByteArray new: 16000.
	1 to: 16000 do: [:i | row at: i put: i \\ 251].
	[p := ByteArray new: n.
	 1 to: n by: 16000 do: [:k | p replaceFrom: k to: k + 15999 with: row startingAt: 1].
	 ((p at: 1) = 1 and: [(p at: n) = (16000 \\ 251)]) ifFalse: [failures := failures + 1].
	 keep := p] repeat
]

{ #category : #loads }
ShellBench class >> storm [
	"Module 7's storm: a long-lived tree of depth 12, then trees of depth 16 built, checked and dropped, forever."
	| long |
	long := BenchNode build: 12.
	[(BenchNode build: 16) check = 131071 ifFalse: [failures := failures + 1].
	 long check = 8191 ifFalse: [failures := failures + 1]] repeat
]

{ #category : #loads }
ShellBench class >> ring: w [
	"Module 7's ring (fragment.kasm), bounded: nodes of 14 slots live 32 768 iterations in a ring (promoted, then dying in old space); every 20th evicted node is kept in a keep ring of 65 536 (5 percent survivors scattered in old space, themselves replaced after 1.3 million iterations, where fragment.kasm kept them to the end); 2 young garbage Arrays per iteration; every 4th iteration a store into a kept node. Rings are spines of Arrays of 1024 (an object fits a block)."
	| nodes keep i k slot chunk evicted node kept |
	nodes := Array new: 32.
	1 to: 32 do: [:j | nodes at: j put: (Array new: 1024)].
	keep := Array new: 64.
	1 to: 64 do: [:j | keep at: j put: (Array new: 1024)].
	i := 0.
	k := 0.
	[i := i + 1.
	 node := Array new: 14.
	 node at: 2 put: i.
	 slot := i \\ 32768.
	 chunk := nodes at: slot // 1024 + 1.
	 evicted := chunk at: slot \\ 1024 + 1.
	 chunk at: slot \\ 1024 + 1 put: node.
	 (i \\ 20 = 0 and: [evicted notNil]) ifTrue: [
		k := k + 1 \\ 65536.
		(keep at: k // 1024 + 1) at: k \\ 1024 + 1 put: evicted].
	 Array new: 2.
	 Array new: 2.
	 i \\ 4 = 0 ifTrue: [
		kept := (keep at: i * 7919 \\ 64 + 1) at: i \\ 1024 + 1.
		kept notNil ifTrue: [kept at: 2 put: i]]] repeat
]

{ #category : #loads }
ShellBench class >> share: w of: n [
	"Module 7's share (sharestorm.kasm), forever: young Boxes deposited in a shared Array, the neighbour's taken and checked, kept in a ring of 512."
	| ring512 prev i own neighbour box taken key |
	ring512 := Array new: 512.
	own := w * 256.
	neighbour := w + 1 \\ n * 256.
	prev := nil.
	i := 0.
	[i := i + 1.
	 key := w * 10000000 + i.
	 box := BenchBox key: key prev: prev.
	 prev := i \\ 16 = 0 ifTrue: [nil] ifFalse: [box].
	 shared at: own + (i \\ 256) + 1 put: box.
	 Array new: 4.
	 i \\ 2 = 0 ifTrue: [
		taken := shared at: neighbour + (i \\ 256) + 1.
		taken notNil ifTrue: [
			taken check = 0 ifFalse: [failures := failures + 1].
			(taken next notNil and: [taken next check ~= 0]) ifTrue: [failures := failures + 1].
			ring512 at: i \\ 512 + 1 put: taken]]] repeat
]

{ #category : #loads }
ShellBench class >> failures [
	"Checks that failed in the loads (0: no object was lost or torn)."
	^ failures
]

{ #category : #loads }
ShellBench class >> hog [
	"An infinite loop on the main thread (ADR 0004's stuck scenario)."
	| x |
	x := 0.
	[true] whileTrue: [x := x + 1 \\ 1000]
]

{ #category : #loads }
ShellBench class >> spin: n [
	| acc |
	acc := 0.
	1 to: n do: [:i | acc := acc + i \\ 7].
	^ acc
]
