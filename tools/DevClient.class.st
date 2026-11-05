"The development protocol's client in Smalltalk (module 9c, docs/modules/developer-ui.md): one connection to a target through the shell's transport (ClientTransport, primitive 164). Requests are messages, one per request of protocol.describe (the requests category; DevClient class>>requests maps each kind to its method and DevClientTest checks the map against DevProtocol describe), each taking the request's arguments and a block that gets the result; errors go to the error block given or to the client's error action. Replies come back as #line events on the UI's event loop, matched by id; the other lines are events (transcript, test.*, run.*, process.stopped, process.resumed) dispatched to whichever window registered for their kind (on:do:). A request that gets no reply within its timeout fails with an error (a timer event, never a wait in the UI). Module 9d: a connection that ends while its session was open (a dropped link: the phone left the network, the socket died) is the event 'connection.lost', and the client reconnects (timer events with backoff: 1, 2, 4, 8 s, up to a minute, until close): 'connection.reconnecting', then a new session as the same client in the same package and 'connection.open'; the requests pending at the loss are sent again, but for those that may not be (DevClient class>>notRetried: running them twice is not running them once), which fail as before. A refused session or close ends it for good. Each reply's round trip is kept for the measurements, a retried one's from its first send."
Class {
	#name : #DevClient,
	#superclass : #Object,
	#instVars : [
		'name',
		'path',
		'connection',
		'state',
		'pending',
		'nextId',
		'listeners',
		'errorAction',
		'info',
		'timeoutMs',
		'latencies',
		'lostReason',
		'parts',
		'clientName',
		'package',
		'project',
		'closing',
		'reconnects',
		'backoffMs',
		'reconnectTimer',
		'lostAt',
		'outages',
		'retried'
	],
	#classInstVars : [
		'connections',
		'targetActions'
	],
	#category : #'Tools-Client'
}

