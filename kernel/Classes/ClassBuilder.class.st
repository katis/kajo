"Defines, redefines and removes classes in the running image (module 8e), over the VM's primitives 145 (define), 146 (redefine: reshape every instance, replace every method by its recompiled self, replace the class pool) and 147 (remove). The kernel computes the shape and compiles; the VM re-checks everything the image build checks and refuses what would break it, with a String this class signals as a ClassDefinitionError. A redefinition changes nothing until every method compiled against the new shape and the VM accepted the whole change. Refused in a release image (InstallForbidden)."
Class {
	#name : #ClassBuilder,
	#superclass : #Object
}

{ #category : #defining }
ClassBuilder class >> defaultPackage [
	"The package of a class made with none named outside a development session: Unclassified, as before tags as subdirectories (the category a class made with none got), so every class has a package its file can be written into and the browser lists it."
	^ 'Unclassified'
]

{ #category : #defining }
ClassBuilder class >> define: aName superclass: aClass instanceVariableNames: ivars classVariableNames: cvars classInstanceVariableNames: civars package: aPackageOrNil tag: aTagOrNil kind: aKindOrNil comment: aCommentOrNil [
	"The class aName with this shape: a new class, or the existing class of that name (same superclass) reshaped. Names are Strings or Symbols; aKindOrNil a format kind (nil: the superclass's, as Tonel's #type absent). A package given places the class in it with aTagOrNil as its tag (nil: none, at the package's root); none given keeps an existing class's package and tag and gives a new one the default package (ClassBuilder defaultPackage) and no tag (tags as subdirectories)."
	| existing kind |
	self checkWritable: aName.
	existing := Smalltalk at: aName asSymbol ifAbsent: [nil].
	civars isNil ifTrue: [
		^ self define: aName superclass: aClass instanceVariableNames: ivars classVariableNames: cvars
			classInstanceVariableNames: (existing ifNil: [#()] ifNotNil: [:c | (Smalltalk definitionOf: c) classInstVarNames])
			package: aPackageOrNil tag: aTagOrNil kind: aKindOrNil comment: aCommentOrNil].
	kind := aKindOrNil ifNil: [self inheritedKindFrom: aClass] ifNotNil: [:k | k asSymbol].
	existing ifNotNil: [:c |
		c superclass == aClass ifFalse: [
			^ ClassDefinitionError new signal: aName , ' exists with the superclass ' , c superclass printString , ': redefining it under another superclass is not done'].
		(self kindOf: c) == kind ifFalse: [
			^ ClassDefinitionError new signal: aName , ' is ' , (self kindOf: c) , ': changing its format kind is not done'].
		self checkTag: aTagOrNil.
		self redefine: c instanceVariableNames: ivars classVariableNames: cvars classInstanceVariableNames: civars.
		aPackageOrNil ifNotNil: [:p | self place: c package: p tag: aTagOrNil].
		aCommentOrNil ifNotNil: [:t | c comment: t].
		^ c].
	^ self newClass: aName superclass: aClass instanceVariableNames: ivars classVariableNames: cvars classInstanceVariableNames: civars package: aPackageOrNil tag: aTagOrNil kind: kind comment: aCommentOrNil
]

{ #category : #defining }
ClassBuilder class >> newClass: aName superclass: aClass instanceVariableNames: ivars classVariableNames: cvars classInstanceVariableNames: civars package: aPackageOrNil tag: aTagOrNil kind: kind comment: aCommentOrNil [
	| own ownC cv spec result inherited inheritedC |
	self checkTag: aTagOrNil.
	own := (ivars collect: [:n | n asSymbol]) asArray.
	ownC := (civars collect: [:n | n asSymbol]) asArray.
	cv := (cvars collect: [:n | n asSymbol]) asArray.
	inherited := Smalltalk instanceVariableNamesOf: aClass.
	inheritedC := Smalltalk instanceVariableNamesOf: aClass class.
	spec := Array new: 9.
	spec at: 1 put: aName asSymbol; at: 2 put: aClass; at: 3 put: inherited , own; at: 4 put: inheritedC , ownC;
		at: 5 put: cv; at: 6 put: kind; at: 7 put: Binding; at: 8 put: inherited size; at: 9 put: inheritedC size.
	result := Smalltalk primDefineClass: spec.
	result isString ifTrue: [^ ClassDefinitionError new signal: result].
	Smalltalk noteDefinition: (ClassDefinition instVarNames: own classInstVarNames: ownC
		package: (aPackageOrNil ifNil: [self newClassPackage ifNil: [self defaultPackage]] ifNotNil: [:p | p asString])
		tag: (aPackageOrNil ifNil: [nil] ifNotNil: [aTagOrNil]) kind: kind comment: (aCommentOrNil ifNil: ['']))
		of: result.
	Smalltalk forgetClassNames.
	^ result
]

{ #category : #defining }
ClassBuilder class >> newClassPackage [
	"The package a class defined now belongs to: the one the active Process's development session names (module 9b), else none."
	^ DevProtocol packageOfActiveSession
]

{ #category : #defining }
ClassBuilder class >> place: aClass package: aPackage tag: aTagOrNil [
	"Put aClass in aPackage under aTagOrNil (nil: at the package's root). Its file moves with it the next time it is written (DevSession answers the old path to remove)."
	| d |
	self checkWritable: aClass name.
	self checkTag: aTagOrNil.
	d := Smalltalk definitionOf: aClass.
	d isNil ifTrue: [^ ClassDefinitionError new signal: aClass name , ' has no definition in the image'].
	d package: aPackage asString; tag: aTagOrNil.
	^ aClass
]

{ #category : #defining }
ClassBuilder class >> redefine: aClass instanceVariableNames: ivars classVariableNames: cvars classInstanceVariableNames: civars [
	^ self redefine: aClass instanceVariableNames: ivars classVariableNames: cvars classInstanceVariableNames: civars methods: nil
]

{ #category : #defining }
ClassBuilder class >> redefine: aClass instanceVariableNames: ivars classVariableNames: cvars classInstanceVariableNames: civars methods: aDictionaryOrNil [
	"Change aClass's own instance variables, class variables and class-side instance variables to these, keeping every value by name: one primitive call reshapes the instances of aClass and its subclasses, makes every method of theirs again against the new shape and installs them all, and replaces the pool. aDictionaryOrNil maps aClass and its class side to their new methods ({source. category} each, the whole of them: a method not among them goes), compiled in place of the recorded sources (TonelLoader). A method that does not compile refuses the whole change, naming every such method; nothing changes."
	| d own ownC cv oldCv shapes methods pools sources pending kept added removed newBindings result failures overrides |
	self checkWritable: aClass name.
	d := Smalltalk definitionOf: aClass.
	d isNil ifTrue: [^ ClassDefinitionError new signal: aClass name , ' has no definition in the image'].
	own := (ivars collect: [:n | n asSymbol]) asArray.
	ownC := (civars collect: [:n | n asSymbol]) asArray.
	cv := (cvars collect: [:n | n asSymbol]) asArray.
	oldCv := aClass classVarNames asArray.
	overrides := aDictionaryOrNil ifNil: [IdentityDictionary new].
	shapes := OrderedCollection new.
	methods := OrderedCollection new.
	pools := OrderedCollection new.
	sources := IdentityDictionary new.
	failures := OrderedCollection new.
	"Class variables: the kept Bindings stay, the added are new (or a removed one of the same name, declared again), the removed become undeclared after the change."
	kept := aClass classPool.
	added := cv reject: [:n | kept includesKey: n].
	removed := oldCv reject: [:n | cv includes: n].
	newBindings := cv collect: [:n | (kept at: n ifAbsent: [nil]) ifNil: [Smalltalk undeclaredBinding: n in: aClass]].
	pending := Dictionary new.
	cv with: newBindings do: [:n :b | pending at: n asString put: b].
	cv = oldCv ifFalse: [pools add: (Array with: aClass with: newBindings asArray)].
	"Shapes and recompiled methods, instance side and class side; then the new methods of a side whose shape stays."
	own = d instVarNames asArray ifFalse: [
		self reshape: aClass own: own meta: false into: shapes methods: methods sources: sources pending: pending overrides: overrides failures: failures].
	ownC = d classInstVarNames asArray ifFalse: [
		self reshape: aClass class own: ownC meta: true into: shapes methods: methods sources: sources pending: pending overrides: overrides failures: failures].
	(Array with: aClass with: aClass class) do: [:b |
		((overrides includesKey: b) and: [(sources includesKey: b) not]) ifTrue: [
			self compile: b names: (Smalltalk instanceVariableNamesOf: b) into: methods sources: sources pending: pending overrides: overrides failures: failures]].
	failures isEmpty ifFalse: [
		^ ClassDefinitionError new signal: aClass name , ': ' , failures size printString , ' methods do not compile: ' , (failures inject: '' into: [:a :e | a isEmpty ifTrue: [e] ifFalse: [a , '; ' , e]])].
	(shapes isEmpty and: [pools isEmpty and: [methods isEmpty]]) ifTrue: [^ aClass].
	result := Smalltalk primRedefine: (Array with: shapes asArray with: methods asArray with: pools asArray with: #methodRemovedByRedefinition).
	result isString ifTrue: [^ ClassDefinitionError new signal: aClass name , ': ' , result].
	"The records follow the image: definitions, sources (the replaced methods were forwarded to their new selves), categories, the pragma index, the class variables."
	shapes do: [:s | | b | b := s first.
		b isMeta
			ifTrue: [b == aClass class ifTrue: [d classInstVarNames: ownC]]
			ifFalse: [b == aClass ifTrue: [d instVarNames: own]]].
	sources keysAndValuesDo: [:b :srcs | Smalltalk replaceSources: (srcs collect: [:x | x first -> (x at: 2)]) of: b].
	overrides keysAndValuesDo: [:b :list |
		Smalltalk forgetCategoriesOf: b.
		(sources at: b) do: [:x | Smalltalk noteCategory: (x at: 3) of: x first in: b]].
	methods isEmpty ifFalse: [Pragma rebuildIndex].
	newBindings do: [:b | b isUndeclared ifTrue: [b beDeclared]].
	removed do: [:n | | b | b := kept at: n. b beUndeclared. Smalltalk noteUndeclared: b in: aClass].
	added do: [:n | Smalltalk forgetUndeclared: n in: aClass].
	^ aClass
]

{ #category : #private }
ClassBuilder class >> checkTag: aTagOrNil [
	"A tag is the name of one directory under its package's: no / or NUL, not . or .., not hidden; nil or empty is none."
	| t |
	aTagOrNil isNil ifTrue: [^ self].
	t := aTagOrNil asString.
	t isEmpty ifTrue: [^ self].
	((t includes: $/) or: [(t includes: (Character value: 0)) or: [t first = $.]])
		ifTrue: [^ ClassDefinitionError new signal: '''' , t , ''' is not a tag (one directory name, no /, not hidden)']
]

{ #category : #private }
ClassBuilder class >> checkWritable: aName [
	Smalltalk isReleaseImage ifTrue: [^ InstallForbidden new behavior: nil selector: aName asSymbol; signal]
]

{ #category : #private }
ClassBuilder class >> compile: aBehavior names: instVarNames into: methods sources: sources pending: pending overrides: overrides failures: failures [
	"aBehavior's new methods made from their sources against instVarNames: the overriding ones if any, else every recorded source. Each source kept as {selector. source. category}."
	| list codes srcs |
	list := overrides at: aBehavior ifAbsent: [
		aBehavior selectors asArray collect: [:sel | Array with: (Smalltalk sourceOf: (aBehavior compiledMethodAt: sel)) with: (aBehavior categoryOf: sel) with: sel]].
	codes := OrderedCollection new.
	srcs := OrderedCollection new.
	list do: [:e | | src |
		src := e first.
		src isNil
			ifTrue: [failures add: aBehavior name , '>>' , (e at: 3) , ': no source']
			ifFalse: [
				[ | code |
				 code := Compiler compile: src in: aBehavior instanceVariableNames: instVarNames bindings: pending.
				 codes add: code.
				 srcs add: (Array with: code selector with: src with: ((e at: 2) ifNil: [Behavior defaultCategory]))]
					on: CompileError do: [:x | failures add: aBehavior name , '>>' , (e size > 2 ifTrue: [e at: 3] ifFalse: [(src copyFrom: 1 to: (Scanner patternEndIn: src))]) , ': ' , x messageText]]].
	methods add: (Array with: aBehavior with: codes asArray).
	sources at: aBehavior put: srcs
]

{ #category : #private }
ClassBuilder class >> inheritedKindFrom: aClass [
	"The kind a subclass of aClass takes when none is named: Tonel's rule (and the image build's)."
	| k |
	k := self kindOf: aClass.
	(#(#variable #bytes #words16 #words32 #words64) includes: k) ifTrue: [^ k].
	k == #weak ifTrue: [^ #variable].
	^ #fixed
]

{ #category : #private }
ClassBuilder class >> kindOf: aClass [
	^ (Smalltalk definitionOf: aClass) ifNil: [#fixed] ifNotNil: [:d | d kind]
]

{ #category : #private }
ClassBuilder class >> reshape: aBehavior own: ownNames meta: isMeta into: shapes methods: methods sources: sources pending: pending overrides: overrides failures: failures [
	"Add the shape and the recompiled methods of aBehavior and of every subclass (their class sides for a class-side change), each layout by name from the old slots."
	| newNames |
	newNames := IdentityDictionary new.
	(isMeta ifTrue: [aBehavior theNonMetaClass withAllSubclasses] ifFalse: [aBehavior withAllSubclasses]) do: [:c | | b old new parent layout |
		b := isMeta ifTrue: [c class] ifFalse: [c].
		old := Smalltalk instanceVariableNamesOf: b.
		parent := b == aBehavior
			ifTrue: [(isMeta and: [b superclass isMeta not]) ifTrue: [ownNames] ifFalse: [(Smalltalk instanceVariableNamesOf: b superclass) , ownNames]]
			ifFalse: [(newNames at: b superclass) , (isMeta ifTrue: [(Smalltalk definitionOf: c) classInstVarNames] ifFalse: [(Smalltalk definitionOf: c) instVarNames])].
		new := parent asArray.
		newNames at: b put: new.
		new asSet size = new size ifFalse: [failures add: b name , ': an instance variable name twice'].
		layout := (isMeta ifTrue: [#(1 2 3 4 5)] ifFalse: [#()]) , (new collect: [:n | | i | i := old indexOf: n. i = 0 ifTrue: [0] ifFalse: [i + (isMeta ifTrue: [5] ifFalse: [0])]]).
		shapes add: (Array with: b with: layout size with: layout).
		self compile: b names: new into: methods sources: sources pending: pending overrides: overrides failures: failures]
]

{ #category : #removing }
ClassBuilder class >> remove: aClass [
	"Remove aClass from the image (Smalltalk removeClass:): refused while it has subclasses or instances, while a method outside it names it, or while a Process runs one of its methods. Its methods go, its class variables' Bindings are forgotten, Smalltalk forgets the name; the class object stays in the VM's class table, renamed AnObsolete<Name>."
	| methods result |
	self checkWritable: aClass name.
	aClass subclasses isEmpty ifFalse: [^ ClassDefinitionError new signal: aClass name , ' has subclasses'].
	methods := OrderedCollection new.
	aClass methodsDo: [:m | methods add: m].
	aClass class methodsDo: [:m | methods add: m].
	result := Smalltalk primRemoveClass: aClass as: ('AnObsolete' , aClass name) asSymbol.
	result isString ifTrue: [^ ClassDefinitionError new signal: result].
	methods do: [:m | Pragma noteRemoved: m].
	Smalltalk forgetClass: aClass.
	^ aClass
]
