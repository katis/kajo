"A class written out of one image and read back into another (module 8e, TonelRoundTripTests): instance, class and class-side instance variables, a variable format, methods on both sides with blocks, a class variable, a literal of every kind, and a ""quoted"" word."
Class {
	#name : #TonelFixture,
	#superclass : #Object,
	#instVars : [
		'items',
		'count'
	],
	#classVars : [
		'Made'
	],
	#classInstVars : [
		'default'
	],
	#type : #variable
}

{ #category : #accessing }
TonelFixture >> add: anObject [
	items isNil ifTrue: [items := OrderedCollection new].
	items add: anObject.
	count := (count ifNil: [0]) + 1.
	^ anObject
]

{ #category : #accessing }
TonelFixture >> count [
	^ count ifNil: [0]
]

{ #category : #computing }
TonelFixture >> literals [
	^ {#(1 $a 'b' #c 2.5 16r1F). #[1 2 3]. 100000000000000000000. -3. Made}
]

{ #category : #computing }
TonelFixture >> sumWith: aBlock [
	| total |
	total := 0.
	items do: [:e | total := total + (aBlock value: e)].
	^ total
]

{ #category : #'instance creation' }
TonelFixture class >> default [
	^ default ifNil: [default := self new: 3]
]

{ #category : #'instance creation' }
TonelFixture class >> new: n [
	Made := (Made ifNil: [0]) + 1.
	^ self basicNew: n
]
