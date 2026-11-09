"The class of every class's metaclass's sole instance: Foo is a Class, Foo class a Metaclass."
Class {
	#name : #Class,
	#superclass : #ClassDescription,
	#category : #'Kernel-Classes'
}

{ #category : #accessing }
Class >> isClass [
	^ true
]

{ #category : #'class variables' }
Class >> addClassVarNamed: aString [
	(self classVarNames includes: aString asSymbol) ifTrue: [^ self].
	ClassBuilder redefine: self instanceVariableNames: self instVarNames classVariableNames: (self classVarNames copyWith: aString asSymbol)
		classInstanceVariableNames: self class instVarNames
]

{ #category : #'class variables' }
Class >> removeClassVarNamed: aString [
	(self classVarNames includes: aString asSymbol) ifFalse: [^ ClassDefinitionError new signal: self name , ' has no class variable ' , aString].
	ClassBuilder redefine: self instanceVariableNames: self instVarNames classVariableNames: (self classVarNames reject: [:n | n = aString asSymbol])
		classInstanceVariableNames: self class instVarNames
]

{ #category : #'file out' }
Class >> tonelSource [
	"This class's Tonel file in the canonical form (TonelWriter, module 8e)."
	^ TonelWriter sourceOf: self
]

{ #category : #'subclass creation' }
Class >> byteSubclass: aName instanceVariableNames: ivarString classVariableNames: cvarString package: aPackage [
	^ self subclass: aName instanceVariableNames: ivarString classVariableNames: cvarString package: aPackage tag: nil kind: #bytes
]

{ #category : #'subclass creation' }
Class >> byteSubclass: aName instanceVariableNames: ivarString classVariableNames: cvarString package: aPackage tag: aTag [
	^ self subclass: aName instanceVariableNames: ivarString classVariableNames: cvarString package: aPackage tag: aTag kind: #bytes
]

{ #category : #'subclass creation' }
Class >> subclass: aName [
	"A new class in the session's package or the default one, with no tag; an existing one keeps its package and tag."
	^ ClassBuilder define: aName superclass: self instanceVariableNames: #() classVariableNames: #()
		classInstanceVariableNames: nil package: nil tag: nil kind: nil comment: nil
]

{ #category : #'subclass creation' }
Class >> subclass: aName instanceVariableNames: ivarString classVariableNames: cvarString package: aPackage [
	"A new class (or the class of that name redefined, module 8e), its instances of the receiver's format kind, in aPackage at its root (no tag; tags as subdirectories)."
	^ self subclass: aName instanceVariableNames: ivarString classVariableNames: cvarString package: aPackage tag: nil kind: nil
]

{ #category : #'subclass creation' }
Class >> subclass: aName instanceVariableNames: ivarString classVariableNames: cvarString package: aPackage tag: aTag [
	"A new class (or the class of that name redefined), in aPackage under the tag aTag: its file is <package directory>/<aTag>/<aName>.class.st."
	^ self subclass: aName instanceVariableNames: ivarString classVariableNames: cvarString package: aPackage tag: aTag kind: nil
]

{ #category : #'subclass creation' }
Class >> subclass: aName instanceVariableNames: ivarString classVariableNames: cvarString package: aPackage tag: aTag kind: aKindOrNil [
	^ ClassBuilder define: aName superclass: self instanceVariableNames: ivarString substrings classVariableNames: cvarString substrings
		classInstanceVariableNames: nil package: aPackage tag: aTag kind: aKindOrNil comment: nil
]

{ #category : #'subclass creation' }
Class >> variableSubclass: aName instanceVariableNames: ivarString classVariableNames: cvarString package: aPackage [
	^ self subclass: aName instanceVariableNames: ivarString classVariableNames: cvarString package: aPackage tag: nil kind: #variable
]

{ #category : #'subclass creation' }
Class >> variableSubclass: aName instanceVariableNames: ivarString classVariableNames: cvarString package: aPackage tag: aTag [
	^ self subclass: aName instanceVariableNames: ivarString classVariableNames: cvarString package: aPackage tag: aTag kind: #variable
]

{ #category : #'subclass creation' }
Class >> weakSubclass: aName instanceVariableNames: ivarString classVariableNames: cvarString package: aPackage [
	^ self subclass: aName instanceVariableNames: ivarString classVariableNames: cvarString package: aPackage tag: nil kind: #weak
]

{ #category : #'subclass creation' }
Class >> weakSubclass: aName instanceVariableNames: ivarString classVariableNames: cvarString package: aPackage tag: aTag [
	^ self subclass: aName instanceVariableNames: ivarString classVariableNames: cvarString package: aPackage tag: aTag kind: #weak
]
