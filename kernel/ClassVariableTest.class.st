"Class variables (module 8d): shared by a class, its class side and its subclasses, not seen elsewhere, never shadowed, reached by reflection, and compiled as the Binding itself in the literal frame."
Class {
	#name : #ClassVariableTest,
	#superclass : #TestCase,
	#category : #'Kernel-Tests'
}

{ #category : #running }
ClassVariableTest >> tearDown [
	ClassVariableSample reset
]

{ #category : #tests }
ClassVariableTest >> testBothSidesAndSubclassesShareIt [
	ClassVariableSample reset.
	ClassVariableSample new bump.
	self assert: ClassVariableSample count = 1.
	self assert: ClassVariableSampleChild new bumpTwice = 3.
	self assert: ClassVariableSampleChild seen = 3.
	self assert: ClassVariableSample new count = 3.
	ClassVariableSample count: 10.
	self assert: ClassVariableSampleChild new count = 10
]

{ #category : #tests }
ClassVariableTest >> testAnUnrelatedClassDoesNotSeeIt [
	self should: [Compiler compile: 'f ^ Count' in: Object] raise: CompileError.
	self should: [Compiler compile: 'f ^ Count' in: Object class] raise: CompileError.
	self assert: (Compiler compile: 'f ^ Count' in: ClassVariableSampleChild class) notNil
]

{ #category : #tests }
ClassVariableTest >> testNoTempOrArgumentShadowsIt [
	#('f | Count | ^ 1' 'f: Count ^ 1' 'f ^ [:Count | 1]' 'f ^ [| Count | 1]') do: [:src |
		self should: [Compiler compile: src in: ClassVariableSample] raise: CompileError.
		self should: [Compiler compile: src in: ClassVariableSampleChild class] raise: CompileError]
]

{ #category : #tests }
ClassVariableTest >> testReflection [
	| b |
	self assert: ClassVariableSample classVarNames = #(#Count).
	self assert: ClassVariableSampleChild classVarNames isEmpty.
	b := ClassVariableSample classVariableNamed: #Count.
	self assert: b key == #Count.
	self assert: (ClassVariableSampleChild classVariableNamed: 'Count') == b.
	self assert: (ClassVariableSample class bindingOf: #Count) == b.
	self assert: (ClassVariableSample classPool at: #Count) == b.
	self assert: (Object classVariableNamed: #Count) isNil.
	self assert: (ClassVariableSample classVariableOwnerOf: #Count) == ClassVariableSample.
	self assert: (Float classVarNames includes: #NaN).
	self assert: Float infinity > 1.0e300.
	self assert: Float nan ~= Float nan
]

{ #category : #tests }
ClassVariableTest >> testTheLiteralIsTheBinding [
	| b code |
	b := ClassVariableSample bindingOf: #Count.
	self assert: ((ClassVariableSample >> #count) literals anySatisfy: [:l | l == b]).
	self assert: ((ClassVariableSampleChild class >> #seen) literals anySatisfy: [:l | l == b]).
	code := Compiler compile: 'f ^ Count := Count + 1' in: ClassVariableSampleChild.
	self assert: code literals size = 1.
	self assert: code literals first == b.
	code := Compiler compile: (Smalltalk sourceOf: ClassVariableSample >> #bump) in: ClassVariableSample.
	self assert: (code matches: ClassVariableSample >> #bump) isNil
]

{ #category : #tests }
ClassVariableTest >> testABecomeOfTheValue [
	| a b |
	a := Array with: 1.
	b := Array with: 2 with: 3.
	ClassVariableSample count: a.
	a become: b.
	self assert: ClassVariableSample count size = 2.
	self assert: (ClassVariableSample bindingOf: #Count) value == a
]
