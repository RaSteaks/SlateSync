import test from "node:test";
import assert from "node:assert/strict";
import { validateApiRequest } from "../lib/request-security.mjs";

test("same-origin JSON API requests are accepted", () => {
  assert.doesNotThrow(() =>
    validateApiRequest({
      host: "127.0.0.1:4173",
      origin: "http://127.0.0.1:4173",
      "content-type": "application/json; charset=utf-8",
      "sec-fetch-site": "same-origin",
    }),
  );
});

test("HTTPS requests forwarded by a reverse proxy keep same-host protection", () => {
  assert.doesNotThrow(() =>
    validateApiRequest({
      host: "slatesync.example.com",
      origin: "https://slatesync.example.com",
      "content-type": "application/json",
      "sec-fetch-site": "same-origin",
    }),
  );
});

test("cross-site requests are rejected before they can spend API credit", () => {
  assert.throws(
    () =>
      validateApiRequest({
        host: "127.0.0.1:4173",
        origin: "https://attacker.example",
        "content-type": "application/json",
        "sec-fetch-site": "cross-site",
      }),
    (error) => error.status === 403,
  );
});

test("non-JSON requests are rejected even without browser origin headers", () => {
  assert.throws(
    () =>
      validateApiRequest({
        host: "127.0.0.1:4173",
        "content-type": "text/plain",
      }),
    (error) => error.status === 415,
  );
});

test("trusted CLI clients may omit Origin when sending JSON", () => {
  assert.doesNotThrow(() =>
    validateApiRequest({
      host: "127.0.0.1:4173",
      "content-type": "application/json",
    }),
  );
});
