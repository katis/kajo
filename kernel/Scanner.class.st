"Smalltalk method syntax to tokens: the bootstrap compiler's scanner (Sources/KajoCompiler/Syntax.swift) in Smalltalk, token for token. Positions are byte offsets into the source String. Token kinds are Symbols: #identifier #keyword #binary #integer #float #string #character #symbol #literalArrayStart #byteArrayStart #assign #caret #period #semicolon #colon #leftParen #rightParen #leftBracket #rightBracket #leftBrace #rightBrace #bar #end. Identifiers are ASCII letters, digits and _, and any non-separator scalar above 127 (the Swift one takes Unicode letters)."
Class {
	#name : #Scanner,
	#superclass : #Object,
	#instVars : [
		'source',
		'position',
		'limit',
		'line',
		'kind',
		'value',
		'start',
		'stop',
		'tokenLine'
	],
	#category : #'Kernel-Compiler'
}

{ #category : #accessing }
Scanner >> byteAt: i [
	^ i < limit ifTrue: [source byteAt: i] ifFalse: [0]
]

{ #category : #accessing }
Scanner >> digits: radix [
	| out b d |
	out := OrderedCollection new.
	[b := self byteAt: position.
	 d := (b between: 48 and: 57) ifTrue: [b - 48] ifFalse: [(b between: 65 and: 90) ifTrue: [b - 55] ifFalse: [99]].
	 d < radix] whileTrue: [out add: d. position := position + 1].
	^ out
]

{ #category : #accessing }
Scanner >> fail: aString [
	^ self fail: aString line: line
]

{ #category : #accessing }
Scanner >> fail: aString line: anInteger [
	^ CompileError new line: anInteger; signal: aString
]

{ #category : #accessing }
Scanner >> identifierRun [
	| s |
	s := position.
	[(self isLetterAt: position) or: [self isDigitByte: (self byteAt: position)]] whileTrue: [
		position := position + (source scalarSizeAt: position)].
	^ source copyFrom: s to: position - 1
]

{ #category : #accessing }
Scanner >> isBinaryByte: b [
	^ b > 0 and: [b < 128 and: ['+-*/\<>=~&|@%,?!' includes: (Character value: b)]]
]

{ #category : #accessing }
Scanner >> isDigitByte: b [
	^ b >= 48 and: [b <= 57]
]

{ #category : #accessing }
Scanner >> isLetterAt: i [
	| b |
	i >= limit ifTrue: [^ false].
	b := source byteAt: i.
	b < 128 ifTrue: [^ (b between: 65 and: 90) or: [(b between: 97 and: 122) or: [b = 95]]].
	^ (source isBoundary: i) and: [(source scalarAt: i) isSeparator not]
]

{ #category : #accessing }
Scanner >> kind [
	^ kind
]

{ #category : #accessing }
Scanner >> next [
	| b s name c |
	self skipSpace.
	start := position.
	tokenLine := line.
	position >= limit ifTrue: [^ self token: #end value: nil].
	b := source byteAt: position.
	(self isLetterAt: position) ifTrue: [
		name := self identifierRun.
		((self byteAt: position) = 58 and: [(self byteAt: position + 1) ~= 61]) ifTrue: [
			position := position + 1.
			^ self token: #keyword value: name , ':'].
		^ self token: #identifier value: name].
	(self isDigitByte: b) ifTrue: [^ self scanNumber].
	b = 39 ifTrue: [position := position + 1. ^ self token: #string value: self quoted].
	b = 36 ifTrue: [
		position := position + 1.
		position >= limit ifTrue: [^ self fail: 'a character literal needs a character'].
		c := source scalarAt: position.
		position := position + (source scalarSizeAt: position).
		c value = 10 ifTrue: [line := line + 1].
		^ self token: #character value: c].
	b = 35 ifTrue: [^ self scanHash].
	b = 58 ifTrue: [
		position := position + 1.
		(self byteAt: position) = 61 ifTrue: [position := position + 1. ^ self token: #assign value: nil].
		^ self token: #colon value: nil].
	b = 94 ifTrue: [position := position + 1. ^ self token: #caret value: nil].
	b = 46 ifTrue: [position := position + 1. ^ self token: #period value: nil].
	b = 59 ifTrue: [position := position + 1. ^ self token: #semicolon value: nil].
	b = 40 ifTrue: [position := position + 1. ^ self token: #leftParen value: nil].
	b = 41 ifTrue: [position := position + 1. ^ self token: #rightParen value: nil].
	b = 91 ifTrue: [position := position + 1. ^ self token: #leftBracket value: nil].
	b = 93 ifTrue: [position := position + 1. ^ self token: #rightBracket value: nil].
	b = 123 ifTrue: [position := position + 1. ^ self token: #leftBrace value: nil].
	b = 125 ifTrue: [position := position + 1. ^ self token: #rightBrace value: nil].
	(self isBinaryByte: b) ifTrue: [
		s := position.
		[(self isBinaryByte: (self byteAt: position))
			and: [(position > s and: [(self byteAt: position) = 45 and: [self isDigitByte: (self byteAt: position + 1)]]) not]]
				whileTrue: [position := position + 1].
		name := source copyFrom: s to: position - 1.
		name = '|' ifTrue: [^ self token: #bar value: nil].
		^ self token: #binary value: name].
	^ self fail: 'unexpected character'
]

{ #category : #accessing }
Scanner >> position [
	^ position
]

{ #category : #accessing }
Scanner >> quoted [
	"After the opening quote: the String up to the closing one ('' is a quote)."
	| s out startLine b |
	startLine := line.
	out := WriteStream on: String new.
	s := position.
	[true] whileTrue: [
		position >= limit ifTrue: [^ self fail: 'unterminated string' line: startLine].
		b := source byteAt: position.
		b = 39 ifTrue: [
			out nextPutAll: (source copyFrom: s to: position - 1).
			(self byteAt: position + 1) = 39
				ifTrue: [out nextPut: $'. position := position + 2. s := position]
				ifFalse: [position := position + 1. ^ out contents]]
			ifFalse: [
				b = 10 ifTrue: [line := line + 1].
				position := position + 1]]
]

{ #category : #accessing }
Scanner >> restore: anArray [
	position := anArray at: 1.
	line := anArray at: 2.
	kind := anArray at: 3.
	value := anArray at: 4.
	start := anArray at: 5.
	stop := anArray at: 6.
	tokenLine := anArray at: 7
]

{ #category : #accessing }
Scanner >> scanHash [
	| b s name |
	position := position + 1.
	position >= limit ifTrue: [^ self fail: 'a lone #'].
	b := source byteAt: position.
	b = 40 ifTrue: [position := position + 1. ^ self token: #literalArrayStart value: nil].
	b = 91 ifTrue: [position := position + 1. ^ self token: #byteArrayStart value: nil].
	b = 39 ifTrue: [position := position + 1. ^ self token: #symbol value: self quoted].
	(self isBinaryByte: b) ifTrue: [
		s := position.
		[self isBinaryByte: (self byteAt: position)] whileTrue: [position := position + 1].
		^ self token: #symbol value: (source copyFrom: s to: position - 1)].
	(self isLetterAt: position) ifTrue: [
		name := self identifierRun.
		[(self byteAt: position) = 58] whileTrue: [
			position := position + 1.
			name := name , ':'.
			(self isLetterAt: position)
				ifTrue: [name := name , self identifierRun]
				ifFalse: [^ self token: #symbol value: name]].
		^ self token: #symbol value: name].
	^ self fail: 'bad symbol literal'
]

{ #category : #accessing }
Scanner >> scanNumber [
	| radix ds fraction exponent p neg e v text f |
	radix := 10.
	ds := self digits: 10.
	(self byteAt: position) = 114 ifTrue: [
		radix := ds inject: 0 into: [:a :d | a * 10 + d min: 1000].
		(radix between: 2 and: 36) ifFalse: [^ self fail: 'radix not in 2...36'].
		position := position + 1.
		ds := self digits: radix.
		ds isEmpty ifTrue: [^ self fail: 'no digits after the radix']].
	ds size > 4000 ifTrue: [^ self fail: 'a number literal longer than 4000 digits'].
	fraction := #().
	(radix = 10 and: [(self byteAt: position) = 46 and: [self isDigitByte: (self byteAt: position + 1)]]) ifTrue: [
		position := position + 1.
		fraction := self digits: 10].
	(radix = 10 and: [(self byteAt: position) = 101]) ifTrue: [
		p := position + 1.
		neg := false.
		(self byteAt: p) = 45 ifTrue: [neg := true. p := p + 1].
		(self isDigitByte: (self byteAt: p)) ifTrue: [
			position := p.
			e := (self digits: 10) inject: 0 into: [:a :d | a * 10 + d min: 100000].
			exponent := neg ifTrue: [e negated] ifFalse: [e]]].
	(fraction isEmpty and: [(exponent ifNil: [0]) >= 0]) ifTrue: [
		v := ds inject: 0 into: [:a :d | a * radix + d].
		exponent ifNotNil: [:x |
			x > 4000 ifTrue: [^ self fail: 'an exponent larger than 4000'].
			v := v * (10 raisedTo: x)].
		^ self token: #integer value: v].
	text := WriteStream on: String new.
	ds do: [:d | text print: d].
	fraction isEmpty ifFalse: [text nextPut: $.. fraction do: [:d | text print: d]].
	exponent ifNotNil: [:x | text nextPut: $e; print: x].
	f := text contents asFloat.
	f isFinite ifFalse: [^ self fail: 'float literal out of range'].
	^ self token: #float value: f
]

{ #category : #accessing }
Scanner >> setSource: aString [
	source := aString.
	position := 1.
	limit := aString byteSize + 1.
	line := 1
]

{ #category : #accessing }
Scanner >> skipSpace [
	| b startLine |
	[position < limit] whileTrue: [
		b := source byteAt: position.
		b = 10
			ifTrue: [line := line + 1. position := position + 1]
			ifFalse: [
				(b = 32 or: [b = 9 or: [b = 13 or: [b = 12]]])
					ifTrue: [position := position + 1]
					ifFalse: [
						b = 34 ifFalse: [^ self].
						startLine := line.
						position := position + 1.
						[position < limit and: [(source byteAt: position) ~= 34]] whileTrue: [
							(source byteAt: position) = 10 ifTrue: [line := line + 1].
							position := position + 1].
						position >= limit ifTrue: [^ self fail: 'unterminated comment' line: startLine].
						position := position + 1]]]
]

{ #category : #accessing }
Scanner >> source [
	^ source
]

{ #category : #accessing }
Scanner >> start [
	^ start
]

{ #category : #accessing }
Scanner >> state [
	^ {position. line. kind. value. start. stop. tokenLine}
]

{ #category : #accessing }
Scanner >> stop [
	^ stop
]

{ #category : #accessing }
Scanner >> token: aKind value: anObject [
	kind := aKind.
	value := anObject.
	stop := position.
	^ aKind
]

{ #category : #accessing }
Scanner >> tokenLine [
	^ tokenLine
]

{ #category : #accessing }
Scanner >> value [
	^ value
]

{ #category : #accessing }
Scanner class >> on: aString [
	^ self basicNew setSource: aString
]

{ #category : #accessing }
Scanner class >> patternEndIn: aString [
	"The byte offset of the last byte of a method source's message pattern (module 8e: the Tonel writer puts the body's bracket after it)."
	| s k end |
	s := self on: aString.
	k := s next.
	k == #identifier ifTrue: [^ s stop - 1].
	(k == #binary or: [k == #bar]) ifTrue: [s next. ^ s stop - 1].
	end := 0.
	[k == #keyword] whileTrue: [
		s next.
		end := s stop - 1.
		k := s next].
	^ end
]
