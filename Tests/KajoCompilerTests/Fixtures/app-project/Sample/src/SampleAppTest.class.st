"The test kajo new made for SampleApp: a press changes the label."
Class {
	#name : #SampleAppTest,
	#superclass : #TestCase,
	#category : #Sample
}

{ #category : #tests }
SampleAppTest >> testPressingChangesTheLabel [
	SampleApp open.
	self assert: SampleApp labelText equals: 'Hello from Kajo'.
	SampleApp pressed.
	self assert: SampleApp labelText equals: 'Pressed 1 times'
]
