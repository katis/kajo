"A stream the headless CLI emits as events: each line is one transcript event with the Process that wrote it. Class side; shared by every Process under a lock."
Class {
	#name : #Transcript,
	#superclass : #Object,
	#classInstVars : [
		'stream',
		'lock'
	]
}

{ #category : #accessing }
Transcript class >> contents [
	^ lock critical: [stream contents]
]

{ #category : #accessing }
Transcript class >> cr [
	"End the line: one transcript event."
	| line |
	lock critical: [line := stream contents. stream resetContents].
	self emitEvent: 'transcript' fields: {'text'. line}
]

{ #category : #accessing }
Transcript class >> crShow: anObject [
	self cr; show: anObject
]

{ #category : #accessing }
Transcript class >> display: anObject [
	self show: anObject displayString
]

{ #category : #accessing }
Transcript class >> flush [
	| line |
	lock critical: [line := stream contents. stream resetContents].
	line isEmpty ifFalse: [self emitEvent: 'transcript' fields: {'text'. line}]
]

{ #category : #accessing }
Transcript class >> initialize [
	stream := WriteStream on: String new.
	lock := Semaphore forMutualExclusion
]

{ #category : #accessing }
Transcript class >> nextPut: aCharacter [
	aCharacter value = 10 | (aCharacter value = 13) ifTrue: [^ self cr].
	self show: aCharacter asString
]

{ #category : #accessing }
Transcript class >> nextPutAll: aString [
	self show: aString
]

{ #category : #accessing }
Transcript class >> print: anObject [
	self show: anObject printString
]

{ #category : #accessing }
Transcript class >> show: anObject [
	lock critical: [stream nextPutAll: (anObject isString ifTrue: [anObject] ifFalse: [anObject displayString])]
]

{ #category : #accessing }
Transcript class >> showLine: aString [
	"aString and the end of the line as one transcript event, whatever other Processes show meanwhile (show: then cr are two steps another Process's line can fall between: the development answers' reports come from many Processes at once)."
	| line |
	lock critical: [stream nextPutAll: aString. line := stream contents. stream resetContents].
	self emitEvent: 'transcript' fields: {'text'. line}
]

{ #category : #accessing }
Transcript class >> space [
	self show: ' '
]

{ #category : #accessing }
Transcript class >> tab [
	self show: (String with: Character tab)
]
