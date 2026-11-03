"A String's bytes as a read-only, constant-time indexed collection (at:, size, do:, copyFrom:to:), sharing the String."
Class {
	#name : #Utf8View,
	#superclass : #SequenceableCollection,
	#instVars : [
		'string'
	],
	#category : #'Kernel-Text'
}

{ #category : #accessing }
Utf8View class >> on: aString [
	^ self basicNew setString: aString
]

{ #category : #accessing }
Utf8View >> setString: aString [
	string := aString
]

{ #category : #accessing }
Utf8View >> size [
	^ string byteSize
]

{ #category : #accessing }
Utf8View >> at: index [
	^ string byteAt: index
]

{ #category : #accessing }
Utf8View >> at: index put: aByte [
	^ self error: 'a String''s bytes are read-only'
]

{ #category : #accessing }
Utf8View >> species [
	^ ByteArray
]
