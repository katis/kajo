Class {
	#name : #MessageNode,
	#superclass : #ParseNode,
	#instVars : [
		'receiver',
		'selector',
		'arguments',
		'inlined',
		'hidden'
	]
}

{ #category : #accessing }
MessageNode >> arguments [
	^ arguments
]

{ #category : #accessing }
MessageNode >> beInlined [
	inlined := true
]

{ #category : #accessing }
MessageNode >> hidden [
	^ hidden
]

{ #category : #accessing }
MessageNode >> isInlined [
	^ inlined
]

{ #category : #accessing }
MessageNode >> isSuper [
	^ receiver class == VariableNode and: [receiver name = 'super']
]

{ #category : #accessing }
MessageNode >> receiver [
	^ receiver
]

{ #category : #accessing }
MessageNode >> selector [
	^ selector
]

{ #category : #accessing }
MessageNode >> setReceiver: r selector: s arguments: a [
	receiver := r.
	selector := s.
	arguments := a.
	inlined := false.
	hidden := OrderedCollection new
]

{ #category : #accessing }
MessageNode class >> receiver: r selector: s arguments: a line: n [
	^ self new setReceiver: r selector: s arguments: a; line: n; yourself
]
