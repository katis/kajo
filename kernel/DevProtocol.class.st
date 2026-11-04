"The development protocol's target side (module 9b, docs/modules/development-protocol.md, ADR 0011): one Process at the highest priority takes the requests the host's transport checked (primitive 160, canonical JSON with its connection), and each request runs in a Process of its own as a <devProtocol> method of the connection's DevSession; its answer, or the error it signalled, is the reply (primitive 161 to the host, which routes a reply to its connection by its conn). Adding a request is adding a method: protocol.describe lists them, the kind from the selector (processRetrySend: is process.retrySend), the argument names from the method's own. A request with <debuggable> lets an unhandled error stop its Process for the debugger instead of replying with it. Development images only: in a release image nothing here starts."
Class {
	#name : #DevProtocol,
	#superclass : #Object,
	#classInstVars : [
		'semaphore',
		'process',
		'sessions',
		'pending',
		'lock',
		'kinds',
		'argumentNames'
	],
	#category : #'Kernel-Development'
}

{ #category : #describing }
DevProtocol class >> argumentNamesOf: aSelector [
	"The request's argument names: the method's own argument names (from its source), kept per method (a recompiled method is another one)."
	| m |
	m := DevSession lookupSelector: aSelector.
	m isNil ifTrue: [^ #()].
	argumentNames isNil ifTrue: [argumentNames := IdentityDictionary new].
	^ argumentNames at: m ifAbsentPut: [
		(Smalltalk sourceOf: m)
			ifNil: [(1 to: m numArgs) collect: [:i | 'arg' , i printString]]
			ifNotNil: [:src | ((Parser parse: src) arguments collect: [:a | a first asString]) asArray]]
]

{ #category : #describing }
DevProtocol class >> commentOf: aCompiledMethod [
	"The method's first comment, the request's description."
	| src i j |
	src := Smalltalk sourceOf: aCompiledMethod.
	src isNil ifTrue: [^ ''].
	i := src indexOf: $".
	i = 0 ifTrue: [^ ''].
	j := src indexOfSubstring: '"' startingAt: i + 1.
	j = 0 ifTrue: [^ ''].
	^ src copyFrom: i + 1 to: j - 1
]

{ #category : #describing }
DevProtocol class >> describe [
	"Every request: kind, selector, arguments, comment, and whether its errors stop for the debugger."
	self rebuildKinds.
	^ (kinds keys asArray sort: [:a :b | a <= b]) collect: [:k | | sel m o |
		sel := kinds at: k.
		m := DevSession lookupSelector: sel.
		o := JsonObject new.
		o at: 'kind' put: k; at: 'selector' put: sel; at: 'arguments' put: (self argumentNamesOf: sel);
			at: 'comment' put: (self commentOf: m); at: 'debuggable' put: (m hasPragma: #debuggable).
		o]
]

{ #category : #describing }
DevProtocol class >> kindOf: aSelector [
	"process.retrySend for processRetrySend:: the first keyword, split before its first capital, the capital lowered."
	| word colon i b |
	word := aSelector asString.
	colon := word indexOf: $:.
	colon > 0 ifTrue: [word := word copyFrom: 1 to: colon - 1].
	i := 1.
	[i <= word byteSize and: [((word byteAt: i) between: 65 and: 90) not]] whileTrue: [i := i + 1].
	i > word byteSize ifTrue: [^ word].
	b := ByteArray new: 1.
	b at: 1 put: (word byteAt: i) + 32.
	^ (word copyFrom: 1 to: i - 1) , '.' , b asString , (word copyFrom: i + 1 to: word byteSize)
]

{ #category : #describing }
DevProtocol class >> rebuildKinds [
	| d |
	d := Dictionary new.
	(Pragma allNamed: #devProtocol) do: [:p |
		(p method methodClass == DevSession) ifTrue: [d at: (self kindOf: p method selector) put: p method selector]].
	kinds := d
]

{ #category : #describing }
DevProtocol class >> selectorOf: aKind [
	"The selector of the request aKind, or nil; the table is made again when it misses (a request just added)."
	kinds isNil ifTrue: [self rebuildKinds].
	^ kinds at: aKind ifAbsent: [
		self rebuildKinds.
		kinds at: aKind ifAbsent: [nil]]
]

{ #category : #events }
DevProtocol class >> emit: aKind with: aJsonObject [
	"An event to every session (no conn): the kind, the time and the fields."
	| o |
	self isServing ifFalse: [^ nil].
	o := JsonObject new.
	o at: 'v' put: 1; at: 'kind' put: aKind; at: 'ts' put: Smalltalk microsecondClock.
	aJsonObject keysAndValuesDo: [:k :v | o at: k put: v].
	^ self primEmit: (Json write: o)
]

{ #category : #primitives }
DevProtocol class >> primEmit: aString [
	"A line to the host's transport as it is: a reply (with its conn) or an event."
	<primitive: 161>
	^ nil
]

{ #category : #primitives }
DevProtocol class >> primNextRequest [
	"{connection. canonical JSON} of the oldest request, or nil."
	<primitive: 160>
	^ nil
]

{ #category : #primitives }
DevProtocol class >> primRegister: aSemaphore [
	"The Semaphore the host signals once per request; fails without a transport or in a release image."
	<primitive: 159>
	^ nil
]

{ #category : #replies }
DevProtocol class >> reply: aReplyTo error: aString [
	^ self primEmit: '{"v":1,"kind":"reply","conn":' , aReplyTo first printString , ',"id":' , (Json write: aReplyTo last)
		, ',"ok":false,"error":' , (Json write: aString) , '}'
]

{ #category : #replies }
DevProtocol class >> reply: aReplyTo result: anObject [
	^ self primEmit: '{"v":1,"kind":"reply","conn":' , aReplyTo first printString , ',"id":' , (Json write: aReplyTo last)
		, ',"ok":true,"result":' , (Json write: anObject) , '}'
]

{ #category : #requests }
DevProtocol class >> finishActive: aValue [
	"The active request's reply, unless someone else took it (a stopped Process, a debugger command)."
	| entry |
	entry := self takeReplyOf: ProcessorScheduler activeProcess.
	entry isNil ifFalse: [self reply: entry first result: aValue]
]

{ #category : #requests }
DevProtocol class >> finishActiveWithError: aString [
	| entry |
	entry := self takeReplyOf: ProcessorScheduler activeProcess.
	entry isNil ifFalse: [self reply: entry first error: aString]
]

{ #category : #requests }
DevProtocol class >> run: aSelector in: aSession with: anArray replyTo: aReplyTo [
	"A request's Process: the method, then its reply. Errors are the reply, unless the request is <debuggable>."
	| value method |
	lock critical: [pending at: ProcessorScheduler activeProcess put: (Array with: aReplyTo with: aSession)].
	method := DevSession lookupSelector: aSelector.
	(method hasPragma: #debuggable)
		ifTrue: [value := aSession perform: aSelector withArguments: anArray]
		ifFalse: [value := [aSession perform: aSelector withArguments: anArray] on: Error do: [:e |
			self finishActiveWithError: e printString.
			^ nil]].
	self finishActive: value
]

{ #category : #requests }
DevProtocol class >> sessionOfActive [
	"The DevSession whose request the active Process runs, or nil."
	| entry |
	lock isNil ifTrue: [^ nil].
	entry := lock critical: [pending at: ProcessorScheduler activeProcess ifAbsent: [nil]].
	^ entry ifNotNil: [:e | e last]
]

{ #category : #requests }
DevProtocol class >> take: anArray [
	"One request from the transport: {connection. canonical JSON}."
	| conn request id kind args session selector names values |
	conn := anArray first.
	request := [Json read: (anArray at: 2)] on: Error do: [:e | ^ self reply: (Array with: conn with: nil) error: 'unreadable request: ' , e messageText].
	id := request at: 'id'.
	kind := request at: 'kind'.
	args := (request at: 'args') ifNil: [JsonObject new].
	kind = 'session.open' ifTrue: [
		session := DevSession conn: conn client: (args at: 'client') package: (args at: 'package').
		lock critical: [sessions at: conn put: session].
		^ self reply: (Array with: conn with: id) result: session info].
	kind = 'session.close' ifTrue: [
		lock critical: [sessions removeKey: conn ifAbsent: [nil]].
		^ nil].
	session := lock critical: [sessions at: conn ifAbsent: [nil]].
	session isNil ifTrue: [^ self reply: (Array with: conn with: id) error: 'no session on this connection'].
	selector := self selectorOf: kind.
	selector isNil ifTrue: [^ self reply: (Array with: conn with: id) error: 'unknown request ' , kind , ': protocol.describe lists the requests'].
	names := self argumentNamesOf: selector.
	args keys do: [:k |
		(names includes: k) ifFalse: [
			^ self reply: (Array with: conn with: id)
				error: kind , ' has no argument ' , k , ' (its arguments: ' , (names inject: '' into: [:a :n | a isEmpty ifTrue: [n] ifFalse: [a , ', ' , n]]) , ')']].
	values := (names collect: [:n | args at: n]) asArray.
	[self run: selector in: session with: values replyTo: (Array with: conn with: id)] forkAt: 1
]

{ #category : #requests }
DevProtocol class >> takeReplyOf: aProcess [
	"{replyTo. session} of the request aProcess runs, removed: whoever takes it answers the request."
	lock isNil ifTrue: [^ nil].
	^ lock critical: [pending removeKey: aProcess ifAbsent: [nil]]
]

{ #category : #serving }
DevProtocol class >> isServing [
	^ process notNil
]

{ #category : #serving }
DevProtocol class >> serve [
	"The protocol Process: one request per signal."
	[true] whileTrue: [
		semaphore wait.
		self primNextRequest ifNotNil: [:r |
			[self take: r] on: Error do: [:e | Transcript show: 'protocol: ' , e printString; cr]]]
]

{ #category : #serving }
DevProtocol class >> start [
	"Serve the development protocol when the host opened a transport (kajo run --protocol, the macOS shell): the protocol Process at the highest priority, and unhandled errors stop their Process for the debugger from now on. Answers whether it serves; false in a release image or without a transport."
	Smalltalk isReleaseImage ifTrue: [^ false].
	process notNil ifTrue: [^ true].
	lock := Mutex new.
	sessions := Dictionary new.
	pending := IdentityDictionary new.
	kinds := nil.
	semaphore := Semaphore new.
	(self primRegister: semaphore) == self ifFalse: [semaphore := nil. ^ false].
	Debugger enable.
	process := [self serve] forkAt: 2.
	^ true
]

{ #category : #sources }
DevProtocol class >> noteChangeOf: aSelector in: aBehavior [
	"A method was compiled (Behavior>>compile:): when a development session's request did it, the method's author is the session's client and its package the session's (module 9b)."
	| session |
	session := self sessionOfActive.
	session isNil ifTrue: [^ nil].
	Smalltalk noteAuthor: session client of: aSelector in: aBehavior.
	Smalltalk notePackage: session package of: aSelector in: aBehavior
]

{ #category : #sources }
DevProtocol class >> packageOfActiveSession [
	^ self sessionOfActive ifNotNil: [:s | s package]
]
