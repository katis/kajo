"Methods the checker's tests check: each rule has one that must check clean (named ok...) and one that must not (named bad...). Never run; only read."
Class {
	#name : #OTSample,
	#superclass : #Object,
	#instVars : [
		'count',
		'items',
		'name'
	]
}

{ #category : #samples }
OTSample >> badArgType [
	^ items at: 'one'
]

{ #category : #samples }
OTSample >> badArity [
	^ items collect: [:a :b | a]
]

{ #category : #samples }
OTSample >> badAssign [
	count := 'many'
]

{ #category : #samples }
OTSample >> badBlockResult [
	^ items select: [:x | x + 1]
]

{ #category : #samples }
OTSample >> badDnu [
	^ count fooBar
]

{ #category : #samples }
OTSample >> badDnuThroughGenerics [
	^ (items collect: [:x | x printString]) first + 1
]

{ #category : #samples }
OTSample >> badInferredDnu [
	^ self okInferred zork
]

{ #category : #samples }
OTSample >> badMaybeNil [
	^ name asUppercase
]

{ #category : #samples }
OTSample >> badReturn [
	^ name
]

{ #category : #samples }
OTSample >> badTempFlow [
	| t |
	t := 3.
	^ t , 'x'
]

{ #category : #samples }
OTSample >> badUnionMember [
	| t |
	t := 3.
	count > 2 ifTrue: [t := 'x'].
	^ t + 1
]

{ #category : #samples }
OTSample >> okArgType [
	^ items at: 1
]

{ #category : #samples }
OTSample >> okArity [
	^ items collect: [:a | a]
]

{ #category : #samples }
OTSample >> okAssign [
	count := 3
]

{ #category : #samples }
OTSample >> okBlockResult [
	^ items select: [:x | x > 1]
]

{ #category : #samples }
OTSample >> okDnu [
	^ count + 1
]

{ #category : #samples }
OTSample >> okGenerics [
	^ (items collect: [:x | x printString]) first , 'x'
]

{ #category : #samples }
OTSample >> okInferred [
	^ 'abc'
]

{ #category : #samples }
OTSample >> okInject [
	^ items inject: 0 into: [:a :x | a + x]
]

{ #category : #samples }
OTSample >> okMaybeNilNarrowed [
	name isNil ifTrue: [^ ''].
	^ name asUppercase
]

{ #category : #samples }
OTSample >> okMaybeNilIfNotNil [
	^ name ifNotNil: [:n | n asUppercase]
]

{ #category : #samples }
OTSample >> okMaybeNilTested [
	^ name notNil and: [name asUppercase size > 2]
]

{ #category : #samples }
OTSample >> okReturn [
	^ count
]

{ #category : #samples }
OTSample >> okSelf [
	^ self yourself
]

{ #category : #samples }
OTSample >> okTempFlow [
	| t |
	t := 3.
	^ t + 4
]

{ #category : #samples }
OTSample >> okUnionMember [
	| t |
	t := 3.
	count > 2 ifTrue: [t := 'x'].
	^ t printString
]

{ #category : #samples }
OTSample >> okOverload [
	^ items at: count + 1
]

{ #category : #samples }
OTSample >> takesNumbers: aCollection [
	^ aCollection
]

{ #category : #samples }
OTSample >> varianceSend [
	^ self takesNumbers: items
]

{ #category : #samples }
OTSample >> okHandler [
	^ [count foo] on: ZeroDivide do: [:e | e dividend]
]

{ #category : #samples }
OTSample >> badHandler [
	^ [count foo] on: ZeroDivide do: [:e | e zork]
]

{ #category : #samples }
OTSample >> okRecursiveBlock [
	| fact |
	fact := [:n | n < 2 ifTrue: [1] ifFalse: [n * (fact value: n - 1)]].
	^ fact value: 5
]

{ #category : #samples }
OTSample >> okNotNilAnd [
	^ (name notNil and: [count > 1]) ifTrue: [name asUppercase] ifFalse: ['']
]

{ #category : #samples }
OTSample >> badNotNilAndElse [
	^ (name notNil and: [count > 1]) ifTrue: [''] ifFalse: [name asUppercase]
]

{ #category : #samples }
OTSample >> okLoopNarrowing [
	| s |
	s := name.
	[s notNil] whileTrue: [s := s asUppercase. s := nil].
	^ count
]
