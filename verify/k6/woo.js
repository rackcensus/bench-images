import http from 'k6/http';
import { check } from 'k6';
import { Trend } from 'k6/metrics';

const woo = JSON.parse(open('/work/woocommerce.json'));
const params = JSON.parse(open('/work/params.json'));
const base = params.base;
const duration = `${params.duration_seconds}s`;

const headers = {
  Accept: 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
  'Accept-Encoding': 'gzip',
  'Accept-Language': 'en-US,en;q=0.9',
  'User-Agent': 'Mozilla/5.0 (X11; Linux x86_64) rackcensus-verify',
};

const pageSteps = ['home', 'shop', 'category', 'product', 'search'];
const cartSteps = ['add_to_cart', 'cart', 'checkout'];
const trends = {};
for (const step of pageSteps.concat(cartSteps)) {
  trends[step] = new Trend(`woo_${step}`, true);
}

export const options = {
  scenarios: {
    page_mix: { executor: 'constant-vus', exec: 'pageMix', vus: params.vus, duration, gracefulStop: '10s' },
    cart_flow: {
      executor: 'constant-vus', exec: 'cartFlow', vus: params.vus, duration, gracefulStop: '10s',
      startTime: `${params.duration_seconds + 5}s`,
    },
  },
  thresholds: { checks: ['rate==1'], http_req_failed: ['rate==0'] },
  summaryTrendStats: ['avg', 'med', 'p(95)', 'p(99)', 'max', 'count'],
};

function pick(list) {
  return list[Math.floor(Math.random() * list.length)];
}

function get(step, path, jar) {
  const res = http.get(base + path, { headers, jar, redirects: 0, tags: { step } });
  trends[step].add(res.timings.duration);
  return res;
}

const pages = {
  home: () => ['/', 'wp-block-woocommerce-product-collection'],
  shop: () => [woo.pages.shop, 'woocommerce-result-count'],
  category: () => [pick(woo.category_paths), 'woocommerce-result-count'],
  product: () => [pick(woo.product_paths), 'single_add_to_cart_button'],
  search: () => [`/?s=${encodeURIComponent(pick(woo.search_terms))}&post_type=product`, 'woocommerce-result-count'],
};

export function pageMix() {
  const step = pageSteps[(__ITER + __VU) % pageSteps.length];
  const [path, marker] = pages[step]();
  const res = get(step, path);
  check(res, {
    [`${step} is 200`]: (r) => r.status === 200,
    [`${step} has content`]: (r) => r.body.includes(marker),
  });
}

export function cartFlow() {
  const jar = new http.CookieJar();
  const id = pick(woo.product_ids);
  const item = `%22id%22%3A${id}%2C`;

  const added = get('add_to_cart', `/?add-to-cart=${id}`, jar);
  const cookies = jar.cookiesForURL(`${base}/`);
  check(added, {
    'add_to_cart is 200': (r) => r.status === 200,
    'add_to_cart sets woocommerce_items_in_cart': () => (cookies.woocommerce_items_in_cart || [])[0] === '1',
  });

  const cart = get('cart', woo.pages.cart, jar);
  check(cart, {
    'cart is 200': (r) => r.status === 200,
    'cart holds one item': (r) => r.body.includes('%22items_count%22%3A1%2C'),
    'cart holds the product': (r) => r.body.includes(item),
  });

  const checkout = get('checkout', woo.pages.checkout, jar);
  check(checkout, {
    'checkout is 200': (r) => r.status === 200,
    'checkout renders the checkout block': (r) => r.body.includes('wp-block-woocommerce-checkout'),
    'checkout holds the product': (r) => r.body.includes(item),
  });
}

function stepSummary(data, step, seconds) {
  const metric = data.metrics[`woo_${step}`];
  if (!metric) {
    return { step, requests: 0 };
  }
  const v = metric.values;
  return {
    step,
    requests: v.count,
    requests_per_second: v.count / seconds,
    latency_ms: { avg: v.avg, p50: v.med, p95: v['p(95)'], p99: v['p(99)'], max: v.max },
  };
}

export function handleSummary(data) {
  const seconds = params.duration_seconds;
  const result = {
    vus: params.vus,
    duration_seconds: seconds,
    checks: { passes: data.metrics.checks.values.passes, fails: data.metrics.checks.values.fails },
    http_req_failed: data.metrics.http_req_failed.values.rate,
    page_mix: pageSteps.map((s) => stepSummary(data, s, seconds)),
    cart_flow: cartSteps.map((s) => stepSummary(data, s, seconds)),
  };
  const lines = result.page_mix.concat(result.cart_flow).map((s) =>
    `${s.step}: ${s.requests} requests, ${(s.requests_per_second || 0).toFixed(1)} req/s, p95 ${s.latency_ms ? s.latency_ms.p95.toFixed(1) : 0} ms`);
  lines.push(`checks: ${result.checks.passes} passed, ${result.checks.fails} failed`);
  return {
    '/work/k6-summary.json': JSON.stringify(result, null, 2),
    stdout: `${lines.join('\n')}\n`,
  };
}
