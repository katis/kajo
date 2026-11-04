"A method made, installed or removed, or a doit evaluated, in a release image (module 8d): the image was built or sealed so that Smalltalk cannot change its methods. Names the class and the selector."
Class {
	#name : #InstallForbidden,
	#superclass : #Error,
	#instVars : [
		'behavior',
		'selector'
	],
	#category : #'Kernel-Exceptions'
}

{ #category : #accessing }
InstallForbidden >> behavior [
	^ behavior
]

{ #category : #accessing }
InstallForbidden >> behavior: aBehavior selector: aSymbol [
	behavior := aBehavior.
	selector := aSymbol
]

{ #category : #accessing }
InstallForbidden >> messageText [
	^ 'a release image: cannot change ' , behavior printString , '>>' , (selector ifNil: ['(doit)'] ifNotNil: [:s | s])
]

{ #category : #accessing }
InstallForbidden >> selector [
	^ selector
]
