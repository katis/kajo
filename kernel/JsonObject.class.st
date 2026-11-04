"A JSON object of the development protocol (module 9b): String keys in the order they were put, each with its value. Json reads objects as these and writes them in their order, so a reply's members come out as the request handler put them."
Class {
	#name : #JsonObject,
	#superclass : #Object,
	#instVars : [
		'keys',
		'values'
	],
	#category : #'Kernel-Development'
}

{ #category : #accessing }
JsonObject >> at: aKey [
	^ self at: aKey ifAbsent: [nil]
]

{ #category : #accessing }
JsonObject >> at: aKey ifAbsent: aBlock [
	| i |
	i := keys indexOf: aKey asString.
	i = 0 ifTrue: [^ aBlock value].
	^ values at: i
]

{ #category : #accessing }
JsonObject >> at: aKey put: aValue [
	| k i |
	k := aKey asString.
	i := keys indexOf: k.
	i = 0
		ifTrue: [keys add: k. values add: aValue]
		ifFalse: [values at: i put: aValue].
	^ aValue
]

{ #category : #accessing }
JsonObject >> includesKey: aKey [
	^ (keys indexOf: aKey asString) > 0
]

{ #category : #accessing }
JsonObject >> keys [
	^ keys asArray
]

{ #category : #accessing }
JsonObject >> keysAndValuesDo: aBlock [
	1 to: keys size do: [:i | aBlock value: (keys at: i) value: (values at: i)]
]

{ #category : #accessing }
JsonObject >> printOn: aStream [
	aStream nextPutAll: (Json write: self)
]

{ #category : #accessing }
JsonObject >> size [
	^ keys size
]

{ #category : #initialization }
JsonObject >> initialize [
	keys := OrderedCollection new.
	values := OrderedCollection new
]

{ #category : #'instance creation' }
JsonObject class >> new [
	^ self basicNew initialize
]
