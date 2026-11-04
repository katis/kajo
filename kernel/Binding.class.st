"A class variable (module 8d): its name (a Symbol) and its value. A class's pool, in its metaclass, holds one Binding per class variable it declares; every method that names the variable holds the Binding itself in its literal frame and reads it with value and writes it with value: (no bytecode of its own). The literal frame is read-only, the Binding is not."
Class {
	#name : #Binding,
	#superclass : #Object,
	#instVars : [
		'key',
		'value'
	],
	#category : #'Kernel-Classes'
}

{ #category : #accessing }
Binding >> key [
	^ key
]

{ #category : #accessing }
Binding >> value [
	^ value
]

{ #category : #accessing }
Binding >> value: anObject [
	"Answers anObject: a compiled assignment's value."
	value := anObject.
	^ anObject
]

{ #category : #printing }
Binding >> printOn: aStream [
	aStream nextPutAll: key; nextPutAll: ' -> '; print: value
]
