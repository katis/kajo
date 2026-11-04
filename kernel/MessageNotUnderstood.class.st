"doesNotUnderstand: signals it; resuming answers for the message."
Class {
	#name : #MessageNotUnderstood,
	#superclass : #Error,
	#instVars : [
		'message',
		'receiver'
	],
	#category : #'Kernel-Exceptions'
}

{ #category : #accessing }
MessageNotUnderstood >> isResumable [
	^ true
]

{ #category : #accessing }
MessageNotUnderstood >> message [
	^ message
]

{ #category : #accessing }
MessageNotUnderstood >> message: aMessage receiver: anObject [
	message := aMessage.
	receiver := anObject
]

{ #category : #accessing }
MessageNotUnderstood >> messageText [
	^ receiver printString , ' does not understand #' , message selector
]

{ #category : #accessing }
MessageNotUnderstood >> receiver [
	^ receiver
]
