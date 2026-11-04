"A Process stopped for the debugger (module 9b): why (error, step, suspended), the exception, its frames from where it stopped down (live Contexts: the Process runs nothing else while stopped), and the commands clients send it. The stopped Process itself waits on the semaphore and runs each command: a command answers its request; proceed and step let it go on (serve answers), restart, retry and terminate unwind its stack and never come back."
Class {
	#name : #DebugStop,
	#superclass : #Object,
	#instVars : [
		'process',
		'exception',
		'reason',
		'frames',
		'semaphore',
		'commands',
		'mutex',
		'resumeValue',
		'resuming',
		'atSend'
	],
	#category : #'Kernel-Development'
}

{ #category : #accessing }
DebugStop >> atSend: aBoolean [
	"Whether the first frame's pc is at a send it is about to make (a step stopped at a poll) rather than after one."
	atSend := aBoolean
]

{ #category : #accessing }
DebugStop >> errorText [
	exception isNil ifTrue: [^ reason].
	^ [exception class name , ': ' , exception messageText] on: Error do: [:e | exception class name]
]

{ #category : #accessing }
DebugStop >> process [
	^ process
]

{ #category : #accessing }
DebugStop >> reason [
	^ reason
]

{ #category : #accessing }
DebugStop >> setProcess: aProcess exception: anException reason: aString frames: anArray [
	process := aProcess.
	exception := anException.
	reason := aString.
	frames := anArray.
	semaphore := Semaphore new.
	commands := OrderedCollection new.
	mutex := Mutex new.
	resuming := false.
	atSend := false
]

{ #category : #accessing }
DebugStop >> summary [
	"process.stopped's fields: the Process, why, the error, and each frame's method and source range."
	| o |
	o := JsonObject new.
	o at: 'process' put: process id; at: 'reason' put: reason; at: 'error' put: self errorText;
		at: 'frames' put: ((1 to: (frames size min: 32)) collect: [:i | self frameSummary: i]) asArray.
	^ o
]

{ #category : #commands }
DebugStop >> command: aSelector arguments: anArray replyTo: anEntry [
	"From a request's Process: queue a command for the stopped Process and wake it. anEntry is the request's {replyTo. session}, which the command answers."
	anEntry isNil ifTrue: [^ self].
	mutex critical: [commands add: (Array with: aSelector with: anArray with: anEntry)].
	semaphore signal
]

{ #category : #commands }
DebugStop >> evaluate: aString frame: anIndex replyTo: aReplyTo session: aSession [
	| value |
	value := Compiler evaluate: aString in: (self frameAt: anIndex).
	DevProtocol reply: aReplyTo result: (aSession describe: value)
]

{ #category : #commands }
DebugStop >> framesReplyTo: aReplyTo session: aSession [
	DevProtocol reply: aReplyTo result: ((1 to: frames size) collect: [:i | self frameDetail: i session: aSession]) asArray
]

{ #category : #commands }
DebugStop >> proceed: aValue replyTo: aReplyTo session: aSession [
	DevProtocol reply: aReplyTo result: true.
	resumeValue := aValue.
	resuming := true
]

{ #category : #commands }
DebugStop >> restart: anIndex replyTo: aReplyTo session: aSession [
	"Restart a frame: its sender runs again the send that made it, with the frame's receiver (a block frame's closure) and arguments; the frames above unwind."
	| f s send operands |
	f := self frameAt: anIndex.
	s := f sender.
	s isNil ifTrue: [^ self error: 'the bottom frame has no send to run again'].
	send := s sendBeforePc.
	send isNil ifTrue: [^ self error: 'the frame was not entered by a send'].
	operands := OrderedCollection new.
	f method isBlockMethod
		ifTrue: [operands add: f closure]
		ifFalse: [
			send first == f method selector ifFalse: [
				^ self error: 'the frame was entered by ' , send first printString , ', not by a send of its selector: restart its sender'].
			operands add: f receiver].
	1 to: f method numArgs do: [:i | operands add: (f tempAt: i)].
	operands size = (send last + 1) ifFalse: [^ self error: 'the send takes ' , send last printString , ' arguments, the frame ' , f method numArgs printString].
	DevProtocol reply: aReplyTo result: true.
	self leave.
	s restartSendWith: operands asArray
]

{ #category : #commands }
DebugStop >> retrySendReplyTo: aReplyTo session: aSession [
	"At doesNotUnderstand:, send the message again from where it was sent: looked up again, so a method defined since answers it."
	| dnu s send msg |
	(exception isKindOf: MessageNotUnderstood) ifFalse: [^ self error: 'the Process did not stop at doesNotUnderstand:'].
	dnu := exception signalerContext.
	(dnu notNil and: [dnu method selector == #doesNotUnderstand:]) ifFalse: [^ self error: 'no doesNotUnderstand: frame'].
	s := dnu sender.
	msg := exception message.
	send := s isNil ifTrue: [nil] ifFalse: [s sendBeforePc].
	(send notNil and: [send first == msg selector]) ifFalse: [^ self error: 'the message was not sent by a send of ' , msg selector printString].
	DevProtocol reply: aReplyTo result: true.
	self leave.
	s restartSendWith: (Array with: exception receiver) , msg arguments
]

{ #category : #commands }
DebugStop >> step: aMode frame: anIndex replyTo: aReplyTo session: aSession [
	"Let the Process go on and stop it again where the step ends: into, over or out of frame anIndex. A frame that is not at a send it is about to make goes on after its last send (after an error, into is over: the frame goes on after the send that failed)."
	| mode f |
	mode := (#('into' 'over' 'out') indexOf: aMode asString).
	mode = 0 ifTrue: [^ self error: 'a step is into, over or out'].
	f := self frameAt: anIndex.
	reason = 'error' ifTrue: [mode = 1 ifTrue: [mode := 2]].
	(anIndex = 1 and: [atSend]) ifFalse: [mode := mode + 4].
	DevProtocol reply: aReplyTo result: true.
	self leave.
	resumeValue := nil.
	resuming := true.
	process primStep: mode frame: f
]

{ #category : #commands }
DebugStop >> terminateReplyTo: aReplyTo session: aSession [
	DevProtocol reply: aReplyTo result: true.
	self leave.
	process terminateUnwinding
]

{ #category : #frames }
DebugStop >> frameAt: anIndex [
	| i |
	i := anIndex ifNil: [1].
	(i isInteger and: [i between: 1 and: frames size]) ifFalse: [^ self error: 'no frame ' , i printString].
	^ frames at: i
]

{ #category : #frames }
DebugStop >> frameDetail: anIndex session: aSession [
	"A frame for the debugger: frameSummary and the receiver and variables described, and the source."
	| f o vars |
	f := frames at: anIndex.
	o := self frameSummary: anIndex.
	o at: 'receiver' put: (aSession describe: f receiver).
	vars := OrderedCollection new.
	(Compiler frameVariablesOf: f method) do: [:v | | value |
		value := [| x | x := f tempAt: (v at: 2). (v at: 3) isNil ifTrue: [x] ifFalse: [x isNil ifTrue: [nil] ifFalse: [x at: (v at: 3)]]]
			on: Error do: [:e | nil].
		vars add: ((aSession describe: value) at: 'name' put: v first; yourself)].
	o at: 'variables' put: vars asArray; at: 'source' put: f method sourceCode.
	^ o
]

{ #category : #frames }
DebugStop >> frameSummary: anIndex [
	"index, method, pc and the source range the pc is at ({start. end}, byte offsets from 1 in the method's source): the send the frame is in, or for the frame a step stopped, the send it is about to make."
	| f o pc range |
	f := frames at: anIndex.
	o := JsonObject new.
	pc := f pc.
	range := (anIndex = 1 and: [atSend])
		ifTrue: [f method sourceRangeAt: pc]
		ifFalse: [f method sourceRangeAt: pc - 1].
	o at: 'index' put: anIndex; at: 'method' put: f method printString; at: 'pc' put: pc; at: 'range' put: range.
	^ o
]

{ #category : #serving }
DebugStop >> leave [
	Debugger unpark: self
]

{ #category : #serving }
DebugStop >> nextCommand [
	^ mutex critical: [commands isEmpty ifTrue: [nil] ifFalse: [commands removeFirst]]
]

{ #category : #serving }
DebugStop >> serve [
	"Wait for commands and run them, until one lets the Process go on: answer its value."
	[true] whileTrue: [ | cmd |
		semaphore wait.
		cmd := self nextCommand.
		cmd isNil ifFalse: [
			[self perform: cmd first withArguments: (cmd at: 2) , (Array with: (cmd at: 3) first with: (cmd at: 3) last)]
				on: Error do: [:e | DevProtocol reply: (cmd at: 3) first error: e printString].
			resuming ifTrue: [
				(cmd first == #step:frame:replyTo:session:) ifFalse: [self leave].
				^ resumeValue]]]
]

{ #category : #'instance creation' }
DebugStop class >> process: aProcess exception: anException reason: aString frames: anArray [
	^ self new setProcess: aProcess exception: anException reason: aString frames: anArray
]
