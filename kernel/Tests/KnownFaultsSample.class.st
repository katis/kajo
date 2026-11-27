"A class KnownFaultsTest compiles methods into (the known faults, docs/modules/known-faults.md, item 3). Its class side stands still right after the install primitive, where a method is installed and the pragma index may not have been told yet: there it runs onInstall once, which the test sets. Its instance side keeps a class in a temporary while it waits (item 5)."
Class {
	#name : #KnownFaultsSample,
	#superclass : #Object,
	#classInstVars : [
		'onInstall'
	]
}

{ #category : #forcing }
KnownFaultsSample >> hold: aClass until: aSemaphore [
	"Keep aClass in a temporary of this frame until aSemaphore is signalled."
	| held |
	held := aClass.
	aSemaphore wait.
	^ held
]

{ #category : #forcing }
KnownFaultsSample class >> onInstall: aBlockOrNil [
	onInstall := aBlockOrNil
]

{ #category : #forcing }
KnownFaultsSample class >> primAddSelector: aSymbol withMethod: aCompiledMethod [
	| r hook |
	r := super primAddSelector: aSymbol withMethod: aCompiledMethod.
	hook := onInstall.
	onInstall := nil.
	hook ifNotNil: [:b | b value: aSymbol].
	^ r
]
