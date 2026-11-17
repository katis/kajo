"Methods the checker's tests check (TypeCheckerTest; the experiment's OTSample with its side file's types written inline): each rule has one that must check clean (named ok...) and one that must not (named bad...). Never run; only read. Its bad methods are diagnostics of the development image on purpose."
Class {
	#name : #TypeCheckerSample,
	#superclass : #Object,
	#instVars : [
		'count <Integer>',
		'items <OrderedCollection[Integer]>',
		'name <String | Nil>'
	]
}

{ #category : #samples }
TypeCheckerSample >> badAnnotation: x <Intger> ^<Integer> [
	^ 3
]

{ #category : #samples }
TypeCheckerSample >> badArgType [
	^ items at: 'one'
]

{ #category : #samples }
TypeCheckerSample >> badArity [
	^ items collect: [:a :b | a]
]

{ #category : #samples }
TypeCheckerSample >> badAssign [
	count := 'many'
]

{ #category : #samples }
TypeCheckerSample >> badBlockResult [
	^ items select: [:x | x + 1]
]

{ #category : #samples }
TypeCheckerSample >> badDnu [
	^ count fooBar
]

{ #category : #samples }
TypeCheckerSample >> badDnuThroughGenerics [
	^ (items collect: [:x | x printString]) first + 1
]

{ #category : #samples }
TypeCheckerSample >> badHandler [
	^ [count foo] on: ZeroDivide do: [:e | e zork]
]

{ #category : #samples }
TypeCheckerSample >> badIfNotNilBlock [
	^ name ifNotNil: [:n | n zork]
]

{ #category : #samples }
TypeCheckerSample >> badIfNotNilResult ^<String> [
	^ name ifNotNil: [:n | n asUppercase]
]

{ #category : #samples }
TypeCheckerSample >> badInferredDnu [
	^ self okInferred zork
]

{ #category : #samples }
TypeCheckerSample >> badMaybeNil [
	^ name asUppercase
]

{ #category : #samples }
TypeCheckerSample >> badNotNilAndElse [
	^ (name notNil and: [count > 1]) ifTrue: [''] ifFalse: [name asUppercase]
]

{ #category : #samples }
TypeCheckerSample >> badReturn ^<String> [
	^ name
]

{ #category : #samples }
TypeCheckerSample >> badTempFlow [
	| t |
	t := 3.
	^ t , 'x'
]

{ #category : #samples }
TypeCheckerSample >> badUnionMember [
	| t |
	t := 3.
	count > 2 ifTrue: [t := 'x'].
	^ t + 1
]

{ #category : #samples }
TypeCheckerSample >> okArgType [
	^ items at: 1
]

{ #category : #samples }
TypeCheckerSample >> okArity [
	^ items collect: [:a | a]
]

{ #category : #samples }
TypeCheckerSample >> okAssign [
	count := 3
]

{ #category : #samples }
TypeCheckerSample >> okBitAnd ^<Integer> [
	^ 6 bitAnd: 3
]

{ #category : #samples }
TypeCheckerSample >> okBlockResult [
	^ items select: [:x | x > 1]
]

{ #category : #samples }
TypeCheckerSample >> okDnu [
	^ count + 1
]

{ #category : #samples }
TypeCheckerSample >> okGenerics [
	^ (items collect: [:x | x printString]) first , 'x'
]

{ #category : #samples }
TypeCheckerSample >> okHandler [
	^ [count foo] on: ZeroDivide do: [:e | e dividend]
]

{ #category : #samples }
TypeCheckerSample >> okIfNil ^<String> [
	^ name ifNil: ['none']
]

{ #category : #samples }
TypeCheckerSample >> okInferred [
	^ 'abc'
]

{ #category : #samples }
TypeCheckerSample >> okInject [
	^ items inject: 0 into: [:a :x | a + x]
]

{ #category : #samples }
TypeCheckerSample >> okLoopNarrowing [
	| s |
	s := name.
	[s notNil] whileTrue: [s := s asUppercase. s := nil].
	^ count
]

{ #category : #samples }
TypeCheckerSample >> okMaybeNilIfNotNil [
	^ name ifNotNil: [:n | n asUppercase]
]

{ #category : #samples }
TypeCheckerSample >> okMaybeNilNarrowed [
	name isNil ifTrue: [^ ''].
	^ name asUppercase
]

{ #category : #samples }
TypeCheckerSample >> okMaybeNilTested [
	^ name notNil and: [name asUppercase size > 2]
]

{ #category : #samples }
TypeCheckerSample >> okNotNilAnd [
	^ (name notNil and: [count > 1]) ifTrue: [name asUppercase] ifFalse: ['']
]

{ #category : #samples }
TypeCheckerSample >> okOverload [
	^ items at: count + 1
]

{ #category : #samples }
TypeCheckerSample >> okRecursiveBlock [
	| fact |
	fact := [:n | n < 2 ifTrue: [1] ifFalse: [n * (fact value: n - 1)]].
	^ fact value: 5
]

{ #category : #samples }
TypeCheckerSample >> okReturn ^<Integer> [
	^ count
]

{ #category : #samples }
TypeCheckerSample >> okSelf ^<Self> [
	^ self yourself
]

{ #category : #samples }
TypeCheckerSample >> okSignatureWithoutAMethod: anInterval <Interval[Integer]> ^<Array[Integer]> [
	^ anInterval select: [:x | x > 1]
]

{ #category : #samples }
TypeCheckerSample >> okSpecies ^<Self> [
	^ self class new
]

{ #category : #samples }
TypeCheckerSample >> okTempFlow [
	| t |
	t := 3.
	^ t + 4
]

{ #category : #samples }
TypeCheckerSample >> okTypeTest: anObject <Object> ^<Dynamic> [
	(anObject isKindOf: String) ifFalse: [^ 0].
	^ anObject asUppercase
]

{ #category : #samples }
TypeCheckerSample >> okTypeTestOr: anObject <Object> ^<String> [
	^ (anObject isString | anObject isInteger) ifTrue: [anObject printString] ifFalse: ['']
]

{ #category : #samples }
TypeCheckerSample >> okUnionMember [
	| t |
	t := 3.
	count > 2 ifTrue: [t := 'x'].
	^ t printString
]

{ #category : #samples }
TypeCheckerSample >> takesNumbers: aCollection <OrderedCollection[Number]> ^<Self> [
	^ aCollection
]

{ #category : #samples }
TypeCheckerSample >> varianceSend [
	^ self takesNumbers: items
]
