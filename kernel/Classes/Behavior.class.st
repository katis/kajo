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
	]
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
Behavior >> name ^<String> [
	^ self slotAt: 3
]

{ #category : #accessing }
Behavior >> superclass ^<Behavior | Nil> [
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
	| method old category oldCategory |
	Smalltalk isReleaseImage ifTrue: [^ InstallForbidden new behavior: self selector: nil; signal].
	method := (Compiler compile: aString in: self) makeMethodIn: self.
	old := self compiledMethodAt: method selector ifAbsent: [nil].
	oldCategory := self categoryOf: method selector.
	category := aCategoryOrNil isNil
		ifTrue: [oldCategory ifNil: [Behavior defaultCategory]]
		ifFalse: [aCategoryOrNil asSymbol].
	"Types 2: a method compiled where a signature without a method stands replaces it (open question 2), filed under the signature's category unless one is given."
	(old isNil and: [aCategoryOrNil isNil]) ifTrue: [
		(Smalltalk signatureOf: method selector in: self) ifNotNil: [:e | category := e at: 2]].
	"The records first, then the install: another Process that finds the method (it may run on another worker at the same moment) finds its source and its category (the tools test's fault, docs/modules/tools-test-fault.md). An install left by an unwind takes them back."
	Smalltalk noteSource: aString of: method.
	Smalltalk noteCategory: category of: method selector in: self.
	[self addSelector: method selector withMethod: method] ifCurtailed: [
		Smalltalk forgetSourceOf: method.
		oldCategory isNil
			ifTrue: [Smalltalk forgetCategoryOf: method selector in: self]
			ifFalse: [Smalltalk noteCategory: oldCategory of: method selector in: self]].
	"The replaced method's source is retired, not forgotten: a reader that holds the old method still reads it (the known faults, item 3)."
	old ifNotNil: [:m | Smalltalk retireSourceOf: m].
	Smalltalk forgetSignatureOf: method selector in: self.
	DevProtocol noteChangeOf: method selector in: self.
	Smalltalk noteChange: #method of: method selector in: self.
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
Behavior >> basicNew ^<Instance> [
	<primitive: 4>
	^ self error: 'cannot make an instance of ' , self name
]

{ #category : #'instance creation' }
Behavior >> basicNew: size <Integer> ^<Instance> [
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
Behavior >> new ^<Instance> [
	^ self basicNew initialize
]

{ #category : #'instance creation' }
Behavior >> new: size <Integer> ^<Instance> [
	^ (self basicNew: size) initialize
]

{ #category : #instances }
Behavior >> allInstances ^<Array[Instance]> [
	"Every object whose class is the receiver, with no limit but the largest Array's (16 777 215; allInstances: takes a smaller one: the owner's answer of 2026-11-09 to the discoverability follow-up's open question 3). Beware: a development image holds millions of objects, and Object allInstances or String allInstances is an Array of hundreds of thousands made in one stop that can be a frame long; ask for a limit where that matters. The objects are found in one stop of the world after every young one is promoted, so an object nothing reaches any more is still an instance until a collection frees it (send Smalltalk garbageCollect first for the live ones only). The immediate classes (SmallInteger, SmallFloat, Character) have no instances in the heap and answer #(); UndefinedObject, True and False answer their one instance."
	^ self allInstances: 16777215
]

{ #category : #instances }
Behavior >> allInstances: aLimit [
	"Every object whose class is the receiver, at most aLimit of them (an Integer from 0 to 16777215, the largest Array): primitive 167, one walk of old space in a stop. See allInstances."
	^ self instancesOf: {self} limit: aLimit
]

{ #category : #instances }
Behavior >> allSubInstances [
	"Every object whose class is the receiver or inherits from it, with no limit but the largest Array's (allSubInstances: for a smaller one); one walk of old space with every such class at once. See allInstances."
	^ self allSubInstances: 16777215
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
Behavior >> instanceCount ^<Integer> [
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
	"Install a method (verified by the VM against this class) and note its pragmas, both under Smalltalk registry:, the lock the pragma index's readers take: a reader never finds the method installed and its pragmas not yet noted (the known faults, item 3)."
	| old result |
	Smalltalk isReleaseImage ifTrue: [^ InstallForbidden new behavior: self selector: aSymbol; signal].
	Smalltalk registry: [
		old := self compiledMethodAt: aSymbol ifAbsent: [nil].
		result := self primAddSelector: aSymbol withMethod: aCompiledMethod.
		result isString ifFalse: [Pragma noteRemoved: old; noteInstalled: aCompiledMethod]].
	result isString ifTrue: [^ self error: result]
]

{ #category : #methods }
Behavior >> canUnderstand: aSymbol <Symbol> ^<Boolean> [
	^ (self lookupSelector: aSymbol) notNil
]

{ #category : #methods }
Behavior >> compiledMethodAt: aSymbol <Symbol> ^<CompiledMethod> [
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
Behavior >> includesSelector: aSymbol <Symbol> ^<Boolean> [
	^ (self compiledMethodAt: aSymbol ifAbsent: [nil]) notNil
]

{ #category : #methods }
Behavior >> lookupSelector: aSymbol <Symbol> ^<CompiledMethod | Nil> [
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
	"The removal and the pragma index under the registry as the install's are; the source is retired, not forgotten: a reader that holds the method still reads it (the known faults, item 3)."
	Smalltalk registry: [
		old := self compiledMethodAt: aSymbol ifAbsent: [nil].
		old isNil ifFalse: [
			result := self primRemoveSelector: aSymbol.
			result isString ifFalse: [Pragma noteRemoved: old]]].
	old isNil ifTrue: [^ nil].
	result isString ifTrue: [^ self error: result].
	Smalltalk retireSourceOf: old.
	Smalltalk forgetCategoryOf: aSymbol in: self.
	Smalltalk notePackage: nil of: aSymbol in: self.
	Smalltalk noteChange: #methodRemoved of: aSymbol in: self.
	^ old
]

{ #category : #methods }
Behavior >> selectors ^<Array[Symbol]> [
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
	"The selectors filed under aCategory (a String or Symbol), sorted: only that category's, not the whole organization (the third review's small fixes, item 4)."
	| cat |
	cat := aCategory asSymbol.
	^ (self selectors select: [:sel | ((self categoryOf: sel) ifNil: [Behavior defaultCategory]) == cat]) asArray sort: [:a :b | a <= b]
]

{ #category : #printing }
Behavior >> printOn: aStream [
	aStream nextPutAll: self name
]

{ #category : #signatures }
Behavior >> removeSignature: aSelector [
	"Types 2: forget this class's signature without a method of aSelector; answers its pattern's text, or nil when there was none."
	| e |
	Smalltalk isReleaseImage ifTrue: [^ InstallForbidden new behavior: self selector: aSelector; signal].
	e := Smalltalk forgetSignatureOf: aSelector in: self.
	e isNil ifTrue: [^ nil].
	Smalltalk noteChange: #signature of: aSelector asSymbol in: self.
	^ e first
]

{ #category : #signatures }
Behavior >> signature: aString classified: aCategoryOrNil [
	"Types 2 (docs/modules/types-2.md): add or replace this class's signature without a method, aString a message pattern with at least one type, as a class file writes it after `Class >> `. Nothing to the VM: no method, respondsTo: and includesSelector: unchanged; text the type checker reads, which a release build does not keep. Refused with an Error when this class has a method of that selector (a class has a method or a signature for a selector) and with a CompileError when aString is not one pattern with a type; InstallForbidden in a release image. Answers the selector."
	| parser p sel |
	Smalltalk isReleaseImage ifTrue: [^ InstallForbidden new behavior: self selector: nil; signal].
	parser := Parser new setSource: aString.
	p := parser parsePattern.
	parser kind == #end ifFalse: [^ CompileError new line: parser line; signal: 'a signature is a message pattern alone'].
	((p at: 3) anySatisfy: [:t | t notNil]) | (p at: 4) notNil
		ifFalse: [^ CompileError new line: 1; signal: 'a signature writes at least one type'].
	sel := (p at: 1) asSymbol.
	(self includesSelector: sel) ifTrue: [^ self error: self name , '>>' , sel , ' is a method: a class has a method or a signature for a selector'].
	Smalltalk noteSignature: (aString copyFrom: 1 to: parser lastEnd) category: aCategoryOrNil package: DevProtocol packageOfActiveSession of: sel in: self.
	Smalltalk noteChange: #signature of: sel in: self.
	^ sel
]

{ #category : #signatures }
Behavior >> signatureAt: aSelector [
	"Types 2: the pattern's text of this class's signature without a method of aSelector, or nil."
	^ (Smalltalk signatureOf: aSelector in: self) ifNotNil: [:e | e first]
]

{ #category : #testing }
Behavior >> includesBehavior: aClass <Behavior> ^<Boolean> [
	^ self == aClass or: [self inheritsFrom: aClass]
]

{ #category : #testing }
Behavior >> inheritsFrom: aClass <Behavior> ^<Boolean> [
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
