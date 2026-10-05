# nimbu implementation notes

nimbu is an external Gloas (EIP-7732 / ePBS) payload builder in Nim, built on
[nimbus-eth2](https://github.com/status-im/nimbus-eth2). This directory holds
every design note, spec interpretation and decision for the project.

## Index

| #    | Note                                                              | Status          |
| ---- | ----------------------------------------------------------------- | --------------- |
| 0001 | [Architecture flow](0001-architecture-flow.md)                    | draft v0        |
| 0002 | [Gloas spec digest (builder's view)](0002-gloas-spec-digest.md)   | living          |
| 0003 | [What we reuse from nimbus-eth2](0003-nimbus-eth2-reuse.md)       | living          |
| 0004 | [Repository layout and vendoring](0004-repo-layout-and-vendoring.md) | proposed     |
| 0005 | [Decisions and open questions](0005-decisions-and-open-questions.md) | append-only  |
| 0006 | [Coding standards](0006-coding-standards.md)                      | adopted         |

Suggested reading order: 0001 → 0002 → 0003, then the rest as needed.

## Conventions

- **File names.** `NNNN-kebab-topic.md`. Numbers are never reused. Retire a
  note by marking it *superseded by NNNN*; don't delete it.
- **Header.** Each note starts with a title, a `Status:` line and a
  `Last reviewed:` date.
- **Citations.** Spec claims cite the spec file and section, and are pinned
  to the commits listed in [0002](0002-gloas-spec-digest.md#pinned-spec-versions).
- **Symbol references.** References to nimbus-eth2 code give the path and
  symbol name. Line numbers are only valid for the pinned commit in
  [0003](0003-nimbus-eth2-reuse.md).
- **Decisions.** Decisions and open questions go in
  [0005](0005-decisions-and-open-questions.md), not scattered across notes.
- **Code and notes.** Code comments point here (`# see notes/0001 §3.4`)
  instead of duplicating rationale.
