"An Array longer than one object can be (module 9c): no object is larger than one heap block (32 KiB, 4095 slots), so a sequence of more elements keeps them in Arrays of 2048, indexed from 1 like an Array. Array large: n answers an Array when n fits one object and a LargeArray otherwise; the kernel's growable collections (OrderedCollection, the hashed ones) and their asArray use it, so a table of the image (every behavior, the sources by behavior, the class names) can pass 4095 entries. It is a SequenceableCollection, not an Array: its at: and at:put: are sends, not the fast paths."
Class {
	#name : #LargeArray,
	#superclass : #SequenceableCollection,
	#instVars : [
		'chunks',
		'size'
	],
	#category : #'Kernel-Collections'
}

{ #category : #accessing }
LargeArray >> at: index [
	(index isInteger and: [index between: 1 and: size]) ifFalse: [^ self indexError: index].
	^ (chunks at: index - 1 // 2048 + 1) at: index - 1 \\ 2048 + 1
]

{ #category : #accessing }
LargeArray >> at: index put: anObject [
	(index isInteger and: [index between: 1 and: size]) ifFalse: [^ self indexError: index].
	^ (chunks at: index - 1 // 2048 + 1) at: index - 1 \\ 2048 + 1 put: anObject
]

{ #category : #accessing }
LargeArray >> do: aBlock [
	chunks do: [:c | c do: aBlock]
]

{ #category : #accessing }
LargeArray >> postCopy [
	chunks := chunks collect: [:c | c copy]
]

{ #category : #accessing }
LargeArray >> printOn: aStream [
	aStream nextPutAll: 'a LargeArray('; print: size; nextPut: $)
]

{ #category : #accessing }
LargeArray >> setSize: n [
	| left |
	size := n.
	chunks := Array new: n + 2047 // 2048.
	left := n.
	1 to: chunks size do: [:i |
		chunks at: i put: (Array new: (left min: 2048)).
		left := left - 2048]
]

{ #category : #accessing }
LargeArray >> size [
	^ size
]

{ #category : #accessing }
LargeArray >> species [
	^ LargeArray
]

{ #category : #'instance creation' }
LargeArray class >> new [
	^ self new: 0
]

{ #category : #'instance creation' }
LargeArray class >> new: n [
	^ self basicNew setSize: n
]
