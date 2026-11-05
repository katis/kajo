"The protocol client in Smalltalk (module 9c): every request of protocol.describe has its message, replies are matched by id and their round trips kept, errors reach the error block or the error action, events reach the listeners of their kind, a malformed line is a client.error event, and the connection's end fails what is pending. Module 9d: a dropped link reconnects with a growing wait and sends again what may be sent again; a refused session and close end it for good."
Class {
	#name : #DevClientTest,
	#superclass : #TestCase,
	#category : #'Tools-Tests'
}

{ #category : #tests }
DevClientTest >> testADroppedLinkReconnectsAndSendsAgainWhatMayBe [
	| c got failed events listId evalId |
	c := FakeDevClient on: [:k :a | nil].
	c hold: true.
	events := OrderedCollection new.
	#('connection.lost' 'connection.reconnecting' 'connection.open') do: [:k | c on: k do: [:e | events add: k]].
	listId := c classList: nil then: [:r | got := r].
	evalId := c request: 'evaluate' args: {'source'. '1'} then: [:r | got := #evaluated] else: [:e | failed := e].
	self assert: c pendingCount equals: 2.
	c lost: 'the target closed the connection'.
	"The doit may have run: it fails; the read waits."
	self assert: c state equals: #reconnecting.
	self assert: (failed includesSubstring: 'not sent again').
	self assert: c pendingCount equals: 1.
	self assert: c timers size equals: 1.
	self assert: c timers first first equals: 1000.
	"A request made meanwhile waits too, unsent."
	c classCategories: [:r | nil].
	self assert: c sent size equals: 2.
	c fireTimer.
	self assert: c opened equals: 1.
	self assert: c reconnects equals: 1.
	c sessionOpened.
	self assert: c state equals: #open.
	self assert: events asArray equals: #('connection.lost' 'connection.reconnecting' 'connection.open').
	"Both were sent on the new session, with their ids."
	self assert: c sent size equals: 4.
	self assert: c retried equals: 2.
	self assert: (c sent last: 2) first first equals: 'class.list'.
	c answer: listId with: #('Object').
	self assert: got equals: #('Object').
	self assert: c latencies last first equals: 'class.list (retried)'.
	self assert: c outages size equals: 1.
	self assert: c backoffMs equals: 1000
]

{ #category : #tests }
DevClientTest >> testALineIsReadAndAMalformedOneIsAnEvent [
	| c errors seen |
	c := FakeDevClient on: [:k :a | nil].
	errors := OrderedCollection new.
	c on: 'client.error' do: [:e | errors add: e].
	c on: 'process.resumed' do: [:e | seen := e at: 'process'].
	c receiveLine: '{"v":1,"kind":"process.resumed","process":12}'.
	c receiveLine: '{"v":1,"kind":'.
	c receiveLine: '[1,2]'.
	self assert: seen equals: 12.
	self assert: errors size equals: 2
]

{ #category : #tests }
DevClientTest >> testARefusedSessionIsNotReconnected [
	| c refused reply |
	c := FakeDevClient on: [:k :a | nil].
	c on: 'connection.refused' do: [:e | refused := e].
	reply := JsonObject new.
	reply at: 'v' put: 1; at: 'kind' put: 'reply'; at: 'id' put: 'session'; at: 'ok' put: false; at: 'error' put: 'no session without the token'.
	c receive: reply.
	self assert: refused equals: 'no session without the token'.
	c lost: 'the target closed the connection'.
	self assert: c state equals: #lost.
	self assert: c timers isEmpty
]

{ #category : #tests }
DevClientTest >> testATimedOutRequestFails [
	| c failed |
	c := FakeDevClient on: [:k :a | nil].
	c pendingAt: 3 put: {'test.run'. 0. [:r | nil]. [:e | failed := e]. nil}.
	c timedOut: 3.
	self assert: (failed includesSubstring: 'no reply').
	self assert: c pendingCount equals: 0
]

{ #category : #tests }
DevClientTest >> testAnErrorGoesToTheErrorBlockOrTheErrorAction [
	| c a b |
	c := FakeDevClient on: [:kind :args | self error: 'no such class'].
	c request: 'class.definition' args: {'className'. 'Nope'} then: [:r | a := #result] else: [:e | a := e].
	self assert: a equals: 'no such class'.
	c onError: [:e :kind | b := kind , ': ' , e].
	c classDefinition: 'Nope' then: [:r | b := #result].
	self assert: b equals: 'class.definition: no such class'
]

{ #category : #tests }
DevClientTest >> testEventsReachTheirListeners [
	| c lines all |
	c := FakeDevClient on: [:k :a | nil].
	lines := OrderedCollection new.
	all := 0.
	c on: 'transcript' do: [:e | lines add: (e at: 'text')].
	c on: '*' do: [:e | all := all + 1].
	c event: 'transcript' with: {'text'. 'hello'}.
	c event: 'test.passed' with: {'test'. 'FooTest>>testBar'}.
	self assert: lines asArray equals: #('hello').
	self assert: all equals: 2
]

{ #category : #tests }
DevClientTest >> testEveryRequestHasItsMessage [
	"DevClient class>>requests against this image's own protocol.describe: the same kinds, each method taking the request's arguments and the result block."
	| described table |
	described := DevProtocol describe.
	table := Dictionary new.
	DevClient requests do: [:r | table at: r first put: (r at: 2)].
	self assert: table size equals: described size.
	described do: [:d | | sel |
		sel := table at: (d at: 'kind') ifAbsent: [nil].
		self assert: sel notNil description: (d at: 'kind') , ' has no DevClient message'.
		self assert: (DevClient includesSelector: sel) description: sel.
		self assert: sel numArgs equals: (d at: 'arguments') size + 1]
]

{ #category : #tests }
DevClientTest >> testRepliesAreMatchedById [
	| c got |
	c := FakeDevClient on: [:kind :args | kind = 'evaluate' ifTrue: [(args at: 'source') , '!'] ifFalse: [nil]].
	c evaluate: '3 + 4' receiver: nil then: [:r | got := r].
	self assert: got equals: '3 + 4!'.
	self assert: c sentKinds equals: #('evaluate').
	self assert: c latencies size equals: 1.
	self assert: c latencies first first equals: 'evaluate'.
	self assert: c pendingCount equals: 0
]

{ #category : #tests }
DevClientTest >> testTheConnectionsEndFailsWhatIsPending [
	| c failed lost |
	c := FakeDevClient on: [:k :a | nil].
	c pendingAt: 7 put: {'class.list'. 0. [:r | nil]. [:e | failed := e]. nil}.
	c on: 'connection.lost' do: [:why | lost := why].
	"Closed by the client (module 9d: a dropped link reconnects instead)."
	c close.
	c lost: 'the target closed the connection'.
	self assert: c state equals: #lost.
	self assert: (failed includesSubstring: 'lost').
	self assert: lost equals: 'the target closed the connection'.
	c classList: nil then: [:r | failed := #sent].
	self deny: failed == #sent
]

{ #category : #tests }
DevClientTest >> testTheSessionReplyOpensTheClient [
	| c opened |
	c := DevClient new.
	c on: 'connection.open' do: [:i | opened := i at: 'client'].
	self assert: c state equals: #connecting.
	c receiveLine: '{"v":1,"kind":"reply","conn":1,"id":"session","ok":true,"result":{"protocol":1,"client":"developer"}}'.
	self assert: c isOpen.
	self assert: opened equals: 'developer'
]

{ #category : #tests }
DevClientTest >> testTheWaitGrowsAndCloseEndsIt [
	| c failed |
	c := FakeDevClient on: [:k :a | nil].
	c hold: true.
	c request: 'class.list' args: #() then: [:r | nil] else: [:e | failed := e].
	c lost: 'dropped'.
	c fireTimer.
	"The new connection failed too."
	c lost: 'connect: no route to host'.
	c fireTimer.
	c lost: 'connect: no route to host'.
	self assert: (c timers collect: [:t | t first]) asArray equals: #(4000).
	self assert: c reconnects equals: 2.
	c close.
	self assert: c state equals: #lost.
	self assert: (failed includesSubstring: 'closed').
	self assert: c pendingCount equals: 0
]
