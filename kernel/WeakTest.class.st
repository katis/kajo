"WeakArray and Ephemeron with the finalization Process."
Class {
	#name : #WeakTest,
	#superclass : #TestCase,
	#category : #'Kernel-Tests'
}

{ #category : #accessing }
WeakTest >> testWeakArrayLosesItsReferent [
	| w |
	w := WeakArray new: 2.
	w at: 1 put: Object new.
	w at: 2 put: self.
	Smalltalk garbageCollect.
	self assert: (w at: 1) isNil.
	self assert: (w at: 2) == self
]

{ #category : #accessing }
WeakTest >> testEphemeronIsMourned [
	| done log |
	done := Semaphore new.
	log := OrderedCollection new.
	Ephemeron key: Object new value: #payload finalizer: [:v | log add: v. done signal].
	Smalltalk garbageCollect.
	done wait.
	self assert: log asArray = #(#payload)
]

{ #category : #accessing }
WeakTest >> testEphemeronWithALiveKeyStays [
	| key e |
	key := Object new.
	e := Ephemeron key: key value: 3.
	Smalltalk garbageCollect.
	self assert: e key == key.
	self assert: e value = 3
]
