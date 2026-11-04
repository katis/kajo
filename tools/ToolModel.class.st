"What a tool shows and asks its target (module 9c): a client, the window showing it (nil when tested headless), a status line. Every change of what it shows is changed: anAspect, which the window turns into view calls; the tests check the model and the requests it sent (FakeDevClient)."
Class {
	#name : #ToolModel,
	#superclass : #Object,
	#instVars : [
		'client',
		'view',
		'status'
	],
	#category : #'Tools-Models'
}

{ #category : #accessing }
ToolModel >> client [
	^ client
]

{ #category : #accessing }
ToolModel >> client: aDevClient [
	client := aDevClient
]

{ #category : #accessing }
ToolModel >> status [
	^ status ifNil: ['']
]

{ #category : #accessing }
ToolModel >> status: aString [
	status := aString.
	self changed: #status
]

{ #category : #accessing }
ToolModel >> view [
	^ view
]

{ #category : #accessing }
ToolModel >> view: aToolWindow [
	view := aToolWindow
]

{ #category : #closing }
ToolModel >> closed [
	"The window closed: let go of what the target holds for this tool."
	^ self
]

{ #category : #requests }
ToolModel >> request: aKind args: anArray then: aBlock [
	"Send a request through the client (anArray: its arguments as name, value pairs); its error goes to this tool's status line."
	client isNil ifTrue: [^ self status: 'not connected'].
	^ client request: aKind args: anArray then: aBlock else: [:e | self failed: e]
]

{ #category : #updating }
ToolModel >> changed: anAspect [
	view isNil ifFalse: [view update: anAspect]
]

{ #category : #updating }
ToolModel >> failed: aString [
	"A request's error: the status line."
	self status: aString
]
