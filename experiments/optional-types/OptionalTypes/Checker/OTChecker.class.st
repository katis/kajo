"The optional type checker of the experiment. It holds the annotations, the switches the experiment measures, the type relations (subtype, join, unify), the inferred results of unannotated methods, and the dependency index from what a method's check read (a signature, an inferred body, a selector looked up) to the methods that read it, so that a change rechecks only those. Switches:
	genericMethods: a signature's own variables (collect:'s X) are inferred at a send; off, they are Dynamic.
	nilStrict: Nil is a type of its own and a send to T | Nil that Nil does not understand is a diagnostic; off, nil belongs to every type.
	overloads: a selector with several signatures takes the first whose arguments fit; off, the last one only.
	covariant: Array[Integer] is an Array[Number]; off (the default), type arguments are invariant with Dynamic as the way out.
	inferReturns: an unannotated method's result is inferred from its body (cached); off, it is Dynamic."
Class {
	#name : #OTChecker,
	#superclass : #Object,
	#instVars : [
		'annotations',
		'genericMethods',
		'nilStrict',
		'overloads',
		'covariant',
		'inferReturns',
		'returnCache',
		'inferring',
		'index',
		'results',
		'recordTypes',
		'cacheIndex'
	]
}

{ #category : #accessing }
OTChecker >> annotations [
	^ annotations
]

{ #category : #accessing }
OTChecker >> annotations: anOTAnnotations [
	annotations := anOTAnnotations.
	self forgetCaches
]

{ #category : #checking }
OTChecker >> check: aSelector in: aBehavior [
	"The result of checking one method (an OTMethodCheck), kept with its dependencies in the index."
	| mc key |
	key := self keyOf: aSelector in: aBehavior.
	mc := OTMethodCheck checker: self behavior: aBehavior selector: aSelector.
	mc run.
	self forget: key.
	results at: key put: mc.
	mc deps do: [:d | (index at: d ifAbsentPut: [Set new]) add: key].
	^ mc
]

{ #category : #checking }
OTChecker >> checkClass: aClass [
	"Every method of the class and of its metaclass; the checks, an OrderedCollection."
	| out |
	out := OrderedCollection new.
	{aClass. aClass class} do: [:b |
		(b selectors asArray sort: [:x :y | x <= y]) do: [:sel | out add: (self check: sel in: b)]].
	^ out
]

{ #category : #accessing }
OTChecker >> covariant [
	^ covariant
]

{ #category : #accessing }
OTChecker >> covariant: aBoolean [
	covariant := aBoolean
]

{ #category : #dependencies }
OTChecker >> dependentsOf: aKey [
	"The keys of the methods whose check read aKey."
	^ (index at: aKey ifAbsent: [#()]) asArray
]

{ #category : #dependencies }
OTChecker >> invalidate: aKey [
	"What a change of aKey (a signature, a body, a selector, a class's variables) makes stale: the inferred results that read it are forgotten, transitively through their own bodies, and the keys of every method whose check read any of them are answered (a Set)."
	| todo seen methods k |
	todo := OrderedCollection with: aKey.
	seen := Set new.
	seen add: aKey.
	methods := Set new.
	[todo isEmpty] whileFalse: [
		k := todo removeFirst.
		(index at: k ifAbsent: [#()]) do: [:mk | methods add: mk].
		(cacheIndex at: k ifAbsent: [#()]) asArray do: [:cm | | bk |
			returnCache removeKey: cm ifAbsent: [nil].
			bk := 'body:' , (self keyOf: cm selector in: cm methodClass).
			(seen includes: bk) ifFalse: [seen add: bk. todo add: bk]]].
	^ methods
]

{ #category : #dependencies }
OTChecker >> recheck: aSetOfKeys [
	"Check again each method named by a key (Class>>selector or Class class>>selector) that still exists; the checks."
	| out |
	out := OrderedCollection new.
	aSetOfKeys do: [:mk | | i cname sel b |
		i := mk indexOfSubstring: '>>'.
		cname := mk copyFrom: 1 to: i - 1.
		sel := (mk copyFrom: i + 2 to: mk byteSize) asSymbol.
		b := (cname endsWith: ' class')
			ifTrue: [(Smalltalk classNamed: (cname copyFrom: 1 to: cname byteSize - 6)) ifNotNil: [:c | c class]]
			ifFalse: [Smalltalk classNamed: cname].
		(b notNil and: [b includesSelector: sel])
			ifTrue: [out add: (self check: sel in: b)]
			ifFalse: [self forget: mk. results removeKey: mk ifAbsent: [nil]]].
	^ out
]

{ #category : #dependencies }
OTChecker >> forget: aMethodKey [
	"Drop a method's old dependencies before it is checked again."
	(results at: aMethodKey ifAbsent: [nil]) ifNotNil: [:old |
		old deps do: [:d | (index at: d ifAbsent: [nil]) ifNotNil: [:s | s remove: aMethodKey ifAbsent: [nil]]]]
]

{ #category : #accessing }
OTChecker >> forgetCaches [
	returnCache := IdentityDictionary new.
	cacheIndex := Dictionary new.
	inferring := IdentitySet new
]

{ #category : #accessing }
OTChecker >> forgetInferredReturnOf: aCompiledMethod [
	returnCache removeKey: aCompiledMethod ifAbsent: [nil]
]

{ #category : #relations }
OTChecker >> signatures: found apply: aSelector from: aBehavior [
	"Whether the signatures found from aBehavior up still describe the method aBehavior runs: not when it runs an override in a class between with no side file of its own (an unannotated override is not assumed to keep its superclass's signature)."
	| impl c d |
	found isNil ifTrue: [^ false].
	impl := aBehavior lookupSelector: aSelector.
	impl isNil ifTrue: [^ true].
	c := impl methodClass theNonMetaClass.
	d := found first.
	^ c == d or: [(c inheritsFrom: d) not or: [(annotations infoFor: c) notNil]]
]

{ #category : #accessing }
OTChecker >> genericMethods [
	^ genericMethods
]

{ #category : #accessing }
OTChecker >> genericMethods: aBoolean [
	genericMethods := aBoolean
]

{ #category : #accessing }
OTChecker >> index [
	^ index
]

{ #category : #inference }
OTChecker >> inferredReturnOf: aCompiledMethod [
	"The result type of an unannotated method from its body, with Self for the receiver; Dynamic while it is being inferred (recursion) or when the switch is off."
	| mc t |
	inferReturns ifFalse: [^ OTType dynamic].
	aCompiledMethod primitive = 0 ifFalse: [^ OTType dynamic].
	(returnCache at: aCompiledMethod ifAbsent: [nil]) ifNotNil: [:r | ^ r].
	(inferring includes: aCompiledMethod) ifTrue: [^ OTType dynamic].
	inferring add: aCompiledMethod.
	[mc := OTMethodCheck checker: self behavior: aCompiledMethod methodClass selector: aCompiledMethod selector.
	 mc beQuiet.
	 mc run.
	 t := mc inferredResult] ensure: [inferring remove: aCompiledMethod ifAbsent: [nil]].
	returnCache at: aCompiledMethod put: t.
	mc deps do: [:d | (cacheIndex at: d ifAbsentPut: [IdentitySet new]) add: aCompiledMethod].
	^ t
]

{ #category : #accessing }
OTChecker >> inferReturns [
	^ inferReturns
]

{ #category : #accessing }
OTChecker >> inferReturns: aBoolean [
	inferReturns := aBoolean
]

{ #category : #relations }
OTChecker >> isClass: a subtypeOf: b [
	| map ps x y |
	(a cls includesBehavior: b cls) ifFalse: [^ false].
	b args isEmpty ifTrue: [^ true].
	a args isEmpty ifTrue: [^ true].
	map := annotations map: a to: b cls.
	ps := annotations paramsOf: b cls.
	1 to: (ps size min: b args size) do: [:i |
		x := map at: (ps at: i) ifAbsent: [OTType dynamic].
		y := b args at: i.
		(covariant
			ifTrue: [self isSubtype: x of: y]
			ifFalse: [(self isSubtype: x of: y) and: [self isSubtype: y of: x]]) ifFalse: [^ false]].
	^ true
]

{ #category : #relations }
OTChecker >> isSubtype: a of: b [
	"Whether a value of type a may be used where b is expected (Dynamic both ways)."
	(a isDynamic or: [b isDynamic]) ifTrue: [^ true].
	(a isNilType and: [nilStrict not]) ifTrue: [^ true].
	a isUnion ifTrue: [^ a members allSatisfy: [:m | self isSubtype: m of: b]].
	b class == OTSelf ifTrue: [^ a class == OTSelf or: [(a isClassType or: [a isMetaType]) and: [a selfKind == #self]]].
	b class == OTInstance ifTrue: [^ a class == OTInstance or: [a isClassType and: [a selfKind == #instance]]].
	(a class == OTSelf or: [a class == OTInstance or: [a class == OTSelfClass or: [b class == OTSelfClass]]]) ifTrue: [^ true].
	(b class == OTVarClass or: [a class == OTVarClass]) ifTrue: [^ a isMetaType or: [a class == OTVarClass or: [a isClassType and: [a cls includesBehavior: Behavior]]]].
	b isUnion ifTrue: [^ b members anySatisfy: [:m | self isSubtype: a of: m]].
	(b isClassType and: [b cls == Object]) ifTrue: [^ true].
	(a isVar or: [b isVar]) ifTrue: [^ a isVar and: [b isVar and: [a name = b name]]].
	a isClassType ifTrue: [
		b isClassType ifTrue: [^ self isClass: a subtypeOf: b].
		b isBlockType ifTrue: [^ a cls includesBehavior: BlockClosure].
		^ false].
	a isBlockType ifTrue: [
		b isClassType ifTrue: [^ BlockClosure includesBehavior: b cls].
		b isBlockType ifTrue: [
			a args size = b args size ifFalse: [^ false].
			1 to: a args size do: [:i | (self isSubtype: (b args at: i) of: (a args at: i)) ifFalse: [^ false]].
			^ self isSubtype: a result of: b result].
		^ false].
	a isMetaType ifTrue: [
		b isMetaType ifTrue: [^ a cls includesBehavior: b cls].
		b isClassType ifTrue: [^ a cls class includesBehavior: b cls].
		^ false].
	^ false
]

{ #category : #relations }
OTChecker >> join: a with: b [
	"The least type that holds both (approximate: a common superclass, else a union of at most three)."
	| c u |
	(a isNil or: [a isUnassigned]) ifTrue: [^ b].
	(b isNil or: [b isUnassigned]) ifTrue: [^ a].
	(a isDynamic or: [b isDynamic]) ifTrue: [^ OTType dynamic].
	(a sameAs: b) ifTrue: [^ a].
	(a isNilType or: [b isNilType]) ifTrue: [^ OTType union: {a. b}].
	(a includesNil or: [b includesNil]) ifTrue: [^ OTType union: {self join: a withoutNil with: b withoutNil. OTType nilType}].
	(self isSubtype: a of: b) ifTrue: [^ b].
	(self isSubtype: b of: a) ifTrue: [^ a].
	(a isClassType and: [b isClassType]) ifTrue: [
		c := a cls.
		[c notNil and: [(b cls includesBehavior: c) not]] whileTrue: [c := c superclass].
		(c notNil and: [c ~~ Object]) ifTrue: [^ OTType of: c]].
	u := OTType union: {a. b}.
	u members size > 3 ifTrue: [^ OTType of: Object].
	^ u
]

{ #category : #checking }
OTChecker >> keyOf: aSelector in: aBehavior [
	^ aBehavior name , '>>' , aSelector
]

{ #category : #accessing }
OTChecker >> nilStrict [
	^ nilStrict
]

{ #category : #accessing }
OTChecker >> nilStrict: aBoolean [
	nilStrict := aBoolean
]

{ #category : #accessing }
OTChecker >> overloads [
	^ overloads
]

{ #category : #accessing }
OTChecker >> overloads: aBoolean [
	overloads := aBoolean
]

{ #category : #accessing }
OTChecker >> recordTypes [
	^ recordTypes
]

{ #category : #accessing }
OTChecker >> recordTypes: aBoolean [
	recordTypes := aBoolean
]

{ #category : #accessing }
OTChecker >> results [
	^ results
]

{ #category : #accessing }
OTChecker >> setUp [
	annotations := OTAnnotations new.
	genericMethods := true.
	nilStrict := true.
	overloads := true.
	covariant := false.
	inferReturns := true.
	recordTypes := false.
	index := Dictionary new.
	results := Dictionary new.
	self forgetCaches
]

{ #category : #relations }
OTChecker >> unify: p with: a vars: aSet into: aDictionary [
	"Bind the method variables aSet names in the parameter type p to what the argument type a gives them."
	| map ps |
	(p class == OTVarClass and: [(aSet includes: p name) and: [a isMetaType]]) ifTrue: [
		aDictionary at: p name put: (self join: (aDictionary at: p name ifAbsent: [nil]) with: (OTType of: a cls)).
		^ self].
	(p isVar and: [aSet includes: p name]) ifTrue: [
		aDictionary at: p name put: (self join: (aDictionary at: p name ifAbsent: [nil]) with: a).
		^ self].
	p isUnion ifTrue: [
		(p members reject: [:m | m isNilType]) do: [:m | self unify: m with: a withoutNil vars: aSet into: aDictionary].
		^ self].
	(p isClassType and: [a isClassType and: [p args notEmpty and: [a cls includesBehavior: p cls]]]) ifTrue: [
		map := annotations map: a to: p cls.
		ps := annotations paramsOf: p cls.
		1 to: (ps size min: p args size) do: [:i |
			self unify: (p args at: i) with: (map at: (ps at: i) ifAbsent: [OTType dynamic]) vars: aSet into: aDictionary].
		^ self].
	(p isBlockType and: [a isBlockType]) ifTrue: [
		1 to: (p args size min: a args size) do: [:i | self unify: (p args at: i) with: (a args at: i) vars: aSet into: aDictionary].
		self unify: p result with: a result vars: aSet into: aDictionary]
]

{ #category : #'instance creation' }
OTChecker class >> new [
	^ self basicNew setUp
]

{ #category : #'instance creation' }
OTChecker class >> on: anOTAnnotations [
	^ self new annotations: anOTAnnotations; yourself
]
