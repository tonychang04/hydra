'use strict';

/**
 * Return a friendly greeting for the given name.
 *
 * @param {string} name - recipient's name. Falsy values fall back to "world".
 * @returns {string} "Hello, <name>!"
 */
function greet(name) {
  const who = (typeof name === 'string' && name.trim().length > 0) ? name.trim() : 'world';
  return `Hello, ${who}!`;
}

module.exports = { greet };
