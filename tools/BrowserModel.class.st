"The browser's model (module 9c): packages, the classes of the selected package as a tree by superclass or by category, the instance or class side, a class's method categories and selectors, and the source pane (a method, a class definition, a comment, or a template for a new method or class). Accepting the pane compiles the method, defines the class or sets the comment through the protocol; the target answers the files the change touched, which the client's transport writes into the project directory. A compile error is shown at its line. Senders and implementors fill a list of methods to go to. defineMethod:in:then: is the debugger's define-and-retry: a template for the missing method, and a block run when it compiles."
Class {
	#name : #BrowserModel,
	#superclass : #ToolModel,
	#instVars : [
		'hierarchy',
		'packages',
		'package',
		'byCategory',
		'className',
		'side',
		'categories',
		'category',
		'selectorsByCategory',
		'selector',
		'source',
		'sourceKind',
		'errorLine',
		'messages',
		'messagesTitle',
		'afterSave',
		'files',
		'indexByName',
		'sourceToken'
	],
	#category : #'Tools-Models'
}

{ #category : #accessing }
BrowserModel >> byCategory [
	^ byCategory == true
]

{ #category : #accessing }
BrowserModel >> categories [
	^ categories ifNil: [#()]
]

{ #category : #accessing }
BrowserModel >> category [
	^ category
]

{ #category : #accessing }
BrowserModel >> className [
	^ className
]

{ #category : #accessing }
BrowserModel >> errorLine [
	^ errorLine
]

{ #category : #accessing }
BrowserModel >> filesWritten [
	"The files the last accepted change touched (the target's answer)."
	^ files ifNil: [#()]
]

{ #category : #accessing }
BrowserModel >> hierarchy [
	^ hierarchy ifNil: [#()]
]

{ #category : #accessing }
BrowserModel >> isClassSide [
	^ side = 'class'
]

{ #category : #accessing }
BrowserModel >> messages [
	^ messages ifNil: [#()]
]

{ #category : #accessing }
BrowserModel >> messagesTitle [
	^ messagesTitle ifNil: ['']
]

{ #category : #accessing }
BrowserModel >> package [
	^ package
]

{ #category : #accessing }
BrowserModel >> packages [
	^ packages ifNil: [#()]
]

{ #category : #accessing }
BrowserModel >> selector [
	^ selector
]

{ #category : #accessing }
BrowserModel >> selectors [
	"The selected category's selectors, or every selector of the side, sorted."
	| out |
	selectorsByCategory isNil ifTrue: [^ #()].
	category isNil ifFalse: [^ ((selectorsByCategory at: category) ifNil: [#()]) asArray sorted: [:a :b | a <= b]].
	out := OrderedCollection new.
	selectorsByCategory keysAndValuesDo: [:k :v | out addAll: v].
	^ out asArray sort: [:a :b | a <= b]
]

{ #category : #accessing }
BrowserModel >> side [
	^ side ifNil: ['instance']
]

{ #category : #accessing }
BrowserModel >> source [
	^ source ifNil: ['']
]

{ #category : #accessing }
BrowserModel >> sourceKind [
	"#method, #definition, #comment, #newMethod, #newClass or #empty: what accepting the pane does."
	^ sourceKind ifNil: [#empty]
]

{ #category : #changes }
BrowserModel >> accept: aString [
	"Accept the source pane (Cmd-S): compile the method, define the class or set the comment."
	| k |
	k := self sourceKind.
	(k == #method or: [k == #newMethod]) ifTrue: [^ self compile: aString].
	(k == #definition or: [k == #newClass]) ifTrue: [^ self define: aString].
	k == #comment ifTrue: [
		^ self request: 'class.comment' args: {'className'. className. 'comment'. aString} then: [:r |
			files := r at: 'files'.
			source := aString.
			self status: 'comment of ' , className , ' saved']].
	self status: 'nothing to save'
]

{ #category : #changes }
BrowserModel >> compile: aString [
	| cat c |
	className isNil ifTrue: [^ self status: 'select a class first'].
	cat := category ifNil: [selector isNil ifTrue: ['as yet unclassified'] ifFalse: [nil]].
	c := className.
	self request: 'method.compile' args: {'className'. c. 'source'. aString. 'category'. cat. 'side'. self side}
		then: [:r | | sel after |
			files := r at: 'files'.
			sel := r at: 'selector'.
			errorLine := nil.
			source := aString.
			sourceKind := #method.
			selector := sel.
			self status: 'compiled ' , c , '>>' , sel.
			self changed: #source; changed: #selector.
			self loadSelectors.
			after := afterSave.
			afterSave := nil.
			after isNil ifFalse: [after cull: sel]]
]

{ #category : #changes }
BrowserModel >> define: aString [
	"Accept a class definition: 'Super subclass: #Name instanceVariableNames: ... classVariableNames: ... category: ...'."
	| spec |
	spec := [self parseDefinition: aString] on: Error do: [:e | ^ self status: 'not a class definition: ' , e messageText].
	self request: 'class.define' args: {'name'. spec at: 2. 'superclass'. spec first. 'instanceVariables'. spec at: 3. 'classVariables'. spec at: 4. 'category'. spec at: 5}
		then: [:r |
			files := r at: 'files'.
			className := spec at: 2.
			self status: 'defined ' , className.
			self refresh.
			self loadSelectors.
			self showDefinition]
]

{ #category : #changes }
BrowserModel >> defineMethod: aSelector in: aClassName then: aBlock [
	"The debugger's define-and-retry: aClassName's instance side selected, a template for aSelector in the pane; aBlock runs once it compiles."
	side := 'instance'.
	self selectClass: aClassName.
	selector := nil.
	afterSave := aBlock.
	self showSource: (self patternOf: aSelector) , (String with: Character lf) , (String with: Character tab) , '^ self' kind: #newMethod
]

{ #category : #changes }
BrowserModel >> failed: aString [
	"A compile error names its line: the pane shows it there."
	| i |
	i := aString indexOfSubstring: 'line '.
	i > 0 ifTrue: [ | n j |
		j := i + 5.
		n := 0.
		[j <= aString byteSize and: [(aString byteAt: j) between: 48 and: 57]] whileTrue: [
			n := n * 10 + ((aString byteAt: j) - 48).
			j := j + 1].
		n > 0 ifTrue: [errorLine := n. self changed: #errorLine]].
	super failed: aString
]

{ #category : #changes }
BrowserModel >> parseDefinition: aString [
	"{superclass. name. instance variables. class variables. category} of a definition."
	| s sup out k |
	s := Scanner on: aString.
	s next == #identifier ifFalse: [^ self error: 'a superclass first'].
	sup := s value.
	out := Array new: 5.
	out at: 1 put: sup.
	[(k := s next) == #end] whileFalse: [
		k == #keyword ifFalse: [^ self error: 'a keyword expected'].
		s value = 'subclass:' ifTrue: [
			s next == #symbol ifFalse: [^ self error: 'the name as a symbol'].
			out at: 2 put: s value asString].
		s value = 'instanceVariableNames:' ifTrue: [s next. out at: 3 put: s value].
		s value = 'classVariableNames:' ifTrue: [s next. out at: 4 put: s value].
		s value = 'category:' ifTrue: [s next. out at: 5 put: s value]].
	(out at: 2) isNil ifTrue: [^ self error: 'subclass: #Name'].
	^ out
]

{ #category : #changes }
BrowserModel >> removeClass [
	| c |
	className isNil ifTrue: [^ self].
	c := className.
	self request: 'class.remove' args: {'className'. c} then: [:r |
		files := r at: 'files'.
		self status: 'removed ' , c.
		self selectClass: nil.
		self refresh]
]

{ #category : #changes }
BrowserModel >> removeMethod [
	| sel |
	(className isNil or: [selector isNil]) ifTrue: [^ self].
	sel := selector.
	self request: 'method.remove' args: {'className'. className. 'selector'. sel. 'side'. self side} then: [:r |
		files := r at: 'files'.
		self status: 'removed ' , className , '>>' , sel.
		selector := nil.
		self loadSelectors.
		self showDefinition]
]

{ #category : #classes }
BrowserModel >> classNames [
	"The names of the classes the class pane shows: the selected package's, or all."
	^ (self visibleEntries collect: [:e | e at: 'name']) asArray
]

{ #category : #classes }
BrowserModel >> classOfId: anId [
	(anId isNil or: [anId < 1 or: [anId > self hierarchy size]]) ifTrue: [^ nil].
	^ (hierarchy at: anId) at: 'name'
]

{ #category : #classes }
BrowserModel >> classTree [
	"{id. parentId. title} triples for the class outline, parents first: by superclass (a class whose superclass is not shown is a root), or by category. A class's id is its index in the hierarchy; a category's is 100000 plus its index."
	| visible names out roots children cats add |
	visible := self visibleEntries.
	out := OrderedCollection new.
	self byCategory ifTrue: [
		cats := (visible collect: [:e | (e at: 'category') ifNil: ['Unclassified']]) asSet asArray sort: [:a :b | a <= b].
		cats doWithIndex: [:c :i |
			out add: {100000 + i. 0. c}.
			(visible select: [:e | ((e at: 'category') ifNil: ['Unclassified']) = c]) do: [:e |
				out add: {self idOfClass: (e at: 'name'). 100000 + i. e at: 'name'}]].
		^ out asArray].
	names := Set new.
	visible do: [:e | names add: (e at: 'name')].
	children := Dictionary new.
	roots := OrderedCollection new.
	visible do: [:e | | sup |
		sup := e at: 'superclass'.
		(sup notNil and: [names includes: sup])
			ifTrue: [(children at: sup ifAbsentPut: [OrderedCollection new]) add: (e at: 'name')]
			ifFalse: [roots add: (e at: 'name')]].
	add := nil.
	add := [:n :parent |
		out add: {self idOfClass: n. parent. n}.
		((children at: n ifAbsent: [#()]) asArray sort: [:a :b | a <= b]) do: [:c | add value: c value: (self idOfClass: n)]].
	(roots asArray sort: [:a :b | a <= b]) do: [:r | add value: r value: 0].
	^ out asArray
]

{ #category : #classes }
BrowserModel >> entryOf: aName [
	| i |
	i := self idOfClass: aName.
	^ i = 0 ifTrue: [nil] ifFalse: [hierarchy at: i]
]

{ #category : #classes }
BrowserModel >> idOfClass: aName [
	indexByName isNil ifTrue: [^ 0].
	^ indexByName at: aName ifAbsent: [0]
]

{ #category : #classes }
BrowserModel >> setHierarchy: anArray [
	"Every class's entry (name, superclass, category, package), and its index by name."
	hierarchy := anArray.
	indexByName := Dictionary new: anArray size.
	anArray doWithIndex: [:e :i | indexByName at: (e at: 'name') put: i]
]

{ #category : #classes }
BrowserModel >> visibleEntries [
	package isNil ifTrue: [^ self hierarchy].
	^ self hierarchy select: [:e | (e at: 'package') = package]
]

{ #category : #messages }
BrowserModel >> implementors [
	selector isNil ifTrue: [^ self].
	self request: 'method.implementors' args: {'selector'. selector} then: [:r |
		messagesTitle := 'implementors of ' , selector.
		messages := (r collect: [:c | c , '>>' , selector]) asArray.
		self changed: #messages]
]

{ #category : #messages }
BrowserModel >> selectMessage: aString [
	"'Foo>>bar' or 'Foo class>>bar' from the messages list: go there."
	| i cls sel |
	i := aString indexOfSubstring: '>>'.
	i = 0 ifTrue: [^ self].
	cls := aString copyFrom: 1 to: i - 1.
	sel := aString copyFrom: i + 2 to: aString byteSize.
	(cls endsWith: ' class')
		ifTrue: [side := 'class'. cls := cls copyFrom: 1 to: cls byteSize - 6]
		ifFalse: [side := 'instance'].
	package := nil.
	self changed: #classes.
	self selectClass: cls.
	self selectSelector: sel
]

{ #category : #messages }
BrowserModel >> senders [
	selector isNil ifTrue: [^ self].
	self request: 'method.senders' args: {'selector'. selector} then: [:r |
		messagesTitle := 'senders of ' , selector.
		messages := r asArray.
		self changed: #messages]
]

{ #category : #selecting }
BrowserModel >> loadSelectors [
	| c |
	c := className.
	self request: 'class.selectors' args: {'className'. c. 'side'. self side} then: [:r |
		c = className ifTrue: [
			selectorsByCategory := r.
			categories := r keys asArray sorted: [:a :b | a <= b].
			self changed: #categories; changed: #selectors]]
]

{ #category : #selecting }
BrowserModel >> refresh [
	"The packages and the class tree from the target."
	self request: 'package.list' args: #() then: [:r |
		packages := r.
		self changed: #packages].
	self request: 'class.hierarchy' args: #() then: [:r |
		self setHierarchy: r.
		self changed: #classes]
]

{ #category : #selecting }
BrowserModel >> selectCategory: aName [
	category := aName.
	selector := nil.
	self changed: #selectors
]

{ #category : #selecting }
BrowserModel >> selectClass: aName [
	"A class: its categories and selectors, and its definition in the source pane."
	className := aName.
	category := nil.
	selector := nil.
	selectorsByCategory := nil.
	categories := #().
	self changed: #class; changed: #categories; changed: #selectors.
	aName isNil ifTrue: [^ self showSource: '' kind: #empty].
	self loadSelectors.
	self showDefinition
]

{ #category : #selecting }
BrowserModel >> selectPackage: aName [
	package := aName.
	self selectClass: nil.
	self changed: #classes
]

{ #category : #selecting }
BrowserModel >> selectSelector: aSelector [
	"A method: its source in the pane."
	| t |
	selector := aSelector.
	self changed: #selector.
	aSelector isNil ifTrue: [^ self showDefinition].
	t := self nextSourceToken.
	self request: 'method.source' args: {'className'. className. 'selector'. aSelector. 'side'. self side} then: [:r |
		(t = sourceToken and: [selector = aSelector]) ifTrue: [
			self status: (r at: 'class') , '>>' , aSelector , ((r at: 'author') ifNil: [''] ifNotNil: [:a | '  (' , a , ')']).
			self showSource: (r at: 'source') kind: #method]]
]

{ #category : #selecting }
BrowserModel >> selectorsLoaded [
	"Whether the selected class's selectors came (a class may have none)."
	^ selectorsByCategory notNil
]

{ #category : #selecting }
BrowserModel >> toggleByCategory [
	byCategory := self byCategory not.
	self changed: #classes
]

{ #category : #selecting }
BrowserModel >> toggleSide [
	side := self isClassSide ifTrue: ['instance'] ifFalse: ['class'].
	self changed: #side.
	className isNil ifFalse: [self selectClass: className]
]

{ #category : #source }
BrowserModel >> definitionText: aDefinition [
	"A class definition as the browser shows and accepts it."
	^ String streamContents: [:s |
		s nextPutAll: ((aDefinition at: 'superclass') ifNil: ['nil']); nextPutAll: ' subclass: #'; nextPutAll: (aDefinition at: 'name'); lf;
			tab; nextPutAll: 'instanceVariableNames: '''; nextPutAll: (self words: (aDefinition at: 'instanceVariables')); nextPutAll: ''''; lf;
			tab; nextPutAll: 'classVariableNames: '''; nextPutAll: (self words: (aDefinition at: 'classVariables')); nextPutAll: ''''; lf;
			tab; nextPutAll: 'category: '''; nextPutAll: ((aDefinition at: 'category') ifNil: ['']); nextPutAll: '''']
]

{ #category : #source }
BrowserModel >> newClassTemplate [
	self showSource: (String streamContents: [:s |
		s nextPutAll: 'Object subclass: #NameOfClass'; lf;
			tab; nextPutAll: 'instanceVariableNames: '''''; lf;
			tab; nextPutAll: 'classVariableNames: '''''; lf;
			tab; nextPutAll: 'category: '''; nextPutAll: (package ifNil: ['Unclassified']); nextPutAll: ''''])
		kind: #newClass
]

{ #category : #source }
BrowserModel >> newMethodTemplate [
	className isNil ifTrue: [^ self status: 'select a class first'].
	selector := nil.
	self changed: #selector.
	self showSource: 'messageSelectorAndArgumentNames' , (String with: Character lf) , (String with: Character tab) , '"comment stating purpose of message"' kind: #newMethod
]

{ #category : #source }
BrowserModel >> nextSourceToken [
	"A new token for the pane: only the reply to the last request for it is shown."
	sourceToken := (sourceToken ifNil: [0]) + 1.
	^ sourceToken
]

{ #category : #source }
BrowserModel >> patternOf: aSelector [
	"A message pattern for aSelector with argument names (anObject, arg2, ...)."
	| parts |
	(aSelector includes: $:) ifFalse: [
		((aSelector byteAt: 1) between: 65 and: 122) ifTrue: [^ aSelector].
		^ aSelector , ' anObject'].
	parts := (aSelector splitOn: ':') reject: [:p | p isEmpty].
	^ String streamContents: [:s |
		parts doWithIndex: [:p :i |
			i > 1 ifTrue: [s space].
			s nextPutAll: p; nextPutAll: ': '; nextPutAll: (i = 1 ifTrue: ['anObject'] ifFalse: ['arg' , i printString])]]
]

{ #category : #source }
BrowserModel >> showComment [
	| t |
	className isNil ifTrue: [^ self].
	t := self nextSourceToken.
	self request: 'class.definition' args: {'className'. className} then: [:d |
		t = sourceToken ifTrue: [self showSource: ((d at: 'comment') ifNil: ['']) kind: #comment]]
]

{ #category : #source }
BrowserModel >> showDefinition [
	| c t |
	c := className.
	c isNil ifTrue: [^ self].
	t := self nextSourceToken.
	self request: 'class.definition' args: {'className'. c} then: [:d |
		(t = sourceToken and: [c = className and: [selector isNil]]) ifTrue: [self showSource: (self definitionText: d) kind: #definition]]
]

{ #category : #source }
BrowserModel >> showSource: aString kind: aSymbol [
	"What the pane shows from now on; a reply to an earlier request for the pane (a definition still on its way when a template is shown) is dropped."
	self nextSourceToken.
	source := aString.
	sourceKind := aSymbol.
	errorLine := nil.
	self changed: #source
]

{ #category : #source }
BrowserModel >> words: anArrayOrNil [
	anArrayOrNil isNil ifTrue: [^ ''].
	^ anArrayOrNil inject: '' into: [:a :w | a isEmpty ifTrue: [w] ifFalse: [a , ' ' , w]]
]
