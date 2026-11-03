"ivars in Smalltalk (module 8b): ivars.kasm in kernel style. A tight loop reading and writing the instance variables of four receivers."
Class {
	#name : #Cell,
	#superclass : #Object,
	#instVars : [ 'a', 'b', 'c', 'd' ],
	#category : #Bench
}

{ #category : #bench }
Cell >> init: x [
	a := x.
	b := x.
	c := x.
	d := 0
]

{ #category : #bench }
Cell >> spin: n [
	| m |
	m := n.
	[m > 0] whileTrue: [
		a := a + b.
		a >= 1000003 ifTrue: [a := a - 1000003].
		c := c + a.
		c >= 1000003 ifTrue: [c := c - 1000003].
		b := b + 1.
		b < 1000 ifFalse: [b := 0].
		d := d + 1.
		m := m - 1]
]

{ #category : #bench }
Cell >> sum [
	^ a + b + c + d
]
