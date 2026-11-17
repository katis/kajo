"A subclass of TypeCheckerSample with signatures without a method (Types 2): one that narrows what it inherits as the type language allows (an argument narrowed from Object to String, as Number's comparisons narrow Magnitude's), one that contradicts it (a String where an Integer is answered), and one for a selector nothing answers. Never run; only read."
Class {
	#name : #TypeCheckerNarrowSample,
	#superclass : #TypeCheckerSample
}

{ #category : #samples }
TypeCheckerNarrowSample >> okReturn ^<String>

{ #category : #samples }
TypeCheckerNarrowSample >> okTypeTest: anObject <String> ^<Dynamic>

{ #category : #samples }
TypeCheckerNarrowSample >> zork ^<Integer>
