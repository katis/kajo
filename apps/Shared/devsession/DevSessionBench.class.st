"Module 9c's scripted developer session (docs/modules/developer-ui.md, Measurements), run by the macOS shell's mode=devsession in a development image: the tools open on the image's own socket, the browser is populated (the class tree pushed whole and on demand, a package's selectors in a table pushed whole and on demand), classes and methods are selected, a method compiled, a test class run, an error raised that opens a debugger, two steps, and a fix that restarts the frame. Each step waits for what the tools show (polled by timer events, never a wait in the UI) and is timed; at the end a transcript line 'devsession: done <json>' carries the steps and the client's request round trips by kind. startTyping: opens a method in a browser and asks the shell to type into it ('devsession: type <handle>')."
Class {
	#name : #DevSessionBench,
	#superclass : #Object,
	#classInstVars : [
		'client',
		'browser',
		'steps',
		'stepName',
		'stepStart',
		'queue',
		'failure',
		'package',
		'measureWindow'
	],
	#category : #'Devsession'
}

{ #category : #session }
DevSessionBench >> failingStep [
	"The session's error: missingPart is not defined; the debugger steps twice and saves a fix."
	| a |
	a := self missingPart.
	a := self twice: a.
	a := self twice: a.
	^ a
]

{ #category : #session }
DevSessionBench >> twice: x [
	^ x
]

{ #category : #running }
DevSessionBench class >> begin: aName [
	stepName := aName.
	stepStart := Smalltalk microsecondClock
]

{ #category : #running }
DevSessionBench class >> end [
	"The step's time recorded, then the next step."
	self record.
	self next
]

{ #category : #running }
DevSessionBench class >> fail: aString [
	failure := stepName displayString , ': ' , aString.
	queue := OrderedCollection new.
	self finish
]

{ #category : #running }
DevSessionBench class >> next [
	queue isEmpty ifTrue: [^ self finish].
	queue removeFirst value
]

{ #category : #running }
DevSessionBench class >> when: aCondition then: aBlock [
	"aBlock once aCondition holds, polled every 5 ms by timer events (30 s at most)."
	self when: aCondition then: aBlock until: Smalltalk microsecondClock + 30000000
]

{ #category : #running }
DevSessionBench class >> when: aCondition then: aBlock until: aDeadline [
	([aCondition value] on: Error do: [:e | false]) ifTrue: [^ aBlock value].
	Smalltalk microsecondClock > aDeadline ifTrue: [^ self fail: 'timed out'].
	UIEventLoop after: 5 do: [self when: aCondition then: aBlock until: aDeadline]
]

{ #category : #running }
DevSessionBench class >> finish [
	"The steps and the request round trips by kind (count, p50 and p99 in microseconds) on the transcript."
	| o byKind lat |
	o := JsonObject new.
	o at: 'failure' put: failure.
	o at: 'steps' put: steps asArray.
	byKind := Dictionary new.
	client isNil ifFalse: [client latencies do: [:l | (byKind at: l first ifAbsentPut: [OrderedCollection new]) add: l last]].
	lat := JsonObject new.
	(byKind keys asArray sort: [:a :b | a <= b]) do: [:k | | v |
		v := (byKind at: k) asArray sort: [:a :b | a <= b].
		lat at: k put: {v size. v at: (v size + 1 // 2). v at: ((v size * 99 + 99) // 100 min: v size). v last}].
	o at: 'requests' put: lat.
	Transcript show: 'devsession: done ' , (Json write: o); cr; flush
]

{ #category : #session }
DevSessionBench class >> start: aSocketPath package: aPackage [
	"The scripted session, from the shell (main-affine): its steps run from events."
	steps := OrderedCollection new.
	failure := nil.
	package := aPackage.
	DevTools openLocal: aSocketPath project: nil.
	client := DevTools local.
	browser := (DevTools windowsOf: BrowserWindow) first model.
	queue := OrderedCollection new.
	queue add: [self populatePush]; add: [self populateOnDemand]; add: [self treeOnly: #push]; add: [self treeOnly: #onDemand];
		add: [self selectorsPush]; add: [self selectorsOnDemand];
		add: [self selectClasses]; add: [self compile]; add: [self runTests]; add: [self raiseError];
		add: [self stepOnce]; add: [self stepOnce]; add: [self fixAndProceed].
	self begin: 'open'.
	self when: [client isOpen and: [browser hierarchy size > 0]] then: [self end].
	^ true
]

{ #category : #session }
DevSessionBench class >> populatePush [
	"The class tree: class.hierarchy, then the whole tree pushed to the outline."
	BrowserWindow treeForm: #push.
	self populate: 'populate.push'
]

{ #category : #session }
DevSessionBench class >> populateOnDemand [
	"The same with the roots pushed and the rest given as the outline asks."
	BrowserWindow treeForm: #onDemand.
	self populate: 'populate.onDemand'
]

{ #category : #session }
DevSessionBench class >> populate: aName [
	| before |
	before := client latencies size.
	self begin: aName.
	browser refresh.
	self when: [(client latencies size - before) >= 2] then: [
		BrowserWindow treeForm: #push.
		self end]
]

{ #category : #session }
DevSessionBench class >> treeOnly: aForm [
	"The class tree given to the outline again, the model's tree and the view calls only (no request)."
	BrowserWindow treeForm: aForm.
	self begin: 'tree.' , aForm.
	browser view update: #classes.
	BrowserWindow treeForm: #push.
	self end
]

{ #category : #session }
DevSessionBench class >> selectors: aBlock [
	"package.selectors of the session's package, then aBlock with them."
	client request: 'package.selectors' args: {'name'. package} then: aBlock else: [:e | self fail: e]
]

{ #category : #session }
DevSessionBench class >> measureTable [
	measureWindow isNil ifTrue: [
		measureWindow := Window new.
		measureWindow title: 'Selectors'.
		measureWindow x: 1000 y: 60 width: 360 height: 500.
		measureWindow add: TableView new.
		measureWindow subviews first x: 0 y: 0 width: 360 height: 500.
		measureWindow subviews first columns: #('Selector').
		measureWindow show].
	^ measureWindow subviews first
]

{ #category : #session }
DevSessionBench class >> selectorsPush [
	"Every selector of the package in a table, pushed whole."
	| t |
	t := self measureTable.
	self begin: 'selectors.request'.
	self selectors: [:all |
		self record.
		self begin: 'selectors.push.' , all size printString.
		t list: all.
		self end]
]

{ #category : #session }
DevSessionBench class >> selectorsOnDemand [
	"The same table given a row count, and pages of 100 as it shows them."
	| t all pages |
	t := self measureTable.
	pages := 0.
	self selectors: [:r |
		all := r.
		t onPage: [:first |
			pages := pages + 1.
			t rows: ((first to: (first + 99 min: all size)) collect: [:i | {all at: i}]) asArray at: first].
		self begin: 'selectors.onDemand.' , all size printString.
		t rowCount: all size.
		self when: [pages > 0] then: [self end]]
]

{ #category : #session }
DevSessionBench class >> selectClasses [
	"Ten classes of the package, a method of each, one after the other."
	| names picks |
	names := browser hierarchy select: [:e | (e at: 'package') = package].
	picks := (1 to: 10) collect: [:i | (names at: (i * names size // 11 max: 1)) at: 'name'].
	self begin: 'select.10'.
	self selectEach: picks asOrderedCollection
]

{ #category : #session }
DevSessionBench class >> selectEach: aCollection [
	| c |
	aCollection isEmpty ifTrue: [^ self end].
	c := aCollection removeFirst.
	browser selectClass: c.
	self when: [browser className = c and: [browser selectors notEmpty]] then: [ | sel |
		sel := browser selectors first.
		browser selectSelector: sel.
		self when: [browser selector = sel and: [browser sourceKind == #method]] then: [self selectEach: aCollection]]
]

{ #category : #session }
DevSessionBench class >> compile [
	self begin: 'compile'.
	browser selectClass: 'DevSessionBench'.
	self when: [browser className = 'DevSessionBench' and: [browser sourceKind == #definition]] then: [
		browser newMethodTemplate.
		browser accept: 'benchAnswer
	^ 42'.
		self when: [browser selector = 'benchAnswer' and: [browser status beginsWith: 'compiled']] then: [self end]]
]

{ #category : #session }
DevSessionBench class >> runTests [
	| runner |
	runner := (DevTools openTestRunner: client) model.
	self begin: 'test.run'.
	runner runFilter: 'StringTest>>*'.
	self when: [runner isRunning not and: [runner results notEmpty]] then: [self end]
]

{ #category : #session }
DevSessionBench class >> debugger [
	^ DevTools debuggers isEmpty ifTrue: [nil] ifFalse: [DevTools debuggers last model]
]

{ #category : #session }
DevSessionBench class >> raiseError [
	"A doit that fails: the debugger opens with its frames."
	| w |
	w := WorkspaceModel new client: client; yourself.
	self begin: 'error.debugger'.
	w doIt: 'DevSessionBench new failingStep'.
	self when: [self debugger notNil and: [self debugger frames notEmpty]] then: [self end]
]

{ #category : #session }
DevSessionBench class >> stepOnce [
	| d n |
	d := self debugger.
	n := client latencies size.
	self begin: 'step'.
	d step: 'over'.
	self when: [d state == #stopped and: [d reason = 'step' and: [client latencies size > (n + 1)]]] then: [self end]
]

{ #category : #session }
DevSessionBench class >> fixAndProceed [
	"Save a fix of failingStep in its frame: compiled, the frame restarted, the Process goes on."
	| d i |
	d := self debugger.
	i := 0.
	d frames doWithIndex: [:f :k | (i = 0 and: [(f at: 'method') = 'DevSessionBench>>failingStep']) ifTrue: [i := k]].
	i = 0 ifTrue: [^ self fail: 'no frame of failingStep'].
	self begin: 'fix.proceed'.
	d selectFrame: i.
	d save: 'failingStep
	^ 42'.
	self when: [d state == #running] then: [self end]
]

{ #category : #typing }
DevSessionBench class >> startTyping: aSocketPath [
	"Open a method in a browser, put the insertion point at its end and ask the shell to type into it."
	steps := OrderedCollection new.
	failure := nil.
	DevTools openLocal: aSocketPath project: nil.
	client := DevTools local.
	browser := (DevTools windowsOf: BrowserWindow) first model.
	self when: [client isOpen] then: [
		browser selectClass: 'DevSessionBench'.
		self when: [browser className = 'DevSessionBench' and: [browser selectors includes: 'twice:']] then: [
			browser selectSelector: 'twice:'.
			self when: [browser sourceKind == #method] then: [ | v n |
				v := browser view sourceView.
				n := v text byteSize.
				v call: 'focus' with: #().
				v selectFrom: n + 1 to: n.
				Transcript show: 'devsession: type ' , v handle printString; cr; flush]]].
	^ true
]

{ #category : #running }
DevSessionBench class >> record [
	"The step's time, its name and when it began (the shell counts the frames missed in it)."
	steps add: {stepName. Smalltalk microsecondClock - stepStart. stepStart}
]
