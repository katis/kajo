"Scrolling text that lines are appended to (the demo's Transcript)."
Class {
	#name : #TextView,
	#superclass : #View,
	#category : #'Kernel-UI'
}

{ #category : #registry }
TextView class >> kind [
	^ 'textView'
]

{ #category : #accessing }
TextView >> appendLine: aString [
	self call: 'appendLine' with: {aString}
]

{ #category : #accessing }
TextView >> clear [
	self call: 'clear' with: #()
]

{ #category : #accessing }
TextView >> text [
	^ self get: 'text'
]

{ #category : #accessing }
TextView >> text: aString [
	self set: 'text' to: aString
]

{ #category : #accessing }
TextView >> headlessCall: aName with: anArray [
	| t |
	aName = 'clear' ifTrue: [^ self set: 'text' to: ''].
	aName = 'appendLine' ifTrue: [
		t := (self get: 'text') ifNil: [''].
		^ self set: 'text' to: (t isEmpty ifTrue: [anArray first] ifFalse: [t , (String with: Character lf) , anArray first])].
	^ nil
]
