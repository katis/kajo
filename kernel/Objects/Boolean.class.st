"true and false. Literal-block ifTrue:, and: and their friends are compiled inline; these methods serve other arguments and perform:."
Class {
	#name : #Boolean,
	#superclass : #Object
}

{ #category : #accessing }
Boolean >> & aBoolean [
	^ self subclassResponsibility
]

{ #category : #accessing }
Boolean >> and: aBlock [
	^ self subclassResponsibility
]

{ #category : #accessing }
Boolean >> eqv: aBoolean [
	^ self == aBoolean
]

{ #category : #accessing }
Boolean >> ifFalse: aBlock [
	^ self subclassResponsibility
]

{ #category : #accessing }
Boolean >> ifFalse: falseBlock ifTrue: trueBlock [
	^ self ifTrue: trueBlock ifFalse: falseBlock
]

{ #category : #accessing }
Boolean >> ifTrue: aBlock [
	^ self subclassResponsibility
]

{ #category : #accessing }
Boolean >> ifTrue: trueBlock ifFalse: falseBlock [
	^ self subclassResponsibility
]

{ #category : #accessing }
Boolean >> isBoolean [
	^ true
]

{ #category : #accessing }
Boolean >> isLiteral [
	^ true
]

{ #category : #accessing }
Boolean >> not [
	^ self subclassResponsibility
]

{ #category : #accessing }
Boolean >> or: aBlock [
	^ self subclassResponsibility
]

{ #category : #accessing }
Boolean >> shallowCopy [
	^ self
]

{ #category : #accessing }
Boolean >> xor: aBoolean [
	^ self ~~ aBoolean value
]

{ #category : #accessing }
Boolean >> | aBoolean [
	^ self subclassResponsibility
]
