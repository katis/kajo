"Checks one method's parse tree (the kernel compiler's Parser) against the types the image writes (Types 2; the experiment's OTMethodCheck), or one signature without a method against what it narrows and against the classes that answer it (runSignature): types each expression, checks each send, assignment and return, and records the diagnostics, the counts the experiment reports (sends; sends whose receiver type is known; sends resolved to a signature; sends whose result is known) and the dependency keys the check read. Quiet (inference of an unannotated callee's result) records nothing but the returns."
Class {
	#name : #MethodTypeCheck,
	#superclass : #Object,
	#instVars : [
		'checker',
		'ann',
		'behavior',
		'base',
		'meta',
		'selector',
		'key',
		'source',
		'selfType',
		'instType',
		'sig',
		'declaredReturn',
		'ivarNames',
		'diagnostics',
		'deps',
		'quiet',
		'returns',
		'fellOff',
		'sends',
		'knownSends',
		'typedSends',
		'knownResults',
		'types',
		'parsed',
		'prepassing'
	]
}

{ #category : #accessing }
MethodTypeCheck >> beQuiet [
	quiet := true
]

{ #category : #accessing }
MethodTypeCheck >> behavior [
	^ behavior
]

{ #category : #accessing }
MethodTypeCheck >> deps [
	^ deps
]

{ #category : #accessing }
MethodTypeCheck >> diagnostics [
	^ diagnostics
]

{ #category : #accessing }
MethodTypeCheck >> hasSignature [
	^ sig notNil
]

{ #category : #accessing }
MethodTypeCheck >> inferredResult [
	"The join of every returned type (Self when the method falls off its end), with the receiver's mark kept so a caller can substitute its own receiver."
	| t |
	t := nil.
	returns do: [:r | t := checker join: t with: r].
	fellOff ifTrue: [t := checker join: t with: selfType].
	^ t ifNil: [Type dynamic]
]

{ #category : #accessing }
MethodTypeCheck >> key [
	^ key
]

{ #category : #accessing }
MethodTypeCheck >> knownResults [
	^ knownResults
]

{ #category : #accessing }
MethodTypeCheck >> knownSends [
	^ knownSends
]

{ #category : #accessing }
MethodTypeCheck >> parsed [
	^ parsed
]

{ #category : #accessing }
MethodTypeCheck >> sends [
	^ sends
]

{ #category : #accessing }
MethodTypeCheck >> setChecker: aChecker behavior: aBehavior selector: aSymbol [
	checker := aChecker.
	ann := aChecker table.
	behavior := aBehavior.
	selector := aSymbol.
	meta := aBehavior isMeta.
	base := aBehavior theNonMetaClass.
	key := aChecker keyOf: aSymbol in: aBehavior.
	diagnostics := OrderedCollection new.
	deps := Set new.
	quiet := false.
	returns := OrderedCollection new.
	fellOff := false.
	sends := 0.
	knownSends := 0.
	typedSends := 0.
	knownResults := 0.
	types := OrderedCollection new.
	parsed := false
]

{ #category : #accessing }
MethodTypeCheck >> typedSends [
	^ typedSends
]

{ #category : #accessing }
MethodTypeCheck >> types [
	"With recordTypes: {start. end. receiver type. selector} of every send."
	^ types
]

{ #category : #diagnostics }
MethodTypeCheck >> note: aKind at: aNode text: aString [
	| range |
	quiet ifTrue: [^ self].
	range := self rangeOf: aNode.
	diagnostics add: ((TypeDiagnostic kind: aKind where: key line: (aNode ifNil: [0] ifNotNil: [:n | n line]) text: aString
		start: range first end: range last)
		setBehavior: behavior selector: selector; yourself)
]

{ #category : #diagnostics }
MethodTypeCheck >> noteFailure: aString [
	"The checker failed on this method (its own fault): one #checker diagnostic says so, and what the check had found is dropped."
	diagnostics := OrderedCollection new.
	quiet := false.
	self note: #checker at: nil text: 'the checker failed here: ' , aString
]

{ #category : #diagnostics }
MethodTypeCheck >> rangeOf: aNode [
	"{start. end} of the source a diagnostic is about, byte offsets in the method's source from 0, end exclusive, or {nil. nil}: the node's own (sends and primaries have one), a return's value's, an assignment's from its variable to its value's end."
	| v |
	aNode isNil ifTrue: [^ {nil. nil}].
	aNode sourceStart notNil ifTrue: [^ {aNode sourceStart. aNode sourceEnd}].
	aNode class == ReturnNode ifTrue: [^ self rangeOf: aNode value].
	aNode class == AssignmentNode ifTrue: [
		v := self rangeOf: aNode value.
		^ {(self rangeOf: aNode variable) first ifNil: [v first]. v last}].
	aNode class == CascadeNode ifTrue: [^ self rangeOf: aNode receiver].
	^ {nil. nil}
]

{ #category : #narrowing }
MethodTypeCheck >> assigned: aNode into: aSet [
	| c |
	c := aNode class.
	c == AssignmentNode ifTrue: [aSet add: aNode variable name. ^ self assigned: aNode value into: aSet].
	c == MessageNode ifTrue: [self assigned: aNode receiver into: aSet. aNode arguments do: [:a | self assigned: a into: aSet]. ^ self].
	c == CascadeNode ifTrue: [self assigned: aNode receiver into: aSet. aNode messages do: [:m | (m at: 2) do: [:a | self assigned: a into: aSet]]. ^ self].
	c == BlockNode ifTrue: [aNode statements do: [:st | self assigned: st into: aSet]. ^ self].
	c == BraceNode ifTrue: [aNode elements do: [:a | self assigned: a into: aSet]. ^ self].
	c == ReturnNode ifTrue: [^ self assigned: aNode value into: aSet]
]

{ #category : #narrowing }
MethodTypeCheck >> assignsOuter: aNode in: env [
	"Whether a block (or a loop's blocks) assigns a variable declared outside it: such a block is typed twice, so the second pass starts from what the first assigned (loops iterated once)."
	| names |
	names := Set new.
	self assigned: aNode into: names.
	^ names anySatisfy: [:n | (env envDeclaring: n) notNil or: [ivarNames includes: n]]
]

{ #category : #narrowing }
MethodTypeCheck >> conditionNarrowing: aNode in: env [
	"{variable name. its type when aNode is true. its type when false} (nil: unchanged) when aNode tests a variable: a nil test (v isNil, v notNil, v == nil, v ~~ nil, v = nil, v ~= nil), with the typeTests switch a type test (v isKindOf: C, v isString and the other isX), a conjunction (true only) and a disjunction of tests of one variable (true only); else nil."
	| r s a b t cur |
	aNode class == MessageNode ifFalse: [^ nil].
	r := aNode receiver.
	s := aNode selector.
	(s == #and: and: [aNode arguments first class == BlockNode]) ifTrue: [
		a := self conditionNarrowing: r in: env.
		^ a ifNotNil: [{a first. a at: 2. nil. a at: 4}]].
	((s == #| or: [s == #or:]) and: [checker typeTests]) ifTrue: [
		a := self conditionNarrowing: r in: env.
		b := aNode arguments first.
		(s == #or: and: [b class == BlockNode and: [b statements size = 1]]) ifTrue: [b := b statements first].
		b := self conditionNarrowing: b in: env.
		(a notNil and: [b notNil and: [a first = b first and: [(a at: 2) notNil and: [(b at: 2) notNil]]]]) ifFalse: [^ nil].
		^ {a first. Type union: {a at: 2. b at: 2}. nil. #typeTest}].
	checker typeTests ifTrue: [
	((s == #== and: [r class == MessageNode and: [r selector == #class and: [r receiver class == VariableNode]]]) and: [aNode arguments first class == VariableNode]) ifTrue: [
			^ (Smalltalk classNamed: aNode arguments first name) ifNotNil: [:c | {r receiver name. Type of: c. nil. #typeTest}]]].
	(r class == VariableNode and: [(#('self' 'super' 'thisContext') includes: r name) not]) ifFalse: [^ nil].
	cur := self currentTypeOf: r name in: env.
	t := nil.
	(s == #isNil or: [(s == #== or: [s == #=]) and: [aNode arguments first class == LiteralNode and: [aNode arguments first value isNil]]])
		ifTrue: [^ cur ifNotNil: [{r name. nil. cur withoutNil. #nilFlow}]].
	(s == #notNil or: [(s == #~~ or: [s == #~=]) and: [aNode arguments first class == LiteralNode and: [aNode arguments first value isNil]]])
		ifTrue: [^ cur ifNotNil: [{r name. cur withoutNil. nil. #nilFlow}]].
	checker typeTests ifFalse: [^ nil].
	((s == #isKindOf: or: [s == #isMemberOf:]) and: [aNode arguments first class == VariableNode]) ifTrue: [
		t := (Smalltalk classNamed: aNode arguments first name) ifNotNil: [:c | Type of: c]].
	t isNil ifTrue: [
		t := (#(#isString String #isSymbol Symbol #isInteger Integer #isFraction Fraction #isFloat Float #isNumber Number #isCharacter Character #isArray Array #isCollection Collection #isBlock BlockClosure #isBoolean Boolean)
			indexOf: s) in: [:i | (i > 0 and: [i odd]) ifTrue: [Type of: (Smalltalk classNamed: (#(#isString String #isSymbol Symbol #isInteger Integer #isFraction Fraction #isFloat Float #isNumber Number #isCharacter Character #isArray Array #isCollection Collection #isBlock BlockClosure #isBoolean Boolean) at: i + 1))]]].
	^ t ifNotNil: [{r name. t. nil. #typeTest}]
]

{ #category : #narrowing }
MethodTypeCheck >> currentTypeOf: aName in: env [
	| e |
	(env narrowingOf: aName) ifNotNil: [:t | ^ t].
	e := env envDeclaring: aName.
	e notNil ifTrue: [^ e vars at: aName].
	(ivarNames includes: aName) ifTrue: [^ self ivarType: aName].
	^ nil
]

{ #category : #narrowing }
MethodTypeCheck >> loop: aNode in: env [
	"[cond] whileTrue: [body]: the body runs in the condition's scope (what the condition assigned is assigned), and after a condition that ends in a not-nil test (v notNil, v notNil and: [...]) the variable is not nil in the body. Answers Nil."
	self countSend: (Type of: BlockClosure) result: Type nilType node: aNode selector: aNode selector.
	(self assignsOuter: aNode in: env) ifTrue: [self prepass: [self loopOnce: aNode in: env]].
	^ self loopOnce: aNode in: env
]

{ #category : #narrowing }
MethodTypeCheck >> loopOnce: aNode in: env [
	| cond e body test t |
	cond := aNode receiver.
	e := TypeScope parent: env.
	cond temporaries do: [:x | e declare: x first type: UnassignedType new].
	self statements: cond statements in: e method: false.
	body := TypeScope parent: e.
	cond statements notEmpty ifTrue: [
		test := self conditionNarrowing: cond statements last in: e.
		test notNil ifTrue: [
			t := aNode selector == #whileTrue: ifTrue: [test at: 2] ifFalse: [test at: 3].
			t notNil ifTrue: [body narrow: test first to: t kind: (test at: 4)]]].
	aNode arguments first temporaries do: [:x | body declare: x first type: UnassignedType new].
	self statements: aNode arguments first statements in: body method: false.
	^ Type nilType
]

{ #category : #narrowing }
MethodTypeCheck >> narrowAfter: aStatement in: env [
	"After `cond ifTrue: [^ ...]` the variable cond tests has its type for false for the rest of the scope, after `cond ifFalse: [^ ...]` its type for true, after `v ifNil: [^ ...]` v is not nil."
	| sel test blk t |
	aStatement class == MessageNode ifFalse: [^ self].
	sel := aStatement selector.
	blk := aStatement arguments isEmpty ifTrue: [nil] ifFalse: [aStatement arguments first].
	(blk notNil and: [blk class == BlockNode and: [blk statements notEmpty and: [blk statements last class == ReturnNode]]]) ifFalse: [^ self].
	(sel == #ifNil: and: [aStatement receiver class == VariableNode]) ifTrue: [
		^ (self currentTypeOf: aStatement receiver name in: env) ifNotNil: [:x | env narrow: aStatement receiver name to: x withoutNil kind: #nilFlow]].
	(sel == #ifTrue: or: [sel == #ifFalse:]) ifFalse: [^ self].
	test := self conditionNarrowing: aStatement receiver in: env.
	test isNil ifTrue: [^ self].
	t := sel == #ifTrue: ifTrue: [test at: 3] ifFalse: [test at: 2].
	t notNil ifTrue: [env narrow: test first to: t kind: (test at: 4)]
]

{ #category : #narrowing }
MethodTypeCheck >> nilTestIn: aNode in: env [
	"The flow the experiment follows: the ifNil: family on a variable's type, and the blocks of ifTrue:, ifFalse:, and:, or: and the two-block forms after a condition that tests a variable (conditionNarrowing:). Answers the send's type, or nil when aNode is none of them."
	| test sel rt nn args blockT r b0 b1 |
	sel := aNode selector.
	args := aNode arguments.
	(#(#ifNil: #ifNotNil: #ifNil:ifNotNil: #ifNotNil:ifNil:) includes: sel) ifTrue: [
		(args allSatisfy: [:a | a class == BlockNode]) ifFalse: [^ nil].
		checker memberwiseNil ifTrue: [^ nil].
		rt := self typeOf: aNode receiver in: env.
		quiet ifFalse: [checker count: 'ifNil family receiver ' , (rt isDynamic ifTrue: ['Dynamic'] ifFalse: [rt isVar ifTrue: ['type parameter'] ifFalse: [rt includesNil ifTrue: [(aNode receiver class == VariableNode and: [ivarNames includes: aNode receiver name]) ifTrue: ['union with Nil, an ivar'] ifFalse: ['union with Nil']] ifFalse: ['without Nil']]])].
		self countSend: rt result: Type dynamic node: aNode selector: sel.
		nn := rt withoutNil.
		(quiet not and: [rt includesNil and: [args anySatisfy: [:blk | blk numArgs = 1]]]) ifTrue: [checker count: 'blockParam'].
		r := nil.
		args do: [:blk | | expect benv |
			expect := (blk numArgs = 1) ifTrue: [BlockType args: {nn} result: Type dynamic] ifFalse: [nil].
			benv := env.
			(blk numArgs = 0 and: [aNode receiver class == VariableNode and: [rt includesNil and: [
				(sel == #ifNotNil: or: [sel == #ifNotNil:ifNil:]) ifTrue: [blk == args first] ifFalse: [sel == #ifNil:ifNotNil: and: [blk == args last]]]]])
				ifTrue: [benv := TypeScope parent: env. benv narrow: aNode receiver name to: nn kind: #nilFlow].
			blockT := self block: blk expected: expect in: benv.
			r := checker join: r with: blockT result].
		sel == #ifNil: ifTrue: [r := checker join: r with: nn].
		(sel == #ifNotNil:) ifTrue: [r := checker join: r with: Type nilType].
		^ r].
	(#(#ifTrue: #ifFalse: #and: #or: #ifTrue:ifFalse: #ifFalse:ifTrue:) includes: sel) ifFalse: [^ nil].
	(args allSatisfy: [:a | a class == BlockNode and: [a numArgs = 0]]) ifFalse: [^ nil].
	test := self conditionNarrowing: aNode receiver in: env.
	test isNil ifTrue: [^ nil].
	rt := self typeOf: aNode receiver in: env.
	self countSend: rt result: (Type of: Boolean) node: aNode selector: sel.
	b0 := args first.
	b1 := args size > 1 ifTrue: [args last] ifFalse: [nil].
	r := nil.
	args do: [:blk | | e whenTrue t |
		whenTrue := (sel == #ifTrue: or: [sel == #and:]) or: [(sel == #ifTrue:ifFalse: and: [blk == b0]) or: [sel == #ifFalse:ifTrue: and: [blk == b1]]].
		t := whenTrue ifTrue: [test at: 2] ifFalse: [test at: 3].
		e := TypeScope parent: env.
		t notNil ifTrue: [e narrow: test first to: t kind: (test at: 4)].
		r := checker join: r with: (self statements: blk statements in: e method: false)].
	(#(#ifTrue: #ifFalse:) includes: sel) ifTrue: [r := checker join: r with: Type nilType].
	(#(#and: #or:) includes: sel) ifTrue: [r := Type of: Boolean].
	^ r
]

{ #category : #narrowing }
MethodTypeCheck >> prepass: aBlock [
	"Run aBlock quietly once (its assignments join into the outer variables); not nested."
	| was |
	prepassing == true ifTrue: [^ self].
	was := quiet.
	quiet := true.
	prepassing := true.
	aBlock ensure: [quiet := was. prepassing := false]
]

{ #category : #running }
MethodTypeCheck >> run [
	| m tree env params sigMap |
	m := behavior compiledMethodAt: selector ifAbsent: [nil].
	m isNil ifTrue: [^ self runSignature].
	source := m sourceCode.
	source isNil ifTrue: [^ self].
	tree := [Parser parse: source] on: CompileError do: [:e | self note: #parse at: nil text: e messageText. e return: nil].
	tree isNil ifTrue: [^ self].
	parsed := true.
	((ann typedClass: base) problemsOf: key) do: [:t | self note: #annotation at: nil text: t].
	params := ann paramsOf: base.
	meta
		ifTrue: [
			selfType := MetaType cls: base selfKind: #self.
			instType := NominalType cls: base args: (params collect: [:p | Type dynamic]) selfKind: #instance.
			ivarNames := #()]
		ifFalse: [
			selfType := NominalType cls: base args: (params collect: [:p | checker genericClasses ifTrue: [TypeVariable named: p] ifFalse: [Type dynamic]]) selfKind: #self.
			instType := nil.
			ivarNames := (Smalltalk instanceVariableNamesOf: base) collect: [:s | s asString]].
	(ann signaturesFor: selector from: behavior) ifNotNil: [:found |
		sig := found last last.
		deps add: sig key.
		sigMap := (meta or: [found first isMeta]) ifTrue: [Dictionary new] ifFalse: [ann map: selfType to: found first].
		declaredReturn := sig result substitute: sigMap self: nil instance: nil].
	env := TypeScope parent: nil.
	tree arguments doWithIndex: [:a :i |
		env declare: a first type: ((sig notNil and: [sig argTypes size = tree arguments size])
			ifTrue: [(sig argTypes at: i) substitute: sigMap self: selfType instance: instType]
			ifFalse: [Type dynamic])].
	tree temporaries do: [:t | env declare: t first type: UnassignedType new].
	self statements: tree statements in: env method: true
]

{ #category : #running }
MethodTypeCheck >> runSource: aString key: aKey bindings: aDictionary [
	"Question 9: check a workspace expression with typed variables; its last statement's type is the result."
	| tree env |
	key := aKey.
	source := aString.
	tree := [Parser parse: source] on: CompileError do: [:e | self note: #parse at: nil text: e messageText. e return: nil].
	tree isNil ifTrue: [^ self].
	parsed := true.
	selfType := Type nilType.
	ivarNames := #().
	env := TypeScope parent: nil.
	aDictionary keysAndValuesDo: [:k :v | env declare: k type: v].
	tree temporaries do: [:t | env declare: t first type: UnassignedType new].
	tree statements do: [:st | returns add: (self typeOf: st in: env)]
]

{ #category : #sending }
MethodTypeCheck >> apply: found to: rt instance: instanceType args: argNodes node: aNode in: env [
	"A send covered by a signature: bind the receiver's type arguments, infer the method's variables from the arguments (blocks typed by what is expected of them), check every argument, answer the result."
	| defClass sigs s map vars bind argTypes params result leftover |
	defClass := found first.
	sigs := found last.
	map := (rt isClassType and: [defClass isBehavior and: [defClass isMeta not]]) ifTrue: [ann map: rt to: defClass] ifFalse: [Dictionary new].
	checker genericClasses ifFalse: [map keys do: [:k | map at: k put: Type dynamic]].
	s := self chooseSignature: sigs map: map receiver: rt instance: instanceType args: argNodes in: env.
	deps add: s key.
	s argTypes size = argNodes size ifFalse: [
		self note: #annotation at: aNode text: s key , ' has ' , s argTypes size printString , ' argument types'.
		argNodes do: [:a | self typeOf: a in: env].
		^ Type dynamic].
	vars := checker genericMethods ifTrue: [s vars] ifFalse: [Set new].
	checker genericMethods ifFalse: [s vars do: [:v | map at: v put: Type dynamic]].
	params := s argTypes collect: [:p | p substitute: map self: rt instance: instanceType].
	bind := Dictionary new.
	argTypes := Array new: argNodes size.
	"non-block arguments first: they bind the variables the blocks' arguments use"
	1 to: argNodes size do: [:i |
		(argNodes at: i) class == BlockNode ifFalse: [
			argTypes at: i put: (self typeOf: (argNodes at: i) in: env).
			checker unify: (params at: i) with: (argTypes at: i) vars: vars into: bind]].
	1 to: argNodes size do: [:i | | expected |
		(argNodes at: i) class == BlockNode ifTrue: [
			expected := self dynamicVars: vars in: ((params at: i) substitute: bind self: nil instance: nil) except: bind.
			argTypes at: i put: (self block: (argNodes at: i) expected: expected in: env).
			checker unify: (params at: i) with: (argTypes at: i) vars: vars into: bind]].
	leftover := Dictionary new.
	vars do: [:v | (bind includesKey: v) ifFalse: [leftover at: v put: Type dynamic]].
	bind keysAndValuesDo: [:k :v | leftover at: k put: v].
	1 to: argNodes size do: [:i | | p a |
		p := (params at: i) substitute: leftover self: nil instance: nil.
		a := argTypes at: i.
		((argNodes at: i) class == BlockNode and: [p isBlockType])
			ifTrue: [
				a args size = p args size
					ifFalse: [self note: #arity at: (argNodes at: i) text: 'block of ' , a args size printString , ' arguments where ' , p printString , ' is expected (#' , s selector , ')']
					ifTrue: [(checker isSubtype: a result of: p result) ifFalse: [
						self note: #blockResult at: (argNodes at: i) text: 'block answers ' , a result printString , ' where ' , p result printString , ' is expected (#' , s selector , ')']]]
			ifFalse: [
				(checker isSubtype: a of: p) ifFalse: [
					self note: #argType at: (argNodes at: i) text: 'argument ' , i printString , ' of #' , s selector , ' is ' , a printString , ', expected ' , p printString]]].
	result := (s result substitute: map self: rt instance: instanceType) substitute: leftover self: nil instance: nil.
	quiet ifFalse: [typedSends := typedSends + 1].
	self countSend: rt result: result node: aNode selector: s selector.
	^ result
]

{ #category : #sending }
MethodTypeCheck >> argTypesOf: argNodes in: env [
	^ argNodes collect: [:a | self typeOf: a in: env]
]

{ #category : #sending }
MethodTypeCheck >> chooseSignature: sigs map: map receiver: rt instance: instanceType args: argNodes in: env [
	"With overloads, the first signature whose non-block argument types fit (typed quietly); else the last."
	| was ok |
	(checker overloads not or: [sigs size = 1]) ifTrue: [^ sigs last].
	was := quiet.
	quiet := true.
	[sigs do: [:s |
		ok := s argTypes size = argNodes size and: [
			(1 to: argNodes size) allSatisfy: [:i |
				(argNodes at: i) class == BlockNode or: [
					checker isSubtype: (self typeOf: (argNodes at: i) in: env) of: ((s argTypes at: i) substitute: map self: rt instance: instanceType)]]].
		ok ifTrue: [quiet := was. ^ s]]] ensure: [quiet := was].
	^ sigs last
]

{ #category : #sending }
MethodTypeCheck >> countSend: rt result: aType node: aNode selector: aSymbol [
	quiet ifTrue: [^ self].
	sends := sends + 1.
	rt isKnown ifTrue: [knownSends := knownSends + 1].
	(rt isKnown and: [aType isKnown]) ifTrue: [knownResults := knownResults + 1].
	checker recordTypes ifTrue: [types add: {aNode sourceStart. aNode sourceEnd. rt. aSymbol}]
]

{ #category : #sending }
MethodTypeCheck >> dynamicVars: aSet in: aType except: aDictionary [
	"aType with the variables of aSet not yet bound made Dynamic in block arguments (a block's argument cannot wait for inference); the result keeps them to be bound by the block."
	| d |
	aType isBlockType ifFalse: [^ aType].
	d := Dictionary new.
	aSet do: [:v | (aDictionary includesKey: v) ifFalse: [d at: v put: Type dynamic]].
	^ BlockType args: (aType args collect: [:t | t substitute: d self: nil instance: nil]) result: aType result
]

{ #category : #sending }
MethodTypeCheck >> resolveSelf: aType to: rt [
	"An inferred result with the callee's receiver mark, in terms of this send's receiver."
	aType isUnion ifTrue: [^ Type union: (aType members collect: [:m | self resolveSelf: m to: rt])].
	((aType isClassType or: [aType isMetaType]) and: [aType selfKind == #self]) ifTrue: [^ rt].
	(aType isClassType and: [aType selfKind == #instance]) ifTrue: [
		^ rt isMetaType ifTrue: [NominalType cls: rt cls args: #()] ifFalse: [aType withoutSelfMark]].
	^ aType
]

{ #category : #sending }
MethodTypeCheck >> send: aSymbol to: rt lookup: lookupClassOrNil args: argNodes node: aNode in: env [
	"The type of a send, its diagnostics noted. lookupClassOrNil is the class a super send looks up from."
	| r members was |
	(rt isDynamic or: [rt isVar or: [rt class == SelfType or: [rt class == InstanceType or: [rt class == SelfClassType]]]]) ifTrue: [
		argNodes do: [:a | self typeOf: a in: env].
		self countSend: rt result: Type dynamic node: aNode selector: aSymbol.
		^ Type dynamic].
	rt isUnion ifTrue: [
		members := rt members reject: [:m | m isNilType].
		(checker memberwiseNil and: [rt includesNil and: [(self understands: aSymbol type: Type nilType) and: [(UndefinedObject lookupSelector: aSymbol) ~~ (Object lookupSelector: aSymbol)]]])
			ifTrue: [members := members , {Type nilType}].
		(rt includesNil and: [checker nilStrict and: [(UndefinedObject lookupSelector: aSymbol) isNil]]) ifTrue: [
			self note: #maybeNil at: aNode text: '#' , aSymbol , ' sent to ' , rt printString].
		members size = 1 ifTrue: [^ self send: aSymbol to: members first lookup: nil args: argNodes node: aNode in: env].
		quiet ifFalse: [
			(rt includesNil and: [checker nilStrict and: [(UndefinedObject lookupSelector: aSymbol) notNil]]) ifTrue: [checker count: 'polymorphic with Nil'].
			(members size > 1 and: [members allSatisfy: [:m | self understands: aSymbol type: m]]) ifTrue: [checker count: 'polymorphic between classes']].
		members do: [:m | (self understands: aSymbol type: m) ifFalse: [
			self note: #dnu at: aNode text: m printString , ' (of ' , rt printString , ') does not understand #' , aSymbol]].
		r := self send: aSymbol to: members first lookup: nil args: argNodes node: aNode in: env.
		was := quiet.
		quiet := true.
		[members allButFirst do: [:m |
			r := checker join: r with: (self send: aSymbol to: m lookup: nil args: argNodes node: aNode in: env)]] ensure: [quiet := was].
		^ r].
	rt isBlockType ifTrue: [
		(#(#value #value: #value:value: #value:value:value: #value:value:value:value:) includes: aSymbol) ifTrue: [
			r := self argTypesOf: argNodes in: env.
			r size = rt args size
				ifFalse: [self note: #arity at: aNode text: 'a block of ' , rt args size printString , ' arguments sent #' , aSymbol]
				ifTrue: [1 to: r size do: [:i |
					(checker isSubtype: (r at: i) of: (rt args at: i)) ifFalse: [
						self note: #argType at: (argNodes at: i) text: 'argument ' , i printString , ' of #' , aSymbol , ' is ' , (r at: i) printString , ', the block takes ' , (rt args at: i) printString]]].
			self countSend: rt result: rt result node: aNode selector: aSymbol.
			^ rt result].
		^ self send: aSymbol to: (Type of: BlockClosure) lookup: nil args: argNodes node: aNode in: env].
	rt isProtocolType ifTrue: [^ self sendToProtocol: aSymbol to: rt args: argNodes node: aNode in: env].
	rt isMetaType ifTrue: [^ self sendToClass: aSymbol to: rt lookup: lookupClassOrNil args: argNodes node: aNode in: env].
	rt isClassType ifTrue: [^ self sendToInstance: aSymbol to: rt lookup: lookupClassOrNil args: argNodes node: aNode in: env].
	argNodes do: [:a | self typeOf: a in: env].
	^ Type dynamic
]

{ #category : #sending }
MethodTypeCheck >> sendToClass: aSymbol to: rt lookup: lookupClassOrNil args: argNodes node: aNode in: env [
	| lc found m inst |
	lc := lookupClassOrNil ifNil: [rt cls].
	found := ann signaturesFor: aSymbol from: lc class.
	inst := NominalType cls: rt cls args: #() selfKind: (rt selfKind == #self ifTrue: [#instance] ifFalse: [nil]).
	"The receiver's own class: on the class side its instances are Instance; on the instance side (self class) an instance it makes is of the receiver's class, so Self, with its type arguments free (a new collection need not hold the receiver's element type): Types 2, the experiment's limit 'self class new is Instance, not Self'."
	(rt selfKind == #self) ifTrue: [
		inst := meta
			ifTrue: [instType]
			ifFalse: [NominalType cls: selfType cls args: (selfType args collect: [:a | Type dynamic]) selfKind: #self]].
	found notNil ifTrue: [^ self apply: found to: rt instance: inst args: argNodes node: aNode in: env].
	deps add: 'sel:' , aSymbol.
	m := lc class lookupSelector: aSymbol.
	^ self unannotated: m selector: aSymbol to: rt from: lc class args: argNodes node: aNode in: env
]

{ #category : #sending }
MethodTypeCheck >> sendToInstance: aSymbol to: rt lookup: lookupClassOrNil args: argNodes node: aNode in: env [
	| lc found m |
	lc := lookupClassOrNil ifNil: [rt cls].
	found := ann signaturesFor: aSymbol from: lc.
	"A value typed as some Behavior (species ^<Behavior>) is a class nobody knows: what its Instance-typed methods make is Dynamic."
	found notNil ifTrue: [^ self apply: found to: rt instance: ((rt cls includesBehavior: Behavior) ifTrue: [Type dynamic] ifFalse: [nil]) args: argNodes node: aNode in: env].
	deps add: 'sel:' , aSymbol.
	m := lc lookupSelector: aSymbol.
	^ self unannotated: m selector: aSymbol to: rt from: lc args: argNodes node: aNode in: env
]

{ #category : #sending }
MethodTypeCheck >> sendToProtocol: aSymbol to: rt args: argNodes node: aNode in: env [
	"A send to a value of a protocol made by code: its signatures, else Object's methods (a proxy is an Object), else a diagnostic."
	| p found |
	deps add: 'protocol:' , rt name.
	p := ann protocolNamed: rt name.
	p isNil ifTrue: [argNodes do: [:a | self typeOf: a in: env]. self countSend: rt result: Type dynamic node: aNode selector: aSymbol. ^ Type dynamic].
	found := p signaturesFor: aSymbol.
	found notNil ifTrue: [^ self apply: {found first. found last} to: rt instance: nil args: argNodes node: aNode in: env].
	(Object lookupSelector: aSymbol) isNil ifTrue: [
		argNodes do: [:x | self typeOf: x in: env].
		self note: #dnu at: aNode text: rt name , ' does not answer #' , aSymbol.
		self countSend: rt result: Type dynamic node: aNode selector: aSymbol.
		^ Type dynamic].
	^ self sendToInstance: aSymbol to: (Type of: Object) lookup: nil args: argNodes node: aNode in: env
]

{ #category : #sending }
MethodTypeCheck >> unannotated: aMethodOrNil selector: aSymbol to: rt from: aBehavior args: argNodes node: aNode in: env [
	"A send no signature covers: a diagnostic when nothing implements it, else Dynamic or the callee's inferred result."
	| r |
	argNodes do: [:a | self typeOf: a in: env].
	aMethodOrNil isNil ifTrue: [
		(aBehavior lookupSelector: #doesNotUnderstand:) methodClass == Object ifTrue: [
			self note: #dnu at: aNode text: rt printString , ' does not understand #' , aSymbol].
		self countSend: rt result: Type dynamic node: aNode selector: aSymbol.
		^ Type dynamic].
	r := checker inferredReturnOf: aMethodOrNil.
	deps add: 'body:' , (checker keyOf: aSymbol in: aMethodOrNil methodClass).
	r := self resolveSelf: r to: rt.
	self countSend: rt result: r node: aNode selector: aSymbol.
	^ r
]

{ #category : #sending }
MethodTypeCheck >> understands: aSymbol type: aType [
	"Whether a member of a union answers aSymbol, by signature or by lookup (types that are not classes do)."
	aType isClassType ifTrue: [
		^ (ann signaturesFor: aSymbol from: aType cls) notNil or: [(aType cls lookupSelector: aSymbol) notNil]].
	aType isMetaType ifTrue: [
		^ (ann signaturesFor: aSymbol from: aType cls class) notNil or: [(aType cls class lookupSelector: aSymbol) notNil]].
	^ true
]

{ #category : #signatures }
MethodTypeCheck >> contradiction: aSignature against: inherited map: aDictionary self: selfT instance: inst [
	"Why aSignature contradicts the inherited signature, or nil."
	| mine theirs dyn a b |
	dyn := [:sig | | d | d := Dictionary new. sig vars do: [:v | d at: v put: Type dynamic]. d].
	mine := [:t | (t substitute: (dyn value: aSignature) self: selfT instance: inst)].
	theirs := [:t | ((t substitute: aDictionary self: selfT instance: inst) substitute: (dyn value: inherited) self: selfT instance: inst)].
	1 to: (aSignature argTypes size min: inherited argTypes size) do: [:i |
		a := mine value: (aSignature argTypes at: i).
		b := theirs value: (inherited argTypes at: i).
		((checker isSubtype: a of: b) or: [checker isSubtype: b of: a]) ifFalse: [
			^ aSignature printString , ': argument ' , i printString , ' is ' , a printString , ', unrelated to ' , b printString]].
	a := mine value: aSignature result.
	b := theirs value: inherited result.
	(checker isSubtype: a of: b) ifFalse: [^ aSignature printString , ': answers ' , a printString , ', not a ' , b printString].
	^ nil
]

{ #category : #signatures }
MethodTypeCheck >> runSignature [
	"A signature without a method (docs/modules/types-2.md): a #signature diagnostic when nothing in its class, above it or below it, has a method of its selector (open question 3), and one for each of its signatures that contradicts the first method or signature above its class for the selector (a result that is not the inherited one's subtype, or an argument related to the inherited one's in neither direction: Number's comparisons narrow Magnitude's on purpose). A narrowing is read with Self as the signature's class and method variables as Dynamic."
	| tc sigs selfT inst |
	(Smalltalk signatureOf: selector in: behavior) isNil ifTrue: [^ self].
	parsed := true.
	tc := ann typedClass: base.
	(tc problemsOf: key) do: [:t | self note: #annotation at: nil text: t].
	sigs := tc signaturesAt: selector meta: meta.
	sigs isNil ifTrue: [^ self].
	deps add: sigs first key; add: 'sel:' , selector.
	self signatureIsAnswered ifFalse: [
		self note: #signature at: nil text: 'nothing answers #' , selector , ': no method of it in ' , behavior name , ', above it or below it'].
	behavior superclass isNil ifTrue: [^ self].
	selfT := meta
		ifTrue: [MetaType cls: base]
		ifFalse: [NominalType cls: base args: ((ann paramsOf: base) collect: [:p | TypeVariable named: p]) asArray].
	inst := NominalType cls: base args: #().
	(ann signaturesFor: selector from: behavior superclass) ifNotNil: [:found | | theirs map |
		theirs := found last.
		deps add: theirs first key.
		map := (meta or: [found first isMeta]) ifTrue: [Dictionary new] ifFalse: [ann map: selfT to: found first].
		sigs doWithIndex: [:s :i | | t |
			t := theirs at: (i min: theirs size).
			(self contradiction: s against: t map: map self: selfT instance: inst) ifNotNil: [:why |
				self note: #signature at: nil text: why , ' where ' , found first name , '>>' , selector , ' says ' , t printString]]]
]

{ #category : #signatures }
MethodTypeCheck >> signatureIsAnswered [
	"Whether a method of the selector is in the signature's class, above it, or in a subclass (on the same side)."
	(behavior lookupSelector: selector) notNil ifTrue: [^ true].
	^ base allSubclasses anySatisfy: [:c | (meta ifTrue: [c class] ifFalse: [c]) includesSelector: selector]
]

{ #category : #walking }
MethodTypeCheck >> assign: aVariableNode type: aType in: env node: aNode [
	| n e declared |
	n := aVariableNode name.
	e := env envDeclaring: n.
	(e notNil and: [env depth = e depth])
		ifTrue: [env forgetNarrowing: n]
		ifFalse: [env join: n with: aType by: checker].
	e notNil ifTrue: [
		env depth > e depth
			ifTrue: [
				e vars at: n put: (checker join: (e vars at: n) with: aType).
				env narrow: n to: aType]
			ifFalse: [e vars at: n put: aType].
		^ self].
	(ivarNames includes: n) ifTrue: [
		declared := self ivarType: n.
		(checker isSubtype: aType of: declared) ifTrue: [env narrow: n to: aType].
		(checker isSubtype: aType of: declared) ifFalse: [
			self note: #assignType at: aNode text: n , ' is ' , declared printString , ', assigned ' , aType printString].
		^ self]
]

{ #category : #walking }
MethodTypeCheck >> block: aBlockNode expected: aTypeOrNil in: env [
	"Check a block literal, its arguments typed by the expected block type when its arity fits; answer its block type."
	| e argTypes result |
	(self assignsOuter: aBlockNode in: env) ifTrue: [self prepass: [self blockOnce: aBlockNode expected: aTypeOrNil in: env]].
	^ self blockOnce: aBlockNode expected: aTypeOrNil in: env
]

{ #category : #walking }
MethodTypeCheck >> blockOnce: aBlockNode expected: aTypeOrNil in: env [
	| e argTypes result |
	e := TypeScope parent: env.
	argTypes := OrderedCollection new.
	aBlockNode arguments doWithIndex: [:a :i | | t |
		t := (aTypeOrNil notNil and: [aTypeOrNil isBlockType and: [aTypeOrNil args size = aBlockNode numArgs]])
			ifTrue: [aTypeOrNil args at: i]
			ifFalse: [Type dynamic].
		argTypes add: t.
		e declare: a first type: t].
	aBlockNode temporaries do: [:t | e declare: t first type: UnassignedType new].
	result := self statements: aBlockNode statements in: e method: false.
	^ BlockType args: argTypes asArray result: result
]

{ #category : #walking }
MethodTypeCheck >> cascade: aNode in: env [
	| rt t |
	rt := self typeOf: aNode receiver in: env.
	t := rt.
	aNode messages do: [:m |
		t := self send: (m at: 1) to: rt lookup: nil args: (m at: 2) node: aNode in: env].
	^ t
]

{ #category : #walking }
MethodTypeCheck >> checkReturn: aType node: aNode [
	returns add: aType.
	declaredReturn ifNil: [^ self].
	(checker isSubtype: aType of: declaredReturn) ifFalse: [
		self note: #returnType at: aNode text: 'answers ' , aType printString , ' where ' , declaredReturn printString , ' is declared']
]

{ #category : #walking }
MethodTypeCheck >> ivarType: aName [
	^ (ann ivarTypeOf: aName in: base)
		ifNil: [Type dynamic]
		ifNotNil: [:t | deps add: 'ivars:' , base name. t substitute: Dictionary new self: selfType instance: nil]
]

{ #category : #walking }
MethodTypeCheck >> literalType: anObject [
	anObject isNil ifTrue: [^ Type nilType].
	(anObject == true or: [anObject == false]) ifTrue: [^ Type of: Boolean].
	anObject isInteger ifTrue: [^ Type of: Integer].
	anObject isFloat ifTrue: [^ Type of: Float].
	anObject isSymbol ifTrue: [^ Type of: Symbol].
	anObject isString ifTrue: [^ Type of: String].
	^ Type of: anObject class
]

{ #category : #walking }
MethodTypeCheck >> message: aNode in: env [
	| rt narrowed |
	aNode isSuper ifTrue: [
		base superclass isNil ifTrue: [aNode arguments do: [:a | self typeOf: a in: env]. ^ Type dynamic].
		^ self send: aNode selector to: selfType lookup: base superclass args: aNode arguments node: aNode in: env].
	narrowed := self nilTestIn: aNode in: env.
	narrowed notNil ifTrue: [^ narrowed].
	((aNode selector == #whileTrue: or: [aNode selector == #whileFalse:]) and: [aNode receiver class == BlockNode and: [aNode arguments first class == BlockNode]])
		ifTrue: [^ self loop: aNode in: env].
	rt := self typeOf: aNode receiver in: env.
	^ self send: aNode selector to: rt lookup: nil args: aNode arguments node: aNode in: env
]

{ #category : #walking }
MethodTypeCheck >> statements: anArray in: env method: isMethod [
	"The type of the last statement (Nil for none); a method that does not end in a return answers self."
	| t |
	t := Type nilType.
	anArray do: [:st |
		t := self typeOf: st in: env.
		self narrowAfter: st in: env].
	(isMethod and: [anArray isEmpty or: [anArray last class ~~ ReturnNode]]) ifTrue: [
		fellOff := true.
		declaredReturn ifNotNil: [:r |
			(checker isSubtype: selfType of: r) ifFalse: [
				self note: #returnType at: (anArray isEmpty ifTrue: [nil] ifFalse: [anArray last]) text: 'answers self (' , selfType printString , ') where ' , r printString , ' is declared']]].
	(anArray notEmpty and: [anArray last class == ReturnNode]) ifTrue: [^ Type dynamic].
	^ t
]

{ #category : #walking }
MethodTypeCheck >> typeOf: aNode in: env [
	| c t |
	c := aNode class.
	c == LiteralNode ifTrue: [^ self literalType: aNode value].
	c == VariableNode ifTrue: [^ self variableType: aNode in: env].
	c == AssignmentNode ifTrue: [
		"a block assigned to a variable may name the variable (a recursive block): it is not nil inside"
		(aNode value class == BlockNode and: [(env envDeclaring: aNode variable name) notNil]) ifTrue: [
			(env envDeclaring: aNode variable name) vars at: aNode variable name put: UnassignedType new.
			env forgetNarrowing: aNode variable name].
		t := self typeOf: aNode value in: env.
		self assign: aNode variable type: t in: env node: aNode.
		^ t].
	c == MessageNode ifTrue: [^ self message: aNode in: env].
	c == CascadeNode ifTrue: [^ self cascade: aNode in: env].
	c == BlockNode ifTrue: [^ self block: aNode expected: nil in: env].
	c == BraceNode ifTrue: [
		t := nil.
		aNode elements do: [:e | t := checker join: t with: (self typeOf: e in: env) withoutSelfMark].
		"elements of unrelated classes are a tuple, which the language has no type for: Array[Dynamic]"
		(t notNil and: [t isUnion or: [t isClassType and: [t cls == Object]]]) ifTrue: [t := Type dynamic].
		^ NominalType cls: Array args: {t ifNil: [Type dynamic]}].
	c == ReturnNode ifTrue: [
		t := self typeOf: aNode value in: env.
		self checkReturn: t node: aNode.
		^ Type dynamic].
	^ Type dynamic
]

{ #category : #walking }
MethodTypeCheck >> variableType: aNode in: env [
	| n e |
	n := aNode name.
	(n = 'self' or: [n = 'super']) ifTrue: [^ selfType].
	n = 'thisContext' ifTrue: [^ Type of: Context].
	(env narrowingOf: n) ifNotNil: [:t |
		quiet ifFalse: [(env narrowingKindOf: n) ifNotNil: [:k | | orig |
			orig := (env envDeclaring: n) ifNotNil: [:x | x vars at: n] ifNil: [(ivarNames includes: n) ifTrue: [self ivarType: n]].
			(k ~~ #assignment and: [orig notNil and: [orig isUnion or: [orig isNilType or: [k == #typeTest and: [orig isDynamic not and: [(checker isSubtype: orig of: t) not]]]]]]) ifTrue: [
				checker count: 'narrowRead ' , k , ((ivarNames includes: n) ifTrue: [' ivar'] ifFalse: [' local'])]]].
		^ t].
	e := env envDeclaring: n.
	e notNil ifTrue: [^ e vars at: n].
	(ivarNames includes: n) ifTrue: [^ self ivarType: n].
	(behavior bindingOf: n) notNil ifTrue: [^ Type dynamic].
	(Smalltalk classNamed: n) ifNotNil: [:cl | ^ MetaType cls: cl].
	^ Type dynamic
]

{ #category : #'instance creation' }
MethodTypeCheck class >> checker: aChecker behavior: aBehavior selector: aSymbol [
	^ self new setChecker: aChecker behavior: aBehavior selector: aSymbol
]
