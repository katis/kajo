"What the Smalltalk compiler makes of a method or a block: what a CompiledMethod holds, with its block methods as CompiledCode and its pragmas as Pragmas (without a method) in the literals. matches: compares it with an installed CompiledMethod; makeMethodIn: has the VM make a CompiledMethod of it (module 8d), verified, which addSelector:withMethod: installs or valueWithReceiver:arguments: runs once."
Class {
	#name : #CompiledCode,
	#superclass : #Object,
	#instVars : [
		'selector',
		'bytecodes',
		'literals',
		'numArgs',
		'numTemps',
		'maxStack',
		'primitive',
		'flags',
		'numCopied'
	],
	#category : #'Kernel-Compiler'
}

{ #category : #accessing }
CompiledCode >> setSelector: s bytecodes: b literals: l numArgs: a numTemps: t maxStack: m primitive: p flags: f numCopied: c [
	selector := s.
	bytecodes := b.
	literals := l.
	numArgs := a.
	numTemps := t.
	maxStack := m.
	primitive := p.
	flags := f.
	numCopied := c
]

{ #category : #accessing }
CompiledCode >> selector [
	^ selector
]

{ #category : #accessing }
CompiledCode >> bytecodes [
	^ bytecodes
]

{ #category : #accessing }
CompiledCode >> literals [
	^ literals
]

{ #category : #accessing }
CompiledCode >> numArgs [
	^ numArgs
]

{ #category : #accessing }
CompiledCode >> numTemps [
	^ numTemps
]

{ #category : #accessing }
CompiledCode >> maxStack [
	^ maxStack
]

{ #category : #accessing }
CompiledCode >> primitive [
	^ primitive
]

{ #category : #accessing }
CompiledCode >> flags [
	^ flags
]

{ #category : #accessing }
CompiledCode >> numCopied [
	^ numCopied
]

{ #category : #accessing }
CompiledCode >> isBlock [
	^ (flags bitAnd: 4) ~= 0
]

{ #category : #accessing }
CompiledCode >> needsHome [
	^ (flags bitAnd: 8) ~= 0
]

{ #category : #accessing }
CompiledCode >> matches: aCompiledMethod [
	"nil when the receiver is what aCompiledMethod holds, else the first difference."
	| theirs |
	(aCompiledMethod isKindOf: CompiledMethod) ifFalse: [^ 'not a CompiledMethod'].
	self isBlock ifFalse: [selector == aCompiledMethod selector ifFalse: [^ 'selector']].
	bytecodes = aCompiledMethod bytecodes ifFalse: [^ 'bytecodes ' , bytecodes printString , ' against ' , aCompiledMethod bytecodes printString].
	numArgs = aCompiledMethod numArgs ifFalse: [^ 'argument count'].
	numTemps = aCompiledMethod numTemps ifFalse: [^ 'temps ' , numTemps printString , ' against ' , aCompiledMethod numTemps printString].
	maxStack = aCompiledMethod frameSize ifFalse: [^ 'maxStack ' , maxStack printString , ' against ' , aCompiledMethod frameSize printString].
	primitive = aCompiledMethod primitive ifFalse: [^ 'primitive'].
	flags = aCompiledMethod flags ifFalse: [^ 'flags ' , flags printString , ' against ' , aCompiledMethod flags printString].
	numCopied = aCompiledMethod numCopied ifFalse: [^ 'copied values'].
	theirs := aCompiledMethod literals.
	literals size = theirs size ifFalse: [^ 'literal count ' , literals size printString , ' against ' , theirs size printString].
	literals with: theirs do: [:mine :other | | d |
		d := self literal: mine matches: other.
		d ifNotNil: [:x | ^ 'literal ' , (literals indexOf: mine) printString , ': ' , x]].
	^ nil
]

{ #category : #making }
CompiledCode >> makeMethodIn: aBehavior [
	"A CompiledMethod of aBehavior made by the VM from the receiver: verified by the one bytecode verifier (each block method too), its bytecodes copied, its literal frame read-only (module 8d). A refusal is a CompileError with the verifier's reason; a release image refuses with InstallForbidden."
	| r |
	r := self primMakeMethodIn: aBehavior.
	r isString ifTrue: [^ CompileError new line: 0; signal: 'the VM refused the method: ' , r].
	^ r
]

{ #category : #making }
CompiledCode >> primMakeMethodIn: aBehavior [
	<primitive: 143>
	Smalltalk isReleaseImage ifTrue: [^ InstallForbidden new behavior: aBehavior selector: selector; signal].
	^ self error: 'cannot make a method of ' , aBehavior printString
]

{ #category : #accessing }
CompiledCode >> literal: mine matches: other [
	(mine isKindOf: CompiledCode) ifTrue: [^ (mine matches: other) ifNotNil: [:d | 'block: ' , d]].
	(mine isKindOf: Pragma) ifTrue: [
		((other isKindOf: Pragma) and: [mine selector == other selector and: [BytecodeGenerator literal: mine arguments sameAs: other arguments]])
			ifFalse: [^ 'pragma ' , mine selector].
		^ nil].
	(BytecodeGenerator literal: mine sameAs: other) ifFalse: [^ mine printString , ' against ' , other printString].
	^ nil
]
