"The target picker's model (module 9c): the targets the shell knows (its own transport, the local target; those of ~/.kajo/targets; since module 9d the phones Bonjour finds, listed again when the host's targets change) and those entered by hand, which are connected, and connect and disconnect. Each target's state follows its client: connecting, open, reconnecting (a dropped link, module 9d), lost. Tokens stay in the shell: a target is connected by its name or address with the token the shell holds; a token is never typed into the image: pair: asks the shell to take it in a secure field of its own. The project directory (2026-11-11, docs/modules/project-directory.md): each target's row shows the directory the shell holds for it (where the files of accepted changes go), and chooseProject: asks the shell to ask the developer for one in a panel of its own; the image never names a directory."
Class {
	#name : #TargetPickerModel,
	#superclass : #ToolModel,
	#instVars : [
		'targets',
		'connectAction',
		'targetsSource',
		'clientLookup',
		'pairAction',
		'projectSource',
		'chooseProjectAction'
	]
}

{ #category : #accessing }
TargetPickerModel >> chooseProjectAction: aBlock [
	"aBlock asks the host to ask the developer for a target's project directory (ClientTransport chooseProject: by default; tests give their own)."
	chooseProjectAction := aBlock
]

{ #category : #accessing }
TargetPickerModel >> clientLookup: aBlock [
	"aBlock answers the client of a target's name (DevTools' by default; tests give their own)."
	clientLookup := aBlock
]

{ #category : #accessing }
TargetPickerModel >> connectAction: aBlock [
	"aBlock gets a name and an address, and answers the client (DevTools connects)."
	connectAction := aBlock
]

{ #category : #accessing }
TargetPickerModel >> pairAction: aBlock [
	"aBlock asks the host to pair a target's name (ClientTransport pair: by default; tests give their own)."
	pairAction := aBlock
]

{ #category : #accessing }
TargetPickerModel >> projectOf: aName [
	"The project directory the host holds for aName, or '' when none."
	| d |
	d := projectSource isNil ifTrue: [ClientTransport projectOf: aName] ifFalse: [projectSource value: aName].
	^ d ifNil: ['']
]

{ #category : #accessing }
TargetPickerModel >> projectSource: aBlock [
	"aBlock answers the project directory the host holds for a target's name, or nil (ClientTransport projectOf: by default; tests give their own)."
	projectSource := aBlock
]

{ #category : #accessing }
TargetPickerModel >> rows [
	"{name. address. state. project directory} of each target (a target the host holds no token for says so: pair it; one it holds no directory for shows none: choose it with Project…)."
	^ (self targets collect: [:t | {t first. t at: 2. (self stateOf: t first) , ((t at: 3) == true ifTrue: [''] ifFalse: [', no token']). self projectOf: t first}]) asArray
]

{ #category : #accessing }
TargetPickerModel >> stateOf: aName [
	| c |
	c := clientLookup isNil ifTrue: [DevTools clientNamed: aName] ifFalse: [clientLookup value: aName].
	c isNil ifTrue: [^ 'not connected'].
	^ c state asString
]

{ #category : #accessing }
TargetPickerModel >> targets [
	^ targets ifNil: [#()]
]

{ #category : #accessing }
TargetPickerModel >> targetsSource: aBlock [
	"aBlock answers the host's targets, {name. address. holds a token} each (ClientTransport targets by default; tests give their own)."
	targetsSource := aBlock
]

{ #category : #targets }
TargetPickerModel >> add: anAddress name: aName [
	"A target entered by hand (its address: a socket path, tcp://host:port, bonjour:<name>), connected at once with the token the host holds for it; without one, pair it first."
	targets := self targets , {{aName. anAddress. false}}.
	self changed: #targets.
	self connect: aName
]

{ #category : #targets }
TargetPickerModel >> chooseProject: aName [
	"The host asks the developer for aName's project directory in a panel of its own and keeps it: no directory passes through this image. The targets are listed again when the developer has chosen (a #targets event)."
	| held |
	held := chooseProjectAction isNil ifTrue: [ClientTransport chooseProject: aName] ifFalse: [chooseProjectAction value: aName].
	held isNil ifTrue: [^ self status: 'no project panel: this image runs without a shell that has one'].
	self status: aName , ': choose its project directory in the panel the shell shows'
]

{ #category : #targets }
TargetPickerModel >> connect: aName [
	| t c |
	t := self targets detect: [:x | x first = aName] ifNone: [^ self status: 'no target ' , aName].
	connectAction isNil ifTrue: [^ self status: 'cannot connect'].
	c := connectAction value: aName value: (t at: 2).
	c isNil ifTrue: [^ self status: 'no transport: this image runs without a shell'].
	self status: aName , ': connecting'.
	c on: 'connection.open' do: [:i | self status: aName , ': connected (' , ((i at: 'requests') ifNil: [0]) printString , ' requests)'. self changed: #targets].
	c on: 'connection.refused' do: [:e | self status: aName , ': refused: ' , e displayString. self changed: #targets].
	c on: 'connection.lost' do: [:e | self status: aName , ': ' , e displayString. self changed: #targets].
	c on: 'connection.reconnecting' do: [:ms | self status: aName , ': reconnecting in ' , (ms // 1000) printString , ' s (' , c lostReason displayString , ')'. self changed: #targets].
	self changed: #targets
]

{ #category : #targets }
TargetPickerModel >> disconnect: aName [
	(DevTools clientNamed: aName) ifNotNil: [:c | c close].
	self status: aName , ': closing'
]

{ #category : #targets }
TargetPickerModel >> pair: aName [
	"The host asks for aName's token in a secure field of its own (the developer reads it off the phone's screen) and keeps it: no token passes through this image. The targets are listed again when the host has it (a #targets event)."
	| held |
	held := pairAction isNil ifTrue: [ClientTransport pair: aName] ifFalse: [pairAction value: aName].
	held isNil ifTrue: [^ self status: 'no transport: this image runs without a shell'].
	self status: aName , ': enter its token in the field the shell shows'
]

{ #category : #targets }
TargetPickerModel >> refresh [
	"The shell's targets, and those added by hand."
	| known |
	known := targetsSource isNil ifTrue: [ClientTransport targets] ifFalse: [targetsSource value].
	targets := known , (self targets reject: [:t | known anySatisfy: [:k | k first = t first]]).
	self changed: #targets
]
