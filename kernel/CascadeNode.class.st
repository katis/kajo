"messages: Arrays of selector, arguments and line."
Class {
	#name : #CascadeNode,
	#superclass : #ParseNode,
	#instVars : [
		'receiver',
		'messages'
	],
	#category : #'Kernel-Compiler'
}

{ #category : #accessing }
CascadeNode class >> receiver: r messages: m line: n [
	^ self new setReceiver: r messages: m; line: n; yourself
]

{ #category : #accessing }
CascadeNode >> setReceiver: r messages: m [
	receiver := r.
	messages := m
]

{ #category : #accessing }
CascadeNode >> receiver [
	^ receiver
]

{ #category : #accessing }
CascadeNode >> messages [
	^ messages
]
