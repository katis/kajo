"Module 9c's scripted developer session (docs/modules/developer-ui.md, Measurements), run by the macOS shell's mode=devsession in a development image: the tools open on the image's own socket, the browser is populated (the class tree pushed whole and on demand, a package's selectors in a table pushed whole and on demand), classes and methods are selected, a method compiled, a test class run, an error raised that opens a debugger, two steps, and a fix that restarts the frame. Each step waits for what the tools show (polled by timer events, never a wait in the UI) and is timed; at the end a transcript line 'devsession: done <json>' carries the steps and the client's request round trips by kind. startTyping: opens a method in a browser and asks the shell to type into it ('devsession: type <handle>'). Module 9d: startRemote:package:project: runs the session against another target (the phone, DevSessionTarget in its image) and both forms end with two more steps: a missing method defined from the debugger and the send retried (its file lands in the project), and a dropped link (the shell closes the client's sockets on 'devsession: drop') with a Process stopped in the target, after which the client reconnects, the requests pending at the loss are answered, the stopped Process is still there and its debugger shows its frames again."
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
		'measureWindow',
		'targetClass',
		'workspace'
	]
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
	client isNil ifFalse: [
		o at: 'reconnects' put: client reconnects; at: 'retried' put: client retried.
		o at: 'outages' put: (client outages collect: [:x | x asArray]) asArray].
	Transcript show: 'devsession: done ' , (Json write: o); cr; flush
]

