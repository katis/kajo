"Recursive descent over the Scanner's tokens: the bootstrap compiler's parser in Smalltalk, with the same grammar and the same nesting limit. Since Types 1 (docs/modules/types-1.md) the pattern holds Strongtalk-style types, an argument's after its name and the result's after the whole pattern (TypeNode), with the bootstrap's grammar and refusals; typeSpans holds each written type's range, from its < to its >, for the source colourer."
Class {
	#name : #Parser,
	#superclass : #Object,
	#instVars : [
		'scanner',
		'depth',
		'lastEnd',
		'typeSpans'
	]
}

{ #category : #accessing }
Parser >> advance [
	lastEnd := scanner stop - 1.
	scanner next
]

{ #category : #accessing }
Parser >> atStatementsEnd: inBlock [
	^ self kind == #end or: [inBlock and: [self kind == #rightBracket]]
]

{ #category : #accessing }
Parser >> enter [
	depth := depth + 1.
	depth > 32 ifTrue: [^ self fail: 'nested deeper than 32']
]

{ #category : #accessing }
Parser >> expect: aKind what: aString [
	scanner kind == aKind ifFalse: [^ self fail: 'expected ' , aString].
	self advance
]

{ #category : #accessing }
Parser >> fail: aString [
	^ CompileError new line: scanner tokenLine; signal: aString
]

{ #category : #accessing }
Parser >> isBinary: aString [
	^ self kind == #binary and: [self value = aString]
]

{ #category : #accessing }
Parser >> kind [
	^ scanner kind
]

{ #category : #accessing }
Parser >> lastEnd [
	"The end of the token most recently consumed (a byte offset from 0, exclusive)."
	^ lastEnd
]

{ #category : #accessing }
Parser >> leave [
	depth := depth - 1
]

{ #category : #accessing }
Parser >> line [
	^ scanner tokenLine
]

{ #category : #accessing }
Parser >> negativeNumberFollows [
	"The current token is - with a digit right after it."
	^ (self isBinary: '-') and: [scanner stop = scanner position and: [scanner isDigitByte: (scanner byteAt: scanner position)]]
]

{ #category : #accessing }
Parser >> parseBinaryMessages: receiver [
	| r op line a |
	r := receiver.
	[self kind == #binary or: [self kind == #bar]] whileTrue: [
		op := self kind == #bar ifTrue: ['|'] ifFalse: [self value].
		line := self line.
		self advance.
		a := self parseUnaryMessages: self parsePrimary.
		r := (MessageNode receiver: r selector: op asSymbol arguments: {a} line: line) sourceStart: r sourceStart end: lastEnd; yourself].
	^ r
]

{ #category : #accessing }
Parser >> parseBlock [
	| line args temps statements |
	line := self line.
	self advance.
	self enter.
	args := OrderedCollection new.
	[self kind == #colon] whileTrue: [
		self advance.
		self kind == #identifier ifFalse: [^ self fail: 'expected a block argument name'].
		args add: {self value. self line}.
		self advance].
	args isEmpty ifFalse: [
		(self isBinary: '||')
			ifTrue: [scanner restore: ((scanner state) at: 3 put: #bar; yourself)]
			ifFalse: [
				self kind == #bar
					ifTrue: [self advance]
					ifFalse: [self kind == #rightBracket ifFalse: [^ self fail: 'expected | after the block arguments']]]].
	temps := self parseTemporaries.
	statements := self parseStatementsInBlock: true.
	self expect: #rightBracket what: ']'.
	self leave.
	^ BlockNode arguments: args asArray temporaries: temps statements: statements line: line
]

{ #category : #accessing }
Parser >> parseByteArrayBody [
	| out |
	out := OrderedCollection new.
	[true] whileTrue: [
		self kind == #rightBracket ifTrue: [self advance. ^ ByteArray withAll: out].
		(self kind == #integer and: [self value between: 0 and: 255]) ifFalse: [^ self fail: 'a byte array holds integers 0 to 255'].
		out add: self value.
		self advance]
]

{ #category : #accessing }
Parser >> parseCascade: receiver [
	| first messages line placeholder m |
	first := self parseMessages: receiver.
	self kind == #semicolon ifFalse: [^ first].
	first class == MessageNode ifFalse: [^ self fail: 'a cascade needs a message before ;'].
	messages := OrderedCollection with: {first selector. first arguments. first line. first sourceStart. first sourceEnd}.
	[self kind == #semicolon] whileTrue: [
		self advance.
		line := self line.
		placeholder := VariableNode named: '' line: line.
		m := self parseMessages: placeholder.
		m class == MessageNode ifFalse: [^ self fail: 'expected a message after ;'].
		m receiver == placeholder ifFalse: [^ self fail: 'a cascade part is one message'].
		messages add: {m selector. m arguments. line. first receiver sourceStart. lastEnd}].
	^ CascadeNode receiver: first receiver messages: messages asArray line: receiver line
]

{ #category : #accessing }
Parser >> parseExpression [
	| save name line r |
	self kind == #identifier ifTrue: [
		save := {scanner state. lastEnd}.
		name := self value.
		line := self line.
		self advance.
		self kind == #assign ifTrue: [
			self advance.
			self enter.
			r := AssignmentNode variable: (VariableNode named: name line: line) value: self parseExpression line: line.
			self leave.
			^ r].
		scanner restore: save first.
		lastEnd := save last].
	^ self parseCascade: self parsePrimary
]

{ #category : #accessing }
Parser >> parseLiteralArrayBody [
	| out v s keywordEnd l |
	self enter.
	out := OrderedCollection new.
	[true] whileTrue: [
		self kind == #rightParen ifTrue: [self advance. self leave. ^ out asArray].
		self kind == #end ifTrue: [^ self fail: 'unterminated literal array'].
		(self kind == #leftParen or: [self kind == #literalArrayStart])
			ifTrue: [self advance. out add: self parseLiteralArrayBody]
			ifFalse: [
		(self kind == #leftBracket or: [self kind == #byteArrayStart])
			ifTrue: [self advance. out add: self parseByteArrayBody]
			ifFalse: [
		self kind == #identifier
			ifTrue: [
				v := self value.
				self advance.
				out add: (v = 'nil' ifTrue: [nil] ifFalse: [v = 'true' ifTrue: [true] ifFalse: [v = 'false' ifTrue: [false] ifFalse: [v asSymbol]]])]
			ifFalse: [
		self kind == #keyword
			ifTrue: [
				s := self value.
				keywordEnd := scanner stop.
				self advance.
				[self kind == #keyword and: [scanner start = keywordEnd]] whileTrue: [
					s := s , self value.
					keywordEnd := scanner stop.
					self advance].
				out add: s asSymbol]
			ifFalse: [
		(self kind == #binary and: [self negativeNumberFollows not])
			ifTrue: [out add: self value asSymbol. self advance]
			ifFalse: [
		self kind == #bar
			ifTrue: [out add: #|. self advance]
			ifFalse: [
				l := self parseLiteralToken.
				l isNil ifTrue: [^ self fail: 'unexpected token in a literal array'].
				out add: l first]]]]]]]
]

{ #category : #accessing }
Parser >> parseLiteralToken [
	"A literal in a one-element Array (nil literals are literals), or nil when the token starts none."
	| v |
	self negativeNumberFollows ifTrue: [
		self advance.
		v := self value.
		(self kind == #integer or: [self kind == #float]) ifFalse: [^ self fail: 'expected a number after -'].
		self advance.
		^ {v negated}].
	(#(#integer #float #string #character #symbol) includes: self kind) ifTrue: [
		v := self value.
		self kind == #symbol ifTrue: [v := v asSymbol].
		self advance.
		^ {v}].
	self kind == #literalArrayStart ifTrue: [self advance. ^ {self parseLiteralArrayBody}].
	self kind == #byteArrayStart ifTrue: [self advance. ^ {self parseByteArrayBody}].
	^ nil
]

{ #category : #accessing }
Parser >> parseMessages: receiver [
	| r line selector args a |
	r := self parseBinaryMessages: (self parseUnaryMessages: receiver).
	self kind == #keyword ifTrue: [
		line := self line.
		selector := ''.
		args := OrderedCollection new.
		[self kind == #keyword] whileTrue: [
			selector := selector , self value.
			self advance.
			a := self parsePrimary.
			args add: (self parseBinaryMessages: (self parseUnaryMessages: a))].
		r := (MessageNode receiver: r selector: selector asSymbol arguments: args asArray line: line) sourceStart: r sourceStart end: lastEnd; yourself].
	^ r
]

{ #category : #accessing }
Parser >> parseMethod [
	| line pattern pragmas temps statements |
	line := self line.
	pattern := self parsePattern.
	pragmas := self parsePragmas.
	temps := self parseTemporaries.
	pragmas := pragmas , self parsePragmas.
	statements := self parseStatementsInBlock: false.
	self kind == #end ifFalse: [^ self fail: 'unexpected text after the method''s statements'].
	^ MethodNode new
		setSelector: pattern first asSymbol arguments: (pattern at: 2) temporaries: temps pragmas: pragmas asArray statements: statements;
		argumentTypes: (pattern at: 3) resultType: (pattern at: 4);
		line: line;
		yourself
]

{ #category : #accessing }
Parser >> parsePragmaLiteral [
	| v |
	self kind == #identifier ifTrue: [
		v := self value.
		v = 'nil' ifTrue: [self advance. ^ nil].
		v = 'true' ifTrue: [self advance. ^ true].
		v = 'false' ifTrue: [self advance. ^ false].
		^ self fail: 'a pragma argument must be a literal'].
	^ self parseLiteralToken ifNil: [self fail: 'a pragma argument must be a literal'] ifNotNil: [:l | l first]
]

{ #category : #accessing }
Parser >> parsePragmas [
	| out line selector args |
	out := OrderedCollection new.
	[self isBinary: '<'] whileTrue: [
		line := self line.
		"Types 1: a capital, [, ( or : after the < is a type's start, and a type is written only in the pattern."
		self typeFollows ifTrue: [^ self fail: 'a pragma name starts with a lowercase letter'].
		self advance.
		selector := ''.
		args := OrderedCollection new.
		self kind == #identifier
			ifTrue: [selector := self value. self advance]
			ifFalse: [
				self kind == #keyword ifFalse: [^ self fail: 'expected a pragma'].
				[self kind == #keyword] whileTrue: [
					selector := selector , self value.
					self advance.
					args add: self parsePragmaLiteral]].
		(self isBinary: '>') ifFalse: [^ self fail: 'expected > to end the pragma'].
		self advance.
		out add: {selector asSymbol. args asArray. line}].
	^ out asArray
]

{ #category : #accessing }
Parser >> parsePrimary [
	"A primary with its source range (module 9b); a parenthesized expression keeps its own."
	| start n |
	start := scanner start - 1.
	n := self parsePrimaryNode.
	n sourceEnd isNil ifTrue: [n sourceStart: start end: lastEnd].
	^ n
]

{ #category : #accessing }
Parser >> parsePrimaryNode [
	| line name e elements l |
	line := self line.
	self kind == #identifier ifTrue: [
		name := self value.
		self advance.
		name = 'nil' ifTrue: [^ LiteralNode value: nil line: line].
		name = 'true' ifTrue: [^ LiteralNode value: true line: line].
		name = 'false' ifTrue: [^ LiteralNode value: false line: line].
		^ VariableNode named: name line: line].
	self kind == #leftParen ifTrue: [
		self advance.
		self enter.
		e := self parseExpression.
		self leave.
		self expect: #rightParen what: ')'.
		^ e].
	self kind == #leftBracket ifTrue: [^ self parseBlock].
	self kind == #leftBrace ifTrue: [
		self advance.
		self enter.
		elements := OrderedCollection new.
		[self kind == #rightBrace] whileFalse: [
			self kind == #period
				ifTrue: [self advance]
				ifFalse: [
					elements add: self parseExpression.
					self kind == #period
						ifTrue: [self advance]
						ifFalse: [self kind == #rightBrace ifFalse: [^ self fail: 'expected . or } in a brace array']]]].
		self advance.
		self leave.
		^ BraceNode elements: elements asArray line: line].
	l := self parseLiteralToken.
	l isNil ifTrue: [^ self fail: 'expected an expression'].
	^ LiteralNode value: l first line: line
]

{ #category : #accessing }
Parser >> parseStatementsInBlock: inBlock [
	| out line |
	out := OrderedCollection new.
	[true] whileTrue: [
		(self atStatementsEnd: inBlock) ifTrue: [^ out asArray].
		self kind == #period
			ifTrue: [self advance]
			ifFalse: [
				self kind == #caret
					ifTrue: [
						line := self line.
						self advance.
						out add: (ReturnNode value: self parseExpression line: line).
						[self kind == #period] whileTrue: [self advance].
						(self atStatementsEnd: inBlock) ifTrue: [^ out asArray].
						^ self fail: 'statements after a return']
					ifFalse: [
						out add: self parseExpression.
						self kind == #period
							ifTrue: [self advance]
							ifFalse: [
								(self atStatementsEnd: inBlock) ifTrue: [^ out asArray].
								^ self fail: 'expected a period or the end of the statements']]]]
]

{ #category : #accessing }
Parser >> parseTemporaries [
	| temps |
	temps := OrderedCollection new.
	(self isBinary: '||') ifTrue: [self advance. ^ #()].
	self kind == #bar ifFalse: [^ #()].
	self advance.
	[self kind == #identifier] whileTrue: [temps add: {self value. self line}. self advance].
	self kind == #bar ifFalse: [^ self fail: 'expected | to end the temporaries'].
	self advance.
	^ temps asArray
]

{ #category : #accessing }
Parser >> parseUnaryMessages: receiver [
	| r |
	r := receiver.
	[self kind == #identifier] whileTrue: [
		r := (MessageNode receiver: r selector: self value asSymbol arguments: #() line: self line) sourceStart: r sourceStart end: scanner stop - 1; yourself.
		self advance].
	^ r
]

{ #category : #accessing }
Parser >> setSource: aString [
	scanner := Scanner on: aString.
	depth := 0.
	lastEnd := 0.
	scanner next
]

{ #category : #accessing }
Parser >> setSource: aString position: aPosition line: aLine [
	"Read aString from the byte at aPosition (from 1), counting lines from aLine (the Tonel reader's pattern)."
	scanner := Scanner on: aString.
	scanner position: aPosition line: aLine.
	depth := 0.
	lastEnd := aPosition - 1.
	scanner next
]

{ #category : #accessing }
Parser >> value [
	^ scanner value
]

{ #category : #types }
Parser >> expectTypeEnd [
	"The > that ends a type is one character (Types 1, starting position 2): a binary run that starts with it is split and the rest scanned again, so ^<A>| t | and <A><B> read as with a blank."
	(self kind == #binary and: [(self value byteAt: 1) = 62]) ifFalse: [^ self fail: 'expected > to end the type'].
	self value = '>' ifTrue: [^ self advance].
	lastEnd := scanner start.
	scanner rescanFrom: scanner start + 1
]

{ #category : #types }
Parser >> parseArgumentType [
	"An argument's <type> when one follows, else nil."
	^ self typeFollows ifTrue: [self parseTypeAnnotation] ifFalse: [nil]
]

{ #category : #types }
Parser >> parseClassType [
	"A class definition's type (Types 1: #superclassType): the whole text one type, no method variable, no alternatives."
	| t |
	t := self parseType.
	self kind == #semicolon ifTrue: [^ self fail: 'alternatives are written in a method''s pattern'].
	self kind == #end ifFalse: [^ self fail: 'unexpected text after the type'].
	t declaresVariable ifTrue: [^ self fail: 'a method variable is declared in a method''s pattern'].
	^ t
]

{ #category : #types }
Parser >> parsePattern [
	"The message pattern with its types (Types 1): {selector. arguments ({name. line} each). argument types (a TypeNode or nil each). result type or nil}."
	| selector args types result counts argument |
	selector := ''.
	args := OrderedCollection new.
	types := OrderedCollection new.
	argument := [
		self kind == #identifier ifFalse: [^ self fail: 'expected an argument name'].
		args add: {self value. self line}.
		self advance.
		types add: self parseArgumentType].
	self kind == #identifier ifTrue: [selector := self value. self advance] ifFalse: [
	(self kind == #binary or: [self kind == #bar]) ifTrue: [
		selector := self kind == #bar ifTrue: ['|'] ifFalse: [self value].
		self advance.
		argument value] ifFalse: [
	self kind == #keyword ifTrue: [
		[self kind == #keyword] whileTrue: [
			selector := selector , self value.
			self advance.
			argument value]] ifFalse: [
	^ self fail: 'expected a message pattern']]].
	(self kind == #caret and: [self typeFollowsCaret]) ifTrue: [
		self advance.
		result := self parseTypeAnnotation.
		self kind == #keyword ifTrue: [^ self fail: 'the result type follows the whole pattern'].
		self typeFollows ifTrue: [^ self fail: 'a type after the result'].
		(self kind == #caret and: [self typeFollowsCaret]) ifTrue: [^ self fail: 'two result types']].
	"Overloads: every place with alternatives has the same number."
	counts := ((types asArray copyWith: result) select: [:t | t notNil and: [t kind == #alternatives]]) collect: [:t | t parts size].
	counts isEmpty ifFalse: [
		args isEmpty ifTrue: [^ self fail: 'a unary method has no overloads'].
		(counts allSatisfy: [:n | n = counts first]) ifFalse: [^ self fail: 'overloads give every place the same number of alternatives']].
	^ {selector. args asArray. types asArray. result}
]

{ #category : #types }
Parser >> parseType [
	"type := member { | member }"
	| start first members |
	self enter.
	start := scanner start - 1.
	first := self parseTypeMember.
	self kind == #bar ifFalse: [self leave. ^ first].
	members := OrderedCollection with: first.
	[self kind == #bar] whileTrue: [
		self advance.
		members add: self parseTypeMember].
	self leave.
	^ TypeNode kind: #union name: nil parts: members asArray result: nil start: start end: lastEnd
]

{ #category : #types }
Parser >> parseTypeAnnotation [
	"< alternatives >, at the <."
	| spanStart start first all t |
	spanStart := scanner start - 1.
	self advance.
	start := scanner start - 1.
	first := self parseType.
	t := first.
	self kind == #semicolon ifTrue: [
		all := OrderedCollection with: first.
		[self kind == #semicolon] whileTrue: [
			self advance.
			all add: self parseType].
		t := TypeNode kind: #alternatives name: nil parts: all asArray result: nil start: start end: lastEnd].
	self expectTypeEnd.
	typeSpans isNil ifTrue: [typeSpans := OrderedCollection new].
	typeSpans add: {spanStart. lastEnd}.
	^ t
]

{ #category : #types }
Parser >> parseTypeMember [
	"member := primary [ class ]"
	| start p |
	start := scanner start - 1.
	p := self parseTypePrimary.
	(self kind == #identifier and: [self value = 'class']) ifFalse: [^ p].
	self advance.
	^ TypeNode kind: #class name: nil parts: {p} result: nil start: start end: lastEnd
]

{ #category : #types }
Parser >> parseTypePrimary [
	| start n args result t |
	start := scanner start - 1.
	self kind == #identifier ifTrue: [
		n := self value.
		((n byteAt: 1) between: 65 and: 90) ifFalse: [^ self fail: 'a type name starts with a capital'].
		self advance.
		self kind == #leftBracket ifFalse: [^ TypeNode kind: #name name: n parts: #() result: nil start: start end: lastEnd].
		self advance.
		args := OrderedCollection with: self parseType.
		[self isBinary: ','] whileTrue: [
			self advance.
			args add: self parseType].
		self kind == #rightBracket ifFalse: [^ self fail: 'expected ] to end the type arguments'].
		self advance.
		^ TypeNode kind: #name name: n parts: args asArray result: nil start: start end: lastEnd].
	self kind == #colon ifTrue: [
		self advance.
		(self kind == #identifier and: [(self value byteAt: 1) between: 65 and: 90]) ifFalse: [^ self fail: 'expected a type variable''s name after :'].
		n := self value.
		self advance.
		^ TypeNode kind: #variable name: n parts: #() result: nil start: start end: lastEnd].
	self kind == #leftBracket ifTrue: [
		self advance.
		args := OrderedCollection new.
		[self kind == #caret] whileFalse: [
			args add: self parseType.
			(self isBinary: ',') ifFalse: [^ self fail: 'a block type ends with ^ and its result type'].
			self advance].
		self advance.
		result := self parseType.
		self kind == #rightBracket ifFalse: [^ self fail: 'expected ] to end the block type'].
		self advance.
		^ TypeNode kind: #block name: nil parts: args asArray result: result start: start end: lastEnd].
	self kind == #leftParen ifTrue: [
		self advance.
		t := self parseType.
		self kind == #rightParen ifFalse: [^ self fail: 'expected ) in the type'].
		self advance.
		^ t].
	^ self fail: 'expected a type'
]

{ #category : #types }
Parser >> parseTypedVariables [
	"An #instVars item (Types 1): names, each with an optional <type> after it; {name. the type's text between the angle brackets, or nil} each."
	| out n start t end |
	out := OrderedCollection new.
	[self kind == #end] whileFalse: [
		self kind == #identifier ifFalse: [^ self fail: 'expected an instance variable''s name'].
		n := self value.
		self advance.
		self typeFollows
			ifFalse: [out add: {n. nil}]
			ifTrue: [
				self advance.
				start := scanner start.
				t := self parseType.
				self kind == #semicolon ifTrue: [^ self fail: 'alternatives are written in a method''s pattern'].
				t declaresVariable ifTrue: [^ self fail: 'a method variable is declared in a method''s pattern'].
				end := lastEnd.
				self expectTypeEnd.
				out add: {n. scanner source copyFrom: start to: end}]].
	^ out asArray
]

{ #category : #types }
Parser >> scanner [
	^ scanner
]

{ #category : #types }
Parser >> typeFollows [
	"Whether the token is a < that starts a type: followed by a capital, [, ( or :. The scanner is left where it was."
	^ self typeFollowsAfter: 0
]

{ #category : #types }
Parser >> typeFollowsAfter: n [
	| save answer |
	save := {scanner state. lastEnd}.
	n timesRepeat: [self advance].
	answer := (self isBinary: '<') and: [
		self advance.
		((self kind == #identifier or: [self kind == #keyword]) and: [(self value byteAt: 1) between: 65 and: 90])
			or: [#(#leftBracket #leftParen #colon) includes: self kind]].
	scanner restore: save first.
	lastEnd := save last.
	^ answer
]

{ #category : #types }
Parser >> typeFollowsCaret [
	"Whether the token is ^ and a type's < follows it."
	^ self typeFollowsAfter: 1
]

{ #category : #types }
Parser >> typeSpans [
	"{start. end} of each type written in the pattern, from its < to its > (byte offsets from 0, end exclusive)."
	^ typeSpans ifNil: [#()]
]

{ #category : #accessing }
Parser class >> parse: aString [
	^ self new setSource: aString; parseMethod
]

{ #category : #types }
Parser class >> parseClassType: aString [
	"A class definition's type, a TypeNode; a CompileError when it is not one."
	^ self new setSource: aString; parseClassType
]

{ #category : #types }
Parser class >> parseTypedVariables: aString [
	"An #instVars item's names with their types' texts; a CompileError when it is not one."
	^ self new setSource: aString; parseTypedVariables
]

{ #category : #types }
Parser class >> patternOf: aString [
	"A Parser that read aString's message pattern, types included; it stands at the token after it. The pattern's end is its lastEnd."
	| p |
	p := self new setSource: aString.
	p parsePattern.
	^ p
]
