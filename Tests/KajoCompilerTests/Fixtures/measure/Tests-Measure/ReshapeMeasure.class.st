"Module 8e's measurement: a class of 50 methods and 10 000 instances given one more instance variable; answers the microseconds the whole change took (the recompile in Smalltalk and the primitive's stop), the stop itself is in the VM's stop log."
Class {
	#name : #ReshapeMeasure,
	#superclass : #Object,
	#classInstVars : [
		'chunks'
	]
}

{ #category : #measuring }
ReshapeMeasure class >> run [
	| c t0 t1 ok |
	c := Object subclass: #ReshapeMeasured instanceVariableNames: 'a b c' classVariableNames: '' package: 'Measure' tag: 'Tests-Measure'.
	1 to: 50 do: [:i | c compile: 'm' , i printString , ' ^ a + b + c + ' , i printString].
	chunks := (1 to: 5) collect: [:k | (1 to: 2000) collect: [:i | c basicNew instVarAt: 1 put: i; instVarAt: 2 put: k; instVarAt: 3 put: 0; yourself]].
	t0 := Smalltalk microsecondClock.
	c instanceVariableNames: 'a z b c'.
	t1 := Smalltalk microsecondClock.
	ok := chunks allSatisfy: [:ch | ch allSatisfy: [:x | x basicSize = 0 and: [(x instVarAt: 1) notNil and: [(x instVarAt: 2) isNil and: [x m7 = ((x instVarAt: 1) + (x instVarAt: 3) + 7)]]]]].
	chunks := nil.
	Smalltalk removeClass: c.
	^ ok ifTrue: [t1 - t0] ifFalse: [-1]
]
