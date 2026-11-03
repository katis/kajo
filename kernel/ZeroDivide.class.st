Class {
	#name : #ZeroDivide,
	#superclass : #Error,
	#instVars : [
		'dividend'
	],
	#category : #'Kernel-Exceptions'
}

{ #category : #accessing }
ZeroDivide >> dividend [
	^ dividend
]

{ #category : #accessing }
ZeroDivide >> dividend: aNumber [
	dividend := aNumber
]

{ #category : #accessing }
ZeroDivide >> isResumable [
	^ true
]
