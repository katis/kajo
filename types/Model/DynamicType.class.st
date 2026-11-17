"The dynamic type: not checked. Every type is assignable to it and it to every type (the way out of the type system, TypeScript's any)."
Class {
	#name : #DynamicType,
	#superclass : #Type
}

{ #category : #printing }
DynamicType >> printOn: aStream [
	aStream nextPutAll: 'Dynamic'
]

{ #category : #testing }
DynamicType >> isDynamic [
	^ true
]

{ #category : #testing }
DynamicType >> isKnown [
	^ false
]
