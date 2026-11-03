"nil, the sole instance."
Class {
	#name : #UndefinedObject,
	#superclass : #Object,
	#category : #'Kernel-Objects'
}

{ #category : #accessing }
UndefinedObject >> isNil [
	^ true
]

{ #category : #accessing }
UndefinedObject >> notNil [
	^ false
]

{ #category : #accessing }
UndefinedObject >> isEmptyOrNil [
	^ true
]

{ #category : #accessing }
UndefinedObject >> ifNil: nilBlock [
	^ nilBlock value
]

{ #category : #accessing }
UndefinedObject >> ifNotNil: aBlock [
	^ nil
]

{ #category : #accessing }
UndefinedObject >> ifNil: nilBlock ifNotNil: aBlock [
	^ nilBlock value
]

{ #category : #accessing }
UndefinedObject >> ifNotNil: aBlock ifNil: nilBlock [
	^ nilBlock value
]

{ #category : #accessing }
UndefinedObject >> isLiteral [
	^ true
]

{ #category : #accessing }
UndefinedObject >> printOn: aStream [
	aStream nextPutAll: 'nil'
]

{ #category : #accessing }
UndefinedObject >> shallowCopy [
	^ self
]
