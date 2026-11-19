"The browser's model against a fake target (module 9c): the packages and the class tree by superclass and grouped by tag (tags as subdirectories), a class's categories, selectors and definition, a method's source, compiling (the files of the reply kept, a compile error at its line), a class definition parsed and sent, senders, removal, and define-and-retry."
Class {
	#name : #BrowserModelTest,
	#superclass : #TestCase,
	#instVars : [
		'compiled'
	]
}

{ #category : #diagnostics }
BrowserModelTest >> testABurstOfEventsMakesOneRequest [
	"Five events naming the shown class while its request is outstanding: no more requests until the reply, then one that covers them all."
	| c m |
	c := self diagnosedFake: [:args | self circleDiagnostics].
	m := BrowserModel new client: c; yourself.
	m selectClass: 'Circle'.
	self assert: (self diagnosticsSent: c) equals: 1.
	c hold: true.
	c diagnosticsChanged: #('Circle>>radius').
	self assert: (self diagnosticsSent: c) equals: 2.
	4 timesRepeat: [c diagnosticsChanged: #('Circle>>radius')].
	self assert: (self diagnosticsSent: c) equals: 2.
	c hold: false.
	c answer: c lastId with: self circleDiagnostics.
	self assert: (self diagnosticsSent: c) equals: 3.
	self assert: c pendingCount equals: 0
]

{ #category : #diagnostics }
BrowserModelTest >> testAFailedRequestIsDroppedAndAskedAgainLater [
	"A request that times out (a whole check slower than the client's timeout on a slow target) shows nothing and says nothing; the next class selection asks again."
	| c m |
	c := self diagnosedFake: [:args | self circleDiagnostics].
	c hold: true.
	m := BrowserModel new client: c; yourself.
	m selectClass: 'Circle'.
	c fireRequestTimer: (c requestTimers detect: [:t | (t at: 3) = (c sentKinds indexOf: 'diagnostics')]).
	self assert: (m diagnosticsFailure includesSubstring: 'no reply').
	self deny: (m status includesSubstring: 'no reply').
	self assert: m diagnostics isEmpty.
	c hold: false.
	m selectClass: 'Circle'.
	self assert: (self diagnosticsSent: c) equals: 2.
	self assert: m diagnosticsFailure isNil
]

{ #category : #diagnostics }
BrowserModelTest >> testAMethodHoldsItsDiagnosticsAndTheStatusSaysThem [
	| c m |
	c := self diagnosedFake: [:args | self circleDiagnostics].
	m := BrowserModel new client: c; yourself.
	m selectClass: 'Circle'.
	self assert: (self diagnosticsSent: c) equals: 1.
	self assert: ((c sent detect: [:s | s first = 'diagnostics']) last at: 'className') equals: 'Circle'.
	self assert: ((c sent detect: [:s | s first = 'diagnostics']) last at: 'selector') isNil.
	self assert: (m diagnosedSelectors asArray sort: [:a :b | a <= b]) equals: #('drawOn:' 'radius').
	m selectSelector: 'radius'.
	self assert: m diagnostics size equals: 2.
	self assert: m status equals: '2 type diagnostics: Integer does not understand #foo'.
	m selectSelector: 'radius:'.
	self assert: m diagnostics isEmpty.
	self assert: m status equals: 'Circle>>radius:'.
	m selectSelector: 'drawOn:'.
	self assert: m diagnostics size equals: 1.
	self assert: m status equals: '1 type diagnostic: argument 1 of #drawOn: is Integer, expected Canvas'.
	"One request per class selection: the methods of the class ask nothing."
	self assert: (self diagnosticsSent: c) equals: 1
]

{ #category : #diagnostics }
BrowserModelTest >> testASignatureWithoutAMethodShowsItsDiagnostics [
	"A signature without a method (Types 2) comes from method.source with signature true: the browser shows it, its diagnostics marked, and does not accept it."
	| c m |
	c := FakeDevClient on: [:kind :args |
		kind = 'diagnostics'
			ifTrue: [FakeDevClient diagnostics: {FakeDevClient diagnostic: 'signature' class: 'Circle' side: 'instance' selector: 'at:' line: 1 start: nil end: nil text: 'no class answers Circle>>at:'}]
			ifFalse: [kind = 'method.source'
				ifTrue: [JsonObject new at: 'class' put: 'Circle'; at: 'selector' put: 'at:'; at: 'source' put: 'at: index <Integer> ^<Object>'; at: 'signature' put: true; yourself]
				ifFalse: [self answer: kind args: args]]].
	m := BrowserModel new client: c; yourself.
	m selectClass: 'Circle'.
	m selectSelector: 'at:'.
	self assert: m sourceKind equals: #signature.
	self assert: m diagnostics size equals: 1.
	self assert: m status equals: '1 type diagnostic: no class answers Circle>>at:'.
	m accept: 'at: index <Integer> ^<Object>'.
	self deny: (c sentKinds includes: 'method.compile').
	self assert: (m status includesSubstring: 'signature')
]

{ #category : #diagnostics }
BrowserModelTest >> testATargetWithoutTheCheckerIsAskedOnceAndSaysNothing [
	"A target without the Types package answers the protocol's own refusal: asked once in the session, the browser then works as before this module, with nothing on its status line."
	| c m |
	c := self diagnosedFake: [:args | FakeDevClient refuseDiagnostics].
	m := BrowserModel new client: c; yourself.
	m refresh.
	m selectClass: 'Circle'.
	m selectSelector: 'radius'.
	self assert: m status equals: 'Circle>>radius'.
	m selectClass: 'Square'.
	m toggleSide.
	m selectClass: 'Circle'.
	m selectSelector: 'radius'.
	c diagnosticsChanged: #('Circle>>radius').
	self assert: (self diagnosticsSent: c) equals: 1.
	self assert: (c refuses: 'diagnostics').
	self assert: m diagnostics isEmpty.
	self assert: m status equals: 'Circle>>radius'.
	"A new session asks once again."
	c sessionOpened.
	m selectClass: 'Circle'.
	self assert: (self diagnosticsSent: c) equals: 2
]

{ #category : #diagnostics }
BrowserModelTest >> testAnAcceptAsksAgainAndTheFirstEditDropsTheMarks [
	| c m n |
	n := 0.
	c := self diagnosedFake: [:args |
		n := n + 1.
		n = 1
			ifTrue: [self circleDiagnostics]
			ifFalse: [FakeDevClient diagnostics: {FakeDevClient diagnostic: 'returnType' class: 'Circle' side: 'instance' selector: 'area' line: 2 start: 7 end: 10 text: 'answers Integer where String is declared'}]].
	m := BrowserModel new client: c; yourself.
	m selectClass: 'Circle'.
	m selectSelector: 'radius'.
	self assert: m diagnostics size equals: 2.
	m sourceEdited.
	self assert: m marks equals: #dropped.
	self assert: m diagnostics isEmpty.
	m sourceEdited.
	self assert: m diagnostics isEmpty.
	c hold: true.
	m accept: 'area
	^ 3'.
	c answer: c lastId with: ((JsonObject new) at: 'selector' put: 'area'; at: 'files' put: #(); yourself).
	"Accepted: the marks wait for the reply that follows."
	self assert: m marks equals: #awaiting.
	self assert: m diagnostics isEmpty.
	self assert: (self diagnosticsSent: c) equals: 2.
	c hold: false.
	c answer: c lastId - 1 with: (self answer: 'class.selectors' args: nil).
	c answer: c lastId with: (FakeDevClient diagnostics: {FakeDevClient diagnostic: 'returnType' class: 'Circle' side: 'instance' selector: 'area' line: 2 start: 7 end: 10 text: 'answers Integer where String is declared'}).
	self assert: m marks equals: #shown.
	self assert: m diagnostics size equals: 1.
	self assert: m status equals: '1 type diagnostic: answers Integer where String is declared'
]

{ #category : #diagnostics }
BrowserModelTest >> testAnEventNamingTheShownClassAsksAgainAndAnotherDoesNot [
	| c m |
	c := self diagnosedFake: [:args | self circleDiagnostics].
	m := BrowserModel new client: c; yourself.
	m selectClass: 'Circle'.
	m selectSelector: 'radius'.
	c diagnosticsChanged: #('Square>>side' 'Circles>>radius').
	self assert: (self diagnosticsSent: c) equals: 1.
	c diagnosticsChanged: #('Circle>>radius').
	self assert: (self diagnosticsSent: c) equals: 2.
	c diagnosticsChanged: #('Circle class>>new').
	self assert: (self diagnosticsSent: c) equals: 3.
	"A malformed event asks nothing and is no error."
	c event: 'diagnostics.changed' with: {'methods'. 7}.
	c event: 'diagnostics.changed' with: #().
	self assert: (self diagnosticsSent: c) equals: 3.
	"Cut short: it may name anything."
	c event: 'diagnostics.changed' with: {'methods'. #('Square>>side'). 'truncated'. true}.
	self assert: (self diagnosticsSent: c) equals: 4.
	self assert: m diagnostics size equals: 2
]

{ #category : #diagnostics }
BrowserModelTest >> testTheDiagnosticsListOfAClassAndOfTheImage [
	| c m n |
	n := 0.
	c := self diagnosedFake: [:args |
		(args at: 'className') isNil
			ifTrue: [n := n + 1. FakeDevClient diagnostics: ((self circleDiagnostics at: 'diagnostics') , {FakeDevClient diagnostic: 'dnu' class: 'Square' side: 'class' selector: 'unit' line: 2 start: 4 end: 8 text: 'Nil does not understand #x'}) , (n > 1 ifTrue: [#()] ifFalse: [{FakeDevClient diagnostic: 'annotation' class: 'Canvas' side: 'instance' selector: nil line: 0 start: nil end: nil text: 'unknown class Pen'}])]
			ifFalse: [self circleDiagnostics]].
	m := BrowserModel new client: c; yourself.
	m refresh.
	m listDiagnostics: 'Circle'.
	self assert: m isListing.
	self assert: m messagesTitle equals: 'type diagnostics of Circle: 3'.
	self assert: m messages equals: #('Circle>>radius' 'Circle>>radius' 'Circle>>drawOn:').
	self assert: m messageColumns equals: #('Class' 'Side' 'Selector' 'Diagnostic').
	self assert: m messageRows first equals: #('Circle' 'instance' 'radius' 'Integer does not understand #foo').
	m selectMessageAt: 1.
	self assert: m className equals: 'Circle'.
	self assert: m selector equals: 'radius'.
	self assert: m diagnostics size equals: 2.
	"The image: count and rows equal the request's; a class-side method and a class's own type go where they are."
	m listDiagnostics: nil.
	self assert: m messagesTitle equals: 'type diagnostics of the image: 5'.
	self assert: m messages size equals: 5.
	self assert: (m messages at: 4) equals: 'Square class>>unit'.
	self assert: (m messages at: 5) equals: 'Canvas'.
	self assert: (m messageRows at: 5) equals: #('Canvas' 'instance' '' 'unknown class Pen').
	m selectMessageAt: 4.
	self assert: m className equals: 'Square'.
	self assert: m isClassSide.
	"The list follows the event: the image's list asks again whatever the event names."
	c diagnosticsChanged: #('Canvas>>paint').
	self assert: m messagesTitle equals: 'type diagnostics of the image: 4'.
	self assert: m messages size equals: 4.
	"Senders replace the list: it no longer follows."
	m sendersOf: 'radius'.
	self deny: m isListing.
	self assert: m messageColumns equals: #('Method').
	n := (c sentKinds select: [:k | k = 'diagnostics']) size.
	c diagnosticsChanged: #('Canvas>>paint').
	self assert: (c sentKinds select: [:k | k = 'diagnostics']) size equals: n
]

{ #category : #diagnostics }
BrowserModelTest >> testTheListOnATargetWithoutTheCheckerSaysSo [
	| c m |
	c := self diagnosedFake: [:args | FakeDevClient refuseDiagnostics].
	m := BrowserModel new client: c; yourself.
	m listDiagnostics: nil.
	self assert: (m status includesSubstring: 'unknown request diagnostics').
	m listDiagnostics: nil.
	self assert: m status equals: 'the target has no type checker'.
	self assert: (self diagnosticsSent: c) equals: 1
]

{ #category : #helpers }
BrowserModelTest >> answer: kind args: args [
	| o |
	kind = 'package.list' ifTrue: [^ #('Kernel' 'Sample')].
	kind = 'class.hierarchy' ifTrue: [^ {
		self entry: 'Object' superclass: nil package: 'Kernel' tag: 'Objects'.
		self entry: 'Shape' superclass: 'Object' package: 'Sample' tag: 'Shapes'.
		self entry: 'Circle' superclass: 'Shape' package: 'Sample' tag: 'Shapes'.
		self entry: 'Square' superclass: 'Shape' package: 'Sample' tag: 'Shapes'.
		self entry: 'Canvas' superclass: 'Object' package: 'Sample' tag: nil}].
	kind = 'class.selectors' ifTrue: [
		o := JsonObject new.
		o at: 'accessing' put: #('radius' 'radius:'); at: 'drawing' put: #('drawOn:').
		^ o].
	kind = 'class.definition' ifTrue: [
		o := JsonObject new.
		o at: 'name' put: (args at: 'className'); at: 'superclass' put: 'Shape'; at: 'instanceVariables' put: #('radius');
			at: 'classVariables' put: #(); at: 'package' put: 'Sample'; at: 'tag' put: 'Shapes'; at: 'comment' put: 'A circle.'.
		^ o].
	kind = 'method.source' ifTrue: [
		o := JsonObject new.
		o at: 'class' put: (args at: 'className'); at: 'selector' put: (args at: 'selector'); at: 'source' put: 'radius
	^ radius'; at: 'author' put: nil.
		^ o].
	kind = 'method.compile' ifTrue: [
		((args at: 'source') includesSubstring: '^ ^') ifTrue: [^ self error: 'CompileError: line 2: an expression expected'].
		compiled := args.
		o := JsonObject new.
		o at: 'selector' put: 'area'; at: 'files' put: {(JsonObject new) at: 'path' put: 'Circle.class.st'; at: 'text' put: '...'; yourself}.
		^ o].
	kind = 'class.define' ifTrue: [
		compiled := args.
		^ (JsonObject new) at: 'class' put: (args at: 'name');
			at: 'files' put: {(JsonObject new) at: 'path' put: ((args at: 'tag') ifNil: [''] ifNotNil: [:t | t , '/']) , (args at: 'name') , '.class.st'; at: 'text' put: '...'; yourself};
			yourself].
	kind = 'method.senders' ifTrue: [^ #('Canvas>>paint' 'Circle>>drawOn:')].
	kind = 'method.remove' ifTrue: [^ (JsonObject new) at: 'files' put: #(); yourself].
	^ nil
]

{ #category : #helpers }
BrowserModelTest >> circleDiagnostics [
	"Circle's diagnostics as a class-scope request answers them: two of radius (within its source, 'radius', a line feed, a tab, '^ radius'), one of drawOn: without a range."
	^ FakeDevClient diagnostics: {
		FakeDevClient diagnostic: 'dnu' class: 'Circle' side: 'instance' selector: 'radius' line: 2 start: 10 end: 16 text: 'Integer does not understand #foo'.
		FakeDevClient diagnostic: 'returnType' class: 'Circle' side: 'instance' selector: 'radius' line: 2 start: 8 end: 16 text: 'answers Integer where String is declared'.
		FakeDevClient diagnostic: 'argType' class: 'Circle' side: 'instance' selector: 'drawOn:' line: 0 start: nil end: nil text: 'argument 1 of #drawOn: is Integer, expected Canvas'}
]

{ #category : #helpers }
BrowserModelTest >> diagnosedFake: aBlock [
	"A fake target whose diagnostics request is answered by aBlock (its arguments), the rest as answer:args: answers."
	^ FakeDevClient on: [:kind :args | kind = 'diagnostics' ifTrue: [aBlock value: args] ifFalse: [self answer: kind args: args]]
]

{ #category : #helpers }
BrowserModelTest >> diagnosticsSent: aFake [
	^ (aFake sentKinds select: [:k | k = 'diagnostics']) size
]

{ #category : #helpers }
BrowserModelTest >> entry: aName superclass: aSuper package: aPackage tag: aTag [
	| o |
	o := JsonObject new.
	o at: 'name' put: aName; at: 'superclass' put: aSuper; at: 'package' put: aPackage; at: 'tag' put: aTag.
	^ o
]

{ #category : #helpers }
BrowserModelTest >> fake [
	^ FakeDevClient on: [:kind :args | self answer: kind args: args]
]

{ #category : #tests }
BrowserModelTest >> testAClassDefinitionIsParsedAndSent [
	| m |
	m := BrowserModel new client: self fake; yourself.
	m refresh.
	m selectPackage: 'Sample'.
	m newClassTemplate.
	self assert: m sourceKind equals: #newClass.
	self assert: (m source includesSubstring: 'package: #Sample').
	self deny: (m source includesSubstring: 'category:').
	m accept: 'Shape subclass: #Triangle
	instanceVariableNames: ''a b c''
	classVariableNames: ''''
	package: #Sample
	tag: #''New-Shapes'''.
	self assert: (compiled at: 'name') equals: 'Triangle'.
	self assert: (compiled at: 'superclass') equals: 'Shape'.
	self assert: (compiled at: 'instanceVariables') equals: 'a b c'.
	self assert: (compiled at: 'package') equals: 'Sample'.
	self assert: (compiled at: 'tag') equals: 'New-Shapes'.
	self assert: (compiled includesKey: 'category') not.
	self assert: (m filesWritten first at: 'path') equals: 'New-Shapes/Triangle.class.st'.
	m accept: 'Shape subclass: #Triangle
	instanceVariableNames: ''a b c''
	classVariableNames: ''''
	package: ''Sample'''.
	self assert: (compiled at: 'tag') isNil.
	self assert: (m filesWritten first at: 'path') equals: 'Triangle.class.st'.
	m accept: 'Shape subclass: #Triangle
	instanceVariableNames: ''''
	classVariableNames: ''''
	category: ''Sample-Shapes'''.
	self assert: (m status includesSubstring: 'category: is gone').
	m accept: 'not a definition'.
	self assert: (m status includesSubstring: 'not a class definition')
]

{ #category : #tests }
BrowserModelTest >> testAClassItsSelectorsAndAMethod [
	| m |
	m := BrowserModel new client: self fake; yourself.
	m refresh.
	m selectClass: 'Circle'.
	self assert: m categories equals: #('accessing' 'drawing').
	self assert: m selectors equals: #('drawOn:' 'radius' 'radius:').
	self assert: m sourceKind equals: #definition.
	self assert: (m source beginsWith: 'Shape subclass: #Circle').
	self assert: (m source includesSubstring: 'instanceVariableNames: ''radius''').
	self assert: (m source endsWith: 'package: #Sample
	tag: #Shapes').
	m selectCategory: 'accessing'.
	self assert: m selectors equals: #('radius' 'radius:').
	m selectSelector: 'radius'.
	self assert: m sourceKind equals: #method.
	self assert: (m source beginsWith: 'radius')
]

{ #category : #tests }
BrowserModelTest >> testCompilingAndACompileErrorAtItsLine [
	| m |
	m := BrowserModel new client: self fake; yourself.
	m refresh.
	m selectClass: 'Circle'.
	m newMethodTemplate.
	m accept: 'area
	^ radius * radius'.
	self assert: (compiled at: 'className') equals: 'Circle'.
	self assert: (compiled at: 'category') equals: 'as yet unclassified'.
	self assert: m selector equals: 'area'.
	self assert: (m filesWritten first at: 'path') equals: 'Circle.class.st'.
	self assert: m errorLine isNil.
	m accept: 'area
	^ ^'.
	self assert: m errorLine equals: 2.
	self assert: (m status includesSubstring: 'line 2')
]

{ #category : #tests }
BrowserModelTest >> testDefineAMissingMethodThenRetry [
	| m retried |
	m := BrowserModel new client: self fake; yourself.
	m refresh.
	m defineMethod: 'scaleBy:' in: 'Circle' then: [:sel | retried := sel].
	self assert: m className equals: 'Circle'.
	self assert: m sourceKind equals: #newMethod.
	self assert: (m source beginsWith: 'scaleBy: anObject').
	m accept: m source.
	self assert: retried equals: 'area'
]

{ #category : #tests }
BrowserModelTest >> testPatterns [
	| m |
	m := BrowserModel new.
	self assert: (m patternOf: 'foo') equals: 'foo'.
	self assert: (m patternOf: '+') equals: '+ anObject'.
	self assert: (m patternOf: 'at:put:') equals: 'at: anObject put: arg2'
]

{ #category : #tests }
BrowserModelTest >> testSendersAndGoingToOne [
	| m |
	m := BrowserModel new client: self fake; yourself.
	m refresh.
	m selectClass: 'Circle'.
	m selectSelector: 'radius'.
	m senders.
	self assert: m messagesTitle equals: 'senders of radius'.
	self assert: m messages equals: #('Canvas>>paint' 'Circle>>drawOn:').
	m selectMessage: 'Canvas>>paint'.
	self assert: m className equals: 'Canvas'.
	self assert: m selector equals: 'paint'
]

{ #category : #tests }
BrowserModelTest >> testTheClassTreeBySuperclassAndByTag [
	| m tree |
	m := BrowserModel new client: self fake; yourself.
	m refresh.
	self assert: m packages equals: #('Kernel' 'Sample').
	m selectPackage: 'Sample'.
	self assert: m classNames asArray equals: #('Shape' 'Circle' 'Square' 'Canvas').
	tree := m classTree.
	self assert: (tree collect: [:t | t at: 3]) asArray equals: #('Canvas' 'Shape' 'Circle' 'Square').
	self assert: ((tree at: 3) at: 2) equals: (m idOfClass: 'Shape').
	self assert: ((tree at: 1) at: 2) equals: 0.
	m toggleByTag.
	self assert: m byTag.
	tree := m classTree.
	self assert: (tree collect: [:t | t at: 3]) asArray equals: #('Shapes' 'Shape' 'Circle' 'Square' 'Canvas').
	self assert: ((tree at: 2) at: 2) equals: (tree at: 1) first.
	self assert: (m classOfId: (tree at: 2) first) equals: 'Shape'.
	self assert: ((tree at: 5) at: 2) equals: 0.
	self assert: (m classOfId: (tree at: 5) first) equals: 'Canvas'
]
