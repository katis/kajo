"Things that compare: subclasses define < and =, the rest follows."
Class {
	#name : #Magnitude,
	#superclass : #Object,
	#category : #'Kernel-Numbers'
}

{ #category : #accessing }
Magnitude >> < aMagnitude [
	^ self subclassResponsibility
]

{ #category : #accessing }
Magnitude >> <= aMagnitude [
	^ (aMagnitude < self) not
]

{ #category : #accessing }
Magnitude >> > aMagnitude [
	^ aMagnitude < self
]

{ #category : #accessing }
Magnitude >> >= aMagnitude [
	^ (self < aMagnitude) not
]

{ #category : #accessing }
Magnitude >> between: min and: max [
	^ min <= self and: [self <= max]
]

{ #category : #accessing }
Magnitude >> max: aMagnitude [
	^ self > aMagnitude ifTrue: [self] ifFalse: [aMagnitude]
]

{ #category : #accessing }
Magnitude >> min: aMagnitude [
	^ self < aMagnitude ifTrue: [self] ifFalse: [aMagnitude]
]
