"An inspector's model (module 9c): an object of the target under a handle, its class, printString and slots (named, then the first 100 indexed), each with a handle; dive into a slot and back. Every handle it was given is released when the window closes. Its workspace has self bound to the object."
Class {
	#name : #InspectorModel,
	#superclass : #ToolModel,
	#instVars : [
		'handle',
		'object',
		'slots',
		'history',
		'seen',
		'workspace'
	],
	#category : #'Tools-Models'
}

{ #category : #accessing }
InspectorModel >> handle [
	^ handle
]

{ #category : #accessing }
InspectorModel >> object [
	"The target's description: value (printString), class, handle."
	^ object
]

{ #category : #accessing }
InspectorModel >> slots [
	^ slots ifNil: [#()]
]

{ #category : #accessing }
InspectorModel >> title [
	^ object isNil ifTrue: ['Inspector'] ifFalse: [(object at: 'class') , ' ' , ((object at: 'value') copyFrom: 1 to: ((object at: 'value') byteSize min: 40))]
]

{ #category : #accessing }
InspectorModel >> workspace [
	^ workspace
]

{ #category : #closing }
InspectorModel >> closed [
	"Let the target drop every object this inspector was given a handle to."
	seen isNil ifTrue: [^ self].
	seen do: [:h | client inspectRelease: h then: [:r | nil]].
	seen := Set new
]

{ #category : #closing }
InspectorModel >> releasedCount [
	^ seen size
]

{ #category : #initialization }
InspectorModel >> client: aDevClient [
	super client: aDevClient.
	workspace := WorkspaceModel new client: aDevClient; yourself.
	history := OrderedCollection new.
	seen := Set new
]

{ #category : #navigating }
InspectorModel >> back [
	history isEmpty ifTrue: [^ self].
	self show: history removeLast
]

{ #category : #navigating }
InspectorModel >> dive: anIndex [
	"Inspect the slot at anIndex (its handle); back returns."
	| h |
	(anIndex between: 1 and: self slots size) ifFalse: [^ self].
	h := (slots at: anIndex) at: 'handle'.
	h isNil ifTrue: [^ self status: 'a ' , ((slots at: anIndex) at: 'class') , ' has no slots to look into'].
	history add: handle.
	self show: h
]

{ #category : #navigating }
InspectorModel >> inspect: aHandle [
	history := OrderedCollection new.
	self show: aHandle
]

{ #category : #navigating }
InspectorModel >> show: aHandle [
	handle := aHandle.
	seen add: aHandle.
	workspace receiver: aHandle.
	self request: 'inspect' args: {'handle'. aHandle} then: [:r |
		handle = aHandle ifTrue: [
			object := r.
			slots := r at: 'slots'.
			slots do: [:s | (s at: 'handle') ifNotNil: [:h | seen add: h]].
			self changed: #object]]
]
