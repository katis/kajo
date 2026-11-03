"The common superclass of Class and Metaclass."
Class {
	#name : #ClassDescription,
	#superclass : #Behavior,
	#category : #'Kernel-Classes'
}

{ #category : #accessing }
ClassDescription >> category [
	^ Smalltalk categoryOf: self theNonMetaClass
]
