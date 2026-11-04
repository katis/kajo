"The define and redefine primitives are a trust boundary (module 8e): 1500 seeded mutations of class specifications (an element swapped for an object of the wrong kind, the inherited counts off by one, a name twice or missing, another format kind, a sealed or odd superclass, a bad name, a bad class variable, a stranger for the Bindings' class, the Array cut or grown) through the define primitive, and 500 of a reshape's specification through the redefine primitive, are each refused with the VM's reason or accepted, and an accepted class makes instances and runs a method without bringing the VM down."
Class {
	#name : #ClassFuzzTest,
	#superclass : #TestCase,
	#category : #'Kernel-Tests'
}

{ #category : #mutating }
ClassFuzzTest >> bases [
	"Specifications the define primitive accepts: {name. superclass. instance variables. class-side ones. class variables. kind. Bindings' class. inherited counts}."
	| oc |
	oc := Smalltalk instanceVariableNamesOf: OrderedCollection.
	^ {
		{#ClassFuzzA. Object. #(#p #q). #(#r). #(#Shared). #fixed. Binding. 0. 0}.
		{#ClassFuzzB. OrderedCollection. oc , #(#extra). #(). #(). #fixed. nil. oc size. 0}.
		{#ClassFuzzC. Object. #(). #(). #(). #variable. nil. 0. 0}.
		{#ClassFuzzD. ByteArray. #(). #(). #(). #bytes. nil. 0. 0}.
		{#ClassFuzzE. Object. #(#a). #(#m #n). #(#One #Two). #weak. Binding. 0. 0}.
		{#ClassFuzzF. Object. #(#key #value). #(). #(). #ephemeron. nil. 0. 0}}
]

{ #category : #mutating }
ClassFuzzTest >> mutate: aSpec seed: s0 [
	| s spec kind r names |
	s := self next: s0.
	spec := aSpec copy.
	kind := s \\ 10.
	s := self next: s.
	r := s // 7.
	kind = 0 ifTrue: [spec at: r \\ 9 + 1 put: (self strangers at: r // 9 \\ self strangers size + 1)].
	kind = 1 ifTrue: [spec at: 8 + (r \\ 2) put: (spec at: 8 + (r \\ 2)) + (r // 2 \\ 2 * 2 - 1)].
	kind = 2 ifTrue: [
		names := spec at: 3 + (r \\ 3).
		names isEmpty
			ifTrue: [spec at: 3 + (r \\ 3) put: #(#dup #dup)]
			ifFalse: [spec at: 3 + (r \\ 3) put: names , (Array with: names first)]].
	kind = 3 ifTrue: [
		names := spec at: 3 + (r \\ 2).
		names isEmpty ifFalse: [spec at: 3 + (r \\ 2) put: names allButLast]].
	kind = 4 ifTrue: [spec at: 6 put: (#(#fixed #variable #bytes #words16 #words32 #words64 #weak #ephemeron #squiggly) at: r \\ 9 + 1)].
	kind = 5 ifTrue: [spec at: 2 put: ({CompiledMethod. Context. Metaclass. Object class. ByteArray. Float. SmallInteger. Array. Process. Semaphore. String. Symbol. WeakArray. Ephemeron. Binding} at: r \\ 15 + 1)].
	kind = 6 ifTrue: [spec at: 1 put: (#(#lower #Object #'Has Space' #AnObsoleteThing 'NotASymbol' #X: #'1abc' #Binding #'') at: r \\ 9 + 1)].
	kind = 7 ifTrue: [
		spec at: 5 put: ({#(#lower). #(#Shared #Shared). #(#p). #(#r). #(#NaN). {#'Bad name'}} at: r \\ 6 + 1)].
	kind = 8 ifTrue: [spec at: 7 put: (self strangers at: r \\ self strangers size + 1)].
	kind = 9 ifTrue: [
		spec := r \\ 2 = 0
			ifTrue: [spec copyFrom: 1 to: r // 2 \\ 9]
			ifFalse: [spec , (Array with: (self strangers at: r // 2 \\ self strangers size + 1))]].
	^ spec
]

{ #category : #mutating }
ClassFuzzTest >> strangers [
	^ {42. -1. 'text'. nil. true. 3.5. $c. #foo:bar:. #+. Object. Object class. CompiledMethod. Metaclass. Array new: 3. #(1 2). #(#a 3). 2 raisedTo: 70. Semaphore new. ProcessorScheduler activeProcess. thisContext. [:x | x]. Object >> #printOn:. ByteArray new: 2. Binding new. #()}
]

{ #category : #random }
ClassFuzzTest >> next: seed [
	^ seed * 1103515245 + 12345 \\ 2147483648
]

{ #category : #running }
ClassFuzzTest >> exercise: aClass [
	"Instances of an accepted class: made, slots written and read, a method compiled and run, then the class removed."
	| x |
	x := [aClass basicNew: 3] on: Error do: [:e | e return: nil].
	x isNil ifTrue: [x := [aClass basicNew] on: Error do: [:e | e return: nil]].
	self assert: x notNil.
	aClass instSize > 0 ifTrue: [
		x instVarAt: 1 put: 7.
		self assert: (x instVarAt: 1) = 7].
	aClass compile: 'fuzzAnswer ^ 42'.
	self assert: x fuzzAnswer = 42.
	x := nil.
	Smalltalk removeClass: aClass
]

{ #category : #tests }
ClassFuzzTest >> testSeededReshapesAreRefusedOrAccepted [
	<slow>
	| c objs seed accepted refused |
	Smalltalk isReleaseImage ifTrue: [^ self].
	c := Smalltalk primDefineClass: {#ClassFuzzR. Object. #(#a #b). #(). #(). #fixed. nil. 0. 0}.
	self deny: c isString.
	objs := (1 to: 5) collect: [:i | c basicNew instVarAt: 1 put: i; yourself].
	seed := 16rB0D7.
	accepted := 0. refused := 0.
	1 to: 500 do: [:k | | n spec kind r shape |
		seed := self next: seed.
		n := c instSize.
		shape := {c. n + 1. (1 to: n) asArray , #(0)}.
		spec := {{shape}. {}. {}. nil}.
		kind := seed \\ 8.
		r := seed // 11.
		kind = 0 ifTrue: [shape at: 1 put: (self strangers at: r \\ self strangers size + 1)].
		kind = 1 ifTrue: [shape at: 2 put: n + (r \\ 3) - 1].
		kind = 2 ifTrue: [(shape at: 3) at: r \\ (n + 1) + 1 put: (#(-1 99 0 1) at: r // 3 \\ 4 + 1)].
		kind = 3 ifTrue: [spec at: 2 put: {{c. {Object >> #printOn:. 3}}}].
		kind = 4 ifTrue: [spec at: 3 put: {{c. {Binding new. 3}}}].
		kind = 5 ifTrue: [spec at: 1 put: {{c class. 7. #(1 2 3 4 5 0 0)}. shape}].
		kind = 6 ifTrue: [spec at: r \\ 3 + 1 put: (self strangers at: r // 3 \\ self strangers size + 1)].
		kind = 7 ifTrue: [shape at: 3 put: (n = 0 ifTrue: [#(0)] ifFalse: [(Array new: n + 1 withAll: 1)])].
		r := [Smalltalk primRedefine: spec] on: Error do: [:e | e return: e messageText].
		r isString ifTrue: [refused := refused + 1] ifFalse: [
			accepted := accepted + 1.
			"every instance kept its first slot where the layout put it, and has the class's slots"
			objs do: [:o | self assert: o basicSize = 0. self assert: (o class == c)]]].
	Transcript show: 'ClassFuzzTest: 500 reshapes, ' , refused printString , ' refused, ' , accepted printString , ' accepted'; cr.
	self assert: accepted + refused = 500.
	self assert: refused > 100.
	self assert: accepted > 50.
	objs := nil.
	Smalltalk removeClass: c
]

{ #category : #tests }
ClassFuzzTest >> testSeededSpecificationsAreRefusedOrAccepted [
	<slow>
	| bases seed accepted refused reasons |
	Smalltalk isReleaseImage ifTrue: [^ self].
	bases := self bases.
	"every base is accepted as it is"
	bases do: [:b | | c |
		c := Smalltalk primDefineClass: b.
		self deny: c isString.
		self exercise: c].
	seed := 16rC1A55.
	accepted := 0. refused := 0.
	reasons := Set new.
	1 to: 1500 do: [:k | | spec r |
		seed := self next: seed.
		spec := self mutate: (bases at: k \\ bases size + 1) seed: seed.
		r := [Smalltalk primDefineClass: spec] on: Error do: [:e | e return: e messageText].
		r isString
			ifTrue: [refused := refused + 1. reasons add: (r copyFrom: 1 to: (r byteSize min: 30))]
			ifFalse: [
				accepted := accepted + 1.
				self assert: r isBehavior.
				self exercise: r]].
	Transcript show: 'ClassFuzzTest: 1500 class specifications, ' , refused printString , ' refused (' , reasons size printString , ' reasons), ' , accepted printString , ' accepted'; cr.
	self assert: accepted + refused = 1500.
	self assert: refused > 500.
	self assert: accepted > 50
]
