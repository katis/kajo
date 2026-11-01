# Kajo

Kajo is my dream programming language project.

I want a Smalltalk that renders native UI (for now, macOS and iOS) and makes live development possible.

Performance must be considered carefully and research of multithreaded and state-of-the art VM designs is needed.
iOS doesn't allow JIT, so a snappy VM and GC is needed. We don't want to make scrolling and animations choppy.

We must find a way to make development smooth (no VM to UI thread delay), while making it hard to lock up the UI thread by accident.

## Use cases
 - Develop iOS app remotely and live from Macbook, with a Smalltalk developer UI in the Macbook with AI agent integration
 - Debug, with all the Smalltalk magic
 - Build and release an iOS or Macbook app

## Design principles:
 - Live, image based development is the key
 - Research state-of-the art
 - But also experiment and invent, be creative
 - Do not lock in a tight roadmap, a step or two at a time, rest are ideas
 - References are for inspiration and research, not for copy-paste. This is a greenfield project, no legacy cruft.

## Development principles:
 - Experiment technical details carefully before locking in designs.
 - "Modules hide decisions, not just data"
 - Use TDD wherever possible

## Project structure

 * `references/` contains prior art and other references we might benefit from in the design.
