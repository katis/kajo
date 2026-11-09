"A class with a class variable, for ClassVariableTest (module 8d)."
Class {
	#name : #ClassVariableSample,
	#superclass : #Object,
	#classVars : [
		'Count'
	]
}

{ #category : #accessing }
ClassVariableSample >> bump [
	^ Count := Count + 1
]

{ #category : #accessing }
ClassVariableSample >> count [
	^ Count
]

{ #category : #accessing }
ClassVariableSample class >> count [
	^ Count
]

{ #category : #accessing }
ClassVariableSample class >> count: anObject [
	Count := anObject
]

{ #category : #accessing }
ClassVariableSample class >> reset [
	Count := 0
]
