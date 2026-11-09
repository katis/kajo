"The image's classes as Tonel files (module 8e), in the canonical form kernel/ is written in: the class comment (quotes doubled), the class definition with the keys #name, #superclass, #instVars, #classVars, #classInstVars (each only when not empty) and #type (only when the format kind is not the one the superclass's gives), never #category, #package or #tag (tags as subdirectories: the package is the directory the file is written into and the tag, when the class has one, the subdirectory), a tab before each key and two before each name; then the methods, instance side before class side, grouped by category with the categories sorted, the selectors sorted within each, each one as `{ #category : ... }` on its line and `Class >> pattern [body]` where pattern and body are the recorded source split after the message pattern. A body that does not start on a line of its own is put on one, indented by a tab; anything else of the source is written as recorded. A method of another package than its class's is written in that package's <Class>.extension.st, `Extension { #name : ... }` and the methods (module 9b). A method's metadata is its category only: an agent's author mark is a pragma in the method's source, <author: #'agent:<name>'> (the development answers; source:author: puts it there)."
Class {
	#name : #TonelWriter,
	#superclass : #Object
}

{ #category : #files }
TonelWriter class >> fileNameOf: aClass package: aName [
	"<Name>.class.st when aClass belongs to the package, else <Name>.extension.st (module 9b)."
	^ (Smalltalk packageOf: aClass) = aName
		ifTrue: [aClass name , '.class.st']
		ifFalse: [aClass name , '.extension.st']
]

{ #category : #files }
TonelWriter class >> pathOf: aClass package: aName [
	"The package aName's file of aClass relative to the package's directory: <Tag>/<Name>.class.st when aClass belongs to the package and has a tag, <Name>.class.st when it has none, <Name>.extension.st at the root for another package's class (an extension file stays at the package's root: the extended class's tag is not the package's business)."
	| name |
	name := self fileNameOf: aClass package: aName.
	(Smalltalk packageOf: aClass) = aName ifFalse: [^ name].
	^ (Smalltalk tagOf: aClass) ifNil: [name] ifNotNil: [:t | t asString , '/' , name]
]

{ #category : #files }
TonelWriter class >> write: aClass into: aDirectory [
	"Write aClass's file, <Name>.class.st, into aDirectory or its subdirectory <Tag> (a path under the directory the VM was opened with; '' for that directory itself)."
	^ self write: aClass package: (Smalltalk packageOf: aClass) into: aDirectory
]

{ #category : #files }
TonelWriter class >> write: aClass package: aName into: aDirectory [
	"Write aClass's file for the package aName into aDirectory: its class file when it belongs to the package (in the subdirectory of its tag, which the write creates when missing), else the package's extension file of it. Answers the path written."
	| name path |
	name := self pathOf: aClass package: aName.
	path := aDirectory isEmpty ifTrue: [name] ifFalse: [aDirectory , '/' , name].
	(Smalltalk primWriteFile: path contents: (self sourceOf: aClass package: aName)) == true
		ifFalse: [^ self error: 'cannot write ' , path].
	^ path
]

{ #category : #writing }
TonelWriter class >> canonicalSource: aString [
	"The source a method compiled from aString is recorded with when it is read back from the file this writer writes (module 9b: a development session compiles this, so the image and its files agree method for method): the pattern, then the body the writer puts on lines of its own, ending with a line break."
	^ (self patternAndBodyOf: aString) inject: '' into: [:a :b | a , b]
]

{ #category : #writing }
TonelWriter class >> cut: aRange in: aString [
	"{position. bytes to delete. ''}: the pragma at aRange, with its whole line when nothing else is on it, else with the blanks after it."
	| a b lineStart lineEnd blank |
	a := aRange first.
	b := aRange last.
	blank := [:i | #(9 32 13) includes: (aString byteAt: i)].
	lineStart := a.
	[lineStart > 1 and: [blank value: lineStart - 1]] whileTrue: [lineStart := lineStart - 1].
	lineEnd := b.
	[lineEnd <= aString byteSize and: [blank value: lineEnd]] whileTrue: [lineEnd := lineEnd + 1].
	((lineStart = 1 or: [(aString byteAt: lineStart - 1) = 10]) and: [lineEnd <= aString byteSize and: [(aString byteAt: lineEnd) = 10]])
		ifTrue: [^ Array with: lineStart with: lineEnd - lineStart + 1 with: ''].
	^ Array with: a with: lineEnd - a with: ''
]

{ #category : #writing }
TonelWriter class >> hasMethodsOf: aClass package: aName [
	^ (Array with: aClass with: aClass class) anySatisfy: [:b |
		b selectors anySatisfy: [:sel | (Smalltalk packageOfSelector: sel in: b) = aName]]
]

{ #category : #writing }
TonelWriter class >> headerOf: aClass [
	| d lf entries out comment type |
	lf := String lf.
	d := Smalltalk definitionOf: aClass.
	d isNil ifTrue: [^ self error: aClass name , ' has no definition in the image'].
	out := ''.
	comment := d comment ifNil: [''].
	comment isEmpty ifFalse: [out := '"' , (comment copyReplaceAll: '"' with: '""') , '"' , lf].
	entries := OrderedCollection new.
	entries add: '#name : ' , (self ston: aClass name).
	entries add: '#superclass : ' , (aClass superclass ifNil: ['nil'] ifNotNil: [:s | self ston: s name]).
	d instVarNames isEmpty ifFalse: [entries add: (self list: '#instVars' of: d instVarNames)].
	aClass classVarNames isEmpty ifFalse: [entries add: (self list: '#classVars' of: aClass classVarNames)].
	d classInstVarNames isEmpty ifFalse: [entries add: (self list: '#classInstVars' of: d classInstVarNames)].
	type := self typeOf: aClass.
	type ifNotNil: [:t | entries add: '#type : #' , t].
	out := out , 'Class {' , lf.
	entries doWithIndex: [:e :i |
		out := out , (String tab) , e , (i < entries size ifTrue: [',' , lf] ifFalse: [lf])].
	^ out , '}' , lf
]

{ #category : #writing }
TonelWriter class >> insert: aMark at: aPosition in: aString [
	"{position. 0. text}: aMark on a line of its own, indented as the line of aPosition, when only blanks precede aPosition on its line; else aMark and a blank before the token there."
	| lineStart i |
	aPosition > aString byteSize
		ifTrue: [^ Array with: aPosition with: 0 with: String tab , aMark , String lf].
	lineStart := aPosition.
	[lineStart > 1 and: [(aString byteAt: lineStart - 1) ~= 10]] whileTrue: [lineStart := lineStart - 1].
	i := lineStart.
	[i < aPosition and: [#(9 32) includes: (aString byteAt: i)]] whileTrue: [i := i + 1].
	(i = aPosition and: [lineStart > 1])
		ifTrue: [^ Array with: lineStart with: 0 with: (aString copyFrom: lineStart to: aPosition - 1) , aMark , String lf].
	^ Array with: aPosition with: 0 with: aMark , ' '
]

{ #category : #writing }
TonelWriter class >> list: aKey of: names [
	| lf out |
	lf := String lf.
	out := aKey , ' : [' , lf.
	names doWithIndex: [:n :i |
		out := out , (String tab) , (String tab) , '''' , n , '''' , (i < names size ifTrue: [','] ifFalse: ['']) , lf].
	^ out , (String tab) , ']'
]

{ #category : #writing }
TonelWriter class >> method: aSelector in: aBehavior category: aCategory [
	| lf src pattern body parts |
	lf := String lf.
	src := Smalltalk sourceOf: (aBehavior compiledMethodAt: aSelector).
	src isNil ifTrue: [^ self error: aBehavior name , '>>' , aSelector , ' has no source'].
	parts := self patternAndBodyOf: src.
	pattern := parts first.
	body := parts last.
	^ lf , '{ #category : ' , (self ston: aCategory) , ' }' , lf
		, aBehavior theNonMetaClass name , (aBehavior isMeta ifTrue: [' class'] ifFalse: ['']) , ' >> ' , pattern , ' [' , body , ']' , lf
]

{ #category : #writing }
TonelWriter class >> methodsOf: aClass [
	^ self methodsOf: aClass package: (Smalltalk packageOf: aClass)
]

{ #category : #writing }
TonelWriter class >> methodsOf: aClass package: aName [
	"Each method's text (a line break, its category, its definition) of the package aName, instance side first, by category, by selector."
	| out |
	out := OrderedCollection new.
	(Array with: aClass with: aClass class) do: [:b | | org |
		org := b organization.
		(org keys asArray sort: [:x :y | x <= y]) do: [:cat |
			(org at: cat) do: [:sel |
				(Smalltalk packageOfSelector: sel in: b) = aName ifTrue: [out add: (self method: sel in: b category: cat)]]]].
	^ out
]

{ #category : #writing }
TonelWriter class >> patternAndBodyOf: aString [
	"{pattern. body} as the writer writes a method of the recorded source aString: the body on a line of its own (indented by a tab when it was on the pattern's line) and ending with a line break."
	| lf end pattern body |
	lf := String lf.
	end := Scanner patternEndIn: aString.
	pattern := aString copyFrom: 1 to: end.
	body := aString copyFrom: end + 1 to: aString byteSize.
	(body includesSubstring: lf)
		ifTrue: [
			(body beginsWith: lf) ifFalse: [body := lf , (String tab) , (self withoutLeadingBlanks: body)].
			(body endsWith: lf) ifFalse: [body := body , lf]]
		ifFalse: [body := lf , (String tab) , body trimmed , lf].
	^ Array with: pattern with: body
]

{ #category : #writing }
TonelWriter class >> pragmasFrom: aScanner token: aKind into: cuts [
	"Skip the pragmas aScanner stands at (aKind its current token), adding {start. end} of each <author: ...> one to cuts; answers the token after them."
	| k sel start |
	k := aKind.
	[k == #binary and: [aScanner value = '<']] whileTrue: [
		start := aScanner start.
		k := aScanner next.
		sel := k == #keyword ifTrue: [aScanner value] ifFalse: [nil].
		[k == #end or: [k == #binary and: [aScanner value = '>']]] whileFalse: [k := aScanner next].
		k == #end ifTrue: [^ self error: 'an unterminated pragma'].
		sel = 'author:' ifTrue: [cuts add: (Array with: start with: aScanner stop)].
		k := aScanner next].
	^ k
]

{ #category : #writing }
TonelWriter class >> source: aString author: aClient [
	"The source a development session compiles for aClient (the development answers): for an agent ('agent:<name>') every <author: ...> pragma of aString is taken out and one naming the agent is put in, on a line of its own after the message pattern and the comment and pragmas that follow it, before the temporaries; a line that held only a pragma taken out goes with it. For a developer the source is compiled as written. So an agent's compile always leaves exactly one author pragma, its own, and a developer's is what the developer typed. A source the scanner cannot read is answered as it is (the compiler then says why)."
	| s k cuts insertAt edits lf out mark |
	(aClient notNil and: [aClient asString beginsWith: 'agent:']) ifFalse: [^ aString].
	lf := String lf.
	mark := '<author: ' , (self ston: aClient asString) , '>'.
	cuts := OrderedCollection new.
	[s := Scanner on: aString.
	k := s next.
	k == #identifier
		ifTrue: [k := s next]
		ifFalse: [
			(k == #binary or: [k == #bar])
				ifTrue: [s next. k := s next]
				ifFalse: [[k == #keyword] whileTrue: [s next. k := s next]]].
	k := self pragmasFrom: s token: k into: cuts.
	insertAt := s start.
	k == #bar ifTrue: [
		k := s next.
		[k == #bar or: [k == #end]] whileFalse: [k := s next].
		k == #bar ifTrue: [self pragmasFrom: s token: s next into: cuts]]]
		on: Error do: [:e | ^ aString].
	edits := OrderedCollection new.
	cuts do: [:c | edits add: (self cut: c in: aString)].
	edits add: (self insert: mark at: insertAt in: aString).
	edits := edits asArray sort: [:a :b | a first >= b first].
	out := aString.
	edits do: [:e |
		out := (out copyFrom: 1 to: e first - 1) , (e at: 3) , (out copyFrom: e first + (e at: 2) to: out byteSize)].
	^ out
]

{ #category : #writing }
TonelWriter class >> sourceOf: aClass [
	"aClass's Tonel file, a String."
	^ self sourceOf: aClass package: (Smalltalk packageOf: aClass)
]

{ #category : #writing }
TonelWriter class >> sourceOf: aClass package: aName [
	"The package aName's file of aClass: the class file when aClass belongs to it, else its Extension (module 9b), with the package's methods only."
	| out |
	out := (Smalltalk packageOf: aClass) = aName
		ifTrue: [self headerOf: aClass]
		ifFalse: ['Extension { #name : ' , (self ston: aClass name) , ' }' , String lf].
	(self methodsOf: aClass package: aName) do: [:m | out := out , m].
	^ out
]

{ #category : #writing }
TonelWriter class >> ston: aSymbolOrString [
	"A STON symbol: bare when every scalar is an ASCII letter or digit, else quoted with its quotes doubled."
	| s |
	s := aSymbolOrString asString.
	(s notEmpty and: [s allSatisfy: [:c | (c isLetter and: [c value < 128]) or: [c isDigit]]]) ifTrue: [^ '#' , s].
	^ '#''' , (s copyReplaceAll: '''' with: '''''') , ''''
]

{ #category : #writing }
TonelWriter class >> typeOf: aClass [
	"Tonel's #type, or nil when the format kind is the one aClass would inherit."
	| kind |
	kind := ClassBuilder kindOf: aClass.
	kind == (aClass superclass ifNil: [#fixed] ifNotNil: [:s | ClassBuilder inheritedKindFrom: s]) ifTrue: [^ nil].
	^ (Dictionary new
		at: #fixed put: 'normal'; at: #variable put: 'variable'; at: #bytes put: 'bytes'; at: #words32 put: 'words';
		at: #words16 put: 'words16'; at: #words64 put: 'words64'; at: #weak put: 'weak'; at: #ephemeron put: 'ephemeron';
		yourself) at: kind
]

{ #category : #writing }
TonelWriter class >> withoutLeadingBlanks: aString [
	| i |
	i := 1.
	[i <= aString byteSize and: [(aString scalarAt: i) isSeparator]] whileTrue: [i := i + (aString scalarSizeAt: i)].
	^ aString copyFrom: i to: aString byteSize
]
