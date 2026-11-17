"A key and a value; what a Dictionary holds."
Class {
	#name : #Association,
	#superclass : #Magnitude,
	#typeParameters : [
		'K',
		'V'
	],
	#superclassType : 'Magnitude',
	#instVars : [
		'key <K>',
		'value <V>'
	]
}

{ #category : #accessing }
Association >> < anAssociation <Association> ^<Boolean> [
	^ key < anAssociation key
]

{ #category : #accessing }
Association >> = anObject <Object> ^<Boolean> [
	^ (anObject isKindOf: Association) and: [key = anObject key and: [value = anObject value]]
]

{ #category : #accessing }
Association >> hash ^<Integer> [
	^ key hash
]

{ #category : #accessing }
Association >> key ^<K> [
	^ key
]

{ #category : #accessing }
Association >> key: k <K> ^<Self> [
	key := k
]

{ #category : #accessing }
Association >> key: k <K> value: v <V> ^<Self> [
	key := k.
	value := v
]

{ #category : #accessing }
Association >> printOn: aStream [
	aStream print: key; nextPutAll: '->'; print: value
]

{ #category : #accessing }
Association >> value ^<V> [
	^ value
]

{ #category : #accessing }
Association >> value: v <V> ^<Self> [
	value := v
]

{ #category : #accessing }
Association class >> key: k <:X> value: v <:Y> ^<Instance[X, Y]> [
	^ self basicNew key: k value: v
]