{ #category : #accessing }
DevClient >> backoffMs [
	"The wait before the next reconnect."
	^ backoffMs
]

{ #category : #accessing }
DevClient >> connection [
	^ connection
]

{ #category : #accessing }
DevClient >> info [
	"session.open's answer: the protocol version, the client, the package, the image kind, the number of requests."
	^ info
]

{ #category : #accessing }
DevClient >> isOpen [
	^ state == #open
]

{ #category : #accessing }
DevClient >> latencies [
	"{kind. microseconds} of every reply, from the send to its dispatch in the event loop."
	^ latencies
]

{ #category : #accessing }
DevClient >> lostReason [
	^ lostReason
]

{ #category : #accessing }
DevClient >> name [
	^ name
]

{ #category : #accessing }
DevClient >> outages [
	"{microseconds from the loss to the new session. requests sent again} of every dropped link."
	^ outages
]

{ #category : #accessing }
DevClient >> path [
	^ path
]

{ #category : #accessing }
DevClient >> pendingAt: anId put: anEntry [
	"{kind. sent at. result block. error block. timer. line} (tests)."
	pending at: anId put: anEntry
]

{ #category : #accessing }
DevClient >> pendingCount [
	^ pending size
]

{ #category : #accessing }
DevClient >> reconnects [
	"How many times a new session was asked for after a dropped link."
	^ reconnects
]

{ #category : #accessing }
DevClient >> retried [
	"Requests sent again after a dropped link."
	^ retried
]

{ #category : #accessing }
DevClient >> state [
	"#connecting, #open, #reconnecting (the link dropped: a new session is being opened) or #lost (for good)."
	^ state
]

{ #category : #accessing }
DevClient >> timeoutMs: anInteger [
	timeoutMs := anInteger
]

{ #category : #events }
DevClient >> emit: aKind with: anObject [
	"Run the listeners of aKind, then those of every kind ('*')."
	(listeners at: aKind ifAbsent: [#()]) copy do: [:b | b cull: anObject cull: self].
	(listeners at: '*' ifAbsent: [#()]) copy do: [:b | b cull: anObject cull: self]
]

{ #category : #events }
DevClient >> on: aKind do: aBlock [
	"aBlock runs with each event of aKind ('transcript', 'process.stopped', 'test.passed', 'connection.open', 'connection.lost', '*' for all) and this client."
	(listeners at: aKind ifAbsentPut: [OrderedCollection new]) add: aBlock.
	^ aBlock
]

{ #category : #events }
DevClient >> onError: aBlock [
	"The action for errors of requests sent without an error block (a window's status line)."
	errorAction := aBlock
]

{ #category : #events }
DevClient >> removeListener: aBlock [
	listeners do: [:l | l remove: aBlock ifAbsent: [nil]]
]

{ #category : #initialization }
DevClient >> initialize [
	state := #connecting.
	pending := Dictionary new.
	nextId := 0.
	listeners := Dictionary new.
	latencies := OrderedCollection new.
	timeoutMs := 30000.
	closing := false.
	reconnects := 0.
	retried := 0.
	backoffMs := 1000.
	outages := OrderedCollection new
]

{ #category : #initialization }
DevClient >> setClient: aClient package: aPackageOrNil project: aDirectoryOrNil [
	"Who the session is, what it opens again after a dropped link."
	clientName := aClient.
	package := aPackageOrNil.
	project := aDirectoryOrNil
]

{ #category : #initialization }
DevClient >> setName: aName path: aPath connection: aHandle [
	name := aName.
	path := aPath.
	connection := aHandle
]

{ #category : #receiving }
DevClient >> endWith: aReason [
	"The end for good: every pending request fails, connection.lost."
	| entries |
	state := #lost.
	reconnectTimer ifNotNil: [:t | self cancelTimer: t. reconnectTimer := nil].
	entries := pending values.
	pending := Dictionary new.
	entries do: [:e |
		(e at: 5) ifNotNil: [:t | UIEventLoop cancelTimer: t].
		self fail: e with: 'the connection was lost: ' , aReason displayString].
	self emit: 'connection.lost' with: aReason
]

{ #category : #receiving }
DevClient >> fail: anEntry with: aString [
	| block |
	block := anEntry at: 4.
	block isNil ifTrue: [block := errorAction].
	block isNil
		ifTrue: [Transcript show: name printString , ' ' , (anEntry at: 1) , ': ' , aString; cr]
		ifFalse: [block cull: aString cull: (anEntry at: 1)]
]

{ #category : #receiving }
DevClient >> lost: aReason [
	"The connection ended. Closed by this client, refused, or never opened: every pending request fails, connection.lost, for good. Otherwise a dropped link: what may not be sent again fails, the rest waits, and a reconnect is scheduled (connection.lost, then connection.reconnecting with the wait)."
	| entries |
	lostReason := aReason.
	self class forget: self.
	(closing or: [info isNil]) ifTrue: [^ self endWith: aReason].
	reconnectTimer isNil ifFalse: [^ self].
	state == #reconnecting ifFalse: [
		state := #reconnecting.
		lostAt := Smalltalk microsecondClock.
		entries := OrderedCollection new.
		pending keysAndValuesDo: [:id :e | (self class notRetried includes: (e at: 1)) ifTrue: [entries add: id]].
		entries do: [:id | | e |
			e := pending removeKey: id.
			(e at: 5) ifNotNil: [:t | UIEventLoop cancelTimer: t].
			self fail: e with: 'the connection was lost (' , (e at: 1) , ' is not sent again): ' , aReason displayString].
		self emit: 'connection.lost' with: aReason].
	self emit: 'connection.reconnecting' with: backoffMs.
	reconnectTimer := self after: backoffMs do: [self reconnect].
	backoffMs := backoffMs * 2 min: 60000
]

{ #category : #receiving }
DevClient >> receive: aJsonObject [
	"One object the target sent: a reply (to session.open, or to a request by id) or an event."
	| kind id entry |
	kind := aJsonObject at: 'kind'.
	kind = 'reply' ifFalse: [^ self emit: kind with: aJsonObject].
	id := aJsonObject at: 'id'.
	id = 'session' ifTrue: [ | again |
		(aJsonObject at: 'ok') == true ifTrue: [
			again := state == #reconnecting.
			state := #open.
			info := aJsonObject at: 'result'.
			again ifTrue: [self reopened].
			^ self emit: 'connection.open' with: info].
		"A refused session is not reconnected: the token was not the target's (a new one ends every session)."
		info := nil.
		self close.
		^ self emit: 'connection.refused' with: (aJsonObject at: 'error')].
	entry := pending removeKey: id ifAbsent: [^ nil].
	(entry at: 5) ifNotNil: [:t | UIEventLoop cancelTimer: t].
	latencies add: {entry at: 1. Smalltalk microsecondClock - (entry at: 2)}.
	(aJsonObject at: 'ok') == true
		ifTrue: [(entry at: 3) ifNotNil: [:b | b cull: (aJsonObject at: 'result')]]
		ifFalse: [self fail: entry with: ((aJsonObject at: 'error') ifNil: ['an error without a message'])]
]

{ #category : #receiving }
DevClient >> receiveLine: aString [
	"A #line event's value: the canonical text of a JSON object (a malformed line arrives as a client.error object), or its last piece after #linePart events."
	| o text |
	parts isNil
		ifTrue: [text := aString]
		ifFalse: [text := (parts copyWith: aString) asArray. parts := nil].
	o := [Json read: text] on: Error do: [:e | ^ self emit: 'client.error' with: e messageText].
	(o isKindOf: JsonObject) ifFalse: [^ self emit: 'client.error' with: 'not an object'].
	self receive: o
]

{ #category : #receiving }
DevClient >> receivePart: aString [
	"A #linePart event: a piece of a line longer than one object can be."
	parts isNil ifTrue: [parts := OrderedCollection new].
	parts add: aString
]

{ #category : #receiving }
DevClient >> reconnect [
	"A reconnect's timer: a new connection to the same target, a new session as the same client in the same package (the host opens it with the token it holds). Its session's reply reopens the client; its failure is another loss."
	| h |
	reconnectTimer := nil.
	(closing or: [state ~~ #reconnecting]) ifTrue: [^ self].
	reconnects := reconnects + 1.
	h := self openConnection.
	h isNil ifTrue: [^ self endWith: 'no transport to reconnect with'].
	connection := h.
	self class register: self
]

{ #category : #receiving }
DevClient >> reopened [
	"The new session is open: the requests that waited are sent again (on this connection, with their ids), the wait goes back to a second."
	| ids |
	outages add: {Smalltalk microsecondClock - lostAt. pending size}.
	backoffMs := 1000.
	ids := pending keys asArray sort: [:a :b | a <= b].
	ids do: [:id |
		(state == #open and: [pending includesKey: id]) ifTrue: [ | e |
			e := pending at: id.
			retried := retried + 1.
			self transmit: (e at: 6) kind: (e at: 1) id: id args: nil]]
]

{ #category : #receiving }
DevClient >> timedOut: anId [
	| entry |
	entry := pending removeKey: anId ifAbsent: [^ nil].
	self fail: entry with: (entry at: 1) , ' got no reply within ' , timeoutMs printString , ' ms'
]

{ #category : #requests }
DevClient >> classCategories: aBlock [
	^ self request: 'class.categories' args: #() then: aBlock
]

{ #category : #requests }
DevClient >> classComment: className comment: comment then: aBlock [
	^ self request: 'class.comment' args: {'className'. className. 'comment'. comment} then: aBlock
]

{ #category : #requests }
DevClient >> classDefine: className superclass: superclass instanceVariables: instanceVariables classVariables: classVariables category: category then: aBlock [
	^ self request: 'class.define'
		args: {'name'. className. 'superclass'. superclass. 'instanceVariables'. instanceVariables. 'classVariables'. classVariables. 'category'. category}
		then: aBlock
]

{ #category : #requests }
DevClient >> classDefinition: className then: aBlock [
	^ self request: 'class.definition' args: {'className'. className} then: aBlock
]

{ #category : #requests }
DevClient >> classHierarchy: aBlock [
	^ self request: 'class.hierarchy' args: #() then: aBlock
]

{ #category : #requests }
DevClient >> classList: category then: aBlock [
	^ self request: 'class.list' args: {'category'. category} then: aBlock
]

{ #category : #requests }
DevClient >> classRemove: className then: aBlock [
	^ self request: 'class.remove' args: {'className'. className} then: aBlock
]

{ #category : #requests }
DevClient >> classSelectors: className side: side then: aBlock [
	^ self request: 'class.selectors' args: {'className'. className. 'side'. side} then: aBlock
]

{ #category : #requests }
DevClient >> classTonel: className then: aBlock [
	^ self request: 'class.tonel' args: {'className'. className} then: aBlock
]

{ #category : #requests }
DevClient >> evaluate: source receiver: receiver then: aBlock [
	^ self request: 'evaluate' args: {'source'. source. 'receiver'. receiver} then: aBlock
]

{ #category : #requests }
DevClient >> inspect: handle then: aBlock [
	^ self request: 'inspect' args: {'handle'. handle} then: aBlock
]

{ #category : #requests }
DevClient >> inspectRelease: handle then: aBlock [
	^ self request: 'inspect.release' args: {'handle'. handle} then: aBlock
]

{ #category : #requests }
DevClient >> methodBytecodes: className selector: selector side: side then: aBlock [
	^ self request: 'method.bytecodes' args: {'className'. className. 'selector'. selector. 'side'. side} then: aBlock
]

{ #category : #requests }
DevClient >> methodCompile: className source: source category: category side: side then: aBlock [
	^ self request: 'method.compile' args: {'className'. className. 'source'. source. 'category'. category. 'side'. side} then: aBlock
]

{ #category : #requests }
DevClient >> methodImplementors: selector then: aBlock [
	^ self request: 'method.implementors' args: {'selector'. selector} then: aBlock
]

{ #category : #requests }
DevClient >> methodRemove: className selector: selector side: side then: aBlock [
	^ self request: 'method.remove' args: {'className'. className. 'selector'. selector. 'side'. side} then: aBlock
]

{ #category : #requests }
DevClient >> methodSenders: selector then: aBlock [
	^ self request: 'method.senders' args: {'selector'. selector} then: aBlock
]

{ #category : #requests }
DevClient >> methodSource: className selector: selector side: side then: aBlock [
	^ self request: 'method.source' args: {'className'. className. 'selector'. selector. 'side'. side} then: aBlock
]

{ #category : #requests }
DevClient >> packageList: aBlock [
	^ self request: 'package.list' args: #() then: aBlock
]

{ #category : #requests }
DevClient >> packageSelectors: packageName then: aBlock [
	^ self request: 'package.selectors' args: {'name'. packageName} then: aBlock
]

{ #category : #requests }
DevClient >> processEvaluate: process frame: frame source: source then: aBlock [
	^ self request: 'process.evaluate' args: {'process'. process. 'frame'. frame. 'source'. source} then: aBlock
]

{ #category : #requests }
DevClient >> processFrames: process then: aBlock [
	^ self request: 'process.frames' args: {'process'. process} then: aBlock
]

{ #category : #requests }
DevClient >> processList: aBlock [
	^ self request: 'process.list' args: #() then: aBlock
]

{ #category : #requests }
DevClient >> processProceed: process value: value then: aBlock [
	^ self request: 'process.proceed' args: {'process'. process. 'value'. value} then: aBlock
]

{ #category : #requests }
DevClient >> processRestart: process frame: frame then: aBlock [
	^ self request: 'process.restart' args: {'process'. process. 'frame'. frame} then: aBlock
]

{ #category : #requests }
DevClient >> processRetrySend: process then: aBlock [
	^ self request: 'process.retrySend' args: {'process'. process} then: aBlock
]

{ #category : #requests }
DevClient >> processStep: process mode: mode frame: frame then: aBlock [
	^ self request: 'process.step' args: {'process'. process. 'mode'. mode. 'frame'. frame} then: aBlock
]

{ #category : #requests }
DevClient >> processSuspend: process then: aBlock [
	^ self request: 'process.suspend' args: {'process'. process} then: aBlock
]

{ #category : #requests }
DevClient >> processTerminate: process then: aBlock [
	^ self request: 'process.terminate' args: {'process'. process} then: aBlock
]

{ #category : #requests }
DevClient >> protocolDescribe: aBlock [
	^ self request: 'protocol.describe' args: #() then: aBlock
]

{ #category : #requests }
DevClient >> testRun: filter tag: tag then: aBlock [
	^ self request: 'test.run' args: {'filter'. filter. 'tag'. tag} then: aBlock
]

{ #category : #sending }
DevClient >> after: milliseconds do: aBlock [
	"A timer event (tests give their own)."
	^ UIEventLoop after: milliseconds do: aBlock
]

{ #category : #sending }
DevClient >> cancelTimer: aTimer [
	UIEventLoop cancelTimer: aTimer
]

{ #category : #sending }
DevClient >> close [
	"For good: no reconnect. While reconnecting there is no connection to close: the client ends now."
	closing := true.
	state == #reconnecting ifTrue: [^ self endWith: 'closed'].
	connection isNil ifFalse: [ClientTransport close: connection]
]

{ #category : #sending }
DevClient >> lineFor: aKind id: anId args: aJsonObject [
	| o |
	o := JsonObject new.
	o at: 'v' put: 1; at: 'id' put: anId; at: 'kind' put: aKind; at: 'args' put: aJsonObject.
	^ Json write: o
]

{ #category : #sending }
DevClient >> openConnection [
	"A new connection to the same target (tests give their own): its handle, or nil."
	^ ClientTransport connect: path client: clientName package: package token: nil project: project
]

{ #category : #sending }
DevClient >> request: aKind args: anArray then: aBlock [
	^ self request: aKind args: anArray then: aBlock else: nil
]

{ #category : #sending }
DevClient >> request: aKind args: anArray then: aBlock else: anErrorBlock [
	"Send a request: anArray holds its arguments as name, value pairs (nil values are left out); aBlock gets the result, anErrorBlock (or the error action) the error text. Answers the request's id."
	| args id entry line |
	state == #lost ifTrue: [
		self fail: {aKind. 0. aBlock. anErrorBlock. nil. nil} with: 'not connected: ' , lostReason displayString.
		^ nil].
	args := JsonObject new.
	1 to: anArray size by: 2 do: [:i | (anArray at: i + 1) isNil ifFalse: [args at: (anArray at: i) put: (anArray at: i + 1)]].
	nextId := nextId + 1.
	id := nextId.
	line := self lineFor: aKind id: id args: args.
	entry := {aKind. Smalltalk microsecondClock. aBlock. anErrorBlock. nil. line}.
	pending at: id put: entry.
	entry at: 5 put: (UIEventLoop after: timeoutMs do: [self timedOut: id]).
	"While reconnecting the request waits for the new session (reopened sends it)."
	state == #reconnecting ifFalse: [self transmit: line kind: aKind id: id args: args].
	^ id
]

{ #category : #sending }
DevClient >> transmit: aLine kind: aKind id: anId args: aJsonObject [
	"The line to the target; a connection already gone is the connection's end."
	(ClientTransport send: aLine on: connection) isNil ifTrue: [self lost: 'the connection is closed']
]

{ #category : #connections }
DevClient class >> at: aConnection [
	connections isNil ifTrue: [^ nil].
	^ connections at: aConnection ifAbsent: [nil]
]

{ #category : #connections }
DevClient class >> connect: aPath name: aName client: aClient package: aPackageOrNil token: aTokenOrNil project: aDirectoryOrNil [
	"A client of the target at aPath (its socket), opening its session as aClient with the token the host holds (or aTokenOrNil); changes go to aPackageOrNil and their files into aDirectoryOrNil. The client is #connecting until its session is open (the event connection.open). nil when the image has no transport host."
	| h c |
	self install.
	h := ClientTransport connect: aPath client: aClient package: aPackageOrNil token: aTokenOrNil project: aDirectoryOrNil.
	h isNil ifTrue: [^ nil].
	c := self new setName: aName path: aPath connection: h.
	c setClient: aClient package: aPackageOrNil project: aDirectoryOrNil.
	connections at: h put: c.
	^ c
]

{ #category : #connections }
DevClient class >> forget: aClient [
	connections isNil ifFalse: [connections removeKey: aClient connection ifAbsent: [nil]]
]

{ #category : #connections }
DevClient class >> install [
	"The event loop gives #line and #lost events to the client of their connection."
	connections isNil ifTrue: [connections := Dictionary new].
	UIEventLoop on: #line do: [:e | (self at: e target) ifNotNil: [:c | c receiveLine: e value]].
	UIEventLoop on: #linePart do: [:e | (self at: e target) ifNotNil: [:c | c receivePart: e value]].
	UIEventLoop on: #lost do: [:e | (self at: e target) ifNotNil: [:c | c lost: e value]].
	UIEventLoop on: #targets do: [:e | targetActions isNil ifFalse: [targetActions do: [:b | b value]]]
]

{ #category : #connections }
DevClient class >> onTargetsChanged: aBlock [
	"aBlock runs when the host's targets change (module 9d: a phone appeared on the network or went)."
	targetActions isNil ifTrue: [targetActions := OrderedCollection new].
	targetActions add: aBlock
]

{ #category : #connections }
DevClient class >> register: aClient [
	"aClient's (new) connection's events reach it."
	connections isNil ifTrue: [connections := Dictionary new].
	connections at: aClient connection put: aClient
]

{ #category : #requests }
DevClient class >> notRetried [
	"The requests not sent again after a dropped link: each may have run in the target before the link dropped, and running it twice is not running it once (a doit, a doit in a frame, a step, a test run). Every other request is idempotent (module 9b): a read, a compile of the same source, a command on a stopped Process that answers an error once it is no longer stopped."
	^ #('evaluate' 'process.evaluate' 'process.step' 'test.run')
]

{ #category : #requests }
DevClient class >> requests [
	"Every request of the development protocol and the method that sends it (DevClientTest compares this with DevProtocol describe)."
	^ #(
		#('class.categories' #classCategories:)
		#('class.comment' #classComment:comment:then:)
		#('class.define' #classDefine:superclass:instanceVariables:classVariables:category:then:)
		#('class.definition' #classDefinition:then:)
		#('class.hierarchy' #classHierarchy:)
		#('class.list' #classList:then:)
		#('class.remove' #classRemove:then:)
		#('class.selectors' #classSelectors:side:then:)
		#('class.tonel' #classTonel:then:)
		#('evaluate' #evaluate:receiver:then:)
		#('inspect' #inspect:then:)
		#('inspect.release' #inspectRelease:then:)
		#('method.bytecodes' #methodBytecodes:selector:side:then:)
		#('method.compile' #methodCompile:source:category:side:then:)
		#('method.implementors' #methodImplementors:then:)
		#('method.remove' #methodRemove:selector:side:then:)
		#('method.senders' #methodSenders:then:)
		#('method.source' #methodSource:selector:side:then:)
		#('package.list' #packageList:)
		#('package.selectors' #packageSelectors:then:)
		#('process.evaluate' #processEvaluate:frame:source:then:)
		#('process.frames' #processFrames:then:)
		#('process.list' #processList:)
		#('process.proceed' #processProceed:value:then:)
		#('process.restart' #processRestart:frame:then:)
		#('process.retrySend' #processRetrySend:then:)
		#('process.step' #processStep:mode:frame:then:)
		#('process.suspend' #processSuspend:then:)
		#('process.terminate' #processTerminate:then:)
		#('protocol.describe' #protocolDescribe:)
		#('test.run' #testRun:tag:then:))
]
