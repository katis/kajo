"A DevClient for the tools' tests (module 9c): no connection; each request is answered at once by the responder block, which gets the kind and the arguments (a JsonObject) and answers the result, or signals an error that becomes the error reply. Events are given with event:. Module 9d: a link that drops: hold: keeps requests unanswered (answer:with: answers one), lost: drops the link, the reconnect's timers are kept (fireTimer runs the next) and its connections counted (opened), sessionOpened answers the new session. Gate speed's follow-up: the requests' timeouts are kept apart (requestTimers, {milliseconds. block. id}; fireRequestTimer: runs one), so a test fires a timeout without waiting for one. Types 3: diagnosticsChanged: emits the type checker's event as a target does (diagnostics: answers the request's result, refuseDiagnostics the answer of a target without the checker)."
Class {
	#name : #FakeDevClient,
	#superclass : #DevClient,
	#instVars : [
		'responder',
		'sent',
		'holding',
		'timers',
		'opened',
		'requestTimers'
	]
}

{ #category : #accessing }
FakeDevClient >> diagnosticsChanged: someKeys [
	"The type checker's event after a recheck: the methods whose diagnostics changed (Class>>selector or Class class>>selector)."
	self event: 'diagnostics.changed' with: {'count'. 0. 'pass'. 2. 'methods'. someKeys asArray. 'diagnostics'. #()}
]

{ #category : #accessing }
FakeDevClient >> event: aKind with: anArray [
	"An event from the target: its kind and fields as name, value pairs."
	| o |
	o := JsonObject new.
	o at: 'v' put: 1; at: 'kind' put: aKind.
	1 to: anArray size by: 2 do: [:i | o at: (anArray at: i) put: (anArray at: i + 1)].
	self receive: o
]

{ #category : #accessing }
FakeDevClient >> lastId [
	"The id of the latest request (answer:with: answers a held one by it)."
	^ nextId
]

{ #category : #accessing }
FakeDevClient >> responder: aBlock [
	responder := aBlock
]

{ #category : #accessing }
FakeDevClient >> sent [
	"{kind. arguments} of every request, in order."
	^ sent
]

{ #category : #accessing }
FakeDevClient >> sentKinds [
	^ (sent collect: [:s | s first]) asArray
]

{ #category : #initialization }
FakeDevClient >> setFake: aBlock [
	responder := aBlock.
	sent := OrderedCollection new.
	name := 'fake'.
	state := #open.
	info := JsonObject new.
	holding := false.
	timers := OrderedCollection new.
	requestTimers := OrderedCollection new.
	opened := 0
]

{ #category : #link }
FakeDevClient >> after: milliseconds do: aBlock [
	| t |
	t := {milliseconds. aBlock}.
	timers add: t.
	^ t
]

{ #category : #link }
FakeDevClient >> answer: anId with: aResult [
	| reply |
	reply := JsonObject new.
	reply at: 'v' put: 1; at: 'kind' put: 'reply'; at: 'id' put: anId; at: 'ok' put: true; at: 'result' put: aResult.
	self receive: reply
]

{ #category : #link }
FakeDevClient >> cancelRequestTimer: aTimerOrNil [
	requestTimers := (requestTimers reject: [:t | t == aTimerOrNil]) asOrderedCollection
]

{ #category : #link }
FakeDevClient >> cancelTimer: aTimer [
	timers := (timers reject: [:t | t == aTimer]) asOrderedCollection
]

{ #category : #link }
FakeDevClient >> fireRequestTimer: aTimer [
	"The request's timeout runs out now."
	requestTimers := (requestTimers reject: [:t | t == aTimer]) asOrderedCollection.
	(aTimer at: 2) value
]

{ #category : #link }
FakeDevClient >> fireTimer [
	timers removeFirst last value
]

{ #category : #link }
FakeDevClient >> hold: aBoolean [
	"While true, requests are recorded and left unanswered."
	holding := aBoolean
]

{ #category : #link }
FakeDevClient >> openConnection [
	opened := opened + 1.
	^ 1000 + opened
]

{ #category : #link }
FakeDevClient >> opened [
	^ opened
]

{ #category : #link }
FakeDevClient >> requestTimerAfter: milliseconds do: aBlock [
	| t |
	t := {milliseconds. aBlock. nextId}.
	requestTimers add: t.
	^ t
]

{ #category : #link }
FakeDevClient >> requestTimers [
	"{milliseconds. block. id of the latest request when it was armed} of every request timeout still armed."
	^ requestTimers
]

{ #category : #link }
FakeDevClient >> sessionOpened [
	"The new session's reply."
	| reply |
	reply := JsonObject new.
	reply at: 'v' put: 1; at: 'kind' put: 'reply'; at: 'id' put: 'session'; at: 'ok' put: true; at: 'result' put: JsonObject new.
	self receive: reply
]

{ #category : #link }
FakeDevClient >> timers [
	"{milliseconds. block} of every timer asked for."
	^ timers
]

{ #category : #sending }
FakeDevClient >> transmit: aLine kind: aKind id: anId args: aJsonObject [
	| result reply |
	sent add: {aKind. aJsonObject}.
	holding ifTrue: [^ self].
	reply := JsonObject new.
	reply at: 'v' put: 1; at: 'kind' put: 'reply'; at: 'id' put: anId.
	result := [responder isNil ifTrue: [nil] ifFalse: [responder value: aKind value: aJsonObject]]
		on: Error do: [:e |
			reply at: 'ok' put: false; at: 'error' put: e messageText.
			^ self receive: reply].
	reply at: 'ok' put: true; at: 'result' put: result.
	self receive: reply
]

{ #category : #diagnostics }
FakeDevClient class >> diagnostic: aKind class: aClassName side: aSide selector: aSelector line: aLine start: aStart end: anEnd text: aString [
	"One diagnostic as the diagnostics request and the event carry it."
	^ JsonObject new
		at: 'kind' put: aKind; at: 'class' put: aClassName; at: 'side' put: aSide; at: 'selector' put: aSelector;
		at: 'line' put: aLine; at: 'start' put: aStart; at: 'end' put: anEnd; at: 'text' put: aString;
		yourself
]

{ #category : #diagnostics }
FakeDevClient class >> diagnostics: anArray [
	"The diagnostics request's result: count, checked and the diagnostics."
	^ JsonObject new at: 'count' put: anArray size; at: 'checked' put: anArray size; at: 'diagnostics' put: anArray asArray; yourself
]

{ #category : #diagnostics }
FakeDevClient class >> refuseDiagnostics [
	"What a target without the type checker's package answers (DevProtocol>>take:), signalled from a responder."
	^ self error: 'unknown request diagnostics: protocol.describe lists the requests'
]

{ #category : #'instance creation' }
FakeDevClient class >> on: aBlock [
	^ self new setFake: aBlock
]
