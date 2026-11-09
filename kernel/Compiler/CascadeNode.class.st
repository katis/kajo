"messages: Arrays of selector, arguments, line and the source range (start, end; module 9b)."
Class {
	#name : #CascadeNode,
	#superclass : #ParseNode,
	#instVars : [
		'receiver',
		'messages'
	]
}

{ #category : #accessing }
CascadeNode >> messages [
	^ messages
]

{ #category : #accessing }
CascadeNode >> receiver [
	^ receiver
]

{ #category : #accessing }
CascadeNode >> setReceiver: r messages: m [
	receiver := r.
	messages := m
]

{ #category : #accessing }
CascadeNode class >> receiver: r messages: m line: n [
	^ self new setReceiver: r messages: m; line: n; yourself
]
