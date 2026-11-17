"The dynamic type: not checked. Every type is assignable to it and it to every type (the way out of the type system, TypeScript's any)."
Class {
	#name : #OTDynamic,
	#superclass : #OTType
}

{ #category : #testing }
OTDynamic >> isDynamic [
	^ true
]

{ #category : #testing }
OTDynamic >> isKnown [
	^ false
]

{ #category : #printing }
OTDynamic >> printOn: aStream [
	aStream nextPutAll: 'Dynamic'
]
