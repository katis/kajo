"Run by SUnitTest, not by kajo test (isAbstract)."
Class {
	#name : #SUnitSample,
	#superclass : #TestCase,
	#instVars : [
		'log'
	]
}

{ #category : #accessing }
SUnitSample >> log [
	^ log
]

{ #category : #accessing }
SUnitSample >> setUp [
	log := OrderedCollection with: #setUp
]

{ #category : #accessing }
SUnitSample >> tearDown [
	log add: #tearDown
]

{ #category : #accessing }
SUnitSample >> testError [
	^ 1 / 0
]

{ #category : #accessing }
SUnitSample >> testExpectedFailure [
	<expectedFailure>
	self assert: false
]

{ #category : #accessing }
SUnitSample >> testFail [
	self assert: false
]

{ #category : #accessing }
SUnitSample >> testPass [
	log add: #testPass.
	self assert: true
]

{ #category : #accessing }
SUnitSample >> testShouldFails [
	self should: [1 + 1] raise: ZeroDivide
]

{ #category : #accessing }
SUnitSample >> testUnexpectedPass [
	<expectedFailure>
	self assert: true
]

{ #category : #accessing }
SUnitSample class >> isAbstract [
	^ true
]
