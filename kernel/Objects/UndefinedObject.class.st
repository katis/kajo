"nil, the sole instance."
Class {
	#name : #UndefinedObject,
	#superclass : #Object
}

{ #category : #accessing }
UndefinedObject >> ifNil: nilBlock <[^:R]> ^<R> [
	^ nilBlock value
]

{ #category : #accessing }
UndefinedObject >> ifNil: nilBlock <[^:R]> ifNotNil: aBlock <Dynamic> ^<R> [
	^ nilBlock value
]

{ #category : #accessing }
UndefinedObject >> ifNotNil: aBlock <Dynamic> ^<Nil> [
	^ nil
]

{ #category : #accessing }
UndefinedObject >> ifNotNil: aBlock <Dynamic> ifNil: nilBlock <[^:R]> ^<R> [
	^ nilBlock value
]

{ #category : #accessing }
UndefinedObject >> isEmptyOrNil ^<Boolean> [
	^ true
]

{ #category : #accessing }
UndefinedObject >> isLiteral ^<Boolean> [
	^ true
]

{ #category : #accessing }
UndefinedObject >> isNil ^<Boolean> [
	^ true
]

{ #category : #accessing }
UndefinedObject >> notNil ^<Boolean> [
	^ false
]

{ #category : #accessing }
UndefinedObject >> printOn: aStream <WriteStream> ^<Self> [
	aStream nextPutAll: 'nil'
]

{ #category : #accessing }
UndefinedObject >> shallowCopy ^<Self> [
	^ self
]
