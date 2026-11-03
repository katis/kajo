"The compiler in Smalltalk against the bootstrap compiler: every method of every class of the image, compiled from its recorded source, must equal the installed method (bytecodes, literals, blocks, pragmas, header). Any difference would be listed in knownDifferences with its reason; there is none."
Class {
	#name : #CompilerTest,
	#superclass : #TestCase,
	#category : #'Kernel-Tests'
}

{ #category : #accessing }
CompilerTest >> knownDifferences [
	"Methods whose Smalltalk-compiled form may differ from the bootstrap's, with why. Empty: the two compilers agree on every kernel method."
	^ #()
]

{ #category : #accessing }
CompilerTest >> testEveryMethodCompilesAsTheBootstrapDid [
	<slow>
	| checked failures |
	checked := 0.
	failures := OrderedCollection new.
	Smalltalk allBehaviors do: [:c |
		c methodsDo: [:m | | src d |
			src := Smalltalk sourceOf: m.
			self assert: src notNil description: 'no source for ' , m printString.
			(self knownDifferences includes: m printString) ifFalse: [
				d := [(Compiler compile: src in: c) matches: m] on: Error do: [:e | 'error: ' , e messageText].
				d ifNotNil: [:x | failures add: m printString , ': ' , x].
				checked := checked + 1]]].
	self assert: checked > 1000.
	self assert: failures isEmpty description: (failures isEmpty ifTrue: [''] ifFalse: [failures size printString , ' differ, the first: ' , failures first])
]

{ #category : #accessing }
CompilerTest >> testScannerTokens [
	| s kinds |
	s := Scanner on: 'foo: x ^ #(1 $a) , 16r1F + 2.5e3 - -3 := ''it''''s'' #at:put: [:y | y]'.
	kinds := OrderedCollection new.
	[s next == #end] whileFalse: [kinds add: s kind -> s value].
	self assert: (kinds collect: [:a | a key]) asArray = #(#keyword #identifier #caret #literalArrayStart #integer #character #rightParen #binary #integer #binary #float #binary #binary #integer #assign #string #symbol #leftBracket #colon #identifier #bar #identifier #rightBracket).
	self assert: (kinds at: 9) value = 31.
	self assert: (kinds at: 11) value = 2500.0.
	self assert: (kinds at: 16) value = 'it''s'
]

{ #category : #accessing }
CompilerTest >> testParserErrors [
	#('f ^' 'f [' 'f x := 1' 'f: a a := 1' 'f | a a |' 'f ^ 1. 2' 'f #(' 'f ''abc' 'f "x' 'f ^ 16r' 'f ^ (1' 'f ^ [:x 1]' 'f ^ #[256]' 'f ^ a ; b') do: [:src |
		self should: [Compiler compile: src in: Object] raise: CompileError]
]

{ #category : #accessing }
CompilerTest >> testCompiledCodeRunsTheSame [
	| code |
	code := Compiler compile: 'sum: n | s | s := 0. 1 to: n do: [:i | s := s + i]. ^ s' in: Object.
	self assert: code numArgs = 1.
	self assert: code literals isEmpty.
	self assert: code bytecodes first = (BytecodeGenerator number: #pushInt)
]

{ #category : #accessing }
CompilerTest >> testBlocksAndCaptures [
	| code block |
	code := Compiler compile: 'f: a | t | t := 0. a do: [:e | t := t + e]. ^ [t]' in: Object.
	block := code literals detect: [:l | l isKindOf: CompiledCode].
	self assert: block isBlock.
	self assert: block numCopied = 1.
	self assert: (code bytecodes first: 2) = (ByteArray with: (BytecodeGenerator number: #pushNewArray) with: 1)
]
