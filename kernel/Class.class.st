"The class of every class's metaclass's sole instance: Foo is a Class, Foo class a Metaclass."
Class {
	#name : #Class,
	#superclass : #ClassDescription,
	#category : #'Kernel-Classes'
}

{ #category : #accessing }
Class >> isClass [
	^ true
]
