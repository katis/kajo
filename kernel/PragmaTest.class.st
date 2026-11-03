"Pragmas are literals of their methods; the index answers Pragma allNamed:."
Class {
	#name : #PragmaTest,
	#superclass : #TestCase,
	#category : #'Kernel-Tests'
}

{ #category : #accessing }
PragmaTest >> testPragmasOfAMethod [
	| m |
	m := TestCase class >> #consumesPragmas.
	self assert: m pragmas size = 1.
	self assert: m pragmas first selector == #consumesPragmas:.
	self assert: m pragmas first arguments first = #(#slow #device #expectedFailure).
	self assert: m pragmas first method == m.
	self assert: (m pragmaAt: #consumesPragmas:) notNil.
	self assert: m pragmas first isReadOnly
]

{ #category : #accessing }
PragmaTest >> testPrimitiveIsNotAPragmaLiteral [
	self assert: (SmallInteger >> #+) pragmas isEmpty.
	self assert: (SmallInteger >> #+) primitive = 40
]

{ #category : #accessing }
PragmaTest >> testIndex [
	| all |
	all := Pragma allNamed: #consumesPragmas:.
	self assert: all size >= 2.
	self assert: (all anySatisfy: [:p | p methodClass == TestCase class]).
	self assert: ((Pragma allNamed: #consumesPragmas: in: TestCase class) size = 1).
	self assert: (Pragma allNamed: #expectedFailure) notEmpty
]

{ #category : #accessing }
PragmaTest >> testExpectedFailureTag [
	<expectedFailure>
	self assert: false
]

{ #category : #accessing }
PragmaTest >> testTags [
	self assert: (PragmaTest selector: #testExpectedFailureTag) isExpectedFailure.
	self assert: (PragmaTest selector: #testExpectedFailureTag) tags = #(#expectedFailure)
]
