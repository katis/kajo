"Question 6: the argument classes seen at run time. A traced method is recompiled with one statement before its own (OTTrace note:args:), which records the class of each argument; the guard keeps the recorder from tracing itself. Only for an image that is thrown away afterwards."
Class {
	#name : #OTTrace,
	#superclass : #Object,
	#classVars : [
		'Busy',
		'Seen'
	]
}

{ #category : #recording }
OTTrace class >> note: aKey args: anArray [
	| d |
	Busy == true ifTrue: [^ self].
	Busy := true.
	[Seen isNil ifTrue: [Seen := Dictionary new].
	 d := Seen at: aKey ifAbsentPut: [Array new: anArray size].
	 1 to: anArray size do: [:i |
		(d at: i) isNil ifTrue: [d at: i put: IdentitySet new].
		(d at: i) add: (anArray at: i) class]] ensure: [Busy := false]
]

{ #category : #recording }
OTTrace class >> seen [
	^ Seen ifNil: [Dictionary new]
]

{ #category : #recording }
OTTrace class >> statementsStartIn: aString [
	"The byte offset (from 0) of the first statement: after the pattern, the pragmas and the temporaries, read with the kernel's Scanner."
	| end sc |
	end := Scanner patternEndIn: aString.
	sc := Scanner on: aString.
	sc next.
	[sc kind ~~ #end and: [sc stop - 1 <= end]] whileTrue: [sc next].
	[(sc kind == #binary and: [sc value = '<'])
		ifTrue: [[sc kind == #end or: [sc kind == #binary and: [sc value = '>']]] whileFalse: [sc next]. sc next. true]
		ifFalse: [
			(sc kind == #binary and: [sc value = '||'])
				ifTrue: [sc next. true]
				ifFalse: [
					sc kind == #bar
						ifTrue: [sc next. [sc kind == #end or: [sc kind == #bar]] whileFalse: [sc next]. sc next. true]
						ifFalse: [false]]]] whileTrue.
	^ sc start - 1
]

{ #category : #recording }
OTTrace class >> trace: aSelector in: aClass [
	"Recompile the method with the recording statement first; false when it is not traced (no arguments, a primitive, a handler or unwind mark, no source or no statement)."
	| m src tree start args prologue bytes |
	m := aClass compiledMethodAt: aSelector ifAbsent: [^ false].
	(m numArgs = 0 or: [m primitive ~= 0 or: [m hasHandlerMark or: [m hasUnwindMark]]]) ifTrue: [^ false].
	src := m sourceCode.
	src isNil ifTrue: [^ false].
	tree := Parser parse: src.
	tree statements isEmpty ifTrue: [^ false].
	start := self statementsStartIn: src.
	args := tree arguments collect: [:a | a first].
	prologue := String streamContents: [:s |
		s nextPutAll: 'OTTrace note: '; print: aClass name , '>>' , aSelector; nextPutAll: ' args: {'.
		args do: [:a | s nextPutAll: a] separatedBy: [s nextPutAll: '. '].
		s nextPutAll: '}. '].
	bytes := src asByteArray.
	aClass compile: (String fromUtf8: (bytes copyFrom: 1 to: start)) , prologue , (String fromUtf8: (bytes copyFrom: start + 1 to: bytes size)).
	^ true
]
