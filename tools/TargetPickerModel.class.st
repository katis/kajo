"The target picker's model (module 9c): the targets the shell knows (its own transport, the local target; those of ~/.kajo/targets; since module 9d the phones Bonjour finds, listed again when the host's targets change) and those entered by hand, which are connected, and connect and disconnect. Each target's state follows its client: connecting, open, reconnecting (a dropped link, module 9d), lost. Tokens stay in the shell: a target is connected by its name or address, with the token the shell holds or one entered."
Class {
	#name : #TargetPickerModel,
	#superclass : #ToolModel,
	#instVars : [
		'targets',
		'connectAction',
		'targetsSource',
		'clientLookup'
	],
	#category : #'Tools-Models'
}

{ #category : #accessing }
TargetPickerModel >> clientLookup: aBlock [
	"aBlock answers the client of a target's name (DevTools' by default; tests give their own)."
	clientLookup := aBlock
]

{ #category : #accessing }
TargetPickerModel >> connectAction: aBlock [
	"aBlock gets a name, a socket path and a token or nil, and answers the client (DevTools connects)."
	connectAction := aBlock
]

{ #category : #accessing }
TargetPickerModel >> rows [
	"{name. path. state} of each target."
	^ (self targets collect: [:t | {t first. t at: 2. self stateOf: t first}]) asArray
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
TargetPickerModel >> add: aPath name: aName token: aTokenOrNil [
	"A target entered by hand, connected at once."
	targets := self targets , {{aName. aPath. aTokenOrNil notNil}}.
	self changed: #targets.
	self connect: aName token: aTokenOrNil
]

{ #category : #targets }
TargetPickerModel >> connect: aName token: aTokenOrNil [
	| t c |
	t := self targets detect: [:x | x first = aName] ifNone: [^ self status: 'no target ' , aName].
	connectAction isNil ifTrue: [^ self status: 'cannot connect'].
	c := connectAction value: aName value: (t at: 2) value: aTokenOrNil.
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
TargetPickerModel >> refresh [
	"The shell's targets, and those added by hand."
	| known |
	known := targetsSource isNil ifTrue: [ClientTransport targets] ifFalse: [targetsSource value].
	targets := known , (self targets reject: [:t | known anySatisfy: [:k | k first = t first]]).
	self changed: #targets
]
