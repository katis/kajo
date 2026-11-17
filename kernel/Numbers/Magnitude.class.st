"Things that compare: subclasses define < and =, the rest follows."
Class {
	#name : #Magnitude,
	#superclass : #Object
}

{ #category : #accessing }
Magnitude >> < aMagnitude <Magnitude> ^<Boolean> [
	^ self subclassResponsibility
]

{ #category : #accessing }
Magnitude >> <= aMagnitude <Magnitude> ^<Boolean> [
	^ (aMagnitude < self) not
]

{ #category : #accessing }
Magnitude >> > aMagnitude <Magnitude> ^<Boolean> [
	^ aMagnitude < self
]

{ #category : #accessing }
Magnitude >> >= aMagnitude <Magnitude> ^<Boolean> [
	^ (self < aMagnitude) not
]

{ #category : #accessing }
Magnitude >> between: min <Magnitude> and: max <Magnitude> ^<Boolean> [
	^ min <= self and: [self <= max]
]

{ #category : #accessing }
Magnitude >> max: aMagnitude <Self; Magnitude> ^<Self; Magnitude> [
	^ self > aMagnitude ifTrue: [self] ifFalse: [aMagnitude]
]

{ #category : #accessing }
Magnitude >> min: aMagnitude <Self; Magnitude> ^<Self; Magnitude> [
	^ self < aMagnitude ifTrue: [self] ifFalse: [aMagnitude]
]
