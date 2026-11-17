"The checker's rules, each with a method that must check clean and one that must not (OTSample), each diagnostic kind, each switch, the type notation and the side-file reader, the dependency index and a recheck."
Class {
	#name : #OTCheckerTest,
	#superclass : #TestCase,
	#instVars : [
		'checker'
	]
}

{ #category : #helpers }
OTCheckerTest >> annotationText [
	^ 'class OTSample
ivar count <Integer>
ivar items <OrderedCollection[Integer]>
ivar name <String | Nil>
method badReturn ^<String>
method okReturn ^<Integer>
method okSelf ^<Self>
method takesNumbers: <OrderedCollection[Number]> ^<Self>
method okTypeTest: <Object> ^<Dynamic>
method okTypeTestOr: <Object> ^<String>
class BlockClosure
method on: <X class | ExceptionSet> do: <[X, ^Dynamic]> ^<Dynamic>
method value: <Object> ^<Dynamic>
class ZeroDivide
method dividend ^<Number>
class Object
method yourself ^<Self>
method printString ^<String>
method isKindOf: <Behavior> ^<Boolean>
method isString ^<Boolean>
method isInteger ^<Boolean>
class Boolean
method ifTrue: <[^X]> ^<X | Nil>
method ifTrue: <[^X]> ifFalse: <[^Y]> ^<X | Y>
method | <Boolean> ^<Boolean>
method and: <[^Boolean]> ^<Boolean>
class Collection[E]
method collect: <[E, ^X]> ^<Collection[X]>
method select: <[E, ^Boolean]> ^<Self>
method inject: <A> into: <[A, E, ^A]> ^<A>
class SequenceableCollection[E]
method at: <Integer> ^<E>
method first ^<E>
method collect: <[E, ^X]> ^<SequenceableCollection[X]>
class OrderedCollection[E]
class Magnitude
method > <Magnitude> ^<Boolean>
class Number
method + <Number> ^<Number>
class Integer
method + <Integer> ^<Integer>
method + <Number> ^<Number>
class String
method , <String> ^<String>
method size ^<Integer>
method asUppercase ^<String>
'
]

{ #category : #helpers }
OTCheckerTest >> kindsOf: aSelector [
	^ ((checker check: aSelector in: OTSample) diagnostics collect: [:d | d kind]) asArray
]

{ #category : #running }
OTCheckerTest >> setUp [
	checker := OTChecker on: (OTAnnotations fromString: self annotationText)
]

{ #category : #tests }
OTCheckerTest >> testAnnotationsRead [
	self assert: checker annotations errors isEmpty.
	self assert: (checker annotations infoFor: Collection) params equals: #('E').
	self assert: ((checker annotations signaturesFor: #+ meta: false from: SmallInteger) last size) equals: 2.
	self assert: (checker annotations ivarTypeOf: 'name' in: OTSample) printString equals: 'String | Nil'
]

{ #category : #tests }
OTCheckerTest >> testArgType [
	self assert: (self kindsOf: #okArgType) equals: #().
	self assert: (self kindsOf: #badArgType) equals: #(#argType)
]

{ #category : #tests }
OTCheckerTest >> testArity [
	self assert: (self kindsOf: #okArity) equals: #().
	self assert: (self kindsOf: #badArity) equals: #(#arity)
]

{ #category : #tests }
OTCheckerTest >> testAssign [
	self assert: (self kindsOf: #okAssign) equals: #().
	self assert: (self kindsOf: #badAssign) equals: #(#assignType)
]

{ #category : #tests }
OTCheckerTest >> testBadAnnotationsAreDiagnostics [
	| a |
	a := OTAnnotations fromString: 'class OTSample
ivar nosuch <Integer>
method foo: <Intger> ^<Integer>
method bar ^<Integer
whatever x
class NoSuchClass
method ok ^<Integer>'.
	self assert: (a errors collect: [:d | d kind]) asArray equals: #(#annotation #annotation #annotation #annotation #annotation).
	self assert: (a errors collect: [:d | d line]) asArray equals: #(2 3 4 5 6).
	self assert: ((a infoFor: OTSample) methods includesKey: #ok)
]

{ #category : #tests }
OTCheckerTest >> testBlockResult [
	self assert: (self kindsOf: #okBlockResult) equals: #().
	self assert: (self kindsOf: #badBlockResult) equals: #(#blockResult)
]

{ #category : #tests }
OTCheckerTest >> testCovariantSwitch [
	self assert: (self kindsOf: #varianceSend) equals: #(#argType).
	checker covariant: true.
	self assert: (self kindsOf: #varianceSend) equals: #()
]

{ #category : #tests }
OTCheckerTest >> testDependentsAndRecheck [
	| deps |
	checker checkClass: OTSample.
	self deny: ((checker dependentsOf: 'sig:Collection>>collect:') includes: 'OTSample>>okGenerics').
	deps := checker dependentsOf: 'sig:SequenceableCollection>>collect:'.
	self assert: (deps includes: 'OTSample>>okGenerics').
	self assert: (deps includes: 'OTSample>>badDnuThroughGenerics').
	self deny: (deps includes: 'OTSample>>okAssign').
	self assert: ((checker dependentsOf: 'body:OTSample>>okInferred') includes: 'OTSample>>badInferredDnu')
]

{ #category : #tests }
OTCheckerTest >> testDnu [
	self assert: (self kindsOf: #okDnu) equals: #().
	self assert: (self kindsOf: #badDnu) equals: #(#dnu)
]

{ #category : #tests }
OTCheckerTest >> testGenericMethods [
	self assert: (self kindsOf: #okGenerics) equals: #().
	self assert: (self kindsOf: #badDnuThroughGenerics) equals: #(#dnu).
	self assert: (self kindsOf: #okInject) equals: #().
	checker genericMethods: false.
	self assert: (self kindsOf: #badDnuThroughGenerics) = #() description: 'without generic methods collect: answers Collection[Dynamic]'
]

{ #category : #tests }
OTCheckerTest >> testInferredReturns [
	self assert: (self kindsOf: #badInferredDnu) equals: #(#dnu).
	checker inferReturns: false; forgetCaches.
	self assert: (self kindsOf: #badInferredDnu) equals: #()
]

{ #category : #tests }
OTCheckerTest >> testMaybeNil [
	self assert: (self kindsOf: #badMaybeNil) equals: #(#maybeNil).
	self assert: (self kindsOf: #okMaybeNilNarrowed) equals: #().
	self assert: (self kindsOf: #okMaybeNilIfNotNil) equals: #().
	self assert: (self kindsOf: #okMaybeNilTested) equals: #().
	checker nilStrict: false.
	self assert: (self kindsOf: #badMaybeNil) equals: #()
]

{ #category : #tests }
OTCheckerTest >> testOverloads [
	self assert: (self kindsOf: #okOverload) equals: #().
	checker overloads: false.
	self assert: (self kindsOf: #okOverload) equals: #(#argType)
]

{ #category : #tests }
OTCheckerTest >> testReturn [
	self assert: (self kindsOf: #okReturn) equals: #().
	self assert: (self kindsOf: #badReturn) equals: #(#returnType).
	self assert: (self kindsOf: #okSelf) equals: #()
]

{ #category : #tests }
OTCheckerTest >> testSendCounts [
	| mc |
	mc := checker check: #okGenerics in: OTSample.
	self assert: mc sends equals: 4.
	self assert: mc knownSends equals: 4.
	self assert: mc typedSends equals: 4
]

{ #category : #tests }
OTCheckerTest >> testTempFlow [
	self assert: (self kindsOf: #okTempFlow) equals: #().
	self assert: (self kindsOf: #badTempFlow) equals: #(#dnu)
]

{ #category : #tests }
OTCheckerTest >> testTypeNotation [
	#('Integer' 'Array[E]' 'Dictionary[K, V]' 'String class' 'Integer | Nil' '[E, ^Boolean]' '[^X]' 'Self' 'Instance' 'Instance[E]' 'Dynamic' 'Nil')
		do: [:s | self assert: (OTTypeParser parse: s params: #('E' 'K' 'V')) printString equals: s].
	self assert: (OTTypeParser parse: '(Integer | Nil) | String') printString equals: 'Integer | String | Nil'.
	self should: [OTTypeParser parse: 'Intger'] raise: CompileError.
	self should: [OTTypeParser parse: 'Array[E'] raise: CompileError
]

{ #category : #tests }
OTCheckerTest >> testUnionMembers [
	self assert: (self kindsOf: #okUnionMember) equals: #().
	self assert: (self kindsOf: #badUnionMember) equals: #(#dnu)
]

{ #category : #tests }
OTCheckerTest >> testSubtyping [
	| t |
	t := [:s | OTTypeParser parse: s params: #('E')].
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
OTCheckerTest >> testHandlerArgumentFromTheExceptionClass [
	self assert: (self kindsOf: #okHandler) equals: #(#dnu).
	self assert: ((checker check: #badHandler in: OTSample) diagnostics collect: [:d | d text]) asArray
		equals: #('Integer does not understand #foo' 'ZeroDivide does not understand #zork')
]

{ #category : #tests }
OTCheckerTest >> testFlow [
	self assert: (self kindsOf: #okRecursiveBlock) equals: #().
	self assert: (self kindsOf: #okNotNilAnd) equals: #().
	self assert: (self kindsOf: #badNotNilAndElse) equals: #(#maybeNil).
	self assert: (self kindsOf: #okLoopNarrowing) equals: #()
]

{ #category : #tests }
OTCheckerTest >> testTypeTests [
	self assert: (self kindsOf: #okTypeTest:) equals: #().
	self assert: (self kindsOf: #okTypeTestOr:) equals: #().
	checker typeTests: false.
	self assert: (self kindsOf: #okTypeTest:) equals: #(#dnu)
]
