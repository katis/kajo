"Every side file's annotations, by class, and the lookups the checker makes in them: the signatures of a selector from a class up, the map from a receiver's type arguments to a defining class's parameters, the declared type of an instance variable. A side file is text, one annotation per line (see experiments/optional-types/annotations/README.md):
	class Name[P, Q]
	super Superclass[T]
	ivar name <T>
	cvar Name <T>
	method at: <Integer> put: <E> ^<E>
	meta new: <Integer> ^<Instance>
A line that does not read is an #annotation diagnostic, never a stop."
Class {
	#name : #OTAnnotations,
	#superclass : #Object,
	#instVars : [
		'infos',
		'errors',
		'lines'
	]
}

{ #category : #reading }
OTAnnotations >> addInfo: anInfo [
	infos at: anInfo cls put: anInfo
]

{ #category : #accessing }
OTAnnotations >> classes [
	^ infos keys
]

{ #category : #accessing }
OTAnnotations >> cvarTypeOf: aName in: aClass [
	| c |
	c := aClass theNonMetaClass.
	[c notNil] whileTrue: [
		(infos at: c ifAbsent: [nil]) ifNotNil: [:i | (i cvars at: aName ifAbsent: [nil]) ifNotNil: [:t | ^ t]].
		c := c superclass].
	^ nil
]

{ #category : #accessing }
OTAnnotations >> errors [
	^ errors
]

{ #category : #accessing }
OTAnnotations >> infoFor: aClass [
	^ infos at: aClass ifAbsent: [nil]
]

{ #category : #accessing }
OTAnnotations >> infos [
	^ infos
]

{ #category : #accessing }
OTAnnotations >> ivarCount [
	^ infos inject: 0 into: [:n :i | n + i ivars size + i cvars size]
]

{ #category : #accessing }
OTAnnotations >> ivarTypeOf: aName in: aClass [
	"The declared type of the instance variable aName seen from aClass, or nil."
	| c |
	c := aClass.
	[c notNil] whileTrue: [
		(infos at: c ifAbsent: [nil]) ifNotNil: [:i | (i ivars at: aName ifAbsent: [nil]) ifNotNil: [:t | ^ t]].
		c := c superclass].
	^ nil
]

{ #category : #accessing }
OTAnnotations >> lineCount [
	^ lines
]

{ #category : #lookup }
OTAnnotations >> map: aClassType to: aClass [
	"The defining class aClass's parameters, each to the type the receiver aClassType gives it through the superclass arguments between them."
	| map c ps sargs next |
	c := aClassType cls.
	ps := self paramsOf: c.
	map := Dictionary new.
	1 to: ps size do: [:i | map at: (ps at: i) put: (aClassType args size >= i ifTrue: [aClassType args at: i] ifFalse: [OTType dynamic])].
	[c notNil and: [c ~~ aClass]] whileTrue: [
		c superclass isNil ifTrue: [^ map].
		sargs := self superArgsOf: c.
		next := Dictionary new.
		ps := self paramsOf: c superclass.
		1 to: ps size do: [:i | next at: (ps at: i) put: ((sargs at: i) substitute: map self: nil instance: nil)].
		map := next.
		c := c superclass].
	^ map
]

{ #category : #accessing }
OTAnnotations >> paramsOf: aClass [
	"The type parameters of aClass: its side file's, else its superclass's (an unannotated subclass passes them through)."
	aClass isNil ifTrue: [^ #()].
	(infos at: aClass ifAbsent: [nil]) ifNotNil: [:i | ^ i params].
	^ self paramsOf: aClass superclass
]

{ #category : #reading }
OTAnnotations >> parsePatternOn: aParser meta: aBoolean in: anInfo line: n [
	| s selector args result |
	s := aParser scanner.
	selector := ''.
	args := OrderedCollection new.
	s kind == #identifier
		ifTrue: [selector := s value. s next]
		ifFalse: [
			(s kind == #binary or: [s kind == #bar])
				ifTrue: [
					selector := s kind == #bar ifTrue: ['|'] ifFalse: [s value].
					s next.
					args add: aParser parseTypeInAngles]
				ifFalse: [
					s kind == #keyword ifFalse: [^ aParser fail: 'expected a message pattern'].
					[s kind == #keyword] whileTrue: [
						selector := selector , s value.
						s next.
						args add: aParser parseTypeInAngles]]].
	result := OTType dynamic.
	s kind == #caret ifTrue: [s next. result := aParser parseTypeInAngles].
	s kind == #end ifFalse: [^ aParser fail: 'unexpected text after the signature'].
	^ OTSignature selector: selector asSymbol argTypes: args asArray result: result vars: aParser methodVars line: n meta: aBoolean owner: anInfo cls
]

{ #category : #reading }
OTAnnotations >> readLine: aString number: n file: aName into: anInfoHolder [
	"One line of a side file; anInfoHolder is a one-element Array holding the current class's info."
	| s word info p name |
	s := Scanner on: aString.
	s next.
	s kind == #end ifTrue: [^ self].
	s kind == #identifier ifFalse: [^ CompileError new line: n; signal: 'expected class, super, ivar, cvar, method or meta'].
	word := s value.
	s next.
	lines := lines + 1.
	word = 'class' ifTrue: [
		s kind == #identifier ifFalse: [^ CompileError new line: n; signal: 'expected a class name'].
		(Smalltalk classNamed: s value) ifNil: [^ CompileError new line: n; signal: 'no class named ' , s value] ifNotNil: [:c |
			info := (infos at: c ifAbsent: [nil]) ifNil: [OTClassInfo cls: c file: aName].
			infos at: c put: info.
			anInfoHolder at: 1 put: info].
		s next.
		s kind == #leftBracket ifTrue: [ | ps |
			ps := OrderedCollection new.
			s next.
			[s kind == #identifier] whileTrue: [
				ps add: s value.
				s next.
				(s kind == #binary and: [s value = ',']) ifTrue: [s next]].
			s kind == #rightBracket ifFalse: [^ CompileError new line: n; signal: 'expected ] after the parameters'].
			s next.
			info params: ps asArray].
		^ self].
	info := anInfoHolder at: 1.
	info isNil ifTrue: [^ CompileError new line: n; signal: 'a class line comes first'].
	p := OTTypeParser on: s params: info params.
	word = 'super' ifTrue: [ | t |
		t := p parseType.
		(t isClassType and: [t cls == info cls superclass]) ifFalse: [^ CompileError new line: n; signal: 'super names the superclass with its arguments'].
		^ info superArgs: t args].
	(word = 'ivar' or: [word = 'cvar']) ifTrue: [
		s kind == #identifier ifFalse: [^ CompileError new line: n; signal: 'expected a variable name'].
		name := s value.
		s next.
		word = 'ivar'
			ifTrue: [
				(((Smalltalk instanceVariableNamesOf: info cls) collect: [:x | x asString]) includes: name) ifFalse: [^ CompileError new line: n; signal: info cls name , ' has no instance variable ' , name].
				info ivars at: name put: p parseTypeInAngles]
			ifFalse: [info cvars at: name put: p parseTypeInAngles].
		^ self].
	(word = 'method' or: [word = 'meta']) ifTrue: [
		^ info addSignature: (self parsePatternOn: p meta: word = 'meta' in: info line: n)].
	^ CompileError new line: n; signal: 'unknown annotation ' , word
]

{ #category : #reading }
OTAnnotations >> readString: aString file: aName [
	"Every annotation of one side file; a line that does not read is noted and skipped."
	| holder n |
	holder := Array new: 1.
	n := 0.
	aString lines do: [:l |
		n := n + 1.
		(l trimmed isEmpty or: [l trimmed first = $#]) ifFalse: [
			[self readLine: l number: n file: aName into: holder]
				on: CompileError
				do: [:e | errors add: (OTDiagnostic kind: #annotation where: aName line: n text: e messageText)]]]
]

{ #category : #accessing }
OTAnnotations >> setUp [
	infos := IdentityDictionary new.
	errors := OrderedCollection new.
	lines := 0
]

{ #category : #lookup }
OTAnnotations >> signatureCount [
	^ infos inject: 0 into: [:n :i | n + i signatureCount]
]

{ #category : #lookup }
OTAnnotations >> signaturesFor: aSelector meta: aBoolean from: aClass [
	"{defining class. its signatures} for aSelector from aClass up, or nil."
	| c |
	c := aClass.
	[c notNil] whileTrue: [
		(infos at: c ifAbsent: [nil]) ifNotNil: [:i |
			((aBoolean ifTrue: [i metaMethods] ifFalse: [i methods]) at: aSelector ifAbsent: [nil]) ifNotNil: [:l | ^ {c. l}]].
		c := c superclass].
	^ nil
]

{ #category : #lookup }
OTAnnotations >> superArgsOf: aClass [
	"The types aClass gives its superclass's parameters, over aClass's own parameters."
	| own ps |
	(infos at: aClass ifAbsent: [nil]) ifNotNil: [:i | i superArgs ifNotNil: [:a | ^ a]].
	own := self paramsOf: aClass.
	ps := self paramsOf: aClass superclass.
	^ ps collect: [:p | (own includes: p) ifTrue: [OTVar named: p] ifFalse: [OTType dynamic]]
]

{ #category : #'instance creation' }
OTAnnotations class >> new [
	^ self basicNew setUp
]

{ #category : #'instance creation' }
OTAnnotations class >> fromString: aString [
	^ self new readString: aString file: 'string'; yourself
]
