"What the checker reads of the image's types (Types 2, docs/modules/types-2.md; the experiment's OTAnnotations, which read side files): for each class a TypedClass, built when first needed from the methods' patterns (the kernel's Parser, parsePattern: a TypeNode per written type) and from the class's ClassTypes (class-level types as text, and the signatures without a method), and forgotten when the class changes (forget:). No side file and no type parser of its own: a type is made from a TypeNode (typeFrom:...). Also the protocols made by code (register:) and an overlay of signatures a test or a tool adds by text (addSignature:in:), and the lookups the checker makes: a selector's signatures from a class up (signaturesFor:from:), the map from a receiver's type arguments to a defining class's parameters, an instance variable's declared type."
Class {
	#name : #TypeTable,
	#superclass : #Object,
	#instVars : [
		'classes',
		'protocols',
		'overlay'
	]
}

{ #category : #accessing }
TypeTable >> classes [
	"The TypedClasses built so far, by class."
	^ classes
]

{ #category : #accessing }
TypeTable >> forget: aBehavior [
	"aBehavior's class changed: its TypedClass is read again when next needed. A class that carries no type passes its parameters to its subclasses, so theirs go too."
	| cls |
	cls := aBehavior theNonMetaClass.
	classes removeKey: cls ifAbsent: [nil].
	(classes keys select: [:c | c inheritsFrom: cls]) do: [:c | classes removeKey: c ifAbsent: [nil]]
]

{ #category : #accessing }
TypeTable >> forgetAll [
	classes := IdentityDictionary new
]

{ #category : #accessing }
TypeTable >> setUp [
	classes := IdentityDictionary new.
	protocols := Dictionary new.
	overlay := IdentityDictionary new
]

{ #category : #accessing }
TypeTable >> signatureCount [
	"The signatures of the classes read so far (every alternative of an overload counts)."
	^ classes inject: 0 into: [:n :tc | n + tc signatureCount]
]

{ #category : #accessing }
TypeTable >> typedClass: aClass [
	"aClass's TypedClass (aClass not a metaclass), read the first time it is asked for."
	^ classes at: aClass ifAbsent: [ | tc |
		tc := self build: aClass.
		classes at: aClass put: tc.
		tc]
]

{ #category : #building }
TypeTable >> addSignaturesFrom: anArray into: aTypedClass [
	"anArray is {behavior. a parsed pattern (Parser>>parsePattern: selector, arguments, argument TypeNodes, result TypeNode). kind}: one TypeSignature per overload alternative."
	| b p sel argNodes resNode vars n key places |
	b := anArray first.
	p := anArray at: 2.
	sel := (p at: 1) asSymbol.
	argNodes := p at: 3.
	resNode := p at: 4.
	key := self keyOf: sel in: b.
	places := argNodes asOrderedCollection copy.
	places add: resNode.
	vars := Set new.
	places do: [:t | t ifNotNil: [:x | self declaredVariablesIn: x into: vars]].
	n := 1.
	places do: [:t | (t notNil and: [t kind == #alternatives]) ifTrue: [n := t parts size]].
	1 to: n do: [:k | | args res |
		args := argNodes collect: [:t | self typeFrom: (self alternative: k of: t) params: aTypedClass params vars: vars class: b theNonMetaClass into: aTypedClass key: key].
		res := self typeFrom: (self alternative: k of: resNode) params: aTypedClass params vars: vars class: b theNonMetaClass into: aTypedClass key: key.
		aTypedClass addSignature: (TypeSignature selector: sel argTypes: args asArray result: res vars: vars meta: b isMeta owner: b theNonMetaClass kind: (anArray at: 3))]
]

{ #category : #building }
TypeTable >> alternative: k of: aTypeNodeOrNil [
	"The k-th alternative of an overloaded place, the type itself in every signature when the place has one, nil (Dynamic) when it has none."
	aTypeNodeOrNil isNil ifTrue: [^ nil].
	aTypeNodeOrNil kind == #alternatives ifTrue: [^ aTypeNodeOrNil parts at: k].
	^ aTypeNodeOrNil
]

{ #category : #building }
TypeTable >> build: aClass [
	"aClass's TypedClass, read from the image: its methods' patterns, both sides, and its ClassTypes."
	| tc ct pending |
	tc := TypedClass cls: aClass.
	ct := Smalltalk typesOf: aClass.
	pending := OrderedCollection new.
	(Array with: aClass with: aClass class) do: [:b | | own |
		own := (overlay at: b ifAbsent: [#()]) collect: [:text | (Parser new setSource: text) parsePattern].
		b selectors do: [:sel | | src p |
			(own anySatisfy: [:o | (o at: 1) asSymbol == sel]) ifFalse: [
				src := Smalltalk sourceOf: (b compiledMethodAt: sel).
				src notNil ifTrue: [
					p := [(Parser new setSource: src) parsePattern] on: CompileError do: [:e | nil].
					(p notNil and: [self hasTypes: p]) ifTrue: [pending add: (Array with: b with: p with: #method)]]]].
		ct ifNotNil: [:t |
			(t signatureSelectorsMeta: b isMeta) do: [:sel | | p |
				(own anySatisfy: [:o | (o at: 1) asSymbol == sel]) ifFalse: [
					p := [(Parser new setSource: (t signatureAt: sel meta: b isMeta) first) parsePattern]
						on: CompileError do: [:e | tc addProblem: 'the signature does not read: ' , e messageText for: (self keyOf: sel in: b). nil].
					p ifNotNil: [pending add: (Array with: b with: p with: #signature)]]]].
		own do: [:p | pending add: (Array with: b with: p with: #overlay)]].
	tc carriesTypes: (pending notEmpty or: [ct notNil and: [ct isEmpty not]]).
	tc params: (tc carriesTypes
		ifTrue: [ct isNil ifTrue: [#()] ifFalse: [ct typeParameters]]
		ifFalse: [aClass superclass isNil ifTrue: [#()] ifFalse: [(self typedClass: aClass superclass) params]]).
	ct ifNotNil: [:t | | key |
		key := 'class:' , aClass name.
		t superclassType ifNotNil: [:text |
			([Parser parseClassType: text] on: CompileError do: [:e | tc addProblem: '#superclassType does not read: ' , e messageText for: key. nil])
				ifNotNil: [:node | | ty |
					ty := self typeFrom: node params: tc params vars: #() class: aClass into: tc key: key.
					tc superArgs: (ty isClassType ifTrue: [ty args] ifFalse: [nil])]].
		t instVarTypes keysAndValuesDo: [:n :text |
			([Parser parseClassType: text] on: CompileError do: [:e | tc addProblem: 'the type of ' , n , ' does not read: ' , e messageText for: key. nil])
				ifNotNil: [:node | tc ivars at: n asString put: (self typeFrom: node params: tc params vars: #() class: aClass into: tc key: key)]]].
	pending do: [:x | self addSignaturesFrom: x into: tc].
	^ tc
]

{ #category : #building }
TypeTable >> declaredVariablesIn: aTypeNode into: aSet [
	"The method variables a type declares (:X)."
	aTypeNode kind == #variable ifTrue: [aSet add: aTypeNode name].
	aTypeNode parts do: [:p | self declaredVariablesIn: p into: aSet].
	aTypeNode result ifNotNil: [:r | self declaredVariablesIn: r into: aSet]
]

{ #category : #building }
TypeTable >> hasTypes: aPattern [
	"Whether a parsed pattern writes any type."
	^ ((aPattern at: 3) anySatisfy: [:t | t notNil]) or: [(aPattern at: 4) notNil]
]

{ #category : #building }
TypeTable >> typeFrom: aTypeNodeOrNil params: params vars: vars class: aClass into: aTypedClass key: aKey [
	"The Type a TypeNode writes, with aClass's parameters and the signature's method variables in scope; Dynamic for none. A name that is no class, parameter or variable is Dynamic and a problem of aKey (an #annotation diagnostic of that method)."
	| n k |
	aTypeNodeOrNil isNil ifTrue: [^ Type dynamic].
	k := aTypeNodeOrNil kind.
	n := aTypeNodeOrNil name.
	k == #variable ifTrue: [^ TypeVariable named: n].
	k == #block ifTrue: [
		^ BlockType
			args: (aTypeNodeOrNil parts collect: [:p | self typeFrom: p params: params vars: vars class: aClass into: aTypedClass key: aKey]) asArray
			result: (self typeFrom: aTypeNodeOrNil result params: params vars: vars class: aClass into: aTypedClass key: aKey)].
	k == #union ifTrue: [
		^ Type union: (aTypeNodeOrNil parts collect: [:p | self typeFrom: p params: params vars: vars class: aClass into: aTypedClass key: aKey])].
	k == #class ifTrue: [ | p |
		p := aTypeNodeOrNil parts first.
		(p kind == #name and: [p name = 'Self' and: [p parts isEmpty]]) ifTrue: [^ SelfClassType new].
		(p kind == #variable or: [p kind == #name and: [(vars includes: p name) or: [params includes: p name]]]) ifTrue: [^ TypeVariableClass named: p name].
		(p kind == #name and: [p parts isEmpty]) ifTrue: [
			(Smalltalk classNamed: p name) ifNotNil: [:c | ^ MetaType cls: c].
			aTypedClass addProblem: 'no class named ' , p name for: aKey.
			^ Type dynamic].
		aTypedClass addProblem: 'a class type of something that is not a class: ' , p description for: aKey.
		^ Type dynamic].
	k == #name ifFalse: [aTypedClass addProblem: 'a type of kind ' , k , ' here' for: aKey. ^ Type dynamic].
	n = 'Dynamic' ifTrue: [^ Type dynamic].
	n = 'Self' ifTrue: [^ SelfType new].
	n = 'Instance' ifTrue: [
		aTypeNodeOrNil parts isEmpty ifTrue: [^ InstanceType new].
		^ InstanceType new args: (aTypeNodeOrNil parts collect: [:p | self typeFrom: p params: params vars: vars class: aClass into: aTypedClass key: aKey]) asArray; yourself].
	n = 'Nil' ifTrue: [^ Type nilType].
	((vars includes: n) or: [params includes: n]) ifTrue: [^ TypeVariable named: n].
	(Smalltalk classNamed: n) ifNotNil: [:c |
		^ NominalType cls: c args: (aTypeNodeOrNil parts collect: [:p | self typeFrom: p params: params vars: vars class: aClass into: aTypedClass key: aKey]) asArray].
	aTypedClass addProblem: 'no class named ' , n for: aKey.
	^ Type dynamic
]

{ #category : #building }
TypeTable >> typeOfText: aString params: anArray [
	"The Type a type's text writes (as a class definition writes one: Parser class>>parseClassType:), with the names of anArray as type parameters; a CompileError when it does not read or names no class (for tests and tools)."
	| tc t |
	tc := TypedClass cls: nil.
	t := self typeFrom: (Parser parseClassType: aString) params: anArray vars: #() class: nil into: tc key: 'text'.
	(tc problemsOf: 'text') isEmpty ifFalse: [^ CompileError new line: 1; signal: (tc problemsOf: 'text') first].
	^ t
]

{ #category : #lookup }
TypeTable >> ivarTypeOf: aName in: aClass [
	"The declared type of the instance variable aName seen from aClass, or nil."
	| c |
	c := aClass.
	[c notNil] whileTrue: [
		((self typedClass: c) ivars at: aName ifAbsent: [nil]) ifNotNil: [:t | ^ t].
		c := c superclass].
	^ nil
]

{ #category : #lookup }
TypeTable >> keyOf: aSelector in: aBehavior [
	^ aBehavior name , '>>' , aSelector
]

{ #category : #lookup }
TypeTable >> map: aClassType to: aClass [
	"The defining class aClass's parameters, each to the type the receiver aClassType gives it through the superclass arguments between them."
	| map c ps sargs next |
	c := aClassType cls.
	ps := self paramsOf: c.
	map := Dictionary new.
	1 to: ps size do: [:i | map at: (ps at: i) put: (aClassType args size >= i ifTrue: [aClassType args at: i] ifFalse: [Type dynamic])].
	[c notNil and: [c ~~ aClass]] whileTrue: [
		c superclass isNil ifTrue: [^ map].
		sargs := self superArgsOf: c.
		next := Dictionary new.
		ps := self paramsOf: c superclass.
		1 to: ps size do: [:i | next at: (ps at: i) put: ((i <= sargs size ifTrue: [sargs at: i] ifFalse: [Type dynamic]) substitute: map self: nil instance: nil)].
		map := next.
		c := c superclass].
	^ map
]

{ #category : #lookup }
TypeTable >> paramsOf: aClass [
	"The type parameters of aClass: its own (#typeParameters), none when it carries types and writes none, else its superclass's (a class that writes no type passes them through)."
	aClass isNil ifTrue: [^ #()].
	^ (self typedClass: aClass theNonMetaClass) params
]

{ #category : #lookup }
TypeTable >> signaturesFor: aSelector from: aBehavior [
	"{the behavior that answers it. its signatures} for aSelector from aBehavior up, or nil: the first method or signature the lookup meets (Types 2), a typed method or a signature without a method being the answer, an untyped method the answer (nil: its result is inferred) when its class carries no type, and passed over when its class carries any. A class-side lookup goes up the metaclass chain into Class, ClassDescription and Behavior."
	| b tc |
	b := aBehavior.
	[b notNil] whileTrue: [
		tc := self typedClass: b theNonMetaClass.
		(tc signaturesAt: aSelector meta: b isMeta) ifNotNil: [:l | ^ Array with: b with: l].
		((b includesSelector: aSelector) and: [tc carriesTypes not]) ifTrue: [^ nil].
		b := b superclass].
	^ nil
]

{ #category : #lookup }
TypeTable >> superArgsOf: aClass [
	"The types aClass gives its superclass's parameters, over aClass's own parameters."
	| own ps |
	(self typedClass: aClass) superArgs ifNotNil: [:a | ^ a].
	own := self paramsOf: aClass.
	ps := self paramsOf: aClass superclass.
	^ ps collect: [:p | (own includes: p) ifTrue: [TypeVariable named: p] ifFalse: [Type dynamic]]
]

{ #category : #overlay }
TypeTable >> addSignature: aPatternString in: aBehavior [
	"A signature a test or a tool states without changing the image (the experiment's side-file lines read at run time): it replaces, from the next lookup on, what aBehavior's class says of that selector on that side. Answers its dependency key."
	| p sel |
	p := (Parser new setSource: aPatternString) parsePattern.
	sel := (p at: 1) asSymbol.
	(overlay at: aBehavior ifAbsentPut: [OrderedCollection new]) add: aPatternString.
	self forget: aBehavior.
	^ 'sig:' , (self keyOf: sel in: aBehavior)
]

{ #category : #protocols }
TypeTable >> protocolNamed: aString [
	^ protocols at: aString ifAbsent: [nil]
]

{ #category : #protocols }
TypeTable >> register: aTypeProtocol [
	"Add or replace the protocol of that name (protocols made by code, the experiment's question 9); answers the dependency key a checker invalidates."
	protocols at: aTypeProtocol name put: aTypeProtocol.
	^ 'protocol:' , aTypeProtocol name
]

{ #category : #'instance creation' }
TypeTable class >> new [
	^ self basicNew setUp
]
