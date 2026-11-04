"Installing from Smalltalk (module 8d): Behavior>>compile: makes (the VM verifies), installs, records the source and keeps the pragma index; removeSelector: undoes it; Compiler evaluate: runs a doit once without installing anything; the make primitive refuses what the verifier refuses and copies what it accepts; sealed classes stay closed; a release image refuses all of it."
Class {
	#name : #LiveCompileTest,
	#superclass : #TestCase,
	#category : #'Kernel-Tests'
}

{ #category : #running }
LiveCompileTest >> tearDown [
	Smalltalk isReleaseImage ifTrue: [^ self].
	#(#liveAnswer #liveValue: #liveValue #liveTagged) do: [:s | LiveSample removeSelector: s].
	LiveSample class removeSelector: #liveMade
]

{ #category : #tests }
LiveCompileTest >> testCompileCallReplaceRemove [
	| s |
	Smalltalk isReleaseImage ifTrue: [^ self].
	s := LiveSample new.
	self deny: (s respondsTo: #liveAnswer).
	self assert: (LiveSample compile: 'liveAnswer ^ 41') == #liveAnswer.
	self assert: (s respondsTo: #liveAnswer).
	self assert: s liveAnswer = 41.
	LiveSample compile: 'liveAnswer ^ 42'.
	self assert: s liveAnswer = 42.
	self assert: (Smalltalk sourceOf: LiveSample >> #liveAnswer) = 'liveAnswer ^ 42'.
	LiveSample removeSelector: #liveAnswer.
	self deny: (s respondsTo: #liveAnswer).
	self should: [s liveAnswer] raise: MessageNotUnderstood
]

{ #category : #tests }
LiveCompileTest >> testCompileKeepsThePragmaIndex [
	| m |
	Smalltalk isReleaseImage ifTrue: [^ self].
	LiveSample compile: 'liveTagged <liveSampleTag: 3> ^ 1'.
	m := LiveSample >> #liveTagged.
	self assert: (m pragmaAt: #liveSampleTag:) arguments = #(3).
	self assert: (m pragmaAt: #liveSampleTag:) method == m.
	self assert: (m pragmaAt: #liveSampleTag:) isReadOnly.
	self assert: ((Pragma allNamed: #liveSampleTag:) anySatisfy: [:p | p method == m]).
	LiveSample removeSelector: #liveTagged.
	self deny: ((Pragma allNamed: #liveSampleTag:) anySatisfy: [:p | p method == m])
]

{ #category : #tests }
LiveCompileTest >> testEvaluate [
	Smalltalk isReleaseImage ifTrue: [^ self].
	self assert: (Compiler evaluate: '3 + 4') = 7.
	self assert: (Compiler evaluate: '| a | a := 3. [:x | a := a * x] value: 3. a') = 9.
	self assert: (Compiler evaluate: 'self size' for: #(1 2 3)) = 3.
	self assert: (Compiler evaluate: '^ self' for: 5) = 5.
	self assert: (Compiler evaluate: '') isNil.
	self assert: (Compiler evaluate: 'value' for: (LiveSample new instVarAt: 1 put: 6; yourself)) = 6.
	self assert: (Compiler evaluate: 'Float nan isNaN') ~~ nil.
	self deny: (UndefinedObject includesSelector: #DoIt).
	self deny: (Array includesSelector: #DoIt).
	self should: [Compiler evaluate: '3 +'] raise: CompileError.
	self should: [Compiler evaluate: 'undeclaredThing'] raise: CompileError
]

{ #category : #tests }
LiveCompileTest >> testEveryMethodMakesAsInstalled [
	"The stronger form of CompilerTest's comparison: every method of the image compiled by the compiler in Smalltalk, made by the VM (verified, not installed) and equal to the installed one."
	<slow>
	| checked failures |
	Smalltalk isReleaseImage ifTrue: [^ self].
	checked := 0.
	failures := OrderedCollection new.
	Smalltalk allBehaviors do: [:c |
		c methodsDo: [:m | | code d |
			code := Compiler compile: (Smalltalk sourceOf: m) in: c.
			d := [| made |
				made := code makeMethodIn: c.
				(code matches: made) ifNil: [(made bytecodes = m bytecodes and: [made literals size = m literals size]) ifFalse: ['made differs']]]
				on: Error do: [:e | 'error: ' , e messageText].
			d ifNotNil: [:x | failures add: m printString , ': ' , x].
			checked := checked + 1]].
	self assert: checked > 1000.
	self assert: failures isEmpty description: (failures isEmpty ifTrue: [''] ifFalse: [failures size printString , ' differ, the first: ' , failures first])
]

{ #category : #tests }
LiveCompileTest >> testInstanceVariablesBlocksAndTheClassSide [
	| s |
	Smalltalk isReleaseImage ifTrue: [^ self].
	LiveSample compile: 'liveValue: x value := x'.
	LiveSample compile: 'liveValue ^ [:k | value + k] value: 1'.
	LiveSample class compile: 'liveMade ^ self new liveValue: 9; yourself'.
	s := LiveSample liveMade.
	self assert: s liveValue = 10.
	self assert: (LiveSample class >> #liveMade) methodClass == LiveSample class
]

{ #category : #tests }
LiveCompileTest >> testMakeVerifiesAndCopies [
	| code bytes m |
	Smalltalk isReleaseImage ifTrue: [^ self].
	code := Compiler compile: 'liveAnswer ^ #(1 $a ''b'') , {value}' in: LiveSample.
	m := code makeMethodIn: LiveSample.
	self assert: m isReadOnly.
	self assert: m bytecodes isReadOnly.
	self assert: m literals isReadOnly.
	self assert: (m literals allSatisfy: [:l | l isReadOnly]).
	self assert: (code matches: m) isNil.
	bytes := m bytecodes copy.
	code bytecodes at: 1 put: 255.
	self assert: m bytecodes = bytes.
	"the verifier's reason, as a CompileError"
	self should: [code makeMethodIn: LiveSample] raise: CompileError.
	[code makeMethodIn: LiveSample] on: CompileError do: [:e | self assert: (e messageText includesSubstring: 'no instruction')].
	"an instance variable the class does not have"
	code := Compiler compile: 'liveAnswer ^ value' in: LiveSample.
	self should: [code makeMethodIn: Object] raise: CompileError.
	"a Binding where a selector is expected"
	code := Compiler compile: 'liveAnswer ^ self yourself' in: LiveSample.
	code literals at: 1 put: (ClassVariableSample bindingOf: #Count).
	self should: [code makeMethodIn: LiveSample] raise: CompileError
]

{ #category : #tests }
LiveCompileTest >> testRunWithoutInstalling [
	| m |
	Smalltalk isReleaseImage ifTrue: [^ self].
	m := (Compiler compile: 'liveValue: x ^ value + x' in: LiveSample) makeMethodIn: LiveSample.
	self assert: (m valueWithReceiver: (LiveSample new instVarAt: 1 put: 2; yourself) arguments: #(3)) = 5.
	self deny: (LiveSample includesSelector: #liveValue:).
	"not an instance of the method's class, the wrong argument count"
	self should: [m valueWithReceiver: Object new arguments: #(3)] raise: Error.
	self should: [m valueWithReceiver: LiveSample new arguments: #()] raise: Error
]

{ #category : #tests }
LiveCompileTest >> testSealedClassesStayClosed [
	"Module 9b: a sealed class (and its class side) takes a method that only sends (an extension), never one with a primitive, an instance variable or a slot store, and keeps every kernel method that does."
	Smalltalk isReleaseImage ifTrue: [^ self].
	#(#CompiledMethod #MethodDictionary #Metaclass #Class #Behavior #Process #Context) do: [:n | | c |
		c := Smalltalk at: n.
		self should: [c compile: 'liveAnswer <primitive: 117> ^ 1'] raise: Error.
		self should: [c class compile: 'liveAnswer ^ self instVarAt: 1 put: 1'] raise: Error.
		self deny: (c includesSelector: #liveAnswer).
		self deny: (c class includesSelector: #liveAnswer).
		c compile: 'liveAnswer ^ 1'.
		self assert: (c includesSelector: #liveAnswer).
		c removeSelector: #liveAnswer.
		self deny: (c includesSelector: #liveAnswer)].
	self should: [Process removeSelector: #primTerminate] raise: Error.
	self assert: (Process includesSelector: #primTerminate).
	self should: [Context removeSelector: #pc] raise: Error.
	self assert: (Context includesSelector: #pc)
]

{ #category : #tests }
LiveCompileTest >> testTheReleaseFlag [
	"In a development image everything above works; in a release image (kajo seal) every way in is refused with InstallForbidden and nothing changes."
	Smalltalk isReleaseImage ifFalse: [^ self assert: (Compiler evaluate: '1 + 1') = 2].
	self should: [LiveSample compile: 'liveAnswer ^ 1'] raise: InstallForbidden.
	self should: [Compiler evaluate: '1 + 1'] raise: InstallForbidden.
	self should: [(Compiler compile: 'liveAnswer ^ 1' in: LiveSample) makeMethodIn: LiveSample] raise: InstallForbidden.
	self should: [LiveSample removeSelector: #printOn:] raise: InstallForbidden.
	self should: [Object addSelector: #printOn: withMethod: Object >> #printOn:] raise: InstallForbidden.
	[LiveSample compile: 'liveAnswer ^ 1'] on: InstallForbidden do: [:e | self assert: (e messageText includesSubstring: 'release')].
	self deny: (LiveSample includesSelector: #liveAnswer)
]
