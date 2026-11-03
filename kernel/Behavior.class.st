"What every class and metaclass has: a superclass, a method dictionary, an instance size and an index in the VM's class table. The slots are the VM's and sealed: methods read them with slotAt:, and change them only through primitives."
Class {
	#name : #Behavior,
	#superclass : #Object,
	#instVars : [
		'superclass',
		'methodDict',
		'name',
		'instSize',
		'classIndex'
	],
	#category : #'Kernel-Classes'
}

{ #category : #'instance creation' }
Behavior >> new [
	^ self basicNew initialize
]

{ #category : #'instance creation' }
Behavior >> new: size [
	^ (self basicNew: size) initialize
]

{ #category : #'instance creation' }
Behavior >> basicNew [
	<primitive: 4>
	^ self error: 'cannot make an instance of ' , self name
]

{ #category : #'instance creation' }
Behavior >> basicNew: size [
	<primitive: 3>
	^ self error: 'cannot make an instance of ' , self name , ' with ' , size printString , ' slots'
]

{ #category : #accessing }
Behavior >> superclass [
	^ self slotAt: 1
]

{ #category : #accessing }
Behavior >> methodDictionary [
	^ self slotAt: 2
]

{ #category : #accessing }
Behavior >> instSize [
	^ self slotAt: 4
]

{ #category : #accessing }
Behavior >> classIndex [
	^ self slotAt: 5
]

{ #category : #accessing }
Behavior >> name [
	^ self slotAt: 3
]

{ #category : #accessing }
Behavior >> theNonMetaClass [
	^ self
]

{ #category : #testing }
Behavior >> isBehavior [
	^ true
]

{ #category : #testing }
Behavior >> isMeta [
	^ false
]

{ #category : #testing }
Behavior >> inheritsFrom: aClass [
	| c |
	c := self superclass.
	[c == nil] whileFalse: [
		c == aClass ifTrue: [^ true].
		c := c superclass].
	^ false
]

{ #category : #testing }
Behavior >> includesBehavior: aClass [
	^ self == aClass or: [self inheritsFrom: aClass]
]

{ #category : #methods }
Behavior >> selectors [
	"The selectors of the receiver's own methods, an Array."
	| d out |
	d := self methodDictionary.
	d == nil ifTrue: [^ #()].
	out := OrderedCollection new.
	1 to: d basicSize by: 2 do: [:i | | k | k := d slotAt: i. k == nil ifFalse: [out add: k]].
	^ out asArray
]

{ #category : #methods }
Behavior >> includesSelector: aSymbol [
	^ (self compiledMethodAt: aSymbol ifAbsent: [nil]) notNil
]

{ #category : #methods }
Behavior >> compiledMethodAt: aSymbol [
	^ self compiledMethodAt: aSymbol ifAbsent: [self error: self name , ' has no method ' , aSymbol]
]

{ #category : #methods }
Behavior >> compiledMethodAt: aSymbol ifAbsent: aBlock [
	| d |
	d := self methodDictionary.
	d == nil ifTrue: [^ aBlock value].
	1 to: d basicSize by: 2 do: [:i | (d slotAt: i) == aSymbol ifTrue: [^ d slotAt: i + 1]].
	^ aBlock value
]

{ #category : #methods }
Behavior >> >> aSymbol [
	^ self compiledMethodAt: aSymbol
]

{ #category : #methods }
Behavior >> methodsDo: aBlock [
	| d |
	d := self methodDictionary.
	d == nil ifTrue: [^ self].
	1 to: d basicSize by: 2 do: [:i | (d slotAt: i) == nil ifFalse: [aBlock value: (d slotAt: i + 1)]]
]

{ #category : #methods }
Behavior >> lookupSelector: aSymbol [
	| c |
	c := self.
	[c == nil] whileFalse: [
		(c compiledMethodAt: aSymbol ifAbsent: [nil]) ifNotNil: [:m | ^ m].
		c := c superclass].
	^ nil
]

{ #category : #methods }
Behavior >> canUnderstand: aSymbol [
	^ (self lookupSelector: aSymbol) notNil
]

{ #category : #methods }
Behavior >> addSelector: aSymbol withMethod: aCompiledMethod [
	"Install a method (verified by the VM against this class) and note its pragmas."
	| old |
	old := self compiledMethodAt: aSymbol ifAbsent: [nil].
	self primAddSelector: aSymbol withMethod: aCompiledMethod.
	Pragma noteRemoved: old; noteInstalled: aCompiledMethod
]

{ #category : #methods }
Behavior >> removeSelector: aSymbol [
	| old |
	old := self compiledMethodAt: aSymbol ifAbsent: [^ nil].
	self primRemoveSelector: aSymbol.
	Pragma noteRemoved: old.
	^ old
]

{ #category : #methods }
Behavior >> primAddSelector: aSymbol withMethod: aCompiledMethod [
	<primitive: 97>
	^ self error: 'the VM refused the method ' , aSymbol printString
]

{ #category : #methods }
Behavior >> primRemoveSelector: aSymbol [
	<primitive: 98>
	^ self error: 'cannot remove ' , aSymbol printString
]

{ #category : #hierarchy }
Behavior >> allSuperclasses [
	| out c |
	out := OrderedCollection new.
	c := self superclass.
	[c == nil] whileFalse: [out add: c. c := c superclass].
	^ out
]

{ #category : #hierarchy }
Behavior >> withAllSuperclasses [
	^ (OrderedCollection with: self) addAll: self allSuperclasses; yourself
]

{ #category : #hierarchy }
Behavior >> subclasses [
	^ (Smalltalk allClasses select: [:c | c superclass == self]) asArray
]

{ #category : #hierarchy }
Behavior >> allSubclasses [
	| out |
	out := OrderedCollection new.
	Smalltalk allClasses do: [:c | (c inheritsFrom: self) ifTrue: [out add: c]].
	^ out
]

{ #category : #hierarchy }
Behavior >> allInstVarNames [
	^ Smalltalk instanceVariableNamesOf: self
]

{ #category : #printing }
Behavior >> printOn: aStream [
	aStream nextPutAll: self name
]
