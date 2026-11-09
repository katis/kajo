"A Dictionary by key identity (== and identityHash): Symbols, classes."
Class {
	#name : #IdentityDictionary,
	#superclass : #Dictionary
}

{ #category : #accessing }
IdentityDictionary >> equal: a to: b [
	^ a == b
]

{ #category : #accessing }
IdentityDictionary >> hashFor: anObject [
	^ anObject identityHash
]
