# Side files

One file per annotated class, `<Class>.types`, read by `OTAnnotations` (the
experiment's checker) one line at a time with the kernel's Scanner. The
kernel's sources are not touched. A line is one of:

    class Name[P, Q]                 the class and its type parameters (first)
    super Superclass[T, U]           what it gives its superclass's parameters
    ivar name <Type>                 an instance variable's type
    cvar Name <Type>                 a class variable's type
    method at: <Integer> put: <E> ^<E>     an instance-side signature
    meta new: <Integer> ^<Instance>        a class-side signature

Types: `Integer`, `Array[E]`, `Dictionary[K, V]`, `String class`, `Integer |
Nil`, `[E, ^Boolean]`, `[^X]`, `Self`, `Self class`, `Instance`,
`Instance[X]`, `X class`, `Dynamic`, `Nil`. A name of one or two characters
that is not a class is a type variable: the class's parameter when the
`class` line names it, else a variable of that method (inferred at each
send). A missing `^<T>` is `Dynamic`. A selector given twice is an overload:
the first signature whose arguments fit is used. `#` starts a comment line.
A line that does not read is an `#annotation` diagnostic.

These were written by hand for the experiment (scripts/draft.py made a
first draft from argument names, which was mostly rewritten).
