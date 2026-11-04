"The development protocol's client transport (module 9c, docs/modules/developer-ui.md): the shell, kajo run or a test owns the sockets (primitive 164, the host's client callback); the image asks it to connect to a target, send a request line, close, list the targets it knows, and post a timer event. What a connection receives comes back on the event queue as #line events (the canonical text of each JSON object the host's bounded reader accepted, or a client.error object saying why a line was refused) and a #lost event at its end, so the UI's one event loop handles a reply like a click. A target's token stays in the host: connect names the socket and the host opens the session with the token it holds (from ~/.kajo/targets, or its own transport's), unless one is given. Without a host every call answers nil."
Class {
	#name : #ClientTransport,
	#superclass : #Object,
	#category : #'Kernel-Development'
}

{ #category : #primitives }
ClientTransport class >> primCall: op handle: aHandle with: anArray [
	"Primitive 164: the host's client transport; nil when there is none or it refused."
	<primitive: 164>
	^ nil
]

{ #category : #transport }
ClientTransport class >> close: aConnection [
	^ self primCall: 'close' handle: aConnection with: #()
]

{ #category : #transport }
ClientTransport class >> connect: aPath client: aClient package: aPackageOrNil token: aTokenOrNil project: aDirectoryOrNil [
	"A new connection's handle at once (nil without a host): the connect and the session.open (id 'session') happen in the host, its reply and every later line arrive as #line events, the end as #lost."
	^ self primCall: 'connect' handle: nil with: {aPath. aClient. aPackageOrNil. aTokenOrNil. aDirectoryOrNil}
]

{ #category : #transport }
ClientTransport class >> hasHost [
	^ (self primCall: 'targets' handle: nil with: #()) notNil
]

{ #category : #transport }
ClientTransport class >> send: aLine on: aConnection [
	"One request line (a JSON object, no line break); true, or nil when the connection is gone."
	^ self primCall: 'send' handle: aConnection with: {aLine}
]

{ #category : #transport }
ClientTransport class >> targets [
	"The targets the host knows: {name. socket path. whether it holds the token} each."
	| text |
	text := self primCall: 'targets' handle: nil with: #().
	text isNil ifTrue: [^ #()].
	^ (text lines collect: [:l | | f |
		f := l splitOn: Character tab.
		{f first. f at: 2. (f at: 3) = '1'}]) asArray
]

{ #category : #transport }
ClientTransport class >> timer: milliseconds token: aNumber [
	"A #timer event with target aNumber after milliseconds; nil without a host."
	^ self primCall: 'timer' handle: nil with: {milliseconds. aNumber}
]
