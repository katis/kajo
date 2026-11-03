"The class of a class. Foo class superclass is Foo superclass class; Object class superclass is Class."
Class {
	#name : #Metaclass,
	#superclass : #ClassDescription,
	#instVars : [
		'thisClass'
	],
	#category : #'Kernel-Classes'
}

{ #category : #accessing }
Metaclass >> thisClass [
	^ self slotAt: 6
]

{ #category : #accessing }
Metaclass >> soleInstance [
	^ self thisClass
]

{ #category : #accessing }
Metaclass >> theNonMetaClass [
	^ self thisClass
]

{ #category : #accessing }
Metaclass >> name [
	^ self thisClass name , ' class'
]

{ #category : #accessing }
Metaclass >> isMeta [
	^ true
]
