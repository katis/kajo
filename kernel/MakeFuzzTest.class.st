"The make-method primitive is a trust boundary (module 8d): 1500 seeded mutations of real CompiledCode (bytes flipped, literals swapped for objects of the wrong class, counts off by one, block methods with the wrong copied count, a Binding where a selector should be, flags and primitives changed) are each refused with the VM's reason or made, verified, and run once in a Process of their own without bringing the VM down."
Class {
	#name : #MakeFuzzTest,
	#superclass : #TestCase,
	#category : #'Kernel-Tests'
}

{ #category : #mutating }
MakeFuzzTest >> codesIn: code [
	"The method and its block methods, depth first."
	| out |
	out := OrderedCollection with: code.
	code literals do: [:l | (l isKindOf: CompiledCode) ifTrue: [out addAll: (self codesIn: l)]].
	^ out
]

{ #category : #mutating }
MakeFuzzTest >> copyOf: code [
	"A deep copy: the bytecodes, the literals and the block methods are the copy's own."
	| c |
	c := code shallowCopy.
	c instVarAt: 2 put: code bytecodes copy.
	c instVarAt: 3 put: (code literals collect: [:l | (l isKindOf: CompiledCode) ifTrue: [self copyOf: l] ifFalse: [l]]).
	^ c
]

{ #category : #mutating }
MakeFuzzTest >> mutate: code seed: s0 [
	"One mutation of a copy of code (or of one of its block methods), chosen by the seed."
	| s c codes target kind n r |
	s := s0.
	c := self copyOf: code.
	codes := self codesIn: c.
	s := self next: s.
	target := codes at: s \\ codes size + 1.
	s := self next: s.
	kind := s \\ 10.
	s := self next: s.
	r := s // 7.
	kind = 0 ifTrue: [
		n := target bytecodes size.
		n > 0 ifTrue: [target bytecodes at: r \\ n + 1 put: r // 3 \\ 256]].
	kind = 1 ifTrue: [
		n := target literals size.
		n > 0 ifTrue: [target literals at: r \\ n + 1 put: (self strangers at: r // 5 \\ self strangers size + 1)]].
	kind = 2 ifTrue: [target instVarAt: 4 + (r \\ 3) put: (target instVarAt: 4 + (r \\ 3)) + (r // 3 \\ 2 * 2 - 1)].
	kind = 3 ifTrue: [target instVarAt: 9 put: target numCopied + (r \\ 2 * 2 - 1)].
	kind = 4 ifTrue: [
		n := (1 to: target literals size) select: [:i | (target literals at: i) isSymbol].
		n isEmpty ifFalse: [target literals at: (n at: r \\ n size + 1) put: (ClassVariableSample bindingOf: #Count)]].
	kind = 5 ifTrue: [target instVarAt: 8 put: (target flags bitXor: (#(1 2 4 8 16) at: r \\ 5 + 1))].
	kind = 6 ifTrue: [target instVarAt: 7 put: r \\ 256].
	kind = 7 ifTrue: [
		n := target bytecodes size.
		target instVarAt: 2 put: (r \\ 2 = 0
			ifTrue: [target bytecodes copyFrom: 1 to: (r // 2 \\ (n + 1))]
			ifFalse: [target bytecodes , (ByteArray with: r // 2 \\ 256)])].
	kind = 8 ifTrue: [target instVarAt: (#(1 2 3) at: r \\ 3 + 1) put: (self strangers at: r // 3 \\ self strangers size + 1)].
	kind = 9 ifTrue: [
		n := target literals size.
		n > 1 ifTrue: [| i j x |
			i := r \\ n + 1. j := r // n \\ n + 1.
			x := target literals at: i.
			target literals at: i put: (target literals at: j); at: j put: x]].
	^ c
]

{ #category : #mutating }
MakeFuzzTest >> strangers [
	"Literals of the wrong class for wherever they land."
	^ {42. -1. 'text'. nil. true. 3.5. $c. #foo:bar:. #+. Object. MakeFuzzSample class. ClassVariableSample bindingOf: #Count. Array new: 3. 1.0e300. 2 raisedTo: 70. MakeFuzzSample new. Semaphore new. ProcessorScheduler activeProcess. thisContext. [:x | x]. Object >> #printOn:. #(1 2) asOrderedCollection. ByteArray new: 2. Pragma selector: #foo: arguments: #(1 2)}
]

{ #category : #random }
MakeFuzzTest >> next: seed [
	^ seed * 1103515245 + 12345 \\ 2147483648
]

{ #category : #running }
MakeFuzzTest >> runOnce: aMethod [
	"Run a made method once in a Process of its own, errors caught; one that loops is terminated after a while. True when it ended by itself."
	| p args |
	args := Array new: aMethod numArgs withAll: 3.
	p := [[aMethod valueWithReceiver: MakeFuzzSample new arguments: args] on: Error do: [:e | e return: nil]] fork.
	200 timesRepeat: [p isTerminated ifTrue: [^ true]. ProcessorScheduler yield].
	p terminate.
	^ false
]

{ #category : #tests }
MakeFuzzTest >> testSeededMutationsAreRefusedOrRun [
	<slow>
	| codes seed made refused ended reasons |
	Smalltalk isReleaseImage ifTrue: [^ self].
	codes := (MakeFuzzSample selectors asArray sort: [:x :y | x <= y]) collect: [:sel |
		Compiler compile: (Smalltalk sourceOf: MakeFuzzSample >> sel) in: MakeFuzzSample].
	seed := 16r5EED.
	made := 0. refused := 0. ended := 0.
	reasons := Set new.
	1 to: 1500 do: [:k | | code m |
		seed := self next: seed.
		code := self mutate: (codes at: k \\ codes size + 1) seed: seed.
		m := [code makeMethodIn: MakeFuzzSample] on: CompileError do: [:e |
			refused := refused + 1.
			reasons add: (e messageText copyFrom: 1 to: (e messageText byteSize min: 40)).
			e return: nil].
		m ifNotNil: [
			made := made + 1.
			self assert: m isReadOnly.
			self assert: m bytecodes isReadOnly.
			(self runOnce: m) ifTrue: [ended := ended + 1]]].
	Transcript show: 'MakeFuzzTest: 1500 mutations, ' , refused printString , ' refused (' , reasons size printString , ' reasons), ' , made printString , ' made, ' , ended printString , ' ran to their end'; cr.
	self assert: made + refused = 1500.
	self assert: refused > 500.
	self assert: made > 50
]

{ #category : #tests }
MakeFuzzTest >> testTheSamplesMakeAndRun [
	MakeFuzzSample selectors do: [:sel | | m |
		m := (Compiler compile: (Smalltalk sourceOf: MakeFuzzSample >> sel) in: MakeFuzzSample) makeMethodIn: MakeFuzzSample.
		self assert: ((Compiler compile: (Smalltalk sourceOf: MakeFuzzSample >> sel) in: MakeFuzzSample) matches: m) isNil.
		self assert: (self runOnce: m)].
	self assert: ((MakeFuzzSample >> #sum:) valueWithReceiver: MakeFuzzSample new arguments: #(3)) = 12
]
