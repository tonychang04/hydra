# hollo-hydra-demo

A minimal Node project used as fixture fodder for the "Hydra in 10 minutes" demo.

> Note: there is an intentional typo on the heading above ("hollo" should be "hello"). That typo is the T1 target for fixture issue `01-t1-typo.md`. Don't fix it by hand — let Hydra do it.

## What this is

A zero-dep Node 18+ package with one exported function (`greet`) and two tests that run under node's built-in test runner. No `npm install`. No lockfile. Nothing to set up. You should be able to clone and immediately run:

```bash
node --test src/greet.test.js
```

## Layout

```
hello-hydra-demo/
├── package.json            Node package metadata + test script
├── README.md               this file (contains the T1 typo target)
├── src/
│   ├── greet.js            the greet(name) function
│   └── greet.test.js       two passing node:test cases
├── fixture-issues/         three fixture issue bodies to file via gh-filings.sh
├── gh-filings.sh           one-command script to open the three issues on your fork
└── DEMO.md                 the 10-minute walkthrough
```

## Usage

```bash
node -e "const {greet} = require('./src/greet'); console.log(greet('Ada'))"
# -> Hello, Ada!
```

Run the tests:

```bash
node --test src/greet.test.js
# (two passing tests)
```

See [DEMO.md](./DEMO.md) for the full 10-minute walkthrough that wires this demo into a Hydra session.
