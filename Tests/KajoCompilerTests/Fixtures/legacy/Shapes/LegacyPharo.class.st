"A Pharo 12 style class file (tags as subdirectories' bar): #package and #tag keys in the definition, which both readers read and ignore. Its package is the directory it is read from (legacy, so Legacy) and its tag the subdirectory (Shapes), not what the keys say."
Class {
	#name : #LegacyPharo,
	#superclass : #Object,
	#instVars : [
		'side'
	],
	#package : #'Elsewhere',
	#tag : #'Wrong'
}

{ #category : #accessing }
LegacyPharo >> side [
	^ side ifNil: [3]
]
