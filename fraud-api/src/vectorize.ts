import mccRisk from "./data/mcc_risk.json";
import normalization from "./data/normalization.json";

const MCC_RISK: Record<string, number> = mccRisk;
const NORM = normalization;

function clamp(v: number): number {
  if (v < 0) return 0;
  if (v > 1) return 1;
  return v;
}

export interface Payload {
  id: string;
  transaction: {
    amount: number;
    installments: number;
    requested_at: string;
  };
  customer: {
    avg_amount: number;
    tx_count_24h: number;
    known_merchants: string[];
  };
  merchant: {
    id: string;
    mcc: string;
    avg_amount: number;
  };
  terminal: {
    is_online: boolean;
    card_present: boolean;
    km_from_home: number;
  };
  last_transaction: {
    timestamp: string;
    km_from_current: number;
  } | null;
}

export function vectorize(payload: Payload): Float32Array {
  const vec = new Float32Array(14);

  vec[0] = clamp(payload.transaction.amount / NORM.max_amount);
  vec[1] = clamp(payload.transaction.installments / NORM.max_installments);
  vec[2] = payload.customer.avg_amount === 0
    ? 0
    : clamp((payload.transaction.amount / payload.customer.avg_amount) / NORM.amount_vs_avg_ratio);

  const reqDate = new Date(payload.transaction.requested_at);
  if (isNaN(reqDate.getTime())) {
    vec[3] = -1;
    vec[4] = -1;
  } else {
    vec[3] = reqDate.getUTCHours() / 23.0;
    // Map JS getUTCDay() (0=Sunday..6=Saturday) to official spec (0=Monday..6=Sunday)
    vec[4] = ((reqDate.getUTCDay() + 6) % 7) / 6.0;
  }

  if (payload.last_transaction && !isNaN(reqDate.getTime())) {
    const lastDate = new Date(payload.last_transaction.timestamp);
    if (isNaN(lastDate.getTime())) {
      vec[5] = -1;
      vec[6] = -1;
    } else {
      const minutes = Math.floor((reqDate.getTime() - lastDate.getTime()) / 60000);
      vec[5] = clamp(minutes / NORM.max_minutes);
      vec[6] = clamp(payload.last_transaction.km_from_current / NORM.max_km);
    }
  } else {
    vec[5] = -1;
    vec[6] = -1;
  }

  vec[7] = clamp(payload.terminal.km_from_home / NORM.max_km);
  vec[8] = clamp(payload.customer.tx_count_24h / NORM.max_tx_count_24h);
  vec[9] = payload.terminal.is_online ? 1 : 0;
  vec[10] = payload.terminal.card_present ? 1 : 0;
  vec[11] = payload.customer.known_merchants.includes(payload.merchant.id) ? 0 : 1;
  vec[12] = MCC_RISK[payload.merchant.mcc] ?? 0.5;
  vec[13] = clamp(payload.merchant.avg_amount / NORM.max_merchant_avg_amount);

  return vec;
}
