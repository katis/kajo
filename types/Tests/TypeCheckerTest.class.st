"The checker's rules on the types the image writes (Types 2; the experiment's OTCheckerTest, whose 24 tests read a side file of their own): each rule with a method of TypeCheckerSample that must check clean and one that must not, each diagnostic kind, each switch, the type notation, the dependency index and a recheck; and Types 2's own: Self in an argument place with an overload, a SmallInteger sum, a signature without a method found by the lookup, a narrowing signature, a signature nothing answers, and the class side's self class new."
Class {
	#name : #TypeCheckerTest,
	#superclass : #TestCase,
	#instVars : [
		'checker'
	]
}

{ #category : #helpers }
TypeCheckerTest >> kindsOf: aSelector [
	^ self kindsOf: aSelector in: TypeCheckerSample
]

{ #category : #helpers }
TypeCheckerTest >> kindsOf: aSelector in: aClass [
	^ ((checker check: aSelector in: aClass) diagnostics collect: [:d | d kind]) asArray
]

{ #category : #helpers }
TypeCheckerTest >> resultOf: aString bindings: anArray [
	"The type of a workspace expression with typed variables ({name. type text} pairs), printed."
	| d mc |
	d := Dictionary new.
	1 to: anArray size by: 2 do: [:i | d at: (anArray at: i) put: (checker table typeOfText: (anArray at: i + 1) params: #())].
	mc := checker checkSource: aString named: 'test' bindings: d.
	self assert: mc diagnostics isEmpty description: aString , ': ' , mc diagnostics printString.
	^ mc inferredResult printString
]

{ #category : #running }
TypeCheckerTest >> setUp [
	checker := TypeChecker new
]

{ #category : #tests }
TypeCheckerTest >> testArgType [
	self assert: (self kindsOf: #okArgType) equals: #().
	self assert: (self kindsOf: #badArgType) equals: #(#argType)
]

{ #category : #tests }
TypeCheckerTest >> testArity [
	self assert: (self kindsOf: #okArity) equals: #().
	self assert: (self kindsOf: #badArity) equals: #(#arity)
]

{ #category : #tests }
TypeCheckerTest >> testAssign [
	self assert: (self kindsOf: #okAssign) equals: #().
	self assert: (self kindsOf: #badAssign) equals: #(#assignType)
]

{ #category : #tests }
TypeCheckerTest >> testBadTypesAreDiagnostics [
	"A type that names no class is an #annotation diagnostic of its method, and the rest of the method is checked."
	self assert: (self kindsOf: #badAnnotation:) equals: #(#annotation).
	self should: [checker table typeOfText: 'Intger' params: #()] raise: CompileError.
	self should: [checker table typeOfText: 'Array[E' params: #()] raise: CompileError
]

{ #category : #tests }
TypeCheckerTest >> testBlockResult [
	self assert: (self kindsOf: #okBlockResult) equals: #().
	self assert: (self kindsOf: #badBlockResult) equals: #(#blockResult)
]

{ #category : #tests }
TypeCheckerTest >> testCovariantSwitch [
	self assert: (self kindsOf: #varianceSend) equals: #(#argType).
	checker covariant: true.
	self assert: (self kindsOf: #varianceSend) equals: #()
]

{ #category : #tests }
TypeCheckerTest >> testDependentsAndRecheck [
	| mc |
	mc := checker check: #okGenerics in: TypeCheckerSample.
	self assert: (mc deps anySatisfy: [:d | d beginsWith: 'sig:']).
	mc deps do: [:d | self assert: ((checker dependentsOf: d) includes: 'TypeCheckerSample>>okGenerics')].
	self deny: ((checker dependentsOf: 'sig:Collection>>inject:into:') includes: 'TypeCheckerSample>>okGenerics').
	checker check: #badInferredDnu in: TypeCheckerSample.
	self assert: ((checker dependentsOf: 'body:TypeCheckerSample>>okInferred') includes: 'TypeCheckerSample>>badInferredDnu').
	self assert: ((checker recheck: (checker invalidate: 'body:TypeCheckerSample>>okInferred')) collect: [:c | c key]) asArray equals: #('TypeCheckerSample>>badInferredDnu')
]

{ #category : #tests }
TypeCheckerTest >> testDnu [
	self assert: (self kindsOf: #okDnu) equals: #().
	self assert: (self kindsOf: #badDnu) equals: #(#dnu)
]

{ #category : #tests }
TypeCheckerTest >> testFlow [
	self assert: (self kindsOf: #okRecursiveBlock) equals: #().
	self assert: (self kindsOf: #okNotNilAnd) equals: #().
	self assert: (self kindsOf: #badNotNilAndElse) equals: #(#maybeNil).
	self assert: (self kindsOf: #okLoopNarrowing) equals: #()
]

{ #category : #tests }
TypeCheckerTest >> testGenericMethods [
	self assert: (self kindsOf: #okGenerics) equals: #().
	self assert: (self kindsOf: #badDnuThroughGenerics) equals: #(#dnu).
	self assert: (self kindsOf: #okInject) equals: #().
	checker genericMethods: false.
	self assert: (self kindsOf: #badDnuThroughGenerics) = #() description: 'without generic methods collect: answers Collection[Dynamic]'
]

{ #category : #tests }
TypeCheckerTest >> testHandlerArgumentFromTheExceptionClass [
	self assert: (self kindsOf: #okHandler) equals: #(#dnu).
	self assert: ((checker check: #badHandler in: TypeCheckerSample) diagnostics collect: [:d | d text]) asArray
		equals: #('Integer does not understand #foo' 'ZeroDivide does not understand #zork')
]

{ #category : #tests }
TypeCheckerTest >> testIfNotNilBySignaturesAlone [
	"The ifNil: family typed member by member from three signatures each on Object (with Self) and UndefinedObject (with Dynamic), stated over the image's own (the table's overlay), no T - Nil operator and no rule of the checker's own."
	#('ifNotNil: aBlock <[Self, ^:R]> ^<R>' 'ifNil: aBlock <[^:R]> ^<Self>' 'ifNil: aBlock <[^:R]> ifNotNil: notNilBlock <[Self, ^:S]> ^<S>')
		do: [:t | checker table addSignature: t in: Object].
	#('ifNotNil: aBlock <Dynamic> ^<Nil>' 'ifNil: aBlock <[^:R]> ^<R>' 'ifNil: aBlock <[^:R]> ifNotNil: notNilBlock <Dynamic> ^<R>')
		do: [:t | checker table addSignature: t in: UndefinedObject].
	checker memberwiseNil: true.
	self assert: (self kindsOf: #okMaybeNilIfNotNil) equals: #().
	self assert: (self kindsOf: #okIfNil) equals: #().
	self assert: ((checker check: #badIfNotNilBlock in: TypeCheckerSample) diagnostics collect: [:d | d text]) asArray equals: #('String does not understand #zork').
	self assert: ((checker check: #badIfNotNilResult in: TypeCheckerSample) diagnostics collect: [:d | d text]) asArray equals: #('answers String | Nil where String is declared')
]

{ #category : #tests }
TypeCheckerTest >> testInferredReturns [
	self assert: (self kindsOf: #badInferredDnu) equals: #(#dnu).
	checker inferReturns: false; forgetCaches.
	self assert: (self kindsOf: #badInferredDnu) equals: #()
]

{ #category : #tests }
TypeCheckerTest >> testMaybeNil [
	self assert: (self kindsOf: #badMaybeNil) equals: #(#maybeNil).
	self assert: (self kindsOf: #okMaybeNilNarrowed) equals: #().
	self assert: (self kindsOf: #okMaybeNilIfNotNil) equals: #().
	self assert: (self kindsOf: #okMaybeNilTested) equals: #().
	checker nilStrict: false.
	self assert: (self kindsOf: #badMaybeNil) equals: #()
]

{ #category : #tests }
TypeCheckerTest >> testOverloads [
	self assert: (self kindsOf: #okOverload) equals: #().
	checker overloads: false.
	self assert: (self kindsOf: #okOverload) equals: #(#argType)
]

{ #category : #tests }
TypeCheckerTest >> testReturn [
	self assert: (self kindsOf: #okReturn) equals: #().
	self assert: (self kindsOf: #badReturn) equals: #(#returnType).
	self assert: (self kindsOf: #okSelf) equals: #()
]

{ #category : #tests }
TypeCheckerTest >> testSendCounts [
	| mc |
	mc := checker check: #okGenerics in: TypeCheckerSample.
	self assert: mc sends equals: 4.
	self assert: mc knownSends equals: 4.
	self assert: mc typedSends equals: 4
]

{ #category : #tests }
TypeCheckerTest >> testSubtyping [
	| t |
	t := [:s | checker table typeOfText: s params: #('E')].
	self assert: (checker isSubtype: (t value: 'SmallInteger') of: (t value: 'Number')).
	self deny: (checker isSubtype: (t value: 'String') of: (t value: 'Number')).
	self assert: (checker isSubtype: (t value: 'Nil') of: (t value: 'String | Nil')).
	self deny: (checker isSubtype: (t value: 'String | Nil') of: (t value: 'String')).
	self assert: (checker isSubtype: (t value: 'OrderedCollection[Integer]') of: (t value: 'SequenceableCollection[Integer]')).
	self deny: (checker isSubtype: (t value: 'OrderedCollection[Integer]') of: (t value: 'OrderedCollection[Number]')).
	self assert: (checker isSubtype: (t value: 'OrderedCollection[Dynamic]') of: (t value: 'OrderedCollection[Number]')).
	self assert: (checker isSubtype: (t value: '[Object, ^Integer]') of: (t value: '[Integer, ^Number]')).
	self deny: (checker isSubtype: (t value: '[Integer, ^Integer]') of: (t value: '[Object, ^Integer]')).
	self assert: (checker isSubtype: (t value: 'String class') of: (t value: 'Collection class')).
	self assert: (checker isSubtype: (t value: 'String class') of: (t value: 'Behavior'))
]

{ #category : #tests }
TypeCheckerTest >> testTempFlow [
	self assert: (self kindsOf: #okTempFlow) equals: #().
	self assert: (self kindsOf: #badTempFlow) equals: #(#dnu)
]

{ #category : #tests }
TypeCheckerTest >> testTypeNotation [
	#('Integer' 'Array[E]' 'Dictionary[K, V]' 'String class' 'Integer | Nil' '[E, ^Boolean]' '[^E]' 'Self' 'Instance' 'Instance[E]' 'Dynamic' 'Nil')
		do: [:s | self assert: (checker table typeOfText: s params: #('E' 'K' 'V')) printString equals: s].
	self assert: (checker table typeOfText: '(Integer | Nil) | String' params: #()) printString equals: 'Integer | String | Nil'
]

{ #category : #tests }
TypeCheckerTest >> testTypeTests [
	self assert: (self kindsOf: #okTypeTest:) equals: #().
	self assert: (self kindsOf: #okTypeTestOr:) equals: #().
	checker typeTests: false.
	self assert: (self kindsOf: #okTypeTest:) equals: #(#dnu)
]

{ #category : #tests }
TypeCheckerTest >> testTypesAreReadFromTheImage [
	self assert: (checker table typedClass: Collection) params equals: #('E').
	self assert: ((checker table signaturesFor: #+ from: SmallInteger) last size) equals: 2.
	self assert: (checker table ivarTypeOf: 'name' in: TypeCheckerSample) printString equals: 'String | Nil'.
	self assert: ((checker table signaturesFor: #+ from: Integer) first) equals: Number
]

{ #category : #tests }
TypeCheckerTest >> testUnionMembers [
	self assert: (self kindsOf: #okUnionMember) equals: #().
	self assert: (self kindsOf: #badUnionMember) equals: #(#dnu)
]

{ #category : #'tests-types 2' }
TypeCheckerTest >> testANarrowingSignatureIsCheckedAgainstWhatItNarrows [
	| texts |
	"an argument narrowed is allowed (Number's comparisons narrow Magnitude's)"
	self assert: (self kindsOf: #okTypeTest: in: TypeCheckerNarrowSample) equals: #().
	self assert: (self kindsOf: #< in: Number) equals: #().
	"a result that is not the inherited one's contradicts it"
	texts := ((checker check: #okReturn in: TypeCheckerNarrowSample) diagnostics collect: [:d | d kind -> d text]) asArray.
	self assert: texts size equals: 1.
	self assert: texts first key equals: #signature.
	self assert: (texts first value includesSubstring: 'answers String, not a Integer') description: texts first value.
	"a signature that nothing answers"
	self assert: (self kindsOf: #zork in: TypeCheckerNarrowSample) equals: #(#signature)
]

{ #category : #'tests-types 2' }
TypeCheckerTest >> testASignatureWithoutAMethodIsFoundByTheLookup [
	"Integer>>bitAnd: and Interval>>select: are signatures without a method; the lookup takes them as it takes a typed method, and the methods that answer them are checked against them."
	self assert: ((checker table signaturesFor: #bitAnd: from: Integer) last first kind) equals: #signature.
	self assert: (self kindsOf: #okBitAnd) equals: #().
	self assert: (self kindsOf: #okSignatureWithoutAMethod:) equals: #().
	self assert: (self resultOf: '7 bitAnd: 3' bindings: #()) equals: 'Integer'.
	self assert: (self resultOf: 'i select: [:x | x > 1]' bindings: #('i' 'Interval[Integer]')) equals: 'Array[Integer]'.
	self assert: (self resultOf: 'a collect: [:x | x printString]' bindings: #('a' 'Array[Integer]')) equals: 'Array[String]'.
	self assert: (self resultOf: '(Array new: 3) at: 1' bindings: #()) equals: 'Dynamic'.
	"a signature without a method is checked as itself: answered by SmallInteger's and the large integers' methods"
	self assert: (self kindsOf: #bitAnd: in: Integer) equals: #()
]

{ #category : #'tests-types 2' }
TypeCheckerTest >> testASmallIntegerSumIsAnIntegerNotASmallInteger [
	"SmallInteger's own method says <Integer; Number> ^<Integer; Number>: a sum can change class."
	self assert: (self resultOf: 's + 1' bindings: #('s' 'SmallInteger')) equals: 'Integer'.
	self assert: (self resultOf: 's + 1.5' bindings: #('s' 'SmallInteger')) equals: 'Number'.
	self assert: (self resultOf: 's negated' bindings: #('s' 'SmallInteger')) equals: 'Integer'
]

{ #category : #'tests-types 2' }
TypeCheckerTest >> testSelfClassNewIsSelf [
	"On the instance side, self class new is an instance of the receiver's class, Self (the experiment's limit 'self class new is Instance, not Self')."
	self assert: (self kindsOf: #okSpecies) equals: #()
]

{ #category : #'tests-types 2' }
TypeCheckerTest >> testSelfInAnArgumentPlaceWithAnOverload [
	"Number >> + aNumber <Self; Number> ^<Self; Number>: Self is the receiver's type, in the argument's place too, so an Integer and an Integer is an Integer and anything else a Number."
	self assert: (self resultOf: '3 + 4' bindings: #()) equals: 'Integer'.
	self assert: (self resultOf: '3 + 4.5' bindings: #()) equals: 'Number'.
	self assert: (self resultOf: 'i + 4' bindings: #('i' 'Integer')) equals: 'Integer'.
	self assert: (self resultOf: 'i + 4.5' bindings: #('i' 'Integer')) equals: 'Number'.
	self assert: (self resultOf: 'f + 1.5' bindings: #('f' 'Float')) equals: 'Float'.
	self assert: (self resultOf: 'm max: 3' bindings: #('m' 'Integer')) equals: 'Integer'
]
