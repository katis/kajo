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

{ #category : #evaluating }
CompiledMethod >> valueWithReceiver: anObject arguments: anArray [
	"Run the method once on anObject, as if a send had found it, without installing it (module 8d: what Compiler evaluate: does with a doit). The receiver must be an instance of the method's class or of a subclass, anArray its arguments; a method with a primitive does not run this way."
	<primitive: 85>
	^ self error: 'cannot run ' , self printString , ' on ' , anObject printString , ' with ' , anArray size printString , ' argument(s)'
]
