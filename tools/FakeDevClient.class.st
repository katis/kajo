"A DevClient for the tools' tests (module 9c): no connection; each request is answered at once by the responder block, which gets the kind and the arguments (a JsonObject) and answers the result, or signals an error that becomes the error reply. Events are given with event:."
Class {
	#name : #FakeDevClient,
	#superclass : #DevClient,
	#instVars : [
		'responder',
		'sent'
	],
	#category : #'Tools-Tests'
}

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
	state := #open
]

{ #category : #sending }
FakeDevClient >> transmit: aLine kind: aKind id: anId args: aJsonObject [
	| result reply |
	sent add: {aKind. aJsonObject}.
	reply := JsonObject new.
	reply at: 'v' put: 1; at: 'kind' put: 'reply'; at: 'id' put: anId.
	result := [responder isNil ifTrue: [nil] ifFalse: [responder value: aKind value: aJsonObject]]
		on: Error do: [:e |
			reply at: 'ok' put: false; at: 'error' put: e messageText.
			^ self receive: reply].
	reply at: 'ok' put: true; at: 'result' put: result.
	self receive: reply
]

{ #category : #'instance creation' }
FakeDevClient class >> on: aBlock [
	^ self new setFake: aBlock
]
