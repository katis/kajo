# Optional types: the direction

Started by the owner on 2026-11-17: "I think we can table AOT 3 for now. I
would like to plan an optional type system for the language. How would that
work with live development, etc."

## The main session's outline, the same day

Types as diagnostics and never a refusal (Strongtalk's and Newspeak's
position), because a live image is inconsistent between changes; an
incremental checker on a background Process in the development image only;
diagnostics over the development protocol, for the tools and an AI agent;
the image proposing types from live values; the VM never trusting a type,
native code using one only as a guarded hint; protocols and classes, `Nil`
explicit, `Self`, block types; generics as the costly part; the syntax
either Strongtalk's inline form or pragmas; an experiment on the kernel
first.

## 2026-11-17, the owner's decisions

"Generics are important, just don't go overboard with the type system.
Speed is a good thing if we can get it, but stuff like documentation,
catching errors and AI feedback is more important. Also as a basis for
better auto complete in the editor for humans. I think we can use the
Strongtalk style syntax. You can experiment with pragmas first if you think
it's easier, but Strontalk for the final build. Diagnostics only."

1. Diagnostics only.
2. Goals in order: documentation, catching errors, AI feedback; completion
   in the editor; speed if it comes.
3. Generics are in; the type system stays small.
4. Strongtalk-style syntax in the final build; the experiment may carry
   types another way.

The experiment's brief is `experiments/optional-types/DESIGN.md`; its
results will be `experiments/optional-types/RESULTS.md`.
