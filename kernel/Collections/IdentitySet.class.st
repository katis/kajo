"A Set by identity (== and identityHash)."
Class {
	#name : #IdentitySet,
	#superclass : #Set
}

{ #category : #accessing }
IdentitySet >> equal: a to: b [
	^ a == b
]

{ #category : #accessing }
IdentitySet >> hashFor: anObject [
	^ anObject identityHash
]
