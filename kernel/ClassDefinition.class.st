"What the image keeps of a class beyond the VM's class object (module 8e): its own instance variable names and class-side instance variable names (Symbols, in slot order), its category, its format kind (fixed, variable, bytes, words16, words32, words64, weak, ephemeron) and its comment. Smalltalk holds one per class; the compiler in Smalltalk reads the names, the Tonel writer all of it. The class variables are the class's pool."
Class {
	#name : #ClassDefinition,
	#superclass : #Object,
	#instVars : [
		'instVarNames',
		'classInstVarNames',
		'category',
		'kind',
		'comment'
	],
	#category : #'Kernel-Classes'
}

{ #category : #accessing }
ClassDefinition >> category [
	^ category
]

{ #category : #accessing }
ClassDefinition >> category: aSymbol [
	category := aSymbol
]

{ #category : #accessing }
ClassDefinition >> classInstVarNames [
	^ classInstVarNames
]

{ #category : #accessing }
ClassDefinition >> classInstVarNames: anArray [
	classInstVarNames := anArray
]

{ #category : #accessing }
ClassDefinition >> comment [
	^ comment
]

{ #category : #accessing }
ClassDefinition >> comment: aString [
	comment := aString
]

{ #category : #accessing }
ClassDefinition >> instVarNames [
	^ instVarNames
]

{ #category : #accessing }
ClassDefinition >> instVarNames: anArray [
	instVarNames := anArray
]

{ #category : #accessing }
ClassDefinition >> kind [
	^ kind
]

{ #category : #initialization }
ClassDefinition >> setInstVarNames: ivars classInstVarNames: civars category: aCategory kind: aKind comment: aString [
	instVarNames := ivars.
	classInstVarNames := civars.
	category := aCategory.
	kind := aKind.
	comment := aString
]

{ #category : #'instance creation' }
ClassDefinition class >> instVarNames: ivars classInstVarNames: civars category: aCategory kind: aKind comment: aString [
	^ self new setInstVarNames: ivars classInstVarNames: civars category: aCategory kind: aKind comment: aString
]
