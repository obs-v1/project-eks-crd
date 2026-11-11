// BankObs load generator — drives the API GATEWAY directly (gateway-service:8000), NOT the
// web-portal SSR tier. Each VU: log in through the gateway (→ auth-service) to get a JWT, then
// fire a burst of UPI payments through the gateway (→ payment-gateway → upi-service → router →
// fraud → ledger → account). Everything is OTel-traced, so Jaeger + the spanmetrics RED dashboards
// light up.
//
// WHY gateway-direct: when the journey hit web-portal:8200, almost all load was server-side page
// rendering absorbed by web-portal; only a thin slice reached gateway-service, so a CPU-saturation
// fault on the gateway never produced a visible latency cascade (and web-portal's SSR tier — which
// emits no spanmetrics — became the real, invisible bottleneck). Hitting the gateway's own API
// routes puts the load squarely on gateway-service, so throttling its CPU shows up directly as a
// p95 cascade on the RED dashboard, and propagates down the payment rails.
import http from 'k6/http';
import { check, sleep } from 'k6';
import { Rate } from 'k6/metrics';

const BASE = __ENV.BASE_URL || 'http://gateway-service:8000';
const VUS = parseInt(__ENV.VUS || '10', 10);
const DURATION = __ENV.DURATION || '24h';
const PAY_BURST = parseInt(__ENV.PAY_BURST || '3', 10);    // payments per login iteration
const THINK = parseFloat(__ENV.THINK || '0.1');            // base think-time between calls (seconds)

const journeyErrors = new Rate('journey_errors');

export const options = {
  scenarios: {
    customers: { executor: 'constant-vus', vus: VUS, duration: DURATION },
  },
  thresholds: { journey_errors: ['rate<0.9'] }, // informational; faults are expected
  insecureSkipTLSVerify: true,
  noConnectionReuse: false,
};

const PASS = __ENV.PASS || 'Training@123';
// Payments RECIRCULATE within a pool of well-funded internal customers: each iteration logs in as
// one pool member (the payer) and pays ANOTHER, so money only moves between them and no single
// account drains (the old web-portal journey always paid FROM cust00000001 → it drained to ~0 and
// every later debit 409'd → a fake, growing error floor). Each {cust,vpa} is seeded in Oracle +
// vpa_registry and funded with ₹200k+. The sender MUST be the logged-in customer, so payer identity
// and from_vpa are chosen together. Override with POOL_CUSTS / POOL_VPAS (comma-separated, aligned).
const POOL_CUSTS = (__ENV.POOL_CUSTS || 'CUST-00000002,CUST-00000003,CUST-00000004,CUST-00000005').split(',');
const POOL_VPAS  = (__ENV.POOL_VPAS  || 'cust00000002@bankobs,cust00000003@bankobs,cust00000004@bankobs,cust00000005@bankobs').split(',');
const POOL = POOL_CUSTS.map((c, i) => ({ cust: c.trim(), vpa: POOL_VPAS[i].trim() }));

function pick(a) { return a[Math.floor(Math.random() * a.length)]; }

export default function () {
  const me = pick(POOL);
  // 1) login through the gateway (→ auth-service); grab the JWT for the payment calls
  const login = http.post(
    `${BASE}/api/v1/auth/login`,
    JSON.stringify({ customer_id: me.cust, password: PASS }),
    { headers: { 'Content-Type': 'application/json' }, tags: { name: 'login' } },
  );
  const okLogin = check(login, { 'login 200': (r) => r.status === 200 });
  journeyErrors.add(!okLogin);
  if (!okLogin) { sleep(1); return; }
  const token = login.json('data.token');
  const authHdr = { 'Content-Type': 'application/json', 'Authorization': `Bearer ${token}` };
  sleep(Math.random() * THINK + THINK);

  // 2) burst of UPI payments through the gateway (full payment chain; best-effort under a fault)
  for (let i = 0; i < PAY_BURST; i++) {
    let payee = pick(POOL);
    if (POOL.length > 1) { while (payee.vpa === me.vpa) payee = pick(POOL); }
    const amt = Math.floor(Math.random() * 500) + 10;
    const pay = http.post(
      `${BASE}/api/v1/payments/initiate`,
      JSON.stringify({ payment_type: 'UPI', from_vpa: me.vpa, to_vpa: payee.vpa, amount: amt }),
      { headers: authHdr, tags: { name: 'pay' }, timeout: '15s' },
    );
    // healthy pay returns 202 {status: COMPLETED}; under a fault it may 5xx / time out (expected).
    check(pay, { 'pay ok': (r) => r.status === 202 || r.status === 200 }) || journeyErrors.add(1);
    sleep(Math.random() * THINK + THINK);
  }
}
