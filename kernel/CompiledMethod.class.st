"A method or a block method: bytecodes, literals and a header the VM verified. Sealed; read with slotAt:. Block methods are literals of their method."
Class {
	#name : #CompiledMethod,
	#superclass : #Object,
	#instVars : [
		'bytecodes',
		'literals',
		'numArgs',
		'numTemps',
		'frameSize',
		'selector',
		'primitive',
		'flags',
		'methodClass',
		'numCopied'
	],
	#category : #'Kernel-Methods'
}

{ #category : #accessing }
CompiledMethod >> blockMethods [
	^ self literals select: [:each | each class == CompiledMethod]
]

{ #category : #accessing }
CompiledMethod >> bytecodes [
	^ self slotAt: 1
]

{ #category : #accessing }
CompiledMethod >> flags [
	^ self slotAt: 8
]

{ #category : #accessing }
CompiledMethod >> frameSize [
	^ self slotAt: 5
]

{ #category : #accessing }
CompiledMethod >> hasHandlerMark [
	^ (self flags bitAnd: 2) ~= 0
]

{ #category : #accessing }
CompiledMethod >> hasPragma: aSymbol [
	^ (self pragmaAt: aSymbol) notNil
]

{ #category : #accessing }
CompiledMethod >> hasUnwindMark [
	^ (self flags bitAnd: 1) ~= 0
]

{ #category : #accessing }
CompiledMethod >> isBlockMethod [
	^ (self flags bitAnd: 4) ~= 0
]

{ #category : #accessing }
CompiledMethod >> isCompiledMethod [
	^ true
]

{ #category : #accessing }
CompiledMethod >> literals [
	^ self slotAt: 2
]

{ #category : #accessing }
CompiledMethod >> methodClass [
	^ self slotAt: 9
]

{ #category : #accessing }
CompiledMethod >> needsHome [
	^ (self flags bitAnd: 8) ~= 0
]

{ #category : #accessing }
CompiledMethod >> numArgs [
	^ self slotAt: 3
]

{ #category : #accessing }
CompiledMethod >> numCopied [
	^ self slotAt: 10
]

{ #category : #accessing }
CompiledMethod >> numTemps [
	^ self slotAt: 4
]

{ #category : #accessing }
CompiledMethod >> pragmaAt: aSymbol [
	^ self pragmas detect: [:p | p selector == aSymbol] ifNone: [nil]
]

{ #category : #accessing }
CompiledMethod >> pragmas [
	^ self literals select: [:each | each class == Pragma]
]

{ #category : #accessing }
CompiledMethod >> primitive [
	^ self slotAt: 7
]

{ #category : #accessing }
CompiledMethod >> printOn: aStream [
	aStream print: self methodClass; nextPutAll: '>>'.
	self isBlockMethod ifTrue: [aStream nextPutAll: '[]'] ifFalse: [aStream nextPutAll: self selector]
]

{ #category : #accessing }
CompiledMethod >> selector [
	^ self slotAt: 6
]

{ #category : #debugging }
CompiledMethod >> hasSourceMap [
	^ (self flags bitAnd: 16) ~= 0
]

{ #category : #debugging }
CompiledMethod >> homeMethod [
	"The method a block method belongs to (itself for a method)."
	self isBlockMethod ifFalse: [^ self].
	self methodClass methodsDo: [:m | (m includesBlockMethod: self) ifTrue: [^ m]].
	^ nil
]

{ #category : #debugging }
CompiledMethod >> includesBlockMethod: aCompiledMethod [
	^ self blockMethods anySatisfy: [:b | b == aCompiledMethod or: [b includesBlockMethod: aCompiledMethod]]
]

{ #category : #debugging }
CompiledMethod >> sourceCode [
	"The recorded source of the method (of its home method for a block method), or nil."
	^ self homeMethod ifNotNil: [:m | Smalltalk sourceOf: m]
]

{ #category : #debugging }
CompiledMethod >> sourceMapEntries [
	"The pc-to-source map (module 9b), each entry {pc. start. end}: a send at pc whose source is the bytes from start (1-based) to end (inclusive) of sourceCode. Empty without a map."
	| map out i pc next |
	self hasSourceMap ifFalse: [^ #()].
	map := self literals last.
	out := OrderedCollection new.
	i := 1.
	pc := 0.
	next := [| v shift b |
		v := 0. shift := 0.
		[b := map at: i. i := i + 1. v := v + ((b bitAnd: 127) bitShift: shift). shift := shift + 7. b >= 128] whileTrue.
		v].
	[i <= map size] whileTrue: [ | start |
		pc := pc + next value.
		start := next value.
		out add: {pc. start + 1. start + next value}].
	^ out asArray
]

{ #category : #debugging }
CompiledMethod >> sourceRangeAt: aPc [
	"{start. end} of the send at aPc or the last one before it, nil when there is none."
	| found |
	found := nil.
	self sourceMapEntries do: [:e | e first <= aPc ifTrue: [found := {e at: 2. e at: 3}]].
	^ found
]

{ #category : #evaluating }
CompiledMethod >> valueWithReceiver: anObject arguments: anArray [
	"Run the method once on anObject, as if a send had found it, without installing it (module 8d: what Compiler evaluate: does with a doit). The receiver must be an instance of the method's class or of a subclass, anArray its arguments; a method with a primitive does not run this way."
	<primitive: 85>
	^ self error: 'cannot run ' , self printString , ' on ' , anObject printString , ' with ' , anArray size printString , ' argument(s)'
]

{ #category : #accessing }
CompiledMethod >> plainBytecodes [
	"The bytecodes as the compilers emitted them: the VM makes every method through a peephole that writes fused opcodes into some first bytes (interpreter speed); this answers a new ByteArray with each one back as its first part."
	<primitive: 166>
	^ self primitiveFailed
]
