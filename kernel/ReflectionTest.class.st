"Classes, metaclasses, methods and their reading primitives."
Class {
	#name : #ReflectionTest,
	#superclass : #TestCase,
	#category : #'Kernel-Tests'
}

{ #category : #accessing }
ReflectionTest >> testHierarchy [
	self assert: SmallInteger superclass == Integer.
	self assert: (SmallInteger inheritsFrom: Number).
	self assert: (String inheritsFrom: ArrayedCollection).
	self assert: Symbol superclass == String.
	self assert: (Integer allSubclasses includes: LargeNegativeInteger).
	self assert: (Collection subclasses includes: SequenceableCollection).
	self assert: (Smalltalk allClasses includes: TestCase)
]

{ #category : #accessing }
ReflectionTest >> testInstanceVariableNames [
	self assert: (Smalltalk instanceVariableNamesOf: Association) = #(#key #value).
	self assert: (Smalltalk instanceVariableNamesOf: KeyNotFound) = #(#messageText #signalContext #handlerContext #outerContext #key).
	self assert: (Smalltalk instanceVariableNamesOf: Transcript class) = #(#stream #lock).
	self assert: Association allInstVarNames = #(#key #value)
]

{ #category : #accessing }
ReflectionTest >> testMetaclasses [
	self assert: 3 class class class == Metaclass.
	self assert: Object class superclass == Class.
	self assert: Integer class superclass == Number class.
	self assert: Object class class == Metaclass.
	self assert: Object class name = 'Object class'.
	self assert: Object class isMeta.
	self assert: Object class theNonMetaClass == Object
]

{ #category : #accessing }
ReflectionTest >> testMethods [
	| m |
	m := Integer >> #factorial.
	self assert: m selector == #factorial.
	self assert: m methodClass == Integer.
	self assert: m numArgs = 0.
	self assert: m printString = 'Integer>>factorial'.
	self assert: (Integer includesSelector: #factorial).
	self deny: (SmallInteger includesSelector: #factorial).
	self assert: (SmallInteger canUnderstand: #factorial).
	self assert: ((SmallInteger lookupSelector: #factorial) == m).
	self assert: (Object selectors includes: #printString).
	self assert: (BlockClosure >> #ensure:) hasUnwindMark.
	self assert: (BlockClosure >> #privateOn:do:) hasHandlerMark
]

{ #category : #accessing }
ReflectionTest >> testSmalltalk [
	self assert: (Smalltalk at: #Object) == Object.
	self assert: (Smalltalk at: #NoSuchClass ifAbsent: [nil]) isNil.
	self assert: (Smalltalk categoryOf: Object) = 'Kernel-Objects'.
	self assert: Object category = 'Kernel-Objects'
]
