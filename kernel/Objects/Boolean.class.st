"true and false. Literal-block ifTrue:, and: and their friends are compiled inline; these methods serve other arguments and perform:."
Class {
	#name : #Boolean,
	#superclass : #Object
}

{ #category : #accessing }
Boolean >> & aBoolean <Boolean> ^<Boolean> [
	^ self subclassResponsibility
]

{ #category : #accessing }
Boolean >> and: aBlock <[^Boolean]> ^<Boolean> [
	^ self subclassResponsibility
]

{ #category : #accessing }
Boolean >> eqv: aBoolean <Boolean> ^<Boolean> [
	^ self == aBoolean
]

{ #category : #accessing }
Boolean >> ifFalse: aBlock <[^:X]> ^<X | Nil> [
	^ self subclassResponsibility
]

{ #category : #accessing }
Boolean >> ifFalse: falseBlock <[^:X]> ifTrue: trueBlock <[^:Y]> ^<X | Y> [
	^ self ifTrue: trueBlock ifFalse: falseBlock
]

{ #category : #accessing }
Boolean >> ifTrue: aBlock <[^:X]> ^<X | Nil> [
	^ self subclassResponsibility
]

{ #category : #accessing }
Boolean >> ifTrue: trueBlock <[^:X]> ifFalse: falseBlock <[^:Y]> ^<X | Y> [
	^ self subclassResponsibility
]

{ #category : #accessing }
Boolean >> isBoolean ^<Boolean> [
	^ true
]

{ #category : #accessing }
Boolean >> isLiteral ^<Boolean> [
	^ true
]

{ #category : #accessing }
Boolean >> not ^<Boolean> [
	^ self subclassResponsibility
]

{ #category : #accessing }
Boolean >> or: aBlock <[^Boolean]> ^<Boolean> [
	^ self subclassResponsibility
]

{ #category : #accessing }
Boolean >> shallowCopy ^<Self> [
	^ self
]

{ #category : #accessing }
Boolean >> xor: aBoolean <Boolean> ^<Boolean> [
	^ self ~~ aBoolean value
]

{ #category : #accessing }
Boolean >> | aBoolean <Boolean> ^<Boolean> [
	^ self subclassResponsibility
]
