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

{ #category : #accessing }
Behavior >> classIndex [
	^ self slotAt: 5
]

{ #category : #accessing }
Behavior >> instSize [
	^ self slotAt: 4
]

{ #category : #accessing }
Behavior >> methodDictionary [
	^ self slotAt: 2
]

{ #category : #accessing }
Behavior >> name [
	^ self slotAt: 3
]

{ #category : #accessing }
Behavior >> superclass [
	^ self slotAt: 1
]

{ #category : #accessing }
Behavior >> theNonMetaClass [
	^ self
]

{ #category : #'class variables' }
Behavior >> bindingOf: aString [
	"The Binding a method of this class reaches through the name aString: a class variable's, or nil (classes are not bound; Smalltalk at: answers them)."
	^ self classVariableNamed: aString
]

{ #category : #'class variables' }
Behavior >> classPool [
	"This class's own class variables: a new IdentityDictionary from each name to its Binding."
	| d |
	d := IdentityDictionary new.
	self classPoolBindings do: [:b | d at: b key put: b].
	^ d
]

{ #category : #'class variables' }
Behavior >> classPoolBindings [
	"The Bindings of the class variables this class declares (its metaclass's pool, module 8d), an Array."
	^ (self theNonMetaClass class slotAt: 7) ifNil: [#()]
]

{ #category : #'class variables' }
Behavior >> classVarNames [
	"The names of the class variables this class declares, Symbols."
	^ self classPoolBindings collect: [:b | b key]
]

{ #category : #'class variables' }
Behavior >> classVariableNamed: aString [
	"The Binding of the class variable aString names that this class sees (its own, then its superclasses'), or nil. The class side sees the same."
	| sym c |
	sym := Symbol lookup: aString.
	sym isNil ifTrue: [^ nil].
	c := self theNonMetaClass.
	[c == nil] whileFalse: [
		c classPoolBindings do: [:b | b key == sym ifTrue: [^ b]].
		c := c superclass].
	^ nil
]

{ #category : #'class variables' }
Behavior >> classVariableOwnerOf: aString [
	"The class that declares the class variable aString names, as this class sees it, or nil."
	| sym c |
	sym := Symbol lookup: aString.
	sym isNil ifTrue: [^ nil].
	c := self theNonMetaClass.
	[c == nil] whileFalse: [
		(c classPoolBindings anySatisfy: [:b | b key == sym]) ifTrue: [^ c].
		c := c superclass].
	^ nil
]

{ #category : #compiling }
Behavior >> compile: aString [
	"Compile a method's source with the compiler in Smalltalk, have the VM make and verify it, install it (replacing a method of that selector), record its source and keep the pragma index (module 8d) and its category: the replaced method's, else 'as yet unclassified' (module 8e). Answers the selector; a CompileError when the source or the VM refuses it, InstallForbidden in a release image."
	^ self compile: aString classified: nil
]

{ #category : #compiling }
Behavior >> compile: aString classified: aCategoryOrNil [
	"compile:, the method filed under aCategoryOrNil (a String or Symbol; nil keeps the replaced method's category, or 'as yet unclassified')."
	| method old category |
	Smalltalk isReleaseImage ifTrue: [^ InstallForbidden new behavior: self selector: nil; signal].
	method := (Compiler compile: aString in: self) makeMethodIn: self.
	old := self compiledMethodAt: method selector ifAbsent: [nil].
	category := aCategoryOrNil isNil
		ifTrue: [(self categoryOf: method selector) ifNil: [Behavior defaultCategory]]
		ifFalse: [aCategoryOrNil asSymbol].
	self addSelector: method selector withMethod: method.
	Smalltalk noteSource: aString of: method.
	Smalltalk noteCategory: category of: method selector in: self.
	old ifNotNil: [:m | Smalltalk forgetSourceOf: m].
	DevProtocol noteChangeOf: method selector in: self.
	^ method selector
]

{ #category : #hierarchy }
Behavior >> allInstVarNames [
	^ Smalltalk instanceVariableNamesOf: self
]

{ #category : #hierarchy }
Behavior >> allSubclasses [
	| out |
	out := OrderedCollection new.
	Smalltalk allClasses do: [:c | (c inheritsFrom: self) ifTrue: [out add: c]].
	^ out
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
Behavior >> subclasses [
	^ (Smalltalk allClasses select: [:c | c superclass == self]) asArray
]

{ #category : #hierarchy }
Behavior >> withAllSubclasses [
	"The receiver, then every class that inherits from it, each after its superclass."
	^ (OrderedCollection with: self) addAll: (self allSubclasses asArray sort: [:a :b | a allSuperclasses size <= b allSuperclasses size]); yourself
]

{ #category : #hierarchy }
Behavior >> withAllSuperclasses [
	^ (OrderedCollection with: self) addAll: self allSuperclasses; yourself
]

{ #category : #'instance creation' }
Behavior >> basicNew [
	<primitive: 4>
	^ self error: 'cannot make an instance of ' , self name
]

{ #category : #'instance creation' }
Behavior >> basicNew: size [
	"Module 10: past 4095 slots (32 760 bytes) the instance is a large object, old at birth. The largest pointer object has 16777215 slots; large bytes: the largest byte object 2147483647 bytes (of a words class, as many elements as fit)."
	<primitive: 3>
	| kinds limit |
	kinds := #(#bytes #words16 #words32 #words64).
	limit := (kinds includes: (ClassBuilder kindOf: self))
		ifTrue: [2147483647 // (#(1 2 4 8) at: (kinds indexOf: (ClassBuilder kindOf: self)))]
		ifFalse: [16777215].
	(size isInteger and: [size > limit]) ifTrue: [
		^ self error: 'cannot make an instance of ' , self name , ' with ' , size printString , ' slots: the largest object has ' , limit printString].
	(size isInteger and: [size > 4095]) ifTrue: [
		^ self error: 'cannot make an instance of ' , self name , ' with ' , size printString , ' slots: no room in the heap for a large object of that size'].
	^ self error: 'cannot make an instance of ' , self name , ' with ' , size printString , ' slots'
]

{ #category : #'instance creation' }
Behavior >> new [
	^ self basicNew initialize
]

{ #category : #'instance creation' }
Behavior >> new: size [
	^ (self basicNew: size) initialize
]

{ #category : #instances }
Behavior >> allInstances [
	"Every object whose class is the receiver, at most 100 000 of them (allInstances: for more). A development image holds millions of objects, and one Array of all of them would be a stop a frame long (the discoverability follow-up's open question 3, built with a limit as recommended). The objects are found in one stop of the world after every young one is promoted, so an object nothing reaches any more is still an instance until a collection frees it (send Smalltalk garbageCollect first for the live ones only). The immediate classes (SmallInteger, SmallFloat, Character) have no instances in the heap and answer #(); UndefinedObject, True and False answer their one instance."
	^ self allInstances: 100000
]

{ #category : #instances }
Behavior >> allInstances: aLimit [
	"Every object whose class is the receiver, at most aLimit of them (an Integer from 0 to 16777215, the largest Array): primitive 167, one walk of old space in a stop. See allInstances."
	^ self instancesOf: {self} limit: aLimit
]

{ #category : #instances }
Behavior >> allSubInstances [
	"Every object whose class is the receiver or inherits from it, at most 100 000 of them; one walk of old space with every such class at once. See allInstances."
	^ self allSubInstances: 100000
]

{ #category : #instances }
Behavior >> allSubInstances: aLimit [
	"As allInstances:, for the receiver and every behavior that inherits from it, metaclasses included (Object class inherits from Class, so Class allSubInstances answers every class)."
	| classes |
	classes := (Smalltalk allBehaviors select: [:c | c includesBehavior: self]) asOrderedCollection.
	(classes includes: self) ifFalse: [classes addFirst: self].
	^ self instancesOf: classes asArray limit: aLimit
]

{ #category : #instances }
Behavior >> instanceCount [
	"How many objects have the receiver as their class (primitive 168: the same walk as allInstances, nothing allocated). Garbage counts until a collection frees it."
	| n |
	n := Smalltalk primInstanceCountOf: {self}.
	n isNil ifTrue: [^ self error: 'cannot count the instances of ' , self name , ': the heap is full'].
	^ n
]

{ #category : #instances }
Behavior >> instancesOf: anArray limit: aLimit [
	| a |
	(aLimit isInteger and: [aLimit between: 0 and: 16777215]) ifFalse: [
		^ self error: 'the limit of allInstances: is an Integer from 0 to 16777215, not ' , aLimit printString].
	a := Smalltalk primAllInstancesOf: anArray limit: aLimit.
	a isNil ifTrue: [^ self error: 'cannot list the instances of ' , self name , ': the heap is full'].
	^ a
]

{ #category : #methods }
Behavior >> >> aSymbol [
	^ self compiledMethodAt: aSymbol
]

{ #category : #methods }
Behavior >> addSelector: aSymbol withMethod: aCompiledMethod [
	"Install a method (verified by the VM against this class) and note its pragmas."
	| old result |
	Smalltalk isReleaseImage ifTrue: [^ InstallForbidden new behavior: self selector: aSymbol; signal].
	old := self compiledMethodAt: aSymbol ifAbsent: [nil].
	result := self primAddSelector: aSymbol withMethod: aCompiledMethod.
	result isString ifTrue: [^ self error: result].
	Pragma noteRemoved: old; noteInstalled: aCompiledMethod
]

{ #category : #methods }
Behavior >> canUnderstand: aSymbol [
	^ (self lookupSelector: aSymbol) notNil
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
Behavior >> includesSelector: aSymbol [
	^ (self compiledMethodAt: aSymbol ifAbsent: [nil]) notNil
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
Behavior >> methodsDo: aBlock [
	| d |
	d := self methodDictionary.
	d == nil ifTrue: [^ self].
	1 to: d basicSize by: 2 do: [:i | (d slotAt: i) == nil ifFalse: [aBlock value: (d slotAt: i + 1)]]
]

{ #category : #methods }
Behavior >> primAddSelector: aSymbol withMethod: aCompiledMethod [
	"Fails in a release image, for a sealed class (or its class side), or for a method not made for this class and selector; answers a String saying why when a method may not extend a sealed class (module 9b: no primitive, no instance variable, no slot store or become)."
	<primitive: 97>
	Smalltalk isReleaseImage ifTrue: [^ InstallForbidden new behavior: self selector: aSymbol; signal].
	^ self error: 'the VM refused the method ' , aSymbol printString , ' for ' , self printString
]

{ #category : #methods }
Behavior >> primRemoveSelector: aSymbol [
	<primitive: 98>
	Smalltalk isReleaseImage ifTrue: [^ InstallForbidden new behavior: self selector: aSymbol; signal].
	^ self error: 'cannot remove ' , aSymbol printString , ' from ' , self printString
]

{ #category : #methods }
Behavior >> removeSelector: aSymbol [
	| old result |
	Smalltalk isReleaseImage ifTrue: [^ InstallForbidden new behavior: self selector: aSymbol; signal].
	old := self compiledMethodAt: aSymbol ifAbsent: [^ nil].
	result := self primRemoveSelector: aSymbol.
	result isString ifTrue: [^ self error: result].
	Pragma noteRemoved: old.
	Smalltalk forgetSourceOf: old.
	Smalltalk forgetCategoryOf: aSymbol in: self.
	Smalltalk notePackage: nil of: aSymbol in: self.
	^ old
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

{ #category : #organization }
Behavior >> categories [
	"The categories of this class's methods, sorted."
	^ self organization keys asArray sort: [:a :b | a <= b]
]

{ #category : #organization }
Behavior >> categoryOf: aSelector [
	"The category (a Symbol) the method aSelector of this class is filed under, or nil (module 8e)."
	^ Smalltalk categoryOfSelector: aSelector in: self
]

{ #category : #organization }
Behavior >> organization [
	"Each category of this class's methods, a Symbol, to its selectors, sorted (an IdentityDictionary)."
	| d |
	d := IdentityDictionary new.
	self selectors do: [:sel | (d at: ((self categoryOf: sel) ifNil: [Behavior defaultCategory]) ifAbsentPut: [OrderedCollection new]) add: sel].
	d keys do: [:k | d at: k put: ((d at: k) asArray sort: [:a :b | a <= b])].
	^ d
]

{ #category : #organization }
Behavior >> selectorsInCategory: aCategory [
	"The selectors filed under aCategory (a String or Symbol), sorted."
	^ self organization at: aCategory asSymbol ifAbsent: [#()]
]

{ #category : #printing }
Behavior >> printOn: aStream [
	aStream nextPutAll: self name
]

{ #category : #testing }
Behavior >> includesBehavior: aClass [
	^ self == aClass or: [self inheritsFrom: aClass]
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
Behavior >> isBehavior [
	^ true
]

{ #category : #testing }
Behavior >> isMeta [
	^ false
]

{ #category : #testing }
Behavior >> isObsolete [
	"A removed class (Smalltalk removeClass:, module 8e): its class object stays in the VM's class table, renamed AnObsolete<Name>."
	^ self isMeta not and: [self name beginsWith: 'AnObsolete']
]

{ #category : #compiling }
Behavior class >> defaultCategory [
	^ #'as yet unclassified'
]
