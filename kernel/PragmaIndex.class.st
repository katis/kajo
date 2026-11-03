"The pragma index (kernel.md ''Pragmas''): pragma selector to the Pragmas of every installed method that has one. Built by the kernel's initialization, kept by installation and removal, saved with the image."
Class {
	#name : #PragmaIndex,
	#superclass : #Object,
	#classInstVars : [
		'table'
	],
	#category : #'Kernel-Methods'
}

{ #category : #accessing }
PragmaIndex class >> table [
	^ table
]

{ #category : #accessing }
PragmaIndex class >> table: anIdentityDictionary [
	table := anIdentityDictionary
]
