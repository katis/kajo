"A type of the optional-types experiment (experiments/optional-types/DESIGN.md). Types are values: a checker never stores into one after it is made. The language: class types with arguments (OTClassType), the type of a class object (OTMetaType), unions (OTUnion), block types (OTBlockType), Self and Instance (OTSelf, OTInstance), type variables (OTVar: a generic class's parameter or a generic method's variable) and the dynamic type (OTDynamic). Nil is the class type of UndefinedObject, Object is the top."
Class {
	#name : #OTType,
	#superclass : #Object
}

{ #category : #testing }
OTType >> includesNil [
	^ false
]

{ #category : #testing }
OTType >> isBlockType [
	^ false
]

{ #category : #testing }
OTType >> isClassType [
	^ false
]

{ #category : #testing }
OTType >> isDynamic [
	^ false
]

{ #category : #testing }
OTType >> isKnown [
	"A type that names what the value is: not dynamic and not an unresolved variable (the completion measure)."
	^ true
]

{ #category : #testing }
OTType >> isMetaType [
	^ false
]

{ #category : #testing }
OTType >> isNilType [
	^ false
]

{ #category : #testing }
OTType >> isUnassigned [
	^ false
]

{ #category : #testing }
OTType >> isUnion [
	^ false
]

{ #category : #testing }
OTType >> isVar [
	^ false
]

{ #category : #accessing }
OTType >> members [
	^ {self}
]

{ #category : #comparing }
OTType >> sameAs: aType [
	^ self printString = aType printString
]

{ #category : #substitution }
OTType >> substitute: aDictionary self: selfType instance: instanceType [
	"The type with each variable aDictionary names replaced, Self by selfType and Instance by instanceType (nil leaves them)."
	^ self
]

{ #category : #substitution }
OTType >> varsDo: aBlock [
	"Each variable in the type."
]

{ #category : #accessing }
OTType >> withoutNil [
	^ self
]

{ #category : #accessing }
OTType >> withoutSelfMark [
	^ self
]

{ #category : #'instance creation' }
OTType class >> dynamic [
	^ OTDynamic new
]

{ #category : #'instance creation' }
OTType class >> nilType [
	^ OTClassType cls: UndefinedObject args: #()
]

{ #category : #'instance creation' }
OTType class >> of: aClass [
	^ OTClassType cls: aClass args: #()
]

{ #category : #'instance creation' }
OTType class >> union: aCollection [
	"The union of the types, flattened, without repeats; one member is that member, a dynamic member makes the union dynamic."
	| out |
	out := OrderedCollection new.
	aCollection do: [:t |
		t members do: [:m |
			m isDynamic ifTrue: [^ m].
			(out anySatisfy: [:x | x sameAs: m]) ifFalse: [out add: m]]].
	out isEmpty ifTrue: [^ self dynamic].
	out size = 1 ifTrue: [^ out first].
	"Nil last, as a person writes it."
	(out anySatisfy: [:x | x isNilType]) ifTrue: [out := (out reject: [:x | x isNilType]) , {self nilType}].
	^ OTUnion new setMembers: out asArray
]
