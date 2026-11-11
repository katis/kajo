"The development protocol's client transport (module 9c, docs/modules/developer-ui.md): the shell, kajo run or a test owns the sockets (primitive 164, the host's client callback); the image asks it to connect to a target, send a request line, close, list the targets it knows, and post a timer event. What a connection receives comes back on the event queue as #line events (the canonical text of each JSON object the host's bounded reader accepted, or a client.error object saying why a line was refused) and a #lost event at its end, so the UI's one event loop handles a reply like a click. A target's token stays in the host: connect names the target and the host opens the session with the token it holds (from ~/.kajo/targets, its own transport's, or one the developer typed into the host's own secure field: pair:); no token ever passes through the image. The project directory (2026-11-11, docs/modules/project-directory.md) is the host's too: the host holds each target's directory and writes the files of a connection's replies there; the image never names one, may ask which one the host holds (projectOf:) and may ask the host to ask the developer (chooseProject:). Without a host every call answers nil."
Class {
	#name : #ClientTransport,
	#superclass : #Object
}

{ #category : #primitives }
ClientTransport class >> primCall: op handle: aHandle with: anArray [
	"Primitive 164: the host's client transport; nil when there is none or it refused."
	<primitive: 164>
	^ nil
]

{ #category : #transport }
ClientTransport class >> chooseProject: aTargetName [
	"The project directory: the host asks the developer for aTargetName's project directory in a panel of its own and keeps it; the image never names one. Answers whether the host holds a directory for the target now (nil without a host, or one with no panel); when the developer has chosen, a #targets event follows."
	^ self primCall: 'chooseProject' handle: nil with: {aTargetName}
]

{ #category : #transport }
ClientTransport class >> close: aConnection [
	^ self primCall: 'close' handle: aConnection with: #()
]

{ #category : #transport }
ClientTransport class >> connect: aTarget client: aClient package: aPackageOrNil [
	"A new connection's handle at once (nil without a host): the connect and the session.open (id 'session', with the token the host holds for aTarget) happen in the host, its reply and every later line arrive as #line events, the end as #lost. The files of its replies go to the project directory the host holds for aTarget, or nowhere."
	^ self primCall: 'connect' handle: nil with: {aTarget. aClient. aPackageOrNil}
]

{ #category : #transport }
ClientTransport class >> hasHost [
	^ (self primCall: 'targets' handle: nil with: #()) notNil
]

{ #category : #transport }
ClientTransport class >> pair: aTargetName [
	"Module 9d: the host asks the developer for aTargetName's token in a secure field of its own (read off the phone's screen) and keeps it; the image never sees it. Answers whether the host holds a token for the target now; when the developer has answered, a #targets event follows."
	^ self primCall: 'pairing' handle: nil with: {aTargetName}
]

{ #category : #transport }
ClientTransport class >> projectOf: aTargetName [
	"The project directory the host holds for aTargetName (a String, for the tools to show), or nil."
	^ self primCall: 'project' handle: nil with: {aTargetName}
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
