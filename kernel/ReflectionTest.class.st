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
	self assert: (Smalltalk categoryOf: Object) = 'Kernel-Objects'.
	self assert: Object category = 'Kernel-Objects'
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
	self assert: keep size equals: 5
]
