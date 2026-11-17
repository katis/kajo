"A type of the type checker (Types 2, docs/modules/types-2.md; the experiment's OTType, experiments/optional-types). Types are values: nothing stores into one after it is made. The language: an instance of a class with its type arguments (NominalType), a class object (MetaType), unions (UnionType), block types (BlockType), Self and Instance (SelfType, SelfClassType, InstanceType), type variables (TypeVariable: a generic class's parameter or a method variable; TypeVariableClass: X class), protocols made by code (ProtocolType) and the dynamic type (DynamicType). Nil is UndefinedObject's NominalType, Object is the top. The checker builds them from the parse tree's TypeNodes (TypeTable); they are diagnostics only and the VM never sees one."
Class {
	#name : #Type,
	#superclass : #Object
}

{ #category : #accessing }
Type >> members [
	^ {self}
]

{ #category : #accessing }
Type >> withoutNil [
	^ self
]

{ #category : #accessing }
Type >> withoutSelfMark [
	^ self
]

{ #category : #comparing }
Type >> sameAs: aType [
	^ self printString = aType printString
]

{ #category : #substitution }
Type >> substitute: aDictionary self: selfType instance: instanceType [
	"The type with each variable aDictionary names replaced, Self by selfType and Instance by instanceType (nil leaves them)."
	^ self
]

{ #category : #substitution }
Type >> varsDo: aBlock [
	"Each variable in the type."
]

{ #category : #testing }
Type >> includesNil [
	^ false
]

{ #category : #testing }
Type >> isBlockType [
	^ false
]

{ #category : #testing }
Type >> isClassType [
	"An instance of a class (NominalType)."
	^ false
]

{ #category : #testing }
Type >> isDynamic [
	^ false
]

{ #category : #testing }
Type >> isKnown [
	"A type that names what the value is: not dynamic and not an unresolved variable (the completion measure)."
	^ true
]

{ #category : #testing }
Type >> isMetaType [
	^ false
]

{ #category : #testing }
Type >> isNilType [
	^ false
]

{ #category : #testing }
Type >> isProtocolType [
	^ false
]

{ #category : #testing }
Type >> isUnassigned [
	^ false
]

{ #category : #testing }
Type >> isUnion [
	^ false
]

{ #category : #testing }
Type >> isVar [
	^ false
]

{ #category : #'instance creation' }
Type class >> dynamic [
	^ DynamicType new
]

{ #category : #'instance creation' }
Type class >> nilType [
	^ NominalType cls: UndefinedObject args: #()
]

{ #category : #'instance creation' }
Type class >> of: aClass [
	^ NominalType cls: aClass args: #()
]

{ #category : #'instance creation' }
Type class >> union: aCollection [
	"The union of the types, flattened, without repeats; one member is that member, a dynamic member makes the union dynamic. Nil last, as a person writes it."
	| out |
	out := OrderedCollection new.
	aCollection do: [:t |
		t members do: [:m |
			m isDynamic ifTrue: [^ m].
			(out anySatisfy: [:x | x sameAs: m]) ifFalse: [out add: m]]].
	out isEmpty ifTrue: [^ self dynamic].
	out size = 1 ifTrue: [^ out first].
	(out anySatisfy: [:x | x isNilType]) ifTrue: [out := (out reject: [:x | x isNilType]) , {self nilType}].
	^ UnionType new setMembers: out asArray
]
