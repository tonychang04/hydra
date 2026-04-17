'use strict';

const { test } = require('node:test');
const assert = require('node:assert/strict');
const { greet } = require('./greet');

test('greet returns "Hello, <name>!" for a named input', () => {
  assert.equal(greet('Ada'), 'Hello, Ada!');
});

test('greet falls back to "world" when name is empty or missing', () => {
  assert.equal(greet(''), 'Hello, world!');
  assert.equal(greet(undefined), 'Hello, world!');
});
