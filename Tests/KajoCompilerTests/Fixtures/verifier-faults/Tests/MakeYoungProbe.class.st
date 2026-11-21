"The verifier's faults (docs/modules/verifier-faults.md), fault 1: a method made by primitive 143 whose literal frame holds a young object that nothing else names, kept in a class variable; and a class variable added live, its Binding made in Smalltalk, compiled into a method the plain way. The Swift test scavenges after each and reads the verifiers."
Class {
	#name : #MakeYoungProbe,
	#superclass : #Object,
	#classVars : [
		'Made'
	]
}

{ #category : #probing }
MakeYoungProbe class >> check: kind [
	"1 when the made method still answers the young object it was made with, 0 when not."
	| v |
	v := Made valueWithReceiver: self new arguments: #().
	kind = 1 ifTrue: [^ v class == self ifTrue: [1] ifFalse: [0]].
	kind = 2 ifTrue: [^ v key == #Probe ifTrue: [1] ifFalse: [0]].
	kind = 3 ifTrue: [^ v first = 7 ifTrue: [1] ifFalse: [0]].
	kind = 4 ifTrue: [^ (v includes: 4) ifTrue: [1] ifFalse: [0]].
	^ 0
]

{ #category : #probing }
MakeYoungProbe class >> forget [
	Made := nil.
	^ 0
]

{ #category : #probing }
MakeYoungProbe class >> liveClassVariable [
	"A class defined live with a class variable, a method compiled against it, then a second class variable (a new Binding made by Smalltalk undeclaredBinding:in:) and a method compiled against that: the compiler's own way to put a Binding in a literal frame. Answers 0."
	| c |
	c := Object subclass: #MakeYoungLive instanceVariableNames: '' classVariableNames: 'First' package: 'Kernel' tag: 'Tests-Live'.
	c compile: 'first ^ First ifNil: [First := 1]'.
	c := Object subclass: #MakeYoungLive instanceVariableNames: '' classVariableNames: 'First Second' package: 'Kernel' tag: 'Tests-Live'.
	c compile: 'second ^ Second ifNil: [Second := Array with: 3]'.
	^ 0
]

{ #category : #probing }
MakeYoungProbe class >> liveClassVariableCheck [
	"1 when both methods of the live class answer what they stored."
	| c |
	c := Smalltalk classNamed: #MakeYoungLive.
	^ (c new first = 1 and: [c new second first = 3]) ifTrue: [1] ifFalse: [0]
]

{ #category : #probing }
MakeYoungProbe class >> make: kind [
	"A method whose literal #placeholder is a young object of the kind asked, made by primitive 143 and kept in Made; nothing else names the object. 1 when made, -1 when the VM refused it."
	| code i |
	code := Compiler compile: 'probe ^ #placeholder' in: self.
	i := code literals indexOf: #placeholder.
	code literals at: i put: (self young: kind).
	Made := [code makeMethodIn: self] on: CompileError do: [:e | e return: nil].
	^ Made isNil ifTrue: [-1] ifFalse: [1]
]

{ #category : #probing }
MakeYoungProbe class >> young: kind [
	"A new object of each kind the make primitive takes as it is: an instance of an ordinary class, a Binding, two collections; a closure (5), which the primitive refuses."
	kind = 1 ifTrue: [^ self new].
	kind = 2 ifTrue: [^ Binding new key: #Probe].
	kind = 3 ifTrue: [^ OrderedCollection new add: 7; yourself].
	kind = 4 ifTrue: [^ Set new add: 4; yourself].
	kind = 5 ifTrue: [^ [:y | y]].
	^ nil
]
