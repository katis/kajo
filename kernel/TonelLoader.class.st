"Loads one Tonel file into the running image (module 8e; Smalltalk readTonel:): defines the class or redefines the existing one through ClassBuilder, with the file's methods as the class's whole method set on both sides, made in the same primitive call that changes the shape, so a file that renames an instance variable and the methods that use it loads in one step. An Extension's methods are compiled into their class one by one."
Class {
	#name : #TonelLoader,
	#superclass : #Object,
	#category : #'Kernel-System'
}

{ #category : #loading }
TonelLoader class >> load: aDocument [
	| cls sup existing methods |
	aDocument isExtension ifTrue: [^ self loadExtension: aDocument].
	sup := aDocument superclassName ifNotNil: [:n | Smalltalk at: n asSymbol ifAbsent: [^ ClassDefinitionError new signal: aDocument name , ': no superclass ' , n]].
	existing := Smalltalk at: aDocument name asSymbol ifAbsent: [nil].
	cls := ClassBuilder define: aDocument name superclass: sup
		instanceVariableNames: (existing ifNil: [aDocument instVarNames] ifNotNil: [:c | c instVarNames])
		classVariableNames: (existing ifNil: [aDocument classVarNames] ifNotNil: [:c | c classVarNames])
		classInstanceVariableNames: (existing ifNil: [aDocument classInstVarNames] ifNotNil: [:c | c class instVarNames])
		category: aDocument category kind: aDocument kind comment: aDocument comment.
	methods := IdentityDictionary new.
	methods at: cls put: OrderedCollection new; at: cls class put: OrderedCollection new.
	aDocument methods do: [:m |
		(methods at: ((m at: 1) ifTrue: [cls class] ifFalse: [cls])) add: (Array with: (m at: 3) with: ((m at: 2) isEmpty ifTrue: [nil] ifFalse: [(m at: 2) asSymbol]))].
	ClassBuilder redefine: cls instanceVariableNames: aDocument instVarNames classVariableNames: aDocument classVarNames
		classInstanceVariableNames: aDocument classInstVarNames methods: methods.
	aDocument methods do: [:m |
		(m size >= 4 and: [(m at: 4) notNil]) ifTrue: [
			Smalltalk noteAuthor: (m at: 4) of: (Parser parse: (m at: 3)) selector in: ((m at: 1) ifTrue: [cls class] ifFalse: [cls])]].
	^ cls
]

{ #category : #loading }
TonelLoader class >> loadExtension: aDocument [
	| cls |
	cls := Smalltalk at: aDocument name asSymbol ifAbsent: [^ ClassDefinitionError new signal: 'an extension of unknown class ' , aDocument name].
	aDocument methods do: [:m | | b sel |
		b := (m at: 1) ifTrue: [cls class] ifFalse: [cls].
		sel := b compile: (m at: 3) classified: ((m at: 2) isEmpty ifTrue: [nil] ifFalse: [m at: 2]).
		(m size >= 4 and: [(m at: 4) notNil]) ifTrue: [Smalltalk noteAuthor: (m at: 4) of: sel in: b]].
	^ cls
]
