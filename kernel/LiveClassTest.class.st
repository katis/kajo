"Classes defined, reshaped and removed in the running image (module 8e): the Smalltalk-80 definition protocol over the define, redefine and remove primitives; instances keep their values by name, methods are recompiled against the new shape or the change is refused before anything changes; class variables come and go, a removed one leaves its Binding undeclared; a Process running a method of the class refuses a reshape; old closures follow their method; a release image refuses all of it."
Class {
	#name : #LiveClassTest,
	#superclass : #TestCase,
	#category : #'Kernel-Tests'
}

{ #category : #running }
LiveClassTest >> defineSample [
	^ Object subclass: #LiveClassSample instanceVariableNames: 'a b' classVariableNames: 'Count' category: 'Kernel-Tests-Live'
]

{ #category : #running }
LiveClassTest >> tearDown [
	Smalltalk isReleaseImage ifTrue: [^ self].
	#(#LiveClassSampleSub #LiveClassSample #LiveClassSampleB) do: [:n |
		(Smalltalk at: n ifAbsent: [nil]) ifNotNil: [:c | Smalltalk removeClass: c]]
]

{ #category : #tests }
LiveClassTest >> testARemovalThatBreaksAMethodChangesNothing [
	| c x |
	Smalltalk isReleaseImage ifTrue: [^ self].
	c := self defineSample.
	c compile: 'a ^ a'. c compile: 'a: v a := v'. c compile: 'twiceA ^ a * 2'.
	x := c new a: 4; yourself.
	[c removeInstVarName: 'a'. self assert: false]
		on: ClassDefinitionError do: [:e |
			self assert: (e messageText includesSubstring: 'twiceA').
			self assert: (e messageText includesSubstring: 'LiveClassSample>>a:')].
	self assert: c instVarNames = #(#a #b).
	self assert: x twiceA = 8.
	c removeSelector: #twiceA; removeSelector: #a; removeSelector: #a:.
	c removeInstVarName: 'a'.
	self assert: c instVarNames = #(#b).
	self assert: x basicSize = 0 & (c instSize = 1)
]

{ #category : #tests }
LiveClassTest >> testARunningMethodRefusesTheReshape [
	| c go started p result |
	Smalltalk isReleaseImage ifTrue: [^ self].
	c := self defineSample.
	c compile: 'a: v a := v'.
	c compile: 'waitOn: s then: t t signal. s wait. ^ a'.
	go := Semaphore new.
	started := Semaphore new.
	p := [result := (c new a: 3; yourself) waitOn: go then: started] fork.
	started wait.
	[c addInstVarName: 'z'. self assert: false]
		on: ClassDefinitionError do: [:e |
			self assert: (e messageText includesSubstring: 'runs').
			self assert: (e messageText includesSubstring: 'waitOn:then:')].
	self assert: c instVarNames = #(#a #b).
	go signal.
	[result isNil] whileTrue: [ProcessorScheduler yield].
	self assert: result = 3.
	c addInstVarName: 'z'.
	self assert: c instVarNames = #(#a #b #z)
]

{ #category : #tests }
LiveClassTest >> testClassSideInstanceVariables [
	| c |
	Smalltalk isReleaseImage ifTrue: [^ self].
	c := self defineSample.
	c class instanceVariableNames: 'made'.
	c class compile: 'made ^ made ifNil: [0]'.
	c class compile: 'note made := self made + 1'.
	c note; note.
	self assert: c made = 2.
	c class instanceVariableNames: 'first made'.
	self assert: c made = 2.
	self assert: c class instVarNames = #(#first #made).
	self assert: (Smalltalk instanceVariableNamesOf: c class) = #(#first #made)
]

{ #category : #tests }
LiveClassTest >> testClassVariablesComeAndGoUndeclared [
	| c b |
	Smalltalk isReleaseImage ifTrue: [^ self].
	c := self defineSample.
	c addClassVarNamed: 'Total'.
	self assert: c classVarNames = #(#Count #Total).
	c compile: 'total ^ Total'.
	c compile: 'total: v Total := v'.
	c new total: 5.
	self assert: c new total = 5.
	b := c bindingOf: 'Total'.
	c removeClassVarNamed: 'Total'.
	self assert: c classVarNames = #(#Count).
	self assert: b isUndeclared.
	self assert: c new total isNil.
	self should: [c new total: 6] raise: Error.
	self should: [c compile: 'other ^ Total'] raise: CompileError.
	c addClassVarNamed: 'Total'.
	self assert: (c bindingOf: 'Total') == b.
	self deny: b isUndeclared.
	c new total: 7.
	self assert: c new total = 7
]

{ #category : #tests }
LiveClassTest >> testDefineInstantiateRemove [
	| c x |
	Smalltalk isReleaseImage ifTrue: [^ self].
	c := self defineSample.
	self assert: (Smalltalk at: #LiveClassSample) == c.
	self assert: c superclass == Object.
	self assert: c class class == Metaclass.
	self assert: c class superclass == Object class.
	self assert: c instVarNames = #(#a #b).
	self assert: c classVarNames = #(#Count).
	self assert: c category = 'Kernel-Tests-Live'.
	self assert: c instSize = 2.
	self assert: (Object subclasses includes: c).
	c compile: 'a ^ a' classified: #accessing.
	c compile: 'a: x a := x' classified: #accessing.
	c compile: 'bump Count := (Count ifNil: [0]) + 1. ^ Count'.
	c class compile: 'with: x ^ self new a: x; yourself'.
	x := c with: 7.
	self assert: x a = 7.
	self assert: x bump = 1.
	self assert: x bump = 2.
	self assert: (c categoryOf: #a) == #accessing.
	"an instance keeps the class"
	self should: [Smalltalk removeClass: c] raise: ClassDefinitionError.
	self assert: (Smalltalk at: #LiveClassSample) == c.
	x := nil.
	Smalltalk removeClass: c.
	self assert: (Smalltalk at: #LiveClassSample ifAbsent: [nil]) isNil.
	self deny: (Smalltalk allClasses includes: c).
	self assert: c isObsolete.
	self assert: c selectors isEmpty.
	"the name is free again"
	c := self defineSample.
	self assert: (Smalltalk at: #LiveClassSample) == c.
	self deny: c isObsolete
]

{ #category : #tests }
LiveClassTest >> testDefinitionsTheVMRefuses [
	Smalltalk isReleaseImage ifTrue: [^ self].
	self should: [Object subclass: #liveLower instanceVariableNames: '' classVariableNames: '' category: 'x'] raise: ClassDefinitionError.
	self should: [Object subclass: #AnObsoleteThing instanceVariableNames: '' classVariableNames: '' category: 'x'] raise: ClassDefinitionError.
	self should: [Array subclass: #Object instanceVariableNames: '' classVariableNames: '' category: 'x'] raise: ClassDefinitionError.
	self should: [CompiledMethod subclass: #LiveClassSampleB instanceVariableNames: '' classVariableNames: '' category: 'x'] raise: ClassDefinitionError.
	self should: [Context subclass: #LiveClassSampleB instanceVariableNames: '' classVariableNames: '' category: 'x'] raise: ClassDefinitionError.
	self should: [Association subclass: #LiveClassSampleB instanceVariableNames: 'key' classVariableNames: '' category: 'x'] raise: ClassDefinitionError.
	self should: [Object subclass: #LiveClassSampleB instanceVariableNames: 'p p' classVariableNames: '' category: 'x'] raise: ClassDefinitionError.
	self should: [Object subclass: #LiveClassSampleB instanceVariableNames: '' classVariableNames: 'lower' category: 'x'] raise: ClassDefinitionError.
	self should: [Object subclass: #LiveClassSampleB instanceVariableNames: 'Tag' classVariableNames: 'Tag' category: 'x'] raise: ClassDefinitionError.
	self should: [Float subclass: #LiveClassSampleB instanceVariableNames: '' classVariableNames: 'NaN' category: 'x'] raise: ClassDefinitionError.
	self should: [ByteArray subclass: #LiveClassSampleB instanceVariableNames: 'p' classVariableNames: '' category: 'x'] raise: ClassDefinitionError.
	self should: [ByteArray subclass: #LiveClassSampleB instanceVariableNames: '' classVariableNames: '' category: 'x' kind: #variable] raise: ClassDefinitionError.
	self assert: (Smalltalk at: #LiveClassSampleB ifAbsent: [nil]) isNil.
	"the primitive refuses what the kernel would not send"
	self assert: (Smalltalk primDefineClass: #(1 2 3)) isString.
	self assert: (Smalltalk primDefineClass: (Array new: 9)) isString.
	self assert: (Smalltalk primDefineClass: {#LiveClassSampleB. Object. #(#a). #(). #(). #fixed. nil. 1. 0}) isString.
	self assert: (Smalltalk primDefineClass: {#LiveClassSampleB. Object. #(). #(). #(). #squiggly. nil. 0. 0}) isString.
	self assert: (Smalltalk primDefineClass: {#LiveClassSampleB. Object class. #(). #(). #(). #fixed. nil. 0. 0}) isString.
	self assert: (Smalltalk primDefineClass: {#LiveClassSampleB. Object. #(). #(). #(#Tag). #fixed. Object. 0. 0}) isString.
	self assert: (Smalltalk at: #LiveClassSampleB ifAbsent: [nil]) isNil
]

{ #category : #tests }
LiveClassTest >> testOldClosuresFollowTheirMethod [
	| c x blk orphan |
	Smalltalk isReleaseImage ifTrue: [^ self].
	c := self defineSample.
	c compile: 'a: v a := v'.
	c compile: 'reader ^ [a]'.
	c compile: 'orphan ^ [a]'.
	x := c new a: 9; yourself.
	blk := x reader.
	orphan := x orphan.
	c removeSelector: #orphan.
	c instanceVariableNames: 'z a'.
	"the block of the replaced method reads the new slot of a"
	self assert: blk value = 9.
	"the block of the removed method was compiled for the old slots: it says so instead of reading them"
	self should: [orphan value] raise: Error.
	c instanceVariableNames: 'a'.
	self assert: blk value = 9
]

{ #category : #tests }
LiveClassTest >> testReshapeKeepsValuesByNameAndRecompiles [
	| c sub x y |
	Smalltalk isReleaseImage ifTrue: [^ self].
	c := self defineSample.
	c compile: 'a ^ a'. c compile: 'b ^ b'. c compile: 'a: x b: y a := x. b := y'.
	c compile: 'sum ^ a + b'.
	sub := c subclass: #LiveClassSampleSub instanceVariableNames: 's' classVariableNames: '' category: 'Kernel-Tests-Live'.
	sub compile: 's ^ s'. sub compile: 's: v s := v'. sub compile: 'total ^ self sum + s'.
	x := c new a: 1 b: 2; yourself.
	y := (sub new a: 10 b: 20; yourself) s: 30; yourself.
	c instanceVariableNames: 'z b a'.
	self assert: c instVarNames = #(#z #b #a).
	self assert: c instSize = 3.
	self assert: sub instSize = 4.
	self assert: (x instVarAt: 1) isNil.
	self assert: x a = 1 & (x b = 2) & (x sum = 3).
	self assert: (x instVarAt: 3) = 1.
	self assert: y total = 60.
	self assert: (y instVarAt: 4) = 30.
	self assert: (Smalltalk sourceOf: c >> #sum) = 'sum ^ a + b'.
	c addInstVarName: 'w'.
	self assert: c instVarNames = #(#z #b #a #w).
	self assert: y total = 60 & (y s = 30).
	c compile: 'w ^ w'.
	self assert: x w isNil.
	"new instances have the new shape"
	self assert: (c new a: 5 b: 6; yourself) sum = 11
]

{ #category : #tests }
LiveClassTest >> testTheReleaseFlagRefusesClassChanges [
	Smalltalk isReleaseImage ifFalse: [^ self].
	self should: [self defineSample] raise: InstallForbidden.
	self should: [LiveSample addInstVarName: 'x'] raise: InstallForbidden.
	self should: [Smalltalk removeClass: LiveSample] raise: InstallForbidden.
	self assert: (Smalltalk at: #LiveClassSample ifAbsent: [nil]) isNil.
	self assert: LiveSample instVarNames = #(#value)
]
