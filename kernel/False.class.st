Class {
	#name : #False,
	#superclass : #Boolean,
	#category : #'Kernel-Objects'
}

{ #category : #accessing }
False >> ifTrue: aBlock [
	^ nil
]

{ #category : #accessing }
False >> ifFalse: aBlock [
	^ aBlock value
]

{ #category : #accessing }
False >> ifTrue: trueBlock ifFalse: falseBlock [
	^ falseBlock value
]

{ #category : #accessing }
False >> and: aBlock [
	^ false
]

{ #category : #accessing }
False >> or: aBlock [
	^ aBlock value
]

{ #category : #accessing }
False >> & aBoolean [
	^ false
]

{ #category : #accessing }
False >> | aBoolean [
	^ aBoolean
]

{ #category : #accessing }
False >> not [
	^ true
]

{ #category : #accessing }
False >> printOn: aStream [
	aStream nextPutAll: 'false'
]
