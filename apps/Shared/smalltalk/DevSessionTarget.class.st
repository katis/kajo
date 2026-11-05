"What the scripted developer session (apps/Shared/devsession) does to a target other than its own image (module 9d: the phone's shell image): a method that fails at a missing method and is fixed in its frame, one whose missing method is defined from the Mac's debugger and the send retried, and one that stops for the dropped link. originalFailingStep is the source the session puts back first, so a target serves several sessions."
Class {
	#name : #DevSessionTarget,
	#superclass : #Object,
	#category : #'Shell-Bench'
}

{ #category : #session }
DevSessionTarget >> definedLater [
	"undefinedStep is not defined: the debugger defines it and retries the send."
	^ self undefinedStep + 1
]

{ #category : #session }
DevSessionTarget >> failingStep [
	"missingPart is not defined; the debugger steps twice and saves a fix."
	| a |
	a := self missingPart.
	a := self twice: a.
	a := self twice: a.
	^ a
]

{ #category : #session }
DevSessionTarget >> stopForDrop [
	"Stops for the debugger and waits there while the link drops."
	^ self error: 'stopped for the dropped link'
]

{ #category : #session }
DevSessionTarget >> twice: x [
	^ x
]

{ #category : #session }
DevSessionTarget class >> originalFailingStep [
	^ 'failingStep
	"missingPart is not defined; the debugger steps twice and saves a fix."
	| a |
	a := self missingPart.
	a := self twice: a.
	a := self twice: a.
	^ a'
]
