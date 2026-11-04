"The inspector's and the workspace's models against a fake target (module 9c): an object's slots, diving and coming back, every handle released at the end; do it, print it and inspect it, with self bound by handle."
Class {
	#name : #InspectorModelTest,
	#superclass : #TestCase,
	#category : #'Tools-Tests'
}

{ #category : #helpers }
InspectorModelTest >> describe: aValue class: aClass handle: aHandle name: aName [
	| o |
	o := JsonObject new.
	o at: 'value' put: aValue; at: 'class' put: aClass; at: 'handle' put: aHandle.
	aName isNil ifFalse: [o at: 'name' put: aName].
	^ o
]

{ #category : #tests }
InspectorModelTest >> testDoPrintAndInspectIt [
	| c w inspected printed |
	c := FakeDevClient on: [:kind :args | self describe: '7' class: 'SmallInteger' handle: 5 name: nil].
	w := WorkspaceModel new client: c; yourself.
	w inspectAction: [:d :client | inspected := d at: 'handle'].
	w doIt: '3 + 4'.
	self assert: w status equals: 'SmallInteger: 7'.
	self assert: (c sent last last at: 'source') equals: '3 + 4'.
	w inspectIt: '3 + 4'.
	self assert: inspected equals: 5.
	w printIt: '3 + 4'.
	self assert: (w lastResult at: 'value') equals: '7'.
	w doIt: ''.
	self assert: c sent size equals: 3
]

{ #category : #tests }
InspectorModelTest >> testSlotsDiveBackAndRelease [
	| c m |
	c := FakeDevClient on: [:kind :args | | h |
		kind = 'inspect' ifTrue: [
			h := args at: 'handle'.
			(self describe: 'thing ' , h printString class: 'Thing' handle: h name: nil)
				at: 'slots' put: {self describe: 'other' class: 'Thing' handle: h + 10 name: 'next'. self describe: '3' class: 'SmallInteger' handle: nil name: 'count'};
				yourself]
		ifFalse: [self describe: '1' class: 'SmallInteger' handle: nil name: nil]].
	m := InspectorModel new client: c; yourself.
	m inspect: 2.
	self assert: (m object at: 'value') equals: 'thing 2'.
	self assert: (m slots collect: [:s | s at: 'name']) asArray equals: #('next' 'count').
	m dive: 1.
	self assert: m handle equals: 12.
	m dive: 2.
	self assert: m handle equals: 12.
	m back.
	self assert: m handle equals: 2.
	m workspace doIt: 'self foo'.
	self assert: (c sent last last at: 'receiver') equals: 2.
	m closed.
	self assert: (c sentKinds select: [:k | k = 'inspect.release']) size equals: 3
]
