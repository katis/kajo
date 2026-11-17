"Reads a type from the kernel's Scanner, in the Strongtalk-like notation of the side files: `Integer`, `Array[E]`, `Dictionary[K, V]`, `String class`, `Integer | Nil`, `[E, ^Boolean]`, `[^X]`, `Self`, `Instance`, `Dynamic`, `Nil`, `(T)`. A name of one or two characters that is not a class is a type variable (the class's parameter when it names one, else a variable of the method); any other name must be a class. Errors are CompileErrors with the reason."
Class {
	#name : #OTTypeParser,
	#superclass : #Object,
	#instVars : [
		'scanner',
		'params',
		'methodVars'
	]
}

{ #category : #parsing }
OTTypeParser >> advance [
	scanner next
]

{ #category : #parsing }
OTTypeParser >> fail: aString [
	^ CompileError new line: 0; signal: aString
]

{ #category : #parsing }
OTTypeParser >> isBinary: aString [
	^ scanner kind == #binary and: [scanner value = aString]
]

{ #category : #accessing }
OTTypeParser >> methodVars [
	"The variables of the method the parsed types named (names, a Set)."
	^ methodVars
]

{ #category : #parsing }
OTTypeParser >> parseAlternative [
	| name t |
	scanner kind == #leftParen ifTrue: [
		self advance.
		t := self parseType.
		scanner kind == #rightParen ifFalse: [^ self fail: 'expected )'].
		self advance.
		^ t].
	scanner kind == #leftBracket ifTrue: [^ self parseBlockType].
	scanner kind == #identifier ifFalse: [^ self fail: 'expected a type'].
	name := scanner value.
	self advance.
	name = 'Dynamic' ifTrue: [^ OTType dynamic].
	name = 'Self' ifTrue: [(scanner kind == #identifier and: [scanner value = 'class']) ifTrue: [self advance. ^ OTSelfClass new]. ^ OTSelf new].
	name = 'Instance' ifTrue: [^ scanner kind == #leftBracket ifTrue: [OTInstance new args: self parseArguments; yourself] ifFalse: [OTInstance new]].
	name = 'Nil' ifTrue: [^ OTType nilType].
	(params includes: name) ifTrue: [^ OTVar named: name].
	(Smalltalk classNamed: name) ifNotNil: [:c |
		(scanner kind == #identifier and: [scanner value = 'class']) ifTrue: [self advance. ^ OTMetaType cls: c].
		scanner kind == #leftBracket ifTrue: [^ OTClassType cls: c args: self parseArguments].
		^ OTClassType cls: c args: #()].
	name byteSize <= 2 ifTrue: [
		methodVars add: name.
		(scanner kind == #identifier and: [scanner value = 'class']) ifTrue: [self advance. ^ OTVarClass named: name].
		^ OTVar named: name].
	^ self fail: 'no class named ' , name
]

{ #category : #parsing }
OTTypeParser >> parseArguments [
	"[T, U] after a generic class's name."
	| out |
	self advance.
	out := OrderedCollection new.
	[out add: self parseType.
	 self isBinary: ','] whileTrue: [self advance].
	scanner kind == #rightBracket ifFalse: [^ self fail: 'expected ] after the type arguments'].
	self advance.
	^ out asArray
]

{ #category : #parsing }
OTTypeParser >> parseBlockType [
	"[A, B, ^R], [^R], [A] (result dynamic), []."
	| args result |
	self advance.
	args := OrderedCollection new.
	result := OTType dynamic.
	[scanner kind == #rightBracket] whileFalse: [
		scanner kind == #caret
			ifTrue: [self advance. result := self parseType]
			ifFalse: [args add: self parseType].
		(self isBinary: ',') ifTrue: [self advance] ifFalse: [
			scanner kind == #rightBracket ifFalse: [^ self fail: 'expected , or ] in a block type']]].
	self advance.
	^ OTBlockType args: args asArray result: result
]

{ #category : #parsing }
OTTypeParser >> parseType [
	| alts |
	alts := OrderedCollection with: self parseAlternative.
	[scanner kind == #bar] whileTrue: [
		self advance.
		alts add: self parseAlternative].
	^ alts size = 1 ifTrue: [alts first] ifFalse: [OTType union: alts]
]

{ #category : #parsing }
OTTypeParser >> parseTypeInAngles [
	"<T>; the scanner is on the <."
	| t |
	(self isBinary: '<') ifFalse: [^ self fail: 'expected <'].
	self advance.
	t := self parseType.
	(self isBinary: '>') ifFalse: [^ self fail: 'expected > after a type'].
	self advance.
	^ t
]

{ #category : #accessing }
OTTypeParser >> scanner [
	^ scanner
]

{ #category : #accessing }
OTTypeParser >> setScanner: aScanner params: anArray [
	scanner := aScanner.
	params := anArray.
	methodVars := Set new
]

{ #category : #'instance creation' }
OTTypeParser class >> on: aScanner params: anArray [
	^ self new setScanner: aScanner params: anArray
]

{ #category : #parsing }
OTTypeParser class >> parse: aString [
	^ self parse: aString params: #()
]

{ #category : #parsing }
OTTypeParser class >> parse: aString params: anArray [
	| p t |
	p := self on: (Scanner on: aString) params: anArray.
	p scanner next.
	t := p parseType.
	p scanner kind == #end ifFalse: [^ p fail: 'unexpected text after the type'].
	^ t
]
