"Recursive descent over the Scanner's tokens: the bootstrap compiler's parser in Smalltalk, with the same grammar and the same nesting limit."
Class {
	#name : #Parser,
	#superclass : #Object,
	#instVars : [
		'scanner',
		'depth'
	],
	#category : #'Kernel-Compiler'
}

{ #category : #accessing }
Parser >> advance [
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
		r := MessageNode receiver: r selector: op asSymbol arguments: {a} line: line].
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
	messages := OrderedCollection with: {first selector. first arguments. first line}.
	[self kind == #semicolon] whileTrue: [
		self advance.
		line := self line.
		placeholder := VariableNode named: '' line: line.
		m := self parseMessages: placeholder.
		m class == MessageNode ifFalse: [^ self fail: 'expected a message after ;'].
		m receiver == placeholder ifFalse: [^ self fail: 'a cascade part is one message'].
		messages add: {m selector. m arguments. line}].
	^ CascadeNode receiver: first receiver messages: messages asArray line: receiver line
]

{ #category : #accessing }
Parser >> parseExpression [
	| save name line r |
	self kind == #identifier ifTrue: [
		save := scanner state.
		name := self value.
		line := self line.
		self advance.
		self kind == #assign ifTrue: [
			self advance.
			self enter.
			r := AssignmentNode variable: (VariableNode named: name line: line) value: self parseExpression line: line.
			self leave.
			^ r].
		scanner restore: save].
	^ self parseCascade: self parsePrimary
]

{ #category : #accessing }
Parser >> parseLiteralArrayBody [
	| out v s lastEnd l |
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
				lastEnd := scanner stop.
				self advance.
				[self kind == #keyword and: [scanner start = lastEnd]] whileTrue: [
					s := s , self value.
					lastEnd := scanner stop.
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
		r := MessageNode receiver: r selector: selector asSymbol arguments: args asArray line: line].
	^ r
]

{ #category : #accessing }
Parser >> parseMethod [
	| line selector args pragmas temps statements |
	line := self line.
	selector := ''.
	args := OrderedCollection new.
	self kind == #identifier ifTrue: [selector := self value. self advance] ifFalse: [
	(self kind == #binary or: [self kind == #bar]) ifTrue: [
		selector := self kind == #bar ifTrue: ['|'] ifFalse: [self value].
		self advance.
		self kind == #identifier ifFalse: [^ self fail: 'expected an argument name'].
		args add: {self value. self line}.
		self advance] ifFalse: [
	self kind == #keyword ifTrue: [
		[self kind == #keyword] whileTrue: [
			selector := selector , self value.
			self advance.
			self kind == #identifier ifFalse: [^ self fail: 'expected an argument name'].
			args add: {self value. self line}.
			self advance]] ifFalse: [
	^ self fail: 'expected a message pattern']]].
	pragmas := self parsePragmas.
	temps := self parseTemporaries.
	pragmas := pragmas , self parsePragmas.
	statements := self parseStatementsInBlock: false.
	self kind == #end ifFalse: [^ self fail: 'unexpected text after the method''s statements'].
	^ MethodNode new
		setSelector: selector asSymbol arguments: args asArray temporaries: temps pragmas: pragmas asArray statements: statements;
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
		r := MessageNode receiver: r selector: self value asSymbol arguments: #() line: self line.
		self advance].
	^ r
]

{ #category : #accessing }
Parser >> setSource: aString [
	scanner := Scanner on: aString.
	depth := 0.
	scanner next
]

{ #category : #accessing }
Parser >> value [
	^ scanner value
]

{ #category : #accessing }
Parser class >> parse: aString [
	^ self new setSource: aString; parseMethod
]
