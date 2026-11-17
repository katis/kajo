"What the checker knows of one class's types, read from the image (Types 2; the experiment's OTClassInfo, which read a side file): its type parameters (#typeParameters, or its superclass's when the class carries no type at all), what it gives its superclass's (#superclassType, or the parameters of the same names), its instance variables' types, and for each side each selector's signatures: a typed method's pattern or a signature without a method, an overload being several. carriesTypes says whether the class writes any type at all (a typed method, a signature, a class-level type): an untyped method of a class that carries types keeps the signature above it, one of a class that carries none does not (the lookup's rule, TypeTable>>signaturesFor:from:). problems holds, per method or signature key, what did not read (#annotation diagnostics of the method)."
Class {
	#name : #TypedClass,
	#superclass : #Object,
	#instVars : [
		'cls',
		'params',
		'superArgs',
		'ivars',
		'methods',
		'metaMethods',
		'carriesTypes',
		'problems'
	]
}

{ #category : #accessing }
TypedClass >> addProblem: aString for: aKey [
	(problems at: aKey ifAbsentPut: [OrderedCollection new]) add: aString
]

{ #category : #accessing }
TypedClass >> addSignature: aSignature [
	((aSignature isMeta ifTrue: [metaMethods] ifFalse: [methods]) at: aSignature selector ifAbsentPut: [OrderedCollection new]) add: aSignature
]

{ #category : #accessing }
TypedClass >> carriesTypes [
	^ carriesTypes
]

{ #category : #accessing }
TypedClass >> carriesTypes: aBoolean [
	carriesTypes := aBoolean
]

{ #category : #accessing }
TypedClass >> cls [
	^ cls
]

{ #category : #accessing }
TypedClass >> ivars [
	^ ivars
]

{ #category : #accessing }
TypedClass >> metaMethods [
	^ metaMethods
]

{ #category : #accessing }
TypedClass >> methods [
	^ methods
]

{ #category : #accessing }
TypedClass >> params [
	^ params
]

{ #category : #accessing }
TypedClass >> params: anArray [
	params := anArray
]

{ #category : #accessing }
TypedClass >> problems [
	^ problems
]

{ #category : #accessing }
TypedClass >> problemsOf: aKey [
	^ problems at: aKey ifAbsent: [#()]
]

{ #category : #accessing }
TypedClass >> setCls: aClass [
	cls := aClass.
	params := #().
	superArgs := nil.
	ivars := Dictionary new.
	methods := IdentityDictionary new.
	metaMethods := IdentityDictionary new.
	carriesTypes := false.
	problems := Dictionary new
]

{ #category : #accessing }
TypedClass >> signatureCount [
	| n |
	n := 0.
	methods do: [:l | n := n + l size].
	metaMethods do: [:l | n := n + l size].
	^ n
]

{ #category : #accessing }
TypedClass >> signaturesAt: aSelector meta: aBoolean [
	"The signatures of aSelector on that side, or nil."
	^ (aBoolean ifTrue: [metaMethods] ifFalse: [methods]) at: aSelector ifAbsent: [nil]
]

{ #category : #accessing }
TypedClass >> superArgs [
	^ superArgs
]

{ #category : #accessing }
TypedClass >> superArgs: anArray [
	superArgs := anArray
]

{ #category : #'instance creation' }
TypedClass class >> cls: aClass [
	^ self new setCls: aClass
]
