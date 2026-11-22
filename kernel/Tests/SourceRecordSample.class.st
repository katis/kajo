"A class SourceRecordTest compiles methods into and redefines at run time (the tools test's fault, docs/modules/tools-test-fault.md). Its class side stands still where a change has made a method visible: right after an install (addSelector:withMethod:) and, in a redefinition, at the first isMeta sent to it after the methods were made again while one of them has no source yet; there it runs onChange, which the test sets."
Class {
	#name : #SourceRecordSample,
	#superclass : #Object,
	#classInstVars : [
		'onChange',
		'inHook'
	]
}

{ #category : #forcing }
SourceRecordSample class >> addSelector: aSymbol withMethod: aCompiledMethod [
	super addSelector: aSymbol withMethod: aCompiledMethod.
	self changed: aSymbol
]

{ #category : #forcing }
SourceRecordSample class >> changed: aSymbol [
	"Run onChange once per change, never from inside itself."
	| hook |
	(onChange isNil or: [inHook == true]) ifTrue: [^ self].
	hook := onChange.
	inHook := true.
	[hook value: aSymbol] ensure: [inHook := false]
]

{ #category : #forcing }
SourceRecordSample class >> isMeta [
	"A redefinition sends this to the class whose shape it changed, after its primitive made the methods again and before their sources are recorded anew (ClassBuilder class>>redefine:...): the hook runs when #recordedValue is there with no source."
	(onChange notNil and: [inHook ~~ true and: [(self includesSelector: #recordedValue) and: [(Smalltalk sourceOf: (self compiledMethodAt: #recordedValue)) isNil]]])
		ifTrue: [self changed: #recordedValue].
	^ super isMeta
]

{ #category : #forcing }
SourceRecordSample class >> onChange: aBlockOrNil [
	onChange := aBlockOrNil.
	inHook := false
]
