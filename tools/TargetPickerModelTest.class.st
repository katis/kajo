"The target picker's model (module 9d): the host's targets listed again when they change, a target paired through the host (no token in the image), connected through the connect action, and its state following the client across a dropped link: connecting, open, reconnecting, open again."
Class {
	#name : #TargetPickerModelTest,
	#superclass : #TestCase,
	#category : #'Tools-Tests'
}

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
	self assert: m rows equals: {{'local'. '/tmp/kajo-x.sock'. 'not connected'}}.
	"A phone the host holds no token for says so; pairing asks the host, and the token never passes through the image."
	known := known , {{'phone'. 'bonjour:phone'. false}}.
	m refresh.
	self assert: (m rows at: 2) last equals: 'not connected, no token'.
	m pair: 'phone'.
	self assert: paired equals: 'phone'.
	self assert: (m status includesSubstring: 'enter its token').
	known := {known first}.
	"A phone appears on the network: the host's targets change and the picker lists them again."
	known := known , {{'phone'. 'bonjour:phone'. true}}.
	m refresh.
	self assert: (m rows collect: [:r | r first]) asArray equals: #('local' 'phone').
	m connect: 'phone'.
	self assert: (m rows at: 2) last equals: 'open'.
	c packageTags: nil then: [:r | nil].
	c lost: 'the target closed the connection'.
	self assert: (m rows at: 2) last equals: 'reconnecting'.
	self assert: (m status includesSubstring: 'reconnecting in 1 s').
	c fireTimer.
	c sessionOpened.
	self assert: (m rows at: 2) last equals: 'open'.
	self assert: (m status includesSubstring: 'connected').
	self assert: c retried equals: 1
]
