"Checks one method's parse tree (the kernel compiler's Parser) against the annotations: types each expression, checks each send, assignment and return, and records the diagnostics, the counts the experiment reports (sends; sends whose receiver type is known; sends resolved to a signature; sends whose result is known) and the dependency keys the check read. Quiet (inference of an unannotated callee's result) records nothing but the returns."
Class {
	#name : #OTMethodCheck,
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
		'parsed'
	]
}

{ #category : #accessing }
OTMethodCheck >> beQuiet [
	quiet := true
]

{ #category : #accessing }
OTMethodCheck >> deps [
	^ deps
]

{ #category : #accessing }
OTMethodCheck >> diagnostics [
	^ diagnostics
]

{ #category : #accessing }
OTMethodCheck >> hasSignature [
	^ sig notNil
]

{ #category : #accessing }
OTMethodCheck >> inferredResult [
	"The join of every returned type (Self when the method falls off its end), with the receiver's mark kept so a caller can substitute its own receiver."
	| t |
	t := nil.
	returns do: [:r | t := checker join: t with: r].
	fellOff ifTrue: [t := checker join: t with: selfType].
	^ t ifNil: [OTType dynamic]
]

{ #category : #accessing }
OTMethodCheck >> key [
	^ key
]

{ #category : #accessing }
OTMethodCheck >> knownResults [
	^ knownResults
]

{ #category : #accessing }
OTMethodCheck >> knownSends [
	^ knownSends
]

{ #category : #accessing }
OTMethodCheck >> parsed [
	^ parsed
]

{ #category : #accessing }
OTMethodCheck >> sends [
	^ sends
]

{ #category : #accessing }
OTMethodCheck >> types [
	"With recordTypes: {start. end. receiver type. selector} of every send."
	^ types
]

{ #category : #accessing }
OTMethodCheck >> typedSends [
	^ typedSends
]

{ #category : #accessing }
OTMethodCheck >> setChecker: aChecker behavior: aBehavior selector: aSymbol [
	checker := aChecker.
	ann := aChecker annotations.
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

{ #category : #diagnostics }
OTMethodCheck >> note: aKind at: aNode text: aString [
	quiet ifTrue: [^ self].
	diagnostics add: (OTDiagnostic kind: aKind where: key line: (aNode ifNil: [0] ifNotNil: [:n | n line]) text: aString
		start: (aNode ifNotNil: [:n | n sourceStart]) end: (aNode ifNotNil: [:n | n sourceEnd]))
]

{ #category : #running }
OTMethodCheck >> run [
	| m tree env params sigMap |
	m := behavior compiledMethodAt: selector ifAbsent: [nil].
	m isNil ifTrue: [^ self].
	source := m sourceCode.
	source isNil ifTrue: [^ self].
	tree := [Parser parse: source] on: CompileError do: [:e | self note: #parse at: nil text: e messageText. e return: nil].
	tree isNil ifTrue: [^ self].
	parsed := true.
	params := ann paramsOf: base.
	meta
		ifTrue: [
			selfType := OTMetaType cls: base selfKind: #self.
			instType := OTClassType cls: base args: (params collect: [:p | OTVar named: p]) selfKind: #instance.
			ivarNames := #()]
		ifFalse: [
			selfType := OTClassType cls: base args: (params collect: [:p | OTVar named: p]) selfKind: #self.
			instType := nil.
			ivarNames := (Smalltalk instanceVariableNamesOf: base) collect: [:s | s asString]].
	(ann signaturesFor: selector meta: meta from: base) ifNotNil: [:found |
		sig := found last last.
		deps add: sig key.
		sigMap := meta ifTrue: [Dictionary new] ifFalse: [ann map: selfType to: found first].
		declaredReturn := sig result substitute: sigMap self: nil instance: nil].
	env := OTEnv parent: nil.
	tree arguments doWithIndex: [:a :i |
		env declare: a first type: ((sig notNil and: [sig argTypes size = tree arguments size])
			ifTrue: [(sig argTypes at: i) substitute: sigMap self: selfType instance: instType]
			ifFalse: [OTType dynamic])].
	tree temporaries do: [:t | env declare: t first type: OTType nilType].
	self statements: tree statements in: env method: true
]

{ #category : #walking }
OTMethodCheck >> statements: anArray in: env method: isMethod [
	"The type of the last statement (Nil for none); a method that does not end in a return answers self."
	| t |
	t := OTType nilType.
	anArray do: [:st |
		t := self typeOf: st in: env.
		self narrowAfter: st in: env].
	(isMethod and: [anArray isEmpty or: [anArray last class ~~ ReturnNode]]) ifTrue: [
		fellOff := true.
		declaredReturn ifNotNil: [:r |
			(checker isSubtype: selfType of: r) ifFalse: [
				self note: #returnType at: (anArray isEmpty ifTrue: [nil] ifFalse: [anArray last]) text: 'answers self (' , selfType printString , ') where ' , r printString , ' is declared']]].
	(anArray notEmpty and: [anArray last class == ReturnNode]) ifTrue: [^ OTType dynamic].
	^ t
]

{ #category : #walking }
OTMethodCheck >> typeOf: aNode in: env [
	| c t |
	c := aNode class.
	c == LiteralNode ifTrue: [^ self literalType: aNode value].
	c == VariableNode ifTrue: [^ self variableType: aNode in: env].
	c == AssignmentNode ifTrue: [
		t := self typeOf: aNode value in: env.
		self assign: aNode variable type: t in: env node: aNode.
		^ t].
	c == MessageNode ifTrue: [^ self message: aNode in: env].
	c == CascadeNode ifTrue: [^ self cascade: aNode in: env].
	c == BlockNode ifTrue: [^ self block: aNode expected: nil in: env].
	c == BraceNode ifTrue: [
		t := nil.
		aNode elements do: [:e | t := checker join: t with: (self typeOf: e in: env) withoutSelfMark].
		^ OTClassType cls: Array args: {t ifNil: [OTType dynamic]}].
	c == ReturnNode ifTrue: [
		t := self typeOf: aNode value in: env.
		self checkReturn: t node: aNode.
		^ OTType dynamic].
	^ OTType dynamic
]

{ #category : #walking }
OTMethodCheck >> literalType: anObject [
	anObject isNil ifTrue: [^ OTType nilType].
	(anObject == true or: [anObject == false]) ifTrue: [^ OTType of: Boolean].
	anObject isInteger ifTrue: [^ OTType of: Integer].
	anObject isFloat ifTrue: [^ OTType of: Float].
	anObject isSymbol ifTrue: [^ OTType of: Symbol].
	anObject isString ifTrue: [^ OTType of: String].
	^ OTType of: anObject class
]

{ #category : #walking }
OTMethodCheck >> variableType: aNode in: env [
	| n e |
	n := aNode name.
	(n = 'self' or: [n = 'super']) ifTrue: [^ selfType].
	n = 'thisContext' ifTrue: [^ OTType of: Context].
	(env narrowingOf: n) ifNotNil: [:t | ^ t].
	e := env envDeclaring: n.
	e notNil ifTrue: [^ e vars at: n].
	(ivarNames includes: n) ifTrue: [^ self ivarType: n].
	(behavior bindingOf: n) notNil ifTrue: [
		^ (ann cvarTypeOf: n in: base) ifNil: [OTType dynamic] ifNotNil: [:t | deps add: 'ivars:' , base name. t]].
	(Smalltalk classNamed: n) ifNotNil: [:cl | ^ OTMetaType cls: cl].
	^ OTType dynamic
]

{ #category : #walking }
OTMethodCheck >> ivarType: aName [
	^ (ann ivarTypeOf: aName in: base)
		ifNil: [OTType dynamic]
		ifNotNil: [:t | deps add: 'ivars:' , base name. t substitute: Dictionary new self: selfType instance: nil]
]

{ #category : #walking }
OTMethodCheck >> assign: aVariableNode type: aType in: env node: aNode [
	| n e declared |
	n := aVariableNode name.
	env forgetNarrowing: n.
	e := env envDeclaring: n.
	e notNil ifTrue: [
		e vars at: n put: (env depth > e depth
			ifTrue: [checker join: (e vars at: n) with: aType]
			ifFalse: [aType]).
		^ self].
	(ivarNames includes: n) ifTrue: [
		declared := self ivarType: n.
		(checker isSubtype: aType of: declared) ifFalse: [
			self note: #assignType at: aNode text: n , ' is ' , declared printString , ', assigned ' , aType printString].
		^ self].
	(behavior bindingOf: n) notNil ifTrue: [
		(ann cvarTypeOf: n in: base) ifNotNil: [:declaredC |
			(checker isSubtype: aType of: declaredC) ifFalse: [
				self note: #assignType at: aNode text: n , ' is ' , declaredC printString , ', assigned ' , aType printString]]]
]

{ #category : #walking }
OTMethodCheck >> checkReturn: aType node: aNode [
	returns add: aType.
	declaredReturn ifNil: [^ self].
	(checker isSubtype: aType of: declaredReturn) ifFalse: [
		self note: #returnType at: aNode text: 'answers ' , aType printString , ' where ' , declaredReturn printString , ' is declared']
]

{ #category : #walking }
OTMethodCheck >> block: aBlockNode expected: aTypeOrNil in: env [
	"Check a block literal, its arguments typed by the expected block type when its arity fits; answer its block type."
	| e argTypes result |
	e := OTEnv parent: env.
	argTypes := OrderedCollection new.
	aBlockNode arguments doWithIndex: [:a :i | | t |
		t := (aTypeOrNil notNil and: [aTypeOrNil isBlockType and: [aTypeOrNil args size = aBlockNode numArgs]])
			ifTrue: [aTypeOrNil args at: i]
			ifFalse: [OTType dynamic].
		argTypes add: t.
		e declare: a first type: t].
	aBlockNode temporaries do: [:t | e declare: t first type: OTType nilType].
	result := self statements: aBlockNode statements in: e method: false.
	^ OTBlockType args: argTypes asArray result: result
]

{ #category : #walking }
OTMethodCheck >> cascade: aNode in: env [
	| rt t |
	rt := self typeOf: aNode receiver in: env.
	t := rt.
	aNode messages do: [:m |
		t := self send: (m at: 1) to: rt lookup: nil args: (m at: 2) node: aNode in: env].
	^ t
]

{ #category : #walking }
OTMethodCheck >> message: aNode in: env [
	| rt narrowed |
	aNode isSuper ifTrue: [
		base superclass isNil ifTrue: [aNode arguments do: [:a | self typeOf: a in: env]. ^ OTType dynamic].
		^ self send: aNode selector to: selfType lookup: base superclass args: aNode arguments node: aNode in: env].
	narrowed := self nilTestIn: aNode in: env.
	narrowed notNil ifTrue: [^ narrowed].
	rt := self typeOf: aNode receiver in: env.
	^ self send: aNode selector to: rt lookup: nil args: aNode arguments node: aNode in: env
]

{ #category : #narrowing }
OTMethodCheck >> nilTested: aNode [
	"{variable name. #notNil or #isNil} when aNode is a nil test of a variable (v isNil, v notNil, v == nil, v ~~ nil, v = nil, v ~= nil), else nil."
	| r s |
	aNode class == MessageNode ifFalse: [^ nil].
	r := aNode receiver.
	r class == VariableNode ifFalse: [^ nil].
	(#('self' 'super' 'thisContext') includes: r name) ifTrue: [^ nil].
	s := aNode selector.
	s == #isNil ifTrue: [^ {r name. #isNil}].
	s == #notNil ifTrue: [^ {r name. #notNil}].
	((s == #== or: [s == #=]) and: [aNode arguments first class == LiteralNode and: [aNode arguments first value isNil]]) ifTrue: [^ {r name. #isNil}].
	((s == #~~ or: [s == #~=]) and: [aNode arguments first class == LiteralNode and: [aNode arguments first value isNil]]) ifTrue: [^ {r name. #notNil}].
	^ nil
]

{ #category : #narrowing }
OTMethodCheck >> nilTestIn: aNode in: env [
	"The nil tests the experiment narrows on: the ifNil: family on a variable's type, and a block run only when a variable is not nil (v notNil ifTrue: [...], v isNil ifFalse: [...], v notNil and: [...], ifTrue:ifFalse: likewise). Answers the send's type, or nil when aNode is none of them."
	| test sel rt nn args blockT r b0 b1 |
	sel := aNode selector.
	args := aNode arguments.
	(#(#ifNil: #ifNotNil: #ifNil:ifNotNil: #ifNotNil:ifNil:) includes: sel) ifTrue: [
		(args allSatisfy: [:a | a class == BlockNode]) ifFalse: [^ nil].
		rt := self typeOf: aNode receiver in: env.
		self countSend: rt result: OTType dynamic node: aNode selector: sel.
		nn := rt withoutNil.
		r := nil.
		args do: [:blk | | expect |
			expect := (blk numArgs = 1) ifTrue: [OTBlockType args: {nn} result: OTType dynamic] ifFalse: [nil].
			blockT := self block: blk expected: expect in: env.
			r := checker join: r with: blockT result].
		(sel == #ifNil: and: [rt isDynamic not]) ifTrue: [r := checker join: r with: nn].
		(sel == #ifNotNil:) ifTrue: [r := checker join: r with: OTType nilType].
		^ r].
	(#(#ifTrue: #ifFalse: #and: #or: #ifTrue:ifFalse: #ifFalse:ifTrue:) includes: sel) ifFalse: [^ nil].
	test := self nilTested: aNode receiver.
	test isNil ifTrue: [^ nil].
	(args allSatisfy: [:a | a class == BlockNode]) ifFalse: [^ nil].
	rt := self typeOf: aNode receiver in: env.
	self countSend: rt result: (OTType of: Boolean) node: aNode selector: sel.
	"which block runs when the variable is not nil"
	b0 := args first.
	b1 := args size > 1 ifTrue: [args last] ifFalse: [nil].
	r := nil.
	args do: [:blk | | e nonNilBranch |
		nonNilBranch := (test last == #notNil and: [(#(#ifTrue: #and: ) includes: sel) or: [(sel == #ifTrue:ifFalse: and: [blk == b0]) or: [sel == #ifFalse:ifTrue: and: [blk == b1]]]])
			or: [test last == #isNil and: [(#(#ifFalse: #or:) includes: sel) or: [(sel == #ifTrue:ifFalse: and: [blk == b1]) or: [sel == #ifFalse:ifTrue: and: [blk == b0]]]]].
		e := OTEnv parent: env.
		nonNilBranch ifTrue: [(self currentTypeOf: test first in: env) ifNotNil: [:t | e narrow: test first to: t withoutNil]].
		r := checker join: r with: (self statements: blk statements in: e method: false)].
	(#(#ifTrue: #ifFalse:) includes: sel) ifTrue: [r := checker join: r with: OTType nilType].
	(#(#and: #or:) includes: sel) ifTrue: [r := OTType of: Boolean].
	^ r
]

{ #category : #narrowing }
OTMethodCheck >> currentTypeOf: aName in: env [
	| e |
	(env narrowingOf: aName) ifNotNil: [:t | ^ t].
	e := env envDeclaring: aName.
	e notNil ifTrue: [^ e vars at: aName].
	(ivarNames includes: aName) ifTrue: [^ self ivarType: aName].
	^ nil
]

{ #category : #narrowing }
OTMethodCheck >> narrowAfter: aStatement in: env [
	"After `v isNil ifTrue: [^ ...]`, `v notNil ifFalse: [^ ...]` or `v ifNil: [^ ...]`, v is not nil for the rest of the scope."
	| sel test blk name |
	aStatement class == MessageNode ifFalse: [^ self].
	sel := aStatement selector.
	blk := aStatement arguments isEmpty ifTrue: [nil] ifFalse: [aStatement arguments first].
	(blk notNil and: [blk class == BlockNode and: [blk statements notEmpty and: [blk statements last class == ReturnNode]]]) ifFalse: [^ self].
	name := nil.
	sel == #ifNil: ifTrue: [
		(aStatement receiver class == VariableNode) ifTrue: [name := aStatement receiver name]].
	(sel == #ifTrue: or: [sel == #ifFalse:]) ifTrue: [
		test := self nilTested: aStatement receiver.
		(test notNil and: [(sel == #ifTrue: and: [test last == #isNil]) or: [sel == #ifFalse: and: [test last == #notNil]]])
			ifTrue: [name := test first]].
	name isNil ifTrue: [^ self].
	(self currentTypeOf: name in: env) ifNotNil: [:t | env narrow: name to: t withoutNil]
]

{ #category : #sending }
OTMethodCheck >> countSend: rt result: aType node: aNode selector: aSymbol [
	quiet ifTrue: [^ self].
	sends := sends + 1.
	rt isKnown ifTrue: [knownSends := knownSends + 1].
	(rt isKnown and: [aType isKnown]) ifTrue: [knownResults := knownResults + 1].
	checker recordTypes ifTrue: [types add: {aNode sourceStart. aNode sourceEnd. rt. aSymbol}]
]

{ #category : #sending }
OTMethodCheck >> argTypesOf: argNodes in: env [
	^ argNodes collect: [:a | self typeOf: a in: env]
]

{ #category : #sending }
OTMethodCheck >> send: aSymbol to: rt lookup: lookupClassOrNil args: argNodes node: aNode in: env [
	"The type of a send, its diagnostics noted. lookupClassOrNil is the class a super send looks up from."
	| r members was |
	(rt isDynamic or: [rt isVar or: [rt class == OTSelf or: [rt class == OTInstance]]]) ifTrue: [
		argNodes do: [:a | self typeOf: a in: env].
		self countSend: rt result: OTType dynamic node: aNode selector: aSymbol.
		^ OTType dynamic].
	rt isUnion ifTrue: [
		members := rt members reject: [:m | m isNilType].
		(rt includesNil and: [checker nilStrict and: [(UndefinedObject lookupSelector: aSymbol) isNil]]) ifTrue: [
			self note: #maybeNil at: aNode text: '#' , aSymbol , ' sent to ' , rt printString].
		members size = 1 ifTrue: [^ self send: aSymbol to: members first lookup: nil args: argNodes node: aNode in: env].
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
		^ self send: aSymbol to: (OTType of: BlockClosure) lookup: nil args: argNodes node: aNode in: env].
	rt isMetaType ifTrue: [^ self sendToClass: aSymbol to: rt lookup: lookupClassOrNil args: argNodes node: aNode in: env].
	rt isClassType ifTrue: [^ self sendToInstance: aSymbol to: rt lookup: lookupClassOrNil args: argNodes node: aNode in: env].
	argNodes do: [:a | self typeOf: a in: env].
	^ OTType dynamic
]

{ #category : #sending }
OTMethodCheck >> sendToInstance: aSymbol to: rt lookup: lookupClassOrNil args: argNodes node: aNode in: env [
	| lc found m |
	lc := lookupClassOrNil ifNil: [rt cls].
	found := ann signaturesFor: aSymbol meta: false from: lc.
	found notNil ifTrue: [^ self apply: found to: rt instance: nil args: argNodes node: aNode in: env].
	quiet ifFalse: [deps add: 'sel:' , aSymbol].
	m := lc lookupSelector: aSymbol.
	^ self unannotated: m selector: aSymbol to: rt from: lc args: argNodes node: aNode in: env
]

{ #category : #sending }
OTMethodCheck >> sendToClass: aSymbol to: rt lookup: lookupClassOrNil args: argNodes node: aNode in: env [
	| lc found m inst |
	lc := lookupClassOrNil ifNil: [rt cls].
	found := ann signaturesFor: aSymbol meta: true from: lc.
	inst := OTClassType cls: rt cls args: #() selfKind: (rt selfKind == #self ifTrue: [#instance] ifFalse: [nil]).
	(rt selfKind == #self) ifTrue: [inst := instType].
	found notNil ifTrue: [^ self apply: found to: rt instance: inst args: argNodes node: aNode in: env].
	quiet ifFalse: [deps add: 'sel:' , aSymbol].
	m := lc class lookupSelector: aSymbol.
	^ self unannotated: m selector: aSymbol to: rt from: lc class args: argNodes node: aNode in: env
]

{ #category : #sending }
OTMethodCheck >> unannotated: aMethodOrNil selector: aSymbol to: rt from: aBehavior args: argNodes node: aNode in: env [
	"A send no signature covers: a diagnostic when nothing implements it, else Dynamic or the callee's inferred result."
	| r |
	argNodes do: [:a | self typeOf: a in: env].
	aMethodOrNil isNil ifTrue: [
		(aBehavior lookupSelector: #doesNotUnderstand:) methodClass == Object ifTrue: [
			self note: #dnu at: aNode text: rt printString , ' does not understand #' , aSymbol].
		self countSend: rt result: OTType dynamic node: aNode selector: aSymbol.
		^ OTType dynamic].
	r := checker inferredReturnOf: aMethodOrNil.
	r isDynamic ifFalse: [quiet ifFalse: [deps add: 'body:' , (checker keyOf: aSymbol in: aMethodOrNil methodClass)]].
	r := self resolveSelf: r to: rt.
	self countSend: rt result: r node: aNode selector: aSymbol.
	^ r
]

{ #category : #sending }
OTMethodCheck >> understands: aSymbol type: aType [
	"Whether a member of a union answers aSymbol, by signature or by lookup (types that are not classes do)."
	aType isClassType ifTrue: [
		^ (ann signaturesFor: aSymbol meta: false from: aType cls) notNil or: [(aType cls lookupSelector: aSymbol) notNil]].
	aType isMetaType ifTrue: [
		^ (ann signaturesFor: aSymbol meta: true from: aType cls) notNil or: [(aType cls class lookupSelector: aSymbol) notNil]].
	^ true
]

{ #category : #sending }
OTMethodCheck >> resolveSelf: aType to: rt [
	"An inferred result with the callee's receiver mark, in terms of this send's receiver."
	aType isUnion ifTrue: [^ OTType union: (aType members collect: [:m | self resolveSelf: m to: rt])].
	((aType isClassType or: [aType isMetaType]) and: [aType selfKind == #self]) ifTrue: [^ rt].
	(aType isClassType and: [aType selfKind == #instance]) ifTrue: [
		^ rt isMetaType ifTrue: [OTClassType cls: rt cls args: #()] ifFalse: [aType withoutSelfMark]].
	^ aType
]

{ #category : #sending }
OTMethodCheck >> apply: found to: rt instance: instanceType args: argNodes node: aNode in: env [
	"A send covered by a signature: bind the receiver's type arguments, infer the method's variables from the arguments (blocks typed by what is expected of them), check every argument, answer the result."
	| defClass sigs s map vars bind argTypes params result leftover |
	defClass := found first.
	sigs := found last.
	map := rt isClassType ifTrue: [ann map: rt to: defClass] ifFalse: [Dictionary new].
	s := self chooseSignature: sigs map: map receiver: rt instance: instanceType args: argNodes in: env.
	quiet ifFalse: [deps add: s key].
	s argTypes size = argNodes size ifFalse: [
		self note: #annotation at: aNode text: s key , ' has ' , s argTypes size printString , ' argument types'.
		argNodes do: [:a | self typeOf: a in: env].
		^ OTType dynamic].
	vars := checker genericMethods ifTrue: [s vars] ifFalse: [Set new].
	checker genericMethods ifFalse: [s vars do: [:v | map at: v put: OTType dynamic]].
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
	vars do: [:v | (bind includesKey: v) ifFalse: [leftover at: v put: OTType dynamic]].
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
OTMethodCheck >> dynamicVars: aSet in: aType except: aDictionary [
	"aType with the variables of aSet not yet bound made Dynamic in block arguments (a block's argument cannot wait for inference); the result keeps them to be bound by the block."
	| d |
	aType isBlockType ifFalse: [^ aType].
	d := Dictionary new.
	aSet do: [:v | (aDictionary includesKey: v) ifFalse: [d at: v put: OTType dynamic]].
	^ OTBlockType args: (aType args collect: [:t | t substitute: d self: nil instance: nil]) result: aType result
]

{ #category : #sending }
OTMethodCheck >> chooseSignature: sigs map: map receiver: rt instance: instanceType args: argNodes in: env [
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

{ #category : #'instance creation' }
OTMethodCheck class >> checker: aChecker behavior: aBehavior selector: aSymbol [
	^ self new setChecker: aChecker behavior: aBehavior selector: aSymbol
]
