import { describe, expect, it, test } from 'vitest';

describe.each(['a', 'b'])('letter %s', (letter) => {
  it('has length one', () => {
    expect(letter).toHaveLength(1);
  });
});

test.each([1, 2])('number %i', (n) => {
  expect(n).toBeGreaterThan(0);
});

test.for([{ a: 1 }])('object $a', ({ a }) => {
  expect(a).toBe(1);
});

test.each`
  a    | b
  ${1} | ${2}
`('table $a + $b', ({ a, b }) => {
  expect(a + b).toBe(3);
});

for (const n of [1, 2]) {
  test(`loop ${n}`, () => {
    expect(n).toBeTruthy();
  });
}

test(`plain template`, () => {});

describe.concurrent.skip('chained', () => {
  test.skipIf(false)('curried skipIf', () => {});
  it("it\'s \u00e9scaped", function () {});
});
