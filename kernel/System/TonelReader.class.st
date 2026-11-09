"Tonel files read in the image (module 8e): the bootstrap reader (Sources/KajoCompiler/Tonel.swift) in Smalltalk, rule for rule: the comment before the definition (a doubled quote is one quote), the STON map of Class { ... } or Extension { ... } (a #category, #package or #tag key read and ignored as every key it does not know: the class's place is its file's, tagOfPath:), then each method's optional { #category : ... } and Class [class] >> pattern [ body ], the body's end found by bracket depth outside strings, comments and character literals. A method's source is its pattern without the blanks before the bracket, then its body (a blank between when the body starts with neither a blank nor a line break), as the image build records it. The bootstrap reader stays the image build's and the oracle: a test reads every kernel file with both."
Class {
	#name : #TonelReader,
	#superclass : #Object,
	#instVars : [
		'source',
		'position',
		'limit',
		'line'
	]
}

{ #category : #reading }
TonelReader >> byte [
	^ position < limit ifTrue: [source byteAt: position] ifFalse: [0]
]

{ #category : #reading }
TonelReader >> byteAt: i [
	^ i < limit ifTrue: [source byteAt: i] ifFalse: [0]
]

{ #category : #reading }
TonelReader >> comment [
	| out start |
	out := ''.
	position := position + 1.
	start := position.
	[true] whileTrue: [
		position >= limit ifTrue: [^ self fail: 'unterminated comment'].
		(self byte = 34)
			ifTrue: [
				out := out , (source copyFrom: start to: position - 1).
				(self byteAt: position + 1) = 34 ifFalse: [position := position + 1. ^ out].
				out := out , '"'.
				position := position + 2.
				start := position]
			ifFalse: [
				self byte = 10 ifTrue: [line := line + 1].
				position := position + 1]]
]

{ #category : #reading }
TonelReader >> fail: aString [
	^ CompileError new line: line; signal: aString
]

{ #category : #reading }
TonelReader >> identifier [
	| s |
	s := position.
	[position < limit and: [self isIdentifierByte: self byte]] whileTrue: [position := position + 1].
	^ source copyFrom: s to: position - 1
]

{ #category : #reading }
TonelReader >> isIdentifierByte: b [
	^ b >= 128 or: [(b between: 48 and: 57) or: [(b between: 65 and: 90) or: [(b between: 97 and: 122) or: [b = 95]]]]
]

{ #category : #reading }
TonelReader >> map: depth [
	"{ #key : value, ... }: an OrderedCollection of key -> value."
	| out key v |
	self byte = 123 ifFalse: [^ self fail: 'expected {'].
	position := position + 1.
	out := OrderedCollection new.
	[true] whileTrue: [
		self space.
		position >= limit ifTrue: [^ self fail: 'unterminated map'].
		self byte = 125 ifTrue: [position := position + 1. ^ out].
		key := self value: depth.
		key first == #symbol ifFalse: [^ self fail: 'a map key is a symbol'].
		self space.
		self byte = 58 ifFalse: [^ self fail: 'expected : after #' , (key at: 2)].
		position := position + 1.
		v := self value: depth.
		out add: (key at: 2) -> v.
		self space.
		self byte = 44 ifTrue: [position := position + 1]]
]

{ #category : #reading }
TonelReader >> matchingBracket: open [
	"The offset of the ] that closes the [ at open, skipping strings, comments and character literals."
	| depth k q |
	depth := 0.
	k := open.
	[k < limit] whileTrue: [ | b |
		b := source byteAt: k.
		b = 10 ifTrue: [line := line + 1].
		(b = 39 or: [b = 34]) ifTrue: [
			q := b.
			k := k + 1.
			[k < limit and: [(source byteAt: k) ~= q]] whileTrue: [(source byteAt: k) = 10 ifTrue: [line := line + 1]. k := k + 1]].
		b = 36 ifTrue: [
			k := k + 1.
			(k < limit and: [(source byteAt: k) = 10]) ifTrue: [line := line + 1].
			(k < limit and: [(source byteAt: k) >= 128]) ifTrue: [
				[k + 1 < limit and: [((source byteAt: k + 1) bitAnd: 192) = 128]] whileTrue: [k := k + 1]]].
		b = 91 ifTrue: [depth := depth + 1].
		(b = 93 and: [depth := depth - 1. depth = 0]) ifTrue: [^ k].
		k := k + 1].
	^ self fail: 'a method body without its closing ]'
]

{ #category : #reading }
TonelReader >> names: aKey in: aMap [
	"The names of an array entry (each item may hold several, separated by blanks)."
	| v out |
	v := (aMap detect: [:a | a key = aKey] ifNone: [^ #()]) value.
	v first == #array ifFalse: [^ self fail: '#' , aKey , ' is an array of names'].
	out := OrderedCollection new.
	(v at: 2) do: [:x |
		(#(#symbol #string #identifier) includes: x first) ifFalse: [^ self fail: '#' , aKey , ' is an array of names'].
		(x at: 2) substrings do: [:part |
			(Smalltalk isIdentifier: part) ifFalse: [^ self fail: 'bad name ''' , part , ''' in #' , aKey].
			out add: part]].
	^ out asArray
]

{ #category : #reading }
TonelReader >> quoted [
	"A '...' with '' for a quote; position at the opening quote."
	| out start |
	out := ''.
	position := position + 1.
	start := position.
	[true] whileTrue: [
		position >= limit ifTrue: [^ self fail: 'unterminated string'].
		self byte = 39
			ifTrue: [
				out := out , (source copyFrom: start to: position - 1).
				(self byteAt: position + 1) = 39 ifFalse: [position := position + 1. ^ out].
				out := out , ''''.
				position := position + 2.
				start := position]
			ifFalse: [
				self byte = 10 ifTrue: [line := line + 1].
				position := position + 1]]
]

{ #category : #reading }
TonelReader >> readDocument [
	| comment kind def doc name sup |
	comment := self space.
	kind := self identifier.
	(kind = 'Class' or: [kind = 'Extension']) ifFalse: [^ self fail: 'expected Class { ... } or Extension { ... }'].
	self space.
	def := self map: 0.
	name := self text: 'name' in: def.
	(name notNil and: [Smalltalk isIdentifier: name]) ifFalse: [^ self fail: 'the class needs a #name'].
	doc := TonelDocument new.
	doc name: name; comment: comment; isExtension: kind = 'Extension'.
	kind = 'Class' ifTrue: [
		sup := (def detect: [:a | a key = 'superclass'] ifNone: [nil]) ifNotNil: [:a | a value].
		(sup isNil or: [sup first == #identifier and: [(sup at: 2) = 'nil']])
			ifTrue: [doc superclassName: nil]
			ifFalse: [
				((#(#symbol #string #identifier) includes: sup first) and: [Smalltalk isIdentifier: (sup at: 2)]) ifFalse: [^ self fail: 'bad #superclass'].
				doc superclassName: (sup at: 2)].
		doc instVarNames: (self names: 'instVars' in: def); classInstVarNames: (self names: 'classInstVars' in: def);
			classVarNames: (self names: 'classVars' in: def)].
	doc type: (self text: 'type' in: def).
	[self space. position < limit] whileTrue: [self readMethodInto: doc].
	^ doc
]

{ #category : #reading }
TonelReader >> readMethodInto: aDocument [
	"A method's metadata is read for its category; any other key (an #author of a file written before the development answers among them) is read and ignored, as Pharo's Tonel ignores keys it does not know, so the next write leaves it out."
	| category owner classSide patternStart open close end src body meta |
	category := ''.
	self byte = 123 ifTrue: [
		meta := self map: 0.
		category := (self text: 'category' in: meta) ifNil: [''].
		self space].
	owner := self identifier.
	owner isEmpty ifTrue: [^ self fail: 'expected a method: Class >> selector [ ... ]'].
	self space.
	classSide := false.
	(limit - position >= 5 and: [(1 to: 5) allSatisfy: [:k | (source byteAt: position + k - 1) = (#(99 108 97 115 115) at: k)]]) ifTrue: [
		position := position + 5.
		classSide := true.
		self space].
	(self byte = 62 and: [(self byteAt: position + 1) = 62]) ifFalse: [^ self fail: 'expected >> after ' , owner].
	position := position + 2.
	self space.
	patternStart := position.
	[position < limit and: [self byte ~= 91]] whileTrue: [
		self byte = 10 ifTrue: [line := line + 1].
		position := position + 1].
	position >= limit ifTrue: [^ self fail: 'a method without a body'].
	open := position.
	close := self matchingBracket: open.
	end := open.
	[end > patternStart and: [#(9 10 13 32) includes: (source byteAt: end - 1)]] whileTrue: [end := end - 1].
	src := source copyFrom: patternStart to: end - 1.
	body := source copyFrom: open + 1 to: close - 1.
	(body notEmpty and: [(#(9 10 13 32) includes: (body byteAt: 1)) not]) ifTrue: [src := src , ' '].
	src := src , body.
	position := close + 1.
	owner = aDocument name ifFalse: [^ self fail: 'a method of ' , owner , ' in ' , aDocument name , '''s file'].
	aDocument methods add: (Array with: classSide with: category with: src)
]

{ #category : #reading }
TonelReader >> setSource: aString [
	source := aString.
	position := 1.
	limit := aString byteSize + 1.
	line := 1
]

{ #category : #reading }
TonelReader >> space [
	"Skip blanks and comments; answer the last comment's text (the class comment)."
	| comment b |
	comment := ''.
	[position < limit] whileTrue: [
		b := self byte.
		b = 10
			ifTrue: [line := line + 1. position := position + 1]
			ifFalse: [
				(b = 32 or: [b = 9 or: [b = 13]])
					ifTrue: [position := position + 1]
					ifFalse: [
						b = 34 ifFalse: [^ comment].
						comment := self comment]]].
	^ comment
]

{ #category : #reading }
TonelReader >> text: aKey in: aMap [
	| v |
	v := (aMap detect: [:a | a key = aKey] ifNone: [^ nil]) value.
	^ (#(#symbol #string #identifier) includes: v first) ifTrue: [v at: 2] ifFalse: [nil]
]

{ #category : #reading }
TonelReader >> value: depth [
	"A STON value: #symbol, #'symbol', 'string', [ array ], { map }, a number, or an identifier (nil). Symbols and identifiers answer Arrays tagged #symbol and #identifier; strings their text."
	| b s out |
	depth > 16 ifTrue: [^ self fail: 'STON nested too deep'].
	self space.
	position >= limit ifTrue: [^ self fail: 'expected a value'].
	b := self byte.
	b = 35 ifTrue: [
		position := position + 1.
		self byte = 39 ifTrue: [^ Array with: #symbol with: self quoted].
		s := position.
		[position < limit and: [(self byte > 32) and: [(#(44 125 93) includes: self byte) not]]] whileTrue: [position := position + 1].
		^ Array with: #symbol with: (source copyFrom: s to: position - 1)].
	b = 39 ifTrue: [^ Array with: #string with: self quoted].
	b = 91 ifTrue: [
		position := position + 1.
		out := OrderedCollection new.
		[true] whileTrue: [
			self space.
			position >= limit ifTrue: [^ self fail: 'unterminated array'].
			self byte = 93 ifTrue: [position := position + 1. ^ Array with: #array with: out asArray].
			out add: (self value: depth + 1).
			self space.
			self byte = 44 ifTrue: [position := position + 1]]].
	b = 123 ifTrue: [^ Array with: #map with: (self map: depth + 1)].
	((b between: 48 and: 57) or: [b = 45]) ifTrue: [
		s := position.
		position := position + 1.
		[position < limit and: [self byte between: 48 and: 57]] whileTrue: [position := position + 1].
		(s + 1 = position and: [b = 45]) ifTrue: [^ self fail: 'bad number'].
		^ Array with: #number with: (source copyFrom: s to: position - 1) asInteger].
	s := self identifier.
	s isEmpty ifTrue: [^ self fail: 'unexpected character in STON'].
	^ Array with: #identifier with: s
]

{ #category : #reading }
TonelReader class >> read: aString [
	"aString's class, a TonelDocument; a CompileError when it is not Tonel."
	^ self new setSource: aString; readDocument
]

{ #category : #reading }
TonelReader class >> tagOfPath: aPath [
	"The tag a class file's path gives, aPath relative to its package's directory (tags as subdirectories): nil for a file at the root, the directory's name for a file one directory down, refused (an Error) for a file further down or a directory name no tag can have. The bootstrap reader's tonelTag(ofPath:) is the same rule; a test compares them on every file."
	| parts |
	parts := aPath splitOn: '/'.
	parts size = 1 ifTrue: [^ nil].
	parts size = 2 ifFalse: [^ self error: aPath , ': a class file two directories below its package (a tag is one directory)'].
	((parts first isEmpty or: [(parts first byteAt: 1) = 46]) or: [parts first includes: (Character value: 0)])
		ifTrue: [^ self error: aPath , ': ''' , parts first , ''' is not a tag''s directory'].
	^ parts first asSymbol
]
