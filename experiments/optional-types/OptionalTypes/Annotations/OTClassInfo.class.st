"What one side file says about a class: its type parameters, the arguments it gives its superclass's parameters (nil: the same names pass through), the types of its instance and class variables, and its instance-side and class-side signatures (each selector to its signatures; more than one is an overload)."
Class {
	#name : #OTClassInfo,
	#superclass : #Object,
	#instVars : [
		'cls',
		'params',
		'superArgs',
		'ivars',
		'cvars',
		'methods',
		'metaMethods',
		'file'
	]
}

{ #category : #accessing }
OTClassInfo >> addSignature: aSignature [
	((aSignature isMeta ifTrue: [metaMethods] ifFalse: [methods]) at: aSignature selector ifAbsentPut: [OrderedCollection new]) add: aSignature
]

{ #category : #accessing }
OTClassInfo >> cls [
	^ cls
]

{ #category : #accessing }
OTClassInfo >> cvars [
	^ cvars
]

{ #category : #accessing }
OTClassInfo >> file [
	^ file
]

{ #category : #accessing }
OTClassInfo >> ivars [
	^ ivars
]

{ #category : #accessing }
OTClassInfo >> metaMethods [
	^ metaMethods
]

{ #category : #accessing }
OTClassInfo >> methods [
	^ methods
]

{ #category : #accessing }
OTClassInfo >> params [
	^ params
]

{ #category : #accessing }
OTClassInfo >> params: anArray [
	params := anArray
]

{ #category : #accessing }
OTClassInfo >> setCls: aClass file: aString [
	cls := aClass.
	file := aString.
	params := #().
	superArgs := nil.
	ivars := Dictionary new.
	cvars := Dictionary new.
	methods := IdentityDictionary new.
	metaMethods := IdentityDictionary new
]

{ #category : #accessing }
OTClassInfo >> signatureCount [
	| n |
	n := 0.
	methods do: [:l | n := n + l size].
	metaMethods do: [:l | n := n + l size].
	^ n
]

{ #category : #accessing }
OTClassInfo >> superArgs [
	^ superArgs
]

{ #category : #accessing }
OTClassInfo >> superArgs: anArray [
	superArgs := anArray
]

{ #category : #'instance creation' }
OTClassInfo class >> cls: aClass file: aString [
	^ self new setCls: aClass file: aString
]
