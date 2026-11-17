"A probe of signatures without a method (Types 2)."
Class {
	#name : #SigProbe,
	#superclass : #Object,
	#instVars : [
		'items'
	]
}

{ #category : #accessing }
SigProbe >> at: index <Integer> ^<Integer>

{ #category : #accessing }
SigProbe >> b [
	^ 1
]

{ #category : #accessing }
SigProbe >> c: x <Integer; Float> ^<Integer; Float>

{ #category : #enumerating }
SigProbe >> collect: aBlock <[Integer, ^:X]> ^<Array[X]>

{ #category : #'instance creation' }
SigProbe class >> make: n <Integer> ^<Instance>

{ #category : #'instance creation' }
SigProbe class >> new [
	^ super new
]

