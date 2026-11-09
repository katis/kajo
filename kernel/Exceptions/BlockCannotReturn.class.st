"A non-local return whose home method has already returned."
Class {
	#name : #BlockCannotReturn,
	#superclass : #Error,
	#instVars : [
		'result'
	]
}

{ #category : #accessing }
BlockCannotReturn >> result [
	^ result
]

{ #category : #accessing }
BlockCannotReturn >> result: anObject [
	result := anObject
]
