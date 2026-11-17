"One Tonel file as TonelReader read it (module 8e): the class definition (name, superclass name, instance, class and class-side instance variable names, #type, comment, and Types 1's type parameters, superclass type and instance variables' types; a #category, #package or #tag key is read and ignored: the class's place is its file's, tags as subdirectories) or an Extension's class name, and its methods, each {class side?. category. source}."
Class {
	#name : #TonelDocument,
	#superclass : #Object,
	#instVars : [
		'name',
		'superclassName',
		'instVarNames',
		'classVarNames',
		'classInstVarNames',
		'type',
		'comment',
		'isExtension',
		'methods',
		'typeParameters',
		'superclassType',
		'instVarTypes',
		'signatures'
	]
}

{ #category : #accessing }
TonelDocument >> classInstVarNames [
	^ classInstVarNames ifNil: [#()]
]

{ #category : #accessing }
TonelDocument >> classInstVarNames: anArray [
	classInstVarNames := anArray
]

{ #category : #accessing }
TonelDocument >> classTypes [
	"The ClassTypes the file writes, or nil when it writes none (Types 1)."
	| t |
	t := ClassTypes new.
	t typeParameters: self typeParameters; superclassType: superclassType.
	self instVarTypes do: [:a | t type: a value of: a key].
	self signatures do: [:sig | t signature: (sig at: 4) category: (sig at: 2) package: nil at: (sig at: 3) asSymbol meta: sig first].
	^ t isEmpty ifTrue: [nil] ifFalse: [t]
]

{ #category : #accessing }
TonelDocument >> classVarNames [
	^ classVarNames ifNil: [#()]
]

{ #category : #accessing }
TonelDocument >> classVarNames: anArray [
	classVarNames := anArray
]

{ #category : #accessing }
TonelDocument >> comment [
	^ comment
]

{ #category : #accessing }
TonelDocument >> comment: aString [
	comment := aString
]

{ #category : #accessing }
TonelDocument >> instVarNames [
	^ instVarNames ifNil: [#()]
]

{ #category : #accessing }
TonelDocument >> instVarNames: anArray [
	instVarNames := anArray
]

{ #category : #accessing }
TonelDocument >> instVarTypes [
	"name -> the type's text, for each typed instance variable in order."
	^ instVarTypes ifNil: [instVarTypes := OrderedCollection new]
]

{ #category : #accessing }
TonelDocument >> isExtension [
	^ isExtension == true
]

{ #category : #accessing }
TonelDocument >> isExtension: aBoolean [
	isExtension := aBoolean
]

{ #category : #accessing }
TonelDocument >> kind [
	"The format kind #type names, or nil when absent (inherited)."
	type isNil ifTrue: [^ nil].
	^ (Dictionary new
		at: 'normal' put: #fixed; at: 'variable' put: #variable; at: 'bytes' put: #bytes; at: 'words' put: #words32;
		at: 'words16' put: #words16; at: 'words64' put: #words64; at: 'weak' put: #weak; at: 'ephemeron' put: #ephemeron;
		yourself) at: type ifAbsent: [ClassDefinitionError new signal: name , ': unknown #type ' , type]
]

{ #category : #accessing }
TonelDocument >> methods [
	^ methods ifNil: [methods := OrderedCollection new]
]

{ #category : #accessing }
TonelDocument >> name [
	^ name
]

{ #category : #accessing }
TonelDocument >> name: aString [
	name := aString
]

{ #category : #accessing }
TonelDocument >> signatures [
	"Types 2: the signatures without a method, each {class side?. category. selector. the pattern's text}, in the file's order."
	^ signatures ifNil: [signatures := OrderedCollection new]
]

{ #category : #accessing }
TonelDocument >> superclassName [
	^ superclassName
]

{ #category : #accessing }
TonelDocument >> superclassName: aStringOrNil [
	superclassName := aStringOrNil
]

{ #category : #accessing }
TonelDocument >> superclassType [
	^ superclassType
]

{ #category : #accessing }
TonelDocument >> superclassType: aStringOrNil [
	superclassType := aStringOrNil
]

{ #category : #accessing }
TonelDocument >> type [
	^ type
]

{ #category : #accessing }
TonelDocument >> type: aStringOrNil [
	type := aStringOrNil
]

{ #category : #accessing }
TonelDocument >> typeParameters [
	^ typeParameters ifNil: [#()]
]

{ #category : #accessing }
TonelDocument >> typeParameters: anArray [
	typeParameters := anArray
]

{ #category : #summary }
TonelDocument >> names: anArray [
	^ anArray inject: '' into: [:a :n | a isEmpty ifTrue: [n asString] ifFalse: [a , ' ' , n]]
]

{ #category : #summary }
TonelDocument >> summary [
	"The fields a test compares with the bootstrap reader's, separated by the record separator (30)."
	| rs out |
	rs := String with: (Character value: 30).
	out := name , rs , (superclassName ifNil: ['nil']) , rs , (self names: self instVarNames) , rs , (self names: self classVarNames) , rs
		, (self names: self classInstVarNames) , rs , (type ifNil: ['']) , rs , comment , rs , (self isExtension ifTrue: ['extension'] ifFalse: ['class'])
		, rs , (self names: self typeParameters) , rs , (superclassType ifNil: ['']) , rs
		, (self instVarTypes inject: '' into: [:a :e | a , e key , ' <' , e value , '>;']).
	self methods do: [:m |
		out := out , rs , ((m at: 1) ifTrue: ['class'] ifFalse: ['instance']) , rs , (m at: 2) , rs , (m at: 3)].
	self signatures do: [:sig |
		out := out , rs , 'signature ' , ((sig at: 1) ifTrue: ['class'] ifFalse: ['instance']) , rs , (sig at: 2) , rs , (sig at: 4)].
	^ out
]
