"A class variable (module 8d): its name (a Symbol) and its value. A class's pool, in its metaclass, holds one Binding per class variable it declares; every method that names the variable holds the Binding itself in its literal frame and reads it with value and writes it with value: (no bytecode of its own). The literal frame is read-only, the Binding is not. A class variable removed from its class leaves its Binding undeclared (module 8e): the methods that hold it still read it, as nil, and a write signals an error naming it; adding the variable again declares the same Binding, so those methods work again without a recompile."
Class {
	#name : #Binding,
	#superclass : #Object,
	#instVars : [
		'key',
		'value',
		'undeclared'
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
	"Answers anObject: a compiled assignment's value. An undeclared Binding refuses the write."
	undeclared == true ifTrue: [^ self error: 'the class variable ' , key , ' was removed from its class (undeclared)'].
	value := anObject.
	^ anObject
]

{ #category : #accessing }
Binding >> key: aSymbol [
	key := aSymbol
]

{ #category : #undeclared }
Binding >> isUndeclared [
	^ undeclared == true
]

{ #category : #undeclared }
Binding >> beUndeclared [
	"Its variable was removed from its class: a read answers nil, a write is an error."
	value := nil.
	undeclared := true
]

{ #category : #undeclared }
Binding >> beDeclared [
	undeclared := nil
]

{ #category : #printing }
Binding >> printOn: aStream [
	aStream nextPutAll: key; nextPutAll: ' -> '; print: value
]
