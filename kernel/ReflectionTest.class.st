"Classes, metaclasses, methods and their reading primitives."
Class {
	#name : #ReflectionTest,
	#superclass : #TestCase,
	#category : #'Kernel-Tests'
}

{ #category : #accessing }
ReflectionTest >> testHierarchy [
	self assert: SmallInteger superclass == Integer.
	self assert: (SmallInteger inheritsFrom: Number).
	self assert: (String inheritsFrom: ArrayedCollection).
	self assert: Symbol superclass == String.
	self assert: (Integer allSubclasses includes: LargeNegativeInteger).
	self assert: (Collection subclasses includes: SequenceableCollection).
	self assert: (Smalltalk allClasses includes: TestCase)
]

{ #category : #accessing }
ReflectionTest >> testInstanceVariableNames [
	self assert: (Smalltalk instanceVariableNamesOf: Association) = #(#key #value).
	self assert: (Smalltalk instanceVariableNamesOf: KeyNotFound) = #(#messageText #signalContext #handlerContext #outerContext #key).
	self assert: (Smalltalk instanceVariableNamesOf: Transcript class) = #(#stream #lock).
	self assert: Association allInstVarNames = #(#key #value)
]

{ #category : #accessing }
ReflectionTest >> testMetaclasses [
	self assert: 3 class class class == Metaclass.
	self assert: Object class superclass == Class.
	self assert: Integer class superclass == Number class.
	self assert: Object class class == Metaclass.
	self assert: Object class name = 'Object class'.
	self assert: Object class isMeta.
	self assert: Object class theNonMetaClass == Object
]

{ #category : #accessing }
ReflectionTest >> testMethods [
	| m |
	m := Integer >> #factorial.
	self assert: m selector == #factorial.
	self assert: m methodClass == Integer.
	self assert: m numArgs = 0.
	self assert: m printString = 'Integer>>factorial'.
	self assert: (Integer includesSelector: #factorial).
	self deny: (SmallInteger includesSelector: #factorial).
	self assert: (SmallInteger canUnderstand: #factorial).
	self assert: ((SmallInteger lookupSelector: #factorial) == m).
	self assert: (Object selectors includes: #printString).
	self assert: (BlockClosure >> #ensure:) hasUnwindMark.
	self assert: (BlockClosure >> #privateOn:do:) hasHandlerMark
]

{ #category : #accessing }
ReflectionTest >> testSmalltalk [
	self assert: (Smalltalk at: #Object) == Object.
	self assert: (Smalltalk at: #NoSuchClass ifAbsent: [nil]) isNil.
	self assert: (Smalltalk packageOf: Object) = 'Kernel'.
	self assert: (Smalltalk tagOf: Object) == #Objects.
	self assert: (Smalltalk class includesSelector: #categoryOf:) not
]

{ #category : #instances }
ReflectionTest >> testAClassWithNoInstancesAnswersAnEmptyArray [
	Smalltalk garbageCollect.
	self assert: ReflectionTestSubProbe allInstances equals: #().
	self assert: ReflectionTestSubProbe instanceCount equals: 0
]

{ #category : #instances }
ReflectionTest >> testAFreshInstanceAppearsAndADroppedOneDisappears [
	| p n |
	Smalltalk garbageCollect.
	n := ReflectionTestProbe instanceCount.
	p := ReflectionTestProbe new.
	self assert: (ReflectionTestProbe allInstances identityIncludes: p).
	self assert: ReflectionTestProbe instanceCount equals: n + 1.
	p := nil.
	Smalltalk garbageCollect.
	self assert: ReflectionTestProbe instanceCount equals: n
]

{ #category : #instances }
ReflectionTest >> testAllSubInstancesIncludesASubclasssInstance [
	| p s |
	p := ReflectionTestProbe new.
	s := ReflectionTestSubProbe new.
	self assert: (ReflectionTestProbe allSubInstances identityIncludes: p).
	self assert: (ReflectionTestProbe allSubInstances identityIncludes: s).
	self deny: (ReflectionTestProbe allInstances identityIncludes: s).
	self assert: (ReflectionTestSubProbe allSubInstances identityIncludes: s).
	self deny: (ReflectionTestSubProbe allSubInstances identityIncludes: p)
]

{ #category : #instances }
ReflectionTest >> testTheCountEqualsTheSizeUnderTheLimit [
	| keep |
	keep := (1 to: 5) collect: [:i | ReflectionTestProbe new].
	self assert: ReflectionTestProbe allInstances size equals: ReflectionTestProbe instanceCount.
	self assert: ReflectionTestProbe instanceCount >= keep size
]

{ #category : #instances }
ReflectionTest >> testTheImmediatesAndTheSingletons [
	"SmallInteger, SmallFloat and Character have no instances in the heap; nil, true and false are their classes' one instance."
	self assert: SmallInteger allInstances equals: #().
	self assert: SmallFloat allInstances equals: #().
	self assert: Character allInstances equals: #().
	self assert: SmallInteger instanceCount equals: 0.
	self assert: UndefinedObject allInstances equals: {nil}.
	self assert: True allInstances equals: {true}.
	self assert: False allInstances equals: {false}
]

{ #category : #instances }
ReflectionTest >> testTheLimitHolds [
	| keep |
	keep := (1 to: 5) collect: [:i | ReflectionTestProbe new].
	self assert: (ReflectionTestProbe allInstances: 3) size equals: 3.
	self assert: (ReflectionTestProbe allInstances: 0) equals: #().
	self assert: ((ReflectionTestProbe allInstances: 3) allSatisfy: [:e | e class == ReflectionTestProbe]).
	self should: [ReflectionTestProbe allInstances: -1] raise: Error.
	self should: [ReflectionTestProbe allInstances: 16777216] raise: Error.
	self should: [ReflectionTestProbe allInstances: nil] raise: Error.
	"No default limit: allInstances is every instance."
	self assert: ReflectionTestProbe allInstances size equals: (ReflectionTestProbe allInstances: 16777215) size.
	self assert: keep size equals: 5
]

{ #category : #pointers }
ReflectionTest >> testADroppedReferenceDisappearsAfterACollection [
	| o a |
	o := ReflectionTestProbe new.
	a := Array with: o.
	self assert: o pointerCount equals: 1.
	a := nil.
	Smalltalk garbageCollect.
	self assert: o pointerCount equals: 0
]

{ #category : #pointers }
ReflectionTest >> testALargeHolderIsFound [
	| o a |
	o := ReflectionTestProbe new.
	a := Array new: 10000.
	a at: 10000 put: o.
	self assert: o pointersTo size equals: 1.
	self assert: o pointersTo first == a
]

{ #category : #pointers }
ReflectionTest >> testAWeakHolderIsFound [
	| o w |
	o := ReflectionTestProbe new.
	w := WeakArray new: 2.
	w at: 2 put: o.
	self assert: (o pointersTo identityIncludes: w)
]

{ #category : #pointers }
ReflectionTest >> testAnImmediateHasHolders [
	| a |
	a := Array with: 3.
	self assert: (3 pointersTo: 1) notEmpty.
	self assert: (3 pointersTo identityIncludes: a)
]

{ #category : #pointers }
ReflectionTest >> testAnObjectHeldByOneArrayAnswersThatArray [
	| o a |
	o := ReflectionTestProbe new.
	a := Array with: o.
	self assert: o pointersTo size equals: 1.
	self assert: o pointersTo first == a
]

{ #category : #pointers }
ReflectionTest >> testAnObjectHeldOnlyByATemporaryAnswersNothing [
	"Process stacks are not in the heap: a temporary is no holder."
	| o |
	o := ReflectionTestProbe new.
	self assert: o pointersTo equals: #().
	self assert: o pointerCount equals: 0
]

{ #category : #pointers }
ReflectionTest >> testTheHolderOfAMethodLiteralIsTheMethod [
	| holders |
	"The Symbol below is a literal of this method only: its holders are the method (its literal frame is not listed) and the symbol table."
	holders := #aLiteralOfThisTestOnly pointersTo.
	self assert: (holders identityIncludes: ReflectionTest >> #testTheHolderOfAMethodLiteralIsTheMethod).
	self deny: (holders identityIncludes: (ReflectionTest >> #testTheHolderOfAMethodLiteralIsTheMethod) literals)
]

{ #category : #pointers }
ReflectionTest >> testThePointerCountEqualsTheSizeUnderTheLimit [
	| o keep |
	o := ReflectionTestProbe new.
	keep := (1 to: 5) collect: [:i | Array with: o].
	"The block's closure holds o as well until a collection frees it."
	self assert: o pointersTo size equals: o pointerCount.
	self assert: o pointerCount >= 5
]

{ #category : #pointers }
ReflectionTest >> testThePointerLimitHolds [
	| o keep |
	o := ReflectionTestProbe new.
	keep := (1 to: 5) collect: [:i | Array with: o].
	self assert: (o pointersTo: 3) size equals: 3.
	self assert: (o pointersTo: 0) equals: #().
	self should: [o pointersTo: -1] raise: Error.
	self should: [o pointersTo: 16777216] raise: Error.
	self should: [o pointersTo: nil] raise: Error.
	"No default limit: pointersTo is every holder."
	self assert: o pointersTo size equals: (o pointersTo: 16777215) size.
	self assert: keep size equals: 5
]

{ #category : #pointers }
ReflectionTest >> testThePointersAnswerIsNotItsOwnElement [
	| a |
	a := nil pointersTo: 1000.
	self deny: (a identityIncludes: a).
	a := Array new: 1.
	a at: 1 put: a.
	self assert: (a pointersTo identityIncludes: a)
]
