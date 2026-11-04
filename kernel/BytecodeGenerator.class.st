"The assembler of the Smalltalk compiler: bytecode set v1 (Sources/KajoVM/Interpreter/Opcodes.swift) in a table, a body's instructions to bytes with the literal frame in first-use order (duplicates merged, pragmas last), the ext prefix for operands past 255, jumps resolved, and the stack-depth trace the VM's verifier makes for maxStack. Instructions: {#op. opcode. a. b}, {#label. name}, {#literal. object}, {#send. opcode. selector. argc}, {#closure. aCompiledCode. copied}, {#jump. opcode. label}."
Class {
	#name : #BytecodeGenerator,
	#superclass : #Object,
	#instVars : [
		'lines',
		'literals',
		'labels'
	],
	#category : #'Kernel-Compiler'
}

{ #category : #accessing }
BytecodeGenerator >> assembleWithExtraLiterals: extra [
	"Answer {bytes. literals. maxStack}."
	| ins offsets bytes n k |
	literals := OrderedCollection new.
	labels := Dictionary new.
	ins := OrderedCollection new.
	lines do: [:l | | kind |
		kind := l first.
		kind == #label ifTrue: [labels at: (l at: 2) put: ins size + 1].
		kind == #op ifTrue: [ins add: {l at: 2. l at: 3. l at: 4. nil}].
		kind == #literal ifTrue: [ins add: {#pushLiteral. self literalIndex: (l at: 2). 0. nil}].
		kind == #send ifTrue: [ins add: {l at: 2. self literalIndex: (l at: 3). l at: 4. nil}].
		kind == #closure ifTrue: [ins add: {#pushClosure. self literalIndex: (l at: 2). l at: 3. nil}].
		kind == #jump ifTrue: [ins add: {l at: 2. 0. 0. l at: 3}]].
	extra do: [:x | self literalIndex: x].
	n := ins size.
	offsets := Array new: n + 1.
	offsets at: 1 put: 0.
	1 to: n do: [:i | | op wide |
		op := (ins at: i) first.
		wide := (BytecodeGenerator isExtensible: op) and: [((ins at: i) at: 2) > 255].
		offsets at: i + 1 put: (offsets at: i) + (BytecodeGenerator length: op) + (wide ifTrue: [2] ifFalse: [0])].
	bytes := WriteStream on: (ByteArray new: 0).
	1 to: n do: [:i | | inst op a o rel |
		inst := ins at: i.
		op := inst first.
		a := inst at: 2.
		((BytecodeGenerator isExtensible: op) and: [a > 255]) ifTrue: [
			bytes nextPut: (BytecodeGenerator number: #ext); nextPut: (a bitShift: -8).
			a := a bitAnd: 255].
		bytes nextPut: (BytecodeGenerator number: op).
		o := BytecodeGenerator operands: op.
		o == #index ifTrue: [bytes nextPut: a].
		o == #int8 ifTrue: [bytes nextPut: (a bitAnd: 255)].
		(#(#send #closure #vectorSlot) includes: o) ifTrue: [bytes nextPut: a; nextPut: (inst at: 3)].
		o == #jump ifTrue: [
			rel := (offsets at: (labels at: (inst at: 4))) - (offsets at: i + 1).
			bytes nextPut: (rel bitAnd: 255); nextPut: ((rel bitShift: -8) bitAnd: 255)]].
	k := self maxStackOf: ins.
	^ {bytes contents. literals asArray. k}
]

{ #category : #accessing }
BytecodeGenerator >> literalIndex: anObject [
	literals doWithIndex: [:l :i | (BytecodeGenerator literal: l sameAs: anObject) ifTrue: [^ i - 1]].
	literals add: anObject.
	^ literals size - 1
]

{ #category : #accessing }
BytecodeGenerator >> maxStackOf: ins [
	"The verifier's trace: one depth per reachable instruction; the peak counts each instruction's transient words."
	| depth work max |
	ins isEmpty ifTrue: [^ 0].
	depth := Array new: ins size withAll: -1.
	work := OrderedCollection new.
	depth at: 1 put: 0.
	work add: 1.
	max := 0.
	[work isEmpty] whileFalse: [ | k inst op d after peak |
		k := work removeLast.
		inst := ins at: k.
		op := inst first.
		d := depth at: k.
		after := d - (BytecodeGenerator pops: op argc: (inst at: 3)) + (BytecodeGenerator pushes: op).
		peak := after max: d + (BytecodeGenerator transientDepth: op).
		max := max max: peak.
		(inst at: 4) ifNotNil: [:label | | t |
			t := labels at: label.
			(depth at: t) = -1 ifTrue: [depth at: t put: after. work add: t]].
		((BytecodeGenerator endsBlock: op) not and: [k < ins size]) ifTrue: [
			(depth at: k + 1) = -1 ifTrue: [depth at: k + 1 put: after. work add: k + 1]]].
	^ max
]

{ #category : #accessing }
BytecodeGenerator >> setLines: anOrderedCollection [
	lines := anOrderedCollection
]

{ #category : #accessing }
BytecodeGenerator class >> endsBlock: op [
	^ #(#returnTop #returnSelf #jump #blockReturn #nonlocalReturn) includes: op
]

{ #category : #accessing }
BytecodeGenerator class >> isExtensible: op [
	^ #(#pushTemp #pushLiteral #pushIvar #storeTemp #storeIvar #pushNewArray #send #sendSuper #pushClosure #pushTempVectorSlot #storeTempVectorSlot) includes: op
]

{ #category : #accessing }
BytecodeGenerator class >> length: op [
	| o |
	o := self operands: op.
	o == #none ifTrue: [^ 1].
	(#(#index #int8 #prefix) includes: o) ifTrue: [^ 2].
	^ 3
]

{ #category : #accessing }
BytecodeGenerator class >> literal: a sameAs: b [
	"Literal identity as the assembler merges literals: the same class and value, floats by their bits (their shortest spelling), Arrays element by element."
	a class == b class ifFalse: [^ false].
	a isArray ifTrue: [
		a size = b size ifFalse: [^ false].
		a with: b do: [:x :y | (self literal: x sameAs: y) ifFalse: [^ false]].
		^ true].
	a isFloat ifTrue: [^ a printString = b printString].
	(a isKindOf: CompiledCode) ifTrue: [^ a == b].
	(a isKindOf: Pragma) ifTrue: [^ a == b].
	^ a = b
]

{ #category : #accessing }
BytecodeGenerator class >> number: op [
	^ (self opcodes indexOf: op) - 1
]

{ #category : #accessing }
BytecodeGenerator class >> opcodes [
	^ #(#pushTemp #pushLiteral #pushSelf #pushIvar #storeTemp #storeIvar #pop #dup #pushNil #pushTrue #pushFalse #pushInt #send #returnTop #returnSelf #jump #jumpIfTrue #jumpIfFalse #add #sub #mul #lt #gt #le #ge #eq #identical #div #intDiv #mod #ne #notIdentical #at #atPut #size #classOf #value #value1 #value2 #isNil #notNil #sendSuper #pushClosure #pushNewArray #pushTempVectorSlot #storeTempVectorSlot #pushThisContext #blockReturn #nonlocalReturn #ext)
]

{ #category : #accessing }
BytecodeGenerator class >> operands: op [
	(#(#pushTemp #pushLiteral #pushIvar #storeTemp #storeIvar #pushNewArray) includes: op) ifTrue: [^ #index].
	op == #pushInt ifTrue: [^ #int8].
	(#(#send #sendSuper) includes: op) ifTrue: [^ #send].
	(#(#jump #jumpIfTrue #jumpIfFalse) includes: op) ifTrue: [^ #jump].
	op == #pushClosure ifTrue: [^ #closure].
	(#(#pushTempVectorSlot #storeTempVectorSlot) includes: op) ifTrue: [^ #vectorSlot].
	op == #ext ifTrue: [^ #prefix].
	^ #none
]

{ #category : #accessing }
BytecodeGenerator class >> pops: op argc: n [
	(#(#pushTemp #pushLiteral #pushSelf #pushIvar #pushNil #pushTrue #pushFalse #pushInt #pushNewArray #pushTempVectorSlot #pushThisContext) includes: op) ifTrue: [^ 0].
	(#(#storeTemp #storeIvar #pop #jumpIfTrue #jumpIfFalse #storeTempVectorSlot #dup #returnTop #blockReturn #nonlocalReturn) includes: op) ifTrue: [^ 1].
	(#(#send #sendSuper) includes: op) ifTrue: [^ n + 1].
	op == #pushClosure ifTrue: [^ n].
	(#(#returnSelf #jump #ext) includes: op) ifTrue: [^ 0].
	^ (self specialArgc: op) + 1
]

{ #category : #accessing }
BytecodeGenerator class >> pushes: op [
	(#(#storeTemp #storeIvar #pop #jumpIfTrue #jumpIfFalse #storeTempVectorSlot #returnTop #blockReturn #nonlocalReturn #returnSelf #jump #ext) includes: op) ifTrue: [^ 0].
	op == #dup ifTrue: [^ 2].
	^ 1
]

{ #category : #accessing }
BytecodeGenerator class >> special: aSymbol arguments: n [
	"The opcode a send of aSymbol with n arguments compiles to, or nil."
	self specialSelectors do: [:e | ((e at: 1) == aSymbol and: [(e at: 3) = n]) ifTrue: [^ e at: 2]].
	^ nil
]

{ #category : #accessing }
BytecodeGenerator class >> specialArgc: op [
	(#(#atPut #value2) includes: op) ifTrue: [^ 2].
	(#(#size #classOf #value #isNil #notNil) includes: op) ifTrue: [^ 0].
	^ 1
]

{ #category : #accessing }
BytecodeGenerator class >> specialSelectors [
	"Selector, opcode, arguments."
	^ #(#(#+ #add 1) #(#- #sub 1) #(#* #mul 1) #(#< #lt 1) #(#> #gt 1) #(#<= #le 1) #(#>= #ge 1) #(#= #eq 1) #(#== #identical 1) #(#/ #div 1) #(#// #intDiv 1) #(#\\ #mod 1) #(#~= #ne 1) #(#~~ #notIdentical 1) #(#at: #at 1) #(#at:put: #atPut 2) #(#size #size 0) #(#class #classOf 0) #(#value #value 0) #(#value: #value1 1) #(#value:value: #value2 2) #(#isNil #isNil 0) #(#notNil #notNil 0))
]

{ #category : #accessing }
BytecodeGenerator class >> transientDepth: op [
	(#(#storeIvar #storeTempVectorSlot) includes: op) ifTrue: [^ 2].
	op == #nonlocalReturn ifTrue: [^ 2].
	^ 0
]
