"The image's classes as Tonel files (module 8e), in the canonical form kernel/ is written in: the class comment (quotes doubled), the class definition with the keys #name, #superclass, #instVars, #classVars, #classInstVars (each only when not empty), #category and #type (only when the format kind is not the one the superclass's gives), a tab before each key and two before each name; then the methods, instance side before class side, grouped by category with the categories sorted, the selectors sorted within each, each one as `{ #category : ... }` on its line and `Class >> pattern [body]` where pattern and body are the recorded source split after the message pattern. A body that does not start on a line of its own is put on one, indented by a tab; anything else of the source is written as recorded. A method of another package than its class's is written in that package's <Class>.extension.st, `Extension { #name : ... }` and the methods (module 9b), and a method a development session made carries its author in the method's metadata, `{ #category : ..., #author : ... }`."
Class {
	#name : #TonelWriter,
	#superclass : #Object,
	#category : #'Kernel-System'
}

{ #category : #files }
TonelWriter class >> fileNameOf: aClass package: aName [
	"<Name>.class.st when aClass belongs to the package, else <Name>.extension.st (module 9b)."
	^ (Smalltalk packageOf: aClass) = aName
		ifTrue: [aClass name , '.class.st']
		ifFalse: [aClass name , '.extension.st']
]

{ #category : #files }
TonelWriter class >> write: aClass into: aDirectory [
	"Write aClass's file, <Name>.class.st, into aDirectory (a path under the directory the VM was opened with; '' for that directory itself)."
	^ self write: aClass package: (Smalltalk packageOf: aClass) into: aDirectory
]

{ #category : #files }
TonelWriter class >> write: aClass package: aName into: aDirectory [
	"Write aClass's file for the package aName into aDirectory: its class file when it belongs to the package, else the package's extension file of it."
	| name path |
	name := self fileNameOf: aClass package: aName.
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
	entries add: '#category : ' , (self ston: (d category ifNil: [#Unclassified])).
	type := self typeOf: aClass.
	type ifNotNil: [:t | entries add: '#type : #' , t].
	out := out , 'Class {' , lf.
	entries doWithIndex: [:e :i |
		out := out , (String tab) , e , (i < entries size ifTrue: [',' , lf] ifFalse: [lf])].
	^ out , '}' , lf
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
	| lf src pattern body author parts |
	lf := String lf.
	src := Smalltalk sourceOf: (aBehavior compiledMethodAt: aSelector).
	src isNil ifTrue: [^ self error: aBehavior name , '>>' , aSelector , ' has no source'].
	author := Smalltalk authorOfSelector: aSelector in: aBehavior.
	parts := self patternAndBodyOf: src.
	pattern := parts first.
	body := parts last.
	^ lf , '{ #category : ' , (self ston: aCategory) , (author ifNil: [''] ifNotNil: [:a | ', #author : ' , (self ston: a)]) , ' }' , lf
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
