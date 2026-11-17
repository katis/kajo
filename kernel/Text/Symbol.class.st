"An interned String: one object per spelling, compared by identity. Selectors are Symbols."
Class {
	#name : #Symbol,
	#superclass : #String
}

{ #category : #accessing }
Symbol >> = anObject <Object> ^<Boolean> [
	^ self == anObject
]

{ #category : #accessing }
Symbol >> asString ^<String> [
	^ '' , self
]

{ #category : #accessing }
Symbol >> asSymbol ^<Self> [
	^ self
]

{ #category : #accessing }
Symbol >> displayString ^<String> [
	^ self asString
]

{ #category : #accessing }
Symbol >> hash ^<Integer> [
	<primitive: 122>
	^ self primitiveFailed
]

{ #category : #accessing }
Symbol >> isBinary ^<Boolean> [
	^ self notEmpty and: [(self first isLetter or: [self first = $_]) not]
]

{ #category : #accessing }
Symbol >> isSymbol ^<Boolean> [
	^ true
]

{ #category : #accessing }
Symbol >> keywords ^<Array[String]> [
	"#at:put: -> #('at:' 'put:')"
	| out s |
	self numArgs = 0 ifTrue: [^ Array with: self asString].
	(self first isLetter or: [self first = $_]) ifFalse: [^ Array with: self asString].
	out := OrderedCollection new.
	s := WriteStream on: String new.
	self do: [:c | s nextPut: c. c = $: ifTrue: [out add: s contents. s := WriteStream on: String new]].
	^ out asArray
]

{ #category : #accessing }
Symbol >> numArgs ^<Integer> [
	| first n |
	self isEmpty ifTrue: [^ 0].
	first := self first.
	(first isLetter or: [first = $_]) ifFalse: [^ 1].
	n := 0.
	self do: [:c | c = $: ifTrue: [n := n + 1]].
	^ n
]

{ #category : #accessing }
Symbol >> printOn: aStream [
	| plain |
	plain := self notEmpty and: [self allSatisfy: [:c | c isLetter or: [c isDigit or: [c = $: or: [c = $_]]]]].
	plain := plain and: [self first isDigit not].
	plain := plain or: [self isBinary and: [self allSatisfy: [:c | '+-*/\<>=~&|@%,?!' includes: c]]].
	plain
		ifTrue: [aStream nextPut: $#; nextPutAll: self]
		ifFalse: [aStream nextPut: $#. super printOn: aStream]
]

{ #category : #accessing }
Symbol >> shallowCopy [
	^ self
]

{ #category : #accessing }
Symbol >> species [
	^ String
]

{ #category : #accessing }
Symbol >> value: anObject <Object> ^<Dynamic> [
	^ anObject perform: self
]

{ #category : #accessing }
Symbol >> value: anObject <Object> value: anArgument <Object> ^<Dynamic> [
	^ anObject perform: self with: anArgument
]

{ #category : #accessing }
Symbol class >> intern: aString <String> ^<Symbol> [
	^ aString asSymbol
]

{ #category : #accessing }
Symbol class >> lookup: aString <String> ^<Symbol | Nil> [
	"The Symbol with these bytes, nil if none was interned."
	<primitive: 135>
	^ nil
]

{ #category : #accessing }
Symbol class >> new [
	^ self shouldNotImplement
]

{ #category : #accessing }
Symbol class >> new: n [
	^ self shouldNotImplement
]
