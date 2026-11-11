"The target picker's model (module 9d): the host's targets listed again when they change, a target paired through the host (no token in the image), connected through the connect action, and its state following the client across a dropped link: connecting, open, reconnecting, open again. The project directory (2026-11-11): each row shows the directory the host holds for the target, and Project… asks the host to ask the developer."
Class {
	#name : #TargetPickerModelTest,
	#superclass : #TestCase
}

{ #category : #tests }
TargetPickerModelTest >> testTheProjectItemAsksTheHostAndTheRowsShowTheDirectory [
	"Project… asks the host (the image names no directory), the rows show what the host holds once it has one (a #targets event lists them again), and a target the host holds none for shows none."
	| m held asked |
	held := Dictionary new.
	m := TargetPickerModel new.
	m targetsSource: [{{'local'. '/tmp/kajo-x.sock'. true}. {'app'. 'tcp://192.168.1.5:52000'. true}}].
	m clientLookup: [:n | nil].
	m projectSource: [:n | held at: n ifAbsent: [nil]].
	m chooseProjectAction: [:n | asked := n. held includesKey: n].
	held at: 'local' put: '/Users/me/kajo/tools'.
	m refresh.
	self assert: m rows equals: {{'local'. '/tmp/kajo-x.sock'. 'not connected'. '/Users/me/kajo/tools'}. {'app'. 'tcp://192.168.1.5:52000'. 'not connected'. ''}}.
	m chooseProject: 'app'.
	self assert: asked equals: 'app'.
	self assert: (m status includesSubstring: 'choose its project directory').
	"The developer chose in the host's panel: the host holds it, and the targets event lists the rows again."
	held at: 'app' put: '/Users/me/Sample/src'.
	m refresh.
	self assert: ((m rows at: 2) at: 4) equals: '/Users/me/Sample/src'.
	"Without a shell that has a panel the host answers nil, and the status says so."
	m chooseProjectAction: [:n | nil].
	m chooseProject: 'app'.
	self assert: (m status includesSubstring: 'no project panel')
]

{ #category : #tests }
TargetPickerModelTest >> testTheTargetsAndTheirStatesFollowTheLink [
	| m known c paired |
	known := {{'local'. '/tmp/kajo-x.sock'. true}}.
	m := TargetPickerModel new.
	m targetsSource: [known].
	m clientLookup: [:n | n = 'phone' ifTrue: [c] ifFalse: [nil]].
	m pairAction: [:name | paired := name. true].
	m connectAction: [:name :address |
		c := FakeDevClient on: [:k :a | nil].
		c hold: true.
		c].
	m refresh.
	self assert: m rows equals: {{'local'. '/tmp/kajo-x.sock'. 'not connected'. ''}}.
	"A phone the host holds no token for says so; pairing asks the host, and the token never passes through the image."
	known := known , {{'phone'. 'bonjour:phone'. false}}.
	m refresh.
	self assert: ((m rows at: 2) at: 3) equals: 'not connected, no token'.
	m pair: 'phone'.
	self assert: paired equals: 'phone'.
	self assert: (m status includesSubstring: 'enter its token').
	known := {known first}.
	"A phone appears on the network: the host's targets change and the picker lists them again."
	known := known , {{'phone'. 'bonjour:phone'. true}}.
	m refresh.
	self assert: (m rows collect: [:r | r first]) asArray equals: #('local' 'phone').
	m connect: 'phone'.
	self assert: ((m rows at: 2) at: 3) equals: 'open'.
	c packageTags: nil then: [:r | nil].
	c lost: 'the target closed the connection'.
	self assert: ((m rows at: 2) at: 3) equals: 'reconnecting'.
	self assert: (m status includesSubstring: 'reconnecting in 1 s').
	c fireTimer.
	c sessionOpened.
	self assert: ((m rows at: 2) at: 3) equals: 'open'.
	self assert: (m status includesSubstring: 'connected').
	self assert: c retried equals: 1
]
