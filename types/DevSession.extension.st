Extension { #name : #DevSession }

{ #category : #'requests-types' }
DevSession >> diagnostics: className selector: selector side: side [
	"The type checker's diagnostics (Types 2, docs/modules/types-2.md): of the whole image, of a class (className; both sides) or of one method or signature without a method (className and selector; side instance, the default, or class), once the checker has caught up with every change; each with its kind, class, side, selector, line, source range (start and end, nil for the whole method) and text, and the count. The first request starts the checker, which checks the image on a background Process and then rechecks after every change, emitting diagnostics.changed when a recheck changed the set. Diagnostics only: nothing is refused for a type. A request of the Types package, which only development images hold: elsewhere it is an unknown request."
	<devProtocol>
	^ TypeService diagnosticsOf: className selector: selector side: side
]
