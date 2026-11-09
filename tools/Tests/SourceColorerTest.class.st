"Syntax colouring with the kernel's Scanner (module 9c)."
Class {
	#name : #SourceColorerTest,
	#superclass : #TestCase
}

{ #category : #helpers }
SourceColorerTest >> stylesOf: aString [
	"{text. style} for each range."
	| s out |
	s := SourceColorer stylesFor: aString.
	out := OrderedCollection new.
	1 to: s size by: 3 do: [:i | out add: {aString copyFrom: (s at: i) to: (s at: i + 1). s at: i + 2}].
	^ out asArray
]

{ #category : #tests }
SourceColorerTest >> testASourceItCannotReadIsColouredUpToTheError [
	| st |
	st := self stylesOf: 'foo
	^ self ''unterminated'.
	self assert: (st includes: #('self' 'color:teal')).
	self assert: (SourceColorer stylesFor: '') equals: #()
]

{ #category : #tests }
SourceColorerTest >> testTokensAndComments [
	| st |
	st := self stylesOf: 'at: i put: v
	"store it"
	^ self foo: #bar with: ''x'' and: 42 and: Transcript'.
	self assert: st first equals: #('at: i put: v' 'bold').
	self assert: (st includes: #('"store it"' 'color:gray')).
	self assert: (st includes: #('self' 'color:teal')).
	self assert: (st includes: #('#bar' 'color:brown')).
	self assert: (st includes: #('''x''' 'color:brown')).
	self assert: (st includes: #('42' 'color:green')).
	self assert: (st includes: #('Transcript' 'color:purple'))
]
