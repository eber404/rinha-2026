import { expect, test } from "bun:test";
import { vectorize, type Payload } from "./vectorize";

const base: Payload = {
  id: "tx-1",
  transaction: { amount: 100, installments: 2, requested_at: "2026-03-10T10:00:00Z" },
  customer: { avg_amount: 200, tx_count_24h: 3, known_merchants: ["M1"] },
  merchant: { id: "M1", mcc: "5411", avg_amount: 100 },
  terminal: { is_online: false, card_present: true, km_from_home: 12 },
  last_transaction: null,
};

test("keeps -1 when last_transaction is null", () => {
  const v = vectorize(base);
  expect(v[5]).toBe(-1);
  expect(v[6]).toBe(-1);
});

test("maps monday to official day_of_week 0", () => {
  const v = vectorize({
    ...base,
    transaction: { ...base.transaction, requested_at: "2026-03-09T10:00:00Z" },
  });
  expect(v[4]).toBe(0);
});

test("clamps amount dimensions to normalized range", () => {
  const v = vectorize({
    ...base,
    transaction: { ...base.transaction, amount: 20000 },
    customer: { ...base.customer, avg_amount: 1 },
  });
  expect(v[0]).toBe(1);
  expect(v[2]).toBe(1);
});
