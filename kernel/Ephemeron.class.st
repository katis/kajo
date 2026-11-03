"A key held only as long as something else holds it (ADR 0009 section 1). When a collection finds the key reachable only through ephemerons, the ephemeron is queued and the finalization Process sends it mourn, which runs its finalizer with the value. Ephemerons made with key:value:finalizer: are kept in a registry until mourned. The finalization Process starts with the first one."
Class {
	#name : #Ephemeron,
	#superclass : #Object,
	#instVars : [
		'key',
		'value',
		'finalizer'
	],
	#classInstVars : [
		'registry',
		'finalizationProcess',
		'finalizationSemaphore'
	],
	#category : #'Kernel-Processes',
	#type : #ephemeron
}

{ #category : #accessing }
Ephemeron class >> key: aKey value: aValue [
	^ self basicNew setKey: aKey value: aValue finalizer: nil
]

{ #category : #accessing }
Ephemeron class >> key: aKey value: aValue finalizer: aBlock [
	| e |
	e := self basicNew setKey: aKey value: aValue finalizer: aBlock.
	self registry add: e.
	self ensureFinalizationProcess.
	^ e
]

{ #category : #accessing }
Ephemeron class >> registry [
	registry isNil ifTrue: [registry := IdentitySet new].
	^ registry
]

{ #category : #accessing }
Ephemeron class >> ensureFinalizationProcess [
	"The one Process that mourns queued ephemerons: it starts with the first registered ephemeron of a run, and a saved image keeps it (module 8c)."
	(finalizationProcess notNil and: [finalizationProcess isTerminated not]) ifTrue: [^ self].
	finalizationSemaphore := Semaphore new.
	self finalizationSemaphore: finalizationSemaphore.
	finalizationProcess := [[finalizationSemaphore wait. self mournAll] repeat] forkAt: 0
]

{ #category : #accessing }
Ephemeron class >> mournAll [
	| e |
	[(e := self nextMourner) notNil] whileTrue: [e mourn]
]

{ #category : #accessing }
Ephemeron class >> finalizationSemaphore: aSemaphore [
	<primitive: 36>
	^ self primitiveFailed
]

{ #category : #accessing }
Ephemeron class >> nextMourner [
	<primitive: 37>
	^ nil
]

{ #category : #accessing }
Ephemeron class >> forgetProcess [
	"Before the image build saves the kernel: the build's VM terminates every Process, and a run starts its own."
	finalizationProcess := nil
]

{ #category : #accessing }
Ephemeron class >> resumeAfterSnapshot [
	"A saved image resumed: the finalization Process was saved waiting on its Semaphore, which the VM signals again (module 8c). Start one if there were ephemerons but no Process."
	(registry notNil and: [registry notEmpty]) ifTrue: [self ensureFinalizationProcess]
]

{ #category : #accessing }
Ephemeron class >> finalizationProcess [
	^ finalizationProcess
]

{ #category : #accessing }
Ephemeron >> setKey: aKey value: aValue finalizer: aBlock [
	key := aKey.
	value := aValue.
	finalizer := aBlock
]

{ #category : #accessing }
Ephemeron >> key [
	^ key
]

{ #category : #accessing }
Ephemeron >> value [
	^ value
]

{ #category : #accessing }
Ephemeron >> mourn [
	self class registry remove: self ifAbsent: [nil].
	finalizer ifNotNil: [:b | b cull: value]
]
