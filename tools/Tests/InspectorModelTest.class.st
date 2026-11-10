"The inspector's and the workspace's models against a fake target (module 9c): an object's slots, diving and coming back, every handle released at the end; do it, print it and inspect it, with self bound by handle."
Class {
	#name : #InspectorModelTest,
	#superclass : #TestCase
}

{ #category : #helpers }
InspectorModelTest >> describe: aValue class: aClass handle: aHandle name: aName [
	| o |
	o := JsonObject new.
	o at: 'value' put: aValue; at: 'class' put: aClass; at: 'handle' put: aHandle.
	aName isNil ifFalse: [o at: 'name' put: aName].
	^ o
]

{ #category : #running }
InspectorModelTest >> tearDown [
	DevTools reset
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
InspectorModelTest >> testObjectsPointingToTheObjectAndToASlotsValue [
	"The pointersTo: follow-up: the slots table's context menu finds the holders of the inspected object (self, by its handle), of a slot's value with a handle (self, by that handle) and of one without (its printString evaluated), each in a new inspector; the object is named once, by an evaluation of self or of the printString, and asked about by the handle that answers (the review fixes, part 2, item 9)."
	| c m w inspectors |
	c := FakeDevClient on: [:kind :args | | src |
		src := args at: 'source' ifAbsent: [''].
		kind = 'inspect'
			ifTrue: [(args at: 'handle') = 20
				ifTrue: [(self describe: '#(a Holder a Holder)' class: 'Array' handle: 20 name: nil) at: 'slots' put: #(); yourself]
				ifFalse: [(self describe: 'thing' class: 'Thing' handle: (args at: 'handle') name: nil)
					at: 'slots' put: {self describe: 'other' class: 'Thing' handle: 12 name: 'next'. self describe: '3' class: 'SmallInteger' handle: nil name: 'count'};
					yourself]]
			ifFalse: [(src endsWith: 'pointerCount')
				ifTrue: [self describe: '2' class: 'SmallInteger' handle: nil name: nil]
				ifFalse: [src = 'self'
					ifTrue: [self describe: 'a Thing' class: 'Thing' handle: (args at: 'receiver') name: nil]
					ifFalse: [src = '3'
						ifTrue: [self describe: '3' class: 'SmallInteger' handle: nil name: nil]
						ifFalse: [self describe: '#(a Holder a Holder)' class: 'Array' handle: 20 name: nil]]]]].
	m := InspectorModel new client: c; yourself.
	w := (InspectorWindow on: m) open.
	m inspect: 2.
	w slotsMenuItem: 41.
	self assert: ((c sent select: [:s | s first = 'evaluate']) collect: [:s | {s last at: 'source'. s last at: 'receiver'}]) asArray
		equals: #(#('self' 2) #('self pointerCount' 2) #('self pointersTo: 1000' 2)).
	inspectors := DevTools windowsOf: InspectorWindow.
	self assert: inspectors size equals: 2.
	self assert: inspectors last model title equals: 'Array #(a Holder a Holder) (2 objects pointing to a Thing)'.
	m selectSlot: 1.
	w slotsMenuItem: 42.
	self assert: (((c sent select: [:s | s first = 'evaluate']) last: 3) collect: [:s | s last at: 'receiver']) asArray equals: #(12 12 12).
	m selectSlot: 2.
	w slotsMenuItem: 42.
	self assert: (((c sent select: [:s | s first = 'evaluate']) last: 3) collect: [:s | {s last at: 'source'. s last at: 'receiver'}]) asArray
		equals: #(#('3' nil) #('(3) pointerCount' nil) #('(3) pointersTo: 1000' nil)).
	self assert: (DevTools windowsOf: InspectorWindow) size equals: 4.
	m selectSlot: 0.
	w slotsMenuItem: 42.
	self assert: m status equals: 'select a slot to find the objects pointing to its value'.
	self assert: (InspectorWindow slotsMenuItems collect: [:i | i at: 2]) asArray equals: #('Objects pointing to it' 'Objects pointing to the slot''s value')
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
