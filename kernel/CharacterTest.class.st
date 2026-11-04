"Characters are Unicode scalars."
Class {
	#name : #CharacterTest,
	#superclass : #TestCase,
	#category : #'Kernel-Tests'
}

{ #category : #accessing }
CharacterTest >> testClassification [
	self assert: $a isLetter.
	self assert: $5 isDigit.
	self assert: $  isSeparator.
	self assert: $A isUppercase.
	self assert: $a isVowel.
	self deny: $b isVowel.
	self assert: $a asUppercase == $A.
	self assert: $Z asLowercase == $z.
	self assert: $7 digitValue = 7.
	self assert: (Character value: 233) isLetter
]

{ #category : #accessing }
CharacterTest >> testPrinting [
	self assert: $a printString = '$a'.
	self assert: $a asString = 'a'.
	self assert: (Character value: 233) asString utf8Size = 2
]

{ #category : #accessing }
CharacterTest >> testValues [
	self assert: $a value = 97.
	self assert: (Character value: 97) == $a.
	self assert: 97 asCharacter == $a.
	self assert: (Character value: 16r1F600) value = 16r1F600.
	self assert: $a < $b
]
