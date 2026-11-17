"An arithmetic progression: 1 to: 10, 10 to: 1 by: -2."
Class {
	#name : #Interval,
	#superclass : #SequenceableCollection,
	#typeParameters : [
		'N'
	],
	#instVars : [
		'start <N>',
		'stop <Number>',
		'step <Number>'
	]
}

{ #category : #accessing }
Interval >> at: index <Integer> ^<N> [
	(index isInteger and: [index between: 1 and: self size]) ifFalse: [^ self indexError: index].
	^ start + (step * (index - 1))
]

{ #category : #accessing }
Interval >> at: index put: anObject [
	^ self shouldNotImplement
]

{ #category : #accessing }
Interval >> collect: aBlock <[N, ^:X]> ^<Array[X]> [
	| out i |
	out := Array new: self size.
	i := 0.
	self do: [:e | out at: (i := i + 1) put: (aBlock value: e)].
	^ out
]

{ #category : #accessing }
Interval >> do: aBlock <[N, ^Dynamic]> ^<Self> [
	| i |
	i := start.
	step > 0
		ifTrue: [[i <= stop] whileTrue: [aBlock value: i. i := i + step]]
		ifFalse: [[i >= stop] whileTrue: [aBlock value: i. i := i + step]]
]

{ #category : #accessing }
Interval >> first ^<N> [
	^ start
]

{ #category : #accessing }
Interval >> increment ^<Number> [
	^ step
]

{ #category : #accessing }
Interval >> last ^<N> [
	^ stop - ((stop - start) \\ step)
]

{ #category : #accessing }
Interval >> printOn: aStream [
	aStream nextPut: $(; print: start; nextPutAll: ' to: '; print: stop.
	step = 1 ifFalse: [aStream nextPutAll: ' by: '; print: step].
	aStream nextPut: $)
]

{ #category : #accessing }
Interval >> select: aBlock <[N, ^Boolean]> ^<Array[N]>

{ #category : #accessing }
Interval >> setFrom: a <Number> to: b <Number> by: s <Number> ^<Self> [
	start := a. stop := b. step := s
]

{ #category : #accessing }
Interval >> size ^<Integer> [
	step > 0 ifTrue: [stop < start ifTrue: [^ 0]. ^ stop - start // step + 1].
	start < stop ifTrue: [^ 0].
	^ start - stop // step negated + 1
]

{ #category : #accessing }
Interval >> species ^<Behavior> [
	^ Array
]

{ #category : #accessing }
Interval class >> from: a <:X> to: b <Number> ^<Instance[X]> [
	^ self from: a to: b by: 1
]

{ #category : #accessing }
Interval class >> from: a <:X> to: b <Number> by: s <Number> ^<Instance[X]> [
	s = 0 ifTrue: [^ self error: 'step must not be zero'].
	^ self basicNew setFrom: a to: b by: s
]
