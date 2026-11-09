"The root of the class hierarchy. Every object answers the protocol here: identity and equality, class membership, copying, printing, error signalling, and the reflective primitives (perform:, instVarAt:, the read-only bit)."
Class {
	#name : #Object,
	#superclass : nil,
	#category : #'Kernel-Objects'
}

{ #category : #accessing }
Object >> -> anObject [
	^ Association key: self value: anObject
]

{ #category : #accessing }
Object >> at: index [
	<primitive: 1>
	^ self indexError: index
]

{ #category : #accessing }
Object >> at: index put: anObject [
	<primitive: 2>
	^ self indexError: index
]

{ #category : #accessing }
Object >> basicAt: index [
	<primitive: 1>
	^ self indexError: index
]

{ #category : #accessing }
Object >> basicAt: index put: anObject [
	<primitive: 2>
	^ self indexError: index
]

{ #category : #accessing }
Object >> basicSize [
	<primitive: 95>
	^ 0
]

{ #category : #accessing }
Object >> in: aBlock [
	^ aBlock value: self
]

{ #category : #accessing }
Object >> instVarAt: index [
	<primitive: 91>
	^ self indexError: index
]

{ #category : #accessing }
Object >> instVarAt: index put: anObject [
	<primitive: 92>
	^ self indexError: index
]

{ #category : #accessing }
Object >> size [
	<primitive: 95>
	^ 0
]

{ #category : #accessing }
Object >> value [
	^ self
]

{ #category : #accessing }
Object >> yourself [
	^ self
]

{ #category : #'class membership' }
Object >> class [
	<primitive: 5>
	^ self primitiveFailed
]

{ #category : #'class membership' }
Object >> isKindOf: aClass [
	| c |
	c := self class.
	[c == nil] whileFalse: [
		c == aClass ifTrue: [^ true].
		c := c superclass].
	^ false
]

{ #category : #'class membership' }
Object >> isMemberOf: aClass [
	^ self class == aClass
]

{ #category : #'class membership' }
Object >> respondsTo: aSymbol [
	<primitive: 90>
	^ false
]

{ #category : #comparing }
Object >> = anObject [
	^ self == anObject
]

{ #category : #comparing }
Object >> == anObject [
	"Identity. The VM answers it inline; this method serves perform:."
	<primitive: 18>
	^ self primitiveFailed
]

{ #category : #comparing }
Object >> hash [
	^ self identityHash
]

{ #category : #comparing }
Object >> identityHash [
	<primitive: 19>
	^ self primitiveFailed
]

{ #category : #comparing }
Object >> ~= anObject [
	^ (self = anObject) not
]

{ #category : #comparing }
Object >> ~~ anObject [
	^ (self == anObject) not
]

{ #category : #copying }
Object >> copy [
	^ self shallowCopy postCopy
]

{ #category : #copying }
Object >> postCopy [
	^ self
]

{ #category : #copying }
Object >> shallowCopy [
	<primitive: 96>
	^ self primitiveFailed
]

{ #category : #'error handling' }
Object >> assert: aBlockOrBoolean [
	aBlockOrBoolean value ifFalse: [^ AssertionFailure new signal: 'assertion failed']
]

{ #category : #'error handling' }
Object >> error: aString [
	^ Error new signal: aString
]

{ #category : #'error handling' }
Object >> halt [
	^ Halt new signal
]

{ #category : #'error handling' }
Object >> indexError: index [
	index isInteger ifFalse: [^ self error: 'index ' , index printString , ' is not an integer'].
	^ SubscriptOutOfBounds signalFor: index in: self
]

{ #category : #'error handling' }
Object >> methodRemovedByRedefinition [
	"Sent by a method that ran after a redefinition of its class replaced it by nothing (an old closure's block, a removed method): its class's shape changed under it (module 8e)."
	^ self error: 'a method of ' , self class name , ' that a class redefinition removed ran'
]

{ #category : #'error handling' }
Object >> primitiveFailed [
	^ PrimitiveFailed new signal: 'a primitive failed in ' , thisContext sender method printString
]

{ #category : #'error handling' }
Object >> shouldNotImplement [
	^ self error: thisContext sender method printString , ' is not part of this class''s protocol'
]

{ #category : #'error handling' }
Object >> subclassResponsibility [
	^ self error: 'a subclass should have implemented ' , thisContext sender method printString
]

{ #category : #initialization }
Object >> initialize [
	^ self
]

{ #category : #'message handling' }
Object >> become: anObject [
	<primitive: 8>
	^ self error: 'become: refused'
]

{ #category : #'message handling' }
Object >> doesNotUnderstand: aMessage [
	^ MessageNotUnderstood new message: aMessage receiver: self; signal
]

{ #category : #'message handling' }
Object >> perform: aSymbol [
	<primitive: 86>
	^ self perform: aSymbol withArguments: #()
]

{ #category : #'message handling' }
Object >> perform: aSymbol with: anObject [
	<primitive: 87>
	^ self perform: aSymbol withArguments: {anObject}
]

{ #category : #'message handling' }
Object >> perform: aSymbol with: first with: second [
	<primitive: 88>
	^ self perform: aSymbol withArguments: {first. second}
]

{ #category : #'message handling' }
Object >> perform: aSymbol withArguments: anArray [
	<primitive: 89>
	aSymbol isSymbol ifFalse: [^ self error: 'perform: needs a Symbol'].
	aSymbol numArgs = anArray size ifFalse: [^ self error: 'wrong number of arguments for ' , aSymbol].
	^ self doesNotUnderstand: (Message selector: aSymbol arguments: anArray)
]

{ #category : #'nil handling' }
Object >> ifNil: nilBlock [
	^ self
]

{ #category : #'nil handling' }
Object >> ifNil: nilBlock ifNotNil: aBlock [
	^ aBlock cull: self
]

{ #category : #'nil handling' }
Object >> ifNotNil: aBlock [
	^ aBlock cull: self
]

{ #category : #'nil handling' }
Object >> ifNotNil: aBlock ifNil: nilBlock [
	^ aBlock cull: self
]

{ #category : #printing }
Object >> asString [
	^ self printString
]

{ #category : #printing }
Object >> displayNl [
	Transcript show: self displayString; cr
]

{ #category : #printing }
Object >> displayOn: aStream [
	aStream nextPutAll: self displayString
]

{ #category : #printing }
Object >> displayString [
	^ self printString
]

{ #category : #printing }
Object >> printNl [
	Transcript show: self printString; cr
]

{ #category : #printing }
Object >> printOn: aStream [
	| name |
	name := self class name.
	aStream nextPutAll: (name first isVowel ifTrue: ['an '] ifFalse: ['a ']); nextPutAll: name
]

{ #category : #printing }
Object >> printString [
	| s |
	s := WriteStream on: String new.
	self printOn: s.
	^ s contents
]

{ #category : #processes }
Object >> delay: milliseconds signal: aSemaphore [
	<primitive: 25>
	^ self error: 'cannot start a delay'
]

{ #category : #processes }
Object >> emitEvent: kind fields: anArray [
	"One event of the core event protocol to the host (NDJSON on the headless CLI)."
	<primitive: 140>
	^ self error: 'an event field is not a String, Symbol, number, Character, nil, Boolean or Array'
]

{ #category : #processes }
Object >> fork: aSelector with: anArgument priority: aPriority main: aBoolean exit: aSemaphoreOrNil [
	"A new Process sending aSelector (no primitive, at most one argument) to the receiver."
	<primitive: 20>
	^ self error: 'cannot fork ' , aSelector printString
]

{ #category : #processes }
Object >> slotAt: index [
	"Read a pointer slot of any object, sealed ones included (classes, methods, Processes)."
	<primitive: 117>
	^ self indexError: index
]

{ #category : #'read-only' }
Object >> beReadOnly [
	self setReadOnly: true
]

{ #category : #'read-only' }
Object >> beWritable [
	self setReadOnly: false
]

{ #category : #'read-only' }
Object >> modificationForbiddenAt: index value: aValue [
	"The VM sends this to a read-only object when a store into it is refused (index 1-based)."
	^ ModificationForbidden new object: self index: index value: aValue; signal
]

{ #category : #'read-only' }
Object >> setReadOnly: aBoolean [
	"Answer whether the receiver was read-only."
	<primitive: 93>
	^ self error: 'this object cannot change its read-only state'
]

{ #category : #reflection }
Object >> pointerCount [
	"How many objects hold the receiver in a slot (primitive 170: the walk of pointersTo, nothing allocated). See pointersTo."
	| n |
	n := Smalltalk primPointerCountTo: self.
	n isNil ifTrue: [^ self error: 'cannot count the objects pointing to an object: the heap is full'].
	^ n
]

{ #category : #reflection }
Object >> pointersTo [
	"Every object with a slot holding the receiver, as Pharo's pointersTo, with no limit but the largest Array's (16 777 215; pointersTo: takes a smaller one: the owner's answer of 2026-11-09). Beware: nil pointersTo or 3 pointersTo can be a long Array made in one stop; ask for a limit where that matters. The objects are found in one stop of the world after every young object is promoted, by comparing every slot of every object in the heap with the receiver: named and indexed slots, a weak slot as any other, every slot of an Array past 4095 slots. An object's class is not a slot (see allInstances). A method whose literals include the receiver is listed itself, not its literal frame. Garbage counts until a collection frees it (send Smalltalk garbageCollect first for the live holders only). The stacks of running Processes are not in the heap and are not searched: an object held only by a temporary or an argument of a running method answers #(). The world runs again between two sends, so a holder that stores or drops the receiver afterwards is not seen. The receiver may be an immediate (3 pointersTo lists every object holding 3), and the receiver holding itself is listed; the answer is never one of its own elements."
	^ self pointersTo: 16777215
]

{ #category : #reflection }
Object >> pointersTo: aLimit [
	"As pointersTo, at most aLimit holders (an Integer from 0 to 16777215, the largest Array): primitive 169, one walk of old space in a stop."
	| a |
	(aLimit isInteger and: [aLimit between: 0 and: 16777215]) ifFalse: [
		^ self error: 'the limit of pointersTo: is an Integer from 0 to 16777215, not ' , aLimit printString].
	a := Smalltalk primPointersTo: self limit: aLimit.
	a isNil ifTrue: [^ self error: 'cannot list the objects pointing to an object: the heap is full'].
	^ a
]

{ #category : #testing }
Object >> isArray [
	^ false
]

{ #category : #testing }
Object >> isBehavior [
	^ false
]

{ #category : #testing }
Object >> isBlock [
	^ false
]

{ #category : #testing }
Object >> isBoolean [
	^ false
]

{ #category : #testing }
Object >> isCharacter [
	^ false
]

{ #category : #testing }
Object >> isClass [
	^ false
]

{ #category : #testing }
Object >> isCollection [
	^ false
]

{ #category : #testing }
Object >> isCompiledMethod [
	^ false
]

{ #category : #testing }
Object >> isContext [
	^ false
]

{ #category : #testing }
Object >> isEmptyOrNil [
	^ false
]

{ #category : #testing }
Object >> isFloat [
	^ false
]

{ #category : #testing }
Object >> isFraction [
	^ false
]

{ #category : #testing }
Object >> isInteger [
	^ false
]

{ #category : #testing }
Object >> isLiteral [
	^ false
]

{ #category : #testing }
Object >> isNil [
	^ false
]

{ #category : #testing }
Object >> isNumber [
	^ false
]

{ #category : #testing }
Object >> isReadOnly [
	"Immediates are read-only; method literals are."
	<primitive: 94>
	^ self primitiveFailed
]

{ #category : #testing }
Object >> isString [
	^ false
]

{ #category : #testing }
Object >> isSymbol [
	^ false
]

{ #category : #testing }
Object >> notNil [
	^ true
]