{ #category : #session }
DevSessionBench class >> start: aSocketPath package: aPackage [
	"The scripted session, from the shell (main-affine): its steps run from events."
	steps := OrderedCollection new.
	failure := nil.
	package := aPackage.
	targetClass := 'DevSessionBench'.
	DevTools openLocal: aSocketPath project: nil.
	client := DevTools local.
	^ self run: OrderedCollection new
]

{ #category : #session }
DevSessionBench class >> startRemote: aTarget package: aPackage project: aDirectoryOrNil [
	"Module 9d: the same session against aTarget (a target's name or address: the phone), its changes written into aDirectoryOrNil. DevSessionTarget's failingStep is put back first and its undefinedStep removed, so one target serves several sessions."
	steps := OrderedCollection new.
	failure := nil.
	package := aPackage.
	targetClass := 'DevSessionTarget'.
	client := DevTools openTarget: aTarget name: 'remote' project: aDirectoryOrNil.
	client isNil ifTrue: [Transcript show: 'devsession: done {"failure":"no transport"}'; cr; flush. ^ false].
	^ self run: (OrderedCollection new add: [self reset]; yourself)
]

{ #category : #session }
DevSessionBench class >> startApp: aTarget package: aPackage class: aClassName selector: aSelector source: aSource probe: aProbe expect: aString project: aDirectoryOrNil [
	"Module 11a: the tools against a running app (a generated app's development build, by its Bonjour name or address): open the browser on the app's class, show the class side's aSelector, accept aSource for it, and evaluate aProbe in a workspace until it answers aString: the change is live in the running app. Its file is written into aDirectoryOrNil."
	| w |
	steps := OrderedCollection new.
	failure := nil.
	package := aPackage.
	targetClass := aClassName.
	client := DevTools openTarget: aTarget name: 'app' project: aDirectoryOrNil.
	client isNil ifTrue: [Transcript show: 'devsession: done {"failure":"no transport"}'; cr; flush. ^ false].
	browser := (DevTools windowsOf: BrowserWindow) first model.
	w := WorkspaceModel new client: client; yourself.
	queue := OrderedCollection new.
	queue add: [
		self begin: 'app.select'.
		browser selectClass: aClassName.
		browser isClassSide ifFalse: [browser toggleSide].
		self when: [browser className = aClassName and: [browser selectorsLoaded]] then: [
			browser selectSelector: aSelector.
			self when: [browser selector = aSelector and: [browser sourceKind == #method]] then: [self end]]].
	queue add: [
		self begin: 'app.compile'.
		browser accept: aSource.
		self when: [browser status beginsWith: 'compiled'] then: [self end]].
	queue add: [
		self begin: 'app.live'.
		w evaluate: aProbe then: [:r | nil].
		self when: [w lastResult notNil] then: [
			(w lastResult at: 'value') = aString printString
				ifTrue: [self end]
				ifFalse: [self fail: 'the probe answered ' , (w lastResult at: 'value')]]].
	self begin: 'open'.
	self when: [client isOpen and: [browser hierarchy size > 0]] then: [self end].
	^ true
]

{ #category : #session }
DevSessionBench class >> run: firstSteps [
	browser := (DevTools windowsOf: BrowserWindow) first model.
	queue := firstSteps.
	queue add: [self populatePush]; add: [self populateOnDemand]; add: [self treeOnly: #push]; add: [self treeOnly: #onDemand];
		add: [self selectorsPush]; add: [self selectorsOnDemand];
		add: [self selectClasses]; add: [self compile]; add: [self runTests]; add: [self raiseError];
		add: [self stepOnce]; add: [self stepOnce]; add: [self fixAndProceed]; add: [self defineAndRetry]; add: [self dropLink].
	self begin: 'open'.
	self when: [client isOpen and: [browser hierarchy size > 0]] then: [self end].
	^ true
]

{ #category : #session }
DevSessionBench class >> reset [
	"The target as a session expects it: failingStep fails again, undefinedStep is not there."
	| n |
	self begin: 'reset'.
	n := 0.
	client methodCompile: 'DevSessionTarget' source: DevSessionTarget originalFailingStep category: 'session' side: nil then: [:r | n := n + 1].
	client request: 'method.remove' args: {'className'. 'DevSessionTarget'. 'selector'. 'undefinedStep'} then: [:r | n := n + 1] else: [:e | n := n + 1].
	self when: [n = 2] then: [self end]
]

{ #category : #session }
DevSessionBench class >> defineAndRetry [
	"An error on the target stops its Process at a missing method; the debugger defines the method in a browser, the send is retried and the Process goes on; the method's file is written into the project."
	| w before d |
	w := WorkspaceModel new client: client; yourself.
	before := DevTools debuggers size.
	self begin: 'define.retry'.
	w doIt: 'DevSessionTarget new definedLater'.
	self when: [DevTools debuggers size > before and: [self debugger isDoesNotUnderstand and: [self debugger frames notEmpty]]] then: [
		d := self debugger.
		d defineMissingMethod.
		self when: [(DevTools windowsOf: BrowserWindow) last model sourceKind == #newMethod] then: [
			(DevTools windowsOf: BrowserWindow) last model accept: 'undefinedStep
	^ 41'.
			self when: [d state == #running] then: [self end]]]
]

{ #category : #session }
DevSessionBench class >> dropLink [
	"A Process stops in the target; the link drops (the shell closes the client's sockets) with two requests on their way; the client reconnects, both are answered, the stopped Process is still there and its debugger shows its frames again; then it is terminated."
	| w before d r frames hierarchy processes |
	w := WorkspaceModel new client: client; yourself.
	before := DevTools debuggers size.
	self begin: 'drop.stop'.
	w doIt: 'DevSessionTarget new stopForDrop'.
	self when: [DevTools debuggers size > before and: [self debugger frames notEmpty]] then: [
		d := self debugger.
		self record.
		self begin: 'drop.reconnect'.
		r := client reconnects.
		frames := (client latencies select: [:l | l first = 'process.frames']) size.
		Transcript show: 'devsession: drop'; cr; flush.
		client classHierarchy: [:h | hierarchy := h size].
		client processList: [:l | processes := l].
		self when: [client isOpen and: [client reconnects > r and: [hierarchy notNil and: [processes notNil]]]] then: [
			(processes anySatisfy: [:p | (p at: 'process') = d process and: [(p at: 'stopped') notNil]])
				ifFalse: [self fail: 'the stopped Process is gone after the reconnect']
				ifTrue: [
					self when: [d state == #stopped and: [(client latencies select: [:l | l first = 'process.frames']) size > frames]] then: [
						self record.
						self begin: 'drop.terminate'.
						d terminate.
						"Its reply (ended) and the process.resumed event (running) may come in either order."
						self when: [d state ~~ #stopped] then: [self end]]]]]
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
	self when: [browser className = c and: [browser selectorsLoaded]] then: [ | sel |
		browser selectors isEmpty
			ifTrue: [self selectEach: aCollection]
			ifFalse: [
				sel := browser selectors first.
				browser selectSelector: sel.
				self when: [browser selector = sel and: [browser sourceKind == #method]] then: [self selectEach: aCollection]]]
]

{ #category : #session }
DevSessionBench class >> compile [
	self begin: 'compile'.
	browser selectClass: targetClass.
	self when: [browser className = targetClass and: [browser sourceKind == #definition]] then: [
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
	w doIt: targetClass , ' new failingStep'.
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
	d frames doWithIndex: [:f :k | (i = 0 and: [(f at: 'method') = (targetClass , '>>failingStep')]) ifTrue: [i := k]].
	i = 0 ifTrue: [^ self fail: 'no frame of failingStep'].
	self begin: 'fix.proceed'.
	d selectFrame: i.
	d save: 'failingStep
	^ 42'.
	self when: [d state == #running] then: [self end]
]

{ #category : #instances }
DevSessionBench class >> checkInstances [
	"The discoverability follow-up's bar on this image, evaluated through the tools' own client (the local target is this image): after a collection, ToolWindow allSubInstances against DevTools windows, Class allSubInstances against the classes, String under a limit, SmallInteger's instances; the answer on a transcript line 'devsession: instances <printString>'."
	| w |
	w := WorkspaceModel new client: client; yourself.
	self begin: 'instances.check'.
	w evaluate: 'Smalltalk garbageCollect. {ToolWindow allSubInstances size. DevTools windows size. Class allSubInstances size. Smalltalk allClasses size. (String allInstances: 1000) size. String instanceCount. SmallInteger allInstances}'
		then: [:r | Transcript show: 'devsession: instances ' , (r at: 'value'); cr; flush].
	self when: [w lastResult notNil] then: [self end]
]

{ #category : #instances }
DevSessionBench class >> evaluateInstances: aCount in: aWorkspaceWindow [
	"Do it on the workspace's pane, by its own key action (as the Smalltalk menu's Do it runs it), aCount times, one step each, each waiting for its answer."
	| m before |
	aCount = 0 ifTrue: [^ self next].
	m := aWorkspaceWindow model.
	before := m lastResult.
	self begin: 'instances.eval'.
	aWorkspaceWindow textView selectFrom: 1 to: aWorkspaceWindow textView text byteSize.
	aWorkspaceWindow textView pressKey: 'cmd-d'.
	self when: [m lastResult notNil and: [m lastResult ~~ before]] then: [
		(m lastResult at: 'class') = 'SmallInteger' ifFalse: [^ self fail: 'the doit answered ' , (m lastResult at: 'value')].
		self record.
		self evaluateInstances: aCount - 1 in: aWorkspaceWindow]
]

{ #category : #instances }
DevSessionBench class >> startInstances: aSocketPath [
	"The discoverability follow-up's measurement: the tools on this image, the bar's instance checks, then a Workspace evaluating String allInstances: 100000 ten times by its Do it, each a step whose frames the shell counts. The doit answers the Array's size: an Array's printString is the whole Array printed (the protocol cuts it at 4000 bytes after), and every element's printString is a new String the next walk finds, so printing it doubled the work at every evaluation."
	steps := OrderedCollection new.
	failure := nil.
	DevTools openLocal: aSocketPath project: nil.
	client := DevTools local.
	browser := (DevTools windowsOf: BrowserWindow) first model.
	queue := OrderedCollection new.
	queue add: [self checkInstances].
	queue add: [ | w |
		w := DevTools openWorkspace: client.
		w textView text: '(String allInstances: 100000) size'.
		self evaluateInstances: 10 in: w].
	self begin: 'open'.
	self when: [client isOpen and: [browser hierarchy size > 0]] then: [self end].
	^ true
]

{ #category : #pointers }
DevSessionBench class >> checkPointers [
	"The pointersTo: follow-up's bar on this image, through the tools' own client: after a collection, a fresh object stored in one Array answers exactly that Array; the first tool window's holders include the Array of DevTools' windows collection; nil pointerCount (the worst case) finishes. The answer on a transcript line 'devsession: pointers <printString>'."
	| w |
	w := WorkspaceModel new client: client; yourself.
	self begin: 'pointers.check'.
	w evaluate: '| o a r t | Smalltalk garbageCollect. o := Object new. a := Array with: o. r := o pointersTo. t := DevTools windows first pointersTo. {r size. r first == a. t size. t identityIncludes: (DevTools windows slotAt: 1). nil pointerCount}'
		then: [:r | Transcript show: 'devsession: pointers ' , (r at: 'value'); cr; flush].
	self when: [w lastResult notNil] then: [self end]
]

{ #category : #pointers }
DevSessionBench class >> evaluate: aCount in: aWorkspaceWindow step: aName [
	"Do it on the workspace's pane by its own key action, aCount times, one step named aName each, each waiting for its answer (a SmallInteger)."
	| m before |
	aCount = 0 ifTrue: [^ self next].
	m := aWorkspaceWindow model.
	before := m lastResult.
	self begin: aName.
	aWorkspaceWindow textView selectFrom: 1 to: aWorkspaceWindow textView text byteSize.
	aWorkspaceWindow textView pressKey: 'cmd-d'.
	self when: [m lastResult notNil and: [m lastResult ~~ before]] then: [
		(m lastResult at: 'class') = 'SmallInteger' ifFalse: [^ self fail: 'the doit answered ' , (m lastResult at: 'value')].
		Transcript show: 'devsession: ' , aName , ' ' , (m lastResult at: 'value'); cr; flush.
		self record.
		self evaluate: aCount - 1 in: aWorkspaceWindow step: aName]
]

{ #category : #pointers }
DevSessionBench class >> startPointers: aSocketPath [
	"The pointersTo: follow-up's measurement: the tools on this image, the bar's pointer checks, a Workspace evaluating (DevTools windows first pointersTo: 100000) size ten times (a window is held by a few objects) and then, in the same window so that no window opens in the step, nil pointerCount once (the walk's worst case), each evaluation by its Do it, each a step whose frames the shell counts."
	steps := OrderedCollection new.
	failure := nil.
	DevTools openLocal: aSocketPath project: nil.
	client := DevTools local.
	browser := (DevTools windowsOf: BrowserWindow) first model.
	queue := OrderedCollection new.
	queue add: [self checkPointers].
	queue add: [
		workspace := DevTools openWorkspace: client.
		workspace textView text: '(DevTools windows first pointersTo: 100000) size'.
		self evaluate: 10 in: workspace step: 'pointers.eval'].
	queue add: [
		workspace textView text: 'nil pointerCount'.
		self evaluate: 1 in: workspace step: 'pointers.nilcount'].
	self begin: 'open'.
	self when: [client isOpen and: [browser hierarchy size > 0]] then: [self end].
	^ true
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
