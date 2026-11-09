"The Tonel writer and reader in the image (module 8e): the canonical form the writer writes, the reader reading back what the writer wrote, a class defined and redefined from Tonel text, and a malformed file refused."
Class {
	#name : #TonelTest,
	#superclass : #TestCase
}

{ #category : #running }
TonelTest >> tearDown [
	Smalltalk isReleaseImage ifTrue: [^ self].
	(Smalltalk at: #LiveTonelSample ifAbsent: [nil]) ifNotNil: [:c | Smalltalk removeClass: c]
]

{ #category : #samples }
TonelTest >> sampleText [
	^ '"A class read from Tonel at run time (TonelTest); ""quoted"" words."
Class {
	#name : #LiveTonelSample,
	#superclass : #Object,
	#instVars : [
		''a'',
		''b''
	],
	#classVars : [
		''Shared''
	],
	#classInstVars : [
		''made''
	]
}

{ #category : #accessing }
LiveTonelSample >> a [
	^ a
]

{ #category : #accessing }
LiveTonelSample >> a: x b: y [
	a := x.
	b := y
]

{ #category : #accessing }
LiveTonelSample >> b [
	^ b
]

{ #category : #computing }
LiveTonelSample >> sum [
	"a + b, the comment has a ] in it"
	^ a + b + (Shared ifNil: [0])
]

{ #category : #''instance creation'' }
LiveTonelSample class >> made [
	^ made ifNil: [0]
]

{ #category : #''instance creation'' }
LiveTonelSample class >> new [
	made := self made + 1.
	^ super new
]
'
]

{ #category : #tests }
TonelTest >> testAClassDefinedAndRedefinedFromTonel [
	| c x text |
	Smalltalk isReleaseImage ifTrue: [^ self].
	c := Smalltalk readTonel: self sampleText.
	self assert: (Smalltalk at: #LiveTonelSample) == c.
	self assert: c tonelSource = self sampleText.
	self assert: c comment = 'A class read from Tonel at run time (TonelTest); "quoted" words.'.
	self assert: (c categoryOf: #sum) == #computing.
	x := c new a: 1 b: 2; yourself.
	self assert: x sum = 3 & (c made = 1).
	"the same file again changes nothing"
	self assert: (Smalltalk readTonel: self sampleText) == c.
	self assert: c tonelSource = self sampleText.
	"a renamed instance variable, its methods changed with it, a method gone: one step"
	text := (self sampleText copyReplaceAll: '''a'',' with: '''z'',') copyReplaceAll: 'a := x' with: 'z := x'.
	text := text copyReplaceAll: '^ a + b' with: '^ z + b'.
	text := text copyReplaceAll: (String lf , '{ #category : #accessing }' , String lf , 'LiveTonelSample >> a [' , String lf , String tab , '^ a' , String lf , ']' , String lf) with: ''.
	Smalltalk readTonel: text.
	self assert: c instVarNames = #(#z #b).
	self assert: c tonelSource = text.
	self assert: x b = 2.
	self assert: (x instVarAt: 1) isNil.
	self deny: (x respondsTo: #a).
	x a: 5 b: 6.
	self assert: x sum = 11
]

{ #category : #tests }
TonelTest >> testATagIsTheFilesDirectory [
	"Tags as subdirectories: a class's tag comes from the path its file is read from, relative to its package's directory, never from a key; an old Kajo file's #category and a Pharo file's #package and #tag are read and ignored, and the next write leaves them out."
	| c old pharo |
	Smalltalk isReleaseImage ifTrue: [^ self].
	self assert: (TonelReader tagOfPath: 'Foo.class.st') isNil.
	self assert: (TonelReader tagOfPath: 'Things/Foo.class.st') == #Things.
	self assert: (TonelReader tagOfPath: 'Tests-Live/Foo.class.st') == #'Tests-Live'.
	#('a/b/Foo.class.st' '/Foo.class.st' '.hidden/Foo.class.st' '../Foo.class.st') do: [:p |
		self should: [TonelReader tagOfPath: p] raise: Error].
	old := self sampleText copyReplaceAll: '''made''
	]
}' with: '''made''
	],
	#category : #''Kernel-Tests-Live''
}'.
	pharo := self sampleText copyReplaceAll: '''made''
	]
}' with: '''made''
	],
	#package : #''Elsewhere'',
	#tag : #''Somewhere''
}'.
	self deny: old = self sampleText.
	self deny: pharo = self sampleText.
	self assert: (TonelReader read: old) summary = (TonelReader read: self sampleText) summary.
	self assert: (TonelReader read: pharo) summary = (TonelReader read: self sampleText) summary.
	c := Smalltalk readTonel: old path: 'Live/LiveTonelSample.class.st'.
	self assert: (Smalltalk tagOf: c) == #Live.
	self assert: c tonelSource = self sampleText.
	self assert: (TonelWriter pathOf: c package: (Smalltalk packageOf: c)) = 'Live/LiveTonelSample.class.st'.
	Smalltalk readTonel: pharo path: 'LiveTonelSample.class.st'.
	self assert: (Smalltalk tagOf: c) isNil.
	self assert: c tonelSource = self sampleText.
	self assert: (TonelWriter pathOf: c package: (Smalltalk packageOf: c)) = 'LiveTonelSample.class.st'.
	Smalltalk readTonel: self sampleText.
	self assert: (Smalltalk tagOf: c) isNil.
	self should: [Smalltalk readTonel: self sampleText path: 'a/b/LiveTonelSample.class.st'] raise: Error
]

{ #category : #tests }
TonelTest >> testMalformedTonelIsRefused [
	#('' 'Class' 'Class {' 'Class { #superclass : #Object }' 'Thing { #name : #X }' 'Class { #name : #X } Y >> foo [ ^ 1 ]' 'Class { #name : #X } X >> foo [ ^ 1' '"open comment' 'Class { #name : #X, #instVars : [ ''a-b'' ] }') do: [:t |
		self should: [TonelReader read: t] raise: CompileError]
]

{ #category : #tests }
TonelTest >> testTheReaderReadsWhatTheWriterWrote [
	#(#Object #ClassVariableSample #Float #Array #SmallFloat #Ephemeron #LiveSample #Compiler #Smalltalk) do: [:n | | c doc |
		c := Smalltalk at: n.
		doc := TonelReader read: c tonelSource.
		self assert: doc name = c name asString.
		self assert: doc superclassName = (c superclass ifNotNil: [:s | s name asString]).
		self assert: (doc instVarNames collect: [:x | x asSymbol]) = c instVarNames asArray.
		self assert: (doc classVarNames collect: [:x | x asSymbol]) = c classVarNames asArray.
		self assert: (doc classInstVarNames collect: [:x | x asSymbol]) = c class instVarNames asArray.
		self deny: ((c tonelSource copyFrom: 1 to: (c tonelSource indexOfSubstring: (String lf , '}'))) includesSubstring: '#category :').
		self assert: doc comment = c comment.
		self assert: doc methods size = (c selectors size + c class selectors size).
		doc methods do: [:m | | b sel |
			b := (m at: 1) ifTrue: [c class] ifFalse: [c].
			sel := (Compiler compile: (m at: 3) in: b) selector.
			self assert: (Smalltalk sourceOf: b >> sel) = (m at: 3).
			self assert: (b categoryOf: sel) = (m at: 2) asSymbol]]
]

{ #category : #tests }
TonelTest >> testTheWritersForm [
	| t |
	t := ClassVariableSample tonelSource.
	self assert: (t beginsWith: '"').
	self assert: (t includesSubstring: '#classVars : [').
	self assert: (t indexOfSubstring: 'ClassVariableSample >> ') < (t indexOfSubstring: 'ClassVariableSample class >> ').
	self assert: (t endsWith: (String with: $] with: Character lf)).
	self assert: (TonelWriter ston: #accessing) = '#accessing'.
	self assert: (TonelWriter ston: 'instance creation') = '#''instance creation'''.
	self assert: (TonelWriter ston: 'it''s') = '#''it''''s'''.
	self assert: (Array tonelSource includesSubstring: '#type : #variable').
	self assert: (SmallFloat tonelSource includesSubstring: '#type : #normal').
	self deny: (SmallInteger tonelSource includesSubstring: '#type').
	self deny: (LiveSample tonelSource includesSubstring: '#classVars')
]
