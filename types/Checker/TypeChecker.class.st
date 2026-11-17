"The type checker (Types 2, docs/modules/types-2.md; the experiment's OTChecker). Diagnostics only: it never refuses a method and the VM never sees a type. It holds the type table (what the image's methods, signatures and class definitions say, TypeTable), the switches the experiment measured, the type relations (subtype, join, unify), the inferred results of unannotated methods, and the dependency index from what a method's check read (a signature, an inferred body, a selector looked up) to the methods that read it, so that a change rechecks only those. Per method it keeps only its diagnostics and its dependency keys (results: key to {diagnostics. keys}), not the experiment's whole check record. Switches:
	genericMethods: a signature's own variables (collect:'s X) are inferred at a send; off, they are Dynamic.
	nilStrict: Nil is a type of its own and a send to T | Nil that Nil does not understand is a diagnostic; off, nil belongs to every type.
	overloads: a selector with several signatures takes the first whose arguments fit; off, the last one only.
	covariant: Array[Integer] is an Array[Number]; off (the default), type arguments are invariant with Dynamic as the way out.
	inferReturns: an unannotated method's result is inferred from its body (cached); off, it is Dynamic.
	typeTests: a type test of a variable (v isKindOf: C, v isString, v isInteger | v isFraction) narrows it in the branch it guards; off, only nil tests do."
Class {
	#name : #TypeChecker,
	#superclass : #Object,
	#instVars : [
		'table',
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
		'cacheIndex',
		'typeTests',
		'counts',
		'memberwiseNil',
		'doits',
		'doitChecks',
		'genericClasses'
	]
}

