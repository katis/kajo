"A class's types as written in its definition (Types 1, docs/modules/types-1.md): its type parameters (Strings, #typeParameters), what it gives its superclass's (a type's text, #superclassType, or nil) and its instance variables' types (instance variable name, a Symbol, to the type's text, written after the name in #instVars); and since Types 2 (docs/modules/types-2.md) its signatures without a method, by side and selector, each {the pattern's text. its category, a Symbol. its package, or nil for the class's}. Text only: nothing checks it and the VM never sees it. Smalltalk keeps one per class that has any, in a table of its own that a release image's build does not fill (question 3); the Tonel writer writes it back."
Class {
	#name : #ClassTypes,
	#superclass : #Object,
	#instVars : [
		'typeParameters',
		'superclassType',
		'instVarTypes',
		'signatures',
		'classSignatures'
	]
}

{ #category : #accessing }
ClassTypes >> instVarTypes [
	^ instVarTypes ifNil: [instVarTypes := IdentityDictionary new]
]

{ #category : #accessing }
ClassTypes >> isEmpty [
	^ self typeParameters isEmpty and: [superclassType isNil and: [self instVarTypes isEmpty and: [self hasSignatures not]]]
]

{ #category : #accessing }
ClassTypes >> keepOnly: names [
	"Forget the types of instance variables not among names (a redefinition removed them)."
	(self instVarTypes keys reject: [:n | names includes: n]) do: [:n | instVarTypes removeKey: n]
]

{ #category : #accessing }
ClassTypes >> superclassType [
	^ superclassType
]

{ #category : #accessing }
ClassTypes >> superclassType: aStringOrNil [
	superclassType := aStringOrNil
]

{ #category : #accessing }
ClassTypes >> type: aString of: aName [
	self instVarTypes at: aName asSymbol put: aString
]

{ #category : #accessing }
ClassTypes >> typeOf: aName [
	"The type's text of the instance variable aName, or nil."
	^ self instVarTypes at: aName asSymbol ifAbsent: [nil]
]

{ #category : #accessing }
ClassTypes >> typeParameters [
	^ typeParameters ifNil: [#()]
]

{ #category : #accessing }
ClassTypes >> typeParameters: anArray [
	typeParameters := anArray
]

{ #category : #signatures }
ClassTypes >> hasSignatures [
	^ (signatures notNil and: [signatures notEmpty]) or: [classSignatures notNil and: [classSignatures notEmpty]]
]

{ #category : #signatures }
ClassTypes >> keepSignaturesOf: aClassTypes except: aPackage [
	"Take the signatures of aClassTypes (another one's, the class's before a file was loaded) whose package is neither nil nor aPackage: an extension package's, which a class file does not hold."
	aClassTypes isNil ifTrue: [^ self].
	#(false true) do: [:meta |
		(aClassTypes signatureSelectorsMeta: meta) do: [:sel | | e |
			e := aClassTypes signatureAt: sel meta: meta.
			((e at: 3) notNil and: [(e at: 3) ~= aPackage]) ifTrue: [
				self signature: e first category: (e at: 2) package: (e at: 3) at: sel meta: meta]]]
]

{ #category : #signatures }
ClassTypes >> removeSignatureAt: aSelector meta: aBoolean [
	"Forget the signature of aSelector on that side; answers its entry or nil."
	| d |
	d := aBoolean ifTrue: [classSignatures] ifFalse: [signatures].
	d isNil ifTrue: [^ nil].
	^ d removeKey: aSelector asSymbol ifAbsent: [nil]
]

{ #category : #signatures }
ClassTypes >> signature: aString category: aCategory package: aPackageOrNil at: aSelector meta: aBoolean [
	"Keep a signature without a method: the pattern's text, its category and its package (nil: the class's)."
	| d |
	aBoolean
		ifTrue: [classSignatures isNil ifTrue: [classSignatures := IdentityDictionary new]. d := classSignatures]
		ifFalse: [signatures isNil ifTrue: [signatures := IdentityDictionary new]. d := signatures].
	d at: aSelector asSymbol put: (Array
		with: aString
		with: ((aCategory isNil or: [aCategory isEmpty]) ifTrue: [Behavior defaultCategory] ifFalse: [aCategory asSymbol])
		with: ((aPackageOrNil isNil or: [aPackageOrNil isEmpty]) ifTrue: [nil] ifFalse: [aPackageOrNil asString]))
]

{ #category : #signatures }
ClassTypes >> signatureAt: aSelector meta: aBoolean [
	"{text. category. package} of the signature of aSelector on that side, or nil."
	| d |
	d := aBoolean ifTrue: [classSignatures] ifFalse: [signatures].
	d isNil ifTrue: [^ nil].
	^ d at: aSelector asSymbol ifAbsent: [nil]
]

{ #category : #signatures }
ClassTypes >> signatureSelectorsMeta: aBoolean [
	"The selectors with a signature on that side, an Array."
	| d |
	d := aBoolean ifTrue: [classSignatures] ifFalse: [signatures].
	^ d isNil ifTrue: [#()] ifFalse: [d keys asArray]
]
