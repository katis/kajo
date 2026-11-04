"The compiler in Smalltalk: parse (Parser), analyse (scopes, captures, temp vectors), generate and assemble (BytecodeGenerator) a method of a class into CompiledCode. It follows the bootstrap compiler's rules exactly (Sources/KajoCompiler/Compiler.swift); CompilerTest compiles every method of the image with it and compares the result with the installed method, which the bootstrap compiled."
Class {
	#name : #Compiler,
	#superclass : #Object,
	#instVars : [
		'theClass',
		'instVarNames',
		'firstSlot',
		'seq',
		'labelCounter',
		'doit'
	],
	#category : #'Kernel-Compiler'
}

{ #category : #accessing }
Compiler class >> compile: aString in: aClass [
	^ self new setClass: aClass; compile: aString
]

{ #category : #evaluating }
Compiler class >> evaluate: aString [
	"The value of the statements aString holds, run once with nil as self (a doit: compiled as a method of UndefinedObject, made and verified by the VM, run, dropped; nothing is installed)."
	^ self evaluate: aString for: nil
]

{ #category : #evaluating }
Compiler class >> evaluate: aString for: anObject [
	"The value of the statements aString holds, run once with anObject as self: compiled as a method DoIt of anObject's class (its temporaries the method's, the last statement's value answered), made by the VM, run by valueWithReceiver:arguments:, never installed. A CompileError when the source or the VM refuses it, InstallForbidden in a release image."
	| method |
	Smalltalk isReleaseImage ifTrue: [^ InstallForbidden new behavior: anObject class selector: nil; signal].
	method := (self compileDoIt: aString in: anObject class) makeMethodIn: anObject class.
	^ method valueWithReceiver: anObject arguments: #()
]

{ #category : #evaluating }
Compiler class >> compileDoIt: aString in: aClass [
	"The CompiledCode of a doit: the method DoIt whose body is aString, answering its last statement's value."
	^ self new setClass: aClass; beDoIt; compile: 'DoIt ' , aString
]

{ #category : #accessing }
Compiler >> beDoIt [
	doit := true
]

{ #category : #accessing }
Compiler class >> inlinedSelectors [
	^ #(#ifTrue: #ifFalse: #and: #or: #ifNil: #timesRepeat: #ifTrue:ifFalse: #ifFalse:ifTrue: #ifNotNil: #ifNil:ifNotNil: #ifNotNil:ifNil: #whileTrue: #whileFalse: #whileTrue #whileFalse #repeat #to:do: #to:by:do:)
]

{ #category : #accessing }
Compiler >> setClass: aClass [
	theClass := aClass.
	instVarNames := (Smalltalk instanceVariableNamesOf: aClass) collect: [:s | s asString].
	firstSlot := aClass isMeta ifTrue: [5] ifFalse: [0].
	seq := 0.
	labelCounter := 0.
	doit := false
]

{ #category : #accessing }
Compiler >> fail: aString line: n [
	^ CompileError new line: n; signal: aString
]

{ #category : #accessing }
Compiler >> nextSeq [
	seq := seq + 1.
	^ seq
]

{ #category : #analysis }
Compiler >> declare: aName kind: aKind in: aScope line: n [
	| v |
	aKind == #hidden ifFalse: [
		(#('self' 'super' 'thisContext' 'nil' 'true' 'false') includes: aName) ifTrue: [^ self fail: '''' , aName , ''' cannot be a variable name' line: n].
		(aScope declared anySatisfy: [:x | x name = aName]) ifTrue: [^ self fail: '''' , aName , ''' declared twice' line: n].
		(theClass classVariableOwnerOf: aName) ifNotNil: [:owner |
			^ self fail: '''' , aName , ''' shadows ' , owner name , '''s class variable' line: n]].
	v := TempVariable name: aName kind: aKind scope: aScope seq: self nextSeq.
	aScope declared add: v.
	aScope real locals add: v.
	^ v
]

{ #category : #analysis }
Compiler >> lookup: aName in: aScope [
	| s |
	s := aScope.
	[s notNil] whileTrue: [
		s declared reverseDo: [:v | (v name = aName and: [v kind ~~ #hidden]) ifTrue: [^ v]].
		s := s parent].
	^ nil
]

{ #category : #analysis }
Compiler >> reference: v from: aScope [
	| r |
	r := aScope real.
	r == v real ifTrue: [^ self].
	v beCaptured.
	[r == v real] whileFalse: [
		(r needed identityIncludes: v) ifFalse: [r needed add: v].
		r := r parent real]
]

{ #category : #analysis }
Compiler >> resolve: aNode in: aScope [
	| n v i |
	n := aNode name.
	n = 'self' ifTrue: [^ aNode bind: #self to: nil].
	n = 'super' ifTrue: [^ aNode bind: #super to: nil].
	n = 'thisContext' ifTrue: [^ aNode bind: #thisContext to: nil].
	v := self lookup: n in: aScope.
	v ifNotNil: [:x | self reference: x from: aScope. ^ aNode bind: #local to: x].
	i := instVarNames indexOf: n.
	i > 0 ifTrue: [^ aNode bind: #instance to: firstSlot + i - 1].
	(theClass bindingOf: n) ifNotNil: [:b | ^ aNode bind: #classVariable to: b].
	(Smalltalk classNamed: n) ifNotNil: [:c | ^ aNode bind: #global to: c].
	^ self fail: 'undeclared variable ''' , n , '''' line: aNode line
]

{ #category : #analysis }
Compiler >> isBlock: aNode args: n [
	^ aNode class == BlockNode and: [aNode numArgs = n]
]

{ #category : #analysis }
Compiler >> inlinable: s [
	| a sel |
	s isSuper ifTrue: [^ false].
	a := s arguments.
	sel := s selector.
	(#(#ifTrue: #ifFalse: #and: #or: #ifNil: #timesRepeat:) includes: sel) ifTrue: [^ self isBlock: a first args: 0].
	(#(#ifTrue:ifFalse: #ifFalse:ifTrue:) includes: sel) ifTrue: [^ (self isBlock: a first args: 0) and: [self isBlock: a last args: 0]].
	sel == #ifNotNil: ifTrue: [^ (self isBlock: a first args: 0) or: [self isBlock: a first args: 1]].
	sel == #ifNil:ifNotNil: ifTrue: [^ (self isBlock: a first args: 0) and: [(self isBlock: a last args: 0) or: [self isBlock: a last args: 1]]].
	sel == #ifNotNil:ifNil: ifTrue: [^ ((self isBlock: a first args: 0) or: [self isBlock: a first args: 1]) and: [self isBlock: a last args: 0]].
	(#(#whileTrue: #whileFalse:) includes: sel) ifTrue: [^ (self isBlock: s receiver args: 0) and: [self isBlock: a first args: 0]].
	(#(#whileTrue #whileFalse #repeat) includes: sel) ifTrue: [^ self isBlock: s receiver args: 0].
	sel == #to:do: ifTrue: [^ self isBlock: a last args: 1].
	sel == #to:by:do: ifTrue: [
		^ (self isBlock: a last args: 1) and: [(a at: 2) class == LiteralNode and: [(a at: 2) value isInteger and: [(a at: 2) value ~= 0]]]].
	^ false
]

{ #category : #analysis }
Compiler >> isIntegerLiteral: aNode [
	^ aNode class == LiteralNode and: [aNode value isInteger]
]

{ #category : #analysis }
Compiler >> analyze: aNode in: aScope [
	| c s |
	c := aNode class.
	c == LiteralNode ifTrue: [^ self].
	c == VariableNode ifTrue: [^ self resolve: aNode in: aScope].
	c == AssignmentNode ifTrue: [
		self resolve: aNode variable in: aScope.
		aNode variable binding == #local ifTrue: [
			(#(#argument #inlinedArgument) includes: aNode variable target kind) ifTrue: [
				^ self fail: 'cannot assign to the argument ''' , aNode variable name , '''' line: aNode line].
			aNode variable target beWritten] ifFalse: [
		(#(#instance #classVariable) includes: aNode variable binding) ifFalse: [
			^ self fail: 'cannot assign to ''' , aNode variable name , '''' line: aNode line]].
		^ self analyze: aNode value in: aScope].
	c == MessageNode ifTrue: [
		(self inlinable: aNode) ifTrue: [aNode beInlined. ^ self analyzeInlined: aNode in: aScope].
		self analyze: aNode receiver in: aScope.
		aNode arguments do: [:x | self analyze: x in: aScope].
		^ self].
	c == CascadeNode ifTrue: [
		self analyze: aNode receiver in: aScope.
		aNode messages do: [:m | (m at: 2) do: [:x | self analyze: x in: aScope]].
		^ self].
	c == BraceNode ifTrue: [aNode elements do: [:e | self analyze: e in: aScope]. ^ self].
	c == BlockNode ifTrue: [
		s := CompilerScope parent: aScope real: true seq: self nextSeq.
		aNode scope: s.
		aNode arguments do: [:a | self declare: a first kind: #argument in: s line: (a at: 2)].
		s argumentCount: aNode numArgs.
		aNode temporaries do: [:t | self declare: t first kind: #temporary in: s line: (t at: 2)].
		^ self analyzeStatements: aNode statements in: s].
	c == ReturnNode ifTrue: [^ self analyze: aNode value in: aScope].
	^ self fail: 'unknown node' line: aNode line
]

{ #category : #analysis }
Compiler >> analyzeInlinedBlock: aNode in: aScope [
	| s |
	s := CompilerScope parent: aScope real: false seq: 0.
	aNode scope: s.
	self analyzeInlinedBody: aNode in: s
]

{ #category : #analysis }
Compiler >> analyzeLoopBody: aNode in: aScope [
	"An inlined loop's block: it owns a temp vector, made on every pass, for its captured and assigned variables."
	| s |
	s := CompilerScope loopIn: aScope seq: self nextSeq.
	aScope real loops add: s.
	aNode scope: s.
	self analyzeInlinedBody: aNode in: s
]

{ #category : #analysis }
Compiler >> analyzeInlinedBody: aNode in: s [
	aNode arguments do: [:a | self declare: a first kind: #inlinedArgument in: s line: (a at: 2)].
	aNode temporaries do: [:t | self declare: t first kind: #temporary in: s line: (t at: 2)].
	self analyzeStatements: aNode statements in: s
]

{ #category : #analysis }
Compiler >> analyzeInlined: s in: aScope [
	| sel a |
	sel := s selector.
	a := s arguments.
	(#(#whileTrue: #whileFalse: #whileTrue #whileFalse #repeat) includes: sel) ifTrue: [
		self analyzeLoopBody: s receiver in: aScope.
		a do: [:x | self analyzeLoopBody: x in: aScope].
		^ self].
	(#(#to:do: #to:by:do:) includes: sel) ifTrue: [
		self analyze: s receiver in: aScope.
		self analyze: a first in: aScope.
		sel == #to:by:do: ifTrue: [self analyze: (a at: 2) in: aScope].
		(self isIntegerLiteral: a first) ifFalse: [s hidden add: (self declare: '' kind: #hidden in: aScope line: s line)].
		^ self analyzeLoopBody: a last in: aScope].
	sel == #timesRepeat: ifTrue: [
		self analyze: s receiver in: aScope.
		s hidden add: (self declare: '' kind: #hidden in: aScope line: s line).
		(self isIntegerLiteral: s receiver) ifFalse: [s hidden add: (self declare: '' kind: #hidden in: aScope line: s line)].
		^ self analyzeLoopBody: a first in: aScope].
	self analyze: s receiver in: aScope.
	a do: [:x | self analyzeInlinedBlock: x in: aScope]
]

{ #category : #analysis }
Compiler >> analyzeStatements: aCollection in: aScope [
	aCollection do: [:st | self analyze: st in: aScope]
]

{ #category : #generation }
Compiler >> label [
	labelCounter := labelCounter + 1.
	^ 'L' , labelCounter printString
]

{ #category : #generation }
Compiler >> emit: e op: op [
	e add: {#op. op. 0. 0}
]

{ #category : #generation }
Compiler >> emit: e op: op a: a [
	e add: {#op. op. a. 0}
]

{ #category : #generation }
Compiler >> emit: e op: op a: a b: b [
	e add: {#op. op. a. b}
]

{ #category : #generation }
Compiler >> emit: e jump: op to: aLabel [
	e add: {#jump. op. aLabel}
]

{ #category : #generation }
Compiler >> emit: e label: aLabel [
	e add: {#label. aLabel}
]

{ #category : #generation }
Compiler >> push: v from: r on: e [
	v real == r ifTrue: [
		v inVector
			ifTrue: [^ self emit: e op: #pushTempVectorSlot a: v vectorSlot b: v owner vectorTemp]
			ifFalse: [^ self emit: e op: #pushTemp a: v index]].
	v inVector ifTrue: [^ self emit: e op: #pushTempVectorSlot a: v vectorSlot b: (r copiedIndex: v owner)].
	self emit: e op: #pushTemp a: (r copiedIndex: v)
]

{ #category : #generation }
Compiler >> store: v from: r on: e [
	v real == r ifTrue: [
		v inVector
			ifTrue: [^ self emit: e op: #storeTempVectorSlot a: v vectorSlot b: v owner vectorTemp]
			ifFalse: [^ self emit: e op: #storeTemp a: v index]].
	self emit: e op: #storeTempVectorSlot a: v vectorSlot b: (r copiedIndex: v owner)
]

{ #category : #generation }
Compiler >> pushLiteral: anObject on: e [
	(anObject isInteger and: [anObject between: -128 and: 127]) ifTrue: [^ self emit: e op: #pushInt a: anObject].
	anObject isNil ifTrue: [^ self emit: e op: #pushNil].
	anObject == true ifTrue: [^ self emit: e op: #pushTrue].
	anObject == false ifTrue: [^ self emit: e op: #pushFalse].
	e add: {#literal. anObject}
]

{ #category : #generation }
Compiler >> send: aSelector arguments: n on: e [
	(BytecodeGenerator special: aSelector arguments: n)
		ifNil: [e add: {#send. #send. aSelector. n}]
		ifNotNil: [:op | self emit: e op: op]
]

{ #category : #generation }
Compiler >> gen: aNode in: r on: e value: wantValue [
	| c b |
	c := aNode class.
	c == LiteralNode ifTrue: [wantValue ifTrue: [self pushLiteral: aNode value on: e]. ^ self].
	c == VariableNode ifTrue: [
		wantValue ifFalse: [^ self].
		b := aNode binding.
		(b == #self or: [b == #super]) ifTrue: [^ self emit: e op: #pushSelf].
		b == #thisContext ifTrue: [^ self emit: e op: #pushThisContext].
		b == #local ifTrue: [^ self push: aNode target from: r on: e].
		b == #instance ifTrue: [^ self emit: e op: #pushIvar a: aNode target].
		b == #classVariable ifTrue: [
			"The Binding, then its value (no bytecode of its own)."
			e add: {#literal. aNode target}.
			^ self send: #value arguments: 0 on: e].
		^ e add: {#literal. aNode target}].
	c == AssignmentNode ifTrue: [
		aNode variable binding == #classVariable ifTrue: [
			"value: answers its argument, the assignment's value."
			e add: {#literal. aNode variable target}.
			self gen: aNode value in: r on: e value: true.
			self send: #value: arguments: 1 on: e.
			wantValue ifFalse: [self emit: e op: #pop].
			^ self].
		self gen: aNode value in: r on: e value: true.
		wantValue ifTrue: [self emit: e op: #dup].
		aNode variable binding == #local
			ifTrue: [self store: aNode variable target from: r on: e]
			ifFalse: [self emit: e op: #storeIvar a: aNode variable target].
		^ self].
	c == MessageNode ifTrue: [
		aNode isInlined ifTrue: [^ self genInlined: aNode in: r on: e value: wantValue].
		aNode isSuper
			ifTrue: [
				self emit: e op: #pushSelf.
				aNode arguments do: [:x | self gen: x in: r on: e value: true].
				e add: {#send. #sendSuper. aNode selector. aNode arguments size}]
			ifFalse: [
				self gen: aNode receiver in: r on: e value: true.
				aNode arguments do: [:x | self gen: x in: r on: e value: true].
				self send: aNode selector arguments: aNode arguments size on: e].
		wantValue ifFalse: [self emit: e op: #pop].
		^ self].
	c == CascadeNode ifTrue: [^ self genCascade: aNode in: r on: e value: wantValue].
	c == BraceNode ifTrue: [
		self emit: e op: #pushNewArray a: aNode elements size.
		aNode elements doWithIndex: [:x :i |
			self emit: e op: #dup.
			self pushLiteral: i on: e.
			self gen: x in: r on: e value: true.
			self emit: e op: #atPut.
			self emit: e op: #pop].
		wantValue ifFalse: [self emit: e op: #pop].
		^ self].
	c == BlockNode ifTrue: [wantValue ifTrue: [self genClosure: aNode in: r on: e]. ^ self].
	^ self fail: 'unknown node' line: aNode line
]

{ #category : #generation }
Compiler >> genCascade: aNode in: r on: e value: wantValue [
	| isSuper |
	isSuper := aNode receiver class == VariableNode and: [aNode receiver name = 'super'].
	self gen: aNode receiver in: r on: e value: true.
	aNode messages doWithIndex: [:m :k | | last |
		last := k = aNode messages size.
		last ifFalse: [self emit: e op: #dup].
		(m at: 2) do: [:x | self gen: x in: r on: e value: true].
		isSuper
			ifTrue: [e add: {#send. #sendSuper. m first. (m at: 2) size}]
			ifFalse: [self send: m first arguments: (m at: 2) size on: e].
		last ifFalse: [self emit: e op: #pop]].
	wantValue ifFalse: [self emit: e op: #pop]
]

{ #category : #generation }
Compiler >> genReturn: aNode in: r on: e [
	r parent isNil ifTrue: [
		(aNode class == VariableNode and: [aNode binding == #self]) ifTrue: [^ self emit: e op: #returnSelf].
		self gen: aNode in: r on: e value: true.
		^ self emit: e op: #returnTop].
	self gen: aNode in: r on: e value: true.
	self emit: e op: #nonlocalReturn
]

{ #category : #generation }
Compiler >> genClosure: aNode in: r on: e [
	| s body code |
	s := aNode scope.
	s layout.
	body := OrderedCollection new.
	s vectorTemp >= 0 ifTrue: [
		self emit: body op: #pushNewArray a: s vectorVariables size.
		self emit: body op: #storeTemp a: s vectorTemp].
	aNode statements isEmpty
		ifTrue: [self emit: body op: #pushNil. self emit: body op: #blockReturn]
		ifFalse: [
			aNode statements doWithIndex: [:st :k | | last |
				last := k = aNode statements size.
				st class == ReturnNode
					ifTrue: [self genReturn: st value in: s on: body]
					ifFalse: [
						self gen: st in: s on: body value: last.
						last ifTrue: [self emit: body op: #blockReturn]]]].
	code := self assembleBlock: body scope: s.
	s copied do: [:item |
		(item isKindOf: CompilerScope)
			ifTrue: [self emit: e op: #pushTemp a: (item real == r ifTrue: [item vectorTemp] ifFalse: [r copiedIndex: item])]
			ifFalse: [self emit: e op: #pushTemp a: (item real == r ifTrue: [item index] ifFalse: [r copiedIndex: item])]].
	e add: {#closure. code. s copied size}
]

{ #category : #generation }
Compiler >> assembleBlock: lines scope: s [
	| r home |
	r := (BytecodeGenerator new setLines: lines) assembleWithExtraLiterals: #().
	home := (lines anySatisfy: [:l | l first == #op and: [(l at: 2) == #nonlocalReturn]])
		or: [lines anySatisfy: [:l | l first == #closure and: [(l at: 2) needsHome]]].
	^ CompiledCode new
		setSelector: nil bytecodes: r first literals: (r at: 2) numArgs: s argumentCount
		numTemps: s copied size + s tempCount + 1 maxStack: (r at: 3) primitive: 0
		flags: (home ifTrue: [12] ifFalse: [4]) numCopied: s copied size
]

{ #category : #generation }
Compiler >> genInlinedBody: aNode in: r on: e value: wantValue [
	"A loop body that owns a temp vector makes a fresh one on every pass."
	(aNode scope isLoop and: [aNode scope vectorTemp >= 0]) ifTrue: [
		self emit: e op: #pushNewArray a: aNode scope vectorVariables size.
		self emit: e op: #storeTemp a: aNode scope vectorTemp].
	aNode statements isEmpty ifTrue: [wantValue ifTrue: [self emit: e op: #pushNil]. ^ self].
	aNode statements doWithIndex: [:st :k |
		st class == ReturnNode
			ifTrue: [self genReturn: st value in: r on: e]
			ifFalse: [self gen: st in: r on: e value: (k = aNode statements size and: [wantValue])]]
]

{ #category : #generation }
Compiler >> bindInlinedArgument: aNode in: r on: e [
	aNode numArgs = 1
		ifTrue: [self store: aNode scope declared first from: r on: e]
		ifFalse: [self emit: e op: #pop]
]

{ #category : #generation }
Compiler >> genInlined: s in: r on: e value: wantValue [
	| a sel jump other end loop block counter step limit |
	a := s arguments.
	sel := s selector.
	(#(#ifTrue: #ifFalse:) includes: sel) ifTrue: [
		self gen: s receiver in: r on: e value: true.
		jump := sel == #ifTrue: ifTrue: [#jumpIfFalse] ifFalse: [#jumpIfTrue].
		end := self label.
		wantValue
			ifTrue: [
				other := self label.
				self emit: e jump: jump to: other.
				self genInlinedBody: a first in: r on: e value: true.
				self emit: e jump: #jump to: end.
				self emit: e label: other.
				self emit: e op: #pushNil]
			ifFalse: [
				self emit: e jump: jump to: end.
				self genInlinedBody: a first in: r on: e value: false].
		^ self emit: e label: end].
	(#(#ifTrue:ifFalse: #ifFalse:ifTrue:) includes: sel) ifTrue: [
		self gen: s receiver in: r on: e value: true.
		jump := sel == #ifTrue:ifFalse: ifTrue: [#jumpIfFalse] ifFalse: [#jumpIfTrue].
		other := self label. end := self label.
		self emit: e jump: jump to: other.
		self genInlinedBody: a first in: r on: e value: wantValue.
		self emit: e jump: #jump to: end.
		self emit: e label: other.
		self genInlinedBody: a last in: r on: e value: wantValue.
		^ self emit: e label: end].
	(#(#and: #or:) includes: sel) ifTrue: [
		self gen: s receiver in: r on: e value: true.
		other := self label. end := self label.
		self emit: e jump: (sel == #and: ifTrue: [#jumpIfFalse] ifFalse: [#jumpIfTrue]) to: other.
		self genInlinedBody: a first in: r on: e value: true.
		self emit: e jump: #jump to: end.
		self emit: e label: other.
		self emit: e op: (sel == #and: ifTrue: [#pushFalse] ifFalse: [#pushTrue]).
		self emit: e label: end.
		wantValue ifFalse: [self emit: e op: #pop].
		^ self].
	(#(#ifNil: #ifNotNil:) includes: sel) ifTrue: [
		self gen: s receiver in: r on: e value: true.
		end := self label.
		self emit: e op: #dup.
		self emit: e op: #isNil.
		sel == #ifNil:
			ifTrue: [self emit: e jump: #jumpIfFalse to: end. self emit: e op: #pop]
			ifFalse: [self emit: e jump: #jumpIfTrue to: end. self bindInlinedArgument: a first in: r on: e].
		self genInlinedBody: a first in: r on: e value: true.
		self emit: e label: end.
		wantValue ifFalse: [self emit: e op: #pop].
		^ self].
	(#(#ifNil:ifNotNil: #ifNotNil:ifNil:) includes: sel) ifTrue: [
		self gen: s receiver in: r on: e value: true.
		other := self label. end := self label.
		self emit: e op: #dup.
		self emit: e op: #isNil.
		sel == #ifNil:ifNotNil:
			ifTrue: [
				self emit: e jump: #jumpIfFalse to: other.
				self emit: e op: #pop.
				self genInlinedBody: a first in: r on: e value: true.
				self emit: e jump: #jump to: end.
				self emit: e label: other.
				self bindInlinedArgument: a last in: r on: e.
				self genInlinedBody: a last in: r on: e value: true]
			ifFalse: [
				self emit: e jump: #jumpIfTrue to: other.
				self bindInlinedArgument: a first in: r on: e.
				self genInlinedBody: a first in: r on: e value: true.
				self emit: e jump: #jump to: end.
				self emit: e label: other.
				self emit: e op: #pop.
				self genInlinedBody: a last in: r on: e value: true].
		self emit: e label: end.
		wantValue ifFalse: [self emit: e op: #pop].
		^ self].
	(#(#whileTrue: #whileFalse:) includes: sel) ifTrue: [
		loop := self label. end := self label.
		self emit: e label: loop.
		self genInlinedBody: s receiver in: r on: e value: true.
		self emit: e jump: (sel == #whileTrue: ifTrue: [#jumpIfFalse] ifFalse: [#jumpIfTrue]) to: end.
		self genInlinedBody: a first in: r on: e value: false.
		self emit: e jump: #jump to: loop.
		self emit: e label: end.
		wantValue ifTrue: [self emit: e op: #pushNil].
		^ self].
	(#(#whileTrue #whileFalse) includes: sel) ifTrue: [
		loop := self label.
		self emit: e label: loop.
		self genInlinedBody: s receiver in: r on: e value: true.
		self emit: e jump: (sel == #whileTrue ifTrue: [#jumpIfTrue] ifFalse: [#jumpIfFalse]) to: loop.
		wantValue ifTrue: [self emit: e op: #pushNil].
		^ self].
	sel == #repeat ifTrue: [
		loop := self label.
		self emit: e label: loop.
		self genInlinedBody: s receiver in: r on: e value: false.
		^ self emit: e jump: #jump to: loop].
	(#(#to:do: #to:by:do:) includes: sel) ifTrue: [
		block := a last.
		counter := block scope declared first.
		step := sel == #to:by:do: ifTrue: [(a at: 2) value] ifFalse: [1].
		limit := s hidden isEmpty ifTrue: [nil] ifFalse: [s hidden first].
		self gen: s receiver in: r on: e value: true.
		self store: counter from: r on: e.
		limit ifNotNil: [:x | self gen: a first in: r on: e value: true. self store: x from: r on: e].
		loop := self label. end := self label.
		self emit: e label: loop.
		self push: counter from: r on: e.
		limit ifNil: [self gen: a first in: r on: e value: true] ifNotNil: [:x | self push: x from: r on: e].
		self emit: e op: (step > 0 ifTrue: [#le] ifFalse: [#ge]).
		self emit: e jump: #jumpIfFalse to: end.
		self genInlinedBody: block in: r on: e value: false.
		self push: counter from: r on: e.
		self pushLiteral: step on: e.
		self emit: e op: #add.
		self store: counter from: r on: e.
		self emit: e jump: #jump to: loop.
		self emit: e label: end.
		wantValue ifTrue: [self emit: e op: #pushNil].
		^ self].
	sel == #timesRepeat: ifTrue: [
		counter := s hidden first.
		self pushLiteral: 1 on: e.
		self store: counter from: r on: e.
		s hidden size > 1 ifTrue: [
			self gen: s receiver in: r on: e value: true.
			self store: (s hidden at: 2) from: r on: e].
		loop := self label. end := self label.
		self emit: e label: loop.
		self push: counter from: r on: e.
		s hidden size > 1
			ifTrue: [self push: (s hidden at: 2) from: r on: e]
			ifFalse: [self gen: s receiver in: r on: e value: true].
		self emit: e op: #le.
		self emit: e jump: #jumpIfFalse to: end.
		self genInlinedBody: a first in: r on: e value: false.
		self push: counter from: r on: e.
		self pushLiteral: 1 on: e.
		self emit: e op: #add.
		self store: counter from: r on: e.
		self emit: e jump: #jump to: loop.
		self emit: e label: end.
		wantValue ifTrue: [self emit: e op: #pushNil].
		^ self].
	^ self fail: 'not inlinable: ' , sel line: s line
]

{ #category : #compiling }
Compiler >> compile: aString [
	"The CompiledCode of a method's source in theClass."
	| tree scope primitive flags pragmas e returned r |
	tree := Parser parse: aString.
	scope := CompilerScope parent: nil real: true seq: self nextSeq.
	tree arguments do: [:a |
		(instVarNames includes: a first) ifTrue: [^ self fail: 'argument ''' , a first , ''' shadows an instance variable' line: (a at: 2)].
		self declare: a first kind: #argument in: scope line: (a at: 2)].
	scope argumentCount: tree arguments size.
	tree temporaries do: [:t |
		(instVarNames includes: t first) ifTrue: [^ self fail: 'temporary ''' , t first , ''' shadows an instance variable' line: (t at: 2)].
		self declare: t first kind: #temporary in: scope line: (t at: 2)].
	self analyzeStatements: tree statements in: scope.
	scope layout.
	primitive := 0.
	flags := 0.
	pragmas := OrderedCollection new.
	tree pragmas do: [:p |
		p first == #primitive: ifTrue: [primitive := (p at: 2) first] ifFalse: [
		p first == #unwind ifTrue: [flags := flags bitOr: 1] ifFalse: [
		p first == #handler ifTrue: [flags := flags bitOr: 2] ifFalse: [
		pragmas add: (Pragma selector: p first arguments: (p at: 2))]]]].
	e := OrderedCollection new.
	scope vectorTemp >= 0 ifTrue: [
		self emit: e op: #pushNewArray a: scope vectorVariables size.
		self emit: e op: #storeTemp a: scope vectorTemp].
	returned := false.
	tree statements doWithIndex: [:st :k |
		st class == ReturnNode
			ifTrue: [self genReturn: st value in: scope on: e. returned := true]
			ifFalse: [
				(doit and: [k = tree statements size])
					ifTrue: [self genReturn: st in: scope on: e. returned := true]
					ifFalse: [self gen: st in: scope on: e value: false]]].
	(doit and: [returned not]) ifTrue: [self emit: e op: #pushNil. self emit: e op: #returnTop. returned := true].
	returned ifFalse: [self emit: e op: #returnSelf].
	r := (BytecodeGenerator new setLines: e) assembleWithExtraLiterals: pragmas.
	^ CompiledCode new
		setSelector: tree selector bytecodes: r first literals: (r at: 2) numArgs: tree arguments size
		numTemps: scope tempCount maxStack: (r at: 3) primitive: primitive flags: flags numCopied: 0
]
