"An arithmetic progression: 1 to: 10, 10 to: 1 by: -2."
Class {
	#name : #Interval,
	#superclass : #SequenceableCollection,
	#instVars : [
		'start',
		'stop',
		'step'
	],
	#category : #'Kernel-Collections'
}

{ #category : #accessing }
Interval class >> from: a to: b [
	^ self from: a to: b by: 1
]

{ #category : #accessing }
Interval class >> from: a to: b by: s [
	s = 0 ifTrue: [^ self error: 'step must not be zero'].
	^ self basicNew setFrom: a to: b by: s
]

{ #category : #accessing }
Interval >> setFrom: a to: b by: s [
	start := a. stop := b. step := s
]

{ #category : #accessing }
Interval >> first [
	^ start
]

{ #category : #accessing }
Interval >> increment [
	^ step
]

{ #category : #accessing }
Interval >> size [
	step > 0 ifTrue: [stop < start ifTrue: [^ 0]. ^ stop - start // step + 1].
	start < stop ifTrue: [^ 0].
	^ start - stop // step negated + 1
]

{ #category : #accessing }
Interval >> last [
	^ stop - ((stop - start) \\ step)
]

{ #category : #accessing }
Interval >> at: index [
	(index isInteger and: [index between: 1 and: self size]) ifFalse: [^ self indexError: index].
	^ start + (step * (index - 1))
]

{ #category : #accessing }
Interval >> at: index put: anObject [
	^ self shouldNotImplement
]

{ #category : #accessing }
Interval >> do: aBlock [
	| i |
	i := start.
	step > 0
		ifTrue: [[i <= stop] whileTrue: [aBlock value: i. i := i + step]]
		ifFalse: [[i >= stop] whileTrue: [aBlock value: i. i := i + step]]
]

{ #category : #accessing }
Interval >> collect: aBlock [
	| out i |
	out := Array new: self size.
	i := 0.
	self do: [:e | out at: (i := i + 1) put: (aBlock value: e)].
	^ out
]

{ #category : #accessing }
Interval >> species [
	^ Array
]

{ #category : #accessing }
Interval >> printOn: aStream [
	aStream nextPut: $(; print: start; nextPutAll: ' to: '; print: stop.
	step = 1 ifFalse: [aStream nextPutAll: ' by: '; print: step].
	aStream nextPut: $)
]
