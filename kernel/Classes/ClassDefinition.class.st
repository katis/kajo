"What the image keeps of a class beyond the VM's class object (module 8e): its own instance variable names and class-side instance variable names (Symbols, in slot order), its package and its tag (tags as subdirectories: the package is the directory its file is in, the tag, a Symbol or nil, the subdirectory; nothing about placement lives in the file), its format kind (fixed, variable, bytes, words16, words32, words64, weak, ephemeron) and its comment. Smalltalk holds one per class; the compiler in Smalltalk reads the names, the Tonel writer all of it. The class variables are the class's pool."
Class {
	#name : #ClassDefinition,
	#superclass : #Object,
	#instVars : [
		'instVarNames',
		'classInstVarNames',
		'tag',
		'kind',
		'comment',
		'package'
	]
}

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

{ #category : #accessing }
ClassDefinition >> package [
	"The package the class belongs to (module 9b): a project directory's name, Kernel for kernel/; nil when none was given."
	^ package
]

{ #category : #accessing }
ClassDefinition >> package: aString [
	package := aString
]

{ #category : #accessing }
ClassDefinition >> tag [
	"The class's tag within its package, a Symbol, or nil when its file is at the package's root (tags as subdirectories)."
	^ tag
]

{ #category : #accessing }
ClassDefinition >> tag: aSymbolOrNil [
	tag := (aSymbolOrNil isNil or: [aSymbolOrNil isEmpty]) ifTrue: [nil] ifFalse: [aSymbolOrNil asSymbol]
]

{ #category : #initialization }
ClassDefinition >> setInstVarNames: ivars classInstVarNames: civars package: aPackage tag: aTag kind: aKind comment: aString [
	instVarNames := ivars.
	classInstVarNames := civars.
	package := aPackage.
	self tag: aTag.
	kind := aKind.
	comment := aString
]

{ #category : #'instance creation' }
ClassDefinition class >> instVarNames: ivars classInstVarNames: civars package: aPackage tag: aTag kind: aKind comment: aString [
	^ self new setInstVarNames: ivars classInstVarNames: civars package: aPackage tag: aTag kind: aKind comment: aString
]
