Class {
	#name : #SymbolTest,
	#superclass : #TestCase,
	#category : #'Kernel-Tests'
}

{ #category : #accessing }
SymbolTest >> testInterning [
	self assert: 'abc' asSymbol == #abc.
	self assert: #abc asString = 'abc'.
	self assert: #abc asString class == String.
	self assert: (Symbol lookup: 'abc') == #abc.
	self assert: (Symbol lookup: 'surelyNotInternedYet12345') isNil.
	self assert: #abc hash = 'abc' hash
]

{ #category : #accessing }
SymbolTest >> testSelectors [
	self assert: #foo numArgs = 0.
	self assert: #+ numArgs = 1.
	self assert: #at:put: numArgs = 2.
	self assert: #at:put: keywords = #('at:' 'put:').
	self assert: (#abs value: -3) = 3.
	self assert: (#+ value: 3 value: 4) = 7
]

{ #category : #accessing }
SymbolTest >> testPrinting [
	self assert: #foo printString = '#foo'.
	self assert: #at:put: printString = '#at:put:'.
	self assert: #+ printString = '#+'.
	self assert: #'hello world' printString = '#''hello world'''
]
