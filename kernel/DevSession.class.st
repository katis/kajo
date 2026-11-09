"One connection's session of the development protocol (module 9b): who the client is (developer, agent:<name>: the author of every change it makes), the package its changes belong to, and the objects it holds by handle (evaluate and inspect answer handles; the client releases them, the session's end releases the rest). Every request is a method of this class marked <devProtocol>: adding a request is adding a method, here or as an extension from another package."
Class {
	#name : #DevSession,
	#superclass : #Object,
	#instVars : [
		'conn',
		'client',
		'sessionPackage',
		'handles',
		'nextHandle'
	],
	#category : #'Kernel-Development'
}

{ #category : #accessing }
DevSession >> client [
	^ client
]

{ #category : #accessing }
DevSession >> conn [
	^ conn
]

{ #category : #accessing }
DevSession >> info [
	"session.open's answer: the protocol, the client, the package, the image kind, the number of requests, and every standing stop as its process.stopped event said (the development answers: a client that connects after a Process stopped, with no client or another one, finds it here and opens its debugger)."
	| o |
	o := JsonObject new.
	o at: 'protocol' put: 1; at: 'client' put: client; at: 'package' put: sessionPackage;
		at: 'image' put: (Smalltalk isReleaseImage ifTrue: ['release'] ifFalse: ['development']);
		at: 'requests' put: DevProtocol describe size;
		at: 'stopped' put: ((Debugger stops sort: [:a :b | a process id <= b process id]) collect: [:s | s notedSummary]).
	^ o
]

{ #category : #accessing }
DevSession >> package [
	^ sessionPackage
]

{ #category : #accessing }
DevSession >> setConn: anInteger client: aString package: aPackageOrNil [
	conn := anInteger.
	client := aString.
	sessionPackage := aPackageOrNil.
	handles := Dictionary new.
	nextHandle := 1
]

{ #category : #handles }
DevSession >> describe: anObject [
	"A value for the client: its printString (at most 4000 bytes), its class and a handle to it (nil, Booleans, small Integers and Characters need none)."
	| o |
	o := JsonObject new.
	o at: 'value' put: (self printOf: anObject); at: 'class' put: anObject class name.
	(anObject isNil or: [anObject == true or: [anObject == false or: [anObject isInteger or: [anObject isCharacter]]]])
		ifFalse: [o at: 'handle' put: (self handleOf: anObject)].
	^ o
]

{ #category : #handles }
DevSession >> handleOf: anObject [
	"The handle the session keeps anObject under (one per object)."
	handles keysAndValuesDo: [:k :v | v == anObject ifTrue: [^ k]].
	nextHandle := nextHandle + 1.
	handles at: nextHandle put: anObject.
	^ nextHandle
]

{ #category : #handles }
DevSession >> objectAt: aHandle [
	^ handles at: aHandle ifAbsent: [self error: 'no object under handle ' , aHandle printString]
]

{ #category : #handles }
DevSession >> printOf: anObject [
	| s |
	s := [anObject printString] on: Error do: [:e | '<printString failed: ' , e messageText , '>'].
	^ s byteSize > 4000 ifTrue: [(s copyFrom: 1 to: 4000) , '...'] ifFalse: [s]
]

{ #category : #helpers }
DevSession >> behaviorNamed: aName side: aSide [
	| c |
	aName isNil ifTrue: [^ self error: 'which class?'].
	c := Smalltalk at: aName asSymbol ifAbsent: [^ self error: 'no class ' , aName].
	^ aSide = 'class' ifTrue: [c class] ifFalse: [c]
]

{ #category : #helpers }
DevSession >> filesFor: aBehavior [
	"What the client writes into its project directory after a change of aBehavior's class (module 9b): the session's package's file of the class, {path. text}, or the file to remove when the package has nothing of it any more. The path is relative to the project directory: <Tag>/<Name>.class.st for a class with a tag (tags as subdirectories)."
	| c pkg o |
	c := aBehavior theNonMetaClass.
	pkg := self packageFor: c.
	o := JsonObject new.
	o at: 'path' put: (TonelWriter pathOf: c package: pkg).
	((Smalltalk packageOf: c) = pkg or: [TonelWriter hasMethodsOf: c package: pkg])
		ifTrue: [o at: 'text' put: (TonelWriter sourceOf: c package: pkg)]
		ifFalse: [o at: 'remove' put: true].
	^ Array with: o
]

{ #category : #helpers }
DevSession >> filesFor: aClass movedFrom: anOldPathOrNil [
	"filesFor: aClass, and the file at anOldPathOrNil to remove when the class's file is no longer there (its tag or its package changed: the file moves, as a removed class's file goes)."
	| files o |
	files := self filesFor: aClass.
	(anOldPathOrNil isNil or: [anOldPathOrNil = (files first at: 'path')]) ifTrue: [^ files].
	o := JsonObject new.
	o at: 'path' put: anOldPathOrNil; at: 'remove' put: true.
	^ files , (Array with: o)
]

{ #category : #helpers }
DevSession >> namesOf: aStringOrArray [
	aStringOrArray isNil ifTrue: [^ ''].
	aStringOrArray isString ifTrue: [^ aStringOrArray].
	^ aStringOrArray inject: '' into: [:a :n | a isEmpty ifTrue: [n asString] ifFalse: [a , ' ' , n asString]]
]

{ #category : #helpers }
DevSession >> packageFor: aClass [
	"The package whose files a change of aClass writes: the session's, else the class's own."
	^ sessionPackage ifNil: [Smalltalk packageOf: aClass]
]

{ #category : #helpers }
DevSession >> stopOf: aProcessId [
	^ (Debugger stopWithId: aProcessId) ifNil: [self error: 'the Process ' , aProcessId printString , ' is not stopped']
]

{ #category : #'requests-browse' }
DevSession >> classDefinition: className [
	"A class's definition: its superclass, instance variables, class variables, class-side instance variables, format kind, comment, package and tag (nil when it has none; tags as subdirectories)."
	<devProtocol>
	| c d o |
	c := self behaviorNamed: className side: nil.
	d := Smalltalk definitionOf: c.
	o := JsonObject new.
	o at: 'name' put: c name; at: 'superclass' put: (c superclass ifNotNil: [:s | s name]);
		at: 'instanceVariables' put: (d instVarNames collect: [:n | n asString]);
		at: 'classVariables' put: (c classVarNames collect: [:n | n asString]);
		at: 'classInstanceVariables' put: (d classInstVarNames collect: [:n | n asString]);
		at: 'kind' put: d kind; at: 'comment' put: d comment;
		at: 'package' put: d package; at: 'tag' put: (d tag ifNotNil: [:t | t asString]).
	^ o
]

{ #category : #'requests-browse' }
DevSession >> classHierarchy [
	"Every class with its superclass, package and tag (nil when it has none), sorted by name: the browser's class tree in one request (module 9c; the tag since tags as subdirectories)."
	<devProtocol>
	^ (Smalltalk allClasses collect: [:c | | o |
		o := JsonObject new.
		o at: 'name' put: c name asString; at: 'superclass' put: (c superclass ifNotNil: [:s | s name asString]);
			at: 'package' put: (Smalltalk packageOf: c); at: 'tag' put: ((Smalltalk tagOf: c) ifNotNil: [:t | t asString]).
		o]) asArray sort: [:a :b | (a at: 'name') <= (b at: 'name')]
]

{ #category : #'requests-browse' }
DevSession >> classList: package tag: tag [
	"The names of the classes, of one package when it is given and of one of its tags when that is given too, sorted."
	<devProtocol>
	^ ((Smalltalk allClasses select: [:c |
		(package isNil or: [(Smalltalk packageOf: c) = package])
			and: [tag isNil or: [(Smalltalk tagOf: c) notNil and: [(Smalltalk tagOf: c) asString = tag asString]]]])
		collect: [:c | c name asString]) asArray sort: [:a :b | a <= b]
]

{ #category : #'requests-browse' }
DevSession >> classSelectors: className side: side [
	"A class's selectors by category (side: instance, the default, or class)."
	<devProtocol>
	| b o |
	b := self behaviorNamed: className side: side.
	o := JsonObject new.
	(b organization keys asArray sort: [:x :y | x <= y]) do: [:cat |
		o at: cat put: ((b organization at: cat) collect: [:s | s asString]) asArray].
	^ o
]

{ #category : #'requests-browse' }
DevSession >> classTonel: className [
	"The session's package's Tonel file of a class: {path. text}, what sources are written as."
	<devProtocol>
	^ (self filesFor: (self behaviorNamed: className side: nil)) first
]

{ #category : #'requests-browse' }
DevSession >> methodBytecodes: className selector: selector side: side [
	"A method's bytecodes, literals (printStrings) and pc-to-source map ({pc. start. end} per send)."
	<devProtocol>
	| m o |
	m := (self behaviorNamed: className side: side) compiledMethodAt: selector asSymbol.
	o := JsonObject new.
	o at: 'bytecodes' put: m bytecodes asArray; at: 'literals' put: (m literals collect: [:l | self printOf: l]);
		at: 'sourceMap' put: m sourceMapEntries.
	^ o
]

{ #category : #'requests-browse' }
DevSession >> methodImplementors: selector [
	"The classes that implement a selector ('Foo' or 'Foo class')."
	<devProtocol>
	| sym out |
	sym := selector asSymbol.
	out := OrderedCollection new.
	Smalltalk allClasses do: [:c |
		(c includesSelector: sym) ifTrue: [out add: c name asString].
		(c class includesSelector: sym) ifTrue: [out add: c name , ' class']].
	^ out asArray sort: [:a :b | a <= b]
]

{ #category : #'requests-browse' }
DevSession >> methodSenders: selector [
	"The methods that send a selector ('Class>>selector'; special sends such as + are not literals and are not found)."
	<devProtocol>
	| sym out found |
	sym := selector asSymbol.
	out := OrderedCollection new.
	found := nil.
	found := [:m | (m literals anySatisfy: [:l | l == sym]) or: [m blockMethods anySatisfy: [:b | found value: b]]].
	Smalltalk allClasses do: [:c |
		(Array with: c with: c class) do: [:b |
			b methodsDo: [:m | (found value: m) ifTrue: [out add: m printString]]]].
	^ out asArray sort: [:a :b | a <= b]
]

{ #category : #'requests-browse' }
DevSession >> methodSource: className selector: selector side: side [
	"A method's source, category, package and author."
	<devProtocol>
	| b sel m o |
	b := self behaviorNamed: className side: side.
	sel := selector asSymbol.
	m := b compiledMethodAt: sel.
	o := JsonObject new.
	o at: 'class' put: b name; at: 'selector' put: sel; at: 'category' put: (b categoryOf: sel);
		at: 'package' put: (Smalltalk packageOfSelector: sel in: b); at: 'author' put: (Smalltalk authorOfSelector: sel in: b);
		at: 'source' put: (Smalltalk sourceOf: m).
	^ o
]

{ #category : #'requests-browse' }
DevSession >> packageList [
	"The packages of the image's classes and methods, sorted (module 9c)."
	<devProtocol>
	^ Smalltalk packageNames
]

{ #category : #'requests-browse' }
DevSession >> packageSelectors: name [
	"Every method of a package, 'Class>>selector' or 'Class class>>selector', sorted (module 9c: the browser's list of a package's methods)."
	<devProtocol>
	| out |
	out := OrderedCollection new.
	Smalltalk allClasses do: [:c |
		(Array with: c with: c class) do: [:b |
			b methodsDo: [:m |
				(Smalltalk packageOfSelector: m selector in: b) = name
					ifTrue: [out add: b name asString , '>>' , m selector asString]]]].
	^ out asArray sort: [:a :b | a <= b]
]

{ #category : #'requests-browse' }
DevSession >> packageTags: name [
	"The tags of a package's classes, sorted (every package's when name is nil; tags as subdirectories: a tag is the subdirectory of the package's directory its classes' files are in)."
	<devProtocol>
	^ Smalltalk tagsOf: name
]

{ #category : #'requests-browse' }
DevSession >> protocolDescribe [
	"Every request this target serves: its kind, arguments, comment, and whether an error in it stops for the debugger. Adding a <devProtocol> method of DevSession adds a request."
	<devProtocol>
	^ DevProtocol describe
]

{ #category : #'requests-change' }
DevSession >> changed: aBehavior [
	| o |
	o := JsonObject new.
	o at: 'class' put: aBehavior theNonMetaClass name; at: 'files' put: (self filesFor: aBehavior).
	^ o
]

{ #category : #'requests-change' }
DevSession >> classComment: className comment: comment [
	"Set a class's comment; answers the files to write."
	<devProtocol>
	| c |
	c := self behaviorNamed: className side: nil.
	c comment: comment.
	^ self changed: c
]

{ #category : #'requests-change' }
DevSession >> classDefine: name superclass: superclass instanceVariables: instanceVariables classVariables: classVariables package: package tag: tag [
	"Define a class, or redefine one of the same superclass and kind (instanceVariables and classVariables: blank-separated names or an Array), in package (the session's when not given) under tag (none when not given: the class's file is at the package's root); an existing class given neither keeps its package and tag. A class whose tag or package changes moves its file: the answer's files hold the new one to write and the old one to remove. Answers the class and the files to write."
	<devProtocol>
	| c sup old existing |
	sup := self behaviorNamed: (superclass ifNil: ['Object']) side: nil.
	existing := Smalltalk at: name asSymbol ifAbsent: [nil].
	old := existing ifNotNil: [:e | TonelWriter pathOf: e package: (self packageFor: e)].
	c := sup subclass: name asSymbol instanceVariableNames: (self namesOf: instanceVariables)
		classVariableNames: (self namesOf: classVariables)
		package: ((existing notNil and: [package isNil and: [tag isNil]])
			ifTrue: [nil]
			ifFalse: [package ifNil: [sessionPackage ifNil: [(existing ifNotNil: [:e | Smalltalk packageOf: e]) ifNil: [ClassBuilder defaultPackage]]]])
		tag: tag.
	^ (JsonObject new) at: 'class' put: c name; at: 'files' put: (self filesFor: c movedFrom: old); yourself
]

{ #category : #'requests-change' }
DevSession >> classRemove: className [
	"Remove a class (refused while it has subclasses, instances, or a method that names it). Answers the files to remove."
	<devProtocol>
	| c o path |
	c := self behaviorNamed: className side: nil.
	path := TonelWriter pathOf: c package: (self packageFor: c).
	Smalltalk removeClass: c.
	o := JsonObject new.
	o at: 'path' put: path; at: 'remove' put: true.
	^ (JsonObject new) at: 'class' put: className; at: 'files' put: (Array with: o); yourself
]

{ #category : #'requests-change' }
DevSession >> methodCompile: className source: source category: category side: side [
	"Compile and install a method (side: instance, the default, or class); its package is the session's; an agent's session marks it with <author: #'agent:<name>'> (TonelWriter source:author:, the development answers), a developer's compiles the source as written; the source is kept in the form its file reads back as. Answers the selector and the files to write."
	<devProtocol>
	| b sel o |
	b := self behaviorNamed: className side: side.
	sel := b compile: (TonelWriter source: (TonelWriter canonicalSource: source) author: client) classified: category.
	o := self changed: b.
	o at: 'selector' put: sel.
	^ o
]

{ #category : #'requests-change' }
DevSession >> methodRemove: className selector: selector side: side [
	"Remove a method. Answers the files to write."
	<devProtocol>
	| b |
	b := self behaviorNamed: className side: side.
	(b includesSelector: selector asSymbol) ifFalse: [^ self error: b name , ' has no method ' , selector].
	b removeSelector: selector asSymbol.
	^ self changed: b
]

{ #category : #'requests-evaluate' }
DevSession >> evaluate: source receiver: receiver [
	"Run a doit (statements, temporaries allowed) with self the object under the handle receiver, or nil. Answers its value described: printString, class, handle. An unhandled error stops the request's Process for the debugger and the reply says so (process.stopped)."
	<devProtocol>
	<debuggable>
	| object method |
	object := receiver isNil
		ifTrue: [nil]
		ifFalse: [[self objectAt: receiver] on: Error do: [:e | DevProtocol finishActiveWithError: e messageText. ^ nil]].
	method := [(Compiler compileDoIt: source in: object class) makeMethodIn: object class]
		on: Error do: [:e | DevProtocol finishActiveWithError: e printString. ^ nil].
	^ self describe: (method valueWithReceiver: object arguments: #())
]

{ #category : #'requests-evaluate' }
DevSession >> inspect: handle [
	"The object under a handle: its class, printString, named slots and its first 100 indexed ones, each described."
	<devProtocol>
	| obj o slots names |
	obj := self objectAt: handle.
	o := self describe: obj.
	slots := OrderedCollection new.
	names := obj class allInstVarNames.
	names doWithIndex: [:n :i |
		slots add: ((self describe: ([obj slotAt: i] on: Error do: [:e | nil])) at: 'name' put: n asString; yourself)].
	(obj isString or: [obj isSymbol]) ifFalse: [
		1 to: (([obj basicSize] on: Error do: [:e | 0]) min: 100) do: [:k | true ifTrue: [
			slots add: ((self describe: ([obj basicAt: k] on: Error do: [:e | nil])) at: 'name' put: k printString; yourself)]]].
	o at: 'slots' put: slots asArray.
	^ o
]

{ #category : #'requests-evaluate' }
DevSession >> inspectRelease: handle [
	"Let go of the object under a handle."
	<devProtocol>
	handles removeKey: handle ifAbsent: [nil].
	^ true
]

{ #category : #'requests-processes' }
DevSession >> processEvaluate: process frame: frame source: source [
	"Run a doit in a frame of a stopped Process (frame 1 is where it stopped): self is the frame's receiver, its arguments and temporaries are variables the doit reads and assigns. Answers the value described."
	<devProtocol>
	(self stopOf: process) command: #evaluate:frame:replyTo:session: arguments: (Array with: source with: (frame ifNil: [1]))
		replyTo: (DevProtocol takeReplyOf: ProcessorScheduler activeProcess).
	^ nil
]

{ #category : #'requests-processes' }
DevSession >> processFrames: process [
	"The frames of a stopped Process, from where it stopped down: method, pc, receiver, variables, source and the range the pc is at."
	<devProtocol>
	(self stopOf: process) command: #framesReplyTo:session: arguments: #()
		replyTo: (DevProtocol takeReplyOf: ProcessorScheduler activeProcess).
	^ nil
]

{ #category : #'requests-processes' }
DevSession >> processList [
	"Every live Process: id, state, priority, whether it is main-affine, and why it is stopped when it is."
	<devProtocol>
	^ (ProcessorScheduler primAllProcesses reject: [:p | p isNil]) asArray collect: [:p | | o stop |
		o := JsonObject new.
		o at: 'process' put: p id; at: 'state' put: p state; at: 'priority' put: p priority; at: 'main' put: p isMainAffine.
		stop := Debugger stopOf: p.
		stop isNil ifFalse: [o at: 'stopped' put: stop reason; at: 'error' put: stop errorText].
		o]
]

{ #category : #'requests-processes' }
DevSession >> processProceed: process value: value [
	"Let a stopped Process go on: an error's signal answers value (nil when absent); a step or suspend stop goes on where it stopped."
	<devProtocol>
	(self stopOf: process) command: #proceed:replyTo:session: arguments: (Array with: value)
		replyTo: (DevProtocol takeReplyOf: ProcessorScheduler activeProcess).
	^ nil
]

{ #category : #'requests-processes' }
DevSession >> processRestart: process frame: frame [
	"Restart a frame of a stopped Process: the frames above it unwind (their ensure: blocks run) and its send runs again, finding the method's current version. Answers once the unwinding has run (unwound: true), or, past Process unwindBudgetMs, where it still stands (unwound: false, cutOff)."
	<devProtocol>
	^ (self stopOf: process) await: #restart:replyTo:session: arguments: (Array with: frame)
]

{ #category : #'requests-processes' }
DevSession >> processRetrySend: process [
	"For a Process stopped at doesNotUnderstand:, send the message again to the same receiver with the same arguments (after the method was defined). Answers as process.restart does."
	<devProtocol>
	^ (self stopOf: process) await: #retrySendReplyTo:session: arguments: #()
]

{ #category : #'requests-processes' }
DevSession >> processStep: process mode: mode frame: frame [
	"Step a stopped Process (mode: into, over or out; frame: which frame, 1 by default) and answer at once; the Process stops again (process.stopped, reason step) where the step ends."
	<devProtocol>
	(self stopOf: process) command: #step:frame:replyTo:session: arguments: (Array with: (mode ifNil: ['over']) with: (frame ifNil: [1]))
		replyTo: (DevProtocol takeReplyOf: ProcessorScheduler activeProcess).
	^ nil
]

{ #category : #'requests-processes' }
DevSession >> processSuspend: process [
	"Stop a running or waiting Process for the debugger where it stands (process.stopped, reason suspended)."
	<devProtocol>
	| p |
	p := Debugger processWithId: process.
	p isNil ifTrue: [^ self error: 'no Process ' , process printString].
	^ Debugger suspend: p
]

{ #category : #'requests-processes' }
DevSession >> processTerminate: process [
	"End a Process, running its ensure: blocks: a stopped one unwinds itself, another is interrupted to (Process>>terminate); at most about Process unwindBudgetMs, then it is ended where it stands. Answers whether its unwinding ran to its end (unwound) and, when it was cut off, where it stood (cutOff)."
	<devProtocol>
	| stop p |
	stop := Debugger stopWithId: process.
	stop isNil ifFalse: [^ stop terminate].
	p := Debugger processWithId: process.
	p isNil ifTrue: [^ self error: 'no Process ' , process printString].
	^ DebugStop unwound: p terminateReporting process: p
]

{ #category : #'requests-tests' }
DevSession >> testRun: filter tag: tag [
	"Run the TestCases whose name matches filter (and that carry tag), streaming the test events; answers the number of failures and errors."
	<devProtocol>
	| failures o |
	failures := TestRunner new runFilter: filter tag: tag.
	o := JsonObject new.
	o at: 'failuresAndErrors' put: failures.
	^ o
]

{ #category : #'instance creation' }
DevSession class >> conn: anInteger client: aString package: aPackageOrNil [
	^ self new setConn: anInteger client: aString package: aPackageOrNil
]
