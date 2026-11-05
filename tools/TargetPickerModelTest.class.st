"The target picker's model (module 9d): the host's targets listed again when they change, a target connected through the connect action, and its state following the client across a dropped link: connecting, open, reconnecting, open again."
Class {
	#name : #TargetPickerModelTest,
	#superclass : #TestCase,
	#category : #'Tools-Tests'
}

{ #category : #tests }
TargetPickerModelTest >> testTheTargetsAndTheirStatesFollowTheLink [
	| m known c |
	known := {{'local'. '/tmp/kajo-x.sock'. true}}.
	m := TargetPickerModel new.
	m targetsSource: [known].
	m clientLookup: [:n | n = 'phone' ifTrue: [c] ifFalse: [nil]].
	m connectAction: [:name :address :token |
		c := FakeDevClient on: [:k :a | nil].
		c hold: true.
		c].
	m refresh.
	self assert: m rows equals: {{'local'. '/tmp/kajo-x.sock'. 'not connected'}}.
	"A phone appears on the network: the host's targets change and the picker lists them again."
	known := known , {{'phone'. 'bonjour:phone'. true}}.
	m refresh.
	self assert: (m rows collect: [:r | r first]) asArray equals: #('local' 'phone').
	m connect: 'phone' token: nil.
	self assert: (m rows at: 2) last equals: 'open'.
	c classCategories: [:r | nil].
	c lost: 'the target closed the connection'.
	self assert: (m rows at: 2) last equals: 'reconnecting'.
	self assert: (m status includesSubstring: 'reconnecting in 1 s').
	c fireTimer.
	c sessionOpened.
	self assert: (m rows at: 2) last equals: 'open'.
	self assert: (m status includesSubstring: 'connected').
	self assert: c retried equals: 1
]
