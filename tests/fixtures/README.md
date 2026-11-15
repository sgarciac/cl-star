# Interop fixtures

These files are vendored from the reference implementation of the format:

* https://tangled.org/bnewbold.net/cobalt/tree/main/star/testdata

They are the interop vectors of
https://tangled.org/microcosm.blue/star/tree/interop/interop, updated to the
layout of the current specification:

```
[ magic | len | meta ] [ 1 | len | key | len | val ] * [ 0 ]
```

| file | contents |
| --- | --- |
| `valid-star-fixtures.json` | archives that must parse, with their expected metadata and pairs |
| `invalid-star-fixtures.json` | archives that must be rejected |
| `invalid-star-fixtures-varint.json` | archives that must be rejected because of their varints |
| `example.star` | a small archive with a DRISL metadata and two pairs |

They are used by `tests/interop.lisp`.

Note that the metadata of the invalid fixtures is not always the problem: some
of them are malformed containers, others hold a metadata that is not a valid
DRISL map (no `$type`, a non string `$type`, a non canonical encoding, ...).
`cl-star` only handles the container, the metadata is validated with
`cl-atproto-drisl` through the `:meta-validator` hook of the reader.
