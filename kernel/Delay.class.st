"Suspends the Process for a time (the VM's one-shot timer signals a Semaphore)."
Class {
	#name : #Delay,
	#superclass : #Object,
	#instVars : [
		'milliseconds'
	],
	#category : #'Kernel-Processes'
}

{ #category : #accessing }
Delay class >> forMilliseconds: n [
	^ self basicNew setMilliseconds: n
]

{ #category : #accessing }
Delay class >> forSeconds: n [
	^ self forMilliseconds: n * 1000
]

{ #category : #accessing }
Delay >> setMilliseconds: n [
	milliseconds := n
]

{ #category : #accessing }
Delay >> wait [
	| s |
	s := Semaphore new.
	self delay: milliseconds signal: s.
	s wait
]
