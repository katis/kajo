Class {
	#name : #True,
	#superclass : #Boolean,
	#category : #'Kernel-Objects'
}

{ #category : #accessing }
True >> & aBoolean [
	^ aBoolean
]

{ #category : #accessing }
True >> and: aBlock [
	^ aBlock value
]

{ #category : #accessing }
True >> ifFalse: aBlock [
	^ nil
]

{ #category : #accessing }
True >> ifTrue: aBlock [
	^ aBlock value
]

{ #category : #accessing }
True >> ifTrue: trueBlock ifFalse: falseBlock [
	^ trueBlock value
]

{ #category : #accessing }
True >> not [
	^ false
]

{ #category : #accessing }
True >> or: aBlock [
	^ true
]

{ #category : #accessing }
True >> printOn: aStream [
	aStream nextPutAll: 'true'
]

{ #category : #accessing }
True >> | aBoolean [
	^ true
]
