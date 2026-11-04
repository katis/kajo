"A named list of tests."
Class {
	#name : #TestSuite,
	#superclass : #Object,
	#instVars : [
		'name',
		'tests'
	],
	#category : #SUnit
}

{ #category : #accessing }
TestSuite >> addTest: aTest [
	tests add: aTest
]

{ #category : #accessing }
TestSuite >> name [
	^ name
]

{ #category : #accessing }
TestSuite >> run [
	| r |
	r := TestResult new.
	self run: r.
	^ r
]

{ #category : #accessing }
TestSuite >> run: aResult [
	tests do: [:t | aResult runCase: t]
]

{ #category : #accessing }
TestSuite >> setName: aString [
	name := aString.
	tests := OrderedCollection new
]

{ #category : #accessing }
TestSuite >> tests [
	^ tests
]

{ #category : #accessing }
TestSuite class >> named: aString [
	^ self basicNew setName: aString
]
