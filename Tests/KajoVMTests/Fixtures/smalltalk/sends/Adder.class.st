"sends in Smalltalk (module 8b): the kasm kernel sends.kasm written in kernel style and compiled by the bootstrap compiler. One polymorphic call site (step:) over receivers of three classes and an at: per iteration; Leaf inherits step: from Adder."
Class {
	#name : #Adder,
	#superclass : #Object,
	#category : #Bench
}

{ #category : #bench }
Adder >> step: n [
	^ n + 1
]
