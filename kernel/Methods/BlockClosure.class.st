"A closure: a block method, the home's receiver, the home Context when the block returns non-locally, then the copied values (ADR 0009 section 4). Sealed; literal-block control flow is compiled inline, these methods serve the rest."
Class {
	#name : #BlockClosure,
	#superclass : #Object,
	#instVars : [
		'method',
		'receiver',
		'home'
	],
	#type : #variable
}

{ #category : #control }
BlockClosure >> repeat [
	[self value] repeat
]

{ #category : #control }
BlockClosure >> whileFalse [
	[self value] whileFalse.
	^ nil
]

{ #category : #control }
BlockClosure >> whileFalse: aBlock [
	[self value] whileFalse: [aBlock value].
	^ nil
]

{ #category : #control }
BlockClosure >> whileTrue [
	[self value] whileTrue.
	^ nil
]

{ #category : #control }
BlockClosure >> whileTrue: aBlock [
	[self value] whileTrue: [aBlock value].
	^ nil
]

{ #category : #evaluating }
BlockClosure >> cull: a [
	^ self numArgs = 0 ifTrue: [self value] ifFalse: [self value: a]
]

{ #category : #evaluating }
BlockClosure >> cull: a cull: b [
	^ self numArgs < 2 ifTrue: [self cull: a] ifFalse: [self value: a value: b]
]

{ #category : #evaluating }
BlockClosure >> home [
	<primitive: 115>
	^ self primitiveFailed
]

{ #category : #evaluating }
BlockClosure >> isBlock [
	^ true
]

{ #category : #evaluating }
BlockClosure >> method [
	<primitive: 114>
	^ self primitiveFailed
]

{ #category : #evaluating }
BlockClosure >> numArgs [
	<primitive: 112>
	^ self primitiveFailed
]

{ #category : #evaluating }
BlockClosure >> numArgsError: n [
	^ self error: 'a block of ' , self numArgs printString , ' arguments called with ' , n printString
]

{ #category : #evaluating }
BlockClosure >> receiver [
	<primitive: 113>
	^ self primitiveFailed
]

{ #category : #evaluating }
BlockClosure >> value [
	<primitive: 80>
	^ self numArgsError: 0
]

{ #category : #evaluating }
BlockClosure >> value: a [
	<primitive: 81>
	^ self numArgsError: 1
]

{ #category : #evaluating }
BlockClosure >> value: a value: b [
	<primitive: 82>
	^ self numArgsError: 2
]

{ #category : #evaluating }
BlockClosure >> value: a value: b value: c [
	<primitive: 83>
	^ self numArgsError: 3
]

{ #category : #evaluating }
BlockClosure >> valueWithArguments: anArray [
	<primitive: 84>
	^ self numArgsError: anArray size
]

{ #category : #exceptions }
BlockClosure >> cannotReturn: aValue [
	"The VM sends this when a non-local return's home has already returned."
	^ BlockCannotReturn new result: aValue; signal: 'the block''s home method has returned'
]

{ #category : #exceptions }
BlockClosure >> ensure: aBlock [
	"aBlock runs after the receiver, however the receiver is left. The unwind mark makes the unwinder find this frame: temp 1 the block, temp 2 its complete flag."
	<unwind>
	| complete result |
	result := self value.
	complete ifNil: [
		complete := true.
		aBlock value].
	^ result
]

{ #category : #exceptions }
BlockClosure >> ifCurtailed: aBlock [
	"aBlock runs only if the receiver is left by an unwind (a non-local return, an exception's return)."
	<unwind>
	| complete result |
	result := self value.
	complete := true.
	^ result
]

{ #category : #exceptions }
BlockClosure >> ifError: aBlock [
	^ self on: Error do: [:e | aBlock cull: e messageText cull: e receiver]
]

{ #category : #exceptions }
BlockClosure >> on: exceptionClass do: handlerBlock [
	| result |
	[(result := self privateOn: exceptionClass do: handlerBlock) == Exception retryMarker] whileTrue.
	^ result
]

{ #category : #exceptions }
BlockClosure >> privateOn: exceptionClass do: handlerBlock [
	"The handler mark: the signal finds this frame; temps 1 and 2 are the class and the handler, temp 3 the busy flag."
	<handler>
	| busy |
	^ self value
]

{ #category : #printing }
BlockClosure >> printOn: aStream [
	aStream nextPutAll: '[] in '; print: self method methodClass
]

{ #category : #processes }
BlockClosure >> fork [
	^ self forkAt: nil
]

{ #category : #processes }
BlockClosure >> forkAt: aPriority [
	"A new Process running the block (priority 0 background, 1 normal, 2 UI; nil: the current one's)."
	^ self fork: #forkedValue with: nil priority: aPriority main: false exit: nil
]

{ #category : #processes }
BlockClosure >> forkedValue [
	^ self value
]