{ #category : #accessing }
TypeChecker >> count: aKey [
	counts at: aKey put: (counts at: aKey ifAbsent: [0]) + 1
]

{ #category : #accessing }
TypeChecker >> counts [
	^ counts
]

{ #category : #accessing }
TypeChecker >> covariant [
	^ covariant
]

{ #category : #accessing }
TypeChecker >> covariant: aBoolean [
	covariant := aBoolean
]

{ #category : #accessing }
TypeChecker >> forgetCaches [
	returnCache := Dictionary new.
	cacheIndex := Dictionary new.
	inferring := Set new
]

{ #category : #accessing }
TypeChecker >> forgetInferredReturnOf: aKey [
	returnCache removeKey: aKey ifAbsent: [nil]
]

{ #category : #accessing }
TypeChecker >> genericClasses [
	^ genericClasses
]

{ #category : #accessing }
TypeChecker >> genericClasses: aBoolean [
	"Off: every type argument of a generic class is Dynamic (Array[E] is read as Array), the measure of what generic classes buy."
	genericClasses := aBoolean
]

{ #category : #accessing }
TypeChecker >> genericMethods [
	^ genericMethods
]

{ #category : #accessing }
TypeChecker >> genericMethods: aBoolean [
	genericMethods := aBoolean
]

{ #category : #accessing }
TypeChecker >> index [
	^ index
]

{ #category : #accessing }
TypeChecker >> inferReturns [
	^ inferReturns
]

{ #category : #accessing }
TypeChecker >> inferReturns: aBoolean [
	inferReturns := aBoolean
]

{ #category : #accessing }
TypeChecker >> memberwiseNil [
	^ memberwiseNil
]

{ #category : #accessing }
TypeChecker >> memberwiseNil: aBoolean [
	"On: the ifNil: family is typed by signatures alone (Object's with Self, UndefinedObject's with Dynamic), a send to a union including Nil when Nil answers the selector; off: the checker's own rule for the ifNil: family (nilTestIn:)."
	memberwiseNil := aBoolean
]

{ #category : #accessing }
TypeChecker >> nilStrict [
	^ nilStrict
]

{ #category : #accessing }
TypeChecker >> nilStrict: aBoolean [
	nilStrict := aBoolean
]

{ #category : #accessing }
TypeChecker >> overloads [
	^ overloads
]

{ #category : #accessing }
TypeChecker >> overloads: aBoolean [
	overloads := aBoolean
]

{ #category : #accessing }
TypeChecker >> recordTypes [
	^ recordTypes
]

{ #category : #accessing }
TypeChecker >> recordTypes: aBoolean [
	recordTypes := aBoolean
]

{ #category : #accessing }
TypeChecker >> results [
	^ results
]

{ #category : #accessing }
TypeChecker >> setUp [
	table := TypeTable new.
	genericMethods := true.
	nilStrict := true.
	overloads := true.
	covariant := false.
	inferReturns := true.
	recordTypes := false.
	typeTests := true.
	counts := Dictionary new.
	memberwiseNil := false.
	doits := Dictionary new.
	doitChecks := Dictionary new.
	genericClasses := true.
	index := Dictionary new.
	results := Dictionary new.
	self forgetCaches
]

{ #category : #accessing }
TypeChecker >> table [
	^ table
]

{ #category : #accessing }
TypeChecker >> table: aTypeTable [
	table := aTypeTable.
	self forgetCaches
]

{ #category : #accessing }
TypeChecker >> typeTests [
	^ typeTests
]

{ #category : #accessing }
TypeChecker >> typeTests: aBoolean [
	typeTests := aBoolean
]

{ #category : #checking }
TypeChecker >> behaviorOfKey: aKey [
	"The behavior a method key (Class>>selector or Class class>>selector) names, or nil."
	| i cname |
	i := aKey indexOfSubstring: '>>'.
	i = 0 ifTrue: [^ nil].
	cname := aKey copyFrom: 1 to: i - 1.
	^ (cname endsWith: ' class')
		ifTrue: [(Smalltalk classNamed: (cname copyFrom: 1 to: cname byteSize - 6)) ifNotNil: [:c | c class]]
		ifFalse: [Smalltalk classNamed: cname]
]

{ #category : #checking }
TypeChecker >> check: aSelector in: aBehavior [
	"The result of checking one method (an MethodTypeCheck), kept with its dependencies in the index."
	| mc key |
	key := self keyOf: aSelector in: aBehavior.
	mc := MethodTypeCheck checker: self behavior: aBehavior selector: aSelector.
	[mc run] on: Error do: [:e | mc noteFailure: e messageText].
	self forget: key.
	results at: key put: (Array with: mc diagnostics asArray with: mc deps asArray).
	mc deps do: [:d | (index at: d ifAbsentPut: [Set new]) add: key].
	^ mc
]

{ #category : #checking }
TypeChecker >> checkAll [
	"Every class of the image, by name; answers how many methods and signatures were checked."
	| n |
	n := 0.
	(Smalltalk allClasses asArray sort: [:a :b | a name <= b name]) do: [:c | n := n + (self checkClass: c) size].
	^ n
]

{ #category : #checking }
TypeChecker >> checkClass: aClass [
	"Every method and every signature without a method of the class and of its metaclass; the checks, an OrderedCollection."
	| out |
	out := OrderedCollection new.
	{aClass. aClass class} do: [:b | | sels |
		sels := b selectors asOrderedCollection.
		(Smalltalk typesOf: aClass) ifNotNil: [:t | (t signatureSelectorsMeta: b isMeta) do: [:sel | (sels includes: sel) ifFalse: [sels add: sel]]].
		(sels asArray sort: [:x :y | x <= y]) do: [:sel | out add: (self check: sel in: b)]].
	^ out
]

{ #category : #checking }
TypeChecker >> checkSource: aString named: aKey bindings: aDictionary [
	"Check a workspace expression (question 9): aString's statements as a method of UndefinedObject, each name of aDictionary a variable of that type; kept under aKey so that a change it read rechecks it."
	| mc |
	mc := MethodTypeCheck checker: self behavior: UndefinedObject selector: #doIt.
	mc runSource: 'doIt' , String lf , aString key: aKey bindings: aDictionary.
	self forget: aKey.
	results at: aKey put: (Array with: mc diagnostics asArray with: mc deps asArray).
	doits at: aKey put: {aString. aDictionary}.
	doitChecks at: aKey put: mc.
	mc deps do: [:d | (index at: d ifAbsentPut: [Set new]) add: aKey].
	^ mc
]

{ #category : #checking }
TypeChecker >> doitCheck: aKey [
	"The last check of the workspace expression kept under aKey (checkSource:named:bindings:)."
	^ doitChecks at: aKey ifAbsent: [nil]
]

{ #category : #checking }
TypeChecker >> keyOf: aSelector in: aBehavior [
	^ aBehavior name , '>>' , aSelector
]

{ #category : #checking }
TypeChecker >> resultKeys [
	"The keys of every method, signature and workspace expression checked."
	^ results keys
]

{ #category : #dependencies }
TypeChecker >> dependentsOf: aKey [
	"The keys of the methods whose check read aKey."
	^ (index at: aKey ifAbsent: [#()]) asArray
]

{ #category : #dependencies }
TypeChecker >> forget: aMethodKey [
	"Drop a method's old dependencies before it is checked again."
	(results at: aMethodKey ifAbsent: [nil]) ifNotNil: [:old |
		old last do: [:d | (index at: d ifAbsent: [nil]) ifNotNil: [:s | s remove: aMethodKey ifAbsent: [nil]]]]
]

{ #category : #dependencies }
TypeChecker >> forgetClassNamed: aName [
	"A class removed: the inferred results of its methods go, so nothing here holds its methods (or the class through them)."
	(returnCache keys select: [:k | (k beginsWith: aName , '>>') or: [k beginsWith: aName , ' class>>']]) do: [:k | returnCache removeKey: k]
]

{ #category : #dependencies }
TypeChecker >> hasResultFor: aKey [
	^ results includesKey: aKey
]

{ #category : #dependencies }
TypeChecker >> indexKeysEndingWith: aString [
	"The dependency keys that end with aString (>>selector: every class's signature or body of a selector)."
	^ index keys select: [:k | k endsWith: aString]
]

{ #category : #dependencies }
TypeChecker >> indexKeysOfClassNamed: aName [
	"The dependency keys of the class named aName, both sides: its signatures, its bodies and its instance variables (not the sel: keys)."
	^ index keys select: [:k | | rest |
		(k beginsWith: 'sel:')
			ifTrue: [false]
			ifFalse: [
				rest := k copyFrom: (k indexOf: $:) + 1 to: k byteSize.
				rest = aName or: [(rest beginsWith: aName , '>>') or: [rest beginsWith: aName , ' class>>']]]]
]

{ #category : #dependencies }
TypeChecker >> invalidate: aKey [
	"What a change of aKey (a signature, a body, a selector, a class's variables) makes stale: the inferred results that read it are forgotten, transitively through their own bodies, and the keys of every method whose check read any of them are answered (a Set)."
	| todo seen methods k |
	todo := OrderedCollection with: aKey.
	seen := Set new.
	seen add: aKey.
	methods := Set new.
	[todo isEmpty] whileFalse: [
		k := todo removeFirst.
		(index at: k ifAbsent: [#()]) do: [:mk | methods add: mk].
		(cacheIndex at: k ifAbsent: [#()]) asArray do: [:mk | | bk |
			returnCache removeKey: mk ifAbsent: [nil].
			bk := 'body:' , mk.
			(seen includes: bk) ifFalse: [seen add: bk. todo add: bk]]].
	^ methods
]

{ #category : #dependencies }
TypeChecker >> recheck: aSetOfKeys [
	"Check again each method named by a key (Class>>selector or Class class>>selector) that still exists; the checks."
	| out |
	out := OrderedCollection new.
	aSetOfKeys do: [:mk | | i cname sel b |
		(doits includesKey: mk) ifTrue: [out add: (self checkSource: (doits at: mk) first named: mk bindings: (doits at: mk) last)] ifFalse: [
		i := mk indexOfSubstring: '>>'.
		cname := mk copyFrom: 1 to: i - 1.
		sel := (mk copyFrom: i + 2 to: mk byteSize) asSymbol.
		b := self behaviorOfKey: mk.
		(b notNil and: [(b includesSelector: sel) or: [(Smalltalk signatureOf: sel in: b) notNil]])
			ifTrue: [out add: (self check: sel in: b)]
			ifFalse: [self forget: mk. results removeKey: mk ifAbsent: [nil]]]].
	^ out
]

{ #category : #diagnostics }
TypeChecker >> allDiagnostics [
	| out |
	out := OrderedCollection new.
	results do: [:r | out addAll: r first].
	^ out
]

{ #category : #diagnostics }
TypeChecker >> diagnosticCount [
	^ results inject: 0 into: [:n :r | n + r first size]
]

{ #category : #diagnostics }
TypeChecker >> diagnosticsAt: aKey [
	"The diagnostics of the method or signature aKey names, an Array (empty when it was not checked)."
	^ (results at: aKey ifAbsent: [nil]) ifNil: [#()] ifNotNil: [:r | r first]
]

{ #category : #inference }
TypeChecker >> inferredReturnOf: aCompiledMethod [
	"The result type of an unannotated method from its body, with Self for the receiver; Dynamic while it is being inferred (recursion) or when the switch is off. Cached by the method's key with the method itself, so a recompiled method is inferred again and the old one is not held."
	| mc t key |
	inferReturns ifFalse: [^ Type dynamic].
	aCompiledMethod primitive = 0 ifFalse: [^ Type dynamic].
	key := self keyOf: aCompiledMethod selector in: aCompiledMethod methodClass.
	(returnCache at: key ifAbsent: [nil]) ifNotNil: [:r | r first == aCompiledMethod ifTrue: [^ r last]].
	(inferring includes: key) ifTrue: [^ Type dynamic].
	inferring add: key.
	[mc := MethodTypeCheck checker: self behavior: aCompiledMethod methodClass selector: aCompiledMethod selector.
	 mc beQuiet.
	 [mc run] on: Error do: [:e | nil].
	 t := mc inferredResult] ensure: [inferring remove: key ifAbsent: [nil]].
	returnCache at: key put: (Array with: aCompiledMethod with: t).
	mc deps do: [:d | (cacheIndex at: d ifAbsentPut: [Set new]) add: key].
	^ t
]

{ #category : #relations }
TypeChecker >> isClass: a subtypeOf: b [
	| map ps x y |
	(a cls includesBehavior: b cls) ifFalse: [^ false].
	b args isEmpty ifTrue: [^ true].
	a args isEmpty ifTrue: [^ true].
	map := table map: a to: b cls.
	ps := table paramsOf: b cls.
	1 to: (ps size min: b args size) do: [:i |
		x := map at: (ps at: i) ifAbsent: [Type dynamic].
		y := b args at: i.
		(covariant
			ifTrue: [self isSubtype: x of: y]
			ifFalse: [(self isSubtype: x of: y) and: [self isSubtype: y of: x]]) ifFalse: [^ false]].
	^ true
]

{ #category : #relations }
TypeChecker >> isSubtype: a of: b [
	"Whether a value of type a may be used where b is expected (Dynamic both ways)."
	(a isDynamic or: [b isDynamic]) ifTrue: [^ true].
	(a isNilType and: [nilStrict not]) ifTrue: [^ true].
	a isUnion ifTrue: [^ a members allSatisfy: [:m | self isSubtype: m of: b]].
	b class == SelfType ifTrue: [^ a class == SelfType or: [(a isClassType or: [a isMetaType]) and: [a selfKind == #self]]].
	b class == InstanceType ifTrue: [^ a class == InstanceType or: [a isClassType and: [a selfKind == #instance]]].
	(a class == SelfType or: [a class == InstanceType or: [a class == SelfClassType or: [b class == SelfClassType]]]) ifTrue: [^ true].
	(b class == TypeVariableClass or: [a class == TypeVariableClass]) ifTrue: [^ a isMetaType or: [a class == TypeVariableClass or: [a isClassType and: [a cls includesBehavior: Behavior]]]].
	b isUnion ifTrue: [^ b members anySatisfy: [:m | self isSubtype: a of: m]].
	(b isClassType and: [b cls == Object]) ifTrue: [^ true].
	(a isProtocolType or: [b isProtocolType]) ifTrue: [
		^ a isProtocolType and: [b isProtocolType and: [
			((table protocolNamed: a name) ifNil: [^ true]) includesProtocol: ((table protocolNamed: b name) ifNil: [^ true])]]].
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
TypeChecker >> join: a with: b [
	"The least type that holds both (approximate: a common superclass, else a union of at most three)."
	| c u |
	(a isNil or: [a isUnassigned]) ifTrue: [^ b].
	(b isNil or: [b isUnassigned]) ifTrue: [^ a].
	(a isDynamic or: [b isDynamic]) ifTrue: [^ Type dynamic].
	(a sameAs: b) ifTrue: [^ a].
	(a isNilType or: [b isNilType]) ifTrue: [^ Type union: {a. b}].
	(a includesNil or: [b includesNil]) ifTrue: [^ Type union: {self join: a withoutNil with: b withoutNil. Type nilType}].
	(self isSubtype: a of: b) ifTrue: [^ b].
	(self isSubtype: b of: a) ifTrue: [^ a].
	(a isClassType and: [b isClassType]) ifTrue: [
		c := a cls.
		[c notNil and: [(b cls includesBehavior: c) not]] whileTrue: [c := c superclass].
		(c notNil and: [c ~~ Object]) ifTrue: [^ Type of: c]].
	u := Type union: {a. b}.
	u members size > 3 ifTrue: [^ Type of: Object].
	^ u
]

{ #category : #relations }
TypeChecker >> unify: p with: a vars: aSet into: aDictionary [
	"Bind the method variables aSet names in the parameter type p to what the argument type a gives them."
	| map ps |
	(p class == TypeVariableClass and: [(aSet includes: p name) and: [a isMetaType]]) ifTrue: [
		aDictionary at: p name put: (self join: (aDictionary at: p name ifAbsent: [nil]) with: (Type of: a cls)).
		^ self].
	(p isVar and: [aSet includes: p name]) ifTrue: [
		aDictionary at: p name put: (self join: (aDictionary at: p name ifAbsent: [nil]) with: a).
		^ self].
	p isUnion ifTrue: [
		(p members reject: [:m | m isNilType]) do: [:m | self unify: m with: a withoutNil vars: aSet into: aDictionary].
		^ self].
	(p isClassType and: [a isClassType and: [p args notEmpty and: [a cls includesBehavior: p cls]]]) ifTrue: [
		map := table map: a to: p cls.
		ps := table paramsOf: p cls.
		1 to: (ps size min: p args size) do: [:i |
			self unify: (p args at: i) with: (map at: (ps at: i) ifAbsent: [Type dynamic]) vars: aSet into: aDictionary].
		^ self].
	(p isBlockType and: [a isBlockType]) ifTrue: [
		1 to: (p args size min: a args size) do: [:i | self unify: (p args at: i) with: (a args at: i) vars: aSet into: aDictionary].
		self unify: p result with: a result vars: aSet into: aDictionary]
]

{ #category : #'instance creation' }
TypeChecker class >> new [
	^ self basicNew setUp
]

{ #category : #'instance creation' }
TypeChecker class >> on: aTypeTable [
	^ self new table: aTypeTable; yourself
]
