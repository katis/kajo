"A store into a read-only object (ADR 0009 section 9). Resumable: the resumption value answers for the refused store."
Class {
	#name : #ModificationForbidden,
	#superclass : #Error,
	#instVars : [
		'object',
		'index',
		'value'
	],
	#category : #'Kernel-Exceptions'
}

{ #category : #accessing }
ModificationForbidden >> index [
	^ index
]

{ #category : #accessing }
ModificationForbidden >> isResumable [
	^ true
]

{ #category : #accessing }
ModificationForbidden >> messageText [
	^ 'cannot store into the read-only ' , object printString
]

{ #category : #accessing }
ModificationForbidden >> object [
	^ object
]

{ #category : #accessing }
ModificationForbidden >> object: anObject index: anIndex value: aValue [
	object := anObject.
	index := anIndex.
	value := aValue
]

{ #category : #accessing }
ModificationForbidden >> value [
	^ value
]
